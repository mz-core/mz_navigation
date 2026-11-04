--[[
    mz_navigation - registry server-side de camadas e POIs.

    Regras:
      - o registry e a fonte autoritativa; o cliente nunca define visibilidade;
      - cada resource so altera camadas/POIs que registrou;
      - limites de quantidade impedem inflacao de memoria;
      - POIs expirados (TTL) sao descartados na leitura.
]]

MZNavigation = MZNavigation or {}
MZNavigation.Registry = MZNavigation.Registry or {}

local Registry = MZNavigation.Registry
local Schema = MZNavigation.Schema

local layers = {}
local pois = {}
local poiIdsByLayer = {}

local VISIBLE_ORDER = {
    public = 1,
    character = 2,
    org = 3,
    staff = 4
}

local function limits()
    return Config.Limits
end

local function geometryLimits()
    return {
        maxWorld = Config.Waypoint.maxWorld,
        minZ = Config.Waypoint.minZ,
        maxZ = Config.Waypoint.maxZ
    }
end

local function countPois()
    local total = 0
    for _ in pairs(pois) do total = total + 1 end
    return total
end

local function countLayers()
    local total = 0
    for _ in pairs(layers) do total = total + 1 end
    return total
end

function Registry.CountPois()
    return countPois()
end

function Registry.CountLayers()
    return countLayers()
end

function Registry.Reset()
    layers = {}
    pois = {}
    poiIdsByLayer = {}
end

function Registry.GetLayer(id)
    return layers[id]
end

function Registry.GetPoi(id)
    local poi = pois[id]
    if not poi then return nil end
    if poi.expiresAt and poi.expiresAt <= os.time() then
        Registry.RemovePoi(poi.id, poi.ownerResource, true)
        return nil
    end
    return poi
end

function Registry.RegisterLayer(def, ownerResource)
    if type(ownerResource) ~= 'string' or ownerResource == '' then
        return nil, 'layer_owner_required'
    end
    local existingId = type(def) == 'table' and def.id or nil
    if countLayers() >= limits().maxLayers and not (existingId and layers[existingId]) then
        return nil, 'layer_limit_reached'
    end

    local layer, err = Schema.NormalizeLayer(def, ownerResource, limits())
    if not layer then return nil, err end

    local existing = layers[layer.id]
    if existing and existing.ownerResource ~= ownerResource then
        return nil, 'layer_owned_by_other_resource'
    end
    if existing then
        layer.revision = (tonumber(existing.revision) or 1) + 1
    end

    layers[layer.id] = layer
    return layer
end

function Registry.UnregisterLayer(id, ownerResource)
    if not Schema.IsValidId(id, limits().idMaxLength) then return false, 'layer_id_invalid' end
    local layer = layers[id]
    if not layer then return false, 'layer_not_found' end
    if layer.ownerResource ~= ownerResource then return false, 'layer_owned_by_other_resource' end

    for poiId in pairs(poiIdsByLayer[id] or {}) do
        pois[poiId] = nil
    end
    poiIdsByLayer[id] = nil
    layers[id] = nil
    return true
end

function Registry.UpsertPoi(def, ownerResource)
    if type(ownerResource) ~= 'string' or ownerResource == '' then
        return nil, 'poi_owner_required'
    end

    local poi, err = Schema.NormalizePoi(def, limits(), geometryLimits(), os.time())
    if not poi then return nil, err end

    local layer = layers[poi.layer]
    if not layer then return nil, 'layer_not_found' end

    if poi.visibility == 'staff' or poi.visibility == 'org' or poi.visibility == 'session' then
        return nil, 'poi_visibility_not_supported'
    end
    if poi.visibility == 'character' and layer.visibility ~= 'public' and layer.visibility ~= 'character' then
        return nil, 'poi_visibility_conflict'
    end

    local existing = pois[poi.id]
    if existing then
        if existing.ownerResource ~= ownerResource then return nil, 'poi_owned_by_other_resource' end
        poi.revision = (tonumber(existing.revision) or 1) + 1
    else
        local layerCount = 0
        for _ in pairs(poiIdsByLayer[poi.layer] or {}) do layerCount = layerCount + 1 end
        if layerCount >= limits().maxPoisPerLayer then return nil, 'poi_layer_limit_reached' end
        if countPois() >= limits().maxPoisTotal then return nil, 'poi_limit_reached' end
    end

    poi.ownerResource = ownerResource
    pois[poi.id] = poi
    poiIdsByLayer[poi.layer] = poiIdsByLayer[poi.layer] or {}
    poiIdsByLayer[poi.layer][poi.id] = true

    return poi
