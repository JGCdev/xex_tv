-- 24/7 channels. Each one plays its list nonstop; screens tuned to it join at the current second.
-- A live source (TV stream, YouTube live) plays until it fails; the next source of the list is its backup.

Channels = {}

local cfg = Config.Channels or {}
local channels = {}
local order = {}
local listeners = {}
local tokenCounter = 0
local resourceName = GetCurrentResourceName()

local checkInterval = math.max(60, tonumber(cfg.checkInterval) or 180) -- seconds between checks of a live source
local failedFor = 600 -- a source that failed is skipped this long, unless every source of the channel failed
local outageFor = 60 -- a source its service couldn't answer for (timeout, 429, 5xx) is tried again this soon
local retryDelays = { 60, 120, 240, 480, 600 } -- a channel with nothing to play waits longer each time

local function shuffled(list)
    local copy = {}
    for i, value in ipairs(list) do copy[i] = value end
    for i = #copy, 2, -1 do
        local j = math.random(i)
        copy[i], copy[j] = copy[j], copy[i]
    end
    return copy
end

local function notify(channel)
    for _, listener in ipairs(listeners) do listener(channel) end
end

-- A source failing is part of running channels (a stream ends, a broadcaster moves it, YouTube walls off
-- the host): the backup takes over. Each failure is printed only with Config.Debug.
local function warn(channel, source, err, reason)
    if not Config.Debug then return end
    print(('^3[%s] Channel "%s": %s failed (%s%s).^7'):format(resourceName, channel.id, tostring(source),
        tostring(err), reason and ', ' .. reason or ''))
end

