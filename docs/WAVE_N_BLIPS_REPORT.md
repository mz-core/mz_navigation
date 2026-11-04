# Wave N - blips nativos, camadas e renderer incremental

Data: 2026-10-24  
Resource: `mz_navigation`  
Escopo cumprido: somente `mz_navigation` + documentacao/testes internos.
`mz_core`, `mz_police`, `mz_dispatch`, `mz_phone`, `mz_vehicles`, `mz_org`,
banco e `server.cfg` nao foram alterados.

Baseline pre-change: `NAV_MAP_BASELINE.md`.  
Backup local: `_local_backups/mz_navigation_pre_wave_n_20261024/`.

## Resumo executivo

- O resource nao tinha leitor de blips nativos; o pause map e a NUI eram
  universos separados.
- Foi criado um canal **local, somente leitura, somente enquanto a NUI esta
  aberta**, com allowlist curta de sprites (73, 75, 357, 361), snapshot + diff
  por ID namespaced e remocao explicita.
- O renderer ganhou duas camadas incrementais (`local_native`,
  `local_external`) que atualizam somente o no alterado. Camera, zoom, rota,
  candidato e POIs interativos nao sao tocados pelo delta.
- Foi adicionada uma API local minima para consumidores futuros
  (`UpsertMarker`/`RemoveMarker`), sem editar nenhum produtor agora.
- O layer policial permanece **inerte**: existe apenas um grupo SVG reservado,
  sem store, sem evento e sem autorizacao. O rastreador policial NAO foi
  implementado.
- FiveM runtime: **NOT RUN**. As provas abaixo sao Node/Chromium e Lua offline,
  claramente separadas do teste dentro do GTA.

## Waves

### N0 - Auditoria

Ver `NAV_MAP_BASELINE.md`. A consulta Graphify ampla retornou nodos
nao relacionados; a decisao seguiu a inspecao direta dos arquivos reais.
Principais causas observadas:

1. ausencia total de enumeracao de blips nativos;
2. `resetState()`/`applyBootstrap()` reconstroem o mapa e recentralizam na
   abertura (evento de blip nao pode chamar esses caminhos);
3. `renderMarkers()` recria todos os POIs em mudanca de nivel de zoom;
4. clique de camada chamava `renderLayers()` sem limpar a lista, duplicando
   linhas no painel (corrigido);
5. nenhuma correlacao entre POI de servidor e blip nativo (resolvido por
   namespace, nao por proximidade).

Arquivos editados: nenhum.

### N1 - Coordenadas, tiles e viewport

- A projecao continua unica em `web/js/projection.js` (NUI) e
  `shared/geo.lua` (Lua). Nao foi criada uma segunda conversao.
- `web/assets/map-calibration.json` foi adicionado com 7 ancoras e
  `status: provisional`, `verifiedInGame: false`. Os valores u/v derivam dos
  bounds reais; **nao** sao prova de alinhamento cartografico.
- Testes novos:
  - `tests/calibration.test.js`: bounds do JSON x `config.lua`, 7 ancoras
    world->unit e roundtrip, espaco de tela, inversao de tile no zoom 5.
  - `tests/anchors.lua`: as mesmas 7 ancoras no motor Lua.
- Compatibilidade de runtime: `Geo.NormalizeCoords` e `GPS.GetCurrent` passaram
  a aceitar `vector3` do CFX (table ou tipo proprio), sem mudar o contrato de
  tabela `{x,y,z}` usado pelo servidor e pelos testes.
- Mudar blip/POI **nao** altera tiles. O caminho de blip nao chama
  `renderTiles`/`renderBaseMap`; ha teste estatico para isso.
- Pan/zoom/rota/focus preservados: o delta nao chama `setCamera`,
  `configure`, `renderAll`, `request("bootstrap")` nem `fitToPois`.

### N2 - Leitor local de blips nativos

Novo `client/blips.lua`:

- usa `GetFirstBlipInfoId(sprite)` / `GetNextBlipInfoId(sprite)` por sprite,
  com `DoesBlipExist`, `GetBlipInfoIdCoord`, `GetBlipSprite`, `GetBlipColour`,
  `GetBlipAlpha`;
