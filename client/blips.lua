--[[
    mz_navigation - leitor local de blips nativos + snapshot/diff para a NUI.

    Escopo:
      - SOMENTE leitura de blips que o proprio cliente ja possui;
      - nenhum dado sai do cliente (nao ha evento de rede aqui);
      - nenhuma autorizacao e inferida a partir de sprite/cor/posicao.

    O enumerador de blips do GTA V e POR SPRITE:
      GetFirstBlipInfoId(sprite) / GetNextBlipInfoId(sprite)
    Nao existe "GetAllBlips". Por isso a lista e curta, versionada em
    Config.Blips.Sprites, e nao varremos 1..1000.

    O polling so existe enquanto a NUI esta aberta (SetActive). Ao fechar,
    o timer para e o estado e limpo. Feature flag: Config.Blips.Enabled.
]]

MZNavigation = MZNavigation or {}
MZNavigationClient = MZNavigationClient or {}
MZNavigationClient.Blips = MZNavigationClient.Blips or {}

local Blips = MZNavigationClient.Blips
local Geo = MZNavigation.Geo

local DEFAULT_POLL_MS = 2000
local DEFAULT_MAX_PER_SPRITE = 64
local DEFAULT_MAX_MARKERS = 400
local DEFAULT_LABEL_MAX = 80

local State = {
    active = false,
    generation = 0,
    seq = 0,
    previous = {},
    tokens = {},
    nextToken = 0,
    lastNative = {},
    external = {},
    timerToken = 0,
    polls = 0,
    lastCount = 0,
    lastCostMs = 0,
    lastError = nil
}
Blips.State = State

local function finite(value)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function configValue(key, default)
    local cfg = Config and Config.Blips
    if type(cfg) ~= 'table' then return default end
    local value = cfg[key]
    if value == nil then return default end
    return value
end

local function blipsEnabled()
    return configValue('Enabled', false) == true
end

local function limit(name, default, min, max)
    local value = tonumber(configValue(name, default)) or default
    value = math.floor(value)
    if value < min then value = min end
    if value > max then value = max end
    return value
end

function Blips.IsEnabled()
    return blipsEnabled()
end

function Blips.IsActive()
    return State.active == true
end

function Blips.PollInterval()
    return limit('PollMs', DEFAULT_POLL_MS, 500, 60000)
end

function Blips.MaxPerSprite()
    return limit('MaxPerSprite', DEFAULT_MAX_PER_SPRITE, 1, 256)
end

function Blips.MaxMarkers()
    return limit('MaxMarkers', DEFAULT_MAX_MARKERS, 1, 1000)
end

local function labelMax()
    local limits = Config and Config.Limits
    local value = tonumber(limits and limits.labelMaxLength) or DEFAULT_LABEL_MAX
    if value < 8 then value = 8 end
    if value > 120 then value = 120 end
    return math.floor(value)
end

--[[
    Remove caracteres de controle e limita o tamanho. O consumidor NUI usa
    textContent; ainda assim nao aceitamos texto arbitrario/longo.
]]
function Blips.SanitizeText(value, maxLength)
    if type(value) ~= 'string' then return '' end
    local cleaned = value:gsub('%c', ''):gsub('^%s+', ''):gsub('%s+$', '')
    local cap = math.max(1, math.floor(tonumber(maxLength) or labelMax()))
    return cleaned:sub(1, cap)
end

local function validToken(value, allowedPattern, maxLength)
    if type(value) ~= 'string' then return nil end
    if #value < 1 or #value > maxLength then return nil end
    if value:match(allowedPattern) ~= value then return nil end
    return value
end

function Blips.ValidOwner(value)
    return validToken(value, '^[%w_%-%.]+$', 48) ~= nil
end

function Blips.ValidExternalId(value)
    return validToken(value, '^[%w_%-%._:]+$', 96) ~= nil
end

function Blips.ExternalKey(owner, id)
    return ('external:%s:%s'):format(tostring(owner), tostring(id))
end

