-- Run from the repository root:
--   .\target\release\moon.exe example/shared_service/main.lua
if _G["__init__"] then
    return { thread = 2, enable_stdout = true, loglevel = "DEBUG" }
end

local moon = require("moon")
-- Moon changes the working directory to this startup script's directory.
local player_file = "Player.lua"
local inventory_file = "Player_Inventory.lua"

local function create_player(name)
    local id = moon.new_service({
        name = "player_" .. name,
        file = "service_entry.lua",
        module = player_file,
        -- Named keys also work with Moon binaries built before array-key support.
        parts = { Player_Inventory = inventory_file },
        player_name = name,
    })
    assert(id ~= 0, "failed to create player service: " .. name)
    return id
end

moon.async(function()
    local ok, err = xpcall(function()
        local alice = create_player("Alice")
        local bob = create_player("Bob")

        local name_ok, name = moon.call("lua", alice, "Player.get_name")
        assert(name_ok and name == "Alice")

        local added, count = moon.call("lua", alice, "Player_Inventory.add_item", "potion", 2)
        assert(added and count == 2)

        local updated, update_err = moon.call("lua", alice, "__hotfix",
            inventory_file, "Player_Inventory_v2.lua")
        assert(updated, update_err)

        local added_again, new_count = moon.call("lua", alice, "Player_Inventory.add_item", "potion", 3)
        assert(added_again and new_count == 8) -- Same service state, updated method.

        local bob_added, bob_count = moon.call("lua", bob, "Player_Inventory.add_item", "potion", 3)
        assert(bob_added and bob_count == 3) -- Other service is unchanged.

        local read_ok, final_count = moon.call("lua", alice, "Player_Inventory.get_item_count", "potion")
        assert(read_ok and final_count == 8)

        print("shared service and Player inventory hotfix: OK")
        moon.kill(alice)
        moon.kill(bob)
    end, debug.traceback)

    if not ok then
        moon.error(err)
        moon.exit(-1)
    else
        moon.exit(0)
    end
end)