- allowlist `Config.Blips.Sprites = { 73, 75, 357, 361 }`;
- exclusoes deliberadas: 8 (waypoint pessoal), 56 (tracker police), 280
  (chamado dispatch);
- orcamento: `MaxPerSprite = 64`, `PollMs = 2000`, `MaxMarkers = 400`;
- polling so com `State.active = true` (NUI aberta); `SetActive(false)` para o
  timer, invalida a geracao e limpa o snapshot nativo;
- snapshot/diff com IDs `native:<sprite>:<token>`; o token e monotonico por
  sessao e um handle reutilizado depois de sumir recebe token novo;
- falha temporaria de leitura **nao** remove marcadores (evita flicker);
- feature flag `Config.Blips.Enabled`; desligada, nao cria timer, nao envia
  mensagem e nao adiciona camadas locais.
- `GetBlipSyncDiagnostics()` expõe contagem, geracao, seq, polls, custo do
  ultimo ciclo e erro, sem posicoes.

O enumerador nao foi validado em runtime FiveM (NOT RUN). O codigo e defensivo:
checa a existencia das natives, limita handles e quebra se `GetNext` devolver o
mesmo handle.

### N3 - Registro explicito client-side

Novo contrato local, sem editar produtores:

```lua
exports.mz_navigation:UpsertMarker({
  owner = 'mz_exemplo', id = 'loja:1', label = 'Loja',
  x = 215.0, y = -810.0, z = 30.0,
  category = 'commerce', glyph = 'S'
})
exports.mz_navigation:RemoveMarker('mz_exemplo', 'loja:1')
```

- ID final: `external:<owner>:<id>`.
- Nao concede autorizacao; e apenas exibicao local.
- Nao funde com blip nativo por proximidade. Dois marcadores nas mesmas
  coordenadas continuam dois IDs.
- `owner` e `id` sanitizados; o consumidor nao envia handle, source, job ou
  duty.

### N4 - Renderer incremental e catalogo

- `web/js/blips.js`: store puro UMD, valida versao/geracao/seq, limites de
  500 upserts e 500 removes por mensagem, DTO estrito e namespaces.
- `web/js/map.js`:
  - novos grupos `#navNativeBlips`, `#navExternalMarkers` e o grupo reservado
    `#navPoliceLayer` (`display="none"`, sem logica);
  - `applyMarkerDelta()` cria/atualiza/remove somente o no do ID;
  - `refreshLocalMarkerScale()` ajusta escala no zoom sem remount;
  - `clearLocalMarkers()` em reset/close/stop;
  - `renderLocalMarkers()` apenas em `configure` (bounds mudou).
- Catalogo seguro sprite/categoria -> glifo local (`G`, `C`, `R`, `T`,
  fallback `•`), sem PNG de radar, sem `eval`, sem CDN.
- Texto sempre via `textContent`.
- POIs continuam interativos; o delta nao toca o grupo `#navPois`, rota ou
  candidato. Um teste de browser seleciona um ponto, aplica delta e verifica
  que o candidato permanece.

### N5 - Contratos, testes e documentacao

Aditivo, sem quebrar contratos anteriores:

- `GetMapConfig()` agora inclui `blips = { enabled, pollMs, maxMarkers }`.
- Exports client novos: `UpsertMarker`, `RemoveMarker`,
  `GetBlipSyncDiagnostics`.
- Nenhum evento de rede novo. O canal e `SendNUIMessage` local
  (`navigation:blips:reset` / `navigation:blips:delta`).
- Opcoes existentes de `OpenMap`, picker, rotas, telefone e `mz_transport`
  permanecem.

## Arquivos alterados

