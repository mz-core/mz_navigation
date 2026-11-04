-- mz_navigation - Wave 4A - rotas autoradas.
--
-- APLICACAO MANUAL. O resource NAO executa este arquivo automaticamente.
-- Sem a tabela, o editor falha fechado (`routes_unavailable`) e o mapa continua.
-- Idempotente: apenas CREATE TABLE IF NOT EXISTS.
--
-- Rollback manual (somente com autorizacao e backup):
--   DROP TABLE IF EXISTS mz_navigation_routes;
--   DROP TABLE IF EXISTS mz_navigation_schema_migrations;
--
-- Nao ha FK cross-domain. Owner e character OU org, nunca source.

CREATE TABLE IF NOT EXISTS mz_navigation_schema_migrations (
    version INT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(96) NOT NULL,
    applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS mz_navigation_routes (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    public_id VARCHAR(48) NOT NULL,
    owner_type VARCHAR(16) NOT NULL,
    owner_character_id BIGINT UNSIGNED NULL,
    owner_org_code VARCHAR(64) NULL,
    title VARCHAR(80) NOT NULL,
    description VARCHAR(300) NOT NULL DEFAULT '',
    route_type VARCHAR(24) NOT NULL DEFAULT 'generic',
    visibility VARCHAR(16) NOT NULL DEFAULT 'character',
    schema_version INT UNSIGNED NOT NULL DEFAULT 1,
    revision INT UNSIGNED NOT NULL DEFAULT 1,
    points_json LONGTEXT NOT NULL,
    point_count INT UNSIGNED NOT NULL,
    total_distance DOUBLE NOT NULL,
    is_published TINYINT(1) NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    published_at TIMESTAMP NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_mz_navigation_routes_public_id (public_id),
    KEY ix_mz_navigation_routes_character (owner_character_id, updated_at),
    KEY ix_mz_navigation_routes_org (owner_org_code, updated_at),
    KEY ix_mz_navigation_routes_public (visibility, is_published, updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT IGNORE INTO mz_navigation_schema_migrations (version, name)
VALUES (2, 'wave4a_routes');
