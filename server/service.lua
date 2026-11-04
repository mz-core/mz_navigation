--[[
    mz_navigation - servico server-side.

    Autoridade:
      - identidade resolvida por mz_core (source -> characterId/citizenid);
      - ACL de camadas e POIs resolvida aqui, nunca no cliente;
      - favoritos/recentes persistidos por character_id;
      - picker server-initiated com requestId, timeout e callback.

    O cliente so recebe dados ja filtrados.
]]

MZNavigation = MZNavigation or {}
MZNavigation.Service = MZNavigation.Service or {}

local Service = MZNavigation.Service
local Registry = MZNavigation.Registry
local Repository = MZNavigation.Repository
local Schema = MZNavigation.Schema
local RouteService = MZNavigation.RouteService

Service.Ready = false
Service.PendingPickers = {}

local RateBuckets = {}
local PickerCounts = {}
local SelectionCache = {}
local SelectionOrder = {}
local pickerCounter = 0

local RATE_ACTIONS = {
    bootstrap = 'bootstrap',
    listPOIs = 'listPOIs',
    ['favorites.list'] = 'bootstrap',
    ['favorites.add'] = 'favoritesAdd',
    ['favorites.remove'] = 'favoritesRemove',
    ['recents.list'] = 'bootstrap',
    ['recents.add'] = 'recentsAdd',
    ['routes.list'] = 'routesList',
    ['routes.get'] = 'routesRead',
    ['routes.create'] = 'routesWrite',
    ['routes.update'] = 'routesWrite',
    ['routes.delete'] = 'routesDelete',
    ['routes.publish'] = 'routesPublish',
    ['routes.unpublish'] = 'routesPublish',
    ['routes.catalog'] = 'routesList',
    ['routes.catalog.get'] = 'routesRead'
}

local function nowSeconds()
    return os.time()
end

local function rateAllowed(source, action)
    local key = RATE_ACTIONS[action]
    local policy = key and Config.RateLimits[key]
    if not policy then return false end
    local bucketKey = ('%s:%s'):format(tostring(source), tostring(key))
    local current = RateBuckets[bucketKey]
    local now = nowSeconds()
    if not current or now - current.startedAt >= policy.window then
        current = { startedAt = now, count = 0 }
        RateBuckets[bucketKey] = current
    end
    current.count = current.count + 1
    return current.count <= policy.max
end

