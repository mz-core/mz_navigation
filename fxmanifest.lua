fx_version 'cerulean'
game 'gta5'

lua54 'yes'

name 'mz_navigation'
author 'Mazus'
description 'Geodata, POIs, camadas, destination picker e ponte GPS do MZ Framework'
version '1.1.0'

ui_page 'web/index.html'

shared_scripts {
    'config.lua',
    'config/seed.lua',
    'shared/geo.lua',
    'shared/schema.lua',
    'shared/routes.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/registry.lua',
    'server/repository.lua',
    'server/route_repository.lua',
    'server/route_service.lua',
    'server/service.lua',
    'server/main.lua'
}

client_scripts {
    'client/gps.lua',
    'client/blips.lua',
    'client/picker.lua',
    'client/main.lua'
}

files {
    'web/index.html',
    'web/css/*.css',
    'web/js/*.js',
    'web/assets/*.webp',
    'web/assets/*.json',
    'web/tiles/*/*/*.jpg',
    'web/tiles/*/*/*.png'
}

dependencies {
    'oxmysql',
    'mz_core'
}
