-- Remote control (NUI) for the screen it was opened on.

local opened -- { tv = <screen>, canControl = bool }

local textKeys = {
    'ui_off', 'ui_paste', 'ui_play', 'ui_add_queue', 'ui_queue', 'ui_queue_empty', 'ui_channels',
    'ui_volume', 'ui_loop', 'ui_next', 'ui_pause', 'ui_resume', 'ui_stop', 'ui_resync', 'ui_mute_me',
    'ui_locked', 'ui_started_by', 'ui_live', 'ui_sources', 'ui_close', 'ui_remove',
    'ui_library', 'ui_library_note', 'ui_library_search', 'ui_search', 'ui_featured', 'ui_results',
    'ui_load_more', 'ui_no_results', 'ui_searching', 'ui_watch', 'ui_queue_short',
    'ui_on_air', 'ui_starting', 'ui_channel_note', 'ui_guide_open', 'ui_guide_note', 'ui_all', 'ui_ch_up', 'ui_ch_down',
    'genre_noir', 'genre_horror', 'genre_comedy', 'genre_western', 'genre_scifi', 'genre_silent', 'genre_animation',
    'category_news', 'category_sports', 'category_music', 'category_movies', 'category_kids', 'category_nature',
    'category_documentary', 'category_entertainment',
    'kind_youtube', 'kind_vimeo', 'kind_archive', 'kind_direct', 'kind_hls',
}

-- Must match Library.genres on the server.
local genres = { 'noir', 'horror', 'comedy', 'western', 'scifi', 'silent', 'animation' }

local function texts()
    local out = {}
    for _, key in ipairs(textKeys) do out[key] = locale(key) end
    return out
end

local function stateForUi()
    local state = opened and TV.findState(opened.tv)
    if not state then return false end
    local copy = {}
    for key, value in pairs(state) do copy[key] = value end
    copy.currentTime = TV.currentTime(state)
    copy.receivedAt = nil
    return copy
end

local function pushState()
    if not opened then return end
    SendNUIMessage({ action = 'state', state = stateForUi(), localMute = TV.localMute })
end

TV.listeners[#TV.listeners + 1] = function()
    pushState()
end

local function openRemote(tv)
    if opened then return end
    if not tv then return TV.notify('no_tv', 'error') end

    local info = lib.callback.await('xex_tv:inspect', false, TV.descriptor(tv))
    if type(info) ~= 'table' or not info.ok then
        return TV.notify(type(info) == 'table' and info.message or 'error', 'error')
    end
    if info.screen then TV.applyState(info.screen) end

    opened = { tv = tv, canControl = info.canControl == true }
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        ui = Config.UI,
        texts = texts(),
        screenLabel = info.label,
        canControl = opened.canControl,
        queue = Config.Queue,
        channels = type(info.channels) == 'table' and info.channels or {},
        -- What the link field accepts, shown under it.
        sources = {
            youtube = Config.Sources.youtube == true,
            vimeo = Config.Sources.vimeo == true,
            archive = Config.Library ~= nil and Config.Library.enabled == true,
            direct = #Config.AllowedMediaHosts > 0,
        },
        library = Config.Library and Config.Library.enabled and { genres = genres } or false,
        state = stateForUi(),
        localMute = TV.localMute,
    })
end

-- Called from commands, targets and keybinds: run in a thread so the server callback can be awaited.
function TV.openRemote(tv)
    CreateThread(function() openRemote(tv) end)
end

local function closeRemote()
    opened = nil
    SetNuiFocus(false, false)
end

RegisterNUICallback('action', function(data, cb)
    if not opened or type(data) ~= 'table' or type(data.action) ~= 'string' then return cb({ ok = false }) end

    local result = lib.callback.await('xex_tv:action', false, data.action, TV.descriptor(opened.tv), data.value)
    if type(result) ~= 'table' then return cb({ ok = false, message = locale('error') }) end
    if result.screen then TV.applyState(result.screen) end

    cb({ ok = result.ok == true, message = locale(result.message or 'error') })
    pushState()
end)

RegisterNUICallback('library', function(data, cb)
    if not opened or not opened.canControl or type(data) ~= 'table' then return cb({ ok = false }) end

    local result = lib.callback.await('xex_tv:library', false, TV.descriptor(opened.tv), {
        query = type(data.query) == 'string' and data.query:sub(1, 60) or nil,
        genre = type(data.genre) == 'string' and data.genre or nil,
        page = tonumber(data.page) or 1,
    })
    if type(result) ~= 'table' then return cb({ ok = false, message = locale('library_failed') }) end
    if not result.ok then result.message = locale(result.message or 'library_failed') end
    cb(result)
end)

-- The guide asks again when it opens: what each channel airs changes over time.
RegisterNUICallback('channels', function(_, cb)
    if not opened then return cb({}) end
    local info = lib.callback.await('xex_tv:inspect', false, TV.descriptor(opened.tv))
    cb({ channels = type(info) == 'table' and info.ok and info.channels or nil })
end)

RegisterNUICallback('mute', function(_, cb)
    TV.localMute = not TV.localMute
    cb({ localMute = TV.localMute })
end)

RegisterNUICallback('close', function(_, cb)
    closeRemote()
    cb(1)
end)

AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() and opened then closeRemote() end
end)

exports('open', function() TV.openRemote(TV.nearest()) end)