local function clearRate(source)
    local prefix = tostring(source) .. ':'
    for key in pairs(RateBuckets) do
        if key:sub(1, #prefix) == prefix then RateBuckets[key] = nil end
    end
end

local function coreIdentity(source)
    local ok, identity = pcall(function()
        return exports['mz_core']:ResolvePlayerIdentity(source)
    end)
    if not ok or type(identity) ~= 'table' then return nil, 'identity_unavailable' end
    if identity.ok ~= true then return nil, identity.error or 'identity_unavailable' end
    local characterId = tonumber(identity.characterId)
    if not characterId or characterId < 1 then return nil, 'identity_unavailable' end
    return {
        characterId = characterId,
        citizenid = tostring(identity.citizenid or ''),
        accountId = tonumber(identity.accountId)
    }
end

local function playerOrgCodes(source)
    local ok, orgs = pcall(function()
        return exports['mz_org']:GetPlayerOrgs(source)
    end)
    if not ok or type(orgs) ~= 'table' then return {} end
    local codes = {}
    for _, org in ipairs(orgs) do
        if type(org) == 'table' then
            local code = org.code or org.orgCode
            if type(code) == 'string' and code ~= '' then codes[code] = true end
        end
    end
    return codes
end

local function canStaff(source, permission)
    if type(permission) ~= 'string' or permission == '' then return false end
    local ok, allowed = pcall(function()
        return exports['mz_core']:HasGlobalPermission(source, permission)
    end)
    return ok and allowed == true
end

local function sessionIdFor(source)
    local ok, session = pcall(function()
        return exports['mz_core']:GetPlayerSession(source)
    end)
    if not ok or type(session) ~= 'table' then return nil end
    return tonumber(session.sessionId or session.id)
end

function Service.GetContext(source)
    source = tonumber(source)
    if not source or source <= 0 then return nil, 'player_not_found' end
    if GetPlayerName(source) == nil then return nil, 'player_not_found' end

    local identity, identityErr = coreIdentity(source)
    if not identity then return nil, identityErr end

    return {
        source = source,
        characterId = identity.characterId,
        citizenid = identity.citizenid,
        accountId = identity.accountId,
        sessionId = sessionIdFor(source),
        orgCodes = playerOrgCodes(source),
        canStaff = function(permission) return canStaff(source, permission) end
    }
end

function Service.MapConfig()
    local tiles = Config.Map.tiles
    local atlasAvailable = false
    if tiles.enabled == true then
        local ok, contents = pcall(function()
            return LoadResourceFile(GetCurrentResourceName(), 'web/tiles/atlas.json')
        end)
        atlasAvailable = ok and type(contents) == 'string' and #contents > 0
    end

    return {
        bounds = {
            minX = Config.Map.minX, maxX = Config.Map.maxX,
            minY = Config.Map.minY, maxY = Config.Map.maxY
        },
        minZoom = Config.Map.minZoom,
        maxZoom = Config.Map.maxZoom,
        defaultZoom = Config.Map.defaultZoom,
        locale = Config.Locale or 'pt-BR',
        routes = {
            enabled = Config.Routes and Config.Routes.Enabled == true,
            catalogEnabled = Config.Routes and Config.Routes.CatalogEnabled == true,
            available = MZNavigation.RouteRepository
                and MZNavigation.RouteRepository.Available == true or false,
            quotaAvailable = MZNavigation.RouteRepository
                and MZNavigation.RouteRepository.QuotaAvailable == true or false,
            minPoints = Config.Routes and Config.Routes.MinPoints or 2,
            maxPoints = Config.Routes and Config.Routes.MaxPoints or 64,
            maxTitle = Config.Routes and Config.Routes.MaxTitle or 80,
            maxDescription = Config.Routes and Config.Routes.MaxDescription or 300,
            maxTotalDistance = Config.Routes and Config.Routes.MaxTotalDistance or 20000.0
        },
        tiles = {
            enabled = tiles.enabled == true and atlasAvailable,
            available = atlasAvailable,
            path = tiles.path,
            tileSize = tiles.tileSize,
            maxZoom = tiles.maxZoom,
            projection = tiles.projection,
            license = tiles.license
        },
        blips = {
            -- Somente capacidade do canal local; nenhum dado de blip sai do cliente.
            enabled = Config.Blips and Config.Blips.Enabled == true,
            pollMs = Config.Blips and Config.Blips.PollMs or 2000,
            maxMarkers = Config.Blips and Config.Blips.MaxMarkers or 400
        },
        schematic = not (tiles.enabled == true and atlasAvailable)
    }
end

local function sanitizeFavoriteRow(row)
    if type(row) ~= 'table' then return nil end
    return {
        id = tonumber(row.id),
        label = tostring(row.label or ''),
        x = tonumber(row.x),
        y = tonumber(row.y),
        z = row.z ~= nil and tonumber(row.z) or nil,
        poiId = row.poi_id,
        createdAt = row.created_at,
        updatedAt = row.updated_at
    }
end

local function sanitizeRecentRow(row)
    if type(row) ~= 'table' then return nil end
    return {
        id = tonumber(row.id),
        label = tostring(row.label or ''),
        x = tonumber(row.x),
        y = tonumber(row.y),
        z = row.z ~= nil and tonumber(row.z) or nil,
        poiId = row.poi_id,
        visitedAt = row.visited_at
    }
end

local function mapRows(rows, mapper)
    local out = {}
    for _, row in ipairs(type(rows) == 'table' and rows or {}) do
        local value = mapper(row)
        if value then out[#out + 1] = value end
    end
    return out
end

function Service.ListFavorites(ctx)
    if Repository.Available ~= true then return {}, 'database_unavailable' end
    local ok, rows = pcall(Repository.ListFavorites, ctx.characterId, Config.Limits.maxFavoritesPerCharacter)
    if not ok then return {}, 'database_error' end
    return mapRows(rows, sanitizeFavoriteRow)
end

function Service.ListRecents(ctx)
    if Repository.Available ~= true then return {} end
    local ok, rows = pcall(Repository.ListRecents, ctx.characterId, Config.Limits.maxRecentsPerCharacter)
    if not ok then return {} end
    return mapRows(rows, sanitizeRecentRow)
end

function Service.AddFavorite(ctx, payload)
    if Repository.Available ~= true then return nil, 'database_unavailable' end

    local favorite, err = Schema.NormalizeFavorite(payload, Config.Limits)
    if not favorite then return nil, err end

    local ok, existing = pcall(Repository.FindFavoriteByLabel, ctx.characterId, favorite.label)
    if not ok then return nil, 'database_error' end
    if not existing then
        local countOk, total = pcall(Repository.CountFavorites, ctx.characterId)
        if not countOk then return nil, 'database_error' end
        if (tonumber(total) or 0) >= Config.Limits.maxFavoritesPerCharacter then
            return nil, 'favorite_limit_reached'
        end
    end

    local insertOk, row = pcall(Repository.UpsertFavorite, ctx.characterId, ctx.citizenid, favorite)
    if not insertOk or not row then return nil, 'database_error' end

    Repository.Audit(ctx.characterId, ctx.citizenid, 'favorite.upsert', favorite.poiId or favorite.label, favorite.label)
    return sanitizeFavoriteRow(row)
end

function Service.RemoveFavorite(ctx, payload)
    if Repository.Available ~= true then return false, 'database_unavailable' end
    local favoriteId = tonumber(payload and payload.id)
    if not favoriteId or favoriteId < 1 or favoriteId % 1 ~= 0 then
        return false, 'favorite_id_invalid'
    end

    local ok, removed = pcall(Repository.RemoveFavorite, ctx.characterId, favoriteId)
    if not ok then return false, 'database_error' end
    if not removed then return false, 'favorite_not_found' end

    Repository.Audit(ctx.characterId, ctx.citizenid, 'favorite.remove', tostring(favoriteId), nil)
    return true
end

function Service.AddRecent(ctx, payload)
    if Repository.Available ~= true then return false, 'database_unavailable' end

    local recent, err = Schema.NormalizeRecent(payload, Config.Limits)
    if not recent then return false, err end

    local ok, applied = pcall(
        Repository.AddRecent,
        ctx.characterId,
        ctx.citizenid,
        recent,
        Config.Limits.maxRecentsPerCharacter
    )
    if not ok or applied == false then return false, 'database_error' end
    return true
end

function Service.RecordSelection(ctx, selection)
    if not ctx or not selection then return end
    local cacheEntry = {
        characterId = ctx.characterId,
        citizenid = ctx.citizenid,
        selection = selection,
        selectedAt = nowSeconds()
    }
    SelectionCache[ctx.characterId] = cacheEntry
    SelectionOrder[#SelectionOrder + 1] = ctx.characterId
    while #SelectionOrder > (Config.Sessions.cacheSize or 256) do
        local oldest = table.remove(SelectionOrder, 1)
        if oldest and SelectionCache[oldest] == cacheEntry then
            SelectionCache[oldest] = nil
        end
    end
end

function Service.GetLastSelection(characterId)
    local entry = SelectionCache[tonumber(characterId) or -1]
    return entry and entry.selection or nil
end

function Service.BuildBootstrap(ctx)
    local layers, pois = Registry.Collect(ctx)
    local favorites = Service.ListFavorites(ctx)
    local recents = Service.ListRecents(ctx)
    local orgCodes = {}
    for code in pairs(ctx.orgCodes or {}) do orgCodes[#orgCodes + 1] = code end
    table.sort(orgCodes)

    return {
        map = Service.MapConfig(),
        layers = layers,
        pois = pois,
        favorites = favorites,
        recents = recents,
        editor = {
            orgCodes = orgCodes
        },
        limits = {
            maxFavorites = Config.Limits.maxFavoritesPerCharacter,
            maxRecents = Config.Limits.maxRecentsPerCharacter
        }
    }
end

local function sanitizePickerOptions(options)
    options = type(options) == 'table' and options or {}
    local title = Schema.SanitizeText(options.title, 60)
    if title == '' then title = 'Escolha um destino' end

    local initial = nil
    if options.initialX ~= nil or options.initialY ~= nil then
        local coords = MZNavigation.Geo.NormalizeCoords(
            { x = options.initialX, y = options.initialY },
            { maxWorld = Config.Waypoint.maxWorld }
        )
        if coords then initial = coords end
    end

    local layerFilter = nil
    if type(options.layers) == 'table' and #options.layers > 0 and #options.layers <= 32 then
        layerFilter = {}
        for _, layerId in ipairs(options.layers) do
            if Schema.IsValidId(layerId, Config.Limits.idMaxLength) then
                layerFilter[#layerFilter + 1] = layerId
            end
        end
        if #layerFilter == 0 then layerFilter = nil end
    end

    local zoom = math.floor(tonumber(options.zoom) or Config.Map.defaultZoom)
    zoom = math.max(Config.Picker.minimumZoom, math.min(Config.Picker.maximumZoom, zoom))

    return {
        title = title,
        allowFreePin = options.allowFreePin ~= false,
        requirePoi = options.requirePoi == true,
        initial = initial,
        layers = layerFilter,
        zoom = zoom,
        returnTo = Schema.SanitizeText(options.returnTo, 48)
    }
end

local function finishPicker(requestId, selection, reason)
    local pending = Service.PendingPickers[requestId]
    if not pending then return end
    Service.PendingPickers[requestId] = nil
    PickerCounts[pending.source] = math.max(0, (PickerCounts[pending.source] or 1) - 1)
    if type(pending.callback) == 'function' then
        local ok, err = pcall(pending.callback, selection, reason)
        if not ok then
            print(('[mz_navigation] picker callback error: %s'):format(tostring(err)))
        end
    end
end

function Service.OpenPicker(source, options, callback)
    if Service.Ready ~= true then return false, 'service_not_ready' end

    local ctx, ctxErr = Service.GetContext(source)
    if not ctx then return false, ctxErr end

    source = ctx.source
    local openCount = PickerCounts[source] or 0
    if openCount >= Config.Picker.maxOpenPerSource then
        return false, 'picker_busy'
    end

    pickerCounter = pickerCounter + 1
    local requestId = ('srv_%d_%d'):format(source, pickerCounter)
    local sanitized = sanitizePickerOptions(options)
    sanitized.requestId = requestId
    sanitized.characterId = ctx.characterId

    PickerCounts[source] = openCount + 1
    Service.PendingPickers[requestId] = {
        source = source,
        characterId = ctx.characterId,
        citizenid = ctx.citizenid,
        callback = callback,
        expiresAt = nowSeconds() + math.ceil(Config.Picker.timeoutMs / 1000)
    }

    TriggerClientEvent('mz_navigation:client:openPicker', source, requestId, sanitized)

    SetTimeout(Config.Picker.timeoutMs, function()
        local pending = Service.PendingPickers[requestId]
        if not pending then return end
        finishPicker(requestId, nil, 'timeout')
    end)

    return true, requestId
end

function Service.HandlePickerResult(source, requestId, payload)
    source = tonumber(source)
    requestId = type(requestId) == 'string' and requestId or ''
    local pending = Service.PendingPickers[requestId]
    if not pending then return false, 'picker_not_found' end
    if pending.source ~= source then return false, 'picker_not_owned' end

    local selection, err = Schema.NormalizeSelection(payload, {
        maxWorld = Config.Waypoint.maxWorld,
        minZ = Config.Waypoint.minZ,
        maxZ = Config.Waypoint.maxZ
    })
    if not selection then
        finishPicker(requestId, nil, err or 'selection_invalid')
        return false, err
    end

    local ctx = {
        characterId = pending.characterId,
        citizenid = pending.citizenid
    }
    Service.RecordSelection(ctx, selection)
    Service.AddRecent(ctx, {
        label = selection.label ~= '' and selection.label or 'Destino',
        x = selection.x,
        y = selection.y,
        z = selection.z,
        poiId = selection.poiId
    })

    finishPicker(requestId, selection, 'confirmed')
    return true
end

function Service.CancelPicker(source, requestId, reason)
    source = tonumber(source)
    requestId = type(requestId) == 'string' and requestId or ''
    local pending = Service.PendingPickers[requestId]
    if not pending then return false, 'picker_not_found' end
    if pending.source ~= source then return false, 'picker_not_owned' end
    finishPicker(requestId, nil, reason or 'cancelled')
    return true
end

function Service.CancelPickersForSource(source)
    source = tonumber(source)
    for requestId, pending in pairs(Service.PendingPickers) do
        if pending.source == source then
            finishPicker(requestId, nil, 'player_dropped')
        end
    end
    PickerCounts[source] = nil
    clearRate(source)
end

local function response(source, action, ok, errorCode, data, requestId, origin)
    TriggerClientEvent('mz_navigation:client:response', source, {
        action = action,
        ok = ok == true,
        error = errorCode,
        data = data,
        requestId = requestId,
        origin = origin
    })
end

function Service.HandleRequest(source, action, payload, requestId, origin)
    action = type(action) == 'string' and action:sub(1, 48) or ''
    payload = type(payload) == 'table' and payload or {}
    requestId = type(requestId) == 'string' and requestId:gsub('[^%w_%-:]', ''):sub(1, 80) or nil
    if requestId == '' then requestId = nil end
    origin = origin == 'phone' and 'phone' or 'nav'

    local function respond(ok, errorCode, data)
        if ok ~= true and errorCode == 'unknown_action' then
            print(('[mz_navigation][security] unknown_action source=%s action=%s')
                :format(tostring(source), tostring(action)))
        end
        response(source, action, ok, errorCode, data, requestId, origin)
    end

    if Service.Ready ~= true then return respond(false, 'service_not_ready') end
    if not RATE_ACTIONS[action] then return respond(false, 'unknown_action') end
    if not rateAllowed(source, action) then return respond(false, 'rate_limited') end

    local ctx, ctxErr = Service.GetContext(source)
    if not ctx then return respond(false, ctxErr) end

    if action == 'bootstrap' then
        return respond(true, nil, Service.BuildBootstrap(ctx))
    end

    if action == 'listPOIs' then
        local layers, pois = Registry.Collect(ctx)
        return respond(true, nil, { layers = layers, pois = pois })
    end

    if action == 'favorites.list' then
        local favorites, err = Service.ListFavorites(ctx)
        return respond(true, err, { favorites = favorites })
    end

    if action == 'favorites.add' then
        local favorite, err = Service.AddFavorite(ctx, payload)
        return respond(favorite ~= nil, err, { favorite = favorite })
    end

    if action == 'favorites.remove' then
        local ok, err = Service.RemoveFavorite(ctx, payload)
        return respond(ok, err)
    end

    if action == 'recents.list' then
        return respond(true, nil, { recents = Service.ListRecents(ctx) })
    end

    if action == 'recents.add' then
        local ok, err = Service.AddRecent(ctx, payload)
        return respond(ok, err)
    end

    if action == 'routes.list' then
        local data, err = RouteService.List(ctx, payload)
        return respond(data ~= nil, err, data)
    end

    if action == 'routes.get' then
        local data, err = RouteService.Get(ctx, payload.publicId)
        return respond(data ~= nil, err, { route = data })
    end

    if action == 'routes.create' then
        local data, err = RouteService.Create(ctx, payload)
        return respond(data ~= nil, err, { route = data })
    end

    if action == 'routes.update' then
        local data, err = RouteService.Update(ctx, payload.publicId, payload)
        return respond(data ~= nil, err, { route = data })
    end

    if action == 'routes.delete' then
        local ok, err = RouteService.Delete(ctx, payload.publicId, payload)
        return respond(ok == true, err)
    end

    if action == 'routes.publish' then
        local data, err = RouteService.SetPublished(ctx, payload.publicId, payload, true)
        return respond(data ~= nil, err, { route = data })
    end

    if action == 'routes.unpublish' then
        local data, err = RouteService.SetPublished(ctx, payload.publicId, payload, false)
        return respond(data ~= nil, err, { route = data })
    end

    if action == 'routes.catalog' then
        local data, err = RouteService.CatalogList(ctx, payload)
        return respond(data ~= nil, err, data)
    end

    if action == 'routes.catalog.get' then
        local data, err = RouteService.CatalogGet(ctx, payload.publicId)
        return respond(data ~= nil, err, { route = data })
    end

    return respond(false, 'unknown_action')
end
