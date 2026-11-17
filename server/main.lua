-- Server: screens, their clock and every player action.

local resourceName = GetCurrentResourceName()
local screens = {}
local locations = {}
local modelLookup = {}
local lastActionAt = {}
local lastReportAt = {}
local lastLibraryAt = {}
local actionCooldown = 750 -- ms between actions per player
local revisionCounter = 0

local function normalizeHash(hash)
    hash = tonumber(hash)
    if not hash then return nil end
    if hash < 0 then return hash + 4294967296 end
    return hash
end

for _, definition in ipairs(Config.Models) do
    modelLookup[normalizeHash(definition.hash or joaat(definition.model))] = definition
end

local function definitionFor(model)
    return modelLookup[normalizeHash(model)]
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function roundCoordinate(value)
    local scaled = value * 100
    return scaled >= 0 and math.floor(scaled + 0.5) or math.ceil(scaled - 0.5)
end

local function makeScreenId(bucket, model, coords)
    return ('%d:%u:%d:%d:%d'):format(bucket, normalizeHash(model),
        roundCoordinate(coords.x), roundCoordinate(coords.y), roundCoordinate(coords.z))
end

local function isFiniteNumber(value)
    return type(value) == 'number' and value == value and value > -10000.0 and value < 10000.0
end

local function clamp(value, min, max)
    return math.max(min, math.min(max, value))
end

local function nextRevision()
    revisionCounter = revisionCounter + 1
    return revisionCounter
end

local function playerLabel(src)
    return GetPlayerName(src) or ('ID %d'):format(src)
end

-- FIXED SCREENS ----------------------------------------------------------------------------------

for index, location in ipairs(Config.Locations) do
    local model = normalizeHash(location.hash or joaat(location.model))
    local definition = definitionFor(model)
    if not definition then
        print(('^3[%s] Config.Locations[%d]: model %s is not in Config.Models, skipped.^7'):format(
            resourceName, index, tostring(location.model or location.hash)))
    else
        local coords = { x = location.coords.x, y = location.coords.y, z = location.coords.z }
        local bucket = tonumber(location.bucket) or 0
        locations[#locations + 1] = {
            id = makeScreenId(bucket, model, coords),
            bucket = bucket,
            model = model,
            coords = coords,
            definition = definition,
            config = location,
        }
    end
end

local function locationAt(bucket, model, coords)
    model = normalizeHash(model)
    for _, location in ipairs(locations) do
        if location.bucket == bucket and location.model == model and distance(location.coords, coords) <= 0.75 then
            return location
        end
    end
end

-- VALIDATION -------------------------------------------------------------------------------------

local function validateDescriptor(src, descriptor)
    if type(descriptor) ~= 'table' or type(descriptor.coords) ~= 'table' then return nil, 'no_tv' end

    local model = normalizeHash(descriptor.model)
    local definition = model and definitionFor(model)
    if not definition then return nil, 'no_tv' end

    local coords = {
        x = tonumber(descriptor.coords.x),
        y = tonumber(descriptor.coords.y),
        z = tonumber(descriptor.coords.z),
    }
    if not isFiniteNumber(coords.x) or not isFiniteNumber(coords.y) or not isFiniteNumber(coords.z) then
        return nil, 'no_tv'
    end

    local ped = GetPlayerPed(src)
    if ped == 0 or not DoesEntityExist(ped) then return nil, 'too_far' end

    -- Big screens (cinemas, billboards) can be controlled from further away.
    local maxDistance = math.max(Config.Interaction.controlDistance, math.min(definition.drawDistance, 25.0)) + 5.0
    if #(GetEntityCoords(ped) - vector3(coords.x, coords.y, coords.z)) > maxDistance then
        return nil, 'too_far'
    end

    local bucket = GetPlayerRoutingBucket(src)
    local location = locationAt(bucket, model, coords)
    if location then return location end

    return {
        id = makeScreenId(bucket, model, coords),
        bucket = bucket,
        model = model,
        coords = coords,
        definition = definition,
    }
