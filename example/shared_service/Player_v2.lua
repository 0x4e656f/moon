-- Test replacement for Player.lua.
local Player = {}

function Player.get_name(context)
    return context.config.player_name .. " (updated)"
end

return Player
