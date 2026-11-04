--[[
    mz_navigation - persistencia de rotas (Wave 4A).

    Diferente de favoritos/recentes, a tabela de rotas NAO e criada em runtime.
    Ela exige aplicacao manual de sql/002_mz_navigation_routes.sql. Sem a tabela,
    o editor falha fechado com routes_unavailable e o resto do mapa continua.
]]

MZNavigation = MZNavigation or {}
MZNavigation.RouteRepository = MZNavigation.RouteRepository or {}

local RouteRepository = MZNavigation.RouteRepository

RouteRepository.Available = false
RouteRepository.Error = nil
RouteRepository.QuotaAvailable = false
RouteRepository.QuotaError = nil

local function query(sql, params)
    return MySQL.query.await(sql, params or {})
end

local function insert(sql, params)
    return MySQL.insert.await(sql, params or {})
end

local function update(sql, params)
    return MySQL.update.await(sql, params or {})
end

local function tableExists(name)
    local rows = query([[
        SELECT COUNT(*) AS total
        FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = ?
    ]], { name })
    return rows and rows[1] and tonumber(rows[1].total) == 1
end

function RouteRepository.Prepare()
    if type(MySQL) ~= 'table' or type(MySQL.query) ~= 'table' then
        RouteRepository.Available = false
        RouteRepository.Error = 'oxmysql_unavailable'
        return false, RouteRepository.Error
    end

    local ok, exists = pcall(tableExists, 'mz_navigation_routes')
    if not ok then
        RouteRepository.Available = false
        RouteRepository.Error = 'schema_check_failed'
        print('[mz_navigation] route schema check failed; apply sql/002_mz_navigation_routes.sql manually')
        return false, RouteRepository.Error
    end
    if not exists then
        RouteRepository.Available = false
        RouteRepository.Error = 'routes_table_missing'
        print('[mz_navigation] routes disabled: apply sql/002_mz_navigation_routes.sql manually')
        return false, RouteRepository.Error
    end

    RouteRepository.Available = true
    RouteRepository.Error = nil

    -- A quota transacional e uma migracao separada (003). Sem ela, leitura e
    -- edicao continuam, mas create falha fechado com quota_unavailable.
    local transactionSupported = type(MySQL.transaction) == 'table'
        and type(MySQL.transaction.await) == 'function'
    local quotaOk, quotaExists = pcall(tableExists, 'mz_navigation_route_quotas')
    if not transactionSupported then
        RouteRepository.QuotaAvailable = false
        RouteRepository.QuotaError = 'transaction_unavailable'
        print('[mz_navigation] route create disabled: oxmysql transaction.await unavailable')
    elseif not quotaOk then
        RouteRepository.QuotaAvailable = false
        RouteRepository.QuotaError = 'quota_schema_check_failed'
        print('[mz_navigation] route quota schema check failed; apply sql/003_mz_navigation_route_quotas.sql manually')
    elseif not quotaExists then
        RouteRepository.QuotaAvailable = false
        RouteRepository.QuotaError = 'quota_table_missing'
        print('[mz_navigation] route create disabled: apply sql/003_mz_navigation_route_quotas.sql manually')
    else
        RouteRepository.QuotaAvailable = true
        RouteRepository.QuotaError = nil
    end

    return true
end

local function rowToRoute(row)
    return row
end

function RouteRepository.GetByPublicId(publicId)
    local rows = query([[
        SELECT id, public_id, owner_type, owner_character_id, owner_org_code,
            title, description, route_type, visibility, schema_version, revision,
            points_json, point_count, total_distance, is_published,
            created_at, updated_at, published_at
        FROM mz_navigation_routes
        WHERE public_id = ?
        LIMIT 1
    ]], { publicId })
    return rows and rows[1] and rowToRoute(rows[1]) or nil
end

local function orgCodesOf(ctx)
    local orgCodes = {}
    for code in pairs(ctx.orgCodes or {}) do
        if type(code) == 'string' and #code <= 64 then orgCodes[#orgCodes + 1] = code end
    end
    return orgCodes
end