end

local function canControl(src, location)
    local perms = Config.Permissions
    if perms.adminAce and IsPlayerAceAllowed(tostring(src), perms.adminAce) then return true end
    if perms.ace and not IsPlayerAceAllowed(tostring(src), perms.ace) then return false end

    local lock = location and location.config and location.config.locked
    if not lock then return true end
    if lock.ace and IsPlayerAceAllowed(tostring(src), lock.ace) then return true end

    if lock.jobs then
        local job, grade = Bridge.GetJob(src)
        local minGrade = job and lock.jobs[job]
        if minGrade and (grade or 0) >= minGrade then return true end
    end
    return false
end

local function isRateLimited(src)
    local now = GetGameTimer()
    if now - (lastActionAt[src] or 0) < actionCooldown then return true end
    lastActionAt[src] = now
    return false
end

-- STATE ------------------------------------------------------------------------------------------

local function currentPlaybackTime(screen)
    local current = screen.offset or 0
    if screen.playing then current = current + math.max(0, os.time() - screen.startedAt) end
    if screen.duration then current = math.min(current, screen.duration) end
    return current
end

local function serialiseScreen(screen)
    local queue = {}
    for i, item in ipairs(screen.queue) do
        queue[i] = { kind = item.kind, label = item.title or item.label }
    end

    return {
        id = screen.id,
        bucket = screen.bucket,
        model = screen.model,
        coords = screen.coords,
        media = screen.media,
        mediaToken = screen.mediaToken,
        -- A channel is live: everyone follows its clock, nobody seeks it.
        seekable = not screen.channel and Media.isSeekable(screen.media, screen.duration),
        live = screen.media ~= nil and (screen.media.live == true or screen.channel ~= nil and screen.duration == nil),
        channel = screen.channel,
        channelLabel = screen.channelLabel,
        channelNumber = screen.channelNumber,
        playing = screen.playing,
        currentTime = currentPlaybackTime(screen),
        duration = screen.duration,
        title = screen.title,
        volume = screen.volume,
        loop = screen.loop,
        queue = queue,
        label = screen.label,
        locked = screen.locked,
        revision = screen.revision,
        updatedBy = screen.updatedBy,
    }
end

local function forPlayersInBucket(bucket, callback)
    for _, playerId in ipairs(GetPlayers()) do
        local numericId = tonumber(playerId)
        if numericId and GetPlayerRoutingBucket(numericId) == bucket then callback(numericId) end
    end
end

local function broadcastScreen(screen)
    local payload = serialiseScreen(screen)
    forPlayersInBucket(screen.bucket, function(playerId)
        TriggerClientEvent('xex_tv:syncOne', playerId, payload)
    end)
end

local function removeScreen(screen)
    screens[screen.id] = nil
    forPlayersInBucket(screen.bucket, function(playerId)
        TriggerClientEvent('xex_tv:removeOne', playerId, screen.id)
    end)
end

local function createScreen(base)
    local config = base.config
    return {
        id = base.id,
        bucket = base.bucket,
        model = base.model,
        coords = base.coords,
        label = config and config.label or nil,
        locked = config and config.locked ~= nil or false,
        loop = config and config.loop == true or false,
        volume = config and tonumber(config.volume) or Config.Playback.defaultVolume,
        queue = {},
    }
end

local function startMedia(screen, media, offset)
    screen.channel, screen.channelLabel, screen.channelNumber = nil, nil, nil
    screen.media = media
    screen.mediaToken = nextRevision()
    screen.playing = true
    screen.startedAt = os.time()
    screen.offset = offset or 0
    -- Known up front for the library and checked YouTube links; otherwise reported by a player.
    screen.duration = media.duration
    screen.title = media.title
    screen.revision = nextRevision()
end

