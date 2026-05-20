-- Client-side entry point for at-broker.
-- Handles ped spawning, proximity/target interaction, mission tracking, and
-- all server-to-client event responses.

-- ──────────────────────────────────────────────────────────────────────────────
-- State
-- ──────────────────────────────────────────────────────────────────────────────
local activeContract           = nil
local missionActive            = false
local maxWantedDuringMission   = 0
local missionBlip              = nil
local currentObjective         = nil
local brokerPeds               = {}   -- broker.id → ped handle

-- ──────────────────────────────────────────────────────────────────────────────
-- Target system detection
-- ──────────────────────────────────────────────────────────────────────────────
local targetResource = nil

CreateThread(function()
    if GetResourceState('ox_target') == 'started' then
        targetResource = 'ox_target'
    elseif GetResourceState('qb-target') == 'started' then
        targetResource = 'qb-target'
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Notification helper — cascades through ox_lib → ESX → native GTA toast
-- ──────────────────────────────────────────────────────────────────────────────
local function Notify(notifType, message)
    local shown = false

    if not shown and GetResourceState('ox_lib') == 'started' then
        shown = pcall(function()
            exports.ox_lib:notify({ title = 'Broker', description = message, type = notifType })
        end)
    end

    if not shown and GetResourceState('es_extended') == 'started' then
        shown = pcall(function()
            exports['es_extended']:ShowNotification(message)
        end)
    end

    if not shown then
        SetNotificationTextEntry('STRING')
        AddTextComponentString('~b~Broker~s~: ' .. message)
        DrawNotification(false, true)
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Blip helpers
-- ──────────────────────────────────────────────────────────────────────────────
local function SetMissionBlip(coords, sprite, colour, label)
    if missionBlip then RemoveBlip(missionBlip) end
    missionBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(missionBlip, sprite  or 161)
    SetBlipColour(missionBlip, colour  or 1)
    SetBlipScale(missionBlip, 0.8)
    SetBlipAsShortRange(missionBlip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(label or 'Mission')
    EndTextCommandSetBlipName(missionBlip)
end

local function ClearMissionBlip()
    if missionBlip then RemoveBlip(missionBlip) end
    missionBlip = nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- HUD objective bar — drawn every frame when an objective is set
-- ──────────────────────────────────────────────────────────────────────────────
CreateThread(function()
    while true do
        Wait(0)
        if currentObjective then
            SetTextFont(4)
            SetTextProportional(true)
            SetTextScale(0.0, 0.42)
            SetTextColour(255, 255, 255, 215)
            SetTextEdge(4, 0, 0, 0, 255)
            SetTextOutline()
            SetTextEntry('STRING')
            AddTextComponentString('~y~CONTRACT:~s~ ' .. currentObjective)
            DrawText(0.5, 0.925)
        end
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Broker map blips — always visible so players can navigate to contacts
-- ──────────────────────────────────────────────────────────────────────────────
CreateThread(function()
    for _, broker in ipairs(Config.Brokers) do
        local loc  = broker.location
        local blip = AddBlipForCoord(loc.x, loc.y, loc.z)
        SetBlipSprite(blip, 280)   -- person icon
        SetBlipColour(blip, 44)    -- dark purple
        SetBlipScale(blip, 0.7)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(broker.name)
        EndTextCommandSetBlipName(blip)
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Ped spawning
-- ──────────────────────────────────────────────────────────────────────────────
CreateThread(function()
    for _, broker in ipairs(Config.Brokers) do
        local modelHash = GetHashKey(broker.ped_model)
        RequestModel(modelHash)

        local waited = 0
        while not HasModelLoaded(modelHash) and waited < 10000 do
            Wait(100)
            waited = waited + 100
        end

        if HasModelLoaded(modelHash) then
            local loc = broker.location

            -- Find the actual ground Z so the ped never spawns underground
            local foundGround, groundZ = GetGroundZFor_3dCoord(loc.x, loc.y, loc.z + 2.0, false)
            local spawnZ = foundGround and groundZ or loc.z

            local ped = CreatePed(4, modelHash, loc.x, loc.y, spawnZ, loc.heading, false, false)
            SetEntityInvincible(ped, true)
            SetBlockingOfNonTemporaryEvents(ped, true)
            FreezeEntityPosition(ped, true)
            SetPedCanRagdoll(ped, false)
            SetModelAsNoLongerNeeded(modelHash)

            brokerPeds[broker.id] = ped

            -- Register with target system if available
            if targetResource == 'ox_target' then
                local capturedId = broker.id
                exports.ox_target:addLocalEntity(ped, {
                    {
                        label    = 'Talk to ' .. broker.name,
                        icon     = 'fa-solid fa-handshake-angle',
                        onSelect = function()
                            TriggerServerEvent('at-broker:requestContract', capturedId)
                        end,
                    },
                })
            elseif targetResource == 'qb-target' then
                local capturedId = broker.id
                exports['qb-target']:AddTargetEntity(ped, {
                    options = {
                        {
                            label  = 'Talk to ' .. broker.name,
                            icon   = 'fas fa-handshake',
                            action = function()
                                TriggerServerEvent('at-broker:requestContract', capturedId)
                            end,
                        },
                    },
                    distance = 2.5,
                })
            end
        else
            AT_Broker.Utils.Log('WARN', 'Failed to load ped model: ' .. broker.ped_model)
        end
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Proximity interaction fallback (no target system)
-- Runs every frame near brokers, polls every 500 ms otherwise.
-- ──────────────────────────────────────────────────────────────────────────────
CreateThread(function()
    -- Wait until ped spawn thread has had a chance to run
    Wait(2000)

    while true do
        local playerPos  = GetEntityCoords(PlayerPedId())
        local nearBroker = nil

        for _, broker in ipairs(Config.Brokers) do
            local loc  = broker.location
            local dist = #(playerPos - vector3(loc.x, loc.y, loc.z))
            if dist < 3.5 then
                nearBroker = broker
                break
            end
        end

        if nearBroker and not targetResource then
            -- Per-frame loop while close: show help text and listen for keypress
            while true do
                Wait(0)
                SetTextComponentFormat('STRING')
                AddTextComponentString('[E] Talk to ' .. nearBroker.name)
                DisplayHelpTextFromStringLabel(0, 0, 1, -1)

                if IsControlJustReleased(0, 38) then  -- E
                    TriggerServerEvent('at-broker:requestContract', nearBroker.id)
                end

                -- Re-check distance each frame to break out when player walks away
                local pp = GetEntityCoords(PlayerPedId())
                local d  = #(pp - vector3(nearBroker.location.x, nearBroker.location.y, nearBroker.location.z))
                if d >= 3.5 then break end
            end
        else
            Wait(500)
        end
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Wanted-level tracking during active missions
-- ──────────────────────────────────────────────────────────────────────────────
local function StartWantedTracking()
    CreateThread(function()
        while missionActive do
            Wait(2000)
            local wl = GetPlayerWantedLevel(PlayerId())
            if wl > maxWantedDuringMission then
                maxWantedDuringMission = wl
            end
        end
    end)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Complete the active contract (triggers server-side validation and reward)
-- ──────────────────────────────────────────────────────────────────────────────
local function CompleteContract()
    if not missionActive or not activeContract then return end
    missionActive = false

    TriggerServerEvent('at-broker:completeContract', activeContract.id, {
        max_wanted = maxWantedDuringMission,
    })

    currentObjective       = nil
    maxWantedDuringMission = 0
    ClearMissionBlip()
    activeContract = nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Mission handlers — each type runs its own tracking thread
-- ──────────────────────────────────────────────────────────────────────────────
local MissionHandlers = {}

MissionHandlers['vehicle_theft'] = function(contract)
    local p = contract.payload
    currentObjective = 'Locate and steal the ' .. p.vehicle_model
    SetMissionBlip(p.spawn_location, 523, 5, 'Target Vehicle')

    CreateThread(function()
        local deliveryPhase = false

        while missionActive do
            Wait(1000)

            local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
            if vehicle ~= 0 and not deliveryPhase then
                if GetEntityModel(vehicle) == GetHashKey(p.vehicle_model) then
                    deliveryPhase    = true
                    currentObjective = 'Deliver the vehicle to the drop point'
                    SetMissionBlip(p.deliver_to, 67, 2, 'Delivery Point')
                end
            end

            if deliveryPhase then
                local pPos = GetEntityCoords(PlayerPedId())
                local dist = #(pPos - vector3(p.deliver_to.x, p.deliver_to.y, p.deliver_to.z))
                if dist < 12.0 and GetVehiclePedIsIn(PlayerPedId(), false) ~= 0 then
                    CompleteContract()
                    return
                end
            end
        end
    end)
end

MissionHandlers['delivery'] = function(contract)
    local p = contract.payload
    currentObjective = 'Pick up the ' .. p.item_label
    SetMissionBlip(p.pickup, 478, 3, 'Pickup')

    CreateThread(function()
        local pickedUp = false

        while missionActive do
            Wait(1000)
            local pPos = GetEntityCoords(PlayerPedId())

            if not pickedUp then
                local dist = #(pPos - vector3(p.pickup.x, p.pickup.y, p.pickup.z))
                if dist < 5.0 then
                    -- Attempt inventory integration; fall back to proximity pickup
                    local hasItem = false
                    pcall(function() hasItem = exports['at-inventory']:hasItem(p.item_name) end)
                    if not hasItem then
                        pcall(function() exports['at-inventory']:addItem(p.item_name, 1) end)
                        hasItem = true
                    end

                    if hasItem then
                        pickedUp         = true
                        currentObjective = 'Deliver ' .. p.item_label .. ' — stay clean'
                        SetMissionBlip(p.dropoff, 67, 2, 'Dropoff')
                    end
                end
            else
                local dist = #(pPos - vector3(p.dropoff.x, p.dropoff.y, p.dropoff.z))
                if dist < 5.0 then
                    pcall(function() exports['at-inventory']:removeItem(p.item_name, 1) end)
                    CompleteContract()
                    return
                end
            end
        end
    end)
end

MissionHandlers['sabotage'] = function(contract)
    local p = contract.payload
    currentObjective = 'Reach the target location'
    SetMissionBlip(p.location, 161, 1, 'Sabotage Target')

    CreateThread(function()
        local holdMs  = 0
        local holding = false

        while missionActive do
            Wait(500)
            local pPos = GetEntityCoords(PlayerPedId())
            local dist = #(pPos - vector3(p.location.x, p.location.y, p.location.z))

            if dist < p.radius then
                if not holding then holding = true end
                holdMs = holdMs + 500

                local remaining = math.ceil(math.max(0, p.hold_duration - holdMs / 1000))
                currentObjective = ('Hold position — %ds remaining'):format(remaining)

                if holdMs >= p.hold_duration * 1000 then
                    CompleteContract()
                    return
                end
            else
                if holding then
                    holding          = false
                    holdMs           = 0
                    currentObjective = 'Return to the target location'
                end
            end
        end
    end)
end

MissionHandlers['retrieval'] = function(contract)
    local p = contract.payload
    currentObjective = 'Find the ' .. p.item_label
    SetMissionBlip(p.location, 478, 5, 'Retrieval Point')

    CreateThread(function()
        local retrieved = false

        while missionActive do
            Wait(1000)
            local pPos = GetEntityCoords(PlayerPedId())

            if not retrieved then
                local dist = #(pPos - vector3(p.location.x, p.location.y, p.location.z))
                if dist < p.radius then
                    pcall(function() exports['at-inventory']:addItem(p.item_name, 1) end)
                    retrieved        = true
                    currentObjective = 'Item secured — return it to your contact'

                    -- Route player back to the nearest broker ped
                    local nearestBroker, nearestDist = nil, math.huge
                    for _, broker in ipairs(Config.Brokers) do
                        local d = #(pPos - vector3(broker.location.x, broker.location.y, broker.location.z))
                        if d < nearestDist then
                            nearestDist   = d
                            nearestBroker = broker
                        end
                    end
                    if nearestBroker then
                        SetMissionBlip(nearestBroker.location, 280, 2, 'Return to Contact')
                    end
                end
            else
                -- Check if player has returned to any broker
                for _, broker in ipairs(Config.Brokers) do
                    local d = #(pPos - vector3(broker.location.x, broker.location.y, broker.location.z))
                    if d < 5.0 then
                        pcall(function() exports['at-inventory']:removeItem(p.item_name, 1) end)
                        CompleteContract()
                        return
                    end
                end
            end
        end
    end)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Server → client event handlers
-- ──────────────────────────────────────────────────────────────────────────────

RegisterNetEvent('at-broker:contractAssigned', function(contract)
    if missionActive then
        Notify('warning', 'A new contract arrived but you already have one active.')
        return
    end

    activeContract         = contract
    missionActive          = true
    maxWantedDuringMission = 0

    Notify('info', ('Contract: %s  |  $%d  |  %d min'):format(
        contract.label, contract.reward, math.ceil((contract.duration or 600) / 60)))

    StartWantedTracking()

    local handler = MissionHandlers[contract.type]
    if handler then
        handler(contract)
    else
        Notify('error', 'Unknown contract type received — contact support.')
        missionActive = false
        activeContract = nil
    end
end)

RegisterNetEvent('at-broker:contractCompleted', function(data)
    Notify('success', ('Job done. Payment received: $%d'):format(data.reward))
end)

RegisterNetEvent('at-broker:contractFailed', function(data)
    missionActive  = false
    activeContract = nil
    currentObjective = nil
    ClearMissionBlip()
    Notify('error', 'Contract failed: ' .. (data.reason or 'unknown reason'))
end)

RegisterNetEvent('at-broker:betrayalTriggered', function(data)
    Notify('error', data.broker_name .. ' sold you out. Heat incoming.')
    -- Apply immediate wanted pressure
    SetPlayerWantedLevel(PlayerId(), 3, false)
    SetPlayerWantedLevelNow(PlayerId(), false)
end)

RegisterNetEvent('at-broker:missionEscalation', function(data)
    Notify('warning', data.message or "You've been spotted!")
end)

-- Monitor requests a status ping every 30 s to check wanted level
RegisterNetEvent('at-broker:requestStatus', function(contractId)
    local wl = GetPlayerWantedLevel(PlayerId())
    TriggerServerEvent('at-broker:statusReport', contractId, { wanted_level = wl })
end)

-- Forwarded notification from server (e.g. reject reasons)
RegisterNetEvent('at-broker:notify', function(notifType, message)
    Notify(notifType, message)
end)

-- Fallback reward notification when no framework is detected
RegisterNetEvent('at-broker:giveReward', function(amount)
    Notify('success', ('Reward: $%d — handle your own books.'):format(amount))
end)