local function catalogFor(sprite)
    local catalog = configValue('Catalog', {})
    if type(catalog) ~= 'table' then return nil end
    local entry = catalog[sprite]
    return type(entry) == 'table' and entry or nil
end

--[[
    Normaliza um marcador vindo de native/external. Nao aceita HTML, URL ou
    campos desconhecidos: retorna somente o DTO local.
]]
function Blips.NormalizeMarker(raw, id, limits)
    if type(raw) ~= 'table' then return nil, 'marker_invalid' end
    -- external:<owner 48>:<id 96> = 154; o limite cobre com folga.
    if type(id) ~= 'string' or id == '' or #id > 160 then return nil, 'id_invalid' end

    limits = type(limits) == 'table' and limits or {}
    local maxWorld = tonumber(limits.maxWorld) or 20000.0
    local minZ = tonumber(limits.minZ) or -2000.0
    local maxZ = tonumber(limits.maxZ) or 3000.0

    local x = tonumber(raw.x)
    local y = tonumber(raw.y)
    if not finite(x) or not finite(y) then return nil, 'coords_invalid' end
    if math.abs(x) > maxWorld or math.abs(y) > maxWorld then return nil, 'coords_out_of_range' end

    local sprite = math.floor(tonumber(raw.sprite) or -1)
    if sprite < 0 or sprite > 9999 then return nil, 'sprite_invalid' end

    local marker = {
        id = id,
        source = raw.source == 'external' and 'external' or 'native',
        sprite = sprite,
        colour = math.max(0, math.min(255, math.floor(tonumber(raw.colour) or 0))),
        alpha = math.max(0, math.min(255, math.floor(tonumber(raw.alpha) or 255))),
        x = x + 0.0,
        y = y + 0.0,
        label = Blips.SanitizeText(raw.label, limits.labelMax or labelMax()),
        category = validToken(raw.category, '^[%w_%-]+$', 24) or 'generic',
        glyph = validToken(raw.glyph, '^[%w]$', 1) or '',
        visibility = 'local'
    }

    local z = tonumber(raw.z)
    if z ~= nil and finite(z) and z >= minZ and z <= maxZ then
        marker.z = z + 0.0
    end

    return marker
end

--[[
    Diferenca incremental por id. `previous` e um mapa id -> fingerprint.
    Retorna upserts, removes, current (mapa novo).
]]
function Blips.Fingerprint(marker)
    if type(marker) ~= 'table' then return '' end
    local function num(value)
        if not finite(value) then return '' end
        return string.format('%.2f', value)
    end
    return table.concat({
        marker.id or '',
        num(marker.x),
        num(marker.y),
        num(marker.z),
        tostring(marker.sprite or ''),
        tostring(marker.colour or ''),
        tostring(marker.alpha or ''),
        marker.label or '',
        marker.category or '',
        marker.glyph or ''
    }, '\30')
end

