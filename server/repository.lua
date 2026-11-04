--[[
    mz_navigation - persistencia (oxmysql, sempre parametrizada).

    Owner: mz_navigation. Nenhum outro resource escreve nestas tabelas.
    Favoritos e recentes sao sempre por character_id canonico, nunca por source.
]]

MZNavigation = MZNavigation or {}
MZNavigation.Repository = MZNavigation.Repository or {}

local Repository = MZNavigation.Repository

Repository.Available = false
Repository.Error = nil

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

function Repository.Prepare()
    if type(MySQL) ~= 'table' or type(MySQL.query) ~= 'table' then
        Repository.Available = false
        Repository.Error = 'oxmysql_unavailable'
        return false, Repository.Error
    end

    local ok, err = pcall(function()
        query([[
            CREATE TABLE IF NOT EXISTS mz_navigation_favorites (
                id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                character_id BIGINT UNSIGNED NOT NULL,
                citizenid VARCHAR(64) NOT NULL,
                label VARCHAR(80) NOT NULL,
                x DOUBLE NOT NULL,
                y DOUBLE NOT NULL,
                z DOUBLE NULL,
                poi_id VARCHAR(96) NULL,
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                UNIQUE KEY uq_mz_navigation_favorites_character_label (character_id, label),
                KEY ix_mz_navigation_favorites_character (character_id, updated_at)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ]])

        query([[
            CREATE TABLE IF NOT EXISTS mz_navigation_recents (
                id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                character_id BIGINT UNSIGNED NOT NULL,
                citizenid VARCHAR(64) NOT NULL,
                label VARCHAR(80) NOT NULL,
                x DOUBLE NOT NULL,
                y DOUBLE NOT NULL,
                z DOUBLE NULL,
                poi_id VARCHAR(96) NULL,
                visited_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                KEY ix_mz_navigation_recents_character (character_id, visited_at),
                KEY ix_mz_navigation_recents_poi (character_id, poi_id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ]])

        query([[
            CREATE TABLE IF NOT EXISTS mz_navigation_audit (
                id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                character_id BIGINT UNSIGNED NULL,
                citizenid VARCHAR(64) NULL,
                action VARCHAR(48) NOT NULL,
                target_id VARCHAR(96) NULL,
                detail VARCHAR(255) NULL,
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                KEY ix_mz_navigation_audit_character (character_id, created_at),
                KEY ix_mz_navigation_audit_action (action, created_at)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        ]])

        if not tableExists('mz_navigation_favorites')
            or not tableExists('mz_navigation_recents') then
            error('schema_not_created')
        end
    end)

    if not ok then
        Repository.Available = false
        Repository.Error = 'schema_unavailable'
        print(('[mz_navigation] database prepare failed: %s'):format(tostring(err)))
        return false, Repository.Error
    end

    Repository.Available = true
    Repository.Error = nil
    return true
end

function Repository.Audit(characterId, citizenid, action, targetId, detail)
    if Repository.Available ~= true then return end
    pcall(function()
        insert([[
            INSERT INTO mz_navigation_audit (character_id, citizenid, action, target_id, detail)
            VALUES (?, ?, ?, ?, ?)
        ]], {
            characterId, citizenid,
            tostring(action or ''):sub(1, 48),
            targetId and tostring(targetId):sub(1, 96) or nil,
            detail and tostring(detail):sub(1, 255) or nil
        })
    end)
end

function Repository.ListFavorites(characterId, limit)
    return query([[
        SELECT id, label, x, y, z, poi_id, created_at, updated_at
        FROM mz_navigation_favorites
        WHERE character_id = ?
        ORDER BY updated_at DESC, id DESC
        LIMIT ?
    ]], { characterId, limit })
end

function Repository.FindFavoriteByLabel(characterId, label)
    local rows = query([[
        SELECT id, label, x, y, z, poi_id, created_at, updated_at
        FROM mz_navigation_favorites
        WHERE character_id = ? AND label = ?
        LIMIT 1
    ]], { characterId, label })
    return rows and rows[1] or nil
end

function Repository.CountFavorites(characterId)
    local rows = query([[
        SELECT COUNT(*) AS total FROM mz_navigation_favorites WHERE character_id = ?
    ]], { characterId })
    return tonumber(rows and rows[1] and rows[1].total) or 0
end

function Repository.UpsertFavorite(characterId, citizenid, favorite)
    update([[
        INSERT INTO mz_navigation_favorites (character_id, citizenid, label, x, y, z, poi_id)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            citizenid = ?,
            x = ?, y = ?, z = ?, poi_id = ?, updated_at = CURRENT_TIMESTAMP
    ]], {
        characterId, citizenid, favorite.label, favorite.x, favorite.y, favorite.z, favorite.poiId,
        citizenid, favorite.x, favorite.y, favorite.z, favorite.poiId
    })

    local rows = query([[
        SELECT id, label, x, y, z, poi_id, created_at, updated_at
        FROM mz_navigation_favorites
        WHERE character_id = ? AND label = ?
        LIMIT 1
    ]], { characterId, favorite.label })
    return rows and rows[1] or nil
end

function Repository.RemoveFavorite(characterId, favoriteId)
    local affected = update([[
        DELETE FROM mz_navigation_favorites WHERE character_id = ? AND id = ?
    ]], { characterId, favoriteId })
    return (tonumber(affected) or 0) > 0
end

function Repository.ListRecents(characterId, limit)
    return query([[
        SELECT id, label, x, y, z, poi_id, visited_at
        FROM mz_navigation_recents
        WHERE character_id = ?
        ORDER BY visited_at DESC, id DESC
        LIMIT ?
    ]], { characterId, limit })
end

function Repository.AddRecent(characterId, citizenid, recent, keep)
    local deleteQuery, deleteParams
    if recent.poiId then
        deleteQuery = 'DELETE FROM mz_navigation_recents WHERE character_id = ? AND poi_id = ?'
        deleteParams = { characterId, recent.poiId }
    else
        deleteQuery = 'DELETE FROM mz_navigation_recents WHERE character_id = ? AND label = ?'
        deleteParams = { characterId, recent.label }
    end

    local ok = pcall(function()
        MySQL.transaction.await({
            { query = deleteQuery, values = deleteParams },
            {
                query = [[
                    INSERT INTO mz_navigation_recents (character_id, citizenid, label, x, y, z, poi_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                ]],
                values = { characterId, citizenid, recent.label, recent.x, recent.y, recent.z, recent.poiId }
            },
            {
                query = [[
                    DELETE FROM mz_navigation_recents
                    WHERE character_id = ? AND id NOT IN (
                        SELECT id FROM (
                            SELECT id FROM mz_navigation_recents
                            WHERE character_id = ?
                            ORDER BY visited_at DESC, id DESC
                            LIMIT ?
                        ) AS keep_rows
                    )
                ]],
                values = { characterId, characterId, keep }
            }
        })
    end)

    return ok
end