```text
mz_navigation/config.lua                       + Config.Blips
mz_navigation/fxmanifest.lua                   + client/blips.lua
mz_navigation/client/blips.lua                 novo
mz_navigation/client/gps.lua                   aceita vector3 do CFX em GetBlipInfoIdCoord
mz_navigation/client/main.lua                  ciclo de vida + exports
mz_navigation/shared/geo.lua                   aceita table/vector3 do CFX
mz_navigation/server/service.lua               map config aditivo
mz_navigation/web/index.html                   grupos + script + favicon local
mz_navigation/web/css/navigation.css           estilos dos marcadores locais
mz_navigation/web/js/blips.js                  novo store puro
mz_navigation/web/js/map.js                    delta incremental + grupo police inerte
mz_navigation/web/js/app.js                    integracao, camadas locais, fix duplicacao
mz_navigation/web/js/strings.js                rotulos pt-BR/en-US das camadas locais
mz_navigation/web/assets/map-calibration.json  novo (provisorio)
mz_navigation/tests/blips.test.js               novo
mz_navigation/tests/blips_contract.test.js      novo
mz_navigation/tests/calibration.test.js         novo
mz_navigation/tests/blips.lua                   novo
mz_navigation/tests/anchors.lua                 novo
mz_navigation/tests/browser/blips.spec.js       novo
mz_navigation/tests/browser/navigation.spec.js  espera readiness; ignora 404 de favicon
mz_navigation/README.md                         exports/flag/limitacoes
mz_navigation/docs/NAV_MAP_BASELINE.md          novo
mz_navigation/docs/WAVE_N_BLIPS_REPORT.md       este relatorio
```

## Decisoes e conflitos com o pacote de referencia

| Referencia | Decisao |
|---|---|
| Blueprint sugere Leaflet/CRS.Simple | **Nao substituido**. O motor real e SVG proprio e atende pan/zoom/incremental. Trocar seria risco sem ganho comprovado. |
| `cc_mdt` com Leaflet/CDN/tiles externos | Nao portado. Nenhum CDN, nenhum tile externo, nenhum dos 6 PNG. |
| `cc_mdt` `eval` e HTML interpolado | Proibido; catalogo de glifos fixo e `textContent`. |
| Exemplo `reader.lua` do blueprint | Conceito aproveitado; ID ganhou token monotonico para evitar reuso de handle e allowlist veio dos produtores reais. |
| Exemplo `sync.lua` | Adaptado ao ciclo real: reset na abertura, timer so enquanto aberto, falha de leitura nao limpa marcadores. |
| Exemplo `bridge.mjs` aceitava so `native:` | Adaptado para `native:` e `external:`. |
| `map_calibration.json` com 6+ ancoras | Criado, mas marcado `provisional`/`verifiedInGame=false`; nao houve medicao no GTA. |
| Kit `MZ_NAVIGATION_CODEX_KIT` tinha apenas 00-05 | Os itens 06-08 citados na missao vieram do `MZ_NAVIGATION_BLUEPRINT_V1`; ambos foram lidos. |
| Blueprint indica layer policial vazio | Grupo SVG reservado e inerte. Nenhum tracker implementado. |

## Testes

### PASS - Node (offline, sem navegador)

Comando (working dir `mz_navigation`):

```powershell
node --test tests/blips.test.js tests/calibration.test.js tests/blips_contract.test.js tests/map_reuse_contract.test.js tests/network_event_contract.test.js
node tests/projection.test.js
```

Resultado: **PASS 28/28** + **PASS 13/13**.

Cobre: reset/delta/remocao/movimento, seq/geracao obsoletos, IDs invalidos,
limites, 200 marcadores incrementais, ancoras/roundtrip, contrato estatico de
que o delta nao chama camera/tiles/POIs, allowlist de sprites e ausencia de
rede no leitor.

### PASS - Lua (offline, com stubs de natives)

Comando:

```powershell
lua tests/blips.lua
lua tests/anchors.lua
lua tests/geo.lua
lua tests/registry.lua
lua tests/routes.lua
lua tests/service.lua
lua tests/quota_concurrency.lua
```

Resultado: todos PASS.

Cobre: snapshot, sprite fora do catalogo, handle duplicado, token novo apos
remocao, diff insert/move/remove, ciclo ativar/poll/desativar, flag OFF sem
mensagem, registro external e rejeicao de owner invalido.

### PASS - Browser (Chromium headless, nao e FiveM)

Comando:

