local Player_Inventory = {}

function Player_Inventory.add_item(context, item, amount)
    local items = context.state.inventory
    if not items then
        items = {}
        context.state.inventory = items
    end
    items[item] = (items[item] or 0) + amount
    return items[item]
end

function Player_Inventory.get_item_count(context, item)
    local items = context.state.inventory
    return items and items[item] or 0
end

return Player_Inventory
