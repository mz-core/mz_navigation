--[[
    mz_navigation - schema do editor de rotas (Wave 4A).

    Route definition e uma sequencia autorada de pontos. NAO e rota viaria,
    malha de ruas, ETA ou pathfinding.

    Funcoes puras para teste offline.
]]

MZNavigation = MZNavigation or {}
MZNavigation.RouteSchema = MZNavigation.RouteSchema or {}

local RS = MZNavigation.RouteSchema
local Geo = MZNavigation.Geo
local Schema = MZNavigation.Schema

local function routeLimits()
    return Config.Routes
end

function RS.NormalizePoint(value, limits)
    local point, err = Geo.NormalizeCoords(value, {
        maxWorld = Config.Waypoint.maxWorld,
        minZ = Config.Waypoint.minZ,
        maxZ = Config.Waypoint.maxZ
    })
    if not point then return nil, err end
    if not Geo.IsInsideBounds(point, Config.Map) then
        return nil, 'route_point_out_of_bounds'
    end
    return point
end

function RS.NormalizeVisibility(value, ownerType)
    value = tostring(value or ''):lower()
    if value == '' then
        return ownerType == 'org' and 'org' or 'character'
    end
    if value == 'character' or value == 'org' or value == 'public' then
        return value
    end
    return nil, 'route_visibility_invalid'
end

function RS.NormalizeOwnerType(value)
    value = tostring(value or 'character'):lower()
    if value == 'character' or value == 'org' then return value end
    return nil, 'route_owner_type_invalid'
end

function RS.NormalizeRouteType(value)
    value = tostring(value or 'generic'):lower()
    if Config.Routes.RouteTypes[value] then return value end
    return nil, 'route_type_invalid'
end

function RS.SanitizeSearch(value)
    return Schema.SanitizeText(value, Config.Routes.MaxSearchLength)
end

--[[
    payload = {
      title, description, routeType, points = { {x,y,z?}, ... }
    }
    Retorna definicao normalizada sem owner/visibility (responsabilidade do servico).
]]
function RS.NormalizeDefinition(payload)
    if type(payload) ~= 'table' then return nil, 'route_invalid' end
    local limits = routeLimits()

    local title = Schema.SanitizeText(payload.title, limits.MaxTitle)
    if title == '' then return nil, 'route_title_invalid' end

    local description = Schema.SanitizeText(payload.description, limits.MaxDescription)
    local routeType, typeErr = RS.NormalizeRouteType(payload.routeType)
    if not routeType then return nil, typeErr end

    local points = payload.points
    if type(points) ~= 'table' then return nil, 'route_points_invalid' end
    local pointCount = #points
    if pointCount < limits.MinPoints then return nil, 'route_points_too_few' end
    if pointCount > limits.MaxPoints then return nil, 'route_points_too_many' end

    local normalized, totalDistance = {}, 0.0
    local previous
    for index = 1, pointCount do
        local point, pointErr = RS.NormalizePoint(points[index], limits)
        if not point then return nil, pointErr end
        if previous and Geo.Distance2D(previous, point) < limits.MinPointDistance then
            return nil, 'route_points_duplicate'
        end
        normalized[index] = point
        if previous then totalDistance = totalDistance + Geo.Distance2D(previous, point) end
        previous = point
    end

    if totalDistance > limits.MaxTotalDistance then
        return nil, 'route_too_long'
    end

    if type(json) == 'table' and type(json.encode) == 'function' then
        local ok, encoded = pcall(json.encode, normalized)
        if ok and type(encoded) == 'string' and #encoded > limits.MaxPayloadBytes then
            return nil, 'route_payload_too_large'
        end
    end

    return {
        title = title,
        description = description,
        routeType = routeType,
        points = normalized,
        pointCount = pointCount,
        totalDistance = totalDistance,
        schemaVersion = 1
    }
end

function RS.ValidateExpectedRevision(value)
    local revision = tonumber(value)
    if not revision or revision < 1 or revision % 1 ~= 0 then
        return nil, 'route_revision_invalid'
    end
    return revision
end

function RS.ValidatePublicId(value)
    if type(value) ~= 'string' then return nil, 'route_id_invalid' end
    if #value < 8 or #value > 48 then return nil, 'route_id_invalid' end
    if not value:match('^[a-z0-9_%-]+$') then return nil, 'route_id_invalid' end
    return value
end
