AT_Broker = AT_Broker or {}

AT_Broker.Utils = {}

-- Route log messages through at-core if available, otherwise fall back to
-- print only when Config.Debug is true or the level is ERROR.
function AT_Broker.Utils.Log(level, msg)
    if GetResourceState('at-core') == 'started' then
        pcall(function()
            exports['at-core']:logInfo('at-broker', ('[%s] %s'):format(level, msg))
        end)
        return
    end
    if Config.Debug or level == 'ERROR' or level == 'WARN' then
        print(('[at-broker][%s] %s'):format(level, msg))
    end
end

function AT_Broker.Utils.TableContains(tbl, value)
    for _, v in ipairs(tbl) do
        if v == value then return true end
    end
    return false
end

function AT_Broker.Utils.RandomFromTable(tbl)
    if not tbl or #tbl == 0 then return nil end
    return tbl[math.random(1, #tbl)]
end

function AT_Broker.Utils.GetCurrentTimestamp()
    return os.time()
end

-- Weighted random selection.
-- weights: array of { value = any, weight = number }
function AT_Broker.Utils.WeightedRandom(weights)
    if not weights or #weights == 0 then return nil end
    local total = 0
    for _, w in ipairs(weights) do total = total + w.weight end
    if total <= 0 then return weights[math.random(1, #weights)].value end
    local roll, cumulative = math.random(1, total), 0
    for _, w in ipairs(weights) do
        cumulative = cumulative + w.weight
        if roll <= cumulative then return w.value end
    end
    return weights[#weights].value
end

function AT_Broker.Utils.Clamp(val, min_val, max_val)
    return math.max(min_val, math.min(max_val, val))
end

-- Safe JSON decode — returns nil on failure instead of erroring
function AT_Broker.Utils.SafeJSON(str)
    if type(str) ~= 'string' or str == '' then return nil end
    local ok, result = pcall(json.decode, str)
    return ok and result or nil
end

-- Trim a history table to at most `limit` most-recent entries in place
function AT_Broker.Utils.TrimHistory(history, limit)
    while #history > limit do table.remove(history, 1) end
    return history
end
