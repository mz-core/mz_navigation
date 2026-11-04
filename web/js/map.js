/**
 * mz_navigation - superficie SVG do mapa.
 *
 * Responsabilidades:
 *   - projecao e camera (pan/zoom) sem re-renderizar marcadores;
 *   - atlas local opaco, grid e distritos;
 *   - tiles opcionais quando um atlas licenciado estiver presente;
 *   - hit-test de POIs e clique livre.
 *
 * Sem innerHTML com dados de servidor: tudo e criado via DOM/SVG API.
 */
(function () {
  "use strict";

  const P = window.MZNavProjection;
  const SVG_NS = "http://www.w3.org/2000/svg";
  const MIN_ZOOM = 1;
  const MAX_ZOOM = 5;
  const BASE_MAP_HREF = "assets/los-santos-atlas.webp";

  const DISTRICTS = [
    { label: "LOS SANTOS", x: 120, y: -950, size: 10 },
    { label: "VINEWOOD", x: 320, y: 400, size: 9 },
    { label: "DEL PERRO", x: -1650, y: -1150, size: 8 },
    { label: "SANDY SHORES", x: 1750, y: 3500, size: 9 },
    { label: "PALETO BAY", x: -280, y: 6500, size: 9 },
    { label: "GRAPESEED", x: 1750, y: 4900, size: 8 },
    { label: "MONTE CHILIAD", x: 450, y: 5566, size: 8 },
  ];

  const LAYER_TONES = [
    "#6ee7b7",
    "#93c5fd",
    "#fcd34d",
    "#f9a8d4",
    "#c4b5fd",
    "#fdba74",
    "#7dd3fc",
  ];

  // Catalogo seguro sprite/categoria -> glifo local. Nenhum PNG/radar de
  // terceiros e carregado; o texto e desenhado com textContent.
  const BLIP_GLYPHS = {
    clothing: "R",
    tattoo: "T",
    garage: "G",
    fuel: "C",
  };
  const BLIP_TONES = {
    73: "#f9a8d4",
    75: "#c4b5fd",
    357: "#6ee7b7",
    361: "#fcd34d",
  };
  const POLICE_TONES = {
    car: "#7dd3fc",
    moto: "#fcd34d",
    helicopter: "#c4b5fd",
    boat: "#6ee7b7",
    plane: "#fdba74",
    generic: "#93c5fd",
  };

  const REGIONS = [
    { label: "metro", x: 0, y: -1200, rx: 1700, ry: 1500 },
    { label: "hills", x: 400, y: 500, rx: 900, ry: 700 },
    { label: "desert", x: 1600, y: 3400, rx: 800, ry: 650 },
    { label: "north", x: -250, y: 6300, rx: 700, ry: 600 },
    { label: "peak", x: 450, y: 5566, rx: 480, ry: 480 },
  ];

  function renderRegions() {
    const group = MAP.groups.regions;
    if (!group) return;
    group.replaceChildren();
    if (!MAP.bounds) return;

    const b = MAP.bounds;
    const sx = P.MAP_UNITS / (b.maxX - b.minX);
    const sy = P.MAP_UNITS / (b.maxY - b.minY);

    REGIONS.forEach((region) => {
      const point = P.worldToMap(region.x, region.y, MAP.bounds);
      if (!point) return;
      group.appendChild(
        svgEl("ellipse", {
          cx: point.mx,
          cy: point.my,
          rx: region.rx * sx,
          ry: region.ry * sy,
          class: "nav-region",
        }),
      );
    });
  }

  const MAP = {
    svg: null,
    groups: {},
    config: null,
    bounds: null,
    markers: [],
    layers: new Map(),
    visibleLayers: new Set(),
    localMarkers: { native: new Map(), external: new Map() },
    localNodes: new Map(),
    policeMarkers: new Map(),
    policeNodes: new Map(),
    camera: { cx: 500, cy: 500, zoom: 2 },
    selected: null,
    routePoints: [],
    routeSelected: -1,
    tileZoom: null,
    drag: null,
    moved: false,
    callbacks: {},
    observer: null,
    frame: 0,
    tileFailures: new Set(),
  };

  function svgEl(tag, attrs) {
    const node = document.createElementNS(SVG_NS, tag);
    if (attrs) {
      Object.keys(attrs).forEach((key) => node.setAttribute(key, String(attrs[key])));
    }
    return node;
  }

  function assetHref(path) {
    const value = String(path || "");
    if (/^(?:https?:|data:|blob:)/i.test(value)) return value;
    const base = String(MAP.config?.assetBase || "").replace(/\/$/, "");
    return base ? `${base}/${value.replace(/^\//, "")}` : value;
  }

  function layerTone(layerId) {
    if (!layerId) return LAYER_TONES[0];
    let hash = 0;
    for (let index = 0; index < layerId.length; index += 1) {
      hash = (hash * 31 + layerId.charCodeAt(index)) % 9973;
    }
    return LAYER_TONES[hash % LAYER_TONES.length];
  }

  function aspectRatio() {
    const rect = MAP.svg.getBoundingClientRect();
    if (!rect.height) return 1.6;
    return Math.max(0.6, rect.width / rect.height);
  }

  function currentViewport() {
    return P.viewport(MAP.camera, aspectRatio());
  }

  function applyViewBox() {
    const view = currentViewport();
    MAP.camera.cx = view.cx;
    MAP.camera.cy = view.cy;
    MAP.svg.setAttribute(
      "viewBox",
      `${view.cx - view.width / 2} ${view.cy - view.height / 2} ${view.width} ${view.height}`,
    );
    const zoomLevel = Math.round(MAP.camera.zoom);
    if (MAP.svg.dataset.zoomLevel !== String(zoomLevel)) {
      MAP.svg.dataset.zoomLevel = String(zoomLevel);
      renderDistricts();
      renderMarkers();
      renderCandidate();
      renderRoute();
      refreshLocalMarkerScale();
      refreshPoliceMarkerScale();
    }
    if (MAP.config && MAP.config.tiles && MAP.config.tiles.enabled) {
      const nextTileZoom = Math.max(0, Math.min(MAP.config.tiles.maxZoom, zoomLevel - 1));
      if (nextTileZoom !== MAP.tileZoom) {
        MAP.tileZoom = nextTileZoom;
        renderTiles();
      }
    }
    if (typeof MAP.callbacks.onCamera === "function") {
      MAP.callbacks.onCamera({ ...MAP.camera });
    }
  }

  function requestFrame() {
    if (MAP.frame) return;
    MAP.frame = window.requestAnimationFrame(() => {
      MAP.frame = 0;
      applyViewBox();
    });
  }

  function screenToMap(clientX, clientY) {
    const rect = MAP.svg.getBoundingClientRect();
    const view = currentViewport();
    const nx = (clientX - rect.left) / Math.max(1, rect.width);
    const ny = (clientY - rect.top) / Math.max(1, rect.height);
    return {
      mx: view.cx - view.width / 2 + nx * view.width,
      my: view.cy - view.height / 2 + ny * view.height,
    };
  }

  function renderBaseMap() {
    const group = MAP.groups.base;
    if (!group) return;
    group.replaceChildren();
    if (!MAP.bounds || !MAP.config?.tiles?.projection) return;

    const rect = P.tileWorldRect(
      0,
      0,
      0,
      MAP.config.tiles.projection,
      MAP.config.tiles.tileSize || 256,
    );
    if (!rect) return;

    const topLeft = P.worldToMap(rect.minX, rect.maxY, MAP.bounds);
    const bottomRight = P.worldToMap(rect.maxX, rect.minY, MAP.bounds);
    if (!topLeft || !bottomRight) return;

    const x = Math.min(topLeft.mx, bottomRight.mx);
    const y = Math.min(topLeft.my, bottomRight.my);
    const width = Math.abs(bottomRight.mx - topLeft.mx);
    const height = Math.abs(bottomRight.my - topLeft.my);
    group.appendChild(svgEl("image", {
      href: assetHref(MAP.config.baseMapPath || BASE_MAP_HREF),
      x,
      y,
      width,
      height,
      preserveAspectRatio: "none",
      class: "nav-base-map",
      "aria-hidden": "true",
    }));
    group.appendChild(svgEl("rect", {
      x,
      y,
      width,
      height,
      class: "nav-base-shade",
    }));
  }

  function renderGrid() {
    const group = MAP.groups.grid;
    group.replaceChildren();
    const units = P.MAP_UNITS;

    for (let value = 0; value <= units; value += 50) {
      const major = value % 200 === 0;
      const stroke = svgEl("line", {
        x1: value,
        y1: 0,
        x2: value,
        y2: units,
        class: major ? "nav-grid-line nav-grid-line--major" : "nav-grid-line",
      });
      group.appendChild(stroke);
      const horizontal = svgEl("line", {
        x1: 0,
        y1: value,
        x2: units,
        y2: value,
        class: major ? "nav-grid-line nav-grid-line--major" : "nav-grid-line",
      });
      group.appendChild(horizontal);
    }

    [
      { label: "N", x: units / 2, y: 16 },
      { label: "S", x: units / 2, y: units - 8 },
      { label: "O", x: 10, y: units / 2 },
      { label: "L", x: units - 16, y: units / 2 },
    ].forEach((item) => {
      const text = svgEl("text", {
        x: item.x,
        y: item.y,
        class: "nav-cardinal",
        "text-anchor": "middle",
      });
      text.textContent = item.label;
      group.appendChild(text);
    });
  }

  function renderDistricts() {
    const group = MAP.groups.districts;
    group.replaceChildren();
    if (!MAP.bounds) return;
    const k = markerScale();

    DISTRICTS.forEach((district) => {
      const point = P.worldToMap(district.x, district.y, MAP.bounds);
      if (!point) return;
      const text = svgEl("text", {
        x: point.mx,
        y: point.my,
        class: "nav-district",
        "font-size": district.size * k,
        "text-anchor": "middle",
      });
      text.textContent = district.label;
      group.appendChild(text);
    });
  }

  function markerScale() {
    const view = currentViewport();
    const rect = MAP.svg.getBoundingClientRect();
    return view.width / Math.max(1, rect.width);
  }

  function markerLabelVisible() {
    const level = Number(MAP.svg.dataset.zoomLevel || Math.round(MAP.camera.zoom) || 1);
    return level >= 4;
  }

  function renderMarkers() {
    const group = MAP.groups.pois;
    group.replaceChildren();
    if (!MAP.bounds) return;

    const k = markerScale();
    const visible = MAP.markers.filter((poi) => MAP.visibleLayers.has(poi.layer));
    const showLabel = markerLabelVisible();

    visible.forEach((poi) => {
      const point = P.worldToMap(poi.x, poi.y, MAP.bounds);
      if (!point) return;
      const tone = layerTone(poi.layer);
      const node = svgEl("g", {
        class: "nav-poi",
        "data-poi-id": poi.id,
        transform: `translate(${point.mx} ${point.my})`,
        tabindex: "0",
        role: "button",
        "aria-label": poi.label,
      });
      node.appendChild(
        svgEl("circle", { r: 12 * k, class: "nav-poi-hit" }),
      );
      node.appendChild(
        svgEl("circle", { r: 5 * k, class: "nav-poi-dot", fill: tone }),
      );
      if (showLabel) {
        const text = svgEl("text", {
          x: 8 * k, y: 4 * k, class: "nav-poi-label",
          "font-size": 11 * k, "stroke-width": 3 * k,
        });
        text.textContent = poi.label;
        node.appendChild(text);
      }
      group.appendChild(node);
    });
  }

  function renderRoute() {
    const group = MAP.groups.route;
    if (!group) return;
    group.replaceChildren();
    if (!MAP.bounds || !MAP.routePoints.length) return;

    const k = markerScale();
    const mapped = MAP.routePoints
      .map((point) => P.worldToMap(point.x, point.y, MAP.bounds))
      .filter(Boolean);
    if (!mapped.length) return;

    if (mapped.length >= 2) {
      group.appendChild(svgEl("polyline", {
        points: mapped.map((point) => `${point.mx},${point.my}`).join(" "),
        class: "nav-route-line nav-route-line--casing",
      }));
      const line = svgEl("polyline", {
        points: mapped.map((point) => `${point.mx},${point.my}`).join(" "),
        class: "nav-route-line",
      });
      group.appendChild(line);
    }

    mapped.forEach((point, index) => {
      const active = index === MAP.routeSelected;
      const node = svgEl("g", {
        class: active ? "nav-route-point is-selected" : "nav-route-point",
        transform: `translate(${point.mx} ${point.my})`,
      });
      node.appendChild(
        svgEl("circle", {
          r: (active ? 9 : 7) * k,
          class: active ? "nav-route-point-bg is-selected" : "nav-route-point-bg",
        }),
      );
      const label = svgEl("text", {
        x: 0,
        y: 2.6 * k,
        class: "nav-route-point-label",
        "text-anchor": "middle",
        "font-size": 7 * k,
      });
      label.textContent = String(index + 1);
      node.appendChild(label);
      group.appendChild(node);
    });
  }

  function setRoutePoints(points, selectedIndex) {
    MAP.routePoints = Array.isArray(points) ? points.filter(Boolean) : [];
    MAP.routeSelected = Number.isInteger(selectedIndex) ? selectedIndex : -1;
    renderRoute();
  }

  function setRouteSelected(index) {
    MAP.routeSelected = Number.isInteger(index) ? index : -1;
    renderRoute();
  }

  function renderCandidate() {
    const group = MAP.groups.candidate;
    group.replaceChildren();
    if (!MAP.selected || !MAP.bounds) return;
    const k = markerScale();

    const point = P.worldToMap(MAP.selected.x, MAP.selected.y, MAP.bounds);
    if (!point) return;

    const node = svgEl("g", {
      class: "nav-candidate",
      transform: `translate(${point.mx} ${point.my})`,
    });
    node.appendChild(svgEl("circle", { r: 12 * k, class: "nav-candidate-ring" }));
    node.appendChild(svgEl("circle", { r: 5 * k, class: "nav-candidate-dot" }));
    node.appendChild(svgEl("line", { x1: -20 * k, y1: 0, x2: -9 * k, y2: 0, class: "nav-candidate-cross" }));
    node.appendChild(svgEl("line", { x1: 9 * k, y1: 0, x2: 20 * k, y2: 0, class: "nav-candidate-cross" }));
    node.appendChild(svgEl("line", { x1: 0, y1: -20 * k, x2: 0, y2: -9 * k, class: "nav-candidate-cross" }));
    node.appendChild(svgEl("line", { x1: 0, y1: 9 * k, x2: 0, y2: 20 * k, class: "nav-candidate-cross" }));

    const label = svgEl("text", {
      x: 0, y: -22 * k, class: "nav-candidate-label",
      "text-anchor": "middle", "font-size": 11 * k, "stroke-width": 3 * k,
    });
    label.textContent = MAP.selected.label || "Destino";
    node.appendChild(label);
    group.appendChild(node);
  }

  function renderTiles() {
    const group = MAP.groups.tiles;
    group.replaceChildren();
    const config = MAP.config;
    if (!config || !config.tiles || !config.tiles.enabled || !MAP.bounds) return;

    const tileZoom = MAP.tileZoom;
    if (tileZoom === null) return;

    const maxTile = Math.pow(2, tileZoom);
    const view = currentViewport();
    const padding = 1;
    const minMapX = view.cx - view.width / 2;
    const maxMapX = view.cx + view.width / 2;
    const minMapY = view.cy - view.height / 2;
    const maxMapY = view.cy + view.height / 2;

    let rendered = 0;
    for (let ty = 0; ty < maxTile; ty += 1) {
      for (let tx = 0; tx < maxTile; tx += 1) {
        const rect = P.tileWorldRect(tx, ty, tileZoom, config.tiles.projection, config.tiles.tileSize);
        if (!rect) continue;

        const topLeft = P.worldToMap(rect.minX, rect.maxY, MAP.bounds);
        const bottomRight = P.worldToMap(rect.maxX, rect.minY, MAP.bounds);
        if (!topLeft || !bottomRight) continue;

        const x = Math.min(topLeft.mx, bottomRight.mx) - padding;
        const y = Math.min(topLeft.my, bottomRight.my) - padding;
        const width = Math.abs(bottomRight.mx - topLeft.mx) + padding * 2;
        const height = Math.abs(bottomRight.my - topLeft.my) + padding * 2;

        if (x + width < minMapX || x > maxMapX || y + height < minMapY || y > maxMapY) continue;
        if (rendered >= 256) break;

        const key = `${tileZoom}/${tx}/${ty}`;
        if (MAP.tileFailures.has(key)) continue;

        const href = assetHref(`${config.tiles.path}/${tileZoom}/${tx}/${ty}.jpg`);
        const image = svgEl("image", {
          href,
          x,
          y,
          width,
          height,
          preserveAspectRatio: "none",
          class: "nav-tile",
        });
        image.addEventListener(
          "error",
          () => {
            MAP.tileFailures.add(key);
          },
          { once: true },
        );
        group.appendChild(image);
        rendered += 1;
      }
    }
  }

  function select(selection) {
    MAP.selected = selection || null;
    renderCandidate();
  }

  function localLayerOfId(id) {
    if (typeof id !== "string") return null;
    if (id.indexOf("native:") === 0) return "native";
    if (id.indexOf("external:") === 0) return "external";
    return null;
  }

  function localGroup(layer) {
    return layer === "external" ? MAP.groups.externalMarkers : MAP.groups.nativeBlips;
  }

  function localTone(marker) {
    const sprite = Number(marker && marker.sprite);
    if (Number.isFinite(sprite) && Object.prototype.hasOwnProperty.call(BLIP_TONES, sprite)) {
      return BLIP_TONES[sprite];
    }
    return marker && marker.source === "external" ? "#93c5fd" : "#6ee7b7";
  }

  function localGlyph(marker) {
    if (marker && /^[A-Za-z0-9]$/.test(marker.glyph || "")) return marker.glyph;
    if (marker && Object.prototype.hasOwnProperty.call(BLIP_GLYPHS, marker.category)) {
      return BLIP_GLYPHS[marker.category];
    }
    const label = marker && typeof marker.label === "string" ? marker.label.trim() : "";
    return label ? label.charAt(0).toUpperCase() : "\u2022";
  }

  function createLocalNode(marker, layer) {
    const node = svgEl("g", {
      class: `nav-blip nav-blip--${layer}`,
      "data-marker-id": marker.id,
      "data-layer": layer,
      "aria-hidden": "true",
      "pointer-events": "none",
    });
    const ring = svgEl("circle", {
      class: "nav-blip-ring",
      fill: "none",
      stroke: localTone(marker),
      "stroke-width": 1.4,
      "vector-effect": "non-scaling-stroke",
    });
    const dot = svgEl("circle", {
      class: "nav-blip-dot",
      fill: localTone(marker),
      "vector-effect": "non-scaling-stroke",
    });
    const glyph = svgEl("text", {
      class: "nav-blip-glyph",
      "text-anchor": "middle",
      fill: "#0b0f15",
    });
    glyph.textContent = localGlyph(marker);
    const label = svgEl("text", {
      class: "nav-blip-label",
      "text-anchor": "start",
      "paint-order": "stroke",
      stroke: "rgba(11, 15, 21, 0.9)",
    });
    label.textContent = marker.label || "";
    node.appendChild(ring);
    node.appendChild(dot);
    node.appendChild(glyph);
    node.appendChild(label);
    node.__parts = { ring, dot, glyph, label };
    return node;
  }

  function updateLocalNode(node, marker, scale) {
    if (!node || !marker) return;
    const point = P.worldToMap(marker.x, marker.y, MAP.bounds);
    if (!point) return;
    const k = scale;
    const tone = localTone(marker);
    node.setAttribute("transform", `translate(${point.mx} ${point.my})`);
    node.setAttribute("data-sprite", String(marker.sprite));
    const alpha = Number.isFinite(Number(marker.alpha)) ? Number(marker.alpha) : 255;
    node.style.opacity = String(Math.max(0, Math.min(1, alpha / 255)));
    const parts = node.__parts || {};
    if (parts.ring) {
      parts.ring.setAttribute("r", String(9 * k));
      parts.ring.setAttribute("stroke", tone);
    }
    if (parts.dot) parts.dot.setAttribute("r", String(4.5 * k));
    if (parts.glyph) {
      parts.glyph.setAttribute("y", String(2.4 * k));
      parts.glyph.setAttribute("font-size", String(6 * k));
      parts.glyph.textContent = localGlyph(marker);
    }
    if (parts.label) {
      parts.label.setAttribute("x", String(8 * k));
      parts.label.setAttribute("y", String(3.4 * k));
      parts.label.setAttribute("font-size", String(10 * k));
      parts.label.setAttribute("stroke-width", String(3 * k));
      parts.label.setAttribute("display", markerLabelVisible() ? "inline" : "none");
      parts.label.textContent = marker.label || "";
    }
  }

  function applyLocalVisibility() {
    const nativeVisible = MAP.visibleLayers.has("local_native") || MAP.visibleLayers.has("native");
    const native = MAP.groups.nativeBlips;
    if (native) native.style.display = nativeVisible ? "" : "none";
    const externalVisible = MAP.visibleLayers.has("local_external") || MAP.visibleLayers.has("external");
    const external = MAP.groups.externalMarkers;
    if (external) external.style.display = externalVisible ? "" : "none";
  }

  /**
   * Atualizacao incremental: somente ids alterados tocam o DOM. Nao mexe em
   * camera, tiles, base map, rota, candidato ou POIs interativos.
   */
  function applyMarkerDelta(upserts, removes) {
    const layerRemoves = Array.isArray(removes) ? removes : [];
    const layerUpserts = Array.isArray(upserts) ? upserts : [];

    for (const id of layerRemoves) {
      const node = MAP.localNodes.get(id);
      if (node) {
        node.remove();
        MAP.localNodes.delete(id);
      }
      const layer = localLayerOfId(id);
      if (layer) MAP.localMarkers[layer].delete(id);
    }

    const scale = MAP.bounds && MAP.svg ? markerScale() : 1;
    for (const marker of layerUpserts) {
      if (!marker || typeof marker.id !== "string") continue;
      if (!Number.isFinite(Number(marker.x)) || !Number.isFinite(Number(marker.y))) continue;
      const layer = localLayerOfId(marker.id);
      if (!layer) continue;
      MAP.localMarkers[layer].set(marker.id, marker);
      if (!MAP.bounds || !MAP.svg) continue;

      let node = MAP.localNodes.get(marker.id);
      if (!node) {
        node = createLocalNode(marker, layer);
        MAP.localNodes.set(marker.id, node);
        const group = localGroup(layer);
        if (group) group.appendChild(node);
      }
      updateLocalNode(node, marker, scale);
    }
    applyLocalVisibility();
  }

  function clearLocalMarkers(layer) {
    for (const [id, node] of [...MAP.localNodes]) {
      if (layer && localLayerOfId(id) !== layer) continue;
      node.remove();
      MAP.localNodes.delete(id);
    }
    if (layer) {
      if (MAP.localMarkers[layer]) MAP.localMarkers[layer].clear();
    } else {
      MAP.localMarkers.native.clear();
      MAP.localMarkers.external.clear();
    }
  }

  function renderLocalMarkers() {
    for (const node of MAP.localNodes.values()) node.remove();
    MAP.localNodes.clear();
    if (!MAP.bounds || !MAP.svg) return;
    ["native", "external"].forEach((layer) => {
      const group = localGroup(layer);
      if (!group) return;
      group.replaceChildren();
      const scale = markerScale();
      for (const [id, marker] of MAP.localMarkers[layer]) {
        const node = createLocalNode(marker, layer);
        MAP.localNodes.set(id, node);
        group.appendChild(node);
        updateLocalNode(node, marker, scale);
      }
    });
    applyLocalVisibility();
  }

  function refreshLocalMarkerScale() {
    if (!MAP.bounds || !MAP.svg) return;
    const scale = markerScale();
    for (const [id, node] of MAP.localNodes) {
      const layer = localLayerOfId(id);
      const marker = layer && MAP.localMarkers[layer].get(id);
      if (marker) updateLocalNode(node, marker, scale);
    }
  }

  function policeGroup() {
    return MAP.groups.police;
  }

  function policeTone(unit) {
    return POLICE_TONES[unit && unit.category] || POLICE_TONES.generic;
  }

  function createPoliceNode(unit, scale) {
    const k = scale;
    const node = svgEl("g", {
      class: `nav-police-unit nav-police-unit--${unit.category || "generic"}`,
      "data-unit-id": unit.id,
      "data-plate": unit.plate || "",
      "data-status": unit.status || "active",
      role: "button",
      tabindex: "0",
      "aria-label": unit.label || unit.plate || unit.unitId || "Viatura",
      "pointer-events": "all",
    });
    const hit = svgEl("circle", { class: "nav-police-hit", r: 14 * k, fill: "transparent" });
    const arrow = svgEl("path", {
      class: "nav-police-arrow",
      d: "M0,-9 L6,7 L0,3 L-6,7 Z",
      fill: policeTone(unit),
      stroke: "rgba(8, 13, 17, 0.95)",
      "stroke-width": 1.2,
      "stroke-linejoin": "round",
      "vector-effect": "non-scaling-stroke",
    });
    const dot = svgEl("circle", {
      class: "nav-police-dot",
      r: 2.2 * k,
      fill: "#0b0f15",
    });
    const label = svgEl("text", {
      class: "nav-police-label",
      x: 9 * k,
      y: 3.5 * k,
      "font-size": 10 * k,
      "text-anchor": "start",
      "paint-order": "stroke",
      stroke: "rgba(11, 15, 21, 0.92)",
      "stroke-width": 3 * k,
    });
    label.textContent = unit.plate || unit.unitId || "Viatura";
    node.appendChild(hit);
    node.appendChild(arrow);
    node.appendChild(dot);
    node.appendChild(label);
    node.__parts = { hit, arrow, dot, label };
    return node;
  }

  function updatePoliceNode(node, unit, scale) {
    if (!node || !unit) return;
    const point = P.worldToMap(unit.x, unit.y, MAP.bounds);
    if (!point) return;
    const k = scale;
    const heading = Number.isFinite(Number(unit.heading)) ? Number(unit.heading) : 0;
    node.setAttribute("transform", `translate(${point.mx} ${point.my})`);
    node.setAttribute("data-status", unit.status || "active");
    node.setAttribute("data-plate", unit.plate || "");
    node.setAttribute("aria-label", unit.label || unit.plate || unit.unitId || "Viatura");
    const parts = node.__parts || {};
    if (parts.arrow) {
      parts.arrow.setAttribute("transform", `rotate(${heading.toFixed(1)})`);
      parts.arrow.setAttribute("fill", policeTone(unit));
    }
    if (parts.hit) parts.hit.setAttribute("r", String(14 * k));
    if (parts.dot) parts.dot.setAttribute("r", String(2.2 * k));
    if (parts.label) {
      parts.label.setAttribute("x", String(9 * k));
      parts.label.setAttribute("y", String(3.5 * k));
      parts.label.setAttribute("font-size", String(10 * k));
      parts.label.setAttribute("stroke-width", String(3 * k));
      parts.label.setAttribute("display", markerLabelVisible() ? "inline" : "none");
      parts.label.textContent = unit.plate || unit.unitId || "Viatura";
    }
    node.style.opacity = unit.status === "stale" ? "0.55" : unit.status === "offduty" ? "0.35" : "1";
  }

  function clearPoliceMarkers() {
    for (const node of MAP.policeNodes.values()) node.remove();
    MAP.policeNodes.clear();
    MAP.policeMarkers.clear();
  }

  function applyPoliceDelta(upserts, removes) {
    const group = policeGroup();
    const removed = Array.isArray(removes) ? removes : [];
    const changed = Array.isArray(upserts) ? upserts : [];
    for (const id of removed) {
      const node = MAP.policeNodes.get(id);
      if (node) node.remove();
      MAP.policeNodes.delete(id);
      MAP.policeMarkers.delete(id);
    }
    const scale = MAP.bounds && MAP.svg ? markerScale() : 1;
    for (const unit of changed) {
      if (!unit || typeof unit.id !== "string") continue;
      if (!Number.isFinite(Number(unit.x)) || !Number.isFinite(Number(unit.y))) continue;
      MAP.policeMarkers.set(unit.id, unit);
      if (!MAP.bounds || !MAP.svg || !group) continue;
      let node = MAP.policeNodes.get(unit.id);
      if (!node) {
        node = createPoliceNode(unit, scale);
        MAP.policeNodes.set(unit.id, node);
        group.appendChild(node);
      }
      updatePoliceNode(node, unit, scale);
    }
  }

  function setPoliceUnits(units) {
    clearPoliceMarkers();
    applyPoliceDelta(Array.isArray(units) ? units : [], []);
  }

  function updatePoliceMarkers(units) {
    if (!MAP.bounds || !MAP.svg) return;
    const scale = markerScale();
    for (const unit of Array.isArray(units) ? units : []) {
      if (!unit || typeof unit.id !== "string") continue;
      let node = MAP.policeNodes.get(unit.id);
      if (!node) {
        const group = policeGroup();
        if (!group) continue;
        node = createPoliceNode(unit, scale);
        MAP.policeNodes.set(unit.id, node);
        group.appendChild(node);
      }
      MAP.policeMarkers.set(unit.id, unit);
      updatePoliceNode(node, unit, scale);
    }
  }

  function renderPoliceMarkers() {
    for (const node of MAP.policeNodes.values()) node.remove();
    MAP.policeNodes.clear();
    const group = policeGroup();
    if (!group) return;
    group.replaceChildren();
    const scale = MAP.bounds && MAP.svg ? markerScale() : 1;
    for (const [id, unit] of MAP.policeMarkers) {
      const node = createPoliceNode(unit, scale);
      MAP.policeNodes.set(id, node);
      group.appendChild(node);
      updatePoliceNode(node, unit, scale);
    }
  }

  function refreshPoliceMarkerScale() {
    if (!MAP.bounds || !MAP.svg) return;
    const scale = markerScale();
    for (const [id, node] of MAP.policeNodes) {
      const unit = MAP.policeMarkers.get(id);
      if (unit) updatePoliceNode(node, unit, scale);
    }
  }

  function setPoliceVisible(visible) {
    const group = policeGroup();
    if (!group) return;
    if (visible === false) {
      group.style.display = "none";
    } else {
      group.removeAttribute("display");
      group.style.display = "";
    }
  }

  function policeUnitFromEvent(event) {
    const node = event.target.closest && event.target.closest("[data-unit-id]");
    if (!node) return null;
    return node.getAttribute("data-unit-id");
  }

  function setCamera(camera) {
    if (!camera) return;
    MAP.camera.cx = P.clamp(Number(camera.cx) || 500, 0, P.MAP_UNITS);
    MAP.camera.cy = P.clamp(Number(camera.cy) || 500, 0, P.MAP_UNITS);
    MAP.camera.zoom = P.clamp(Number(camera.zoom) || 2, MIN_ZOOM, MAX_ZOOM);
    requestFrame();
  }

  function centerOnWorld(coords, zoom) {
    if (!coords || !MAP.bounds) return;
    const point = P.worldToMap(coords.x, coords.y, MAP.bounds);
    if (!point) return;
    MAP.camera.cx = point.mx;
    MAP.camera.cy = point.my;
    if (zoom) MAP.camera.zoom = P.clamp(Number(zoom), MIN_ZOOM, MAX_ZOOM);
    requestFrame();
  }

  function fitPoints(points) {
    if (!MAP.bounds) return false;
    const mapped = (points || [])
      .map((point) => P.worldToMap(point.x, point.y, MAP.bounds))
      .filter(Boolean);
    if (!mapped.length) return false;

    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    mapped.forEach((point) => {
      minX = Math.min(minX, point.mx);
      minY = Math.min(minY, point.my);
      maxX = Math.max(maxX, point.mx);
      maxY = Math.max(maxY, point.my);
    });

    const padding = 60;
    const spanX = Math.max(20, maxX - minX);
    const spanY = Math.max(20, maxY - minY);
    const height = Math.max(spanY + padding * 2, (spanX + padding * 2) / aspectRatio());
    const zoom = P.clamp(1 + Math.log2(P.MAP_UNITS / height), MIN_ZOOM, MAX_ZOOM);

    MAP.camera = { cx: (minX + maxX) / 2, cy: (minY + maxY) / 2, zoom };
    requestFrame();
    return true;
  }

  function fitToPois(pois) {
    const visible = (pois || []).filter((poi) => MAP.visibleLayers.has(poi.layer));
    return fitPoints(visible);
  }

  function setZoom(zoom) {
    MAP.camera.zoom = P.clamp(Number(zoom) || 2, MIN_ZOOM, MAX_ZOOM);
    requestFrame();
  }

  function zoomBy(delta) {
    setZoom(MAP.camera.zoom + delta);
  }

  function setData(pois, layers) {
    MAP.markers = Array.isArray(pois) ? pois : [];
    MAP.layers = new Map();
    (layers || []).forEach((layer) => MAP.layers.set(layer.id, layer));
    renderMarkers();
    MAP.tileFailures.clear();
    renderTiles();
  }

  function setVisibleLayers(layerIds) {
    const next = layerIds instanceof Set ? layerIds : new Set(layerIds || []);
    const changed = next.size !== MAP.visibleLayers.size
      || [...next].some((id) => !MAP.visibleLayers.has(id));
    MAP.visibleLayers = next;
    if (changed) renderMarkers();
    applyLocalVisibility();
  }

  function poiFromEvent(event) {
    const node = event.target.closest && event.target.closest("[data-poi-id]");
    if (!node) return null;
    const id = node.getAttribute("data-poi-id");
    return MAP.markers.find((poi) => poi.id === id) || null;
  }

  function choosePoi(poi) {
    if (!poi) return false;
    MAP.selected = { x: poi.x, y: poi.y, z: poi.z, poiId: poi.id, label: poi.label };
    renderCandidate();
    if (typeof MAP.callbacks.onSelect === "function") MAP.callbacks.onSelect(MAP.selected, poi);
    return true;
  }

  function onKeyDown(event) {
    if (event.key !== "Enter" && event.key !== " ") return;
    if (choosePoi(poiFromEvent(event))) {
      event.preventDefault();
      return;
    }
    const unitId = policeUnitFromEvent(event);
    if (unitId && typeof MAP.callbacks.onPoliceSelect === "function") {
      MAP.callbacks.onPoliceSelect(unitId);
      event.preventDefault();
    }
  }

  function onPointerDown(event) {
    if (event.button !== undefined && event.button !== 0) return;
    MAP.drag = {
      id: event.pointerId,
      x: event.clientX,
      y: event.clientY,
      startX: event.clientX,
      startY: event.clientY,
      cx: MAP.camera.cx,
      cy: MAP.camera.cy,
      poi: poiFromEvent(event),
      police: policeUnitFromEvent(event),
    };
    MAP.moved = false;
    MAP.svg.setPointerCapture?.(event.pointerId);
  }

  function onPointerMove(event) {
    if (!MAP.drag || MAP.drag.id !== event.pointerId) return;
    const dx = event.clientX - MAP.drag.x;
    const dy = event.clientY - MAP.drag.y;
    if (Math.abs(event.clientX - MAP.drag.startX) > 4 || Math.abs(event.clientY - MAP.drag.startY) > 4) {
      MAP.moved = true;
    }
    if (!MAP.moved) return;

    const rect = MAP.svg.getBoundingClientRect();
    const view = currentViewport();
    const unitsPerPxX = view.width / Math.max(1, rect.width);
    const unitsPerPxY = view.height / Math.max(1, rect.height);

    MAP.camera.cx = P.clamp(MAP.drag.cx - dx * unitsPerPxX, 0, P.MAP_UNITS);
    MAP.camera.cy = P.clamp(MAP.drag.cy - dy * unitsPerPxY, 0, P.MAP_UNITS);
    requestFrame();
  }

  function onPointerUp(event) {
    if (!MAP.drag) return;
    const wasDrag = MAP.moved;
    const pointerPoi = MAP.drag.poi;
    const pointerPolice = MAP.drag.police;
    MAP.drag = null;
    MAP.svg.releasePointerCapture?.(event.pointerId);
    if (wasDrag) return;

    const poi = pointerPoi || poiFromEvent(event);
    if (choosePoi(poi)) return;

    const unitId = pointerPolice || policeUnitFromEvent(event);
    if (unitId && typeof MAP.callbacks.onPoliceSelect === "function") {
      MAP.callbacks.onPoliceSelect(unitId);
      return;
    }

    const point = screenToMap(event.clientX, event.clientY);
    const world = P.mapToWorld(point.mx, point.my, MAP.bounds);
    if (!world) return;
    MAP.selected = { x: world.x, y: world.y, label: "Ponto no mapa" };
    renderCandidate();
    if (typeof MAP.callbacks.onSelect === "function") MAP.callbacks.onSelect(MAP.selected, null);
  }

  function onWheel(event) {
    event.preventDefault();
    const step = event.deltaY > 0 ? -0.35 : 0.35;
    const anchorBefore = screenToMap(event.clientX, event.clientY);
    MAP.camera.zoom = P.clamp(MAP.camera.zoom + step, MIN_ZOOM, MAX_ZOOM);
    applyViewBox();
    const anchorAfter = screenToMap(event.clientX, event.clientY);
    MAP.camera.cx = P.clamp(MAP.camera.cx + (anchorBefore.mx - anchorAfter.mx), 0, P.MAP_UNITS);
    MAP.camera.cy = P.clamp(MAP.camera.cy + (anchorBefore.my - anchorAfter.my), 0, P.MAP_UNITS);
    requestFrame();
  }

  function onPointerCancel() {
    MAP.drag = null;
    MAP.moved = false;
  }

  function onContextMenu(event) {
    event.preventDefault();
  }

  function init(svg, callbacks) {
    MAP.svg = svg;
    MAP.callbacks = callbacks || {};
    MAP.groups = {
      base: svg.querySelector("#navBaseMap"),
      tiles: svg.querySelector("#navTiles"),
      regions: svg.querySelector("#navRegions"),
      grid: svg.querySelector("#navGrid"),
      districts: svg.querySelector("#navDistricts"),
      nativeBlips: svg.querySelector("#navNativeBlips"),
      externalMarkers: svg.querySelector("#navExternalMarkers"),
      police: svg.querySelector("#navPoliceLayer"),
      route: svg.querySelector("#navRoute"),
      pois: svg.querySelector("#navPois"),
      candidate: svg.querySelector("#navCandidate"),
    };

    svg.addEventListener("pointerdown", onPointerDown);
    svg.addEventListener("pointermove", onPointerMove);
    svg.addEventListener("pointerup", onPointerUp);
    svg.addEventListener("pointercancel", onPointerCancel);
    svg.addEventListener("wheel", onWheel, { passive: false });
    svg.addEventListener("contextmenu", onContextMenu);
    svg.addEventListener("keydown", onKeyDown);

    MAP.observer = new ResizeObserver(() => requestFrame());
    MAP.observer.observe(svg);

    renderGrid();
    renderRegions();
    renderDistricts();
    applyViewBox();
  }

  function configure(config) {
    MAP.config = config || {};
    MAP.bounds = P.normalizeBounds(MAP.config.bounds);
    renderBaseMap();
    renderRegions();
    renderDistricts();
    renderTiles();
    renderRoute();
    renderLocalMarkers();
    renderPoliceMarkers();
    applyViewBox();
  }

  function resetCamera() {
    MAP.camera = { cx: 500, cy: 500, zoom: (MAP.config && MAP.config.defaultZoom) || 2 };
    requestFrame();
  }

  function destroy() {
    if (MAP.svg) {
      MAP.svg.removeEventListener("pointerdown", onPointerDown);
      MAP.svg.removeEventListener("pointermove", onPointerMove);
      MAP.svg.removeEventListener("pointerup", onPointerUp);
      MAP.svg.removeEventListener("pointercancel", onPointerCancel);
      MAP.svg.removeEventListener("wheel", onWheel);
      MAP.svg.removeEventListener("contextmenu", onContextMenu);
      MAP.svg.removeEventListener("keydown", onKeyDown);
    }
    MAP.observer?.disconnect();
    MAP.observer = null;
    if (MAP.frame) window.cancelAnimationFrame(MAP.frame);
    MAP.frame = 0;
    MAP.drag = null;
    MAP.localNodes.clear();
    MAP.localMarkers.native.clear();
    MAP.localMarkers.external.clear();
    MAP.policeNodes.clear();
    MAP.policeMarkers.clear();
    MAP.svg = null;
    MAP.groups = {};
  }

  window.MZNavMap = {
    init,
    configure,
    setData,
    setVisibleLayers,
    applyMarkerDelta,
    clearLocalMarkers,
    applyPoliceDelta,
    setPoliceUnits,
    updatePoliceMarkers,
    clearPoliceMarkers,
    setPoliceVisible,
    select,
    setCamera,
    centerOnWorld,
    fitToPois,
    fitPoints,
    setRoutePoints,
    setRouteSelected,
    setZoom,
    zoomBy,
    resetCamera,
    destroy,
    getCamera: () => ({ ...MAP.camera }),
    getZoom: () => MAP.camera.zoom,
    isLoaded: () => MAP.config !== null,
    getLocalMarkerCount: (layer) => (MAP.localMarkers[layer] ? MAP.localMarkers[layer].size : 0),
    getPoliceCount: () => MAP.policeMarkers.size,
    layerTone,
  };
})();
