-- Client: finds screens, renders the closest ones (one DUI each) and keeps them in sync with the server.

lib.locale()

TV = {
    states = {},
    localMute = false,
    listeners = {},
}

local runtimes = {}
local activeRuntimeIds = {}
local modelLookup = {}
local modelHashes = {}
local nearestTv
local currentBucket = 0
local playerErrors = {}
local reportedTokens = {}
local reportedErrors = {}
local registeredRenderTargets = {}
local spawnedProps = {}
local resourceName = GetCurrentResourceName()
local playback = Config.Playback

local creating = {}
local scanInterval = 750
local falloffStart = 1.5 -- metres at full volume; then it fades out up to the model's drawDistance
local helpDistance = 2.0
local driftTolerance = 3.0 -- seconds before a screen jumps back in sync
local driftCheckInterval = 15000
local stateRefreshInterval = 60000 -- full re-sync in case an event was lost; bucket changes are instant

local function normalizeHash(hash)
    hash = tonumber(hash)
    if not hash then return nil end
    if hash < 0 then return hash + 4294967296 end
    return hash
end

for _, definition in ipairs(Config.Models) do
    definition.hash = definition.hash or joaat(definition.model)
    definition.label = definition.label or definition.model
    modelLookup[normalizeHash(definition.hash)] = definition
    modelHashes[#modelHashes + 1] = definition.hash
end

local function debugPrint(...)
    if Config.Debug then print(('[%s]'):format(resourceName), ...) end
end

function TV.notify(key, kind, ...)
    lib.notify({ title = Config.UI.brand .. ' ' .. Config.UI.title, description = locale(key, ...), type = kind or 'inform' })
end

local function distanceBetween(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function TV.definitionFor(model)
    return modelLookup[normalizeHash(model)]
end

function TV.currentTime(state)
    local current = tonumber(state.currentTime) or 0
    if state.playing and state.receivedAt then
        current = current + math.max(0, GetGameTimer() - state.receivedAt) / 1000
    end
    if state.duration then current = math.min(current, state.duration) end
    return current
end

function TV.findState(tv)
    if not tv then return nil end
    local model = normalizeHash(tv.model)
    for _, state in pairs(TV.states) do
        if normalizeHash(state.model) == model and distanceBetween(state.coords, tv.coords) <= 0.75 then
            return state
        end
    end
end

function TV.descriptor(tv)
    return { model = tv.model, coords = { x = tv.coords.x, y = tv.coords.y, z = tv.coords.z } }
end

function TV.fromEntity(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    local model = GetEntityModel(entity)
    local definition = TV.definitionFor(model)
    if not definition then return nil end
    local coords = GetEntityCoords(entity)
    return {
        entity = entity,
        model = model,
        coords = coords,
        definition = definition,
        distance = #(GetEntityCoords(cache.ped) - coords),
    }
end

function TV.nearest()
    return nearestTv
end

local function emit(id)
    for _, listener in ipairs(TV.listeners) do listener(id) end
end

-- DUI RUNTIMES -----------------------------------------------------------------------------------

local playerTextKeys = {
    'player_waiting', 'player_loading', 'player_failed', 'player_no_detail', 'player_code',
    'player_yt_2', 'player_yt_5', 'player_yt_100', 'player_yt_101', 'player_yt_153', 'player_yt_other',
    'player_api_failed', 'player_direct_failed', 'player_stream_failed', 'player_vimeo_failed', 'player_autoplay',
    'player_unsupported', 'kind_youtube', 'kind_vimeo', 'kind_archive', 'kind_direct', 'kind_hls',
}

local playerTexts
local function getPlayerTexts()
    if not playerTexts then
        playerTexts = {}
        for _, key in ipairs(playerTextKeys) do playerTexts[key] = locale(key) end
    end
    return playerTexts
end

local function sendRuntimeMessage(runtime, action, volume)
    local state = TV.states[runtime.id]
    if not state or not runtime.dui or not IsDuiAvailable(runtime.dui) then return end

    SendDuiMessage(runtime.dui, json.encode({
        action = action,
        screenId = state.id,
        mediaToken = state.mediaToken,
        media = state.media,
        playing = state.playing,
        currentTime = TV.currentTime(state),
        volume = volume or runtime.lastVolume or state.volume,
        driftTolerance = driftTolerance,
        ui = action == 'load' and Config.UI or nil,
        texts = action == 'load' and getPlayerTexts() or nil,
    }))
end

local function destroyRuntime(id)
    local runtime = runtimes[id]
    if not runtime then return end
    if runtime.dui then DestroyDui(runtime.dui) end
    runtimes[id] = nil
    activeRuntimeIds[id] = nil
end

local function registerRenderTarget(definition, model)
    local name = definition.renderTarget
    if not IsNamedRendertargetRegistered(name) then RegisterNamedRendertarget(name, false) end
    if not IsNamedRendertargetLinked(model) then LinkNamedRendertarget(model) end
    if not IsNamedRendertargetRegistered(name) then return nil end
    registeredRenderTargets[name] = true
    return GetNamedRendertargetRenderId(name)
end

local function playerUrl()
    if playback.playerUrl and playback.playerUrl ~= '' then return playback.playerUrl end
    return ('https://cfx-nui-%s/ui/player/player.html'):format(resourceName)
end

local function createRuntime(state, definition)
    if runtimes[state.id] then return runtimes[state.id] end

    local renderId = registerRenderTarget(definition, state.model)
    if not renderId or renderId == 0 then
        print(('[%s] Could not register render target %s for %s.'):format(resourceName, definition.renderTarget, definition.label))
        return nil
    end

    local dui = CreateDui(playerUrl(), 1280, 720)
    if not dui then return nil end

    local timeout = GetGameTimer() + 10000
    while not IsDuiAvailable(dui) and GetGameTimer() < timeout do Wait(50) end
    if not IsDuiAvailable(dui) then
        DestroyDui(dui)
        print(('[%s] DUI was not available for screen %s.'):format(resourceName, state.id))
        return nil
    end

    local suffix = tostring(normalizeHash(joaat(state.id)))
    local txdName, textureName = 'xex_tv_' .. suffix, 'screen_' .. suffix
    CreateRuntimeTextureFromDuiHandle(CreateRuntimeTxd(txdName), textureName, GetDuiHandle(dui))

    local runtime = {
        id = state.id,
        dui = dui,
        txdName = txdName,
        textureName = textureName,
        renderId = renderId,
        lastVolume = 0,
    }
    runtimes[state.id] = runtime
    sendRuntimeMessage(runtime, 'load', 0)
    return runtime
end

local function updateState(payload)
    if type(payload) ~= 'table' or not payload.id then return end
    payload.receivedAt = GetGameTimer()
    TV.states[payload.id] = payload

    local runtime = runtimes[payload.id]
    if runtime then sendRuntimeMessage(runtime, 'sync', runtime.lastVolume) end
    emit(payload.id)
end

RegisterNetEvent('xex_tv:syncAll', function(payload, bucket)
    payload = type(payload) == 'table' and payload or {}
    currentBucket = tonumber(bucket) or 0

    for id in pairs(runtimes) do
        if not payload[id] then destroyRuntime(id) end
    end

    TV.states = {}
    for _, state in pairs(payload) do updateState(state) end
    emit(nil)
end)

TV.applyState = updateState

RegisterNetEvent('xex_tv:syncOne', updateState)

RegisterNetEvent('xex_tv:removeOne', function(id)
    TV.states[id] = nil
    playerErrors[id] = nil
    destroyRuntime(id)
    emit(id)
end)

-- Walls: compares the player's interior and room with the screen's. Outdoors both are 0.
local function roomFactor(entity)
    local room = playback.roomAudio
    if not room or not room.enabled or not entity then return 1.0 end

    local pedInterior, screenInterior = GetInteriorFromEntity(cache.ped), GetInteriorFromEntity(entity)
    if pedInterior ~= screenInterior then return room.otherInterior or 0.1 end
    if pedInterior ~= 0 and GetRoomKeyFromEntity(cache.ped) ~= GetRoomKeyFromEntity(entity) then
        return room.otherRoom or 0.4
    end
    return 1.0
end

local function effectiveVolume(state, definition, distance, entity)
    if TV.localMute then return 0 end
    local start = falloffStart
    local maxDistance = math.max(start + 0.1, definition.drawDistance)
    local factor = 1.0
    if distance > start then
        factor = math.max(0.0, math.min(1.0, 1.0 - (distance - start) / (maxDistance - start)))
    end
    return math.floor(state.volume * factor * factor * roomFactor(entity) + 0.5)
end

-- Picks the closest screens (one per render target, as GTA shares a render target per model)
-- and keeps a DUI only for those.
CreateThread(function()
    while true do
        local playerCoords = GetEntityCoords(cache.ped)
        local byRenderTarget = {}

        for id, state in pairs(TV.states) do
            local definition = TV.definitionFor(state.model)
            if definition then
                local distance = distanceBetween(playerCoords, state.coords)
                if distance <= definition.drawDistance then
                    local entity = GetClosestObjectOfType(state.coords.x, state.coords.y, state.coords.z, 3.0,
                        state.model, false, false, false)
                    if entity ~= 0 then
                        local current = byRenderTarget[definition.renderTarget]
                        if not current or distance < current.distance then
                            byRenderTarget[definition.renderTarget] = {
                                id = id, state = state, definition = definition, distance = distance, entity = entity,
                            }
                        end
                    end
                end
            end
        end

        local selected = {}
        for _, candidate in pairs(byRenderTarget) do selected[#selected + 1] = candidate end
        table.sort(selected, function(a, b) return a.distance < b.distance end)

        local desired = {}
        for index = 1, math.min(#selected, playback.maxConcurrentScreens) do
            local candidate = selected[index]
            local runtime = runtimes[candidate.id]
            -- A new DUI can take seconds to load: create it aside so the other screens keep updating.
            if not runtime and not creating[candidate.id] then
                creating[candidate.id] = true
                CreateThread(function()
                    createRuntime(candidate.state, candidate.definition)
                    creating[candidate.id] = nil
                end)
            end
            if runtime then
                desired[candidate.id] = true
                local volume = effectiveVolume(candidate.state, candidate.definition, candidate.distance, candidate.entity)
                if math.abs((runtime.lastVolume or -1) - volume) >= 2 or (volume == 0) ~= (runtime.lastVolume == 0) then
                    runtime.lastVolume = volume
                    sendRuntimeMessage(runtime, 'sync', volume)
                end
            end
        end

        activeRuntimeIds = desired
        for id in pairs(runtimes) do
            if not desired[id] then destroyRuntime(id) end
        end

        Wait(scanInterval)
    end
end)

-- Drawing to a render target has to happen every frame, but only while a screen is active.
CreateThread(function()
    while true do
        if next(activeRuntimeIds) then
            for id in pairs(activeRuntimeIds) do
                local runtime = runtimes[id]
                if runtime and runtime.renderId ~= 0 then
                    SetTextRenderId(runtime.renderId)
                    SetScriptGfxDrawOrder(4)
                    DrawSprite(runtime.txdName, runtime.textureName, 0.5, 0.5, 1.0, 1.0, 0.0, 255, 255, 255, 255)
                    SetTextRenderId(1)
                end
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

CreateThread(function()
    while true do
        Wait(driftCheckInterval)
        for id in pairs(activeRuntimeIds) do
            local runtime = runtimes[id]
            if runtime then sendRuntimeMessage(runtime, 'sync', runtime.lastVolume) end
        end
    end
end)

CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(500) end
    TriggerServerEvent('xex_tv:requestState')
    while true do
        Wait(stateRefreshInterval)
        TriggerServerEvent('xex_tv:requestState')
    end
end)

-- Events coming from the DUI players.
RegisterNUICallback('playerEvent', function(data, cb)
    cb({ ok = true })
    if type(data) ~= 'table' or not data.screenId then return end

    if data.event == 'error' or data.event == 'warning' then
        playerErrors[data.screenId] = { code = data.code, detail = data.detail or data.title }
        local line = ('screen %s: %s - %s'):format(data.screenId, tostring(data.code), tostring(data.detail or data.title))
        if data.event == 'error' then print(('[%s] %s'):format(resourceName, line)) else debugPrint(line) end

        -- A channel that can't play here: the server moves it on once it trusts the report.
        local state = TV.states[data.screenId]
        if data.event == 'error' and state and state.channel and state.mediaToken == data.mediaToken
            and not reportedErrors[data.mediaToken]
        then
            reportedErrors[data.mediaToken] = true
            TriggerServerEvent('xex_tv:mediaError', data.screenId, data.mediaToken, tostring(data.code))
        end
    elseif data.event == 'media' then
        local state = TV.states[data.screenId]
        if state and state.mediaToken == data.mediaToken and not reportedTokens[data.mediaToken] then
            reportedTokens[data.mediaToken] = true
            TriggerServerEvent('xex_tv:mediaInfo', data.screenId, data.mediaToken, {
                duration = tonumber(data.duration),
                title = type(data.title) == 'string' and data.title:sub(1, 400) or nil,
                live = data.live == true,
            })
        end
    elseif data.event then
        debugPrint(('screen %s: %s'):format(data.screenId, data.event))
    end
end)

-- NEAREST SCREEN ---------------------------------------------------------------------------------

CreateThread(function()
    local controlDistance = Config.Interaction.controlDistance
    while true do
        local playerCoords = GetEntityCoords(cache.ped)
        local closest

        for _, definition in ipairs(Config.Models) do
            local entity = GetClosestObjectOfType(playerCoords.x, playerCoords.y, playerCoords.z, controlDistance,
                definition.hash, false, false, false)
            if entity ~= 0 then
                local coords = GetEntityCoords(entity)
                local distance = #(playerCoords - coords)
                if distance <= controlDistance and (not closest or distance < closest.distance) then
                    closest = { entity = entity, model = GetEntityModel(entity), coords = coords, definition = definition, distance = distance }
                end
            end
        end

        nearestTv = closest
        Wait(scanInterval)
    end
end)

-- FIXED SCREENS (spawned props) --------------------------------------------------------------------

for index, location in ipairs(Config.Locations) do
    if location.spawn then
        local model = location.hash or joaat(location.model)
        lib.points.new({
            coords = location.coords,
            distance = math.max(50.0, (TV.definitionFor(model) or {}).drawDistance or 0) + 20.0,
            onEnter = function()
                if spawnedProps[index] then return end
                lib.requestModel(model)
                -- Local object at the exact config position, so every player resolves the same screen.
                local object = CreateObjectNoOffset(model, location.coords.x, location.coords.y, location.coords.z, false, false, false)
                SetEntityHeading(object, location.heading or 0.0)
                FreezeEntityPosition(object, true)
                SetModelAsNoLongerNeeded(model)
                spawnedProps[index] = object
            end,
            onExit = function()
                local object = spawnedProps[index]
                if object and DoesEntityExist(object) then DeleteObject(object) end
                spawnedProps[index] = nil
            end,
        })
    end
end

-- INTERACTION ------------------------------------------------------------------------------------

local interaction = Config.Interaction

if interaction.command then
    RegisterCommand(interaction.command, function() TV.openRemote(nearestTv) end, false)
end

local keybind
if interaction.key then
    keybind = lib.addKeybind({
        name = 'xex_tv_remote',
        description = locale('keybind'),
        defaultKey = interaction.key,
        onReleased = function()
            if nearestTv and nearestTv.distance <= helpDistance and not IsNuiFocused() then
                TV.openRemote(nearestTv)
            end
        end,
    })
end

local targetSystem
CreateThread(function()
    if not interaction.target then return end
    if GetResourceState('ox_target') == 'started' then
        targetSystem = 'ox'
        exports.ox_target:addModel(modelHashes, {
            {
                name = 'xex_tv_remote',
                icon = 'fa-solid fa-tv',
                label = locale('target'),
                distance = interaction.controlDistance,
                onSelect = function(data) TV.openRemote(TV.fromEntity(data.entity)) end,
            },
        })
    elseif GetResourceState('qb-target') == 'started' then
        targetSystem = 'qb'
        exports['qb-target']:AddTargetModel(modelHashes, {
            options = {
                { icon = 'fas fa-tv', label = locale('target'), action = function(entity) TV.openRemote(TV.fromEntity(entity)) end },
            },
            distance = interaction.controlDistance,
        })
    end
end)

if interaction.help then
    CreateThread(function()
        local helpEntity
        if targetSystem or not (keybind or interaction.command) then return end
        while true do
            if nearestTv and nearestTv.distance <= helpDistance then
                if helpEntity ~= nearestTv.entity then
                    helpEntity = nearestTv.entity
                    -- The key players actually use, after any rebind in the game settings.
                    local text = keybind and locale('help_key', keybind:getCurrentKey())
                        or locale('help_command', interaction.command)
                    BeginTextCommandDisplayHelp('STRING')
                    AddTextComponentSubstringPlayerName(text)
                    EndTextCommandDisplayHelp(0, false, false, 5000)
                end
            elseif helpEntity then
                helpEntity = nil
            end
            Wait(500)
        end
    end)
end

if interaction.debugCommand then
    RegisterCommand(interaction.debugCommand, function()
        local tv = nearestTv
        if not tv then return TV.notify('no_tv', 'error') end

        local state = TV.findState(tv)
        local err = state and playerErrors[state.id]
        local lines = {
            ('Model: %s (%s)'):format(tv.definition.label, tv.model),
            ('Render target: %s'):format(tv.definition.renderTarget),
            ('Coords: %.2f, %.2f, %.2f'):format(tv.coords.x, tv.coords.y, tv.coords.z),
            ('Bucket: %s'):format(currentBucket),
            ('Media: %s'):format(state and state.media and (state.media.kind .. ' · ' .. (state.media.label or '')) or 'off'),
            ('Rendering: %s'):format(state and runtimes[state.id] and 'yes' or 'no'),
            ('Last player error: %s'):format(err and (tostring(err.code) .. ' · ' .. tostring(err.detail)) or 'none'),
        }
        local text = table.concat(lines, '\n')
        print(('[%s]\n%s'):format(resourceName, text))
        lib.alertDialog({ header = Config.UI.brand .. ' ' .. Config.UI.title, content = text, centered = true })
    end, false)
end

AddEventHandler('onResourceStop', function(name)
    if name ~= resourceName then return end
    for id in pairs(runtimes) do destroyRuntime(id) end
    for renderTarget in pairs(registeredRenderTargets) do
        if IsNamedRendertargetRegistered(renderTarget) then ReleaseNamedRendertarget(renderTarget) end
    end
    for _, object in pairs(spawnedProps) do
        if DoesEntityExist(object) then DeleteObject(object) end
    end
    if targetSystem == 'ox' then
        exports.ox_target:removeModel(modelHashes, 'xex_tv_remote')
    elseif targetSystem == 'qb' then
        exports['qb-target']:RemoveTargetModel(modelHashes, locale('target'))
    end
end)
