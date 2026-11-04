# N0 - Baseline real do `mz_navigation`

Data: 2026-10-24  
Escopo: auditoria sem alteracao de codigo. Todos os caminhos abaixo sao reais
no workspace `D:\git-hub\repo_oficial`.

## 1. Arvore auditada

```text
mz_navigation/
  fxmanifest.lua
  config.lua
  config/seed.lua
  shared/geo.lua
  shared/schema.lua
  shared/routes.lua
  client/gps.lua
  client/picker.lua
  client/main.lua
  server/registry.lua
  server/repository.lua
  server/route_repository.lua
  server/route_service.lua
  server/service.lua
  server/main.lua
  sql/001_mz_navigation.sql
  sql/002_mz_navigation_routes.sql
  sql/003_mz_navigation_route_quotas.sql
  web/index.html
  web/css/navigation.css
  web/js/projection.js
  web/js/strings.js
  web/js/map.js
  web/js/app.js
  web/assets/los-santos-atlas.webp
  web/assets/atlas.json
  web/tiles/README.md
  tests/*.lua
  tests/*.test.js
  tests/browser/navigation.spec.js
  docs/
```

Nao existe `.git` neste workspace. Nao foi criada branch, worktree ou commit.
Backup pre-change: `_local_backups/mz_navigation_pre_wave_n_20261024/`.

## 2. Manifest e stack

- `fx_version 'cerulean'`, `game 'gta5'`, `lua54 'yes'`.
- `ui_page 'web/index.html'`; dependencias: `oxmysql`, `mz_core`.
- Client: `gps.lua`, `picker.lua`, `main.lua` (antes desta wave).
- Web: JavaScript vanilla + SVG, sem framework, sem CDN, sem `eval`.
- Assets: atlas WebP local 4096x4096 (601 KB), metadados em
  `web/assets/atlas.json`; tiles de alta resolucao desabilitados.
- `web/tiles/` contem apenas README; nao ha tiles distribuidos.

## 3. Mapa, projecao e viewport (antes)

- `web/js/projection.js`: projecao afim local, `MAP_UNITS = 1000`.
  `u = (x-minX)/(maxX-minX)`, `v = (maxY-y)/(maxY-minY)`.
- Bounds em `config.lua`: `x[-4600,5000]`, `y[-4600,7400]`.
- `shared/geo.lua` repete a formula para Lua (validacao server-side).
- `tilePixel`/`tileWorldRect` usam a transformacao legada
  `scaleX=0.02072, offsetX=117.3, scaleY=0.0205, offsetY=172.8`.
- O atlas e posicionado por `tileWorldRect(0,0,0,...)`; trocar sprite/blip
  nunca alterou tile. Nao ha gerador de tiles neste resource.
- Calibracao contra o pause map **nao existia** e continua nao provada
  (ver `web/assets/map-calibration.json`, `status: provisional`).

## 4. Camadas, POIs e renderer (antes)

- POIs e camadas vem do servidor por `bootstrap` (`Registry.Collect` com ACL).
- `web/js/map.js` desenha SVG com grupos `base`, `tiles`, `regions`, `grid`,
  `districts`, `pois`, `route`, `candidate`.
- `renderMarkers()` faz `group.replaceChildren()` e recria todos os POIs quando
  o nivel inteiro de zoom muda ou a camada e alternada. E um rebuild de POIs,
  nao de tiles.
- `renderTiles()` so roda quando `Config.Map.tiles.enabled` e um atlas
  licenciado existe; falhas de tile sao ignoradas individualmente.
- `renderLayers()` no painel lateral era chamado dentro do proprio clique da
  camada sem limpar `#navSideContent`, produzindo linhas duplicadas no painel
  depois de alternar uma camada. Defeito observado e corrigido nesta wave.

## 5. GPS e waypoint (antes)

- `client/gps.lua` usa `SetNewWaypoint(x,y)`, `SetWaypointOff()` e
  `GetFirstBlipInfoId(8)` para ler o waypoint pessoal.
- `z` e opcional; `GetGroundZFor_3dCoord` e usado com probes decrescentes.
- O waypoint sprite 8 nao era tratado como POI e nao deve entrar no leitor
  nativo.

## 6. Blips nativos (antes)

- Nao existia leitor de blips nativos nem sincronizacao com a NUI.
- Unica chamada a enumerador: `GetFirstBlipInfoId(8)` em `gps.lua`.
- Portanto, blips criados/movidos/removidos por outros resources apareciam no
  pause map do GTA, mas **nunca** apareciam no mapa NUI. O "atraso" observavel
  era ausencia total de canal, nao um polling lento.
