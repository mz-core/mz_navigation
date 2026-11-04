/**
 * mz_navigation - projecao mundo GTA V <-> espaco normalizado do mapa.
 *
 * Esta projecao e afim e local. NAO e um CRS geografico e NAO serve para
 * pathfinding, ETA ou distancia viaria. Distancias devem usar `worldDistance`.
 *
 * UMD minimo para permitir teste com `node tests/projection.test.js`.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = api;
  } else {
    root.MZNavProjection = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const MAP_UNITS = 1000;

  function normalizeBounds(bounds) {
    if (!bounds || typeof bounds !== "object") return null;
    const minX = Number(bounds.minX);
    const maxX = Number(bounds.maxX);
    const minY = Number(bounds.minY);
    const maxY = Number(bounds.maxY);
    if (![minX, maxX, minY, maxY].every(Number.isFinite)) return null;
    if (maxX <= minX || maxY <= minY) return null;
    return { minX, maxX, minY, maxY };
  }

  function worldToUnit(x, y, bounds) {
    const b = normalizeBounds(bounds);
    if (!b) return null;
    const wx = Number(x);
    const wy = Number(y);
    if (!Number.isFinite(wx) || !Number.isFinite(wy)) return null;
    return {
      u: (wx - b.minX) / (b.maxX - b.minX),
      v: (b.maxY - wy) / (b.maxY - b.minY),
    };
  }

  function unitToWorld(u, v, bounds) {
    const b = normalizeBounds(bounds);
    if (!b) return null;
    const nu = Number(u);
    const nv = Number(v);
    if (!Number.isFinite(nu) || !Number.isFinite(nv)) return null;
    return {
      x: b.minX + nu * (b.maxX - b.minX),
      y: b.maxY - nv * (b.maxY - b.minY),
    };
  }

  function worldToMap(x, y, bounds) {
    const unit = worldToUnit(x, y, bounds);
    if (!unit) return null;
    return { mx: unit.u * MAP_UNITS, my: unit.v * MAP_UNITS };
  }

  function mapToWorld(mx, my, bounds) {
    const x = Number(mx);
    const y = Number(my);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
    return unitToWorld(x / MAP_UNITS, y / MAP_UNITS, bounds);
  }

  function clamp(value, min, max) {
    return Math.min(Math.max(value, min), max);
  }

  function worldDistance(a, b) {
    if (!a || !b) return Infinity;
    const dx = Number(a.x) - Number(b.x);
    const dy = Number(a.y) - Number(b.y);
    if (!Number.isFinite(dx) || !Number.isFinite(dy)) return Infinity;
    return Math.sqrt(dx * dx + dy * dy);
  }

  /** Projecao compartilhada pelo atlas estatico local e pelos tiles opcionais. */
  function tilePixel(x, y, zoom, projection) {
    const p = projection || {};
    const scaleX = Number(p.scaleX);
    const offsetX = Number(p.offsetX);
    const scaleY = Number(p.scaleY);
    const offsetY = Number(p.offsetY);
    if (![scaleX, offsetX, scaleY, offsetY].every(Number.isFinite)) return null;
    const zoomScale = Math.pow(2, Number(zoom) || 0);
    return {
      px: zoomScale * (scaleX * Number(x) + offsetX),
      py: zoomScale * (-scaleY * Number(y) + offsetY),
    };
  }

  function tileWorldRect(tileX, tileY, zoom, projection, tileSize) {
    const p = projection || {};
    const size = Number(tileSize) || 256;
    const zoomScale = Math.pow(2, Number(zoom) || 0);
    const scaleX = Number(p.scaleX);
    const scaleY = Number(p.scaleY);
    const offsetX = Number(p.offsetX);
    const offsetY = Number(p.offsetY);
    if (![scaleX, offsetX, scaleY, offsetY].every(Number.isFinite)) return null;
    if (scaleX === 0 || scaleY === 0) return null;

    const left = (Number(tileX) * size) / zoomScale;
    const top = (Number(tileY) * size) / zoomScale;
    const right = ((Number(tileX) + 1) * size) / zoomScale;
    const bottom = ((Number(tileY) + 1) * size) / zoomScale;

    return {
      minX: (left - offsetX) / scaleX,
      maxX: (right - offsetX) / scaleX,
      maxY: (top - offsetY) / -scaleY,
      minY: (bottom - offsetY) / -scaleY,
    };
  }

  function viewport(camera, aspectRatio) {
    const zoom = clamp(Number(camera && camera.zoom) || 1, 1, 5);
    const height = MAP_UNITS / Math.pow(2, zoom - 1);
    const ratio = Number(aspectRatio) > 0 ? Number(aspectRatio) : 1.6;
    const width = height * ratio;
    const centerX = clamp(Number(camera && camera.cx) || MAP_UNITS / 2, 0, MAP_UNITS);
    const centerY = clamp(Number(camera && camera.cy) || MAP_UNITS / 2, 0, MAP_UNITS);
    const halfW = width / 2;
    const halfH = height / 2;
    const cx = width >= MAP_UNITS ? MAP_UNITS / 2 : clamp(centerX, halfW, MAP_UNITS - halfW);
    const cy = height >= MAP_UNITS ? MAP_UNITS / 2 : clamp(centerY, halfH, MAP_UNITS - halfH);
    return { cx, cy, width, height };
  }

  return {
    MAP_UNITS,
    normalizeBounds,
    worldToUnit,
    unitToWorld,
    worldToMap,
    mapToWorld,
    clamp,
    worldDistance,
    tilePixel,
    tileWorldRect,
    viewport,
  };
});
