--[[
    mz_navigation - geometria e validacao de coordenadas.

    Funcoes puras, sem natives e sem I/O, para poderem ser testadas fora do jogo.
    Nenhum dado do cliente deve ser aceito sem passar por aqui.
]]

MZNavigation = MZNavigation or {}
MZNavigation.Geo = MZNavigation.Geo or {}

local Geo = MZNavigation.Geo

local function isFiniteNumber(value)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function Geo.IsFiniteNumber(value)
    return isFiniteNumber(value)
end

--[[
    Normaliza coordenadas aceitando {x,y,z} ou {1,2,3}.
    Retorna nil, motivo quando invalido. z e OPCIONAL: um ponto 2D e valido e
    NAO recebe z=0 automaticamente, porque z=0 nao e uma altura confiavel.
]]
function Geo.NormalizeCoords(value, limits)
    if value == nil then return nil, 'coords_missing' end
    local kind = type(value)
    -- vector3 do FiveM pode chegar como table ou tipo proprio do CFX.
    if kind ~= 'table' and kind ~= 'vector3' and kind ~= 'userdata' then
        return nil, 'coords_invalid'
    end

    local ok, rawX, rawY, rawZ = pcall(function()
        return value.x or value[1], value.y or value[2], value.z or value[3]
    end)
    if not ok then return nil, 'coords_invalid' end

    local x = tonumber(rawX)
    local y = tonumber(rawY)
    if not isFiniteNumber(x) or not isFiniteNumber(y) then return nil, 'coords_invalid' end

    limits = limits or {}
    local maxWorld = limits.maxWorld or 20000.0
    if math.abs(x) > maxWorld or math.abs(y) > maxWorld then return nil, 'coords_out_of_range' end

    local result = { x = x + 0.0, y = y + 0.0 }

    if rawZ ~= nil then
        local z = tonumber(rawZ)
        local minZ = limits.minZ or -2000.0
        local maxZ = limits.maxZ or 3000.0
        if not isFiniteNumber(z) or z < minZ or z > maxZ then
            return nil, 'z_out_of_range'
        end
        result.z = z + 0.0
    end

    return result
end

function Geo.Distance2D(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return math.huge end
    local dx = (tonumber(a.x) or 0.0) - (tonumber(b.x) or 0.0)
    local dy = (tonumber(a.y) or 0.0) - (tonumber(b.y) or 0.0)
    return math.sqrt(dx * dx + dy * dy)
end

function Geo.IsInsideBounds(coords, bounds)
    if type(coords) ~= 'table' or type(bounds) ~= 'table' then return false end
    local x, y = tonumber(coords.x), tonumber(coords.y)
    if not isFiniteNumber(x) or not isFiniteNumber(y) then return false end
    return x >= bounds.minX and x <= bounds.maxX and y >= bounds.minY and y <= bounds.maxY
end

function Geo.ClampToBounds(coords, bounds)
    if type(coords) ~= 'table' or type(bounds) ~= 'table' then return nil end
    local x, y = tonumber(coords.x), tonumber(coords.y)
    if not isFiniteNumber(x) or not isFiniteNumber(y) then return nil end
    local clamped = {
        x = math.min(math.max(x, bounds.minX), bounds.maxX) + 0.0,
        y = math.min(math.max(y, bounds.minY), bounds.maxY) + 0.0
    }
    if coords.z ~= nil then clamped.z = coords.z end
    return clamped
end

--[[
    Projecao afim mundo -> normalizado (0..1).
    u cresce para o leste; v cresce para o sul (coerente com a tela).
    A projecao NAO e geografica e NAO serve para ETA/rota viaria.
]]
function Geo.WorldToUnit(coords, bounds)
    if type(coords) ~= 'table' or type(bounds) ~= 'table' then return nil end
    local width = bounds.maxX - bounds.minX
    local height = bounds.maxY - bounds.minY
    if width <= 0.0 or height <= 0.0 then return nil end
    local x, y = tonumber(coords.x), tonumber(coords.y)
    if not isFiniteNumber(x) or not isFiniteNumber(y) then return nil end
    return {
        u = (x - bounds.minX) / width,
        v = (bounds.maxY - y) / height
    }
end

function Geo.UnitToWorld(u, v, bounds)
    if type(bounds) ~= 'table' then return nil end
    u, v = tonumber(u), tonumber(v)
    if not isFiniteNumber(u) or not isFiniteNumber(v) then return nil end
    local width = bounds.maxX - bounds.minX
    local height = bounds.maxY - bounds.minY
    if width <= 0.0 or height <= 0.0 then return nil end
    return {
        x = bounds.minX + u * width,
        y = bounds.maxY - v * height
    }
end