- Produtores reais no workspace (somente leitura nesta wave):
  - `mz_interact/client/blips.lua`: sprite configuravel; seed usa 357;
  - `mz_garagem/client/main.lua`: 357;
  - `mz_fuel/client/stations.lua`: 361;
  - `mz_tatto/client/shops.lua`: 75;
  - `mz_clothing/client/shops.lua`: 73;
  - `mz_dispatch/client/main.lua`: 280 (chamado; dominio dispatch);
  - `mz_police/client/advanced.lua`: 56 (tracker; dominio police).
- `mz_core`/`mz_phone`/`mz_police` nao foram editados.

## 7. Exports e eventos (antes)

Server (`server/main.lua`):

```text
RegisterLayer, UnregisterLayer, UpsertPOI, RemovePOI, ListVisiblePOIs,
GetMapConfig, OpenDestinationPicker, SetWaypoint, GetLastSelection,
ListPublishedRoutes, GetPublishedRoute, ListRoutesForSource, GetRouteForSource
```

Client (`client/main.lua`):

```text
OpenMap, OpenRouteEditor, OpenRouteCatalog, OpenDestinationPicker,
SetWaypoint, ClearWaypoint, GetWaypoint, IsOpen, Close
```

Server events: `mz_navigation:server:request`, `:pickerResult`, `:pickerCancel`.
Client events: `:client:response`, `:client:openPicker`, `:client:setWaypoint`,
`:client:phoneRequest` (local).
NUI: `navigation:open|close|response`; callbacks
`navigationRequest|navigationConfirm|navigationCancel|navigationClose`.

## 8. Baseline de testes (executado antes das mudancas)

```text
node tests/projection.test.js                     PASS 13/13
node tests/map_reuse_contract.test.js             PASS
node tests/network_event_contract.test.js         PASS
lua tests/geo.lua                                 PASS
lua tests/registry.lua                            PASS
lua tests/routes.lua                              PASS
lua tests/service.lua                             PASS
lua tests/quota_concurrency.lua                   PASS (SQL simulado)
npx playwright test (4 testes)                    PASS 4/4 (Chromium)
FiveM runtime                                     NOT RUN (sem servidor/cliente)
```

## 9. Causas observaveis e gates

1. **Ausencia de canal de blips**: nenhuma leitura de blips nativos, logo
   nenhum evento chegava a NUI.
2. **Risco de recenter**: `resetState()` e `applyBootstrap()` reconstroem mapa e
   recentralizam na abertura. Qualquer evento que chame bootstrap/renderAll
   reseta zoom. O canal novo nao pode chamar esses caminhos.
3. **Remount de POIs**: `renderMarkers()` recria o grupo inteiro em mudanca de
   nivel de zoom; o canal novo precisa de update por id.
4. **Duplicacao no painel**: clique de camada chamava `renderLayers()` sem
   limpar a lista (corrigido).
5. **Duplicacao de marcador**: POI de servidor e blip nativo sao fontes
   distintas. A solucao usa namespaces de ID (`native:`, `external:`), sem
   fundir por proximidade.
6. **Tracker policial**: sprite 56 e 280 ficam fora do leitor local por
   decisao de dominio; a proxima wave usa canal autorizado separado.

## 10. Arquivos previstos para edicao (N1-N5)

```text
mz_navigation/config.lua
mz_navigation/fxmanifest.lua
mz_navigation/client/blips.lua          (novo)
mz_navigation/client/gps.lua            (compatibilidade vector3 do CFX)
mz_navigation/client/main.lua
mz_navigation/shared/geo.lua            (compatibilidade vector3 do CFX)
mz_navigation/server/service.lua        (somente map config aditivo)
mz_navigation/web/index.html
mz_navigation/web/css/navigation.css
mz_navigation/web/js/blips.js           (novo)
mz_navigation/web/js/map.js
mz_navigation/web/js/app.js
mz_navigation/web/js/strings.js
mz_navigation/web/assets/map-calibration.json (novo)
mz_navigation/tests/*                   (novos e ajuste do spec existente)
mz_navigation/README.md
mz_navigation/docs/*                    (novos)
```

Nenhum arquivo de `mz_core`, `mz_police`, `mz_dispatch`, `mz_phone`,
`mz_vehicles`, `mz_org`, banco ou `server.cfg` foi alterado.