```powershell
$env:NODE_PATH='C:\Users\mateu\AppData\Local\npm-cache\_npx\e41f203b7505f1fb\node_modules'
npx --no-install playwright test --config playwright.config.js --workers=1
```

Resultado: **PASS 9/9** (5 novos de blips + 4 de regressao da NUI/telefone).

Prova de comportamento no browser:

- delta cria 2 marcadores nativos;
- segundo delta move um marcador e remove outro;
- o mesmo no SVG e reutilizado (`data-probe` preservado), provando update
  incremental sem remount;
- camera antes/depois e identica (sem zoom reset/recenter);
- candidato de selecao continua na tela;
- camada pode ser desligada/ligada sem resetar camera;
- reset com nova generation limpa a camada;
- delta que chega **antes** do bootstrap e renderizado quando o mapa configura;
- IDs `external:` convivem com `native:` e remocao e por ID.

### FiveM / CEF real

**NOT RUN / BLOCKED**: nao ha servidor FiveM nem cliente GTA neste ambiente.
Os testes de Chromium validam DOM/SVG/estado, nao VRAM, CEF do jogo, natives,
OneSync ou pause map. Nao ha afirmacao de PASS in-game.

Roteiro manual obrigatorio antes de considerar a wave aceita:

1. `ensure mz_navigation`; abrir `/mapa`.
2. Em outro resource, criar blip 357 em local conhecido.
3. Comparar com o pause map: o mesmo ponto deve aparecer na NUI em ate ~2 s.
4. Mover o blip 5 vezes em 10 s; o marcador correto deve mover, sem remount do
   mapa e sem mudar zoom/centro.
5. Remover o blip; o marcador deve sumir no proximo ciclo.
6. Criar dois blips nas mesmas coordenadas; ambos devem existir (IDs distintos).
7. Criar waypoint pessoal (sprite 8) e confirmar que ele **nao** vira POI.
8. Com `mz_police` em duty, confirmar que sprite 56 **nao** entra na camada
   local; idem 280 do dispatch.
9. Alternar camada `Blips do mapa`; sem linhas duplicadas no painel.
10. Abrir/fechar 50 vezes; `GetBlipSyncDiagnostics()` deve mostrar `active=false`
    ao fechar, sem timer residual.
11. `restart mz_navigation` com a NUI aberta; foco liberado, camada limpa.
12. Medir resmon e FPS CEF com 0/50/200 blips; comparar com baseline.

## Metricas e limites

- Custo projetado do leitor: 4 sprites x 64 handles = no maximo 256 handles por
  ciclo, a cada 2 s, e somente com a NUI aberta. Nao ha varredura por frame.
- O numero real depende de quantos blips desses sprites existem no cliente.
- `GetBlipSyncDiagnostics()` fornece `polls`, `nativeCount`, `externalCount`,
  `lastCostMs`, `lastError`, `seq`, `generation`.
- Nao foram medidos p50/p95 de latencia de rede porque o canal nao usa rede.

## Riscos residuais

- Graphify: a consulta ampla retornou nodos nao relacionados; a analise seguiu
  o codigo-fonte real. O `graphify-out/` de `mz_navigation` **nao** foi
  atualizado nesta wave; sincronizacao escopada pendente.
- Enumerador por sprite e comportamento de handle precisam de confirmacao no
  runtime FiveM (NOT RUN).
- `GetBlipSprite` pode divergir do sprite enumerado em builds/modificacoes; o
  codigo so aceita o valor reportado se ele estiver no catalogo.
- Blips muito dinamicos (movendo a cada frame) sao amostrados a 2 s; e um
  trade-off deliberado de custo, nao um rastreador.
- A calibracao do atlas continua provisoria; o pause map pode revelar offsets
  que exigem uma tabela de calibracao medida no jogo.
- Duplicacao visual entre um POI de servidor e um blip nativo nas mesmas
  coordenadas e possivel por design (fontes/layers diferentes). A
  deduplicacao automatica so sera segura quando o produtor declarar o ID
  correlacionado.
- O grupo `#navPoliceLayer` esta vazio e inerte; qualquer codigo que o habilite
  sem ACL server-side e regressao de seguranca.

