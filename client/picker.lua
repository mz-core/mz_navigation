--[[
    mz_navigation - ciclo de vida do destination picker.

    O retorno e sempre assincrono (callback). Nunca devolvemos coordenadas de
    forma sincrona, porque a selecao depende de interacao NUI.

    Estados cobertos: confirmado, cancelado, timeout, substituido, jogador saiu,
    resource parado.
]]

MZNavigationClient = MZNavigationClient or {}
MZNavigationClient.Picker = MZNavigationClient.Picker or {}

local Picker = MZNavigationClient.Picker

Picker.Pending = {}
Picker.Current = nil
local counter = 0

local function ui()
    return MZNavigationClient.UI
end

local function buildRequestId(prefix)
    counter = counter + 1
    return ('%s_%d_%d'):format(prefix or 'c', math.floor(GetGameTimer()), counter)
end

local function finish(requestId, selection, reason)
    local pending = Picker.Pending[requestId]
    if not pending then return false end
    Picker.Pending[requestId] = nil
    if Picker.Current == requestId then Picker.Current = nil end

    if pending.serverInitiated then
        if selection then
            TriggerServerEvent('mz_navigation:server:pickerResult', requestId, selection)
        else
            TriggerServerEvent('mz_navigation:server:pickerCancel', requestId, reason or 'cancelled')
        end
    end

    if type(pending.callback) == 'function' then
        local ok, err = pcall(pending.callback, selection, reason)
        if not ok then
            print(('[mz_navigation] picker callback error: %s'):format(tostring(err)))
        end
    end
    return true
end

local function cancelCurrent(reason)
    if not Picker.Current then return false end
    local requestId = Picker.Current
    local closed = finish(requestId, nil, reason or 'cancelled')
    local uiModule = ui()
    if closed and uiModule then uiModule.Close(reason or 'cancelled') end
    return closed
end

function Picker.HasPending()
    return Picker.Current ~= nil
end

function Picker.GetCurrent()
    return Picker.Current and Picker.Pending[Picker.Current] or nil
end

--[[
    options = {
      title, allowFreePin, requirePoi, initialX, initialY, layers, zoom, returnTo
    }
    callback(selection | nil, reason)
]]
function Picker.Open(options, callback, origin)
    if Picker.Current then cancelCurrent('replaced') end

    local uiModule = ui()
    if not uiModule then return false, 'ui_unavailable' end

    local requestId = buildRequestId('cli')
    Picker.Pending[requestId] = {
        callback = callback,
        origin = origin or 'nav',
        createdAt = GetGameTimer()
    }
    Picker.Current = requestId

    SetTimeout(Config.Picker.timeoutMs, function()
        if not Picker.Pending[requestId] then return end
        local closed = finish(requestId, nil, 'timeout')
        if closed then uiModule.Close('timeout') end
    end)

    uiModule.OpenPicker(requestId, options or {})
    return true, requestId
end

function Picker.OpenServer(requestId, options)
    if type(requestId) ~= 'string' or requestId == '' then return false end
    local uiModule = ui()
    if not uiModule then return false end

    if Picker.Current then cancelCurrent('replaced') end

    options = type(options) == 'table' and options or {}
    if options.initial and type(options.initial) == 'table' then
        options.initialX = options.initial.x
        options.initialY = options.initial.y
    end

    Picker.Pending[requestId] = {
        callback = nil,
        origin = 'server',
        serverInitiated = true,
        createdAt = GetGameTimer()
    }
    Picker.Current = requestId

    SetTimeout(Config.Picker.timeoutMs + 1000, function()
        if not Picker.Pending[requestId] then return end
        finish(requestId, nil, 'timeout')
    end)

    uiModule.OpenPicker(requestId, options)
    return true
end

function Picker.Resolve(requestId, payload)
    local pending = Picker.Pending[requestId]
    if not pending then return false, 'picker_not_found' end

    local selection, err = MZNavigationClient.GPS.BuildSelection(payload, {
        poiId = payload and payload.poiId,
        label = payload and payload.label
    })
    if not selection then return false, err end

    local entered = MZNavigationClient.GPS.Set({ x = selection.x, y = selection.y })
    selection.waypointSet = entered == true

    local uiModule = ui()
    if uiModule then uiModule.Close('confirmed') end
    finish(requestId, selection, 'confirmed')
    return true
end

function Picker.Cancel(requestId, reason)
    requestId = requestId or Picker.Current
    if not requestId then return false end
    local closed = finish(requestId, nil, reason or 'cancelled')
    local uiModule = ui()
    if closed and uiModule and Picker.Current == nil then uiModule.Close(reason or 'cancelled') end
    return closed
end

function Picker.CancelAll(reason)
    for requestId in pairs(Picker.Pending) do
        finish(requestId, nil, reason or 'cancelled')
    end
    Picker.Pending = {}
    Picker.Current = nil
end