-- Next item in the queue, the same one again (loop) or off.
local function advance(screen, actor)
    local nextMedia = table.remove(screen.queue, 1)
    if nextMedia then
        startMedia(screen, nextMedia)
    elseif screen.loop and screen.media then
        screen.offset, screen.startedAt, screen.playing = 0, os.time(), true
        screen.revision = nextRevision()
    else
        removeScreen(screen)
        return false
    end

    screen.updatedBy = actor
    broadcastScreen(screen)
    return true
end

-- CHANNELS ---------------------------------------------------------------------------------------

-- The screen mirrors the channel: same media, token and clock as every other screen on it.
local function applyChannel(screen, channel)
    screen.channel = channel.id
    screen.channelLabel = channel.label
    screen.channelNumber = channel.number
    screen.media = channel.media
    screen.mediaToken = channel.mediaToken
    screen.playing = true
    screen.startedAt = channel.startedAt or os.time()
    screen.offset = 0
    screen.duration = channel.duration
    screen.title = channel.title
    screen.queue = {}
    screen.loop = false
    screen.revision = nextRevision()
end

Channels.onChange(function(channel)
    for _, screen in pairs(screens) do
        if screen.channel == channel.id then
            applyChannel(screen, channel)
            broadcastScreen(screen)
        end
    end
end)

-- 'channel:<id>' in autoplay, exports and the remote.
local function channelFromSource(source)
    local id = type(source) == 'string' and source:match('^channel:([%w_%-]+)$')
    return id and Channels.get(id) or nil
end

local function sendState(src, bucket)
    local payload = {}
    for id, screen in pairs(screens) do
        if screen.bucket == bucket then payload[id] = serialiseScreen(screen) end
    end
    TriggerClientEvent('xex_tv:syncAll', src, payload, bucket)
end

local playerBuckets = {}

-- The playback clock lives here, so queues and loops keep going with nobody watching.
-- It also notices routing bucket changes (instanced houses...) and sends that bucket's screens at once.
CreateThread(function()
    while true do
        Wait(1000)
        local now = os.time()
        for _, screen in pairs(screens) do
            if not screen.channel and screen.playing and screen.duration and currentPlaybackTime(screen) >= screen.duration then
                advance(screen, 'auto')
            elseif not screen.playing and screen.pausedAt and now - screen.pausedAt > 3600 then
                -- Paused and forgotten for an hour: turn it off.
                removeScreen(screen)
            end
        end

        for _, playerId in ipairs(GetPlayers()) do
            local src = tonumber(playerId)
            local bucket = src and GetPlayerRoutingBucket(src)
            if bucket and playerBuckets[src] ~= nil and playerBuckets[src] ~= bucket then
                sendState(src, bucket)
            end
            if src then playerBuckets[src] = bucket end
        end
    end
end)

-- ACTIONS ----------------------------------------------------------------------------------------

local function response(ok, key, screen)
    return { ok = ok, message = key, screen = screen and serialiseScreen(screen) or nil }
end

local function parseVolume(value, fallback)
    local volume = tonumber(value)
    if not volume then return fallback end
    return clamp(math.floor(volume + 0.5), 0, 100)
end

local actions = {}

-- Parses and checks the link a player sent. This waits for YouTube, Vimeo, archive.org or the stream,
-- so callers read the screen again afterwards: someone else may have changed it meanwhile.
local function requestedMedia(value)
    local request = type(value) == 'table' and value or {}
    local media, err = Media.fromInput(request.source)
    return media, err or 'invalid_source'
end

function actions.tune(src, target, _, value)
    local request = type(value) == 'table' and value or {}
    local channel = Channels.get(request.channel)
    if not channel then return response(false, 'error') end

    local screen = screens[target.id] or createScreen(target)
    screen.volume = parseVolume(request.volume, screen.volume)
    applyChannel(screen, channel)
    screen.updatedBy = playerLabel(src)
    screens[screen.id] = screen
    broadcastScreen(screen)
    return response(true, 'tuned', screen)
end

