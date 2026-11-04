-- mz_navigation - Wave 4C - quota transacional de rotas.
--
-- APLICACAO MANUAL. Requer a migration 002 ja aplicada.
-- O runtime NAO executa este arquivo automaticamente.
--
-- Objetivo:
--   serializar CREATE por owner (character/org) no InnoDB e impedir que duas
--   requisicoes concorrentes ultrapassem MaxRoutesPerCharacter/MaxRoutesPerOrg.
--
-- Sem esta tabela:
--   - leitura, editor de rotas existentes, update/delete/publish continuam;
--   - CREATE de rota falha fechado com `quota_unavailable`;
--   - o mapa, favoritos, MZ Maps e Move continuam funcionando.
--
-- Idempotente: CREATE TABLE IF NOT EXISTS + INSERT IGNORE.
-- Aplicar com o resource parado/manualmente, em janela controlada.
--
-- Rollback manual (somente com autorizacao e backup):
--   DROP TABLE IF EXISTS mz_navigation_route_quotas;
--   DELETE FROM mz_navigation_schema_migrations WHERE version = 3;

CREATE TABLE IF NOT EXISTS mz_navigation_route_quotas (
    owner_type VARCHAR(16) NOT NULL,
    owner_key VARCHAR(128) NOT NULL,
    used INT UNSIGNED NOT NULL DEFAULT 0,
    last_token VARCHAR(64) NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (owner_type, owner_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Backfill a partir das rotas existentes. INSERT IGNORE evita sobrescrever
-- contadores de uma aplicacao parcial; se a tabela for recriada, o backfill
-- volta a ser integral. Nao executar com creates concorrentes em andamento.
INSERT IGNORE INTO mz_navigation_route_quotas (owner_type, owner_key, used)
SELECT owner_type,
       CASE
           WHEN owner_type = 'character' THEN CAST(owner_character_id AS CHAR)
           ELSE owner_org_code
       END AS owner_key,
       COUNT(*) AS used
FROM mz_navigation_routes
WHERE (owner_type = 'character' AND owner_character_id IS NOT NULL)
   OR (owner_type = 'org' AND owner_org_code IS NOT NULL AND owner_org_code <> '')
GROUP BY owner_type,
         CASE
             WHEN owner_type = 'character' THEN CAST(owner_character_id AS CHAR)
             ELSE owner_org_code
         END;

INSERT IGNORE INTO mz_navigation_schema_migrations (version, name)
VALUES (3, 'wave4c_route_quota');
