-- Standalone blip file — no dependencies, runs independently of main.lua
CreateThread(function()
    for _, broker in ipairs(Config.Brokers) do
        local loc  = broker.location
        local blip = AddBlipForCoord(loc.x, loc.y, loc.z)
        SetBlipSprite(blip, 280)
        SetBlipColour(blip, 44)
        SetBlipScale(blip, 0.85)
        SetBlipAsShortRange(blip, false)  -- sempre visibile sulla mappa grande
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString('[Broker] ' .. broker.name)
        EndTextCommandSetBlipName(blip)
    end
end)
