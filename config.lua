Config = {}

-- Set true during development to enable fallback print logging
Config.Debug = false

-- Server monitor tick rate (ms)
Config.MonitorInterval = 30000

-- Seconds a player must wait between contract requests
Config.ContractCooldown = 300

-- Last N contract types are down-weighted to discourage repetition
Config.TypeRepeatCooldown = 2

-- Consecutive failures within 1 hour before soft-blacklisting a player
Config.FailThreshold = 3

Config.BlacklistDuration = {
    soft = 1800,   -- 30 min
    hard = 86400,  -- 24 hours
}

-- ──────────────────────────────────────────────────────────────────────────────
-- Reputation gates — define broker_level thresholds and display labels
-- ──────────────────────────────────────────────────────────────────────────────
Config.ReputationGates = {
    [1] = { min = 0,  max = 30,  label = 'Street Hustle'     },
    [2] = { min = 31, max = 70,  label = 'Criminal Network'  },
    [3] = { min = 71, max = 100, label = 'Elite Syndicate'   },
}

-- Payout multiplier per broker_level — rewards scale with trust
Config.LevelRewardMultiplier = {
    [1] = 1.0,
    [2] = 1.4,
    [3] = 2.0,
}

-- Discretion bonus applied to final reward based on how clean the run was
Config.DiscretionBonus = {
    { threshold = 80, multiplier = 1.30 },
    { threshold = 60, multiplier = 1.10 },
    { threshold = 40, multiplier = 1.00 },
    { threshold = 0,  multiplier = 0.80 },
}

-- ──────────────────────────────────────────────────────────────────────────────
-- Brokers — defined in config, never stored in DB
-- level 1 = street  |  level 2 = criminal  |  level 3 = elite
-- ──────────────────────────────────────────────────────────────────────────────
Config.Brokers = {
    {
        id                   = 'lil_dice',
        name                 = "Lil' Dice",
        level                = 1,
        mission_types        = { 'vehicle_theft', 'retrieval' },
        can_betray           = false,
        betrayal_base_chance = 0,
        ped_model            = 'g_m_y_lost_01',
        -- South LS, near Olympic Freeway parking lot
        location             = { x = 231.4, y = -1003.2, z = 29.4, heading = 180.0 },
    },
    {
        id                   = 'mona',
        name                 = 'Mona',
        level                = 2,
        mission_types        = { 'vehicle_theft', 'delivery', 'sabotage' },
        can_betray           = true,
        betrayal_base_chance = 5,
        ped_model            = 'g_f_y_ballas_01',
        -- Little Seoul alley
        location             = { x = -328.5, y = -1475.8, z = 30.1, heading = 90.0 },
    },
    {
        id                   = 'spectre',
        name                 = 'Spectre',
        level                = 3,
        mission_types        = { 'vehicle_theft', 'delivery', 'sabotage', 'retrieval' },
        can_betray           = true,
        betrayal_base_chance = 15,
        ped_model            = 's_m_m_fibsec_01',
        -- Pillbox Hill, near the financial tower
        location             = { x = 207.8, y = -929.4, z = 30.7, heading = 270.0 },
    },
}

-- ──────────────────────────────────────────────────────────────────────────────
-- Contract type definitions
-- ──────────────────────────────────────────────────────────────────────────────
Config.ContractTypes = {
    vehicle_theft = {
        label          = 'Vehicle Acquisition',
        base_reward    = { min = 2000, max = 5000 },
        duration       = 900,  -- seconds until expiry
        danger         = 1,    -- adds to player danger_level on complete
        required_level = 1,
        vehicles = {
            { model = 'adder',    reward_bonus = 3000 },
            { model = 'zentorno', reward_bonus = 2500 },
            { model = 'bati',     reward_bonus = 800  },
            { model = 'sultan',   reward_bonus = 600  },
            { model = 'kuruma',   reward_bonus = 1200 },
            { model = 'buffalo3', reward_bonus = 900  },
        },
    },

    delivery = {
        label            = 'Secure Delivery',
        base_reward      = { min = 1500, max = 4000 },
        duration         = 600,
        danger           = 0,
        required_level   = 2,
        -- Contract fails immediately if wanted level exceeds this value
        wanted_threshold = 0,
        items = {
            { name = 'contraband', label = 'Package',    weight = 40 },
            { name = 'drug_cache', label = 'Product',    weight = 30 },
            { name = 'intel_usb',  label = 'Data Drive', weight = 20 },
            { name = 'cash_bag',   label = 'Currency',   weight = 10 },
        },
    },

    sabotage = {
        label          = 'Sabotage Operation',
        base_reward    = { min = 3000, max = 7000 },
        duration       = 720,
        danger         = 2,
        required_level = 2,
        hold_durations = { 30, 45, 60 }, -- seconds player must hold position
    },

    retrieval = {
        label          = 'Asset Retrieval',
        base_reward    = { min = 2500, max = 6000 },
        duration       = 800,
        danger         = 1,
        required_level = 1,
        items = {
            { name = 'stolen_watch', label = 'Watch',      weight = 35 },
            { name = 'black_market', label = 'Parcel',     weight = 35 },
            { name = 'hard_drive',   label = 'Hard Drive', weight = 30 },
        },
    },
}

-- ──────────────────────────────────────────────────────────────────────────────
-- Mission locations — server picks randomly per contract
-- ──────────────────────────────────────────────────────────────────────────────
Config.MissionLocations = {
    vehicle_theft = {
        { x = 409.6,   y = -1022.5, z = 29.4 },
        { x = -706.8,  y = -915.3,  z = 19.2 },
        { x = 829.9,   y = -1077.9, z = 28.2 },
        { x = 182.6,   y = 6601.9,  z = 31.8 },
        { x = -1213.0, y = -336.8,  z = 37.8 },
    },
    vehicle_dropoff = {
        -- Chop shop / drop points
        { x = -353.7, y = -136.2,  z = 38.9  },
        { x = 734.8,  y = -1087.3, z = 22.2  },
        { x = -62.0,  y = -1100.0, z = 26.4  },
    },
    delivery = {
        pickup = {
            { x = 109.2,  y = -1952.1, z = 20.8 },
            { x = -326.4, y = -1487.3, z = 30.1 },
            { x = 1025.5, y = -1748.9, z = 29.8 },
        },
        dropoff = {
            { x = -1836.5, y = 3014.2, z = 32.8  },
            { x = 1690.2,  y = 4929.3, z = 42.1  },
            { x = -2173.8, y = 260.4,  z = 174.9 },
        },
    },
    sabotage = {
        { x = 2719.7,  y = 1548.7,  z = 24.4 },
        { x = -347.7,  y = -2774.4, z = 6.0  },
        { x = 1688.0,  y = 6419.8,  z = 35.7 },
        { x = -536.7,  y = -1282.9, z = 18.2 },
    },
    retrieval = {
        { x = 816.7,  y = -1024.9, z = 26.4 },
        { x = 488.2,  y = -1302.2, z = 29.3 },
        { x = -145.5, y = -1280.5, z = 30.3 },
        { x = 379.2,  y = -604.2,  z = 28.5 },
    },
}
