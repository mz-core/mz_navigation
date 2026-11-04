--[[
    mz_navigation - geodata, POI registry, layers, destination picker e ponte GPS.

    Este resource NAO e dono de corridas, precos, pagamentos ou estado de viagem.
    Consumidores (mz_phone, mz_transport, futuros) leem contratos daqui.

    Mapa:
      O GTA V usa coordenadas de mundo (x, y) sem CRS geografico. O eixo Y cresce
      para o norte e o eixo X para o leste. A conversao para a tela e uma projecao
      afim: u = (x - minX) / (maxX - minX), v = (maxY - y) / (maxY - minY).

      Os limites abaixo cobrem a ilha principal com margem. Nao sao "GPS": sao
      apenas o viewport padrao da interface.
]]

Config = Config or {}

Config.Debug = false

-- Idioma global do servidor para a UI (pt-BR padrao; en-US suportado pelo editor).
Config.Locale = 'pt-BR'

Config.Map = {
    -- Viewport de mundo (unidades GTA V). Ajustavel sem tocar no codigo.
    minX = -4600.0,
    maxX = 5000.0,
    minY = -4600.0,
    maxY = 7400.0,

    minZoom = 1,
    maxZoom = 5,
    defaultZoom = 2,

    --[[
        Tiles de alta resolucao sao OPCIONAIS e ficam DESABILITADOS por padrao.
        A UI usa o atlas estatico local em web/assets como base; o dono do servidor
        pode fornecer um conjunto de tiles licenciado para maior detalhe no zoom.

        Formato esperado (compativel com o atlas legado observado em ref/races):
          web/tiles/{z}/{x}/{y}.jpg  - tiles 256x256
          z = 0..5, grade 2^z por eixo
        A projecao abaixo e a observada no legado (Leaflet CRS.Simple +
        L.Transformation). Ela NAO e um CRS oficial; foi extraida do codigo de
        referencia e precisa de calibracao visual quando um atlas real for usado.
    ]]
    tiles = {
        enabled = false,
        path = 'tiles',
        tileSize = 256,
        maxZoom = 5,
        projection = {
            scaleX = 0.02072,
            offsetX = 117.3,
            scaleY = 0.0205,
            offsetY = 172.8
        },
        license = 'UNLICENSED'
    }
}

Config.Limits = {
    maxLayers = 64,
    maxPoisPerLayer = 500,
    maxPoisTotal = 4000,
    maxFavoritesPerCharacter = 50,
    maxRecentsPerCharacter = 30,
    maxMetadataKeys = 8,
    labelMaxLength = 80,
    idMaxLength = 96
}

Config.RateLimits = {
    bootstrap = { window = 10, max = 20 },
    listPOIs = { window = 10, max = 40 },
    favoritesAdd = { window = 10, max = 10 },
    favoritesRemove = { window = 10, max = 10 },
    recentsAdd = { window = 10, max = 20 },
    routesList = { window = 10, max = 20 },
    routesRead = { window = 10, max = 30 },
    routesWrite = { window = 10, max = 12 },
    routesDelete = { window = 30, max = 5 },
    routesPublish = { window = 30, max = 5 }
}

--[[
    Wave 4A/4B - rotas autoradas.
    Desabilitado por padrao para rollout incremental. O comando /rotas e a UI
    existem, mas o servidor recusa mutacoes enquanto Enabled ~= true.
    CatalogEnabled controla somente o consumo read-only (fullscreen e MZ Maps).
]]
Config.Routes = {
    Enabled = false,
    -- Catalogo read-only (fullscreen e MZ Maps). OFF por padrao.
    CatalogEnabled = false,
    MinPoints = 2,
    MaxPoints = 64,
    MaxTitle = 80,
    MaxDescription = 300,
    MaxTotalDistance = 20000.0,
    MaxPayloadBytes = 65536,
    MaxRoutesPerCharacter = 30,
    MaxRoutesPerOrg = 100,
    DefaultPageSize = 20,
    MaxPageSize = 50,
    MaxSearchLength = 60,
    MinPointDistance = 0.5,
    RouteTypes = {
        generic = true,
        circuit = true,
        sprint = true,
        patrol = true,
        delivery = true,
        bus = true
    }
}

Config.Picker = {
    timeoutMs = 45000,
    maxOpenPerSource = 2,
    minimumZoom = 1,
    maximumZoom = 5
}

Config.Waypoint = {
    -- Limites de sanidade para qualquer coordenada vinda do cliente.
    maxWorld = 20000.0,
    minZ = -2000.0,
    maxZ = 3000.0,
    -- Faixa usada para resolver altura de solo. Fora disso, z nao e confiavel.
    groundProbeZ = 1000.0
}

Config.Sessions = {
    -- Mantem o ultimo destino confirmado por personagem para consumidores
    -- server-side (ex.: mz_transport) sem depender de source.
    cacheSize = 256
}

--[[
    Sincronizacao de blips nativos locais (client-side, somente leitura).

    O leitor enumera APENAS os sprites abaixo, com GetFirstBlipInfoId /
    GetNextBlipInfoId (a native e por sprite, nao um enumerador universal).
    Nao ha varredura 1..1000 e nada e enviado ao servidor.

    Exclusoes deliberadas:
      - sprite 8  : waypoint pessoal do jogador (ja tem fluxo proprio em gps.lua);
      - sprite 56 : tracker do mz_police (canal autorizado da proxima wave);
      - sprite 280: blip de chamado do mz_dispatch (dominio do dispatch).

    Os marcadores aparecem somente enquanto a NUI esta aberta. `Enabled = false`
    restaura exatamente o comportamento anterior, sem timer e sem mensagens.
]]
Config.Blips = {
    Enabled = true,
    PollMs = 2000,
    MaxPerSprite = 64,
    MaxMarkers = 400,
    Debug = false,
    Sprites = { 73, 75, 357, 361 },
    Catalog = {
        [73] = { label = 'Loja de roupas', category = 'clothing', glyph = 'R' },
        [75] = { label = 'Tatuagem', category = 'tattoo', glyph = 'T' },
        [357] = { label = 'Garagem', category = 'garage', glyph = 'G' },
        [361] = { label = 'Posto de combustivel', category = 'fuel', glyph = 'C' }
    }
}

--[[
    Camadas e POIs de exemplo. Sao dados autorais simples, nao dados de terceiros.
    Coordenadas sao aproximadas e servem como pontos de referencia; o dono do
    servidor pode substituir por dados proprios em config/seed.lua.
]]
-- Preenchido por config/seed.lua (shared_scripts).
Config.Seeds = Config.Seeds or {
    enabled = true,
    layers = {},
    pois = {}
}
