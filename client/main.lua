--[[
    mz_navigation - client controller (NUI focus, comandos, exports, bridge).

    Este arquivo NAO define preco, corrida, pagamento ou propriedade.
    Ele apenas abre a interface, valida coordenadas e delega ao servidor.
]]

MZNavigation = MZNavigation or {}
MZNavigationClient = MZNavigationClient or {}

local GPS = MZNavigationClient.GPS
local Picker = MZNavigationClient.Picker
local Blips = MZNavigationClient.Blips
local Geo = MZNavigation.Geo

local RESOURCE = GetCurrentResourceName()

MZNavigationClient.UI = MZNavigationClient.UI or {}
local UI = MZNavigationClient.UI

UI.opened = false
UI.mode = 'browse'
UI.requestId = nil
UI.options = {}

local function notify(message, notifyType)
    local ok = pcall(function()
        exports['mz_notify']:Notify({
            type = notifyType or 'info',
            title = 'Navegacao',
            message = message,
            duration = 3500
        })
    end)
    if not ok then
        print(('[mz_navigation] %s'):format(tostring(message)))
    end
end

function UI.IsOpen()
    return UI.opened == true
end

local function applyFocus(enabled)
    SetNuiFocus(enabled == true, enabled == true)
end

function UI.Open(mode, requestId, options)
    UI.opened = true
    UI.mode = (mode == 'picker' or mode == 'editor' or mode == 'catalog') and mode or 'browse'
    UI.requestId = requestId
    UI.options = type(options) == 'table' and options or {}

    SendNUIMessage({
        action = 'navigation:open',
        mode = UI.mode,
        requestId = requestId,
        options = UI.options
    })
    applyFocus(true)
    -- Leitor de blips locais: somente enquanto a NUI esta aberta.
    if Blips then Blips.SetActive(true) end
end

function UI.OpenBrowse(options)
    if Picker.HasPending() then return false, 'picker_active' end
    UI.Open('browse', nil, options)
    return true
end

function UI.OpenPicker(requestId, options)
    UI.Open('picker', requestId, options)
end

function UI.OpenEditor(options)
    if Config.Routes == nil or Config.Routes.Enabled ~= true then
        return false, 'routes_disabled'
    end
    if Picker.HasPending() then return false, 'picker_active' end
    UI.Open('editor', nil, options)
    return true
end

function UI.OpenCatalog(options)
    if Config.Routes == nil or Config.Routes.Enabled ~= true then
        return false, 'routes_disabled'
    end
    if Config.Routes.CatalogEnabled ~= true then
        return false, 'catalog_disabled'
    end
    if Picker.HasPending() then return false, 'picker_active' end
    UI.Open('catalog', nil, options)
    return true
end

function UI.Close(reason)
    if not UI.opened then
        return
    end
    UI.opened = false
    UI.mode = 'browse'
    UI.requestId = nil
    UI.options = {}

    SendNUIMessage({ action = 'navigation:close', reason = reason or 'closed' })
    applyFocus(false)
    if Blips then Blips.SetActive(false) end
end

local function responseToNui(payload)
    SendNUIMessage({ action = 'navigation:response', data = payload })
end

local function localResponse(action, requestId, ok, errorCode, data)
    return {
        action = action,
        requestId = requestId,
        ok = ok == true,
        error = errorCode,
        data = data,
        origin = 'nav'
    }
end

local function handleClientAction(action, payload, requestId)
    if action == 'waypoint.set' then
        local ok, err = GPS.Set(payload)
        if ok then notify('Waypoint definido no mapa.', 'success') end
        return localResponse(action, requestId, ok, err)
    end

    if action == 'waypoint.clear' then
        local ok = GPS.Clear()
        return localResponse(action, requestId, ok, ok and nil or 'waypoint_unavailable')
    end

    if action == 'waypoint.current' then
        local current, err = GPS.GetCurrent()
        return localResponse(action, requestId, current ~= nil, err, current)
    end

    if action == 'position.current' then
        local ped = PlayerPedId()
        if not ped or ped == 0 or not DoesEntityExist(ped) then
            return localResponse(action, requestId, false, 'ped_not_found')
        end
        local coords = GetEntityCoords(ped)
        local selection = GPS.BuildSelection({ x = coords.x, y = coords.y, z = coords.z })
        return localResponse(action, requestId, selection ~= nil, selection and nil or 'coords_invalid', selection)
    end

    if action == 'coords.resolve' then
        local selection, err = GPS.BuildSelection({ x = payload.x, y = payload.y })
        return localResponse(action, requestId, selection ~= nil, err, selection)
    end

    return nil
end

--[[
    Bridge usado pelo mz_phone (chamado localmente, nao e net event).
    Actions de servidor sao repassadas com origin='phone'; a resposta volta por
    mz_phone:client:navigationPayload.
]]
AddEventHandler('mz_navigation:client:phoneRequest', function(action, payload, requestId)
    action = type(action) == 'string' and action:sub(1, 48) or ''
    payload = type(payload) == 'table' and payload or {}
    requestId = type(requestId) == 'string' and requestId or ''

    local localPayload = handleClientAction(action, payload, requestId)
    if localPayload then
        localPayload.origin = 'phone'
        TriggerEvent('mz_phone:client:navigationPayload', localPayload)
        return
    end

    TriggerServerEvent('mz_navigation:server:request', action, payload, requestId, 'phone')
end)

RegisterNetEvent('mz_navigation:client:response', function(payload)
    payload = type(payload) == 'table' and payload or {}
    if payload.origin == 'phone' then
        TriggerEvent('mz_phone:client:navigationPayload', payload)
        return
    end
    responseToNui(payload)
end)

