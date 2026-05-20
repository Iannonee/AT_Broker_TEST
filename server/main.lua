-- Framework detection — resolved once at resource start
local Framework     = nil
local FrameworkType = nil

CreateThread(function()
    if GetResourceState('es_extended') == 'started' then
        Framework     = exports['es_extended']:getSharedObject()
        FrameworkType = 'esx'
        AT_Broker.Utils.Log('INFO', 'Framework: ESX')
    elseif GetResourceState('qb-core') == 'started' then
        Framework     = exports['qb-core']:GetCoreObject()
        FrameworkType = 'qb'
        AT_Broker.Utils.Log('INFO', 'Framework: QBCore')
    elseif GetResourceState('ox_core') == 'started' then
        FrameworkType = 'ox'
        AT_Broker.Utils.Log('INFO', 'Framework: ox_core')
    else
        AT_Broker.Utils.Log('WARN', 'No supported framework detected — falling back to license identifier')
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Global helper: resolve a server source to a stable player identifier.
-- Available to all server scripts via the AT_Broker namespace.
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.GetPlayerIdentifier(source)
    local src = tonumber(source)
    if not src then return nil end

    if FrameworkType == 'esx' and Framework then
        local xPlayer = Framework.GetPlayerFromId(src)
        if xPlayer then return xPlayer.identifier end

    elseif FrameworkType == 'qb' and Framework then
        local player = Framework.Functions.GetPlayer(src)
        if player then return player.PlayerData.citizenid end

    elseif FrameworkType == 'ox' then
        local ok, id = pcall(function()
            return exports.ox_core:GetPlayer(src).stateId
        end)
        if ok and id then return id end
    end

    -- Universal fallback: first license: identifier
    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
        local id = GetPlayerIdentifier(src, i)
        if id and id:sub(1, 8) == 'license:' then return id end
    end

    return nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Framework-agnostic cash reward
-- ──────────────────────────────────────────────────────────────────────────────
local function GiveReward(source, amount)
    local src = tonumber(source)

    if FrameworkType == 'esx' and Framework then
        local xPlayer = Framework.GetPlayerFromId(src)
        if xPlayer then xPlayer.addMoney(amount) return end

    elseif FrameworkType == 'qb' and Framework then
        local player = Framework.Functions.GetPlayer(src)
        if player then player.Functions.AddMoney('cash', amount) return end

    elseif FrameworkType == 'ox' then
        local ok = pcall(function()
            exports.ox_core:GetPlayer(src).AddMoney('money', amount)
        end)
        if ok then return end
    end

    -- Last-resort: push to client for server-owner handling
    TriggerClientEvent('at-broker:giveReward', src, amount)
    AT_Broker.Utils.Log('WARN', ('No framework cash handler — reward %d sent to client #%d'):format(amount, src))
end

-- ──────────────────────────────────────────────────────────────────────────────
-- DB migration — run on every resource start, safe to re-run (IF NOT EXISTS)
-- ──────────────────────────────────────────────────────────────────────────────
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    MySQL.query([[
        CREATE TABLE IF NOT EXISTS `broker_players` (
            `identifier`        VARCHAR(60)  NOT NULL,
            `reputation`        INT          NOT NULL DEFAULT 0,
            `reliability`       INT          NOT NULL DEFAULT 50,
            `discretion`        INT          NOT NULL DEFAULT 50,
            `danger_level`      INT          NOT NULL DEFAULT 0,
            `broker_level`      INT          NOT NULL DEFAULT 1,
            `blacklisted_until` BIGINT                DEFAULT NULL,
            `last_contract`     BIGINT                DEFAULT NULL,
            `contract_history`  LONGTEXT              DEFAULT NULL,
            PRIMARY KEY (`identifier`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]], {}, function()
        AT_Broker.Utils.Log('INFO', 'Table broker_players ready')
    end)

    MySQL.query([[
        CREATE TABLE IF NOT EXISTS `broker_contracts` (
            `id`                 INT         NOT NULL AUTO_INCREMENT,
            `broker_id`          VARCHAR(60) NOT NULL,
            `player_identifier`  VARCHAR(60) NOT NULL,
            `type`               VARCHAR(60) NOT NULL,
            `status`             VARCHAR(30) NOT NULL DEFAULT 'active',
            `payload`            LONGTEXT    NOT NULL,
            `created_at`         BIGINT      NOT NULL,
            `expires_at`         BIGINT      NOT NULL,
            `reward`             INT         NOT NULL,
            PRIMARY KEY (`id`),
            INDEX `idx_player` (`player_identifier`),
            INDEX `idx_status` (`status`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]], {}, function()
        AT_Broker.Utils.Log('INFO', 'Table broker_contracts ready')
        -- Monitor starts only after tables are confirmed ready
        AT_Broker.Monitor.Start()
    end)

    AT_Broker.Utils.Log('INFO', 'at-broker resource started')
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Event: player requests a contract from a broker
-- ──────────────────────────────────────────────────────────────────────────────
RegisterNetEvent('at-broker:requestContract', function(broker_id)
    local src = source

    -- Input validation
    if type(broker_id) ~= 'string' or #broker_id == 0 or #broker_id > 60 then
        AT_Broker.Utils.Log('WARN', ('Invalid broker_id from source %d'):format(src))
        return
    end

    local identifier = AT_Broker.GetPlayerIdentifier(src)
    if not identifier then
        TriggerClientEvent('at-broker:notify', src, 'error', 'Unable to identify your player profile.')
        return
    end

    if not AT_Broker.Contracts.GetBrokerById(broker_id) then
        TriggerClientEvent('at-broker:notify', src, 'error', 'Unknown broker.')
        return
    end

    AT_Broker.Reputation.GetOrCreateProfile(identifier, function(profile)
        if not profile then
            TriggerClientEvent('at-broker:notify', src, 'error', 'Profile error — try again.')
            return
        end

        AT_Broker.Contracts.Generate(identifier, broker_id, profile, function(contract, err)
            if err then
                local messages = {
                    insufficient_level = "You don't have the reputation for this contact.",
                    blacklisted        = 'You are blacklisted. Come back later.',
                    cooldown           = 'Not yet. Wait before requesting another contract.',
                    already_active     = 'Finish your current contract first.',
                    unknown_broker     = 'That contact is unknown.',
                    no_types_available = 'No work available right now.',
                }
                TriggerClientEvent('at-broker:notify', src, 'error', messages[err] or 'Contract unavailable.')
                return
            end

            TriggerClientEvent('at-broker:contractAssigned', src, contract)
        end)
    end)
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Event: player signals contract completion
-- ──────────────────────────────────────────────────────────────────────────────
RegisterNetEvent('at-broker:completeContract', function(contractId, completionData)
    local src = source

    if type(contractId) ~= 'number' or contractId <= 0 then
        AT_Broker.Utils.Log('WARN', ('Invalid contractId from source %d'):format(src))
        return
    end

    -- Pull the server-tracked peak wanted level (client-reported value is advisory only)
    if type(completionData) ~= 'table' then completionData = {} end
    completionData.max_wanted = AT_Broker.Monitor.GetMaxWanted(contractId)

    AT_Broker.Contracts.Complete(src, contractId, completionData, function(success, result)
        if not success then
            TriggerClientEvent('at-broker:notify', src, 'error',
                ('Contract rejected: %s'):format(tostring(result)))
            return
        end

        local reward = result
        GiveReward(src, reward)
        AT_Broker.Monitor.CleanupEntry(contractId)

        TriggerClientEvent('at-broker:contractCompleted', src, {
            contract_id = contractId,
            reward      = reward,
        })

        AT_Broker.Utils.Log('INFO', ('Contract #%d completed — reward $%d to %s'):format(
            contractId, reward, AT_Broker.GetPlayerIdentifier(src) or 'unknown'))
    end)
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Event: player voluntarily abandons their active contract
-- ──────────────────────────────────────────────────────────────────────────────
RegisterNetEvent('at-broker:abandonContract', function(contractId)
    local src = source

    if type(contractId) ~= 'number' or contractId <= 0 then return end

    local identifier = AT_Broker.GetPlayerIdentifier(src)
    if not identifier then return end

    MySQL.query(
        'SELECT id FROM broker_contracts WHERE id = ? AND player_identifier = ? AND status = ?',
        { contractId, identifier, 'active' },
        function(rows)
            if not rows or #rows == 0 then return end
            AT_Broker.Contracts.Fail(contractId, identifier, 'abandoned')
            AT_Broker.Monitor.CleanupEntry(contractId)
        end
    )
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Exports: allow other resources to query broker data
-- ──────────────────────────────────────────────────────────────────────────────

-- Returns the full broker_players row for an identifier (awaitable)
exports('getPlayerProfile', function(identifier)
    if type(identifier) ~= 'string' or #identifier == 0 then return nil end
    local p = promise.new()
    AT_Broker.Reputation.GetOrCreateProfile(identifier, function(profile)
        p:resolve(profile)
    end)
    return Citizen.Await(p)
end)

-- Returns the numeric broker_level (1–3) for an identifier (awaitable)
exports('getBrokerLevel', function(identifier)
    if type(identifier) ~= 'string' or #identifier == 0 then return 1 end
    local p = promise.new()
    AT_Broker.Reputation.GetOrCreateProfile(identifier, function(profile)
        p:resolve(profile and profile.broker_level or 1)
    end)
    return Citizen.Await(p)
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Admin commands (server console or in-game with ace permission)
-- ──────────────────────────────────────────────────────────────────────────────

-- broker_setrep <playerid> <0-100>
-- Example (server console): broker_setrep 1 100
RegisterCommand('broker_setrep', function(source, args)
    -- source == 0 means server console; otherwise check ace permission
    if source ~= 0 then
        if not IsPlayerAceAllowed(source, 'command.broker_setrep') then
            TriggerClientEvent('at-broker:notify', source, 'error', 'No permission.')
            return
        end
    end

    local targetSrc = tonumber(args[1])
    local rep       = tonumber(args[2])

    if not targetSrc or not rep then
        print('[at-broker] Usage: broker_setrep <playerid> <0-100>')
        return
    end

    rep = AT_Broker.Utils.Clamp(math.floor(rep), 0, 100)
    local identifier = AT_Broker.GetPlayerIdentifier(targetSrc)
    if not identifier then
        print('[at-broker] Player ' .. targetSrc .. ' not found or not connected.')
        return
    end

    local level = AT_Broker.Reputation.CalcBrokerLevel(rep)

    AT_Broker.Reputation.GetOrCreateProfile(identifier, function()
        MySQL.update(
            'UPDATE broker_players SET reputation = ?, broker_level = ?, blacklisted_until = NULL WHERE identifier = ?',
            { rep, level, identifier },
            function()
                print(('[at-broker] Set %s → reputation %d, level %d'):format(identifier, rep, level))
                TriggerClientEvent('at-broker:notify', targetSrc, 'success',
                    ('Admin set your broker reputation to %d (level %d)'):format(rep, level))
            end
        )
    end)
end, true)

-- broker_reset <playerid>  — clear cooldown, blacklist, and active contract
RegisterCommand('broker_reset', function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'command.broker_setrep') then return end

    local targetSrc  = tonumber(args[1]) or source
    local identifier = AT_Broker.GetPlayerIdentifier(targetSrc)
    if not identifier then print('[at-broker] Player not found.') return end

    MySQL.update(
        'UPDATE broker_players SET last_contract = NULL, blacklisted_until = NULL WHERE identifier = ?',
        { identifier }
    )
    MySQL.update(
        "UPDATE broker_contracts SET status = 'cancelled' WHERE player_identifier = ? AND status = 'active'",
        { identifier }
    )
    print(('[at-broker] Reset cooldown + blacklist for %s'):format(identifier))
    TriggerClientEvent('at-broker:notify', targetSrc, 'success', 'Broker cooldown reset.')
end, true)

-- broker_profile <playerid>  — print current stats to console
RegisterCommand('broker_profile', function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'command.broker_setrep') then return end

    local targetSrc  = tonumber(args[1]) or source
    local identifier = AT_Broker.GetPlayerIdentifier(targetSrc)
    if not identifier then print('[at-broker] Player not found.') return end

    AT_Broker.Reputation.GetOrCreateProfile(identifier, function(profile)
        if not profile then print('[at-broker] No profile found.') return end
        print(('[at-broker] Profile %s → rep:%d lvl:%d rel:%d dis:%d danger:%d blacklisted:%s'):format(
            identifier,
            profile.reputation,
            profile.broker_level,
            profile.reliability,
            profile.discretion,
            profile.danger_level,
            tostring(profile.blacklisted_until)
        ))
    end)
end, true)

-- Returns the active contract for an identifier, or nil (awaitable)
exports('getActiveContract', function(identifier)
    if type(identifier) ~= 'string' or #identifier == 0 then return nil end
    local p = promise.new()
    MySQL.query(
        'SELECT * FROM broker_contracts WHERE player_identifier = ? AND status = ? LIMIT 1',
        { identifier, 'active' },
        function(rows)
            p:resolve(rows and rows[1] or nil)
        end
    )
    return Citizen.Await(p)
end)
