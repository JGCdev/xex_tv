fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'xex_tv'
description 'Synced TVs: 24/7 channels, a public domain movie library, YouTube, Vimeo and video files'
author 'XeX'
version '1.0.2'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

server_scripts {
    'bridge/server.lua',
    'server/media.lua',
    'server/library.lua',
    'server/channels.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
    'client/remote.lua',
}

-- The remote control. Every screen is rendered in its own DUI from ui/player/player.html.
ui_page 'ui/index.html'

files {
    'locales/*.json',
    'ui/index.html',
    'ui/app.js',
    'ui/style.css',
    'ui/fonts/*.woff2',
    'ui/player/*',
    'ui/player/vendor/*',
}

dependencies {
    'ox_lib',
}

-- Free and open: nothing is encrypted.
escrow_ignore {
    '**/*.lua',
    'locales/*.json',
}
