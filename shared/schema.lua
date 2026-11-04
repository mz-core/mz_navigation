--[[
    mz_navigation - validacao de payloads.

    Todo dado vindo de cliente, config ou export de outro resource passa por aqui
    antes de entrar no registry ou no banco. Falhar fechado e o padrao.
]]

MZNavigation = MZNavigation or {}
MZNavigation.Schema = MZNavigation.Schema or {}

local Schema = MZNavigation.Schema
local Geo = MZNavigation.Geo

local VISIBILITIES = {
    public = true,
    staff = true,
    org = true,
    character = true,
    session = true
}

local function sanitizeText(value, maximum)
    if type(value) ~= 'string' then return '' end
    local text = value:gsub('[%z\1-\31\127]', ' ')
    text = text:gsub('%s+', ' ')
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    maximum = tonumber(maximum) or 80
    if #text > maximum then
        text = text:sub(1, maximum)
        text = text:gsub('%s+$', '')
    end
    return text
end

function Schema.SanitizeText(value, maximum)
    return sanitizeText(value, maximum)
end

function Schema.IsValidId(value, maximum)
    if type(value) ~= 'string' then return false end
    maximum = tonumber(maximum) or 96
    if #value < 1 or #value > maximum then return false end
    return value:match('^[a-z][a-z0-9_%-%.:]*$') ~= nil
end

local function sanitizeMetadata(metadata, limit)
    if type(metadata) ~= 'table' then return nil end
    local out, count = {}, 0
    for key, value in pairs(metadata) do
        if type(key) == 'string' and #key <= 32 and key:match('^[a-z][a-z0-9_]*$') then
            local valueType = type(value)
            local accepted = valueType == 'string' or valueType == 'number' or valueType == 'boolean'
            if accepted then
                count = count + 1
                if count > limit then return nil end
                out[key] = valueType == 'string' and sanitizeText(value, 120) or value
            end
        end
    end
    if count == 0 then return nil end
    return out
end

local function normalizeVisibility(value)
    value = tostring(value or 'public'):lower()
    if not VISIBILITIES[value] then return nil end
    return value
end

