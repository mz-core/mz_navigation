--[[
    mz_navigation - bootstrap, eventos e exports publicos.

    Exports server-side (chamaveis por outros resources):
      RegisterLayer(def)                         -> layer | nil, err
      UnregisterLayer(id)                        -> ok, err
      UpsertPOI(def)                             -> poi | nil, err
      RemovePOI(id)                              -> ok, err
      ListVisiblePOIs(source)                    -> { layers, pois }
      GetMapConfig()                             -> map config (sem dados privados)
      OpenDestinationPicker(source, opts, cb)    -> ok, err
      SetWaypoint(source, coords)                -> ok, err
      GetLastSelection(characterId)              -> selection | nil

    Eventos server:
      mz_navigation:server:request(action, payload, requestId, origin)
      mz_navigation:server:pickerResult(requestId, payload)

    Eventos client:
      mz_navigation:client:openPicker(requestId, options)
      mz_navigation:client:response(payload)
      mz_navigation:client:setWaypoint(coords)
      mz_navigation:client:phoneRequest(action, payload, requestId)  -- local, vindo do mz_phone
]]

local Registry = MZNavigation.Registry
local Service = MZNavigation.Service
local Repository = MZNavigation.Repository
local RouteRepository = MZNavigation.RouteRepository
local RouteService = MZNavigation.RouteService

local RESOURCE = GetCurrentResourceName()
local SECURITY_ERRORS = {
    rate_limited = true,
    unknown_action = true,
    picker_not_owned = true,
    picker_not_found = true,
    identity_unavailable = true,
    poi_owned_by_other_resource = true,
    layer_owned_by_other_resource = true
}

local function logSecurity(source, action, reason)
    if not SECURITY_ERRORS[reason] then return end
    print(('[mz_navigation][security] source=%s action=%s reason=%s')
        :format(tostring(source), tostring(action), tostring(reason)))
end

local function registerSeeds()
    if Config.Seeds.enabled ~= true then return end

    for _, layer in ipairs(Config.Seeds.layers or {}) do
        local registered, err = Registry.RegisterLayer(layer, RESOURCE)
        if not registered then
            print(('[mz_navigation] seed layer skipped: %s (%s)'):format(tostring(layer and layer.id), tostring(err)))
        end
    end

    for _, poi in ipairs(Config.Seeds.pois or {}) do
        local registered, err = Registry.UpsertPoi(poi, RESOURCE)
        if not registered then
            print(('[mz_navigation] seed poi skipped: %s (%s)'):format(tostring(poi and poi.id), tostring(err)))
        end
    end
end

exports('RegisterLayer', function(def)
    local owner = GetInvokingResource()
    if not owner then return nil, 'caller_required' end
    return Registry.RegisterLayer(def, owner)
end)

exports('UnregisterLayer', function(id)
    local owner = GetInvokingResource()
    if not owner then return false, 'caller_required' end
    return Registry.UnregisterLayer(id, owner)
end)

exports('UpsertPOI', function(def)
    local owner = GetInvokingResource()
    if not owner then return nil, 'caller_required' end
    return Registry.UpsertPoi(def, owner)
end)

exports('RemovePOI', function(id)
    local owner = GetInvokingResource()
    if not owner then return false, 'caller_required' end
    return Registry.RemovePoi(id, owner)
end)

exports('ListVisiblePOIs', function(source)
    local ctx, err = Service.GetContext(source)
    if not ctx then return nil, err end
    local layers, pois = Registry.Collect(ctx)
    return { layers = layers, pois = pois }
end)

exports('GetMapConfig', function()
    return Service.MapConfig()
end)

exports('OpenDestinationPicker', function(source, options, callback)
    return Service.OpenPicker(source, options, callback)
end)

