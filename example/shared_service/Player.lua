local Player = {}

function Player.get_name(context)
    return context.config.player_name
end

return Player