function Blips.Diff(previous, snapshot)
    previous = type(previous) == 'table' and previous or {}
    local current, upserts, order = {}, {}, {}

    for _, marker in ipairs(type(snapshot) == 'table' and snapshot or {}) do
        if type(marker) == 'table' and type(marker.id) == 'string' then
            local fingerprint = Blips.Fingerprint(marker)
            if current[marker.id] == nil then order[#order + 1] = marker.id end
            current[marker.id] = fingerprint
            if previous[marker.id] ~= fingerprint then
                upserts[#upserts + 1] = marker
            end
        end
    end

    local removes = {}
    for id in pairs(previous) do
        if current[id] == nil then removes[#removes + 1] = id end
    end

    return upserts, removes, current
end

local function nextTokenFor(state, handle)
    local token = state.tokens[handle]
    if token then return token end
    state.nextToken = state.nextToken + 1
    token = state.nextToken
    state.tokens[handle] = token
    return token
end

--[[
    Converte leituras cruas em snapshot normalizado. `state` e injetado para
    permitir teste puro. Handles nao viram IDs persistentes: cada handle vivo
    recebe um token monotonico da sessao. Handle reutilizado depois de sumir
    ganha um token novo, evitando herdar o marcador anterior.
]]
function Blips.BuildSnapshot(entries, state, limits)
    state = type(state) == 'table' and state or State
    state.tokens = type(state.tokens) == 'table' and state.tokens or {}
    state.nextToken = tonumber(state.nextToken) or 0

    local seen, snapshot = {}, {}
    local maxMarkers = limits and limits.maxMarkers or Blips.MaxMarkers()
    local visited = {}

    for _, entry in ipairs(type(entries) == 'table' and entries or {}) do
        if #snapshot >= maxMarkers then break end
        local handle = tonumber(entry and entry.handle)
        local sprite = tonumber(entry and entry.sprite)
        if handle and handle > 0 and sprite and not visited[handle] then
            visited[handle] = true
            local catalog = catalogFor(sprite)
            if catalog then
                seen[handle] = true
                local token = nextTokenFor(state, handle)
                local id = ('native:%d:%d'):format(math.floor(sprite), token)
                local marker = Blips.NormalizeMarker({
                    source = 'native',
                    sprite = sprite,
                    colour = entry.colour,
                    alpha = entry.alpha,
                    x = entry.x,
                    y = entry.y,
                    z = entry.z,
                    label = catalog.label,
                    category = catalog.category,
                    glyph = catalog.glyph
                }, id, limits)
                if marker then snapshot[#snapshot + 1] = marker end
            end
        end
    end

    for handle in pairs(state.tokens) do
        if not seen[handle] then state.tokens[handle] = nil end
    end

    return snapshot
end

local function nativeFn(name)
    local fn = _G[name]
    if type(fn) ~= 'function' then return nil end
    return fn
end

-- FiveM pode devolver vector3 como table ou como tipo proprio; lemos os campos
-- sem assumir `type(value) == 'table'`.
local function readXYZ(value)
    if value == nil then return nil end
    local kind = type(value)
    if kind ~= 'table' and kind ~= 'vector3' and kind ~= 'userdata' then return nil end
    local ok, x, y, z = pcall(function() return value.x, value.y, value.z end)
    if not ok then return nil end
    return x, y, z
end

--[[
    Le apenas os sprites permitidos. Retorna lista crua ou nil, erro.
    Orcamento: no maximo MaxPerSprite handles por sprite, por ciclo.
]]
function Blips.ReadNative()
    local first = nativeFn('GetFirstBlipInfoId')
    local nextBlip = nativeFn('GetNextBlipInfoId')
    local exists = nativeFn('DoesBlipExist')
    local coord = nativeFn('GetBlipInfoIdCoord')
    if not first or not nextBlip or not exists or not coord then
        return nil, 'natives_unavailable'
    end

    local getSprite = nativeFn('GetBlipSprite')
    local getColour = nativeFn('GetBlipColour')
    local getAlpha = nativeFn('GetBlipAlpha')
    local sprites = configValue('Sprites', {})
    local maxPerSprite = Blips.MaxPerSprite()
    local entries, seen = {}, {}

    local ok, err = pcall(function()
        for _, sprite in ipairs(type(sprites) == 'table' and sprites or {}) do
            local spriteId = tonumber(sprite)
            if spriteId and spriteId >= 0 and spriteId <= 9999 then
                local handle = first(spriteId)
                local scanned = 0
                while handle and handle ~= 0 and scanned < maxPerSprite do
                    scanned = scanned + 1
                    if not seen[handle] and exists(handle) then
                        seen[handle] = true
                        local position = coord(handle)
                        local px, py, pz = readXYZ(position)
                        if finite(px) and finite(py) then
                            local actual = spriteId
                            if getSprite then
                                local reported = tonumber(getSprite(handle))
                                if reported and reported >= 0 and catalogFor(reported) then
                                    actual = reported
                                end
                            end
                            entries[#entries + 1] = {
                                handle = handle,
                                sprite = actual,
                                colour = getColour and tonumber(getColour(handle)) or 0,
                                alpha = getAlpha and tonumber(getAlpha(handle)) or 255,
                                x = px,
                                y = py,
                                z = pz
                            }
                        end
                    end
                    local following = nextBlip(spriteId)
                    if following == handle then break end
                    handle = following
                end
            end
        end
    end)

    if not ok then return nil, 'enumeration_failed' end
    return entries, nil
end

local function limitsTable()
    local waypoint = Config and Config.Waypoint or {}
    return {
        maxWorld = tonumber(waypoint.maxWorld) or 20000.0,
        minZ = tonumber(waypoint.minZ) or -2000.0,
        maxZ = tonumber(waypoint.maxZ) or 3000.0,
        labelMax = labelMax(),
        maxMarkers = Blips.MaxMarkers()
    }
end

local function nowMs()
    local fn = nativeFn('GetGameTimer')
    if not fn then return 0 end
    local ok, value = pcall(fn)
    return ok and tonumber(value) or 0
end

local function send(action, payload)
    if type(SendNUIMessage) ~= 'function' then return false end
    payload = type(payload) == 'table' and payload or {}
    payload.action = action
    payload.version = 1
    local ok = pcall(SendNUIMessage, payload)
    return ok == true
end

local function externalList()
    local keys = {}
    for key in pairs(State.external) do keys[#keys + 1] = key end
    table.sort(keys)
    local out = {}
    for _, key in ipairs(keys) do out[#out + 1] = State.external[key] end
    return out
end

local function combinedSnapshot()
    local snapshot, maxMarkers = {}, Blips.MaxMarkers()
    -- Registro explicito tem prioridade de nome/rotulo sobre a leitura nativa.
    for _, marker in ipairs(externalList()) do
        if #snapshot >= maxMarkers then break end
        snapshot[#snapshot + 1] = marker
    end
    for _, marker in ipairs(State.lastNative) do
        if #snapshot >= maxMarkers then break end
        snapshot[#snapshot + 1] = marker
    end
    return snapshot
end

--[[
    Calcula e publica apenas o delta. Nunca envia snapshot inteiro durante a
    sessao (reset e apenas um aviso de geracao).
]]
function Blips.Publish()
    if State.active ~= true then return false end
    local snapshot = combinedSnapshot()
    local upserts, removes, current = Blips.Diff(State.previous, snapshot)
    State.previous = current
    State.lastCount = #snapshot

    if #upserts == 0 and #removes == 0 then return false end
    State.seq = State.seq + 1
    send('navigation:blips:delta', {
        generation = State.generation,
        seq = State.seq,
        upserts = upserts,
        removes = removes
    })
    return true
end

function Blips.Poll()
    if State.active ~= true then return false end
    local ui = MZNavigationClient.UI
    if type(ui) == 'table' and type(ui.IsOpen) == 'function' and ui.IsOpen() ~= true then
        Blips.SetActive(false)
        return false
    end

    local started = nowMs()
    local entries, err = Blips.ReadNative()
    State.polls = State.polls + 1
    if entries then
        State.lastNative = Blips.BuildSnapshot(entries, State, limitsTable())
        State.lastError = nil
        Blips.Publish()
    else
        -- Falha temporaria nao remove marcadores (evita flicker); o proximo
        -- ciclo tenta de novo. O erro fica disponivel para diagnostico.
        State.lastError = err or 'native_read_failed'
    end
    State.lastCostMs = math.max(0, nowMs() - started)

    if configValue('Debug', false) == true then
        print(('[mz_navigation][blips] active=%s markers=%d upserts/cycle cost=%dms poll=%dms error=%s')
            :format(tostring(State.active), State.lastCount, State.lastCostMs,
                Blips.PollInterval(), tostring(State.lastError)))
    end
    return true
end

local function schedule()
    if State.active ~= true then return end
    local token = State.timerToken
    if type(SetTimeout) ~= 'function' then return end
    SetTimeout(Blips.PollInterval(), function()
        if State.active ~= true or State.timerToken ~= token then return end
        Blips.Poll()
        schedule()
    end)
end

--[[
    Liga/desliga o leitor. Ao ligar: gera uma nova generation, limpa o diff e
    envia reset para a NUI. Ao desligar: para o timer, incrementa a generation
    e descarta o snapshot nativo. Marcadores explicitos permanecem para a
    proxima abertura (quem registrou e responsavel por RemoveMarker).
]]
function Blips.SetActive(active)
    active = active == true and blipsEnabled()
    if active == State.active then
        -- CEF pode recarregar/reabrir sem o client mudar de estado. Reenvia
        -- reset + snapshot para a NUI nova sem criar um segundo timer.
        if active then
            State.generation = State.generation + 1
            State.seq = 0
            State.previous = {}
            send('navigation:blips:reset', {
                generation = State.generation,
                reason = 'refresh'
            })
            Blips.Poll()
        end
        return false
    end

    State.active = active
    State.generation = State.generation + 1
    State.seq = 0
    State.previous = {}
    State.lastNative = {}
    State.tokens = {}
    State.nextToken = 0
    State.timerToken = State.timerToken + 1
    if not active then
        State.lastCount = 0
        return true
    end

    send('navigation:blips:reset', {
        generation = State.generation,
        reason = 'open'
    })
    Blips.Poll()
    schedule()
    return true
end

function Blips.Stop()
    if State.active ~= true then return false end
    return Blips.SetActive(false)
end

--[[
    Registro explicito client-side para consumidores futuros. Nao altera
    produtores existentes e nao concede autorizacao: e apenas exibicao local.
    ID final = external:<owner>:<id> (namespace evita colisao silenciosa).
]]
function Blips.UpsertExternal(def)
    if not blipsEnabled() then return nil, 'blips_disabled' end
    if type(def) ~= 'table' then return nil, 'marker_invalid' end

    local owner = def.owner
    local id = def.id
    if not Blips.ValidOwner(owner) then return nil, 'owner_invalid' end
    if not Blips.ValidExternalId(id) then return nil, 'id_invalid' end

    local key = Blips.ExternalKey(owner, id)
    local marker, err = Blips.NormalizeMarker({
        source = 'external',
        sprite = def.sprite or 0,
        colour = def.colour,
        alpha = def.alpha,
        x = def.x,
        y = def.y,
        z = def.z,
        label = def.label or id,
        category = def.category,
        glyph = def.glyph
    }, key, limitsTable())
    if not marker then return nil, err end

    State.external[key] = marker
    Blips.Publish()
    return marker
end

function Blips.RemoveExternal(owner, id)
    if not Blips.ValidOwner(owner) or not Blips.ValidExternalId(id) then return false, 'id_invalid' end
    local key = Blips.ExternalKey(owner, id)
    if State.external[key] == nil then return false, 'marker_not_found' end
    State.external[key] = nil
    Blips.Publish()
    return true
end

function Blips.ClearExternal()
    State.external = {}
    Blips.Publish()
end

function Blips.Diagnostics()
    local externalCount = 0
    for _ in pairs(State.external) do externalCount = externalCount + 1 end
    return {
        enabled = blipsEnabled(),
        active = State.active == true,
        generation = State.generation,
        seq = State.seq,
        nativeCount = #State.lastNative,
        externalCount = externalCount,
        total = State.lastCount,
        polls = State.polls,
        pollMs = Blips.PollInterval(),
        lastCostMs = State.lastCostMs,
        lastError = State.lastError
    }
end

--[[
    Reset de estado usado por testes offline e por troca de personagem/recurso.
    Nao envia mensagem: o chamador decide o ciclo de vida.
]]
function Blips.ResetState()
    State.active = false
    State.generation = 0
    State.seq = 0
    State.previous = {}
    State.tokens = {}
    State.nextToken = 0
    State.lastNative = {}
    State.external = {}
    State.timerToken = State.timerToken + 1
    State.polls = 0
    State.lastCount = 0
    State.lastCostMs = 0
    State.lastError = nil
end

return Blips