--[[
    def = {
      id, label, icon?, category?, visibility?, defaultEnabled?, order?,
      permission?,      -- exigido quando visibility='staff'
      orgCodes?,        -- exigido quando visibility='org'
      ownerCharacterId? -- usado quando visibility='character'
    }
]]
function Schema.NormalizeLayer(def, ownerResource, limits)
    if type(def) ~= 'table' then return nil, 'layer_invalid' end

    local id = def.id
    if not Schema.IsValidId(id, limits.idMaxLength) then return nil, 'layer_id_invalid' end

    local label = sanitizeText(def.label, limits.labelMaxLength)
    if label == '' then return nil, 'layer_label_invalid' end

    local visibility = normalizeVisibility(def.visibility)
    if not visibility then return nil, 'layer_visibility_invalid' end

    local layer = {
        id = id,
        label = label,
        icon = Schema.IsValidId(def.icon, 32) and def.icon or nil,
        category = Schema.IsValidId(def.category, 32) and def.category or nil,
        visibility = visibility,
        defaultEnabled = def.defaultEnabled ~= false,
        order = tonumber(def.order) or 999,
        ownerResource = ownerResource,
        revision = 1
    }

    if visibility == 'staff' then
        if not Schema.IsValidId(def.permission, 64) then return nil, 'layer_permission_required' end
        layer.permission = def.permission
    elseif visibility == 'org' then
        if type(def.orgCodes) ~= 'table' or #def.orgCodes == 0 or #def.orgCodes > 32 then
            return nil, 'layer_orgcodes_required'
        end
        local orgCodes = {}
        for _, code in ipairs(def.orgCodes) do
            if type(code) ~= 'string' or #code > 64 or not code:match('^[%w_%-]+$') then
                return nil, 'layer_orgcode_invalid'
            end
            orgCodes[#orgCodes + 1] = code
        end
        layer.orgCodes = orgCodes
    elseif visibility == 'character' then
        local characterId = tonumber(def.ownerCharacterId)
        if not characterId or characterId < 1 or characterId % 1 ~= 0 then
            return nil, 'layer_owner_required'
        end
        layer.ownerCharacterId = characterId
    elseif visibility == 'session' then
        local sessionId = tonumber(def.sessionId)
        if not sessionId or sessionId < 1 or sessionId % 1 ~= 0 then
            return nil, 'layer_session_required'
        end
        layer.sessionId = sessionId
    end

    return layer
end

--[[
    def = {
      id, layer, label, x, y, z?, icon?, visibility?, ownerCharacterId?,
      metadata?, ttlSeconds?
    }
]]
function Schema.NormalizePoi(def, limits, geometryLimits, now)
    if type(def) ~= 'table' then return nil, 'poi_invalid' end

    local id = def.id
    if not Schema.IsValidId(id, limits.idMaxLength) then return nil, 'poi_id_invalid' end

    local layer = def.layer or def.layerId
    if not Schema.IsValidId(layer, limits.idMaxLength) then return nil, 'poi_layer_invalid' end

    local label = sanitizeText(def.label, limits.labelMaxLength)
    if label == '' then return nil, 'poi_label_invalid' end

    local coords, coordsErr = Geo.NormalizeCoords({ x = def.x, y = def.y, z = def.z }, geometryLimits)
    if not coords then return nil, coordsErr end

    local poi = {
        id = id,
        layer = layer,
        label = label,
        x = coords.x,
        y = coords.y,
        z = coords.z,
        icon = Schema.IsValidId(def.icon, 32) and def.icon or nil,
        revision = 1
    }

    if def.visibility ~= nil then
        local visibility = normalizeVisibility(def.visibility)
        if not visibility then return nil, 'poi_visibility_invalid' end
        poi.visibility = visibility
        if visibility == 'character' then
            local characterId = tonumber(def.ownerCharacterId)
            if not characterId or characterId < 1 or characterId % 1 ~= 0 then
                return nil, 'poi_owner_required'
            end
            poi.ownerCharacterId = characterId
        end
    end

    poi.metadata = sanitizeMetadata(def.metadata, limits.maxMetadataKeys)

    local ttl = tonumber(def.ttlSeconds)
    if ttl ~= nil then
        if ttl < 1 or ttl > 86400 * 7 then return nil, 'poi_ttl_invalid' end
        poi.expiresAt = (now or os.time()) + math.floor(ttl)
    end

    return poi
end

function Schema.NormalizeFavorite(payload, limits)
    if type(payload) ~= 'table' then return nil, 'favorite_invalid' end

    local label = sanitizeText(payload.label, limits.labelMaxLength)
    if label == '' then return nil, 'favorite_label_invalid' end

    local coords, coordsErr = Geo.NormalizeCoords(
        { x = payload.x, y = payload.y, z = payload.z },
        { maxWorld = 20000.0, minZ = -2000.0, maxZ = 3000.0 }
    )
    if not coords then return nil, coordsErr end

    local favored = {
        label = label,
        x = coords.x,
        y = coords.y,
        z = coords.z,
        poiId = Schema.IsValidId(payload.poiId, limits.idMaxLength) and payload.poiId or nil
    }

    return favored
end

function Schema.NormalizeRecent(payload, limits)
    if type(payload) ~= 'table' then return nil, 'recent_invalid' end

    local label = sanitizeText(payload.label, limits.labelMaxLength)
    if label == '' then label = 'Destino' end

    local coords, coordsErr = Geo.NormalizeCoords(
        { x = payload.x, y = payload.y, z = payload.z },
        { maxWorld = 20000.0, minZ = -2000.0, maxZ = 3000.0 }
    )
    if not coords then return nil, coordsErr end

    return {
        label = label,
        x = coords.x,
        y = coords.y,
        z = coords.z,
        poiId = Schema.IsValidId(payload.poiId, limits.idMaxLength) and payload.poiId or nil
    }
end

--[[
    Selecao devolvida pelo picker. z so acompanha quando o cliente conseguiu
    resolve-lo com confianca; caso contrario o campo e omitido.
]]
function Schema.NormalizeSelection(payload, geometryLimits)
    if type(payload) ~= 'table' then return nil, 'selection_invalid' end

    if payload.poiId ~= nil and not Schema.IsValidId(payload.poiId, 96) then
        return nil, 'selection_poi_invalid'
    end

    local coords, coordsErr = Geo.NormalizeCoords(
        { x = payload.x, y = payload.y, z = payload.z },
        geometryLimits
    )
    if not coords then return nil, coordsErr end

    return {
        x = coords.x,
        y = coords.y,
        z = coords.z,
        zReliable = payload.zReliable == true,
        poiId = payload.poiId,
        label = sanitizeText(payload.label, 80)
    }
end
