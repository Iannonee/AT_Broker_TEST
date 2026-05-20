AT_Broker.Monitor = {}

-- Per-contract high-water wanted level, keyed by contract id.
-- Populated by statusReport events, consumed by contracts.Complete.
local wantedHighWater = {}

-- ──────────────────────────────────────────────────────────────────────────────
-- Main tick — called every Config.MonitorInterval ms
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Monitor.Tick()
    local now = AT_Broker.Utils.GetCurrentTimestamp()

    MySQL.query('SELECT * FROM broker_contracts WHERE status = ?', { 'active' }, function(rows)
        if not rows or #rows == 0 then return end

        for _, contract in ipairs(rows) do
            if now >= contract.expires_at then
                AT_Broker.Utils.Log('INFO', ('Contract #%d expired for %s'):format(
                    contract.id, contract.player_identifier))
                AT_Broker.Contracts.Fail(contract.id, contract.player_identifier, 'expired')
            else
                -- Request a live status report from the client if they're online
                local src = AT_Broker.Contracts.GetSourceByIdentifier(contract.player_identifier)
                if src then
                    TriggerClientEvent('at-broker:requestStatus', src, contract.id)
                end
            end
        end
    end)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Receive wanted-level report from the client during an active contract.
-- The client responds to at-broker:requestStatus with this event.
-- ──────────────────────────────────────────────────────────────────────────────
RegisterNetEvent('at-broker:statusReport', function(contractId, report)
    local src = source
    if type(contractId) ~= 'number' then return end
    if type(report) ~= 'table' then return end

    local identifier = AT_Broker.GetPlayerIdentifier(src)
    if not identifier then return end

    MySQL.query(
        'SELECT * FROM broker_contracts WHERE id = ? AND player_identifier = ? AND status = ?',
        { contractId, identifier, 'active' },
        function(rows)
            if not rows or #rows == 0 then return end

            local contract    = rows[1]
            local wantedLevel = AT_Broker.Utils.Clamp(tonumber(report.wanted_level) or 0, 0, 5)

            -- Track peak wanted level for this contract run
            if not wantedHighWater[contractId] or wantedLevel > wantedHighWater[contractId] then
                wantedHighWater[contractId] = wantedLevel
            end

            if wantedLevel > 0 then
                AT_Broker.Utils.Log('WARN', ('Contract #%d: %s wanted level %d'):format(
                    contractId, identifier, wantedLevel))

                -- Delivery contracts fail instantly if wanted threshold is breached
                if contract.type == 'delivery' then
                    local payload   = AT_Broker.Utils.SafeJSON(contract.payload) or {}
                    local threshold = payload.wanted_threshold or 0
                    if wantedLevel > threshold then
                        AT_Broker.Contracts.Fail(contractId, identifier, 'wanted_level_exceeded')
                        return
                    end
                end

                -- Send escalation hint to client for all other types
                TriggerClientEvent('at-broker:missionEscalation', src, {
                    contract_id  = contractId,
                    wanted_level = wantedLevel,
                    message      = "Heat is rising — you've been spotted.",
                })
            end
        end
    )
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- Public accessors used by contracts.lua
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Monitor.GetMaxWanted(contractId)
    return wantedHighWater[contractId] or 0
end

function AT_Broker.Monitor.CleanupEntry(contractId)
    wantedHighWater[contractId] = nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Start the monitor loop — called from main.lua after tables are confirmed ready
-- ──────────────────────────────────────────────────────────────────────────────
function AT_Broker.Monitor.Start()
    CreateThread(function()
        while true do
            Wait(Config.MonitorInterval)
            AT_Broker.Monitor.Tick()
        end
    end)
    AT_Broker.Utils.Log('INFO', ('Monitor loop started (interval %dms)'):format(Config.MonitorInterval))
end