end

function Registry.RemovePoi(id, ownerResource, internal)
    if not Schema.IsValidId(id, limits().idMaxLength) then return false, 'poi_id_invalid' end
    local poi = pois[id]
    if not poi then return false, 'poi_not_found' end
    if not internal and poi.ownerResource ~= ownerResource then
        return false, 'poi_owned_by_other_resource'
    end
    pois[id] = nil
    local bucket = poiIdsByLayer[poi.layer]
    if bucket then bucket[id] = nil end
    return true
end

--[[
    ctx = {
      source,
      characterId = number|nil,
      orgCodes = set<string>|nil,
      canStaff = function(permission) -> boolean
    }
]]
local function layerVisible(layer, ctx)
    local visibility = layer.visibility or 'public'
    if visibility == 'public' then return true end
    if visibility == 'character' then
        return ctx.characterId ~= nil and layer.ownerCharacterId == ctx.characterId
    end
    if visibility == 'org' then
        if type(ctx.orgCodes) ~= 'table' or type(layer.orgCodes) ~= 'table' then return false end
        for _, code in ipairs(layer.orgCodes) do
            if ctx.orgCodes[code] then return true end
        end
        return false
    end
    if visibility == 'staff' then
        if type(ctx.canStaff) ~= 'function' then return false end
        local ok, allowed = pcall(ctx.canStaff, layer.permission)
        return ok and allowed == true
    end
    if visibility == 'session' then
        return ctx.sessionId ~= nil and tostring(layer.sessionId) == tostring(ctx.sessionId)
    end
    return false
end

local function poiVisible(poi, layer, ctx)
    local visibility = poi.visibility or layer.visibility or 'public'
    if visibility == 'character' then
        return ctx.characterId ~= nil and poi.ownerCharacterId == ctx.characterId
    end
    return visibility == 'public'
end

local function publicLayer(layer)
    return {
        id = layer.id,
        label = layer.label,
        icon = layer.icon,
        category = layer.category,
        visibility = layer.visibility,
        defaultEnabled = layer.defaultEnabled,
        order = layer.order,
        revision = layer.revision,
        ownerResource = layer.ownerResource
    }
end

local function publicPoi(poi)
    return {
        id = poi.id,
        layer = poi.layer,
        label = poi.label,
        x = poi.x,
        y = poi.y,
        z = poi.z,
        icon = poi.icon,
        visibility = poi.visibility,
        revision = poi.revision,
        metadata = poi.metadata
    }
end

function Registry.Collect(ctx)
    local visibleLayers, visiblePois = {}, {}
    local now = os.time()

    for _, layer in pairs(layers) do
        if layerVisible(layer, ctx) then
            visibleLayers[#visibleLayers + 1] = publicLayer(layer)
        end
    end

    for _, poi in pairs(pois) do
        if not (poi.expiresAt and poi.expiresAt <= now) then
            local layer = layers[poi.layer]
            if layer and layerVisible(layer, ctx) and poiVisible(poi, layer, ctx) then
                visiblePois[#visiblePois + 1] = publicPoi(poi)
            end
        end
    end

    table.sort(visibleLayers, function(a, b)
        local left = tonumber(a.order) or 999
        local right = tonumber(b.order) or 999
        if left == right then return a.id < b.id end
        return left < right
    end)

    table.sort(visiblePois, function(a, b)
        local left = VISIBLE_ORDER[a.visibility or 'public'] or 9
        local right = VISIBLE_ORDER[b.visibility or 'public'] or 9
        if left == right then return a.id < b.id end
        return left < right
    end)

    return visibleLayers, visiblePois
end

function Registry.GetVisiblePoi(id, ctx)
    local poi = Registry.GetPoi(id)
    if not poi then return nil end
    local layer = layers[poi.layer]
    if not layer then return nil end
    if not layerVisible(layer, ctx) or not poiVisible(poi, layer, ctx) then return nil end
    return publicPoi(poi)
end