exports('SetWaypoint', function(source, coords)
    local ctx, err = Service.GetContext(source)
    if not ctx then return false, err end
    local normalized = MZNavigation.Geo.NormalizeCoords(coords, {
        maxWorld = Config.Waypoint.maxWorld,
        minZ = Config.Waypoint.minZ,
        maxZ = Config.Waypoint.maxZ
    })
    if not normalized then return false, 'invalid_coords' end
    TriggerClientEvent('mz_navigation:client:setWaypoint', ctx.source, normalized)
    return true
end)

exports('GetLastSelection', function(characterId)
    return Service.GetLastSelection(characterId)
end)

--[[
    Contrato somente-leitura do editor de rotas (Wave 4A).
    Consumidores server-side (ex.: futuro mz_racing) leem apenas rotas publicas.
]]
exports('ListPublishedRoutes', function(payload)
    return RouteService.ListPublished(payload)
end)

exports('GetPublishedRoute', function(publicId)
    return RouteService.GetPublished(publicId)
end)

exports('ListRoutesForSource', function(source, payload)
    local ctx, err = Service.GetContext(source)
    if not ctx then return nil, err end
    return RouteService.List(ctx, payload)
end)

exports('GetRouteForSource', function(source, publicId)
    local ctx, err = Service.GetContext(source)
    if not ctx then return nil, err end
    return RouteService.Get(ctx, publicId)
end)

RegisterNetEvent('mz_navigation:server:request', function(action, payload, requestId, origin)
    local src = source
    local ok, err = pcall(Service.HandleRequest, src, action, payload, requestId, origin)
    if not ok then
        print(('[mz_navigation] request handler error: %s'):format(tostring(err)))
        logSecurity(src, action, 'handler_error')
    end
end)

RegisterNetEvent('mz_navigation:server:pickerResult', function(requestId, payload)
    local src = source
    local ok, handled = pcall(function()
        return Service.HandlePickerResult(src, requestId, payload)
    end)
    if not ok then
        print(('[mz_navigation] picker result error: %s'):format(tostring(handled)))
        logSecurity(src, 'pickerResult', 'handler_error')
        return
    end
    if handled ~= true then
        logSecurity(src, 'pickerResult', 'picker_not_owned')
    end
end)

RegisterNetEvent('mz_navigation:server:pickerCancel', function(requestId, reason)
    local src = source
    local ok, handled = pcall(function()
        return Service.CancelPicker(src, requestId, reason)
    end)
    if not ok then
        print(('[mz_navigation] picker cancel error: %s'):format(tostring(handled)))
        return
    end
    if handled ~= true then logSecurity(src, 'pickerCancel', 'picker_not_owned') end
end)

AddEventHandler('playerDropped', function()
    local src = source
    Service.CancelPickersForSource(src)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    Service.Ready = false
    for requestId in pairs(Service.PendingPickers) do
        local pending = Service.PendingPickers[requestId]
        Service.PendingPickers[requestId] = nil
        if pending and type(pending.callback) == 'function' then
            pcall(pending.callback, nil, 'resource_stop')
        end
    end
end)

CreateThread(function()
    local databaseOk, databaseErr = Repository.Prepare()
    Repository.Available = databaseOk == true
    if not databaseOk then
        print(('[mz_navigation] favorites/recents disabled: %s'):format(tostring(databaseErr)))
    end

    local routesOk, routesErr = RouteRepository.Prepare()
    if not routesOk then
        print(('[mz_navigation] route editor persistence: %s'):format(tostring(routesErr)))
    end

    registerSeeds()
    Service.Ready = true
    print(('[mz_navigation] ready layers=%d pois=%d tiles=%s database=%s routes=%s quota=%s'):format(
        Registry.CountLayers(),
        Registry.CountPois(),
        Service.MapConfig().tiles.enabled and 'licensed' or 'schematic',
        Repository.Available and 'ready' or 'unavailable',
        routesOk and 'ready' or 'unavailable',
        RouteRepository.QuotaAvailable and 'ready' or 'unavailable'
    ))
end)