local function publish(channel, source, media)
    tokenCounter = tokenCounter + 1
    channel.source = media and source or nil
    channel.media = media
    channel.mediaToken = ('ch:%s:%d'):format(channel.id, tokenCounter)
    channel.startedAt = os.time()
    channel.checkedAt = os.time()
    channel.duration = media and media.duration or nil
    channel.title = media and media.title or nil
    if media then
        channel.retryAt, channel.retries = nil, 0
    else
        channel.retries = (channel.retries or 0) + 1
        channel.retryAt = os.time() + retryDelays[math.min(channel.retries, #retryDelays)]
    end
    notify(channel)
end

-- Tries one source. A source its service couldn't answer for (archive.org or a broadcaster down, rate
-- limiting, a timeout) is not broken: it is retried soon and not printed, unless the whole channel ends
-- up with nothing. Other failures (removed, geo-blocked, not live now) are printed, as they need a look.
local function try(channel, source, now, outage)
    local media, err, reason, transient = Media.fromInput(source, true)
    if media then
        channel.failedUntil[source], channel.blockedUntil[source] = nil, nil
        return media
    end
    if transient then
        channel.failedUntil[source] = now + outageFor
        local why = reason or tostring(err)
        outage[why] = (outage[why] or 0) + 1
        outage.n = (outage.n or 0) + 1
    else
        channel.failedUntil[source] = now + failedFor
        warn(channel, source, err, reason)
    end
end

-- Plays the next source that resolves, skipping the ones that failed lately. If none works the
-- channel waits and tries again, a bit later each time.
local function advance(channel)
    if channel.switching then return end
    channel.switching = true

    CreateThread(function()
        local now = os.time()
        local media, picked
        local skipped, outage = {}, {}

        -- The first pass skips recent failures and, once a service is down, the rest of its sources.
        local serviceDown = {}
        for _ = 1, #channel.sources do
            channel.position = channel.position + 1
            if channel.position > #channel.playlist then
                if channel.shuffle then channel.playlist = shuffled(channel.sources) end
                channel.position = 1
            end

            local source = channel.playlist[channel.position]
            local service = Media.service(source)
            if (channel.failedUntil[source] or 0) > now then
                skipped[#skipped + 1] = source
            elseif service and serviceDown[service] then
                channel.failedUntil[source] = now + outageFor
            else
                local before = outage.n or 0
                media = try(channel, source, now, outage)
                if media then
                    picked = source
                    break
                end
                if service and (outage.n or 0) > before then serviceDown[service] = true end
            end
        end

        -- The second pass gives the skipped ones another chance, except to the ones players couldn't play
        -- (those would only fail again on every screen) and to a service that is down right now.
        if not media then
            for _, source in ipairs(skipped) do
                local service = Media.service(source)
                if (channel.blockedUntil[source] or 0) <= now and not (service and serviceDown[service]) then
                    media = try(channel, source, now, outage)
                    if media then
                        picked = source
                        break
                    end
                end
            end
        end

        channel.switching = false
        publish(channel, picked, media)

        -- A channel that goes dark prints one line, not one per retry, unless Config.Debug is on.
        if media then
            channel.dark = nil
        elseif Config.Debug or not channel.dark then
            channel.dark = true
            local reasons = {}
            for why, count in pairs(outage) do
                if why ~= 'n' then reasons[#reasons + 1] = count > 1 and ('%s, %d sources'):format(why, count) or why end
            end
            table.sort(reasons)
            print(('^3[%s] Channel "%s": nothing to play right now%s. Retrying quietly%s.^7'):format(resourceName,
                channel.id, #reasons > 0 and ' (' .. table.concat(reasons, '; ') .. ')' or '',
                Config.Debug and (' in %d s'):format(channel.retryAt - os.time()) or ' (Config.Debug = true shows why)'))
        end
    end)
end

-- A live source is checked again from time to time: it may have ended, or the YouTube channel may be
-- airing a new stream.
local function recheck(channel)
    if channel.switching then return end
    channel.switching = true
    channel.checkedAt = os.time()

    CreateThread(function()
        local source, current = channel.source, channel.media
        local media, err, reason, transient = Media.fromInput(source, true)
        channel.switching = false
        if channel.media ~= current then return end

        if not media then
            if transient then
                -- The check itself failed, not the stream: keep playing and look again sooner. Players
                -- report the stream if it really stopped.
                channel.checkedAt = os.time() - checkInterval + outageFor
                return
            end
            channel.failedUntil[source] = os.time() + failedFor
            warn(channel, source, err, reason)
            advance(channel)
        elseif media.kind ~= current.kind or media.id ~= current.id or media.url ~= current.url then
            publish(channel, source, media)
        end
    end)
end

-- CONFIG ------------------------------------------------------------------------------------------

if cfg.enabled then
    for index, entry in ipairs(cfg.list or {}) do
        local id = type(entry.id) == 'string' and entry.id:match('^[%w_%-]+$') and entry.id
        local sources = {}
        for _, source in ipairs(type(entry.sources) == 'table' and entry.sources or {}) do
            if type(source) == 'string' and Media.parse(source, true) then
                sources[#sources + 1] = source
            else
                print(('^3[%s] Config.Channels.list[%d]: source %s is not supported here (check Config.Sources and Config.Library), skipped.^7')
                    :format(resourceName, index, tostring(source)))
            end
        end

        if not id or channels[id] or #sources == 0 then
            print(('^3[%s] Config.Channels.list[%d]: needs a unique id (letters, digits, - and _) and at least one source. Skipped.^7'):format(
                resourceName, index))
        else
            local category = type(entry.category) == 'string' and entry.category:match('^[%w_%-]+$')
            local channel = {
                id = id,
                label = type(entry.label) == 'string' and entry.label or id,
                category = category and category:lower() or nil,
                shuffle = entry.shuffle == true,
                sources = sources,
                position = 0,
                failedUntil = {},
                blockedUntil = {},
            }
            channel.playlist = channel.shuffle and shuffled(sources) or sources
            channels[id] = channel
            order[#order + 1] = channel
            channel.number = #order
        end
    end
end

-- The channel clock. Timed items move on when they end; live ones are checked every few minutes.
CreateThread(function()
    for _, channel in ipairs(order) do advance(channel) end
    if #order == 0 then return end

    while true do
        Wait(1000)
        local now = os.time()
        for _, channel in ipairs(order) do
            if not channel.switching then
                if channel.media and channel.duration then
                    if now - channel.startedAt >= channel.duration then advance(channel) end
                elseif channel.media then
                    if now - channel.checkedAt >= checkInterval then recheck(channel) end
                elseif channel.retryAt and now >= channel.retryAt then
                    advance(channel)
                end
            end
        end
    end
end)

-- API ---------------------------------------------------------------------------------------------

function Channels.onChange(listener)
    listeners[#listeners + 1] = listener
end

function Channels.get(id)
    return type(id) == 'string' and channels[id] or nil
end

-- For the remote: every channel, its number and what it plays now.
function Channels.list()
    local list = {}
    for _, channel in ipairs(order) do
        list[#list + 1] = {
            id = channel.id,
            number = channel.number,
            label = channel.label,
            category = channel.category,
            title = channel.title,
            kind = channel.media and channel.media.kind or nil,
            live = channel.media ~= nil and channel.duration == nil,
        }
    end
    return list
end

-- A player watching the channel reports the length (YouTube, video files) once; the channel then knows
-- when to move on.
function Channels.reportMedia(id, token, duration, title)
    local channel = channels[id]
    if not channel or channel.mediaToken ~= token then return end

    local changed = false
    if not channel.duration and Media.hasClock(channel.media) and duration then
        channel.duration = duration
        changed = true
    end
    if not channel.title and title then
        channel.title = title
        changed = true
    end
    if changed then notify(channel) end
end

-- Players can't play the current source (a stream that stopped, a video blocked in the game browser).
-- The caller has already checked the report; the channel moves on to its next source.
function Channels.skip(id, token, reason)
    local channel = channels[id]
    if not channel or channel.mediaToken ~= token or channel.switching or not channel.source then return end
    channel.failedUntil[channel.source] = os.time() + failedFor
    channel.blockedUntil[channel.source] = os.time() + failedFor
    warn(channel, channel.source, 'players could not play it', reason)
    advance(channel)
end