RegisterNetEvent('mz_navigation:client:openPicker', function(requestId, options)
    Picker.OpenServer(requestId, options)
end)

RegisterNetEvent('mz_navigation:client:setWaypoint', function(coords)
    local ok = GPS.Set(coords)
    if not ok then notify('Coordenada invalida para waypoint.', 'error') end
end)

RegisterNUICallback('navigationRequest', function(data, cb)
    data = type(data) == 'table' and data or {}
    local action = tostring(data.action or '')
    local payload = type(data.payload) == 'table' and data.payload or {}
    local requestId = tostring(data.requestId or '')

    local localPayload = handleClientAction(action, payload, requestId)
    if localPayload then
        responseToNui(localPayload)
        cb({ ok = true })
        return
    end

    TriggerServerEvent('mz_navigation:server:request', action, payload, requestId, 'nav')
    cb({ ok = true, pending = true })
end)

RegisterNUICallback('navigationConfirm', function(data, cb)
    data = type(data) == 'table' and data or {}
    local requestId = tostring(data.requestId or UI.requestId or '')
    local selection = type(data.selection) == 'table' and data.selection or {}
    local ok, err = Picker.Resolve(requestId, selection)
    if not ok then
        responseToNui(localResponse('picker.confirm', requestId, false, err or 'selection_invalid'))
    end
    cb({ ok = ok == true, error = err })
end)

RegisterNUICallback('navigationCancel', function(data, cb)
    data = type(data) == 'table' and data or {}
    local requestId = tostring(data.requestId or UI.requestId or '')
    Picker.Cancel(requestId, 'cancelled')
    if not Picker.HasPending() then UI.Close('cancelled') end
    cb({ ok = true })
end)

RegisterNUICallback('navigationClose', function(_, cb)
    if Picker.HasPending() then
        Picker.Cancel(Picker.Current, 'closed')
    end
    UI.Close('closed')
    cb({ ok = true })
end)

RegisterNetEvent('mz_core:client:characterSelectionRequired', function()
    Picker.CancelAll('identity_changed')
    if UI.opened then
        UI.Close('identity_changed')
    end
    -- Marcadores explicitos podem ser por personagem; nao reutilizar na troca.
    if Blips then Blips.ClearExternal() end
end)

RegisterNetEvent('mz_core:client:playerLoaded', function()
    Picker.CancelAll('identity_changed')
    if UI.opened then
        UI.Close('identity_changed')
    end
    if Blips then Blips.ClearExternal() end
end)

RegisterCommand('mapa', function()
    if UI.IsOpen() then
        UI.Close('command')
        return
    end
    local ok, err = UI.OpenBrowse()
    if not ok then notify('Feche o seletor de destino atual antes de abrir o mapa.', 'error') end
    if err and err ~= 'picker_active' then notify('Mapa indisponivel.', 'error') end
end, false)

RegisterCommand('navigation', function()
    ExecuteCommand('mapa')
end, false)

RegisterCommand('rotas', function()
    if UI.IsOpen() then
        UI.Close('command')
        return
    end
    local ok, err = UI.OpenEditor()
    if not ok then
        if err == 'routes_disabled' then
            notify('Editor de rotas desabilitado no servidor.', 'error')
        elseif err == 'picker_active' then
            notify('Feche o seletor de destino antes de abrir o editor.', 'error')
        end
    end
end, false)

RegisterCommand('maparotas', function()
    if UI.IsOpen() then
        UI.Close('command')
        return
    end
    local ok, err = UI.OpenCatalog()
    if not ok then
        if err == 'catalog_disabled' then
            notify('Catalogo de rotas desabilitado no servidor.', 'error')
        elseif err == 'routes_disabled' then
            notify('Rotas desabilitadas no servidor.', 'error')
        elseif err == 'picker_active' then
            notify('Feche o seletor de destino antes de abrir o catalogo.', 'error')
        end
    end
end, false)

exports('OpenMap', function(options)
    return UI.OpenBrowse(options)
end)

exports('OpenRouteEditor', function(options)
    return UI.OpenEditor(options)
end)

exports('OpenRouteCatalog', function(options)
    return UI.OpenCatalog(options)
end)

exports('OpenDestinationPicker', function(options, callback)
    return Picker.Open(options, callback)
end)

exports('SetWaypoint', function(coords)
    return GPS.Set(coords)
end)

exports('ClearWaypoint', function()
    return GPS.Clear()
end)

exports('GetWaypoint', function()
    return GPS.GetCurrent()
end)

exports('IsOpen', function()
    return UI.IsOpen()
end)

exports('Close', function()
    UI.Close('export')
end)

--[[
    API local minima para consumidores futuros (nao edita produtores agora).
    Nao e autorizacao e nao vai ao servidor: apenas exibicao no mapa local.
    Retorna marker | nil, err.
]]
exports('UpsertMarker', function(def)
    if not Blips then return nil, 'blips_unavailable' end
    return Blips.UpsertExternal(def)
end)

exports('RemoveMarker', function(owner, id)
    if not Blips then return false, 'blips_unavailable' end
    return Blips.RemoveExternal(owner, id)
end)

exports('GetBlipSyncDiagnostics', function()
    if not Blips then return { enabled = false, available = false } end
    local diagnostics = Blips.Diagnostics()
    diagnostics.available = true
    return diagnostics
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    Picker.CancelAll('resource_stop')
    if Blips then Blips.Stop() end
    UI.opened = false
    applyFocus(false)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    if Blips then Blips.Stop() end
    SetNuiFocus(false, false)
end)
