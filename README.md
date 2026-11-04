# mz_navigation

Dono de geodata, camadas, POIs, selecao de destino e ponte GPS do MZ Framework.

Nao e dono de corridas, precos, pagamentos, propriedades ou dados privados de
outros dominios. Consumidores leem os contratos publicos deste resource.

## Escopo

- mapa SVG offline (carta esquematica) com pan/zoom, camadas, busca e POIs;
- `OpenDestinationPicker` assincrono com `requestId`, timeout e cancelamento;
- waypoint GTA via native, com `z` opcional e resolucao de solo quando confiavel;
- favoritos e recentes persistidos por `character_id` (nunca por `source`);
- ACL server-side por camada/POI (`public`, `staff`, `org`, `character`);
- rotas autoradas (editor/catalogo/telefone) com ACL, CAS e quota.

## Comandos

- `/mapa` ou `/navigation` - abre o mapa.
- `/rotas` - abre o editor de rotas (requer `Config.Routes.Enabled = true`,
  migration manual `sql/002_mz_navigation_routes.sql` e, para create concorrente,
  `sql/003_mz_navigation_route_quotas.sql`).
- `/maparotas` - abre o catalogo read-only (requer tambem
  `Config.Routes.CatalogEnabled = true`).

## Rotas

- a migration 002 cria `mz_navigation_routes`;
- a migration 003 cria `mz_navigation_route_quotas` (quota transacional);
- ambas sao manuais; sem 002 leitura/editor retornam `routes_unavailable`;
  sem 003 `routes.create` retorna `quota_unavailable`;
- escritas passam por `RouteService`/`RouteRepository`; o cliente nunca envia
  owner ou `used`.

## Exports server

```lua
exports.mz_navigation:RegisterLayer({ id='garage', label='Garagens', visibility='public' })
exports.mz_navigation:UpsertPOI({ id='garage:central', layer='garage', label='Garagem Central', x=215.0, y=-810.0, z=30.0 })
exports.mz_navigation:RemovePOI('garage:central')
exports.mz_navigation:ListVisiblePOIs(source)
exports.mz_navigation:OpenDestinationPicker(source, { title='Escolha um destino' }, function(selection, reason) end)
exports.mz_navigation:SetWaypoint(source, { x=215.0, y=-810.0 })
exports.mz_navigation:GetLastSelection(characterId)
exports.mz_navigation:GetMapConfig()
exports.mz_navigation:ListPublishedRoutes({ page=1, limit=20 })
exports.mz_navigation:GetPublishedRoute(publicId)
exports.mz_navigation:ListRoutesForSource(source, { scope='all' })
exports.mz_navigation:GetRouteForSource(source, publicId)
```

## Exports client

```lua
exports.mz_navigation:OpenDestinationPicker({ title='Destino', zoom=3 }, function(selection, reason) end)
exports.mz_navigation:SetWaypoint({ x=215.0, y=-810.0 })
exports.mz_navigation:GetWaypoint()
exports.mz_navigation:OpenMap()
exports.mz_navigation:OpenRouteEditor()
exports.mz_navigation:OpenRouteCatalog()
exports.mz_navigation:IsOpen()
exports.mz_navigation:Close()
exports.mz_navigation:UpsertMarker({ owner='mz_exemplo', id='loja:1', label='Loja', x=215.0, y=-810.0 })
exports.mz_navigation:RemoveMarker('mz_exemplo', 'loja:1')
exports.mz_navigation:GetBlipSyncDiagnostics()
```

## Blips locais (client-only)

- `Config.Blips.Enabled = true` liga a leitura de blips nativos **apenas**
  enquanto a NUI esta aberta. Desligar restaura o comportamento anterior.
- Sprites auditados: `73` (roupas), `75` (tatuagem), `357` (garagem) e `361`
  (posto). Waypoint `8`, tracker police `56` e chamado dispatch `280` ficam
  fora por decisao de dominio.
- Nada e enviado ao servidor. IDs sao `native:<sprite>:<token>` e
  `external:<owner>:<id>`; o diff e incremental e a remocao e explicita.
- `UpsertMarker`/`RemoveMarker` sao API de exibicao local para consumidores
  futuros; nao concedem autorizacao e nao alteram produtores existentes.
- O layer policial permanece vazio/inerte (`#navPoliceLayer`) ate a wave
  Police com canal autorizado server-side.

Detalhes e contratos da proxima wave: `docs/WAVE_N_BLIPS_REPORT.md` e
`docs/NAV_MAP_BASELINE.md`.

## Limitacoes declaradas

- a carta esquematica **nao** e um mapa cartografico real;
- nao existe pathfinding, ETA ou rota viaria neste resource;
- `z` de um clique 2D pode ser desconhecido; pontes/interiores exigem cautela;
- a quota transacional exige a migration manual 003 e transacao oxmysql;
- a previa de rota e esquematica e nao cria waypoint;
- o atlas estatico local e a base padrao; tiles de maior resolucao so sao servidos se um pacote licenciado for fornecido (ver `web/tiles/README.md`);
- a calibracao do atlas e provisoria (`web/assets/map-calibration.json`) e exige conferencia no pause map em runtime;
- blips nativos sao amostrados a cada `Config.Blips.PollMs` somente com a NUI aberta; nao sao rastreamento em tempo real;
- compartilhamento de localizacao em tempo real nao faz parte desta versao.

Documentacao completa: `docs/mz_navigation/`.
