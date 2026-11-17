Config = {}

-- 'auto' detects qbx_core, qb-core or es_extended. Force one with 'qbox', 'qb', 'esx' or 'standalone'.
-- The framework is only used for job-locked screens; everything else works standalone.
Config.Framework = 'auto'

-- Language of the remote and notifications comes from ox_lib (`setr ox:locale en` in server.cfg).

-- Check xexstudio.com for new versions on start.
Config.CheckForUpdates = true

-- Prints DUI events and diagnostics to the F8 console, and on the server console why each channel source fails.
Config.Debug = false

-- Branding of the remote and of the screens while they load.
Config.UI = {
    brand = 'Los Santos',
    title = 'TV',
    accent = '#c5f24a',
}

-- How players open the remote.
Config.Interaction = {
    command = 'tv', -- /tv next to a screen. nil = no command
    debugCommand = 'tvdebug', -- model, render target and last player error of the nearest screen. nil = disabled
    target = true, -- adds a "TV" option to every screen model with ox_target or qb-target, if started
    key = nil, -- e.g. 'E': opens the remote next to a screen (players can rebind it). nil = no key
    help = true, -- GTA help text when you walk up to a screen
    controlDistance = 5.0, -- max distance to use the remote
}

-- Who can control screens. Fixed screens can add their own lock (Config.Locations).
Config.Permissions = {
    ace = false, -- e.g. 'xex_tv.use' to require that ACE. false = anyone nearby
    adminAce = 'xex_tv.admin', -- always allowed, also on locked screens
}

-- Sites players can paste links from. Links are checked on the server before they play.
-- YouTube also takes a channel's live stream: youtube.com/@channel/live or 'ytlive:@channel'.
Config.Sources = {
    youtube = true,
    vimeo = true,
}

-- Video files (.mp4, .webm...) and live streams (.m3u8) that players paste are accepted only from these
-- hosts, subdomains included. Each player connects to the host, so it sees their IP: add only hosts you
-- trust. Empty = players can't paste files or streams. Channels and fixed screens don't need this list.
Config.AllowedMediaHosts = {
    -- 'media.example.com',
}

Config.Queue = {
    enabled = true,
    maxItems = 20,
}

-- Movie library in the remote: public domain films from the Internet Archive's feature_films
-- collection, adult titles filtered out. Players stream them from archive.org.
Config.Library = {
    enabled = true,
    -- Shown when the library opens. Use the id from archive.org/details/<id>.
    featured = {
        'Night.Of.The.Living.Dead_1080p',
        'his_girl_friday',
        'The_House_On_Haunted_Hill',
        'Detour',
        'CarnivalofSouls',
        'ScarletStreet',
        'TheStranger_0',
        'kansascityconfidencial',
        'secret_weapon',
        'TheLittleShopOfHorrors1960_765',
        'royal_wedding',
        'mclintok_widescreen',
    },
    -- Films you never want listed or played, by id.
    blocked = {},
}

-- TV channels. The server runs each one nonstop, watched or not, and screens tune in at the current second.
-- Players pick them from the channel guide of the remote; fixed screens and exports use 'channel:<id>'.
--
-- Sources, in order (the next one is the backup when one fails, or the next item when it ends):
--   'https://.../playlist.m3u8'       a live TV stream (HLS). Use 'hls:https://...' if the URL doesn't end in .m3u8
--   'ytlive:@channel'                 whatever that YouTube channel is airing live now
--   'https://www.youtube.com/live/<id>'   one YouTube live stream (skipped once it has ended)
--   'https://youtu.be/<id>', 'https://vimeo.com/<id>'   a video
--   'archive:<id>'                    a film or cartoon from archive.org
--   'https://.../video.mp4'           a video file
-- shuffle = true plays the list in a random order every round (for lists of videos, not for backups).
-- category groups channels in the guide: news, sports, music, movies, kids, nature, documentary,
-- entertainment, or your own word.
--
-- The channels below are public domain films and cartoons from archive.org: the resource ships without any
-- broadcaster, music or other third-party source. Add your own channels here; what you add is your own
-- responsibility. A source that stops answering is skipped and checked again later, and the next one plays. The
-- console stays quiet: a channel that ends up with nothing prints one line, and Config.Debug shows each failure.
-- Films resolved once are remembered across restarts, so they play even while archive.org is down.
--
-- YouTube shows a sign-in page instead of the channel to many hosting IPs, so 'ytlive:' may not work on your
-- server: the channel then moves on to its next source. Put the stream the channel is airing after it as a
-- backup (youtube.com/live/<id>; youtube.com/@channel/live in a browser opens it).
-- Live sources are checked every checkInterval seconds.
Config.Channels = {
    enabled = true,
    checkInterval = 180,
    list = {
        {
            id = 'cinema',
            label = 'Classic Cinema',
            category = 'movies',
            shuffle = true,
            sources = {
                'archive:Detour', 'archive:ScarletStreet', 'archive:TheStranger_0', 'archive:kansascityconfidencial',
                'archive:his_girl_friday', 'archive:royal_wedding', 'archive:TheFlyingDeuces', 'archive:my_favorite_brunette',
                'archive:mclintok_widescreen', 'archive:angel_and_the_badman', 'archive:secret_weapon',
            },
        },
        {
            id = 'horror',
            label = 'Horror Classics',
            category = 'movies',
            shuffle = true,
            sources = {
                'archive:Night.Of.The.Living.Dead_1080p', 'archive:The_House_On_Haunted_Hill', 'archive:CarnivalofSouls',
                'archive:TheLittleShopOfHorrors1960_765', 'archive:white_zombie',
            },
        },
        {
            id = 'cartoons',
            label = 'Cartoons',
            category = 'kids',
            shuffle = true,
            sources = {
                'archive:superman_1941', 'archive:Popeye_forPresident', 'archive:Popeye_Nearlyweds',
                'archive:Popeye_Cooking_With_Gags_1954', 'archive:Popeye_Assault_and_Flattery_1956',
                'archive:Popeye_meetsSinbadtheSailor', 'archive:Popeye_Floor_Flusher_1954',
                'archive:Popeye_Greek_Mirthology_1954', 'archive:ACornyConcerto1943BugsBunny',
                'archive:BugsBunnyCaseOfTheMissingHare', 'archive:bb_snow_white',
            },
        },
    },
}

