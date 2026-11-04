/**
 * mz_navigation - controller da NUI.
 *
 * Contrato NUI:
 *   recebe  navigation:open   { mode, requestId, options }
 *   recebe  navigation:close  { reason }
 *   recebe  navigation:response { action, requestId, ok, error, data }
 *   envia   navigationRequest { action, payload, requestId }
 *   envia   navigationConfirm { requestId, selection }
 *   envia   navigationCancel  { requestId }
 *   envia   navigationClose   {}
 */
(() => {
  "use strict";

  const P = window.MZNavProjection;
  const MAP = window.MZNavMap;
  const NAV_BLIPS = window.MZNavBlips;
  const RESOURCE = typeof GetParentResourceName === "function" ? GetParentResourceName() : "mz_navigation";

  const root = document.getElementById("navRoot");
  const svg = document.getElementById("navMap");
  const searchInput = document.getElementById("navSearch");
  const sideContent = document.getElementById("navSideContent");
  const legend = document.getElementById("navLegend");
  const modeLabel = document.getElementById("navModeLabel");
  const titleLabel = document.getElementById("navTitle");
  const selectionLabel = document.getElementById("navSelectionLabel");
  const selectionKicker = document.getElementById("navSelectionKicker");
  const selectionCoords = document.getElementById("navSelectionCoords");
  const coordsLabel = document.getElementById("navCoords");
  const sourceBadge = document.getElementById("navSourceBadge");
  const favoriteButton = document.getElementById("navFavorite");
  const waypointButton = document.getElementById("navWaypoint");
  const confirmButton = document.getElementById("navConfirm");
  const closeButton = document.getElementById("navClose");
  const toast = document.getElementById("navToast");
  const editorActions = document.getElementById("navEditorActions");
  const editorSaveButton = document.getElementById("navEditorSave");
  const editorPublishButton = document.getElementById("navEditorPublish");
  const editorDeleteButton = document.getElementById("navEditorDelete");
  const editorCloseButton = document.getElementById("navEditorClose");
  const headerSearch = document.querySelector(".nav-search");
  const mapHint = document.getElementById("navMapHint");

  const state = {
    open: false,
    mode: "browse",
    requestId: null,
    options: {},
    map: null,
    layers: [],
    pois: [],
    favorites: [],
    recents: [],
    enabledLayers: new Set(),
    selected: null,
    tab: "layers",
    search: "",
    loading: false,
    error: "",
    lastRemovedFavoriteId: null,
    recenterPending: false,
    editor: {
      routes: [],
      current: null,
      orgCodes: [],
      loading: false,
      error: "",
      search: "",
      page: 1,
      hasNext: false,
      appendList: false,
      dirty: false,
      editingSinceSave: false,
      status: "",
      saving: false,
      confirmDelete: false,
      confirmDiscard: false,
      discardIntent: "",
      selectedPoint: -1,
    },
    catalog: {
      routes: [],
      current: null,
      scope: "all",
      search: "",
      page: 1,
      hasNext: false,
      appendList: false,
      loading: false,
      error: "",
      requestId: null,
      detailRequestId: null,
    },
  };

  const LOCAL_LAYERS = [
    { id: "local_native", labelKey: "nativeLayer", kind: "native", local: true, defaultEnabled: true },
    { id: "local_external", labelKey: "externalLayer", kind: "external", local: true, defaultEnabled: true },
  ];

  const blipStore = NAV_BLIPS ? NAV_BLIPS.createStore() : null;

  const t = (key, values) => (window.MZNavI18n ? window.MZNavI18n.t(key, values) : key);

  let toastTimer = 0;
  let requestCounter = 0;
  let catalogSearchTimer = 0;
  let pendingInitial = null;

  function requestIdFor(action) {
    requestCounter += 1;
    return `ui_${action}_${Date.now()}_${requestCounter}`;
  }

  function post(route, body) {
    return fetch(`https://${RESOURCE}/${route}`, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=UTF-8" },
      body: JSON.stringify(body || {}),
    }).catch(() => null);
  }

  function request(action, payload) {
    const requestId = requestIdFor(action);
    post("navigationRequest", { action, payload: payload || {}, requestId });
    return requestId;
  }

  function showToast(message, isError) {
    if (!toast) return;
    toast.textContent = String(message || "");
    toast.classList.toggle("is-error", isError === true);
    toast.classList.add("is-visible");
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => toast.classList.remove("is-visible"), 2600);
  }

  function formatCoords(coords) {
    if (!coords) return "";
    const x = Number(coords.x);
    const y = Number(coords.y);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return "";
    const z = Number(coords.z);
    const base = `${x.toFixed(1)}, ${y.toFixed(1)}`;
    return Number.isFinite(z) ? `${base} · ${z.toFixed(1)}` : base;
  }

  function layerById(id) {
    return state.layers.find((layer) => layer.id === id) || null;
  }

  function layerLabel(id) {
    const layer = layerById(id);
    return layer ? layer.label : "Geral";
  }

  function localLayerCount(id) {
    if (!blipStore || !NAV_BLIPS) return 0;
    const layer = id === "local_native" ? "native" : id === "local_external" ? "external" : null;
    return layer ? NAV_BLIPS.count(blipStore, layer) : 0;
  }

  function updateLocalLayerCounts() {
    document.querySelectorAll("[data-layer-count]").forEach((node) => {
      const id = node.getAttribute("data-layer-count");
      if (id !== "local_native" && id !== "local_external") return;
      const count = localLayerCount(id);
      node.textContent = `${count} ponto${count === 1 ? "" : "s"}`;
    });
  }

  /**
   * Deltas de blips nao chamam bootstrap/renderAll: o mapa, o zoom, a rota,
   * a selecao e os POIs interativos permanecem intactos.
   */
  function handleBlipMessage(payload) {
    if (!state.open || !blipStore || !NAV_BLIPS) return;
    // Antes do bootstrap, o mapa ainda nao conhece a config; aceitamos o delta
    // para nao perder o snapshot inicial. Depois, a flag do servidor manda.
    if (state.map && (!state.map.blips || state.map.blips.enabled !== true)) return;
    const result = NAV_BLIPS.accept(blipStore, payload);
    if (!result.accepted) return;
    if (result.kind === "reset") {
      MAP.clearLocalMarkers();
    } else {
      MAP.applyMarkerDelta(result.upserts, result.removes);
    }
    updateLocalLayerCounts();
  }

  function normalizeText(value) {
    return String(value || "")
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase();
  }

  function visiblePois() {
    return state.pois.filter((poi) => state.enabledLayers.has(poi.layer));
  }

  function filteredPois() {
    const term = normalizeText(state.search).trim();
    if (!term) return [];
    return visiblePois()
      .filter((poi) => normalizeText(poi.label).includes(term))
      .slice(0, 60);
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function icon(pathData) {
    const svgNode = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svgNode.setAttribute("viewBox", "0 0 24 24");
    svgNode.setAttribute("fill", "none");
    svgNode.setAttribute("stroke", "currentColor");
    svgNode.setAttribute("stroke-width", "1.7");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", pathData);
    svgNode.appendChild(path);
    return svgNode;
  }

  function renderLegend() {
    legend.replaceChildren();
    state.layers.forEach((layer) => {
      if (!state.enabledLayers.has(layer.id)) return;
      const item = element("span");
      const dot = document.createElement("i");
      dot.style.background = MAP.layerTone(layer.id);
      item.appendChild(dot);
      item.appendChild(document.createTextNode(layer.label));
      legend.appendChild(item);
    });
  }

  function renderTabs() {
    const tabs = document.querySelector(".nav-tabs");
    if (tabs) tabs.hidden = state.mode === "editor" || state.mode === "catalog";
    document.querySelectorAll("[data-tab]").forEach((button) => {
      button.classList.toggle("is-active", button.getAttribute("data-tab") === state.tab);
    });
  }

  function poiButton(poi) {
    const row = element("button", "nav-item");
    row.type = "button";
    row.addEventListener("click", () => {
      selectPoi(poi);
      MAP.centerOnWorld(poi, Math.max(3, MAP.getZoom()));
    });

    const copy = element("div", "nav-item-copy");
    copy.appendChild(element("strong", null, poi.label));
    copy.appendChild(element("small", null, `${layerLabel(poi.layer)} · ${formatCoords(poi)}`));
    row.appendChild(copy);
    return row;
  }

  function renderLayers() {
    state.layers.forEach((layer) => {
      const on = state.enabledLayers.has(layer.id);
      const row = element("button", `nav-layer${on ? " is-on" : ""}`);
      row.type = "button";
      row.setAttribute("aria-pressed", on ? "true" : "false");

      const swatch = element("span", "nav-layer-swatch");
      swatch.style.background = MAP.layerTone(layer.id);
      row.appendChild(swatch);

      const copy = element("div", "nav-layer-copy");
      copy.appendChild(element("strong", null, layer.label));
      const count = layer.local
        ? localLayerCount(layer.id)
        : state.pois.filter((poi) => poi.layer === layer.id).length;
      const countNode = element("small", null, `${count} ponto${count === 1 ? "" : "s"}`);
      if (layer.local) countNode.setAttribute("data-layer-count", layer.id);
      copy.appendChild(countNode);
      row.appendChild(copy);

      row.appendChild(element("span", "nav-layer-state", on ? "ON" : "OFF"));
      row.addEventListener("click", () => {
        if (state.enabledLayers.has(layer.id)) state.enabledLayers.delete(layer.id);
        else state.enabledLayers.add(layer.id);
        MAP.setVisibleLayers(state.enabledLayers);
        renderSide();
        renderLegend();
      });
      sideContent.appendChild(row);
    });
  }

  function renderFavorites() {
    if (!state.favorites.length) {
      sideContent.appendChild(
        element("div", "nav-empty", "Nenhum favorito salvo para este personagem."),
      );
      return;
    }

    state.favorites.forEach((favorite) => {
      const row = element("div", "nav-item");
      const button = element("button", "nav-item-copy");
      button.type = "button";
      button.style.background = "transparent";
      button.style.border = "0";
      button.style.textAlign = "left";
      button.style.padding = "0";
      button.style.color = "inherit";
      button.appendChild(element("strong", null, favorite.label));
      button.appendChild(element("small", null, formatCoords(favorite)));
      button.addEventListener("click", () => {
        selectCustom(favorite);
        MAP.centerOnWorld(favorite, Math.max(3, MAP.getZoom()));
      });
      row.appendChild(button);

      const remove = element("button", "nav-item-action");
      remove.type = "button";
      remove.setAttribute("aria-label", `Remover favorito ${favorite.label}`);
      remove.appendChild(icon("M4 7h16M9 7V5h6v2m-8 0 1 13h8l1-13"));
      remove.addEventListener("click", () => {
        state.lastRemovedFavoriteId = favorite.id;
        request("favorites.remove", { id: favorite.id });
      });
      row.appendChild(remove);
      sideContent.appendChild(row);
    });
  }

  function renderRecents() {
    if (!state.recents.length) {
      sideContent.appendChild(element("div", "nav-empty", "Nenhum destino recente."));
      return;
    }

    state.recents.forEach((recent) => {
      const row = element("button", "nav-item");
      row.type = "button";
      const copy = element("div", "nav-item-copy");
      copy.appendChild(element("strong", null, recent.label || "Destino"));
      copy.appendChild(element("small", null, formatCoords(recent)));
      row.appendChild(copy);
      row.addEventListener("click", () => {
        selectCustom(recent);
        MAP.centerOnWorld(recent, Math.max(3, MAP.getZoom()));
      });
      sideContent.appendChild(row);
    });
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  function routeLimits() {
    return (state.map && state.map.routes) || {
      minPoints: 2,
      maxPoints: 64,
      maxTitle: 80,
      maxDescription: 300,
      maxTotalDistance: 20000,
    };
  }

  function editorUsable() {
    const routes = state.map && state.map.routes;
    return !routes || (routes.enabled !== false && routes.available !== false
      && routes.quotaAvailable !== false);
  }

  function resetEditor() {
    state.editor.routes = [];
    state.editor.current = null;
    state.editor.orgCodes = [];
    state.editor.loading = false;
    state.editor.error = "";
    state.editor.search = "";
    state.editor.page = 1;
    state.editor.hasNext = false;
    state.editor.appendList = false;
    state.editor.dirty = false;
    state.editor.editingSinceSave = false;
    state.editor.status = "";
    state.editor.saving = false;
    state.editor.confirmDelete = false;
    state.editor.confirmDiscard = false;
    state.editor.discardIntent = "";
    state.editor.selectedPoint = -1;
    MAP.setRoutePoints([]);
  }

  function newEditorDraft() {
    if (!editorUsable()) {
      showToast(state.editor.error || t("unavailable"), true);
      return;
    }
    const limits = routeLimits();
    state.editor.current = {
      publicId: null,
      title: "",
      description: "",
      routeType: "generic",
      visibility: "character",
      ownerType: "character",
      orgCode: "",
      points: [],
      revision: 0,
      isPublished: false,
      canEdit: true,
      schemaVersion: 1,
      pointCount: 0,
      totalDistance: 0,
    };
    state.editor.dirty = true; state.editor.editingSinceSave = true;
    state.editor.status = "";
    state.editor.error = "";
    state.editor.confirmDelete = false;
    state.editor.confirmDiscard = false;
    state.editor.selectedPoint = -1;
    MAP.setRoutePoints([]);
    renderAll();
  }

  function refreshRouteList(page, append) {
    if (state.editor.loading) return;
    state.editor.loading = true;
    state.editor.error = "";
    state.editor.page = Math.max(1, Number(page) || 1);
    state.editor.appendList = append === true;
    request("routes.list", {
      page: state.editor.page,
      limit: 20,
      search: state.editor.search,
    });
    renderSide();
  }

  function openEditorRoute(publicId) {
    if (!publicId) return;
    if (state.editor.dirty) {
      showToast(t("unsavedSwitch"), true);
      return;
    }
    state.editor.loading = true;
    state.editor.error = "";
    request("routes.get", { publicId });
    renderSide();
  }

  function setEditorField(field, value) {
    const current = state.editor.current;
    if (!current || current.canEdit === false) return;
    if (field === "title" || field === "description" || field === "routeType" || field === "visibility") {
      current[field] = value;
      state.editor.dirty = true; state.editor.editingSinceSave = true;
      state.editor.status = "";
      renderFooter();
      return;
    }
    if (field === "ownerType" && !current.publicId) {
      current.ownerType = value === "org" ? "org" : "character";
      if (current.ownerType === "org") {
        current.orgCode = current.orgCode || state.editor.orgCodes[0] || "";
        if (current.visibility === "character") current.visibility = "org";
      } else {
        current.orgCode = "";
        if (current.visibility === "org") current.visibility = "character";
      }
      state.editor.dirty = true; state.editor.editingSinceSave = true;
      renderSide();
      renderFooter();
      return;
    }
    if (field === "orgCode" && !current.publicId && current.ownerType === "org") {
      if (state.editor.orgCodes.indexOf(value) >= 0) {
        current.orgCode = value;
        state.editor.dirty = true; state.editor.editingSinceSave = true;
        renderFooter();
      }
    }
  }

  function currentPoints() {
    const current = state.editor.current;
    return current && Array.isArray(current.points) ? current.points : [];
  }

  function addEditorPoint(selection) {
    const current = state.editor.current;
    if (!current) {
      showToast(t("addPointHint"), true);
      return;
    }
    if (current.canEdit === false) {
      showToast(t("noPermission"), true);
      return;
    }
    const limits = routeLimits();
    const points = currentPoints();
    if (points.length >= limits.maxPoints) {
      showToast(t("maxPoints"), true);
      return;
    }
    const x = Number(selection && selection.x);
    const y = Number(selection && selection.y);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    const point = { x, y };
    if (selection.z !== undefined && selection.z !== null && Number.isFinite(Number(selection.z))) {
      point.z = Number(selection.z);
    }
    points.push(point);
    current.points = points;
    current.pointCount = points.length;
    state.editor.dirty = true; state.editor.editingSinceSave = true;
    state.editor.selectedPoint = points.length - 1;
    state.editor.status = "";
    MAP.select(null);
    MAP.setRoutePoints(points, state.editor.selectedPoint);
    renderAll();
  }

  function removeEditorPoint(index) {
    const current = state.editor.current;
    if (!current || current.canEdit === false) return;
    const points = currentPoints();
    if (index < 0 || index >= points.length) return;
    points.splice(index, 1);
    current.pointCount = points.length;
    state.editor.dirty = true; state.editor.editingSinceSave = true;
    state.editor.selectedPoint = Math.min(index, points.length - 1);
    MAP.setRoutePoints(points, state.editor.selectedPoint);
    renderAll();
  }

  function moveEditorPoint(index, delta) {
    const current = state.editor.current;
    if (!current || current.canEdit === false) return;
    const points = currentPoints();
    const target = index + delta;
    if (index < 0 || index >= points.length || target < 0 || target >= points.length) return;
    points[index], points[target] = points[target], points[index];
    state.editor.dirty = true; state.editor.editingSinceSave = true;
    state.editor.selectedPoint = target;
    MAP.setRoutePoints(points, state.editor.selectedPoint);
    renderAll();
  }

  function selectEditorPoint(index) {
    const points = currentPoints();
    if (index < 0 || index >= points.length) return;
    state.editor.selectedPoint = index;
    MAP.setRouteSelected(index);
    renderSide();
  }

  function saveEditor() {
    const current = state.editor.current;
    if (!current || state.editor.saving || current.canEdit === false) return;
    const limits = routeLimits();
    const title = String(current.title || "").trim();
    if (!title) {
      showToast(t("invalid"), true);
      return;
    }
    const points = currentPoints();
    if (points.length < limits.minPoints) {
      showToast(t("minPoints"), true);
      return;
    }
    if (points.length > limits.maxPoints) {
      showToast(t("maxPoints"), true);
      return;
    }

    state.editor.saving = true;
    state.editor.error = "";
    state.editor.status = "";
    state.editor.editingSinceSave = false;
    const payload = {
      title,
      description: String(current.description || ""),
      routeType: current.routeType || "generic",
      visibility: current.visibility || "character",
      points,
    };
    if (current.publicId) {
      payload.publicId = current.publicId;
      payload.expectedRevision = current.revision;
      request("routes.update", payload);
    } else {
      payload.ownerType = current.ownerType || "character";
      payload.orgCode = current.orgCode || "";
      request("routes.create", payload);
    }
    renderFooter();
  }

  function setEditorPublished(published) {
    const current = state.editor.current;
    if (!current || !current.publicId) {
      showToast(t("saveFirst"), true);
      return;
    }
    if (state.editor.dirty) {
      showToast(t("saveFirst"), true);
      return;
    }
    request(published ? "routes.publish" : "routes.unpublish", {
      publicId: current.publicId,
      expectedRevision: current.revision,
    });
  }

  function requestEditorDelete() {
    const current = state.editor.current;
    if (!current) return;
    if (!current.publicId) {
      discardEditor("list");
      return;
    }
    if (!state.editor.confirmDelete) {
      state.editor.confirmDelete = true;
      state.editor.confirmDiscard = false;
      renderFooter();
      return;
    }
    state.editor.confirmDelete = false;
    request("routes.delete", {
      publicId: current.publicId,
      expectedRevision: current.revision,
    });
    renderFooter();
  }

  function requestEditorClose() {
    if (state.editor.saving) return;
    if (state.editor.dirty) {
      state.editor.confirmDiscard = true;
      state.editor.discardIntent = "close";
      state.editor.confirmDelete = false;
      renderFooter();
      return;
    }
    post("navigationClose", {});
  }

  function cancelEditorConfirmation() {
    state.editor.confirmDelete = false;
    state.editor.confirmDiscard = false;
    state.editor.discardIntent = "";
    renderFooter();
  }

  function discardEditor(intent) {
    state.editor.current = null;
    state.editor.dirty = false;
    state.editor.editingSinceSave = false;
    state.editor.confirmDelete = false;
    state.editor.confirmDiscard = false;
    state.editor.discardIntent = "";
    state.editor.selectedPoint = -1;
    state.editor.status = "";
    MAP.setRoutePoints([]);
    if (intent === "close") {
      post("navigationClose", {});
      return;
    }
    if (intent === "new") {
      newEditorDraft();
      return;
    }
    renderAll();
    refreshRouteList(1);
  }

  function backToRouteList() {
    if (state.editor.dirty) {
      state.editor.confirmDiscard = true;
      state.editor.discardIntent = "list";
      state.editor.confirmDelete = false;
      renderFooter();
      return;
    }
    state.editor.current = null;
    state.editor.selectedPoint = -1;
    MAP.setRoutePoints([]);
    renderAll();
  }

  function reloadEditorRoute() {
    const current = state.editor.current;
    if (!current || !current.publicId) return;
    state.editor.dirty = false;
    openEditorRoute(current.publicId);
  }

  function editorStatusText() {
    if (state.editor.error) return state.editor.error;
    if (state.editor.status) return state.editor.status;
    return "";
  }

  function selectOptions(values, selected) {
    return values
      .map((value) => `<option value="${escapeHtml(value.value)}"${value.value === selected ? " selected" : ""}>${escapeHtml(value.label)}</option>`)
      .join("");
  }

  function renderEditorSide() {
    const editor = state.editor;
    const routesMeta = state.map && state.map.routes;

    if (!editor.current) {
      const disabledWarning = routesMeta && routesMeta.enabled === false
        ? `<div class="nav-editor-warning">${escapeHtml(t("disabled"))}</div>`
        : routesMeta && routesMeta.available === false
          ? `<div class="nav-editor-warning">${escapeHtml(t("unavailable"))}</div>`
          : routesMeta && routesMeta.quotaAvailable === false
            ? `<div class="nav-editor-warning">${escapeHtml(t("quotaUnavailable"))}</div>`
            : "";

      let list = "";
      if (editor.loading) {
        list = `<div class="nav-empty">${escapeHtml(t("loading"))}</div>`;
      } else if (!editor.routes.length) {
        list = `<div class="nav-empty">${escapeHtml(t("noRoutes"))}</div>`;
      } else {
        list = editor.routes
          .map((route) => `<button type="button" class="nav-editor-route" data-editor-action="open" data-route-id="${escapeHtml(route.publicId)}">
            <span class="nav-editor-route-copy">
              <strong>${escapeHtml(route.title || t("editorTitle"))}</strong>
              <small>${escapeHtml(t("pointsCount", { count: route.pointCount }))} · ${escapeHtml(t("distance", { km: (Number(route.totalDistance || 0) / 1000).toFixed(2) }))}</small>
            </span>
            <span class="nav-editor-badge${route.isPublished ? "" : " is-draft"}">${escapeHtml(route.isPublished ? t("publishedBadge") : t("draft"))}</span>
          </button>`)
          .join("");
      }

      sideContent.innerHTML = `<div class="nav-editor-toolbar">
          <input id="editorSearch" data-editor-search type="search" aria-label="${escapeHtml(t("searchPlaceholder"))}" placeholder="${escapeHtml(t("searchPlaceholder"))}" value="${escapeHtml(editor.search)}" />
          <button type="button" class="nav-btn nav-btn--ghost" data-editor-action="refresh" aria-label="${escapeHtml(t("refresh"))}">&#8635;</button>
        </div>
        <button type="button" class="nav-btn nav-btn--primary" data-editor-action="new" ${editorUsable() ? "" : "disabled"}>${escapeHtml(t("newRoute"))}</button>
        <div class="nav-editor-section">${escapeHtml(t("routes"))}</div>
        ${disabledWarning}
        ${list}
        ${editor.hasNext ? `<button type="button" class="nav-btn nav-btn--ghost" data-editor-action="more">${escapeHtml(t("loadMore"))}</button>` : ""}
        <div class="nav-editor-status${editor.error ? " is-error" : ""}">${escapeHtml(editorStatusText())}</div>`;
      return;
    }

    const current = editor.current;
    const limits = routeLimits();
    const points = currentPoints();
    const selected = editor.selectedPoint;
    const readOnly = current.canEdit === false ? " disabled" : "";
    const typeOptions = [
      { value: "generic", label: t("routeTypeGeneric") },
      { value: "circuit", label: t("routeTypeCircuit") },
      { value: "sprint", label: t("routeTypeSprint") },
      { value: "patrol", label: t("routeTypePatrol") },
      { value: "delivery", label: t("routeTypeDelivery") },
      { value: "bus", label: t("routeTypeBus") },
    ];
    const visibilityOptions = [
      { value: "character", label: t("visibilityCharacter") },
      { value: "public", label: t("visibilityPublic") },
    ];
    if (current.ownerType === "org") {
      visibilityOptions.splice(1, 0, { value: "org", label: t("visibilityOrg") });
    }

    const pointRows = points.length
      ? points
          .map((point, index) => `<div class="nav-point-row${index === selected ? " is-selected" : ""}" data-editor-action="select-point" data-index="${index}">
            <span class="nav-point-index">${index + 1}</span>
            <span class="nav-point-copy">${escapeHtml(formatCoords(point))}${point.z === undefined ? " · z?" : ""}</span>
            <span class="nav-point-actions">
              <button type="button" data-editor-action="up" data-index="${index}" aria-label="${escapeHtml(t("up"))}" ${index === 0 || current.canEdit === false ? "disabled" : ""}>&#8593;</button>
              <button type="button" data-editor-action="down" data-index="${index}" aria-label="${escapeHtml(t("down"))}" ${index === points.length - 1 || current.canEdit === false ? "disabled" : ""}>&#8595;</button>
              <button type="button" data-editor-action="remove" data-index="${index}" aria-label="${escapeHtml(t("remove"))}"${readOnly}>&times;</button>
            </span>
          </div>`)
          .join("")
      : `<div class="nav-empty">${escapeHtml(t("emptyPoints"))}</div>`;

    sideContent.innerHTML = `<button type="button" class="nav-btn nav-btn--ghost" data-editor-action="back">&#8592; ${escapeHtml(t("backToList"))}</button>
      <div class="nav-editor-section">${escapeHtml(current.publicId ? t("editRoute") : t("newDraft"))}</div>
      ${editor.dirty ? `<div class="nav-editor-warning">${escapeHtml(t("unsaved"))}</div>` : ""}
      <div class="nav-field"><label for="editorTitle">${escapeHtml(t("title"))}</label>
        <input id="editorTitle" data-editor-field="title" maxlength="${limits.maxTitle}"${readOnly} value="${escapeHtml(current.title || "")}" />
      </div>
      <div class="nav-field"><label for="editorDescription">${escapeHtml(t("description"))}</label>
        <textarea id="editorDescription" data-editor-field="description" maxlength="${limits.maxDescription}"${readOnly}>${escapeHtml(current.description || "")}</textarea>
      </div>
      <div class="nav-field-row">
        <div class="nav-field"><label for="editorType">${escapeHtml(t("routeType"))}</label>
          <select id="editorType" data-editor-field="routeType"${readOnly}>${selectOptions(typeOptions, current.routeType || "generic")}</select>
        </div>
        <div class="nav-field"><label for="editorVisibility">${escapeHtml(t("visibility"))}</label>
          <select id="editorVisibility" data-editor-field="visibility"${readOnly}>${selectOptions(visibilityOptions, current.visibility || "character")}</select>
        </div>
      </div>
      ${!current.publicId && state.editor.orgCodes.length ? `<div class="nav-field-row">
        <div class="nav-field"><label for="editorOwner">${escapeHtml(t("owner"))}</label>
          <select id="editorOwner" data-editor-field="ownerType"${readOnly}>
            <option value="character"${current.ownerType !== "org" ? " selected" : ""}>${escapeHtml(t("private"))}</option>
            <option value="org"${current.ownerType === "org" ? " selected" : ""}>${escapeHtml(t("org"))}</option>
          </select>
        </div>
        <div class="nav-field"><label for="editorOrg">${escapeHtml(t("orgCode"))}</label>
          <select id="editorOrg" data-editor-field="orgCode" ${current.ownerType === "org" && current.canEdit !== false ? "" : "disabled"}>
            ${state.editor.orgCodes.map((code) => `<option value="${escapeHtml(code)}"${code === current.orgCode ? " selected" : ""}>${escapeHtml(code)}</option>`).join("")}
          </select>
        </div>
      </div>` : ""}
      ${current.ownerType === "org" ? `<div class="nav-field"><label>${escapeHtml(t("ownerOrg"))}</label><input value="${escapeHtml(current.orgCode || "")}" disabled /></div>` : ""}
      <div class="nav-editor-section">${escapeHtml(t("points"))} (${points.length}/${limits.maxPoints})</div>
      <p class="nav-editor-hint">${escapeHtml(t("addPointHint"))}</p>
      <div class="nav-editor-points">${pointRows}</div>
      <div class="nav-editor-status${editor.error ? " is-error" : ""}">${escapeHtml(editorStatusText())}</div>
      ${editor.error && current.publicId ? `<button type="button" class="nav-btn nav-btn--ghost" data-editor-action="reload">${escapeHtml(t("reload"))}</button>` : ""}`;
  }

  function resetCatalog() {
    window.clearTimeout(catalogSearchTimer);
    catalogSearchTimer = 0;
    state.catalog.routes = [];
    state.catalog.current = null;
    state.catalog.scope = "all";
    state.catalog.search = "";
    state.catalog.page = 1;
    state.catalog.hasNext = false;
    state.catalog.appendList = false;
    state.catalog.loading = false;
    state.catalog.error = "";
    state.catalog.requestId = null;
    state.catalog.detailRequestId = null;
  }

  function catalogScopeLabel(scope) {
    return {
      all: t("scopeAll"),
      mine: t("scopeMine"),
      org: t("scopeOrg"),
      public: t("scopePublic"),
    }[scope] || t("scopeAll");
  }

  function catalogVisibilityLabel(visibility) {
    return {
      character: t("visibilityCharacter"),
      org: t("visibilityOrg"),
      public: t("visibilityPublic"),
    }[visibility] || String(visibility || "");
  }

  function catalogTypeLabel(type) {
    return {
      generic: t("routeTypeGeneric"),
      circuit: t("routeTypeCircuit"),
      sprint: t("routeTypeSprint"),
      patrol: t("routeTypePatrol"),
      delivery: t("routeTypeDelivery"),
      bus: t("routeTypeBus"),
    }[type] || String(type || "generic");
  }

  function refreshCatalog(page, append) {
    state.catalog.loading = true;
    state.catalog.error = "";
    state.catalog.page = Math.max(1, Number(page) || 1);
    state.catalog.appendList = append === true;
    if (append !== true) {
      state.catalog.current = null;
      state.catalog.detailRequestId = null;
      MAP.setRoutePoints([]);
    }
    state.catalog.requestId = request("routes.catalog", {
      page: state.catalog.page,
      limit: 20,
      search: state.catalog.search,
      scope: state.catalog.scope,
    });
    renderSide();
  }

  function openCatalogRoute(publicId) {
    if (!publicId) return;
    state.catalog.loading = true;
    state.catalog.error = "";
    state.catalog.current = null;
    state.catalog.detailRequestId = request("routes.catalog.get", { publicId });
    renderSide();
  }

  function setCatalogScope(scope) {
    if (!["all", "mine", "org", "public"].includes(scope)) return;
    state.catalog.scope = scope;
    state.catalog.current = null;
    state.catalog.routes = [];
    state.catalog.detailRequestId = null;
    MAP.setRoutePoints([]);
    refreshCatalog(1, false);
  }

  function backToCatalog() {
    state.catalog.current = null;
    state.catalog.detailRequestId = null;
    state.catalog.loading = false;
    MAP.setRoutePoints([]);
    renderAll();
  }

  function renderCatalogSide() {
    const catalog = state.catalog;
    const routesMeta = state.map && state.map.routes;
    const catalogDisabled = routesMeta && routesMeta.catalogEnabled !== true;

    if (catalog.current) {
      const route = catalog.current;
      const points = Array.isArray(route.points) ? route.points : [];
      const pointRows = points.length
        ? points
            .map((point, index) => `<div class="nav-point-row">
              <span class="nav-point-index">${index + 1}</span>
              <span class="nav-point-copy">${escapeHtml(formatCoords(point))}${point.z === undefined ? " · z?" : ""}</span>
            </div>`)
            .join("")
        : `<div class="nav-empty">${escapeHtml(t("emptyPoints"))}</div>`;

      sideContent.innerHTML = `<button type="button" class="nav-btn nav-btn--ghost" data-catalog-action="back">&#8592; ${escapeHtml(t("backToCatalog"))}</button>
        <div class="nav-editor-section">${escapeHtml(t("catalogDetail"))}</div>
        <h2 class="nav-catalog-title">${escapeHtml(route.title || "")}</h2>
        <p class="nav-catalog-description">${escapeHtml(route.description || t("noDescription"))}</p>
        <div class="nav-catalog-meta">
          <div><span>${escapeHtml(t("routeType"))}</span><strong>${escapeHtml(catalogTypeLabel(route.routeType))}</strong></div>
          <div><span>${escapeHtml(t("visibility"))}</span><strong>${escapeHtml(catalogVisibilityLabel(route.visibility))}</strong></div>
          <div><span>${escapeHtml(t("revision"))}</span><strong>${Number(route.revision || 1)}</strong></div>
          <div><span>${escapeHtml(t("points"))}</span><strong>${points.length}</strong></div>
        </div>
        <div class="nav-editor-section">${escapeHtml(t("points"))} (${points.length})</div>
        <div class="nav-editor-points">${pointRows}</div>
        <div class="nav-editor-status${catalog.error ? " is-error" : ""}">${escapeHtml(catalog.error || "")}</div>`;
      return;
    }

    const scopeButtons = ["all", "mine"]
      .concat(state.editor.orgCodes.length ? ["org"] : [])
      .concat(["public"])
      .map((scope) => `<button type="button" class="${catalog.scope === scope ? "is-active" : ""}" data-catalog-scope="${scope}">${escapeHtml(catalogScopeLabel(scope))}</button>`)
      .join("");

    let list = "";
    if (catalog.loading) {
      list = `<div class="nav-empty">${escapeHtml(t("loading"))}</div>`;
    } else if (catalog.error) {
      list = `<div class="nav-empty">${escapeHtml(catalog.error)}</div>`;
    } else if (!catalog.routes.length) {
      list = `<div class="nav-empty">${escapeHtml(t("catalogEmpty"))}</div>`;
    } else {
      list = catalog.routes
        .map((route) => `<button type="button" class="nav-editor-route" data-catalog-action="open" data-route-id="${escapeHtml(route.publicId)}">
          <span class="nav-editor-route-copy">
            <strong>${escapeHtml(route.title || t("editorTitle"))}</strong>
            <small>${escapeHtml(catalogTypeLabel(route.routeType))} · ${escapeHtml(t("pointsCount", { count: route.pointCount }))} · ${escapeHtml(t("distance", { km: (Number(route.totalDistance || 0) / 1000).toFixed(2) }))}</small>
          </span>
          <span class="nav-editor-badge${route.isPublished ? "" : " is-draft"}">${escapeHtml(route.isPublished ? t("publishedBadge") : t("draft"))}</span>
        </button>`)
        .join("");
    }

    sideContent.innerHTML = `<div class="nav-editor-toolbar">
        <input id="catalogSearch" data-catalog-search type="search" aria-label="${escapeHtml(t("catalogSearchPlaceholder"))}" placeholder="${escapeHtml(t("catalogSearchPlaceholder"))}" value="${escapeHtml(catalog.search)}" />
        <button type="button" class="nav-btn nav-btn--ghost" data-catalog-action="refresh" aria-label="${escapeHtml(t("refresh"))}">&#8635;</button>
      </div>
      <div class="nav-catalog-scopes">${scopeButtons}</div>
      ${catalogDisabled ? `<div class="nav-editor-warning">${escapeHtml(t("catalogDisabled"))}</div>` : ""}
      <div class="nav-editor-section">${escapeHtml(t("routes"))}</div>
      ${list}
      ${catalog.hasNext ? `<button type="button" class="nav-btn nav-btn--ghost" data-catalog-action="more">${escapeHtml(t("loadMore"))}</button>` : ""}
      <div class="nav-editor-status${catalog.error ? " is-error" : ""}">${escapeHtml(catalog.error || "")}</div>`;
  }

  function renderSide() {
    if (state.mode === "editor") {
      renderEditorSide();
      return;
    }
    if (state.mode === "catalog") {
      renderCatalogSide();
      return;
    }
    sideContent.replaceChildren();

    if (state.loading) {
      sideContent.appendChild(element("div", "nav-empty", "Carregando dados do mapa..."));
      return;
    }

    if (state.error) {
      sideContent.appendChild(element("div", "nav-empty", state.error));
      return;
    }

    if (state.search.trim() !== "") {
      const results = filteredPois();
      sideContent.appendChild(
        element("div", "nav-section", `${results.length} resultado${results.length === 1 ? "" : "s"}`),
      );
      if (!results.length) {
        sideContent.appendChild(element("div", "nav-empty", "Nenhum local encontrado com esse termo."));
        return;
      }
      results.forEach((poi) => sideContent.appendChild(poiButton(poi)));
      return;
    }

    if (state.tab === "layers") {
      if (!state.layers.length) {
        sideContent.appendChild(element("div", "nav-empty", "Nenhuma camada publica disponivel."));
        return;
      }
      sideContent.appendChild(element("div", "nav-section", "Camadas do mapa"));
      renderLayers();
      return;
    }

    if (state.tab === "favorites") {
      renderFavorites();
      return;
    }

    renderRecents();
  }

  function renderEditorFooter() {
    const editor = state.editor;
    const current = editor.current;

    editorActions.hidden = false;
    favoriteButton.hidden = true;
    waypointButton.hidden = true;
    confirmButton.hidden = true;
    selectionKicker.textContent = t("editorKicker");

    const points = currentPoints();
    if (current) {
      selectionLabel.textContent = current.title || t("newDraft");
      const stateLabel = editor.dirty
        ? t("unsaved")
        : current.isPublished
          ? `${t("publishedBadge")} · ${t("revision", { revision: current.revision })}`
          : `${t("draft")} · ${t("revision", { revision: current.revision })}`;
      selectionCoords.textContent = `${t("pointsCount", { count: points.length })} · ${stateLabel}`;
    } else {
      selectionLabel.textContent = t("editorTitle");
      selectionCoords.textContent = editor.error || t("noRoutes");
    }

    const confirmingDelete = editor.confirmDelete === true;
    const confirmingDiscard = editor.confirmDiscard === true;
    const canEdit = current && current.canEdit !== false;

    editorSaveButton.hidden = confirmingDelete || confirmingDiscard || !current;
    editorSaveButton.disabled = !canEdit || editor.saving;
    editorSaveButton.textContent = t("save");

    editorPublishButton.hidden = confirmingDelete || confirmingDiscard || !current;
    editorPublishButton.disabled = !current || !current.publicId || editor.dirty || editor.saving || current.visibility !== "public";
    editorPublishButton.textContent = current && current.isPublished ? t("unpublish") : t("publish");

    editorDeleteButton.hidden = !current;
    editorDeleteButton.disabled = !canEdit || editor.saving;
    editorDeleteButton.textContent = confirmingDiscard
      ? t("discard")
      : confirmingDelete
        ? t("confirmDelete")
        : t("delete");

    editorCloseButton.textContent = confirmingDelete || confirmingDiscard ? t("cancel") : t("close");
  }

  function renderCatalogFooter() {
    editorActions.hidden = true;
    favoriteButton.hidden = true;
    waypointButton.hidden = true;
    confirmButton.hidden = true;
    selectionKicker.textContent = t("catalogKicker");

    const route = state.catalog.current;
    if (route) {
      const points = Array.isArray(route.points) ? route.points : [];
      selectionLabel.textContent = route.title || t("catalogTitle");
      selectionCoords.textContent = `${t("pointsCount", { count: points.length })} · ${catalogVisibilityLabel(route.visibility)} · ${t("revision", { revision: route.revision })}`;
    } else {
      selectionLabel.textContent = t("catalogTitle");
      selectionCoords.textContent = state.catalog.error
        || (state.catalog.routes.length
          ? t("catalogSelectHint")
          : t("catalogEmpty"));
    }
  }

  function renderFooter() {
    if (state.mode === "editor") {
      renderEditorFooter();
      return;
    }
    if (state.mode === "catalog") {
      renderCatalogFooter();
      return;
    }

    editorActions.hidden = true;
    favoriteButton.hidden = false;
    waypointButton.hidden = false;
    selectionKicker.textContent = "Destino";

    const selected = state.selected;
    selectionLabel.textContent = selected ? selected.label || "Destino" : "Nenhum ponto selecionado";
    selectionCoords.textContent = selected
      ? formatCoords(selected)
      : "Clique no mapa ou escolha um local na lista.";

    waypointButton.disabled = !selected;
    favoriteButton.disabled = !selected;
    confirmButton.hidden = state.mode !== "picker";
    confirmButton.disabled = !selected;
  }

  function renderAll() {
    if (mapHint) {
      mapHint.textContent = state.mode === "catalog"
        ? t("mapHintCatalog")
        : state.mode === "editor"
          ? t("mapHintEditor")
          : t("mapHintBrowse");
    }
    renderTabs();
    renderSide();
    renderFooter();
    renderLegend();
  }

  function selectCustom(coords, extra) {
    const selection = {
      x: Number(coords.x),
      y: Number(coords.y),
      z: coords.z !== undefined && coords.z !== null ? Number(coords.z) : undefined,
      poiId: coords.poiId || (extra && extra.poiId) || undefined,
      label: coords.label || (extra && extra.label) || "Destino",
    };
    state.selected = selection;
    MAP.select(selection);
    renderFooter();
  }

  function selectPoi(poi) {
    if (!state.enabledLayers.has(poi.layer)) {
      showToast("Ative a camada deste ponto para seleciona-lo.", true);
      return;
    }
    selectCustom({
      x: poi.x,
      y: poi.y,
      z: poi.z,
      poiId: poi.id,
      label: poi.label,
      layer: poi.layer,
    });
  }

  function handleMapSelection(selection, poi) {
    if (state.mode === "catalog") {
      MAP.select(null);
      return;
    }
    if (state.mode === "editor") {
      addEditorPoint(selection);
      return;
    }

    if (poi) {
      selectPoi(poi);
      return;
    }

    if (state.mode === "picker" && state.options.requirePoi === true) {
      showToast("Este seletor exige um local cadastrado.", true);
      return;
    }
    if (state.mode === "picker" && state.options.allowFreePin === false) {
      showToast("Escolha um destino da lista de locais.", true);
      return;
    }

    state.selected = selection;
    renderFooter();
  }

  function hydrateRoute(route) {
    if (!route || typeof route !== "object") return null;
    if (route.orgCode === undefined) route.orgCode = route.ownerOrgCode || "";
    return route;
  }

  function handleRouteResponse(payload) {
    const action = payload.action;
    const data = payload.data || {};

    if (action === "routes.list") {
      const incoming = Array.isArray(data.routes) ? data.routes : [];
      state.editor.routes = state.editor.appendList
        ? state.editor.routes.concat(incoming)
        : incoming;
      state.editor.appendList = false;
      state.editor.page = Number(data.page) || 1;
      state.editor.hasNext = data.hasNext === true;
      state.editor.loading = false;
      state.editor.error = "";
      renderSide();
      return;
    }

    if (action === "routes.get") {
      const route = hydrateRoute(data.route);
      if (!route || !Array.isArray(route.points)) {
        state.editor.loading = false;
        state.editor.error = t("invalid");
        renderSide();
        return;
      }
      state.editor.current = route;
      state.editor.dirty = false;
      state.editor.editingSinceSave = false;
      state.editor.loading = false;
      state.editor.error = "";
      state.editor.status = "";
      state.editor.confirmDelete = false;
      state.editor.confirmDiscard = false;
      state.editor.selectedPoint = route.points.length ? 0 : -1;
      MAP.setRoutePoints(route.points, state.editor.selectedPoint);
      if (route.points.length) MAP.fitPoints(route.points);
      state.editor.loading = false;
      renderAll();
      return;
    }

    if (action === "routes.create" || action === "routes.update"
      || action === "routes.publish" || action === "routes.unpublish") {
      const route = hydrateRoute(data.route);
      state.editor.saving = false;
      if (!route) {
        state.editor.error = t("requestFailed");
        renderAll();
        return;
      }
      const previous = state.editor.current;
      const localEdits = state.editor.editingSinceSave === true && previous;
      state.editor.current = route;
      if (localEdits) {
        route.title = previous.title;
        route.description = previous.description;
        route.routeType = previous.routeType;
        route.visibility = previous.visibility;
        route.points = previous.points;
        route.pointCount = previous.points.length;
        route.orgCode = previous.orgCode;
      }
      state.editor.dirty = localEdits ? true : false;
      state.editor.editingSinceSave = false;
      state.editor.error = "";
      state.editor.status = action === "routes.publish"
        ? t("published")
        : action === "routes.unpublish"
          ? t("unpublished")
          : t("saved");
      state.editor.confirmDelete = false;
      state.editor.confirmDiscard = false;
      MAP.setRoutePoints(state.editor.current.points || [], state.editor.selectedPoint);
      renderAll();
      refreshRouteList(state.editor.page || 1);
      return;
    }

    if (action === "routes.delete") {
      state.editor.current = null;
      state.editor.dirty = false;
      state.editor.confirmDelete = false;
      state.editor.confirmDiscard = false;
      state.editor.selectedPoint = -1;
      state.editor.error = "";
      state.editor.status = t("deleted");
      MAP.setRoutePoints([]);
      renderAll();
      refreshRouteList(1);
    }
  }

  function handleCatalogResponse(payload) {
    if (!state.open) return;
    const action = payload.action;
    const data = payload.data || {};

    if (action === "routes.catalog") {
      if (payload.requestId && payload.requestId !== state.catalog.requestId) return;
      const incoming = Array.isArray(data.routes) ? data.routes : [];
      state.catalog.routes = state.catalog.appendList
        ? state.catalog.routes.concat(incoming)
        : incoming;
      state.catalog.appendList = false;
      state.catalog.page = Number(data.page) || 1;
      state.catalog.hasNext = data.hasNext === true;
      state.catalog.loading = false;
      state.catalog.error = "";
      renderSide();
      return;
    }

    if (action === "routes.catalog.get") {
      if (payload.requestId && payload.requestId !== state.catalog.detailRequestId) return;
      const route = hydrateRoute(data.route);
      state.catalog.loading = false;
      if (!route || !Array.isArray(route.points)) {
        state.catalog.current = null;
        state.catalog.error = t("catalogUnavailable");
        renderAll();
        return;
      }
      state.catalog.current = route;
      state.catalog.error = "";
      MAP.setRoutePoints(route.points, -1);
      if (route.points.length) MAP.fitPoints(route.points);
      renderAll();
    }
  }

  function handleResponse(payload) {
    if (!payload || typeof payload !== "object") return;

    if (payload.ok !== true) {
      if (typeof payload.action === "string" && payload.action.indexOf("routes.catalog") === 0) {
        if (!state.open) return;
        state.catalog.loading = false;
        state.catalog.error = errorMessage(payload.error);
        renderAll();
        showToast(state.catalog.error, true);
        return;
      }
      if (typeof payload.action === "string" && payload.action.indexOf("routes.") === 0) {
        state.editor.loading = false;
        state.editor.saving = false;
        state.editor.error = errorMessage(payload.error);
        if (payload.error === "route_conflict") state.editor.dirty = true;
        state.editor.editingSinceSave = true;
        renderAll();
        showToast(state.editor.error, true);
        return;
      }
      if (payload.error === "service_not_ready") {
        state.loading = false;
        state.error = "Servico de navegacao indisponivel.";
        renderSide();
      }
      const silent = ["rate_limited"].includes(payload.error);
      if (!silent) showToast(errorMessage(payload.error), true);
      return;
    }

    const data = payload.data || {};

    if (typeof payload.action === "string" && payload.action.indexOf("routes.catalog") === 0) {
      handleCatalogResponse(payload);
      return;
    }

    if (typeof payload.action === "string" && payload.action.indexOf("routes.") === 0) {
      handleRouteResponse(payload);
      return;
    }

    if (payload.action === "bootstrap") {
      applyBootstrap(data);
      return;
    }

    if (payload.action === "position.current") {
      if (state.recenterPending && data && Number.isFinite(Number(data.x))) {
        MAP.centerOnWorld(data, Math.max(3, Number(state.options.zoom) || 3));
      }
      state.recenterPending = false;
      return;
    }

    if (payload.action === "favorites.add") {
      if (data.favorite) {
        const index = state.favorites.findIndex((item) => item.id === data.favorite.id);
        if (index >= 0) state.favorites[index] = data.favorite;
        else state.favorites.unshift(data.favorite);
        renderSide();
        showToast("Favorito salvo.");
      }
      return;
    }

    if (payload.action === "favorites.remove") {
      state.favorites = state.favorites.filter((item) => Number(item.id) !== Number(state.lastRemovedFavoriteId));
      request("favorites.list", {});
      showToast("Favorito removido.");
      return;
    }

    if (payload.action === "favorites.list") {
      state.favorites = Array.isArray(data.favorites) ? data.favorites : [];
      if (state.tab === "favorites") renderSide();
      return;
    }

    if (payload.action === "recents.add") {
      return;
    }

    if (payload.action === "recents.list") {
      state.recents = Array.isArray(data.recents) ? data.recents : [];
      if (state.tab === "recents") renderSide();
      return;
    }

    if (payload.action === "waypoint.set" && payload.ok === true) {
      request("recents.add", {
        label: state.selected ? state.selected.label : "Destino",
        x: state.selected ? state.selected.x : 0,
        y: state.selected ? state.selected.y : 0,
        z: state.selected ? state.selected.z : undefined,
        poiId: state.selected ? state.selected.poiId : undefined,
      });
    }
  }

  function errorMessage(code) {
    const messages = {
      service_not_ready: "Servico de navegacao indisponivel.",
      rate_limited: "Aguarde alguns segundos e tente novamente.",
      favorite_limit_reached: "Limite de favoritos atingido para este personagem.",
      favorite_label_invalid: "Informe um nome valido para o favorito.",
      favorite_id_invalid: "Favorito invalido.",
      favorite_not_found: "Este favorito nao existe mais.",
      database_unavailable: "Persistencia indisponivel no momento.",
      coords_invalid: "Coordenada invalida.",
      coords_out_of_range: "Coordenada fora da area permitida.",
      z_out_of_range: "Altura invalida.",
      unknown_action: "Acao nao suportada.",
      picker_busy: "Ja existe um seletor de destino aberto.",
      selection_invalid: "Selecao invalida.",
      routes_disabled: "Editor de rotas desabilitado no servidor.",
      routes_unavailable: "Persistencia de rotas indisponivel. Aplique a migration 002.",
      quota_unavailable: "Quota transacional indisponivel. Aplique a migration 003.",
      catalog_disabled: "Catalogo de rotas desabilitado no servidor.",
      catalog_unavailable: "Catalogo de rotas indisponivel no momento.",
      route_not_found: "Rota nao encontrada.",
      route_forbidden: "Sem permissao para esta rota.",
      route_conflict: "A rota mudou em outro lugar. Recarregue antes de salvar.",
      route_limit_reached: "Limite de rotas atingido.",
      route_title_invalid: "Informe um nome valido para a rota.",
      route_points_invalid: "Pontos da rota invalidos.",
      route_points_too_few: "Adicione pelo menos 2 pontos.",
      route_points_too_many: "Limite de pontos atingido.",
      route_points_duplicate: "Pontos consecutivos muito proximos.",
      route_too_long: "Rota longa demais.",
      route_point_out_of_bounds: "Ponto fora da area do mapa.",
      route_visibility_invalid: "Visibilidade invalida para esta rota.",
      route_org_required: "Informe a organizacao proprietaria.",
      route_org_forbidden: "Voce nao pertence a essa organizacao.",
      route_publish_requires_public: "Defina a visibilidade como publica antes de publicar.",
      route_payload_too_large: "Rota grande demais para salvar.",
      route_revision_invalid: "Versao da rota invalida.",
      route_id_invalid: "Identificador de rota invalido.",
      route_type_invalid: "Tipo de rota invalido.",
      serialization_unavailable: "Falha ao serializar a rota.",
    };
    return messages[code] || "Nao foi possivel concluir a acao.";
  }

  function applyBootstrap(data) {
    state.map = data.map || null;
    const allowedLayers = Array.isArray(state.options.layers) && state.options.layers.length
      ? new Set(state.options.layers)
      : null;
    const layers = Array.isArray(data.layers) ? data.layers : [];
    const pois = Array.isArray(data.pois) ? data.pois : [];

    state.layers = allowedLayers ? layers.filter((layer) => allowedLayers.has(layer.id)) : layers;
    state.pois = allowedLayers ? pois.filter((poi) => allowedLayers.has(poi.layer)) : pois;
    state.favorites = Array.isArray(data.favorites) ? data.favorites : [];
    state.recents = Array.isArray(data.recents) ? data.recents : [];
    state.editor.orgCodes = data.editor && Array.isArray(data.editor.orgCodes)
      ? data.editor.orgCodes.filter((code) => typeof code === "string")
      : [];
    state.loading = false;
    state.error = "";

    if (!state.map) {
      state.error = "Configuracao de mapa indisponivel.";
      renderAll();
      return;
    }

    if (window.MZNavI18n) {
      window.MZNavI18n.set(state.map.locale || "pt-BR");
    }

    if (!allowedLayers && state.map.blips && state.map.blips.enabled === true) {
      state.layers = state.layers.concat(LOCAL_LAYERS.map((layer) => ({
        id: layer.id,
        label: t(layer.labelKey),
        kind: layer.kind,
        local: true,
        defaultEnabled: layer.defaultEnabled,
        order: 1000,
      })));
    }

    MAP.configure(state.map);
    state.enabledLayers = new Set(
      state.layers.filter((layer) => layer.defaultEnabled !== false).map((layer) => layer.id),
    );
    MAP.setData(state.pois, state.layers);
    MAP.setVisibleLayers(state.enabledLayers);

    sourceBadge.textContent = state.map.tiles && state.map.tiles.enabled
      ? "Atlas em tiles"
      : "Atlas Los Santos";
    sourceBadge.classList.remove("is-warn");

    const zoom = state.options.zoom || state.map.defaultZoom || 2;

    if (pendingInitial) {
      selectCustom(pendingInitial);
      MAP.centerOnWorld(pendingInitial, zoom);
      pendingInitial = null;
      state.recenterPending = false;
    } else if (state.selected) {
      MAP.centerOnWorld(state.selected, zoom);
      state.recenterPending = false;
    } else if (!MAP.fitToPois(state.pois)) {
      MAP.setCamera({ cx: P.MAP_UNITS / 2, cy: P.MAP_UNITS / 2, zoom });
    }

    if (state.mode === "editor" && state.map.routes) {
      if (state.map.routes.enabled === false) {
        state.editor.loading = false;
        state.editor.error = t("disabled");
      } else if (state.map.routes.available === false) {
        state.editor.loading = false;
        state.editor.error = t("unavailable");
      } else if (!state.editor.routes.length && !state.editor.loading) {
        refreshRouteList(1);
      }
    }

    if (state.mode === "catalog" && state.map.routes) {
      if (state.map.routes.enabled === false) {
        state.catalog.loading = false;
        state.catalog.error = t("disabled");
      } else if (state.map.routes.available === false) {
        state.catalog.loading = false;
        state.catalog.error = t("unavailable");
      } else if (state.map.routes.catalogEnabled !== true) {
        state.catalog.loading = false;
        state.catalog.error = t("catalogDisabled");
      } else if (!state.catalog.routes.length && !state.catalog.loading) {
        refreshCatalog(1, false);
      }
    }

    renderAll();
  }

  function resetState() {
    state.map = null;
    state.layers = [];
    state.pois = [];
    state.favorites = [];
    state.recents = [];
    state.enabledLayers = new Set();
    state.selected = null;
    state.tab = "layers";
    state.search = "";
    state.loading = true;
    state.error = "";
    pendingInitial = null;
    searchInput.value = "";
    MAP.select(null);
    MAP.setData([], []);
    MAP.clearLocalMarkers();
    if (blipStore && NAV_BLIPS) NAV_BLIPS.resetStore(blipStore, -1);
    resetEditor();
    resetCatalog();
    renderAll();
  }

  function open(payload) {
    state.open = true;
    state.mode = payload.mode === "picker"
      ? "picker"
      : payload.mode === "editor"
        ? "editor"
        : payload.mode === "catalog"
          ? "catalog"
          : "browse";
    state.requestId = payload.requestId || null;
    state.options = payload.options && typeof payload.options === "object" ? payload.options : {};

    resetState();
    root.hidden = false;
    root.setAttribute("aria-hidden", "false");

    if (state.mode === "editor") {
      modeLabel.textContent = t("editorKicker");
      titleLabel.textContent = t("editorTitle");
      headerSearch.hidden = true;
      state.editor.loading = true;
      request("routes.list", { page: 1, limit: 20, search: "" });
    } else if (state.mode === "catalog") {
      modeLabel.textContent = t("catalogKicker");
      titleLabel.textContent = t("catalogTitle");
      headerSearch.hidden = true;
      state.catalog.loading = true;
      state.catalog.requestId = request("routes.catalog", {
        page: 1,
        limit: 20,
        search: "",
        scope: state.catalog.scope,
      });
    } else if (state.mode === "picker") {
      modeLabel.textContent = "Selecionar destino";
      titleLabel.textContent = state.options.title || "Escolha um destino";
      headerSearch.hidden = false;
    } else {
      modeLabel.textContent = "Navegacao";
      titleLabel.textContent = "Mapa";
      headerSearch.hidden = false;
    }

    if (state.options.initialX !== undefined && state.options.initialY !== undefined) {
      pendingInitial = { x: state.options.initialX, y: state.options.initialY, label: "Destino inicial" };
    } else if (state.options.initial && typeof state.options.initial === "object") {
      pendingInitial = {
        x: Number(state.options.initial.x),
        y: Number(state.options.initial.y),
        label: "Destino inicial",
      };
    }

    request("bootstrap", {});
    if (state.mode !== "editor") {
      searchInput.focus({ preventScroll: true });
    }
  }

  function close() {
    state.open = false;
    state.requestId = null;
    root.hidden = true;
    root.setAttribute("aria-hidden", "true");
    headerSearch.hidden = false;
    editorActions.hidden = true;
    MAP.select(null);
    MAP.clearLocalMarkers();
    if (blipStore && NAV_BLIPS) NAV_BLIPS.resetStore(blipStore, -1);
    state.selected = null;
    resetEditor();
    resetCatalog();
    state.mode = "browse";
  }

  function confirmSelection() {
    if (state.mode !== "picker") return;
    if (!state.selected) {
      showToast("Selecione um destino antes de confirmar.", true);
      return;
    }
    const selection = {
      x: state.selected.x,
      y: state.selected.y,
      z: state.selected.z,
      poiId: state.selected.poiId,
      label: state.selected.label,
      zReliable: state.selected.z !== undefined && state.selected.z !== null,
    };
    post("navigationConfirm", { requestId: state.requestId, selection });
  }

  function cancelSelection() {
    if (state.mode === "editor") {
      requestEditorClose();
      return;
    }
    if (state.mode === "catalog") {
      post("navigationClose", {});
      return;
    }
    if (state.mode === "picker") {
      post("navigationCancel", { requestId: state.requestId });
      return;
    }
    post("navigationClose", {});
  }

  function setWaypoint() {
    if (!state.selected) return;
    request("waypoint.set", {
      x: state.selected.x,
      y: state.selected.y,
      z: state.selected.z,
    });
    showToast("Waypoint enviado ao GPS.");
  }

  function addFavorite() {
    if (!state.selected) return;
    let label = String(state.selected.label || "").trim();
    if (!label || label === "Ponto no mapa") {
      label = `Ponto ${Math.round(state.selected.x)}, ${Math.round(state.selected.y)}`;
    }
    request("favorites.add", {
      label: label.slice(0, 80),
      x: state.selected.x,
      y: state.selected.y,
      z: state.selected.z,
      poiId: state.selected.poiId,
    });
  }

  function bindUi() {
    MAP.init(svg, {
      onSelect: handleMapSelection,
      onCamera: (camera) => {
        if (!state.map) return;
        const world = P.mapToWorld(camera.cx, camera.cy, state.map.bounds);
        coordsLabel.textContent = world
          ? `${world.x.toFixed(0)}, ${world.y.toFixed(0)}`
          : "0, 0";
      },
    });

    searchInput.addEventListener("input", () => {
      state.search = searchInput.value;
      renderSide();
    });

    searchInput.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && state.search.trim() !== "") {
        const first = filteredPois()[0];
        if (first) {
          selectPoi(first);
          MAP.centerOnWorld(first, Math.max(3, MAP.getZoom()));
        }
      }
      if (event.key === "Escape") {
        searchInput.blur();
        state.search = "";
        searchInput.value = "";
        renderSide();
      }
      event.stopPropagation();
    });

    document.querySelectorAll("[data-tab]").forEach((button) => {
      button.addEventListener("click", () => {
        state.tab = button.getAttribute("data-tab");
        state.search = "";
        searchInput.value = "";
        renderTabs();
        renderSide();
      });
    });

    document.querySelectorAll("[data-zoom]").forEach((button) => {
      button.addEventListener("click", () => {
        const action = button.getAttribute("data-zoom");
        if (action === "in") MAP.zoomBy(0.5);
        else if (action === "out") MAP.zoomBy(-0.5);
        else MAP.resetCamera();
      });
    });

    waypointButton.addEventListener("click", setWaypoint);
    favoriteButton.addEventListener("click", addFavorite);
    confirmButton.addEventListener("click", confirmSelection);
    closeButton.addEventListener("click", cancelSelection);

    editorSaveButton.addEventListener("click", () => {
      if (state.editor.confirmDiscard || state.editor.confirmDelete) {
        cancelEditorConfirmation();
        return;
      }
      saveEditor();
    });

    editorPublishButton.addEventListener("click", () => {
      setEditorPublished(!(state.editor.current && state.editor.current.isPublished));
    });

    editorDeleteButton.addEventListener("click", () => {
      if (state.editor.confirmDiscard) {
        discardEditor(state.editor.discardIntent || "list");
        return;
      }
      requestEditorDelete();
    });

    editorCloseButton.addEventListener("click", () => {
      if (state.editor.confirmDelete || state.editor.confirmDiscard) {
        cancelEditorConfirmation();
        return;
      }
      requestEditorClose();
    });

    document.addEventListener("click", (event) => {
      if (state.mode !== "catalog") return;
      const scopeNode = event.target.closest("[data-catalog-scope]");
      if (scopeNode) {
        setCatalogScope(scopeNode.getAttribute("data-catalog-scope"));
        return;
      }
      const node = event.target.closest("[data-catalog-action]");
      if (!node) return;
      const action = node.getAttribute("data-catalog-action");
      if (action === "open") {
        openCatalogRoute(node.getAttribute("data-route-id"));
      } else if (action === "back") {
        backToCatalog();
      } else if (action === "refresh") {
        refreshCatalog(1, false);
      } else if (action === "more") {
        refreshCatalog((state.catalog.page || 1) + 1, true);
      }
    });

    document.addEventListener("input", (event) => {
      if (state.mode !== "catalog") return;
      if (event.target.matches("[data-catalog-search]")) {
        state.catalog.search = event.target.value;
        window.clearTimeout(catalogSearchTimer);
        catalogSearchTimer = window.setTimeout(() => {
          if (state.mode !== "catalog" || !state.open) return;
          refreshCatalog(1, false);
        }, 280);
      }
    });

    document.addEventListener("keydown", (event) => {
      if (state.mode !== "catalog") return;
      if (event.target.matches("[data-catalog-search]") && event.key === "Enter") {
        state.catalog.search = event.target.value;
        window.clearTimeout(catalogSearchTimer);
        refreshCatalog(1, false);
      }
    });

    document.addEventListener("click", (event) => {
      if (state.mode !== "editor") return;
      const node = event.target.closest("[data-editor-action]");
      if (!node) return;
      const action = node.getAttribute("data-editor-action");
      const index = Number(node.getAttribute("data-index"));
      const routeId = node.getAttribute("data-route-id");

      if (action === "new") {
        if (state.editor.dirty) {
          state.editor.confirmDiscard = true;
          state.editor.discardIntent = "new";
          state.editor.confirmDelete = false;
          renderFooter();
          return;
        }
        newEditorDraft();
      } else if (action === "refresh") {
        refreshRouteList(1);
      } else if (action === "more") {
        refreshRouteList((state.editor.page || 1) + 1, true);
      } else if (action === "open") {
        openEditorRoute(routeId);
      } else if (action === "back") {
        backToRouteList();
      } else if (action === "reload") {
        reloadEditorRoute();
      } else if (action === "select-point") {
        selectEditorPoint(index);
      } else if (action === "up") {
        moveEditorPoint(index, -1);
      } else if (action === "down") {
        moveEditorPoint(index, 1);
      } else if (action === "remove") {
        removeEditorPoint(index);
      }
    });

    document.addEventListener("input", (event) => {
      if (state.mode !== "editor") return;
      const field = event.target.getAttribute("data-editor-field");
      if (field) {
        setEditorField(field, event.target.value);
        return;
      }
      if (event.target.matches("[data-editor-search]")) {
        state.editor.search = event.target.value;
      }
    });

    document.addEventListener("change", (event) => {
      if (state.mode !== "editor") return;
      const field = event.target.getAttribute("data-editor-field");
      if (field === "routeType" || field === "visibility") {
        setEditorField(field, event.target.value);
      }
    });

    document.addEventListener("keydown", (event) => {
      if (state.mode !== "editor") return;
      if (event.target.matches("[data-editor-search]") && event.key === "Enter") {
        state.editor.search = event.target.value;
        refreshRouteList(1);
      }
    });

    const locateButton = document.querySelector("[data-locate]");
    if (locateButton) {
      locateButton.addEventListener("click", () => {
        state.recenterPending = true;
        request("position.current", {});
      });
    }

    document.addEventListener("keydown", (event) => {
      if (!state.open) return;

      if (event.key === "Escape") {
        event.preventDefault();
        if (state.mode === "editor") {
          if (state.editor.confirmDelete || state.editor.confirmDiscard) {
            cancelEditorConfirmation();
          } else {
            requestEditorClose();
          }
          return;
        }
        if (state.mode === "catalog") {
          post("navigationClose", {});
          return;
        }
        if (state.search) {
          state.search = "";
          searchInput.value = "";
          renderSide();
          return;
        }
        cancelSelection();
        return;
      }

      if (document.activeElement === searchInput) return;

      if (event.key === "Enter") {
        confirmSelection();
        return;
      }

      if (event.key === "/") {
        event.preventDefault();
        searchInput.focus();
        return;
      }

      const camera = MAP.getCamera();
      const step = (P.MAP_UNITS / Math.pow(2, camera.zoom)) * 0.18;

      if (event.key === "ArrowLeft") {
        event.preventDefault();
        MAP.setCamera({ ...camera, cx: camera.cx - step });
      } else if (event.key === "ArrowRight") {
        event.preventDefault();
        MAP.setCamera({ ...camera, cx: camera.cx + step });
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        MAP.setCamera({ ...camera, cy: camera.cy - step });
      } else if (event.key === "ArrowDown") {
        event.preventDefault();
        MAP.setCamera({ ...camera, cy: camera.cy + step });
      } else if (event.key === "+" || event.key === "=") {
        event.preventDefault();
        MAP.zoomBy(0.5);
      } else if (event.key === "-" || event.key === "_") {
        event.preventDefault();
        MAP.zoomBy(-0.5);
      }
    });

    window.addEventListener("message", (event) => {
      const payload = event.data;
      if (!payload || typeof payload !== "object") return;

      if (payload.action === "navigation:open") {
        open(payload);
        return;
      }
      if (payload.action === "navigation:close") {
        close();
        return;
      }
      if (payload.action === "navigation:response") {
        handleResponse(payload.data);
        return;
      }
      if (payload.action === "navigation:blips:reset" || payload.action === "navigation:blips:delta") {
        handleBlipMessage(payload);
      }
    });
  }

  bindUi();
  // Sinal leve para smoke tests da NUI (nao exposto como contrato publico).
  document.documentElement.setAttribute("data-nav-ready", "1");
})();