local function buildAccessWhere(ctx, scope)
    scope = scope or 'all'
    local orgCodes = orgCodesOf(ctx)

    if scope == 'mine' then
        return "owner_type = 'character' AND owner_character_id = ?", { ctx.characterId }
    end

    if scope == 'org' then
        if #orgCodes == 0 then return '1 = 0', {} end
        local placeholders = {}
        local params = {}
        for index = 1, #orgCodes do placeholders[index] = '?' end
        for _, code in ipairs(orgCodes) do params[#params + 1] = code end
        return ('owner_type = \'org\' AND owner_org_code IN (%s)'):format(table.concat(placeholders, ',')), params
    end

    if scope == 'public' then
        return "visibility = 'public' AND is_published = 1", {}
    end

    local orgClause = '1 = 0'
    if #orgCodes > 0 then
        local placeholders = {}
        for index = 1, #orgCodes do placeholders[index] = '?' end
        orgClause = ('owner_org_code IN (%s)'):format(table.concat(placeholders, ','))
    end

    local where = ('((owner_type = \'character\' AND owner_character_id = ?) OR (owner_type = \'org\' AND %s) OR (visibility = \'public\' AND is_published = 1))')
        :format(orgClause)
    local params = { ctx.characterId }
    for _, code in ipairs(orgCodes) do params[#params + 1] = code end
    return where, params
end

function RouteRepository.ListForContext(ctx, filters)
    filters = type(filters) == 'table' and filters or {}
    local where, params = buildAccessWhere(ctx, filters.scope)

    if filters.search and filters.search ~= '' then
        where = where .. ' AND title LIKE ?'
        params[#params + 1] = '%' .. filters.search .. '%'
    end

    local limit = tonumber(filters.limit) or Config.Routes.DefaultPageSize
    local offset = tonumber(filters.offset) or 0
    params[#params + 1] = limit + 1
    params[#params + 1] = offset

    local rows = query(([[
        SELECT id, public_id, owner_type, owner_character_id, owner_org_code,
            title, description, route_type, visibility, schema_version, revision,
            point_count, total_distance, is_published, created_at, updated_at, published_at
        FROM mz_navigation_routes
        WHERE %s
        ORDER BY updated_at DESC, id DESC
        LIMIT ? OFFSET ?
    ]]):format(where), params) or {}

    local hasNext = #rows > limit
    if hasNext then table.remove(rows) end
    for index = 1, #rows do rows[index] = rowToRoute(rows[index]) end
    return rows, hasNext
end

function RouteRepository.ListPublished(filters)
    filters = type(filters) == 'table' and filters or {}
    local where = "visibility = 'public' AND is_published = 1"
    local params = {}
    if filters.search and filters.search ~= '' then
        where = where .. ' AND title LIKE ?'
        params[#params + 1] = '%' .. filters.search .. '%'
    end

    local limit = tonumber(filters.limit) or Config.Routes.DefaultPageSize
    local offset = tonumber(filters.offset) or 0
    params[#params + 1] = limit + 1
    params[#params + 1] = offset

    local rows = query(([[
        SELECT id, public_id, owner_type, owner_org_code, title, description,
            route_type, visibility, schema_version, revision, points_json,
            point_count, total_distance, is_published, created_at, updated_at, published_at
        FROM mz_navigation_routes
        WHERE %s
        ORDER BY updated_at DESC, id DESC
        LIMIT ? OFFSET ?
    ]]):format(where), params) or {}

    local hasNext = #rows > limit
    if hasNext then table.remove(rows) end
    for index = 1, #rows do rows[index] = rowToRoute(rows[index]) end
    return rows, hasNext
end

function RouteRepository.Create(route)
    local id = insert([[
        INSERT INTO mz_navigation_routes (
            public_id, owner_type, owner_character_id, owner_org_code,
            title, description, route_type, visibility, schema_version, revision,
            points_json, point_count, total_distance, is_published
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, 0)
    ]], {
        route.publicId, route.ownerType, route.ownerCharacterId, route.ownerOrgCode,
        route.title, route.description, route.routeType, route.visibility,
        route.schemaVersion, route.pointsJson, route.pointCount, route.totalDistance
    })
    return tonumber(id)
end

--[[
    Create + quota na mesma transacao InnoDB.

    A linha de quota e o ponto de serializacao por owner. O UPDATE condicional
    (`used < limit`) adquire lock exclusivo da linha; concorrentes do mesmo
    owner esperam e, apos o commit, reavaliam a condicao. O UPDATE grava um
    `last_token` unico; o INSERT ... SELECT so cria a rota se esse token for o
    mesmo da tentativa. Qualquer falha de query aborta a transacao inteira.

    Retorno: 1 = criou, 0 = quota atingida, nil,erro = falha de persistencia.
]]
function RouteRepository.CreateWithQuota(route, ownerType, ownerKey, limit)
    if RouteRepository.QuotaAvailable ~= true then
        return nil, RouteRepository.QuotaError or 'quota_unavailable'
    end

    local transaction = MySQL.transaction.await
    local queries = {
        {
            query = [[
                INSERT INTO mz_navigation_route_quotas (owner_type, owner_key, used)
                VALUES (?, ?, 0)
                ON DUPLICATE KEY UPDATE owner_key = owner_key
            ]],
            values = { ownerType, ownerKey }
        },
        {
            query = [[
                UPDATE mz_navigation_route_quotas
                SET used = used + 1, last_token = ?, updated_at = CURRENT_TIMESTAMP
                WHERE owner_type = ? AND owner_key = ? AND used < ?
            ]],
            values = { route.publicId, ownerType, ownerKey, limit }
        },
        {
            query = [[
                INSERT INTO mz_navigation_routes (
                    public_id, owner_type, owner_character_id, owner_org_code,
                    title, description, route_type, visibility, schema_version, revision,
                    points_json, point_count, total_distance, is_published
                )
                SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, 0
                FROM mz_navigation_route_quotas
                WHERE owner_type = ? AND owner_key = ? AND last_token = ?
            ]],
            values = {
                route.publicId, route.ownerType, route.ownerCharacterId, route.ownerOrgCode,
                route.title, route.description, route.routeType, route.visibility,
                route.schemaVersion, route.pointsJson, route.pointCount, route.totalDistance,
                ownerType, ownerKey, route.publicId
            }
        }
    }

    local ok, committed = pcall(transaction, queries)
    if not ok or committed ~= true then
        return nil, 'database_error'
    end

    local row = RouteRepository.GetByPublicId(route.publicId)
    if row then return 1 end

    local used = RouteRepository.GetQuotaUsed(ownerType, ownerKey)
    if used ~= nil and used >= limit then return 0 end
    return nil, 'insert_not_confirmed'
end

function RouteRepository.GetQuotaUsed(ownerType, ownerKey)
    local rows = query([[
        SELECT used FROM mz_navigation_route_quotas
        WHERE owner_type = ? AND owner_key = ?
        LIMIT 1
    ]], { ownerType, ownerKey })
    return tonumber(rows and rows[1] and rows[1].used)
end

-- Decremento compensatorio. Se falhar, a quota fica conservadora (pode negar
-- antes do limite), nunca libera uma vaga sem ter apagado a rota.
function RouteRepository.ReleaseQuota(ownerType, ownerKey)
    if RouteRepository.QuotaAvailable ~= true then return false end
    local changed = update([[
        UPDATE mz_navigation_route_quotas
        SET used = GREATEST(used - 1, 0), updated_at = CURRENT_TIMESTAMP
        WHERE owner_type = ? AND owner_key = ? AND used > 0
    ]], { ownerType, ownerKey })
    return changed ~= nil
end

function RouteRepository.Update(route, expectedRevision)
    return update([[
        UPDATE mz_navigation_routes
        SET title = ?, description = ?, route_type = ?, visibility = ?,
            is_published = CASE WHEN ? = 'public' THEN is_published ELSE 0 END,
            points_json = ?, point_count = ?, total_distance = ?,
            revision = revision + 1, updated_at = CURRENT_TIMESTAMP
        WHERE public_id = ? AND revision = ?
    ]], {
        route.title, route.description, route.routeType, route.visibility,
        route.visibility,
        route.pointsJson, route.pointCount, route.totalDistance,
        route.publicId, expectedRevision
    })
end

function RouteRepository.SetPublished(publicId, expectedRevision, published)
    return update([[
        UPDATE mz_navigation_routes
        SET is_published = ?, published_at = CASE WHEN ? = 1 THEN CURRENT_TIMESTAMP ELSE published_at END,
            revision = revision + 1, updated_at = CURRENT_TIMESTAMP
        WHERE public_id = ? AND revision = ?
    ]], { published and 1 or 0, published and 1 or 0, publicId, expectedRevision })
end

function RouteRepository.Delete(publicId, expectedRevision)
    return update([[
        DELETE FROM mz_navigation_routes
        WHERE public_id = ? AND revision = ?
    ]], { publicId, expectedRevision })
end

function RouteRepository.CountByCharacter(characterId)
    local rows = query([[
        SELECT COUNT(*) AS total FROM mz_navigation_routes
        WHERE owner_type = 'character' AND owner_character_id = ?
    ]], { characterId })
    return tonumber(rows and rows[1] and rows[1].total) or 0
end

function RouteRepository.CountByOrg(orgCode)
    local rows = query([[
        SELECT COUNT(*) AS total FROM mz_navigation_routes
        WHERE owner_type = 'org' AND owner_org_code = ?
    ]], { orgCode })
    return tonumber(rows and rows[1] and rows[1].total) or 0
end