Config.Playback = {
    defaultVolume = 35,
    -- Volume multiplier from another room of the same interior, and from another interior or outside.
    roomAudio = { enabled = true, otherRoom = 0.4, otherInterior = 0.1 },
    maxConcurrentScreens = 3, -- screens rendered at once per player (each one is a browser)
    -- nil = use the bundled player. If YouTube shows error 153 on your server, host the files of
    -- ui/player/ on your own HTTPS domain and put the URL of player.html here.
    playerUrl = nil,
}

-- Fixed screens: existing map props (spawn = false) or props this resource spawns (spawn = true).
-- They can start playing on boot, loop, and be locked to an ACE or to jobs.
Config.Locations = {
    -- {
    --     label = 'Vinewood cinema',
    --     model = 'v_ilev_cin_screen',
    --     coords = vec3(-1426.3, -248.1, 23.3),
    --     spawn = false,
    --     heading = 0.0, -- only for spawn = true
    --     autoplay = 'channel:horror', -- a channel, a film ('archive:<id>') or a link
    --     volume = 40,
    --     loop = true,
    --     locked = { ace = 'xex_tv.cinema', jobs = { cinema = 0 } }, -- job name = minimum grade
    -- },
}

-- Screen models and the render target each one uses. drawDistance is how far the screen is
-- rendered and heard. Add any prop whose render target you know.
Config.Models = {
    { model = 'prop_tv_flat_01', renderTarget = 'tvscreen', drawDistance = 7.5 },
    { model = 'prop_tv_flat_michael', renderTarget = 'tvscreen', drawDistance = 7.5 },
    { model = 'prop_trev_tv_01', renderTarget = 'tvscreen', drawDistance = 7.5 },
    { model = 'prop_tv_flat_03b', renderTarget = 'tvscreen', drawDistance = 7.5 },
    { model = 'prop_tv_flat_03', renderTarget = 'tvscreen', drawDistance = 7.5 },
    { model = 'prop_tv_flat_02b', renderTarget = 'tvscreen', drawDistance = 7.5 },
    { model = 'prop_tv_flat_02', renderTarget = 'tvscreen', drawDistance = 7.5 },
    { model = 'prop_tv_flat_01_screen', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'prop_tv_02', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'prop_tv_03', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'prop_tv_03_overlay', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'prop_tv_06', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'prop_cs_tv_stand', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'prop_flatscreen_overlay', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'prop_monitor_02', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'prop_monitor_w_large', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'prop_laptop_lester2', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'hei_prop_hst_laptop', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'hei_bank_heist_laptop', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'hei_heist_str_avunitl_03', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'apa_mp_h_str_avunitm_01', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'apa_mp_h_str_avunitl_01_b', renderTarget = 'tvscreen', drawDistance = 10.0 },
    { model = 'ex_prop_ex_tv_flat_01', renderTarget = 'ex_tvscreen', drawDistance = 10.0 },
    { model = 'xm_prop_x17_tv_flat_02', renderTarget = 'tv_flat_01', drawDistance = 10.0 },
    { model = 'xm_screen_1', renderTarget = 'prop_x17_tv_ceiling_01', drawDistance = 10.0 },
    { model = 'vw_prop_vw_cinema_tv_01', renderTarget = 'cinscreen', drawDistance = 50.0 },
    { model = 'v_ilev_cin_screen', renderTarget = 'cinscreen', drawDistance = 50.0 },
    { model = 'prop_big_cin_screen', renderTarget = 'cinscreen', drawDistance = 25.0 },
    { model = 'prop_huge_display_01', renderTarget = 'big_disp', drawDistance = 50.0 },
    { model = 'prop_huge_display_02', renderTarget = 'big_disp', drawDistance = 50.0 },
    -- Custom props without a model name: { hash = 1234567890, label = 'my_screen', renderTarget = 'tvscreen', drawDistance = 10.0 },
}