function actions.play(src, target, _, value)
    local request = type(value) == 'table' and value or {}
    local channel = channelFromSource(request.source)
    if channel then
        return actions.tune(src, target, nil, { channel = channel.id, volume = request.volume })
    end

    local media, err = requestedMedia(request)
    if not media then return response(false, err) end

    local screen = screens[target.id] or createScreen(target)
    screen.volume = parseVolume(request.volume, screen.volume)
    startMedia(screen, media)
    screen.updatedBy = playerLabel(src)
    screens[screen.id] = screen
    broadcastScreen(screen)
    return response(true, 'started', screen)
end

function actions.queue(src, target, screen, value)
    if not Config.Queue.enabled then return response(false, 'queue_disabled') end
    if not screen then return actions.play(src, target, screen, value) end
    if #screen.queue >= Config.Queue.maxItems then return response(false, 'queue_full') end

    local media, err = requestedMedia(value)
    if not media then return response(false, err) end

    screen = screens[target.id]
    if not screen then return actions.play(src, target, nil, value) end
    if screen.channel then return response(false, 'channel_live', screen) end
    if #screen.queue >= Config.Queue.maxItems then return response(false, 'queue_full') end

    screen.queue[#screen.queue + 1] = media
    screen.revision = nextRevision()
    broadcastScreen(screen)
    return response(true, 'queued', screen)
end

function actions.togglePause(src, _, screen)
    if screen.playing then
        screen.offset = currentPlaybackTime(screen)
        screen.playing = false
        screen.pausedAt = os.time()
    else
        screen.playing = true
        screen.startedAt = os.time()
    end
    screen.revision = nextRevision()
    screen.updatedBy = playerLabel(src)
    broadcastScreen(screen)
    return response(true, screen.playing and 'resumed' or 'paused', screen)
end

function actions.volume(src, _, screen, value)
    local volume = parseVolume(value)
    if not volume then return response(false, 'error') end
    screen.volume = volume
    screen.revision = nextRevision()
    screen.updatedBy = playerLabel(src)
    broadcastScreen(screen)
    return response(true, 'volume', screen)
end

function actions.seek(src, _, screen, value)
    if not Media.isSeekable(screen.media, screen.duration) then return response(false, 'not_seekable') end
    local seconds = tonumber(value)
    if not seconds or seconds ~= seconds then return response(false, 'error') end

    screen.offset = clamp(math.floor(seconds), 0, screen.duration and math.max(0, screen.duration - 1) or 86400)
    screen.startedAt = os.time()
    screen.revision = nextRevision()
    screen.updatedBy = playerLabel(src)
    broadcastScreen(screen)
    return response(true, 'seeked', screen)
end

function actions.next(src, _, screen)
    if #screen.queue == 0 then return response(false, 'queue_empty', screen) end
    advance(screen, playerLabel(src))
    return response(true, 'skipped', screen)
end

function actions.loop(src, _, screen)
    screen.loop = not screen.loop
    screen.revision = nextRevision()
    screen.updatedBy = playerLabel(src)
    broadcastScreen(screen)
    return response(true, screen.loop and 'loop_on' or 'loop_off', screen)
end

function actions.unqueue(_, _, screen, value)
    local index = math.tointeger(tonumber(value))
    if not index or not screen.queue[index] then return response(false, 'error', screen) end
    table.remove(screen.queue, index)
    screen.revision = nextRevision()
    broadcastScreen(screen)
    return response(true, 'unqueued', screen)
end

function actions.refresh(_, _, screen)
    screen.revision = nextRevision()
    broadcastScreen(screen)
    return response(true, 'refreshed', screen)
end

function actions.stop(_, _, screen)
    removeScreen(screen)
    return response(true, 'stopped')
end

local needsNoScreen = { play = true, queue = true, tune = true }

-- Not possible on a live channel: change the channel or play something else instead.
local notOnChannel = { queue = true, togglePause = true, seek = true, next = true, loop = true, unqueue = true }

lib.callback.register('xex_tv:action', function(src, action, descriptor, value)
    local handler = type(action) == 'string' and actions[action]
    if not handler then return response(false, 'error') end
    if isRateLimited(src) then return response(false, 'rate_limited') end

    local target, err = validateDescriptor(src, descriptor)
    if not target then return response(false, err) end
    if not canControl(src, target) then return response(false, 'no_permission') end

    local screen = screens[target.id]
    if not screen and not needsNoScreen[action] then return response(false, 'no_active_media') end
    if screen and screen.channel and notOnChannel[action] then return response(false, 'channel_live', screen) end
    return handler(src, target, screen, value)
end)

-- What the remote needs on open: can this player control it, and what is playing.
lib.callback.register('xex_tv:inspect', function(src, descriptor)
    local target, err = validateDescriptor(src, descriptor)
    if not target then return { ok = false, message = err } end
    local screen = screens[target.id]
    return {
        ok = true,
        canControl = canControl(src, target),
        label = target.config and target.config.label or nil,
        screen = screen and serialiseScreen(screen) or nil,
        channels = Channels.list(),
    }
end)

-- Library search for the remote. Same checks as the remote: near a screen this player can control.
lib.callback.register('xex_tv:library', function(src, descriptor, request)
    if not (Config.Library and Config.Library.enabled) then return { ok = false, message = 'error' } end

    local now = GetGameTimer()
    if now - (lastLibraryAt[src] or 0) < 800 then return { ok = false, message = 'rate_limited' } end
    lastLibraryAt[src] = now

    local target, err = validateDescriptor(src, descriptor)
    if not target then return { ok = false, message = err } end
    if not canControl(src, target) then return { ok = false, message = 'no_permission' } end

    return Library.search(request)
end)

local lastStateAt = {}

RegisterNetEvent('xex_tv:requestState', function()
    local src = source
    local now = GetGameTimer()
    if now - (lastStateAt[src] or -5000) < 5000 then return end
    lastStateAt[src] = now

    local bucket = GetPlayerRoutingBucket(src)
    playerBuckets[src] = bucket
    sendState(src, bucket)
end)

-- A report about a screen from a player near it, in its bucket, about the media it is playing now.
local function nearScreen(src, id, token, kind)
    local screen = type(id) == 'string' and screens[id]
    if not screen or screen.mediaToken ~= token then return nil end
    if GetPlayerRoutingBucket(src) ~= screen.bucket then return nil end

    local now, key = GetGameTimer(), src .. kind
    if now - (lastReportAt[key] or 0) < 500 then return nil end
    lastReportAt[key] = now

    local ped = GetPlayerPed(src)
    local definition = definitionFor(screen.model)
    if ped == 0 or not definition then return nil end
    if #(GetEntityCoords(ped) - vector3(screen.coords.x, screen.coords.y, screen.coords.z)) > definition.drawDistance + 10.0 then
        return nil
    end
    return screen
end

-- A player who can control the screen is trusted. Otherwise two players have to report the same thing,
-- so a single client can't cut a video short, rename it or skip a channel. Returns the agreed values.
local function agreed(src, screen, token, kind, values)
    if canControl(src, locationAt(screen.bucket, screen.model, screen.coords)) then return values end

    if screen.reportToken ~= token then screen.reportToken, screen.reports = token, {} end
    local reports = screen.reports[kind] or {}
    screen.reports[kind] = reports

    local result = {}
    for other, report in pairs(reports) do
        if other ~= src then
            for key, value in pairs(values) do
                local theirs = report[key]
                if type(value) == 'number' and type(theirs) == 'number' then
                    if math.abs(theirs - value) <= 2 then result[key] = value end
                elseif theirs ~= nil and theirs == value then
                    result[key] = value
                end
            end
        end
    end
    reports[src] = values
    return result
end

-- Players watching a screen report its duration, title and whether it is live, once per media, for what
-- the server couldn't read up front (YouTube durations, video files, HLS streams). The duration drives
-- the queue.
RegisterNetEvent('xex_tv:mediaInfo', function(id, token, info)
    local src = source
    if type(info) ~= 'table' then return end
    local screen = nearScreen(src, id, token, ':info')
    if not screen then return end

    local duration = tonumber(info.duration)
    duration = duration and math.floor(duration)
    -- A video can't be shorter than what has already played.
    if duration and (duration < 1 or duration > 86400 or duration + 5 < currentPlaybackTime(screen)) then duration = nil end

    local values = agreed(src, screen, token, 'info', {
        duration = duration,
        title = Media.sanitiseTitle(info.title),
        live = info.live == true or nil,
    })
    local live = values.live == true
    duration = not live and values.duration or nil
    local title = values.title

    -- On a channel the report goes to the channel, which updates every screen tuned to it.
    if screen.channel then
        Channels.reportMedia(screen.channel, token, duration, title)
        return
    end

    local changed = false
    if live and not screen.media.live then
        screen.media.live = true
        screen.duration = nil
        changed = true
    elseif not screen.duration and Media.hasClock(screen.media) and duration then
        screen.duration = duration
        changed = true
    end

    title = not screen.title and title
    if title then
        screen.title = title
        changed = true
    end

    if changed then
        screen.revision = nextRevision()
        broadcastScreen(screen)
    end
end)

-- Players can't play what a channel is airing (a stream that went down, a video blocked in the game
-- browser): the channel moves on to its next source. Other screens just show the error.
RegisterNetEvent('xex_tv:mediaError', function(id, token, code)
    local src = source
    local screen = nearScreen(src, id, token, ':error')
    if not screen or not screen.channel then return end

    code = type(code) == 'string' and code:sub(1, 40) or 'UNKNOWN'
    if agreed(src, screen, token, 'error', { failed = true }).failed then
        Channels.skip(screen.channel, token, code)
    end
end)

