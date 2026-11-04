--[[
    mz_navigation - servico de rotas (Wave 4A).

    Autoridade:
      - owner e derivado da identidade/org do chamador, nunca do payload;
      - leitura/mutacao sempre passam por canRead/canEdit;
      - update/delete/publish usam revision (optimistic lock);
      - quotas por personagem/org e rate limit ficam no servico;
      - a tabela e manual; sem ela o servico falha fechado.
]]

MZNavigation = MZNavigation or {}
MZNavigation.RouteService = MZNavigation.RouteService or {}

local RouteService = MZNavigation.RouteService
local RouteRepository = MZNavigation.RouteRepository
local RouteSchema = MZNavigation.RouteSchema
local Repository = MZNavigation.Repository
local Schema = MZNavigation.Schema

local idCounter = 0
math.randomseed(os.time())

local function encodePoints(points)
    if type(json) ~= 'table' or type(json.encode) ~= 'function' then return nil end
    local ok, encoded = pcall(json.encode, points)
    if not ok or type(encoded) ~= 'string' then return nil end
    return encoded
end

local function decodePoints(raw)
    if type(raw) ~= 'string' or raw == '' then return {} end
    if type(json) ~= 'table' or type(json.decode) ~= 'function' then return nil end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then return nil end
    return decoded
end

local function newPublicId()
    idCounter = idCounter + 1
    return ('route_%08x%08x%04x'):format(
        os.time(),
        math.random(0, 2147483647),
        idCounter % 65536
    )
end

local function enabled()
    return Config.Routes and Config.Routes.Enabled == true
end

local function repoReady()
    return RouteRepository.Available == true
end

local function quotaReady()
    return RouteRepository.QuotaAvailable == true
end

local function isOwnerCharacter(row, ctx)
    return row.owner_type == 'character'
        and tonumber(row.owner_character_id) == tonumber(ctx.characterId)
end

local function isOwnerOrg(row, ctx)
    if row.owner_type ~= 'org' then return false end
    local code = tostring(row.owner_org_code or '')
    return code ~= '' and ctx.orgCodes and ctx.orgCodes[code] == true
end

local function canRead(row, ctx)
    if isOwnerCharacter(row, ctx) or isOwnerOrg(row, ctx) then return true end
    return row.visibility == 'public' and tonumber(row.is_published) == 1
end

local function canEdit(row, ctx)
    return isOwnerCharacter(row, ctx) or isOwnerOrg(row, ctx)
end

local function sanitizeRow(row, ctx, includePoints)
    if type(row) ~= 'table' then return nil end
    local points = nil
    if includePoints then
        points = decodePoints(row.points_json)
        if not points then return nil end
    end

    local canWrite = ctx and canEdit(row, ctx) or false
    return {
        publicId = tostring(row.public_id or ''),
        title = tostring(row.title or ''),
        description = tostring(row.description or ''),
        routeType = tostring(row.route_type or 'generic'),
        visibility = tostring(row.visibility or 'character'),
        ownerType = tostring(row.owner_type or 'character'),
        ownerOrgCode = row.owner_type == 'org' and tostring(row.owner_org_code or '') or nil,
        schemaVersion = tonumber(row.schema_version) or 1,
        revision = tonumber(row.revision) or 1,
        pointCount = tonumber(row.point_count) or 0,
        totalDistance = tonumber(row.total_distance) or 0.0,
        isPublished = tonumber(row.is_published) == 1,
        canEdit = canWrite == true,
        createdAt = row.created_at,
        updatedAt = row.updated_at,
        publishedAt = row.published_at,
        points = points
    }
end

local function audit(ctx, action, publicId, detail)
    if Repository and type(Repository.Audit) == 'function' then
        Repository.Audit(ctx.characterId, ctx.citizenid, action, publicId, detail)
    end
end

function RouteService.IsEnabled()
    return enabled()
end

function RouteService.CatalogEnabled()
    return enabled() and Config.Routes.CatalogEnabled == true
end

function RouteService.IsAvailable()
    return enabled() and repoReady()
end

local SCOPES = { all = true, mine = true, org = true, public = true }

