/**
 * mz_navigation - store incremental de marcadores locais para a NUI.
 *
 * Recebe somente mensagens do proprio client Lua (navigation:blips:*):
 *   { action, version:1, generation, seq, upserts:[], removes:[] }
 *
 * Regras:
 *   - reset = nova generation; delta = generation atual + seq monotônico;
 *   - id namespaced (`native:` ou `external:`) evita colisao silenciosa;
 *   - DTO estrito: nada de HTML, URL, campos desconhecidos ou numeros infinitos;
 *   - o store e puro: nao conhece DOM, camera, tiles ou servidor.
 *
 * UMD minimo para teste com `node`.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.MZNavBlips = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const VERSION = 1;
  const MAX_UPSERTS = 500;
  const MAX_REMOVES = 500;
  const MAX_WORLD = 20000;
  const MIN_Z = -2000;
  const MAX_Z = 3000;

  const NATIVE_ID = /^native:\d{1,4}:\d{1,9}$/;
  const EXTERNAL_ID = /^external:[A-Za-z0-9_.-]{1,48}:[A-Za-z0-9_.:-]{1,96}$/;

  function isSafeInteger(value) {
    return Number.isSafeInteger(value) && value >= 0;
  }

  function isFiniteNumber(value) {
    return typeof value === "number" && Number.isFinite(value);
  }

  function sanitizeText(value, maxLength) {
    if (typeof value !== "string") return "";
    const cap = Math.max(1, Math.min(120, Math.floor(Number(maxLength) || 80)));
    return value
      .replace(/[\u0000-\u001F\u007F]/g, "")
      .trim()
      .slice(0, cap);
  }

  function clampByte(value, fallback) {
    const number = Number(value);
    if (!Number.isFinite(number)) return fallback;
    return Math.max(0, Math.min(255, Math.floor(number)));
  }

  function layerOfId(id) {
    if (typeof id !== "string") return null;
    if (NATIVE_ID.test(id)) return "native";
    if (EXTERNAL_ID.test(id)) return "external";
    return null;
  }

  function normalizeMarker(raw) {
    if (!raw || typeof raw !== "object") return null;
    if (raw.visibility !== undefined && raw.visibility !== "local") return null;
    const id = typeof raw.id === "string" ? raw.id : "";
    const layer = layerOfId(id);
    if (!layer) return null;

    const x = Number(raw.x);
    const y = Number(raw.y);
    if (!isFiniteNumber(x) || !isFiniteNumber(y)) return null;
    if (Math.abs(x) > MAX_WORLD || Math.abs(y) > MAX_WORLD) return null;

    const sprite = Math.floor(Number(raw.sprite));
    if (!Number.isSafeInteger(sprite) || sprite < 0 || sprite > 9999) return null;

    const marker = {
      id,
      source: layer,
      sprite,
      colour: clampByte(raw.colour, 0),
      alpha: clampByte(raw.alpha, 255),
      x: x + 0,
      y: y + 0,
      label: sanitizeText(raw.label, 80),
      category: /^[A-Za-z0-9_-]{1,24}$/.test(raw.category) ? String(raw.category) : "generic",
      glyph: /^[A-Za-z0-9]$/.test(raw.glyph) ? String(raw.glyph) : "",
      visibility: "local",
    };

    const z = Number(raw.z);
    if (isFiniteNumber(z) && z >= MIN_Z && z <= MAX_Z) marker.z = z + 0;
    return marker;
  }

  function createStore() {
    return {
      generation: -1,
      seq: 0,
      items: new Map(),
    };
  }

  function count(store, layer) {
    if (!store || !(store.items instanceof Map)) return 0;
    if (layer !== "native" && layer !== "external") return store.items.size;
    let total = 0;
    for (const id of store.items.keys()) {
      if (layerOfId(id) === layer) total += 1;
    }
    return total;
  }

  function resetStore(store, generation) {
    store.generation = generation;
    store.seq = 0;
    store.items.clear();
  }

  /**
   * Valida o envelope e aplica o delta. Retorna sempre um resultado explicito;
   * `accepted === false` significa mensagem ignorada (versao/geracao/seq/limite).
   */
  function accept(store, message) {
    const ignored = (reason) => ({
      accepted: false,
      kind: "ignored",
      reason,
      upserts: [],
      removes: [],
    });

    if (!store || !(store.items instanceof Map)) return ignored("store_invalid");
    if (!message || typeof message !== "object") return ignored("message_invalid");
    if (message.version !== VERSION) return ignored("version_invalid");

    const type = message.type || message.action;
    const generation = Number(message.generation);
    if (!isSafeInteger(generation)) return ignored("generation_invalid");

    if (type === "mznav:blips:reset" || type === "navigation:blips:reset") {
      if (generation < store.generation) return ignored("generation_stale");
      resetStore(store, generation);
      return { accepted: true, kind: "reset", upserts: [], removes: [] };
    }

    if (type !== "mznav:blips:delta" && type !== "navigation:blips:delta") {
      return ignored("type_invalid");
    }
    if (generation !== store.generation) return ignored("generation_mismatch");

    const seq = Number(message.seq);
    if (!isSafeInteger(seq) || seq <= store.seq) return ignored("seq_invalid");
    if (!Array.isArray(message.upserts) || !Array.isArray(message.removes)) {
      return ignored("payload_invalid");
    }
    if (message.upserts.length > MAX_UPSERTS || message.removes.length > MAX_REMOVES) {
      return ignored("payload_too_large");
    }

    const acceptedUpserts = new Map();
    for (const raw of message.upserts) {
      const marker = normalizeMarker(raw);
      if (marker) acceptedUpserts.set(marker.id, marker);
    }

    const acceptedRemoves = new Set();
    for (const id of message.removes) {
      if (layerOfId(id)) acceptedRemoves.add(id);
    }

    for (const id of acceptedRemoves) store.items.delete(id);
    for (const [id, marker] of acceptedUpserts) store.items.set(id, marker);
    store.seq = seq;

    return {
      accepted: true,
      kind: "delta",
      upserts: [...acceptedUpserts.values()],
      removes: [...acceptedRemoves],
    };
  }

  function snapshot(store) {
    return store && store.items instanceof Map ? [...store.items.values()] : [];
  }

  return {
    VERSION,
    MAX_UPSERTS,
    MAX_REMOVES,
    NATIVE_ID,
    EXTERNAL_ID,
    sanitizeText,
    layerOfId,
    normalizeMarker,
    createStore,
    resetStore,
    count,
    accept,
    snapshot,
  };
});