## Rollback

1. Imediato, sem deploy: `Config.Blips.Enabled = false`.
   - nenhum timer, nenhuma mensagem, nenhuma camada local;
   - comportamento anterior preservado.
2. Rollback completo: restaurar os arquivos de
   `_local_backups/mz_navigation_pre_wave_n_20261024/` e remover a linha
   `client/blips.lua` do manifest.
3. Sem migracao/DB: nenhuma tabela foi criada ou alterada.
4. `restart mz_navigation` limpa estado e foco; nao ha dado persistido de blip.

## Contratos para a proxima tarefa (`PROMPTS/02_DEEPSEEK_MZ_POLICE.txt`)

**Pre-condicao do proprio prompt:** as Waves N devem estar validadas no FiveM.
Como o runtime esta NOT RUN, a proxima tarefa deve comecar por P0 (auditoria) e
nao pode declarar tracker pronto antes do teste in-game.

O que `mz_navigation` entrega hoje e o que a wave Police podera consumir:

1. **Motor de mapa e camadas**: `window.MZNavMap` com `#navPoliceLayer`
   reservado (`display:none`) e `MAP.groups.police`. O grupo esta vazio; nao ha
   store, evento ou permissao.
2. **Canal local nao serve para policia**: `navigation:blips:*` aceita apenas
   IDs `native:`/`external:` com `visibility:'local'`. Nao reutilizar esse canal
   para unidades policiais.
3. **Canal autorizado novo (a implementar na wave Police)**:
   - server -> cliente autorizado -> NUI, nunca cliente -> servidor;
   - envelope sugerido: `action='navigation:layer:delta'|'navigation:layer:reset'`,
     `version=1`, `layer='police-units'`, `generation`, `seq`, `serverTs`,
     `upserts[]`, `removes[]`;
   - DTO por unidade: `id` namespaced (`unit:<org>:<unitId>`), `x`, `y`,
     `heading` (0..360), `sampleTs`, `serverTs`, `category`
     (`car|moto|helicopter|boat|plane`), `label`, `status`
     (`active|stale|offduty`), `unitId`; opcional `orgCode` somente se a ACL
     server-side permitir;
   - limites de texto/numero, rejeicao de HTML/URL/`eval`, caps por mensagem;
   - `generation` monotonica e `seq` estrito; descartar delta antigo.
4. **Autoridade**: `mz_police` server resolve identidade, org, duty e
   visibilidade a cada emissao/revalidacao. `mz_navigation` **nao** deve expor
   `FetchAllUnits` nem aceitar `job`/`duty` vindos do browser.
5. **Lifecycle**: duty OFF, troca de personagem, desconexao, veiculo guardado,
   `onResourceStop` e restart devem limpar a camada imediatamente
   (reset/clear idempotente). Foco NUI nao pode ser roubado do MDT.
6. **Render**: usar update por ID e RAF/interpolacao na NUI; nao chamar
   `configure`, `renderTiles`, `fitToPois` ou `setCamera` por tick. Follow nao
   altera zoom; pan manual pausa follow. Stale e snap de teleporte visiveis.
7. **`mz_dispatch` -> mapa**: usar o contrato existente de waypoint
   (`exports.mz_navigation:SetWaypoint` no client ou
   `exports.mz_navigation:SetWaypoint(source, coords)` no server). Nao criar
   segundo sistema de waypoint.
8. **Feature flag**: a flag da camada policial pertence a wave Police (ex.:
   `Config.PoliceLayer.Enabled` em `mz_police`), nao a `Config.Blips`.
9. **Testes da proxima wave**: store/interpolacao Node, ACL server-side,
   browser com 30/60/100 unidades, e runtime FiveM com duty OFF, civil,
   reconnect, teleporte, OneSync e restart. Sem FiveM = NOT RUN.

## Proximo gate recomendado

Executar o roteiro FiveM acima em homologacao. Se PASS, congelar o canal local
de blips e iniciar P0/P1 do tracker policial. Se FAIL por enumerador ou
calibracao, corrigir `client/blips.lua`/calibracao antes de qualquer mudanca em
`mz_police`.
