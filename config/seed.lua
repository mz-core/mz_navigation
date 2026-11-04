--[[
    Dados de exemplo do mz_navigation.

    IMPORTANTE: coordenadas de mundo do GTA V sao aproximadas e existem apenas
    como pontos de referencia selecionaveis. Isto NAO e um conjunto de dados
    oficial, NAO e usado para pathfinding e NAO representa propriedade, faccao
    ou localizacao privada de nenhum jogador.
]]

Config.Seeds = {
    enabled = true,

    layers = {
        {
            id = 'landmark',
            label = 'Pontos conhecidos',
            icon = 'landmark',
            category = 'landmark',
            visibility = 'public',
            defaultEnabled = true,
            order = 10
        },
        {
            id = 'services',
            label = 'Servicos',
            icon = 'cross',
            category = 'services',
            visibility = 'public',
            defaultEnabled = true,
            order = 20
        },
        {
            id = 'transport',
            label = 'Transporte',
            icon = 'bus',
            category = 'transport',
            visibility = 'public',
            defaultEnabled = true,
            order = 30
        },
        {
            id = 'commerce',
            label = 'Comercio',
            icon = 'store',
            category = 'commerce',
            visibility = 'public',
            defaultEnabled = true,
            order = 40
        }
    },

    pois = {
        -- landmark
        { id = 'landmark:legion',     layer = 'landmark', label = 'Legion Square',            x = 215.0,   y = -810.0,  z = 30.0,  icon = 'square' },
        { id = 'landmark:maze',       layer = 'landmark', label = 'Maze Bank Tower',          x = -75.0,   y = -818.0,  z = 326.0, icon = 'building' },
        { id = 'landmark:pier',       layer = 'landmark', label = 'Del Perro Pier',           x = -1850.0, y = -1230.0, z = 13.0,  icon = 'waves' },
        { id = 'landmark:chiliad',    layer = 'landmark', label = 'Monte Chiliad',            x = 450.0,   y = 5566.0,  z = 780.0, icon = 'mountain' },
        { id = 'landmark:vinewood',   layer = 'landmark', label = 'Letreiro de Vinewood',     x = 711.0,   y = 1198.0,  z = 300.0, icon = 'sign' },
        { id = 'landmark:casino',     layer = 'landmark', label = 'Cassino',                  x = 925.0,   y = 46.0,    z = 81.0,  icon = 'diamond' },
        { id = 'landmark:observatory',layer = 'landmark', label = 'Observatorio Galileo',     x = -438.0,  y = 1076.0,  z = 350.0, icon = 'telescope' },

        -- services
        { id = 'services:pillbox',    layer = 'services', label = 'Hospital Pillbox Hill',    x = 307.0,   y = -595.0,  z = 43.0,  icon = 'cross' },
        { id = 'services:missionrow', layer = 'services', label = 'Delegacia Mission Row',    x = 425.0,   y = -979.0,  z = 30.0,  icon = 'shield' },
        { id = 'services:fire',       layer = 'services', label = 'Bombeiros Davis',          x = 213.0,   y = -1650.0, z = 29.0,  icon = 'flame' },
        { id = 'services:paleto_med', layer = 'services', label = 'Posto de saude Paleto',    x = -250.0,  y = 6326.0,  z = 32.0,  icon = 'cross' },
        { id = 'services:sandy_med',  layer = 'services', label = 'Posto de saude Sandy',     x = 1839.0,  y = 3672.0,  z = 34.0,  icon = 'cross' },

        -- transport
        { id = 'transport:lsia',      layer = 'transport', label = 'Aeroporto LSIA',           x = -1037.0, y = -2737.0, z = 20.0,  icon = 'plane' },
        { id = 'transport:sandy_air', layer = 'transport', label = 'Aerodromo de Sandy Shores',x = 1747.0,  y = 3273.0,  z = 41.0,  icon = 'plane' },
        { id = 'transport:paleto',    layer = 'transport', label = 'Paleto Bay',               x = -275.0,  y = 6635.0,  z = 31.0,  icon = 'anchor' },
        { id = 'transport:bus_ls',    layer = 'transport', label = 'Terminal de onibus LS',    x = 430.0,   y = -1010.0, z = 29.0,  icon = 'bus' },
        { id = 'transport:heliport',  layer = 'transport', label = 'Heliporto de Downtown',    x = -724.0,  y = -1444.0, z = 43.0,  icon = 'helicopter' },

        -- commerce
        { id = 'commerce:lsc',        layer = 'commerce', label = 'LS Customs',                x = -365.0,  y = -131.0,  z = 38.0,  icon = 'wrench' },
        { id = 'commerce:ammunation', layer = 'commerce', label = 'Ammu-Nation Downtown',      x = 21.0,    y = -1107.0, z = 29.0,  icon = 'target' },
        { id = 'commerce:market',     layer = 'commerce', label = 'Mercado de Strawberry',     x = 28.0,    y = -1339.0, z = 29.0,  icon = 'store' },
        { id = 'commerce:clothes',    layer = 'commerce', label = 'Loja de roupas',            x = 72.0,    y = -1392.0, z = 29.0,  icon = 'shirt' },
        { id = 'commerce:barber',     layer = 'commerce', label = 'Barbearia',                 x = 121.0,   y = -1465.0, z = 29.0,  icon = 'scissors' }
    }
}
