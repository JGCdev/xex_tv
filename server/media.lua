-- Turns what a player pastes (or what the config lists) into something every player can load.
--
-- Kinds: youtube, vimeo, archive (library films), direct (video files) and hls (live TV streams).
-- 'ytlive' is only a parsed step: whatever a YouTube channel is airing live now, resolved into a youtube media.

Media = {}

local resourceName = GetCurrentResourceName()

local function trim(value)
    if type(value) ~= 'string' then return nil end
    value = value:gsub('^%s+', ''):gsub('%s+$', '')
    if value == '' or #value > 2048 then return nil end
    return value
end

local function libraryOn()
    return Config.Library ~= nil and Config.Library.enabled == true
end

local function sourceOn(name)
    return Config.Sources ~= nil and Config.Sources[name] == true
end

-- archive.org identifiers: letters, digits, dots, dashes and underscores.
local function parseArchive(input)
    local id = input:match('archive%.org/details/([%w%._%-]+)')
        or input:match('archive%.org/download/([%w%._%-]+)')
        or input:match('^archive:([%w%._%-]+)$')
    if id and #id >= 3 and #id <= 100 then
        return { kind = 'archive', id = id, label = id }
    end
end

-- A YouTube channel by handle (@name) or id (UC...).
local function channelRef(value)
    if type(value) ~= 'string' then return nil end
    local handle = value:match('^(@[%w%._%-]+)$')
    if handle and #handle >= 4 and #handle <= 101 then return handle end
    local id = value:match('^(UC[%w_%-]+)$')
    if id and #id == 24 then return id end
end

-- 'ytlive:@handle', 'ytlive:UC...', youtube.com/@handle/live or youtube.com/channel/UC.../live.
local function parseYouTubeLive(input)
    local ref = channelRef(input:match('^[Yy][Tt][Ll][Ii][Vv][Ee]:(.+)$'))
        or channelRef(input:match('youtube%.com/(@[%w%._%-]+)/live/?$'))
        or channelRef(input:match('youtube%.com/(@[%w%._%-]+)/live[%?#]'))
        or channelRef(input:match('youtube%.com/channel/(UC[%w_%-]+)/live/?$'))
        or channelRef(input:match('youtube%.com/channel/(UC[%w_%-]+)/live[%?#]'))
    if ref then
        return { kind = 'ytlive', channel = ref, label = ref }
    end
end

local function parseYouTube(input, trusted)
    local live = parseYouTubeLive(input)
    if live then return live end

    local id = input:match('[?&]v=([%w_-]+)')
        or input:match('youtu%.be/([%w_-]+)')
        or input:match('youtube%.com/embed/([%w_-]+)')
        or input:match('youtube%-nocookie%.com/embed/([%w_-]+)')
        or input:match('youtube%.com/shorts/([%w_-]+)')
        or input:match('youtube%.com/live/([%w_-]+)')
        or input:match('^youtube:([%w_-]+)$')

    if not id and input:match('^[%w_-]+$') and #input >= 6 and #input <= 20 then
        id = input
    end

    if id and #id >= 6 and #id <= 20 then
        -- A config source on youtube.com/live/<id> is a live stream: screens report it once it has ended.
        local liveId = trusted and input:find('youtube%.com/live/') and true or nil
        return { kind = 'youtube', id = id, label = id, live = liveId }
    end
end

-- vimeo.com/<id>, vimeo.com/<id>/<hash> (unlisted), player.vimeo.com/video/<id>?h=<hash>, vimeo:<id>[/<hash>].
local function parseVimeo(input)
    local id, hash = input:match('^[Vv][Ii][Mm][Ee][Oo]:(%d+)/?(%x*)$')
    if not id then
        id = input:match('player%.vimeo%.com/video/(%d+)')
        if id then
            hash = input:match('[?&]h=(%x+)')
        else
            id, hash = input:match('vimeo%.com/(%d+)/?(%x*)')
        end
    end

    if id and #id >= 3 and #id <= 12 then
        hash = hash and #hash >= 6 and #hash <= 20 and hash or nil
        return { kind = 'vimeo', id = id, hash = hash, label = id }
    end
end

