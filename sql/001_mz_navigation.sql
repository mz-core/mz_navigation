-- mz_navigation - schema canonico.
--
-- O runtime tambem executa CREATE TABLE IF NOT EXISTS em server/repository.lua.
-- Este arquivo existe para provisionamento manual e auditoria de DDL.
-- Nenhum DELETE/DROP/TRUNCATE e executado automaticamente.

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