function RouteService.List(ctx, payload)
    if not enabled() then return nil, 'routes_disabled' end
    if not repoReady() then return nil, 'routes_unavailable' end

    payload = type(payload) == 'table' and payload or {}
    local page = tonumber(payload.page) or 1
    if page < 1 or page % 1 ~= 0 then page = 1 end
    local limit = tonumber(payload.limit) or Config.Routes.DefaultPageSize
    if limit < 1 then limit = Config.Routes.DefaultPageSize end
    if limit > Config.Routes.MaxPageSize then limit = Config.Routes.MaxPageSize end
    local search = RouteSchema.SanitizeSearch(payload.search)
    local scope = tostring(payload.scope or 'all'):lower()
    if not SCOPES[scope] then scope = 'all' end

    local ok, rows, hasNext = pcall(RouteRepository.ListForContext, ctx, {
        page = page,
        limit = limit,
        offset = (page - 1) * limit,
        search = search,
        scope = scope
    })
    if not ok then return nil, 'database_error' end

    local routes = {}
    for _, row in ipairs(rows or {}) do
        local sanitized = sanitizeRow(row, ctx, false)
        if sanitized then routes[#routes + 1] = sanitized end
    end

    return {
        routes = routes,
        page = page,
        limit = limit,
        hasNext = hasNext == true,
        scope = scope
    }
end

--[[
    Catalogo read-only para fullscreen/MZ Maps. Exige as duas flags:
    Routes.Enabled (feature) e Routes.CatalogEnabled (consumo).
    O DTO do catalogo remove campos internos de auditoria/owner e permissao de
    escrita; o detalhe continua revalidando ACL em RouteService.Get.
]]
local function redactCatalogRoute(route)
    if type(route) ~= 'table' then return route end
    route.ownerOrgCode = nil
    route.canEdit = nil
    route.createdAt = nil
    route.updatedAt = nil
    route.publishedAt = nil
    return route
end

function RouteService.CatalogList(ctx, payload)
    if not enabled() then return nil, 'routes_disabled' end
    if Config.Routes.CatalogEnabled ~= true then return nil, 'catalog_disabled' end
    local data, err = RouteService.List(ctx, payload)
    if not data then return nil, err end
    for _, route in ipairs(data.routes or {}) do redactCatalogRoute(route) end
    return data
end

function RouteService.CatalogGet(ctx, publicId)
    if not enabled() then return nil, 'routes_disabled' end
    if Config.Routes.CatalogEnabled ~= true then return nil, 'catalog_disabled' end
    local route, err = RouteService.Get(ctx, publicId)
    if not route then return nil, err end
    return redactCatalogRoute(route)
end

function RouteService.Get(ctx, publicId)
    if not enabled() then return nil, 'routes_disabled' end
    if not repoReady() then return nil, 'routes_unavailable' end
    local id, idErr = RouteSchema.ValidatePublicId(publicId)
    if not id then return nil, idErr end

    local ok, row = pcall(RouteRepository.GetByPublicId, id)
    if not ok then return nil, 'database_error' end
    -- Nao revelar existencia de rota alheia (IDOR / enumeracao).
    if not row or not canRead(row, ctx) then return nil, 'route_not_found' end

    local route = sanitizeRow(row, ctx, true)
    if not route then return nil, 'route_invalid' end
    return route
end

local function resolveOrg(ctx, payload)
    local orgCode = Schema.SanitizeText(payload.orgCode, 64)
    if orgCode == '' then return nil, 'route_org_required' end
    if not ctx.orgCodes or ctx.orgCodes[orgCode] ~= true then
        return nil, 'route_org_forbidden'
    end
    return orgCode
end

function RouteService.Create(ctx, payload)
    if not enabled() then return nil, 'routes_disabled' end
    if not repoReady() then return nil, 'routes_unavailable' end
    if not quotaReady() then return nil, 'quota_unavailable' end
    payload = type(payload) == 'table' and payload or {}

    local ownerType, ownerErr = RouteSchema.NormalizeOwnerType(payload.ownerType)
    if not ownerType then return nil, ownerErr end

    local ownerCharacterId, ownerOrgCode, orgCode, ownerKey
    if ownerType == 'org' then
        orgCode, ownerErr = resolveOrg(ctx, payload)
        if not orgCode then return nil, ownerErr end
        ownerOrgCode = orgCode
        ownerKey = orgCode
    else
        ownerCharacterId = ctx.characterId
        ownerKey = tostring(ctx.characterId)
    end

    local definition, definitionErr = RouteSchema.NormalizeDefinition(payload)
    if not definition then return nil, definitionErr end

    local visibility, visibilityErr = RouteSchema.NormalizeVisibility(
        payload.visibility,
        ownerType
    )
    if not visibility then return nil, visibilityErr end
    if ownerType == 'character' and visibility == 'org' then
        return nil, 'route_visibility_invalid'
    end
    if ownerType == 'org' and visibility == 'character' then
        return nil, 'route_visibility_invalid'
    end

    local pointsJson = encodePoints(definition.points)
    if not pointsJson then return nil, 'serialization_unavailable' end

    local publicId = newPublicId()
    local ok, created, createErr = pcall(RouteRepository.CreateWithQuota, {
        publicId = publicId,
        ownerType = ownerType,
        ownerCharacterId = ownerCharacterId,
        ownerOrgCode = ownerOrgCode,
        title = definition.title,
        description = definition.description,
        routeType = definition.routeType,
        visibility = visibility,
        schemaVersion = definition.schemaVersion,
        pointsJson = pointsJson,
        pointCount = definition.pointCount,
        totalDistance = definition.totalDistance
    }, ownerType, ownerKey, ownerType == 'org'
        and Config.Routes.MaxRoutesPerOrg
        or Config.Routes.MaxRoutesPerCharacter)
    if not ok then return nil, 'database_error' end
    if tonumber(created) == 0 then return nil, 'route_limit_reached' end
    if tonumber(created) ~= 1 then
        if createErr == 'quota_unavailable' then return nil, createErr end
        return nil, 'database_error'
    end

    audit(ctx, 'route.create', publicId, definition.title)
    return RouteService.Get(ctx, publicId)
end

function RouteService.Update(ctx, publicId, payload)
    if not enabled() then return nil, 'routes_disabled' end
    if not repoReady() then return nil, 'routes_unavailable' end
    payload = type(payload) == 'table' and payload or {}

    local id, idErr = RouteSchema.ValidatePublicId(publicId)
    if not id then return nil, idErr end
    local expectedRevision, revErr = RouteSchema.ValidateExpectedRevision(payload.expectedRevision)
    if not expectedRevision then return nil, revErr end

    local ok, row = pcall(RouteRepository.GetByPublicId, id)
    if not ok then return nil, 'database_error' end
    if not row or not canEdit(row, ctx) then return nil, 'route_not_found' end

    local definition, definitionErr = RouteSchema.NormalizeDefinition(payload)
    if not definition then return nil, definitionErr end

    local visibility, visibilityErr = RouteSchema.NormalizeVisibility(
        payload.visibility or row.visibility,
        row.owner_type
    )
    if not visibility then return nil, visibilityErr end
    if row.owner_type == 'character' and visibility == 'org' then
        return nil, 'route_visibility_invalid'
    end
    if row.owner_type == 'org' and visibility == 'character' then
        return nil, 'route_visibility_invalid'
    end

    local pointsJson = encodePoints(definition.points)
    if not pointsJson then return nil, 'serialization_unavailable' end

    local updateOk, affected = pcall(RouteRepository.Update, {
        publicId = id,
        title = definition.title,
        description = definition.description,
        routeType = definition.routeType,
        visibility = visibility,
        pointsJson = pointsJson,
        pointCount = definition.pointCount,
        totalDistance = definition.totalDistance
    }, expectedRevision)
    if not updateOk then return nil, 'database_error' end
    if tonumber(affected) ~= 1 then
        return nil, 'route_conflict'
    end

    audit(ctx, 'route.update', id, definition.title)
    return RouteService.Get(ctx, id)
end

function RouteService.Delete(ctx, publicId, payload)
    if not enabled() then return nil, 'routes_disabled' end
    if not repoReady() then return nil, 'routes_unavailable' end
    payload = type(payload) == 'table' and payload or {}

    local id, idErr = RouteSchema.ValidatePublicId(publicId)
    if not id then return nil, idErr end
    local expectedRevision, revErr = RouteSchema.ValidateExpectedRevision(payload.expectedRevision)
    if not expectedRevision then return nil, revErr end

    local ok, row = pcall(RouteRepository.GetByPublicId, id)
    if not ok then return nil, 'database_error' end
    if not row or not canEdit(row, ctx) then return nil, 'route_not_found' end

    local deleteOk, affected = pcall(RouteRepository.Delete, id, expectedRevision)
    if not deleteOk then return nil, 'database_error' end
    if tonumber(affected) ~= 1 then return nil, 'route_conflict' end

    if quotaReady() then
        local ownerType = row.owner_type == 'org' and 'org' or 'character'
        local ownerKey = ownerType == 'org'
            and tostring(row.owner_org_code or '')
            or tostring(row.owner_character_id or '')
        local released, releaseErr = pcall(RouteRepository.ReleaseQuota, ownerType, ownerKey)
        if not released or releaseErr ~= true then
            print(('[mz_navigation] route quota release failed: %s'):format(tostring(releaseErr)))
        end
    end

    audit(ctx, 'route.delete', id, row.title)
    return true
end

function RouteService.SetPublished(ctx, publicId, payload, published)
    if not enabled() then return nil, 'routes_disabled' end
    if not repoReady() then return nil, 'routes_unavailable' end
    payload = type(payload) == 'table' and payload or {}

    local id, idErr = RouteSchema.ValidatePublicId(publicId)
    if not id then return nil, idErr end
    local expectedRevision, revErr = RouteSchema.ValidateExpectedRevision(payload.expectedRevision)
    if not expectedRevision then return nil, revErr end

    local ok, row = pcall(RouteRepository.GetByPublicId, id)
    if not ok then return nil, 'database_error' end
    if not row or not canEdit(row, ctx) then return nil, 'route_not_found' end
    if published and row.visibility ~= 'public' then
        return nil, 'route_publish_requires_public'
    end

    local publishOk, affected = pcall(
        RouteRepository.SetPublished,
        id,
        expectedRevision,
        published == true
    )
    if not publishOk then return nil, 'database_error' end
    if tonumber(affected) ~= 1 then return nil, 'route_conflict' end

    audit(ctx, published and 'route.publish' or 'route.unpublish', id, row.title)
    return RouteService.Get(ctx, id)
end

-- Contrato somente-leitura para consumidores server-side futuros (ex.: mz_racing).
function RouteService.ListPublished(payload)
    if not enabled() then return nil, 'routes_disabled' end
    if not repoReady() then return nil, 'routes_unavailable' end
    payload = type(payload) == 'table' and payload or {}

    local page = tonumber(payload.page) or 1
    if page < 1 or page % 1 ~= 0 then page = 1 end
    local limit = tonumber(payload.limit) or Config.Routes.DefaultPageSize
    if limit < 1 then limit = Config.Routes.DefaultPageSize end
    if limit > Config.Routes.MaxPageSize then limit = Config.Routes.MaxPageSize end
    local search = RouteSchema.SanitizeSearch(payload.search)

    local ok, rows, hasNext = pcall(RouteRepository.ListPublished, {
        limit = limit,
        offset = (page - 1) * limit,
        search = search
    })
    if not ok then return nil, 'database_error' end

    local routes = {}
    for _, row in ipairs(rows or {}) do
        local sanitized = sanitizeRow(row, nil, true)
        if sanitized then routes[#routes + 1] = sanitized end
    end
    return { routes = routes, page = page, limit = limit, hasNext = hasNext == true }
end

function RouteService.GetPublished(publicId)
    if not enabled() then return nil, 'routes_disabled' end
    if not repoReady() then return nil, 'routes_unavailable' end
    local id, idErr = RouteSchema.ValidatePublicId(publicId)
    if not id then return nil, idErr end

    local ok, row = pcall(RouteRepository.GetByPublicId, id)
    if not ok then return nil, 'database_error' end
    if not row or row.visibility ~= 'public' or tonumber(row.is_published) ~= 1 then
        return nil, 'route_not_found'
    end
    local route = sanitizeRow(row, nil, true)
    if not route then return nil, 'route_invalid' end
    return route
end
