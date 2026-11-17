-- Framework bridge (server). Only used by job-locked screens (Config.Locations[].locked.jobs).
-- Adapt it if your server uses a custom framework or job system.

Bridge = {}

local function detect()
    if Config.Framework ~= 'auto' then return Config.Framework end
    if GetResourceState('qbx_core') == 'started' then return 'qbox' end
    if GetResourceState('qb-core') == 'started' then return 'qb' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    return 'standalone'
end

Bridge.name = detect()

-- Returns the player's job name and grade, or nil.
if Bridge.name == 'esx' then
    local ESX = exports.es_extended:getSharedObject()

    function Bridge.GetJob(src)
        local xPlayer = ESX.GetPlayerFromId(src)
        local job = xPlayer and xPlayer.job
        if not job then return nil end
        return job.name, tonumber(job.grade) or 0
    end
elseif Bridge.name == 'qb' or Bridge.name == 'qbox' then
    local getPlayer
    if Bridge.name == 'qbox' then
        getPlayer = function(src) return exports.qbx_core:GetPlayer(src) end
    else
        local QBCore = exports['qb-core']:GetCoreObject()
        getPlayer = function(src) return QBCore.Functions.GetPlayer(src) end
    end

    function Bridge.GetJob(src)
        local player = getPlayer(src)
        local job = player and player.PlayerData.job
        if not job then return nil end
        local grade = type(job.grade) == 'table' and job.grade.level or job.grade
        return job.name, tonumber(grade) or 0
    end
else
    function Bridge.GetJob()
        return nil
    end
end
