-- Movie library: public domain films from the Internet Archive. Players send an id; the file is picked here.

Library = {}

local cfg = Config.Library or { enabled = false }
local searchCache = {}
local searchCacheSize = 0
local itemCache = {}
local featuredCache
local blocked = {}
local featuredIds = {}

for _, id in ipairs(cfg.blocked or {}) do blocked[id] = true end
for _, id in ipairs(cfg.featured or {}) do featuredIds[id] = true end

-- Only items with a video the game browser plays (MP4).
local collection = 'feature_films'
local pageSize = 24

local formatFilter = 'format:("h.264" OR MPEG4 OR "512Kb MPEG4")'

-- The archive is user uploaded: keep adult titles out of the results.
local adultFilter = '-subject:(sex OR sexploitation OR erotic OR erotica OR nudity OR nude OR nudist OR adult'
    .. ' OR exploitation OR burlesque OR striptease OR stag)'
    .. ' -title:(sex OR sexy OR nude OR nudist OR erotic OR naked OR stag OR striptease)'

-- The same words, for links pasted by hand (checked against the item's title and subjects).
local adultWords = {
    sex = true, sexy = true, sexploitation = true, erotic = true, erotica = true, nudity = true, nude = true,
    nudist = true, naked = true, adult = true, exploitation = true, burlesque = true, striptease = true, stag = true,
}

local function isAdult(metadata)
    local fields = { metadata.title, metadata.subject }
    for _, field in ipairs(fields) do
        local values = type(field) == 'table' and field or { field }
        for _, value in ipairs(values) do
            if type(value) == 'string' then
                for word in value:lower():gmatch('%a+') do
                    if adultWords[word] then return true end
                end
            end
        end
    end
    return false
end

local genres = {
    noir = 'subject:(noir)',
    horror = 'subject:(horror)',
    comedy = 'subject:(comedy)',
    western = 'subject:(western)',
    scifi = 'subject:("science fiction" OR sci-fi OR scifi)',
    silent = 'subject:(silent)',
    animation = 'subject:(animation OR cartoon OR animated)',
}

Library.genres = { 'noir', 'horror', 'comedy', 'western', 'scifi', 'silent', 'animation' }

local function validId(id)
    return type(id) == 'string' and #id >= 3 and #id <= 100 and id:match('^[%w%._%-]+$') ~= nil
end

-- Uploads marked as public domain only: that leaves out most re-uploads of films still under copyright.
local baseQuery = 'collection:(' .. collection .. ') AND mediatype:movies AND licenseurl:(*publicdomain*) AND '
    .. formatFilter .. ' ' .. adultFilter

-- Words only: no field names, operators or wildcards from players.
local function cleanWords(text)
    if type(text) ~= 'string' then return nil end
    text = text:sub(1, 60):gsub('[%c%(%)%[%]{}:"\'\\%^~%*%?!%+&|/<>=%-]', ' ')
    local words = {}
    for word in text:gmatch('%S+') do
        local lower = word:lower()
        if lower ~= 'and' and lower ~= 'or' and lower ~= 'not' and #words < 6 then words[#words + 1] = word end
    end
    return #words > 0 and table.concat(words, ' AND ') or nil
end

local function toYear(value)
    local year = tonumber(type(value) == 'string' and value:match('%d%d%d%d') or value)
    return year and math.floor(year) or nil
end

local function toItems(docs)
    local items, seen = {}, {}
    for _, doc in ipairs(docs or {}) do
        local id = doc.identifier
        local title = Media.sanitiseTitle(type(doc.title) == 'table' and doc.title[1] or doc.title)
        if validId(id) and title and not blocked[id] then
            local year = toYear(doc.year)
            -- "The Little Shop of Horrors (1960)": move the year out of the title.
            local bare, inTitle = title:match('^(.-)%s*%((%d%d%d%d)%)$')
            if bare and bare ~= '' then
                title, year = bare, year or tonumber(inTitle)
            end
            -- The archive often has the same film several times: show it once.
            local key = title:lower():gsub('[^%w]', '') .. ':' .. tostring(year or '')
            if not seen[key] then
                seen[key] = true
                items[#items + 1] = { id = id, title = title, year = year }
            end
        end
    end
    return items
end

local function searchUrl(query, page, rows, sortByDownloads)
    local url = 'https://archive.org/advancedsearch.php?q=' .. Media.urlEncode(query)
        .. '&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=year'
        .. ('&rows=%d&page=%d&output=json'):format(rows, page)
    if sortByDownloads then url = url .. '&sort%5B%5D=' .. Media.urlEncode('downloads desc') end
    return url
end

local function featured()
    if featuredCache and featuredCache.expires > os.time() then return featuredCache.result end

    local ids = {}
    for _, id in ipairs(cfg.featured or {}) do
        if validId(id) and not blocked[id] then ids[#ids + 1] = id end
    end
    if #ids == 0 then return { ok = true, featured = true, items = {}, hasMore = false } end

    local status, data = Media.httpJson(searchUrl(('identifier:(%s)'):format(table.concat(ids, ' OR ')), 1, #ids, false))
    if status ~= 200 or not data or not data.response then return { ok = false, message = 'library_failed' } end

    -- Keep the order of the config.
    local byId = {}
    for _, item in ipairs(toItems(data.response.docs)) do byId[item.id] = item end
    local items = {}
    for _, id in ipairs(ids) do
        if byId[id] then items[#items + 1] = byId[id] end
    end

    local result = { ok = true, featured = true, items = items, hasMore = false }
    featuredCache = { result = result, expires = os.time() + 3600 }
    return result
end

-- request = { query = 'words', genre = 'noir', page = 1 }. Must run in a thread.
function Library.search(request)
    request = type(request) == 'table' and request or {}
    local words = cleanWords(request.query)
    local genre = type(request.genre) == 'string' and genres[request.genre] or nil
    local page = math.tointeger(tonumber(request.page)) or 1
    page = math.max(1, math.min(page, 20))

    if not words and not genre then return featured() end

    local query = baseQuery
    if genre then query = query .. ' AND ' .. genre end
    if words then query = query .. (' AND (%s)'):format(words) end

    local rows = pageSize
    local key = query .. '#' .. page
    local cached = searchCache[key]
    if cached and cached.expires > os.time() then return cached.result end

    local status, data = Media.httpJson(searchUrl(query, page, rows, true))
    if status ~= 200 or not data or not data.response then return { ok = false, message = 'library_failed' } end

    local total = tonumber(data.response.numFound) or 0
    local result = {
        ok = true,
        items = toItems(data.response.docs),
        page = page,
        hasMore = page < 20 and page * rows < total,
    }

    if searchCacheSize > 200 then searchCache, searchCacheSize = {}, 0 end
    searchCache[key] = { result = result, expires = os.time() + 900 }
    searchCacheSize = searchCacheSize + 1
    return result
end

-- FILE PICKING ------------------------------------------------------------------------------------

-- Web-ready H.264 first, then the original MP4, then the low quality copy.
local function formatRank(file)
    if type(file.name) ~= 'string' or not file.name:lower():match('%.mp4$') then return 0 end
    local format = type(file.format) == 'string' and file.format or ''
    if format == 'h.264' or format == 'h.264 IA' then return 4 end
    if format:sub(1, 5) == 'h.264' then return 3 end
    if format == 'MPEG4' then return 2 end
    if format == '512Kb MPEG4' then return 1 end
    return 0
end

local function seconds(value)
    if type(value) == 'number' then return value end
    if type(value) ~= 'string' then return 0 end
    if value:find(':', 1, true) then
        local total = 0
        for part in value:gmatch('[^:]+') do total = total * 60 + (tonumber(part) or 0) end
        return total
    end
    return tonumber(value) or 0
end

local function pickFile(files)
    local candidates, longest = {}, 0
    for _, file in ipairs(files or {}) do
        if formatRank(file) > 0 then
            candidates[#candidates + 1] = file
            longest = math.max(longest, seconds(file.length))
        end
    end

    -- Some items also hold trailers or chapters: the film is the longest video.
    local best
    for _, file in ipairs(candidates) do
        if seconds(file.length) >= longest * 0.9 then
            if not best or formatRank(file) > formatRank(best)
                or formatRank(file) == formatRank(best) and (tonumber(file.size) or 0) < (tonumber(best.size) or 0)
            then
                best = file
            end
        end
    end
    return best
end

local function inCollection(metadata)
    local collections = metadata.collection
    if type(collections) == 'string' then collections = { collections } end
    for _, name in ipairs(type(collections) == 'table' and collections or {}) do
        if name == collection then return true end
    end
    return false
end

-- archive.org answers one request at a time, with a short gap: on boot every film channel asks at
-- once, and bursts are what gets a server rate limited.
local queueTail, queueHead = 0, 0

local function metadataRequest(id)
    queueTail = queueTail + 1
    local ticket = queueTail
    while queueHead + 1 ~= ticket do Wait(50) end
    local ok, status, data = pcall(Media.httpJson, 'https://archive.org/metadata/' .. Media.urlEncode(id))
    Wait(250)
    queueHead = ticket
    if not ok then return 0 end
    return status, data
end

-- Resolved films are kept in the server's KVP store, so a restart doesn't depend on archive.org
-- answering: the stored file is used whenever archive.org is down, and refreshed when it is back.
local kvpPrefix = 'xex_tv:archive:'
local kvpAvailable = type(GetResourceKvpString) == 'function' and type(SetResourceKvp) == 'function'

local function loadStored(id)
    if not kvpAvailable then return nil end
    local ok, raw = pcall(GetResourceKvpString, kvpPrefix .. id)
    if not ok or type(raw) ~= 'string' then return nil end
    local decoded, stored = pcall(json.decode, raw)
    if not decoded or type(stored) ~= 'table' or type(stored.media) ~= 'table' or type(stored.media.url) ~= 'string' then
        return nil
    end
    return stored
end

local function store(id, media, trustedOnly)
    if not kvpAvailable then return end
    pcall(SetResourceKvp, kvpPrefix .. id, json.encode({ media = media, trustedOnly = trustedOnly or nil }))
end

local function forget(id)
    if not kvpAvailable or type(DeleteResourceKvp) ~= 'function' then return end
    pcall(DeleteResourceKvp, kvpPrefix .. id)
end

-- After archive.org fails to answer, nothing is asked of it for a while: stored films play, the rest wait.
local downFor = 60
local downUntil, downStatus = 0, 0

-- Returns a playable media for an archive.org identifier, or nil, a locale key, a reason for the console
-- and whether archive.org itself failed (so the caller retries soon). Must run in a thread.
-- `trusted` (ids from the config or exports) may be any archive.org video, not only library films.
function Library.resolve(id, trusted)
    if not cfg.enabled or not validId(id) or blocked[id] then return nil, 'invalid_source' end

    local cached = itemCache[id]
    if cached and cached.expires > os.time() then
        if cached.error then return nil, cached.error end
        if cached.trustedOnly and not trusted then return nil, 'not_in_library' end
        return cached.media
    end

    -- archive.org down or rate limiting a moment ago: don't ask again yet, every call would fail the same.
    local status, data
    if os.time() < downUntil then
        status = downStatus
    else
        status, data = metadataRequest(id)
        if Media.isTransient(status) then downUntil, downStatus = os.time() + downFor, status end
    end

    if Media.isTransient(status) then
        -- A film resolved before keeps playing from the stored answer (its download URL doesn't change);
        -- the stored answer is refreshed on a later call.
        local stored = loadStored(id)
        if stored then
            itemCache[id] = { media = stored.media, trustedOnly = stored.trustedOnly, expires = os.time() + 600 }
            if stored.trustedOnly and not trusted then return nil, 'not_in_library' end
            return stored.media
        end
        return nil, 'library_failed', ('archive.org HTTP %s'):format(tostring(status)), true
    end
    if status ~= 200 then return nil, 'library_failed', ('archive.org HTTP %s'):format(tostring(status)) end

    local metadata = data and data.metadata
    local file = metadata and not data.is_dark and pickFile(data.files)
    if not metadata or metadata.mediatype ~= 'movies' or not file then
        itemCache[id] = { error = 'film_unavailable', expires = os.time() + 600 }
        forget(id)
        return nil, 'film_unavailable'
    end

    -- Pasted links follow the same rules as the search: the films collection, public domain, no adult titles.
    local license = type(metadata.licenseurl) == 'string' and metadata.licenseurl or ''
    local trustedOnly = not featuredIds[id]
        and (not inCollection(metadata) or isAdult(metadata) or not license:find('publicdomain', 1, true))

    local path = {}
    for part in file.name:gmatch('[^/]+') do path[#path + 1] = Media.urlEncode(part) end

    local title = Media.sanitiseTitle(type(metadata.title) == 'table' and metadata.title[1] or metadata.title) or id
    local duration = math.floor(seconds(file.length))
    local media = {
        kind = 'archive',
        id = id,
        url = ('https://archive.org/download/%s/%s'):format(Media.urlEncode(id), table.concat(path, '/')),
        label = title,
        title = title,
        duration = duration >= 1 and duration or nil,
    }

    itemCache[id] = { media = media, trustedOnly = trustedOnly, expires = os.time() + 21600 }
    store(id, media, trustedOnly)
    if trustedOnly and not trusted then return nil, 'not_in_library' end
    return media
end
