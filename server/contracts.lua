AT_Broker.Contracts = {}

-- ──────────────────────────────────────────────────────────────────────────────
-- Public: generate and persist a contract for a player with a given broker.
-- cb(contract_table, nil) on success, cb(nil, reason_string) on failure.
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Contracts.Generate(identifier, broker_id, profile, cb)
    local broker = AT_Broker.Contracts.GetBrokerById(broker_id)
    if not broker then return cb(nil, 'unknown_broker') end

    if profile.broker_level < broker.level then
        return cb(nil, 'insufficient_level')
    end

    local now = AT_Broker.Utils.GetCurrentTimestamp()

    if profile.blacklisted_until and profile.blacklisted_until > now then
        return cb(nil, 'blacklisted')
    end

    if profile.last_contract and (now - profile.last_contract) < Config.ContractCooldown then
        return cb(nil, 'cooldown')
    end

    -- One active contract per player at a time
    MySQL.query(
        'SELECT id FROM broker_contracts WHERE player_identifier = ? AND status = ?',
        { identifier, 'active' },
        function(rows)
            if rows and #rows > 0 then return cb(nil, 'already_active') end

            local history      = AT_Broker.Utils.SafeJSON(profile.contract_history) or {}
            local contractType = AT_Broker.Contracts.SelectType(broker, profile, history)
            if not contractType then return cb(nil, 'no_types_available') end

            local payload = AT_Broker.Contracts.BuildPayload(contractType, profile)
            if not payload then return cb(nil, 'payload_build_failed') end

            local typeCfg    = Config.ContractTypes[contractType]
            local baseReward = math.random(typeCfg.base_reward.min, typeCfg.base_reward.max)
            local reward     = math.floor(baseReward * (Config.LevelRewardMultiplier[profile.broker_level] or 1.0))
            local expiresAt  = now + typeCfg.duration

            MySQL.insert(
                [[INSERT INTO broker_contracts
                  (broker_id, player_identifier, type, status, payload, created_at, expires_at, reward)
                  VALUES (?, ?, ?, 'active', ?, ?, ?, ?)]],
                { broker_id, identifier, contractType, json.encode(payload), now, expiresAt, reward },
                function(contractId)
                    if not contractId then return cb(nil, 'db_insert_failed') end

                    MySQL.update(
                        'UPDATE broker_players SET last_contract = ? WHERE identifier = ?',
                        { now, identifier }
                    )

                    AT_Broker.Contracts.ScheduleBetrayal(broker, profile, contractId, identifier)

                    local contract = {
                        id          = contractId,
                        broker_id   = broker_id,
                        broker_name = broker.name,
                        type        = contractType,
                        label       = typeCfg.label,
                        payload     = payload,
                        expires_at  = expiresAt,
                        reward      = reward,
                    }

                    AT_Broker.Utils.Log('INFO', ('Contract #%d [%s] assigned to %s via %s'):format(
                        contractId, contractType, identifier, broker_id))
                    cb(contract, nil)
                end
            )
        end
    )
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Weighted contract-type selection.
-- Down-weights types used in the last Config.TypeRepeatCooldown contracts.
-- Respects broker specialisation (earlier in mission_types[] = slight bonus).
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Contracts.SelectType(broker, profile, history)
    local available = {}

    for idx, ctype in ipairs(broker.mission_types) do
        local typeCfg = Config.ContractTypes[ctype]
        if typeCfg and profile.broker_level >= typeCfg.required_level then
            local weight = 100

            -- Penalise recent repetition
            local checkFrom = math.max(1, #history - Config.TypeRepeatCooldown + 1)
            for i = checkFrom, #history do
                if history[i].type == ctype then weight = weight - 40 end
            end

            -- Slight bonus for a broker's primary specialisation (first in list)
            weight = weight + math.max(0, 10 - (idx - 1) * 3)

            if weight > 0 then
                available[#available + 1] = { value = ctype, weight = weight }
            end
        end
    end

    if #available == 0 then return nil end
    return AT_Broker.Utils.WeightedRandom(available)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Build the JSON payload for each contract type.
-- All randomness is resolved server-side; the client only receives coordinates.
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Contracts.BuildPayload(contractType, profile)
    if contractType == 'vehicle_theft' then
        local vehicles = Config.ContractTypes.vehicle_theft.vehicles
        local vehicle  = AT_Broker.Utils.RandomFromTable(vehicles)
        local spawnLoc = AT_Broker.Utils.RandomFromTable(Config.MissionLocations.vehicle_theft)
        local dropLoc  = AT_Broker.Utils.RandomFromTable(Config.MissionLocations.vehicle_dropoff)
        if not vehicle or not spawnLoc or not dropLoc then return nil end
        return {
            vehicle_model  = vehicle.model,
            reward_bonus   = vehicle.reward_bonus,
            spawn_location = spawnLoc,
            deliver_to     = dropLoc,
        }

    elseif contractType == 'delivery' then
        local itemWeights = {}
        for _, it in ipairs(Config.ContractTypes.delivery.items) do
            itemWeights[#itemWeights + 1] = { value = it, weight = it.weight }
        end
        local item    = AT_Broker.Utils.WeightedRandom(itemWeights)
        local pickup  = AT_Broker.Utils.RandomFromTable(Config.MissionLocations.delivery.pickup)
        local dropoff = AT_Broker.Utils.RandomFromTable(Config.MissionLocations.delivery.dropoff)
        if not item or not pickup or not dropoff then return nil end
        return {
            item_name        = item.name,
            item_label       = item.label,
            pickup           = pickup,
            dropoff          = dropoff,
            wanted_threshold = Config.ContractTypes.delivery.wanted_threshold,
        }

    elseif contractType == 'sabotage' then
        local loc      = AT_Broker.Utils.RandomFromTable(Config.MissionLocations.sabotage)
        local duration = AT_Broker.Utils.RandomFromTable(Config.ContractTypes.sabotage.hold_durations)
        if not loc or not duration then return nil end
        return {
            location      = loc,
            hold_duration = duration,
            radius        = 5.0,
        }

    elseif contractType == 'retrieval' then
        local itemWeights = {}
        for _, it in ipairs(Config.ContractTypes.retrieval.items) do
            itemWeights[#itemWeights + 1] = { value = it, weight = it.weight }
        end
        local item = AT_Broker.Utils.WeightedRandom(itemWeights)
        local loc  = AT_Broker.Utils.RandomFromTable(Config.MissionLocations.retrieval)
        if not item or not loc then return nil end
        return {
            item_name  = item.name,
            item_label = item.label,
            location   = loc,
            radius     = 8.0,
        }
    end

    return nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Betrayal — schedule a delayed betrayal event for eligible brokers.
-- Chance = broker.betrayal_base_chance + (danger_level × 2), rolled once.
-- Fires between 30 s and 3 min after contract assignment.
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Contracts.ScheduleBetrayal(broker, profile, contractId, identifier)
    if not broker.can_betray then return end

    local chance = broker.betrayal_base_chance + (profile.danger_level * 2)
    if math.random(1, 100) > chance then return end

    local delay = math.random(30000, 180000)
    SetTimeout(delay, function()
        -- Contract must still be active for the betrayal to fire
        MySQL.query(
            'SELECT status, payload FROM broker_contracts WHERE id = ?',
            { contractId },
            function(rows)
                if not rows or #rows == 0 then return end
                if rows[1].status ~= 'active' then return end

                AT_Broker.Utils.Log('WARN', ('Betrayal triggered: contract #%d, player %s'):format(
                    contractId, identifier))

                local src = AT_Broker.Contracts.GetSourceByIdentifier(identifier)
                if src then
                    TriggerClientEvent('at-broker:betrayalTriggered', src, {
                        contract_id = contractId,
                        broker_id   = broker.id,
                        broker_name = broker.name,
                    })
                end

                -- Flag betrayal in the stored payload so monitor/reputation can account for it
                local payload = AT_Broker.Utils.SafeJSON(rows[1].payload) or {}
                payload.betrayed = true
                MySQL.update(
                    'UPDATE broker_contracts SET payload = ? WHERE id = ?',
                    { json.encode(payload), contractId }
                )
            end
        )
    end)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Complete a contract.  Called from main.lua after basic source validation.
-- cb(true, final_reward) or cb(false, reason_string)
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Contracts.Complete(source, contractId, completionData, cb)
    local identifier = AT_Broker.GetPlayerIdentifier(source)
    if not identifier then return cb(false, 'no_identifier') end

    MySQL.query(
        'SELECT * FROM broker_contracts WHERE id = ? AND player_identifier = ? AND status = ?',
        { contractId, identifier, 'active' },
        function(rows)
            if not rows or #rows == 0 then return cb(false, 'contract_not_found') end

            local contract = rows[1]
            local now      = AT_Broker.Utils.GetCurrentTimestamp()

            if now > contract.expires_at then
                AT_Broker.Contracts.Fail(contractId, identifier, 'expired')
                return cb(false, 'expired')
            end

            AT_Broker.Reputation.GetOrCreateProfile(identifier, function(profile)
                if not profile then return cb(false, 'no_profile') end

                local finalReward = AT_Broker.Reputation.CalcRewardBonus(profile.discretion, contract.reward)

                -- Append to contract history
                local history = AT_Broker.Utils.SafeJSON(profile.contract_history) or {}
                history[#history + 1] = {
                    type         = contract.type,
                    status       = 'completed',
                    completed_at = now,
                    reward       = finalReward,
                }
                AT_Broker.Utils.TrimHistory(history, 20)

                MySQL.update(
                    'UPDATE broker_contracts SET status = ? WHERE id = ?',
                    { 'completed', contractId },
                    function()
                        MySQL.update(
                            'UPDATE broker_players SET contract_history = ? WHERE identifier = ?',
                            { json.encode(history), identifier },
                            function()
                                local maxWanted = completionData and completionData.max_wanted or 0
                                AT_Broker.Reputation.OnContractComplete(identifier, contract, maxWanted)
                                cb(true, finalReward)
                            end
                        )
                    end
                )
            end)
        end
    )
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Fail a contract (expiry, abandonment, wanted threshold breach, etc.).
-- Safe to call with a contractId that may already be non-active.
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Contracts.Fail(contractId, identifier, reason)
    MySQL.update(
        'UPDATE broker_contracts SET status = ? WHERE id = ? AND status = ?',
        { 'failed', contractId, 'active' },
        function(affected)
            if not affected or affected == 0 then return end  -- already resolved

            MySQL.query(
                'SELECT * FROM broker_contracts WHERE id = ?',
                { contractId },
                function(rows)
                    if not rows or #rows == 0 then return end
                    local contract = rows[1]

                    AT_Broker.Reputation.GetOrCreateProfile(identifier, function(profile)
                        if not profile then return end

                        local now     = AT_Broker.Utils.GetCurrentTimestamp()
                        local history = AT_Broker.Utils.SafeJSON(profile.contract_history) or {}
                        history[#history + 1] = {
                            type         = contract.type,
                            status       = 'failed',
                            completed_at = now,
                            reason       = reason,
                        }
                        AT_Broker.Utils.TrimHistory(history, 20)
                        MySQL.update(
                            'UPDATE broker_players SET contract_history = ? WHERE identifier = ?',
                            { json.encode(history), identifier }
                        )

                        AT_Broker.Reputation.OnContractFail(identifier, contract, reason)
                    end)
                end
            )

            -- Notify online player if they are still connected
            local src = AT_Broker.Contracts.GetSourceByIdentifier(identifier)
            if src then
                TriggerClientEvent('at-broker:contractFailed', src, {
                    contract_id = contractId,
                    reason      = reason,
                })
            end

            AT_Broker.Utils.Log('INFO', ('Contract #%d failed for %s: %s'):format(
                contractId, identifier, reason))
        end
    )
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Contracts.GetBrokerById(broker_id)
    for _, broker in ipairs(Config.Brokers) do
        if broker.id == broker_id then return broker end
    end
    return nil
end

-- Walk all online players and return the server source that maps to identifier
function AT_Broker.Contracts.GetSourceByIdentifier(identifier)
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src and AT_Broker.GetPlayerIdentifier(src) == identifier then
            return src
        end
    end
    return nil
end