-- Host of an http(s) link, or nil. Links with backslashes, credentials or spaces are refused:
-- browsers read `https://a.com\.b.com` as a.com, which would slip past a suffix check.
local function hostOf(input)
    if input:find('[\\%s]') then return nil end
    if (input:match('^%a+://([^/%?#]*)') or ''):find('@', 1, true) then return nil end
    local host, rest = input:lower():match('^https?://([%w%.%-]+)(.*)$')
    if not host or (rest ~= '' and not rest:match('^[:/%?#]')) then return nil end
    return host
end

local function hostIs(host, domain)
    return host == domain or host:sub(-(#domain + 1)) == '.' .. domain
end

local function allowedHost(host)
    for _, allowed in ipairs(Config.AllowedMediaHosts) do
        if hostIs(host, allowed:lower()) then return true end
    end
    return false
end

-- Video files and HLS streams. Config sources (channels, fixed screens, exports) are trusted; links
-- players paste only play from Config.AllowedMediaHosts, because every player connects to that host.
local function parseStream(input, host, trusted, forceHls)
    if input:lower():sub(1, 8) ~= 'https://' then return nil end
    if not trusted and not allowedHost(host) then return nil end

    local path = input:match('^https://[^/%?#]+([^%?#]*)') or ''
    if forceHls or path:lower():match('%.m3u8$') then
        return { kind = 'hls', url = input, label = host }
    end
    local file = path:match('([^/]+)$') or host
    return { kind = 'direct', url = input, label = file:sub(1, 80) }
end

-- Returns a parsed source or nil. `trusted` is for sources from the config and from exports.
function Media.parse(raw, trusted)
    local input = trim(raw)
    if not input then return nil end
    local lower = input:lower()

    -- 'hls:https://...' marks a live stream whose URL doesn't end in .m3u8.
    local forceHls = false
    if lower:sub(1, 4) == 'hls:' then
        input, lower, forceHls = input:sub(5), lower:sub(5), true
        if not lower:match('^https://') then return nil end
    end

    if lower:match('^https?://') then
        local host = hostOf(input)
        if not host then return nil end
        if not forceHls then
            if hostIs(host, 'archive.org') then return libraryOn() and parseArchive(input) or nil end
            if hostIs(host, 'youtube.com') or hostIs(host, 'youtu.be') or hostIs(host, 'youtube-nocookie.com') then
                return sourceOn('youtube') and parseYouTube(input, trusted) or nil
            end
            if hostIs(host, 'vimeo.com') then
                return sourceOn('vimeo') and parseVimeo(input) or nil
            end
        end
        return parseStream(input, host, trusted, forceHls)
    end

    if lower:sub(1, 8) == 'archive:' then return libraryOn() and parseArchive(input) or nil end
    if lower:sub(1, 6) == 'vimeo:' then return sourceOn('vimeo') and parseVimeo(input) or nil end
    if lower:sub(1, 7) == 'ytlive:' then return sourceOn('youtube') and parseYouTubeLive(input) or nil end
    if sourceOn('youtube') then return parseYouTube(input) end
end

-- Sources whose time can be read and set. A live stream never can; an HLS stream only once a player
-- found it is a recording with a length.
function Media.isSeekable(media, duration)
    if not media or media.live then return false end
    if media.kind == 'hls' then return duration ~= nil end
    return media.kind == 'youtube' or media.kind == 'vimeo' or media.kind == 'direct' or media.kind == 'archive'
end

-- Sources whose length a player may report. Live streams have none.
function Media.hasClock(media)
    if not media or media.live then return false end
    return media.kind == 'youtube' or media.kind == 'vimeo' or media.kind == 'direct'
        or media.kind == 'archive' or media.kind == 'hls'
end

-- The service a source depends on, for sources that share one: when it is down, its other sources are
-- down too, so a channel doesn't ask it once per source. archive.org is not listed: the library holds
-- that back itself and still serves the films it has stored.
function Media.service(raw)
    local lower = type(raw) == 'string' and raw:lower() or ''
    if lower:sub(1, 7) == 'ytlive:' then return 'youtube' end
end

-- HTTP --------------------------------------------------------------------------------------------

local userAgent = ('xex_tv/%s (FiveM)'):format(GetResourceMetadata(resourceName, 'version', 0) or '?')

-- An answer that says the service, not the source, has a problem: no answer, rate limiting, server errors.
function Media.isTransient(status)
    return status == 0 or status == 408 or status == 429 or status >= 500
end
local browserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'

function Media.urlEncode(value)
    return (tostring(value):gsub('[^%w%-_%.~]', function(char) return ('%%%02X'):format(char:byte()) end))
end

-- GET from a server thread. Returns the status (0 on timeout), the body and the response headers.
function Media.httpGet(url, headers)
    local p = promise.new()
    local settled = false

    PerformHttpRequest(url, function(status, body, responseHeaders)
        if settled then return end
        settled = true
        p:resolve({ status = status, body = body, headers = responseHeaders })
    end, 'GET', '', headers or { ['User-Agent'] = userAgent })

    SetTimeout(8000, function()
        if settled then return end
        settled = true
        p:resolve({ status = 0 })
    end)

    local result = Citizen.Await(p)
    return result.status, result.body, type(result.headers) == 'table' and result.headers or {}
end

-- GET a JSON document from a server thread. Returns the status (0 on timeout) and the decoded body.
function Media.httpJson(url)
    local status, body = Media.httpGet(url, { ['Accept'] = 'application/json', ['User-Agent'] = userAgent })
    local data
    if status == 200 and body then
        local ok, decoded = pcall(json.decode, body)
        if ok and type(decoded) == 'table' then data = decoded end
    end
    return status, data
end

function Media.sanitiseTitle(title)
    if type(title) ~= 'string' or not utf8.len(title) then return nil end
    title = title:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if title == '' then return nil end
    local cut = utf8.offset(title, 121)
    return cut and title:sub(1, cut - 1) or title
end

-- Answers kept for a while, emptied when they pile up.
local function newCache(limit)
    local entries, size = {}, 0
    return {
        get = function(key)
            local entry = entries[key]
            if entry and entry.expires >= os.time() then return entry end
        end,
        set = function(key, entry, ttl)
            if size > limit then entries, size = {}, 0 end
            entry.expires = os.time() + ttl
            entries[key] = entry
            size = size + 1
        end,
    }
end

-- RESOLVE: YOUTUBE --------------------------------------------------------------------------------

local youtubeCache = newCache(500)

-- Asks YouTube (oEmbed) whether the video exists and can be embedded, and gets its title.
-- Videos limited to some domains still pass: only the game browser can tell, and the screen shows why.
local function resolveYouTube(media)
    local cached = youtubeCache.get(media.id)
    if not cached then
        local url = 'https://www.youtube.com/oembed?format=json&url='
            .. Media.urlEncode('https://www.youtube.com/watch?v=' .. media.id)
        local status, data = Media.httpJson(url)

        if status == 401 then
            cached = { error = 'not_embeddable' }
        elseif status == 400 or status == 403 or status == 404 then
            cached = { error = 'not_found' }
        else
            -- YouTube unreachable or rate limited: let the player try instead of blocking playback.
            cached = { title = data and Media.sanitiseTitle(data.title) }
        end
        youtubeCache.set(media.id, cached, status == 200 and 1800 or 300)
    end

    if cached.error then return nil, cached.error end
    return {
        kind = 'youtube',
        id = media.id,
        label = cached.title or media.id,
        title = cached.title,
        live = media.live or nil,
    }
end

local liveCache = newCache(200)

-- The video a channel is airing live now. Its /live page points to that video while it is on air,
-- and to the channel itself when it isn't.
local function resolveYouTubeLive(media)
    local cached = liveCache.get(media.channel)
    if not cached then
        local path = media.channel:sub(1, 1) == '@' and media.channel or 'channel/' .. media.channel
        local status, body = Media.httpGet('https://www.youtube.com/' .. path .. '/live', {
            ['User-Agent'] = browserAgent,
            ['Accept-Language'] = 'en',
            -- Skips the cookie consent page YouTube shows to servers in the EU.
            ['Cookie'] = 'SOCS=CAI',
        })

        if status == 200 and type(body) == 'string' then
            local id = body:match('<link rel="canonical" href="https://www%.youtube%.com/watch%?v=([%w_-]+)"')
            -- A scheduled stream also has a watch page: only take one that is on air.
            local onAir = body:find('"isLiveNow":true', 1, true)
                or body:find('"isLive":true', 1, true) and not body:find('"isUpcoming":true', 1, true)
            if id and onAir then
                cached = { id = id }
            else
                cached = { error = 'not_live' }
            end
        elseif status == 404 then
            cached = { error = 'not_found' }
        else
            cached = { error = 'stream_failed', reason = ('HTTP %s'):format(tostring(status)), transient = Media.isTransient(status) }
        end
        liveCache.set(media.channel, cached, cached.id and 120 or cached.transient and 30 or 60)
    end

    if cached.error then return nil, cached.error, cached.reason, cached.transient end
    local resolved, err = resolveYouTube({ id = cached.id, live = true })
    if not resolved then return nil, err end
    return resolved
end

-- RESOLVE: VIMEO ----------------------------------------------------------------------------------

local vimeoCache = newCache(300)

-- Vimeo's oEmbed tells whether the video exists, its title and its length. Videos the owner limited to
-- some websites come back without a title: those can't play in the game.
local function resolveVimeo(media)
    local key = media.id .. '/' .. (media.hash or '')
    local cached = vimeoCache.get(key)
    if not cached then
        local page = 'https://vimeo.com/' .. media.id .. (media.hash and '/' .. media.hash or '')
        local status, data = Media.httpJson('https://vimeo.com/api/oembed.json?url=' .. Media.urlEncode(page))

        if status == 200 and data then
            local title = Media.sanitiseTitle(data.title)
            local duration = math.tointeger(tonumber(data.duration))
            if title then
                cached = { title = title, duration = duration and duration >= 1 and duration or nil }
            else
                cached = { error = 'not_embeddable' }
            end
        elseif status == 403 then
            cached = { error = 'not_embeddable' }
        elseif status == 404 then
            cached = { error = 'not_found' }
        else
            -- Vimeo unreachable: let the player try.
            cached = {}
        end
        vimeoCache.set(key, cached, status == 200 and 1800 or 300)
    end

    if cached.error then return nil, cached.error end
    return {
        kind = 'vimeo',
        id = media.id,
        hash = media.hash,
        label = cached.title or media.id,
        title = cached.title,
        duration = cached.duration,
    }
end

-- RESOLVE: HLS ------------------------------------------------------------------------------------

local streamCache = newCache(300)

-- Where the screens load the player from. The stream has to allow that origin (CORS) or the browser
-- refuses to read it.
local function playerOrigin()
    local url = Config.Playback and Config.Playback.playerUrl
    local origin = type(url) == 'string' and url:match('^(https?://[^/%?#]+)')
    return origin or ('https://cfx-nui-%s'):format(resourceName)
end

local function header(headers, name)
    for key, value in pairs(headers) do
        if type(key) == 'string' and key:lower() == name then return value end
    end
end

-- Checks that the playlist answers, is an HLS playlist and lets the game browser read it.
local function resolveHls(media)
    local cached = streamCache.get(media.url)
    if not cached then
        local origin = playerOrigin()
        local status, body, headers = Media.httpGet(media.url, { ['User-Agent'] = browserAgent, ['Origin'] = origin })
        local allowed = header(headers, 'access-control-allow-origin')

        if status ~= 200 or type(body) ~= 'string' or body:sub(1, 7) ~= '#EXTM3U' then
            cached = { error = 'stream_failed', reason = ('HTTP %s'):format(tostring(status)), transient = Media.isTransient(status) }
        elseif allowed ~= '*' and allowed ~= origin then
            cached = { error = 'stream_failed', reason = 'the stream does not allow browser playback (CORS)' }
        else
            -- A media playlist without an end is live. A master playlist doesn't say: the player tells.
            local live = not body:find('#EXT-X-STREAM-INF', 1, true) and not body:find('#EXT-X-ENDLIST', 1, true)
            cached = { live = live }
        end
        streamCache.set(media.url, cached, cached.transient and 30 or cached.error and 60 or 300)
    end

    if cached.error then return nil, cached.error, cached.reason, cached.transient end
    return { kind = 'hls', url = media.url, label = media.label, live = cached.live or nil }
end

-- Turns a parsed source into something every player can load. Must run in a thread: it may ask YouTube,
-- Vimeo, archive.org or the stream first. Returns the media, or nil, a locale key, a reason for the console
-- and whether the failure is the service's (down, rate limiting, timeout) rather than the source's.
function Media.resolve(media, trusted)
    if not media then return nil, 'invalid_source' end
    if media.kind == 'youtube' then return resolveYouTube(media) end
    if media.kind == 'ytlive' then return resolveYouTubeLive(media) end
    if media.kind == 'vimeo' then return resolveVimeo(media) end
    if media.kind == 'archive' then return Library.resolve(media.id, trusted) end
    if media.kind == 'hls' then return resolveHls(media) end
    return media
end

function Media.fromInput(raw, trusted)
    return Media.resolve(Media.parse(raw, trusted), trusted)
end
