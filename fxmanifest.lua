fx_version 'cerulean'
game 'gta5'

name        'at-broker'
description 'Criminal broker network — middleware layer for contract-based criminal activity'
author      'AT_Scripts'
version     '1.0.0'

shared_scripts {
    'config.lua',
    'shared/utils.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/reputation.lua',
    'server/contracts.lua',
    'server/monitor.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}

dependencies {
    'oxmysql',
}