AddEventHandler('playerDropped', function()
    playerBuckets[source] = nil
    lastActionAt[source] = nil
    lastReportAt[source .. ':info'], lastReportAt[source .. ':error'] = nil, nil
    lastLibraryAt[source] = nil
    lastStateAt[source] = nil
end)

-- AUTOPLAY ---------------------------------------------------------------------------------------

CreateThread(function()
    for _, location in ipairs(locations) do
        local autoplay = location.config.autoplay
        local channel = autoplay and channelFromSource(autoplay)
        if channel then
            local screen = createScreen(location)
            applyChannel(screen, channel)
            screen.updatedBy = 'autoplay'
            screens[screen.id] = screen
            broadcastScreen(screen)
        elseif autoplay then
            -- Each screen checks its link on its own. A service that is down (archive.org, a broadcaster)
            -- is tried again a bit later each time, so the screen comes on when it is back.
            CreateThread(function()
                local delays = { 60, 120, 240, 480, 600 }
                local attempt = 0
                while true do
                    local media, err, reason, transient = Media.fromInput(autoplay, true)
                    if media then
                        local screen = createScreen(location)
                        startMedia(screen, media)
                        screen.updatedBy = 'autoplay'
                        screens[screen.id] = screen
                        -- Checking the link takes a moment: players already in (resource restart) get it now.
                        broadcastScreen(screen)
                        return
                    end
                    if not transient then
                        print(('^3[%s] Autoplay source of "%s" was rejected (%s%s). Check the link and Config.Sources.^7'):format(
                            resourceName, tostring(location.config.label or location.id), tostring(err),
                            reason and ', ' .. reason or ''))
                        return
                    end
                    attempt = attempt + 1
                    local delay = delays[math.min(attempt, #delays)]
                    if Config.Debug and attempt == 1 then
                        print(('^3[%s] Autoplay source of "%s" can\'t be checked right now (%s). Retrying in %d s.^7'):format(
                            resourceName, tostring(location.config.label or location.id), reason or tostring(err), delay))
                    end
                    Wait(delay * 1000)
                end
            end)
        end
    end
end)

-- EXPORTS ----------------------------------------------------------------------------------------

-- exports.xex_tv:playAtCoords(vec3(x, y, z), `prop_tv_flat_01`, 'https://youtu.be/...', { volume, offset, bucket, loop })
-- Returns the screen id at once; it starts playing as soon as the link is checked (usually under a second).
exports('playAtCoords', function(coords, model, input, options)
    options = type(options) == 'table' and options or {}
    if not definitionFor(model) or type(coords) ~= 'vector3' and type(coords) ~= 'table' then return false end
    local channel = channelFromSource(input)
    if not channel and not Media.parse(input, true) then return false end

    local bucket = tonumber(options.bucket) or 0
    local plain = { x = coords.x + 0.0, y = coords.y + 0.0, z = coords.z + 0.0 }
    local target = locationAt(bucket, model, plain) or {
        id = makeScreenId(bucket, model, plain),
        bucket = bucket,
        model = normalizeHash(model),
        coords = plain,
    }

    local invoker = GetInvokingResource() or 'export'
    if channel then
        local screen = screens[target.id] or createScreen(target)
        screen.volume = parseVolume(options.volume, screen.volume)
        applyChannel(screen, channel)
        screen.updatedBy = invoker
        screens[screen.id] = screen
        broadcastScreen(screen)
        return target.id
    end

    CreateThread(function()
        local media, err = Media.fromInput(input, true)
        if not media then
            print(('^3[%s] playAtCoords from %s: link rejected (%s).^7'):format(resourceName, invoker, tostring(err)))
            return
        end
        local screen = screens[target.id] or createScreen(target)
        screen.volume = parseVolume(options.volume, screen.volume)
        if options.loop ~= nil then screen.loop = options.loop == true end
        startMedia(screen, media, math.max(0, tonumber(options.offset) or 0))
        screen.updatedBy = invoker
        screens[screen.id] = screen
        broadcastScreen(screen)
    end)
    return target.id
end)

-- Returns true if the link looks valid; it joins the queue once checked.
exports('queue', function(screenId, input)
    if not screens[screenId] or screens[screenId].channel or not Media.parse(input, true) then return false end
    CreateThread(function()
        local media = Media.fromInput(input, true)
        local screen = screens[screenId]
        if not media or not screen or screen.channel or #screen.queue >= Config.Queue.maxItems then return end
        screen.queue[#screen.queue + 1] = media
        screen.revision = nextRevision()
        broadcastScreen(screen)
    end)
    return true
end)

exports('stop', function(screenId)
    local screen = screens[screenId]
    if not screen then return false end
    removeScreen(screen)
    return true
end)

exports('getScreen', function(screenId)
    local screen = screens[screenId]
    return screen and serialiseScreen(screen) or nil
end)

-- VERSION CHECK -----------------------------------------------------------------------------------

-- '1.10.0' is newer than '1.9.2'.
local function newer(latest, current)
    local a, b = {}, {}
    for n in tostring(latest):gmatch('%d+') do a[#a + 1] = tonumber(n) end
    for n in tostring(current):gmatch('%d+') do b[#b + 1] = tonumber(n) end
    for i = 1, math.max(#a, #b) do
        if (a[i] or 0) ~= (b[i] or 0) then return (a[i] or 0) > (b[i] or 0) end
    end
    return false
end

if Config.CheckForUpdates then
    CreateThread(function()
        Wait(5000)
        local current = GetResourceMetadata(resourceName, 'version', 0)
        PerformHttpRequest('https://xexstudio.com/api/version/xex_tv?v=' .. current, function(status, body)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.version then return end
            if newer(data.version, current) then
                print(('^3[%s] Update available: %s -> %s (https://keymaster.fivem.net)^7'):format(resourceName, current, data.version))
            else
                print(('^2[%s] Up to date (%s).^7'):format(resourceName, current))
            end
        end, 'GET')
    end)
end
