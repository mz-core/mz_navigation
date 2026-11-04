--[[
    mz_navigation - ponte GPS client-side.

    Regras:
      - SetNewWaypoint recebe x/y; z nao e necessario para o blip.
      - z de um clique 2D NAO e confiavel. So devolvemos z quando um native de
        solo retorna um valor plausivel; caso contrario o campo e omitido.
      - pontes, tuneis e interiores podem exigir ajuste manual; o consumidor
        deve tratar z ausente.
]]

MZNavigation = MZNavigation or {}
MZNavigationClient = MZNavigationClient or {}
MZNavigationClient.GPS = MZNavigationClient.GPS or {}

local GPS = MZNavigationClient.GPS
local Geo = MZNavigation.Geo

local GROUND_MIN_Z = -100.0
local GROUND_MAX_Z = 1200.0

function GPS.ResolveGroundZ(x, y)
    if type(GetGroundZFor_3dCoord) ~= 'function' then return nil, false end
    local probes = { Config.Waypoint.groundProbeZ, 600.0, 300.0 }
    for _, probe in ipairs(probes) do
        local ok, found, groundZ = pcall(GetGroundZFor_3dCoord, x, y, probe, false)
        if ok and found and type(groundZ) == 'number' and groundZ == groundZ
            and groundZ >= GROUND_MIN_Z and groundZ <= GROUND_MAX_Z then
            return groundZ + 0.0, true
        end
    end
    return nil, false
end

--[[
    Retorna selection = { x, y, z?, zReliable } ou nil, err.
]]
function GPS.BuildSelection(coords, extra)
    local normalized, err = Geo.NormalizeCoords(coords, {
        maxWorld = Config.Waypoint.maxWorld,
        minZ = Config.Waypoint.minZ,
        maxZ = Config.Waypoint.maxZ
    })
    if not normalized then return nil, err end

    local selection = {
        x = normalized.x,
        y = normalized.y,
        zResolved = normalized.z ~= nil,
        zReliable = normalized.z ~= nil
    }
    if normalized.z ~= nil then
        selection.z = normalized.z
    else
        local groundZ, reliable = GPS.ResolveGroundZ(normalized.x, normalized.y)
        if groundZ and reliable then
            selection.z = groundZ
            selection.zReliable = true
        end
    end

    if type(extra) == 'table' then
        if type(extra.poiId) == 'string' then selection.poiId = extra.poiId end
        if type(extra.label) == 'string' then selection.label = extra.label end
    end

    return selection
end

function GPS.Set(coords)
    local normalized, err = Geo.NormalizeCoords(coords, {
        maxWorld = Config.Waypoint.maxWorld,
        minZ = Config.Waypoint.minZ,
        maxZ = Config.Waypoint.maxZ
    })
    if not normalized then return false, err or 'invalid_coords' end
    if type(SetNewWaypoint) ~= 'function' then return false, 'waypoint_unavailable' end

    local ok = pcall(SetNewWaypoint, normalized.x + 0.0, normalized.y + 0.0)
    if not ok then return false, 'waypoint_failed' end
    return true
end

function GPS.Clear()
    if type(SetWaypointOff) ~= 'function' then return false, 'waypoint_unavailable' end
    local ok = pcall(SetWaypointOff)
    return ok == true
end

-- Waypoint atual do jogador (blip 8). Util para "usar destino do GPS".
function GPS.GetCurrent()
    if type(GetFirstBlipInfoId) ~= 'function' then return nil, 'waypoint_unavailable' end
    local blip = GetFirstBlipInfoId(8)
    if not blip or blip == 0 or not DoesBlipExist(blip) then return nil, 'waypoint_not_set' end

    local raw = GetBlipInfoIdCoord(blip)
    local kind = type(raw)
    -- vector3 pode chegar como table ou tipo proprio do CFX.
    if kind ~= 'table' and kind ~= 'vector3' and kind ~= 'userdata' then
        return nil, 'waypoint_not_set'
    end
    local ok, x, y = pcall(function() return raw.x, raw.y end)
    if not ok or type(x) ~= 'number' or type(y) ~= 'number' then
        return nil, 'waypoint_not_set'
    end

    local selection = GPS.BuildSelection({ x = x, y = y })
    if not selection then return nil, 'waypoint_not_set' end
    return selection
end
