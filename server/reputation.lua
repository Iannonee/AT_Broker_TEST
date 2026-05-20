AT_Broker.Reputation = {}

-- ──────────────────────────────────────────────────────────────────────────────
-- Called after a contract is successfully completed.
-- wantedDuringMission is the highest wanted level recorded by the monitor.
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Reputation.OnContractComplete(identifier, contract, wantedDuringMission)
    local dangerIncrease = (Config.ContractTypes[contract.type] and Config.ContractTypes[contract.type].danger) or 0

    MySQL.query('SELECT * FROM broker_players WHERE identifier = ?', { identifier }, function(rows)
        if not rows or #rows == 0 then return end
        local p = rows[1]

        local newReliability = AT_Broker.Utils.Clamp(p.reliability + 10, 0, 100)
        local newDiscretion  = AT_Broker.Utils.Clamp(
            p.discretion + AT_Broker.Reputation.DiscretionDelta(wantedDuringMission), 0, 100)
        local newDanger      = AT_Broker.Utils.Clamp(p.danger_level + dangerIncrease, 0, 100)
        local newReputation  = AT_Broker.Reputation.CalcReputation(newReliability, newDiscretion, newDanger)
        local newLevel       = AT_Broker.Reputation.CalcBrokerLevel(newReputation)

        MySQL.update(
            [[UPDATE broker_players
              SET reliability = ?, discretion = ?, danger_level = ?, reputation = ?, broker_level = ?
              WHERE identifier = ?]],
            { newReliability, newDiscretion, newDanger, newReputation, newLevel, identifier }
        )

        AT_Broker.Utils.Log('INFO', ('Reputation updated [complete] %s: rep=%d lvl=%d rel=%d dis=%d'):format(
            identifier, newReputation, newLevel, newReliability, newDiscretion))
    end)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Called after a contract fails (expiry, abandonment, wanted breach, etc.)
-- Also handles soft-blacklisting after repeated failures within 1 hour.
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Reputation.OnContractFail(identifier, contract, reason)
    MySQL.query('SELECT * FROM broker_players WHERE identifier = ?', { identifier }, function(rows)
        if not rows or #rows == 0 then return end
        local p = rows[1]

        local newReliability = AT_Broker.Utils.Clamp(p.reliability - 20, 0, 100)
        local newReputation  = AT_Broker.Reputation.CalcReputation(newReliability, p.discretion, p.danger_level)
        local newLevel       = AT_Broker.Reputation.CalcBrokerLevel(newReputation)

        -- Count recent failures in the last hour to decide on blacklisting
        local now             = AT_Broker.Utils.GetCurrentTimestamp()
        local history         = AT_Broker.Utils.SafeJSON(p.contract_history) or {}
        local recentFails     = 0
        for _, entry in ipairs(history) do
            if entry.status == 'failed' and (now - (entry.completed_at or 0)) < 3600 then
                recentFails = recentFails + 1
            end
        end

        local blacklistedUntil = p.blacklisted_until
        if recentFails >= Config.FailThreshold then
            blacklistedUntil = now + Config.BlacklistDuration.soft
            AT_Broker.Utils.Log('WARN', ('Soft-blacklisted %s until %d'):format(identifier, blacklistedUntil))
        end

        MySQL.update(
            [[UPDATE broker_players
              SET reliability = ?, reputation = ?, broker_level = ?, blacklisted_until = ?
              WHERE identifier = ?]],
            { newReliability, newReputation, newLevel, blacklistedUntil, identifier }
        )

        AT_Broker.Utils.Log('INFO', ('Reputation updated [fail:%s] %s: rep=%d lvl=%d rel=%d'):format(
            reason, identifier, newReputation, newLevel, newReliability))
    end)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Discretion delta: clean run rewards, heat penalises
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Reputation.DiscretionDelta(wantedLevel)
    if wantedLevel == 0 then return 5  end
    if wantedLevel == 1 then return 0  end
    if wantedLevel == 2 then return -5 end
    return -10 * (wantedLevel - 1)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Weighted average: reliability 50%, discretion 35%, danger penalty 15%
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Reputation.CalcReputation(reliability, discretion, danger)
    local score = reliability * 0.50 + discretion * 0.35 - danger * 0.15
    return AT_Broker.Utils.Clamp(math.floor(score), 0, 100)
end

function AT_Broker.Reputation.CalcBrokerLevel(reputation)
    for level = 3, 1, -1 do
        if reputation >= Config.ReputationGates[level].min then
            return level
        end
    end
    return 1
end

-- Apply the highest matching discretion multiplier to the base reward
function AT_Broker.Reputation.CalcRewardBonus(discretion, baseReward)
    for _, tier in ipairs(Config.DiscretionBonus) do
        if discretion >= tier.threshold then
            return math.floor(baseReward * tier.multiplier)
        end
    end
    return baseReward
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Load (or create) a player profile.
-- cb receives the profile row or nil.
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Reputation.GetOrCreateProfile(identifier, cb)
    MySQL.query(
        'SELECT * FROM broker_players WHERE identifier = ?',
        { identifier },
        function(rows)
            if rows and #rows > 0 then
                return cb(rows[1])
            end

            MySQL.insert(
                [[INSERT INTO broker_players
                  (identifier, reputation, reliability, discretion, danger_level, broker_level)
                  VALUES (?, 0, 50, 50, 0, 1)]],
                { identifier },
                function()
                    MySQL.query(
                        'SELECT * FROM broker_players WHERE identifier = ?',
                        { identifier },
                        function(r)
                            cb(r and r[1] or nil)
                        end
                    )
                end
            )
        end
    )
end
