-- ------------------------------------------
-- The mod transforms unstructured player actions 
-- into a clean, machine-readable logistics stream. 
-- By storing the unit_number (ID) of machines or chests, 
-- the path of each item can be tracked precisely. 
-- The system is a data source for complex evaluations 
-- or logistics statistics. 
--
-- logistics event: (when, who, what, where, object)
--
-- {
--  tick = 12345,
--  actor = { type = "player-hand", id = 1, name = "PlayerName"},
--  action = "GIVE",
--  source_or_target = { type = "assembling-machine-2", id = 67890, slot_name = "modules"},
--  item = { name = "efficiency-module", quantity = 1, quality = "epic"}
-- }
--
-- Actions: TAKE, GIVE, MAKE
-- MAKE is used for crafting/production processes
--
-- Version 0.1.0 first operational Version
-- Version 0.1.1 Make intriduced
-- Version 0.2.0 Material in machines and chests is traced
--               taking material from the ground (F or left-click) corrected 
--
-- ------------------------------------------

local API_NAME = "logistics_events_api"

-- Generate event ID IMMEDIATELY when mod loads (not persistent!)
-- Event-ID SOFORT beim Mod-Load erzeugen (nicht persistent!)
local logistics_event_id = script.generate_event_name()

-- Global table to store the state
-- Globale Tabelle zum Speichern des Zustands
script.on_init(function()
    storage.player_data = {}
    storage.logistics_events = {}
    game.print("[Big Brother] Initialisiert - Event-ID: " .. tostring(logistics_event_id))
end)

script.on_configuration_changed(function()
    storage.player_data = storage.player_data or {}
    storage.logistics_events = storage.logistics_events or {}
    game.print("[Big Brother] Konfiguration geändert - Event-ID: " .. tostring(logistics_event_id))
end)

-- Remote API: other mods can query the event ID (and optionally use pull)
-- Remote-API: andere Mods können Event-ID abfragen (und optional Pull nutzen)
if not remote.interfaces[API_NAME] then
    remote.add_interface(API_NAME, {
        get_event_id = function()
            return logistics_event_id
        end,

        -- Optional: Pull API (if a mod wants to load events later)
        -- Optional: Pull-API (falls ein Mod Events später nachladen will)
        get_events = function(from_index)
            if not (storage and storage.logistics_events) then return {} end
            local start = (type(from_index) == "number" and from_index >= 1) and from_index or 1

            local out = {}
            for i = start, #storage.logistics_events do
                out[#out + 1] = storage.logistics_events[i]
            end
            return out
        end,

        -- Optional: Clear buffer
        -- Optional: Buffer leeren
        clear_events = function()
            if storage then storage.logistics_events = {} end
        end,

        get_api_version = function()
            return 1
        end
    })
end

-- Helper function: Create a logistics event
-- Hilfsfunktion: Erstelle ein Logistik-Event
-- action: "TAKE", "GIVE", or "MAKE"
-- action: "TAKE", "GIVE" oder "MAKE"
-- actor: Table with {type, id, name}
-- actor: Table mit {type, id, name}
-- source_or_target: Table with {type, id, slot_name}
-- source_or_target: Table mit {type, id, slot_name}
-- item: Table with {name, quantity, quality}
-- item: Table mit {name, quantity, quality}
local function create_logistics_event(action, actor, source_or_target, item)
    local event = {
        tick = game.tick,
        actor = actor,                      -- {type = "player-hand", id = 1, name = "PlayerName"}
        action = action,                    -- "TAKE", "GIVE", or "MAKE" / "TAKE", "GIVE" oder "MAKE"
        source_or_target = source_or_target, -- {type = "assembling-machine-2", id = 12345, slot_name = "modules"}
        item = item                         -- {name = "efficiency-module", quantity = 1, quality = "normal"}
    }

    table.insert(storage.logistics_events, event)

    -- Notify other mods (Push)
    -- Andere Mods benachrichtigen (Push)
    script.raise_event(logistics_event_id, { logistics_event = event })

    -- Debug output
    -- Ausgabe für Debugging
--    local location_str = source_or_target.type .. " [ID:" .. source_or_target.id .. "] Slot:" .. source_or_target.slot_name
--    if action == "TAKE" then
--       game.print("[Big-Brother] TAKE | Tick:" .. event.tick .. " | Actor:" .. actor.type .. "[" .. actor.id .. "," .. actor.name .. "] | Source:" .. location_str .. " | Item:" .. item.name .. " | Qty:" .. item.quantity .. " | Quality:" .. item.quality)
--    elseif action == "MAKE" then
--        game.print("[Big-Brother] MAKE | Tick:" .. event.tick .. " | Actor:" .. actor.type .. "[" .. actor.id .. "," .. actor.name .. "] | Location:" .. location_str .. " | Item:" .. item.name .. " | Qty:" .. item.quantity .. " | Quality:" .. item.quality)
--    else -- GIVE
--        game.print("[Big-Brother] GIVE | Tick:" .. event.tick .. " | Actor:" .. actor.type .. "[" .. actor.id .. "," .. actor.name .. "] | Target:" .. location_str .. " | Item:" .. item.name .. " | Qty:" .. item.quantity .. " | Quality:" .. item.quality)
--    end

    return event
end

-- Helper function: Create inventory snapshot (WITH QUALITY!)
-- Hilfsfunktion: Inventar-Snapshot erstellen (MIT QUALITÄT!)
local function create_inventory_snapshot(inventory)
    if not inventory or not inventory.valid then return {} end

    local snapshot = {}
    local contents = inventory.get_contents()

    for _, item_data in pairs(contents) do
        if type(item_data) == "table" and item_data.name then
            -- Key is now item_name + quality
            -- Key ist jetzt item_name + quality
            local quality = item_data.quality or "normal"
            local key = item_data.name .. "::" .. quality
            snapshot[key] = (snapshot[key] or 0) + item_data.count
        end
    end

    return snapshot
end

-- Helper function: Compare two snapshots and find differences
-- Hilfsfunktion: Vergleiche zwei Snapshots und finde Unterschiede
local function compare_snapshots(old_snap, new_snap)
    local changes = {}

    for item_key, old_count in pairs(old_snap) do
        local new_count = new_snap[item_key] or 0
        local diff = new_count - old_count
        if diff ~= 0 then
            changes[item_key] = diff
        end
    end

    for item_key, new_count in pairs(new_snap) do
        if not old_snap[item_key] then
            changes[item_key] = new_count
        end
    end

    return changes
end

-- Helper function: Parse item_key back to name and quality
-- Hilfsfunktion: Parse item_key zurück zu name und quality
local function parse_item_key(item_key)
    local parts = {}
    for part in string.gmatch(item_key, "[^:]+") do
        table.insert(parts, part)
    end

    if #parts >= 2 then
        -- Last part is quality, everything before is item_name
        -- Letzter Teil ist quality, alles davor ist item_name
        local quality = parts[#parts]
        table.remove(parts, #parts)
        local item_name = table.concat(parts, ":")
        return item_name, quality
    else
        return item_key, "normal"
    end
end

-- Helper function: Get all inventories of an entity with labels
-- Hilfsfunktion: Hole alle Inventare einer Entität mit Bezeichnung
local function get_all_entity_inventories(entity)
    local inventories = {}
    local seen_inventories = {}  -- Track inventory objects we've already added

    local inventory_types = {
        {type = defines.inventory.chest, slot_name = "chest"},
        {type = defines.inventory.furnace_source, slot_name = "input"},
        {type = defines.inventory.furnace_result, slot_name = "output"},
        {type = defines.inventory.furnace_modules, slot_name = "modules"},
        {type = defines.inventory.assembling_machine_input, slot_name = "input"},
        {type = defines.inventory.assembling_machine_output, slot_name = "output"},
        {type = defines.inventory.assembling_machine_modules, slot_name = "modules"},
        {type = defines.inventory.lab_input, slot_name = "input"},
        {type = defines.inventory.lab_modules, slot_name = "modules"},
        {type = defines.inventory.mining_drill_modules, slot_name = "modules"},
        {type = defines.inventory.rocket_silo_input, slot_name = "input"},
        {type = defines.inventory.rocket_silo_output, slot_name = "output"},
        {type = defines.inventory.rocket_silo_modules, slot_name = "modules"},
        {type = defines.inventory.beacon_modules, slot_name = "modules"},
        {type = defines.inventory.fuel, slot_name = "fuel"},
        {type = defines.inventory.burnt_result, slot_name = "burnt-result"},
    }

    for _, inv_data in pairs(inventory_types) do
        local inv = entity.get_inventory(inv_data.type)
        if inv and inv.valid then
            -- Use inventory index as unique identifier to avoid duplicates
            -- Nutze Inventar-Index als eindeutigen Identifier um Duplikate zu vermeiden
            local inv_index = inv.index
            if not seen_inventories[inv_index] then
                seen_inventories[inv_index] = true
                table.insert(inventories, {
                    inventory = inv,
                    type = inv_data.type,
                    slot_name = inv_data.slot_name,
                    entity_type = entity.type,
                    entity_id = entity.unit_number or 0
                })
            end
        end
    end

    return inventories
end

-- Initialize player data
-- Initialisiere Player-Data
local function init_player_data(player_index)
    if not storage.player_data[player_index] then
        storage.player_data[player_index] = {
            cursor_item = nil,
            cursor_count = 0,
            cursor_quality = nil,
            main_inventory = {},
            opened_entity = nil,
            entity_inventories = {}
        }
    end
end

-- Event: GUI opened
-- Event: GUI wird geöffnet
script.on_event(defines.events.on_gui_opened, function(event)
    local player = game.players[event.player_index]
    init_player_data(event.player_index)
    local pdata = storage.player_data[event.player_index]

    if event.gui_type == defines.gui_type.controller then
        pdata.main_inventory = create_inventory_snapshot(player.get_main_inventory())

    elseif event.gui_type == defines.gui_type.entity then
        local entity = event.entity
        if entity then
            pdata.opened_entity = entity

            local inventories = get_all_entity_inventories(entity)
            pdata.entity_inventories = {}

            for _, inv_data in pairs(inventories) do
                local snapshot = create_inventory_snapshot(inv_data.inventory)
                pdata.entity_inventories[inv_data.type] = {
                    snapshot = snapshot,
                    slot_name = inv_data.slot_name,
                    inventory = inv_data.inventory,
                    entity_type = inv_data.entity_type,
                    entity_id = inv_data.entity_id
                }
            end
        end
    end
end)

-- Helper function: Find source or target of an item based on inventory changes
-- Hilfsfunktion: Finde Quelle oder Ziel eines Items basierend auf Inventar-Änderungen
local function find_inventory_change(player, pdata, item_key, expected_sign)
    -- expected_sign: -1 for TAKE (item disappeared), +1 for GIVE (item added)
    -- expected_sign: -1 für TAKE (Item verschwunden), +1 für GIVE (Item hinzugefügt)
    
    -- Check player inventory first
    -- Prüfe zuerst Spieler-Inventar
    local new_main_inv = create_inventory_snapshot(player.get_main_inventory())
    local main_changes = compare_snapshots(pdata.main_inventory, new_main_inv)
    
    if main_changes[item_key] then
        local change = main_changes[item_key]
        if (expected_sign < 0 and change < 0) or (expected_sign > 0 and change > 0) then
            pdata.main_inventory = new_main_inv
            return {
                type = "player-inventory",
                id = player.index,
                slot_name = "main"
            }, math.abs(change)
        end
    end
    
    -- Check entity inventories
    -- Prüfe Entitäts-Inventare
    if pdata.opened_entity and pdata.opened_entity.valid then
        for inv_type, inv_data in pairs(pdata.entity_inventories) do
            if inv_data.inventory and inv_data.inventory.valid then
                local new_entity_inv = create_inventory_snapshot(inv_data.inventory)
                local entity_changes = compare_snapshots(inv_data.snapshot, new_entity_inv)
                
                if entity_changes[item_key] then
                    local change = entity_changes[item_key]
                    if (expected_sign < 0 and change < 0) or (expected_sign > 0 and change > 0) then
                        inv_data.snapshot = new_entity_inv
                        return {
                            type = inv_data.entity_type,
                            id = inv_data.entity_id,
                            slot_name = inv_data.slot_name
                        }, math.abs(change)
                    end
                end
            end
        end
    end
    
    return nil, 0
end

-- Event: Cursor stack changes
-- Event: Cursor Stack ändert sich
script.on_event(defines.events.on_player_cursor_stack_changed, function(event)
    local player = game.players[event.player_index]
    init_player_data(event.player_index)
    local pdata = storage.player_data[event.player_index]

    local cursor_stack = player.cursor_stack
    local old_cursor_item = pdata.cursor_item
    local old_cursor_count = pdata.cursor_count
    local old_cursor_quality = pdata.cursor_quality

    local new_cursor_item = nil
    local new_cursor_count = 0
    local new_cursor_quality = nil

    if cursor_stack and cursor_stack.valid_for_read then
        new_cursor_item = cursor_stack.name
        new_cursor_count = cursor_stack.count
        new_cursor_quality = cursor_stack.quality and cursor_stack.quality.name or "normal"
    end

    -- Actor is now also a uniform table
    -- Actor ist jetzt auch eine einheitliche Tabelle
    local actor = {
        type = "player-hand",
        id = event.player_index,
        name = player.name
    }

    -- CASE 1: TAKE - Something was picked up (hand was empty, now full)
    -- FALL 1: TAKE - Etwas wurde in die Hand genommen (Hand war leer, jetzt voll)
    if old_cursor_item == nil and new_cursor_item ~= nil then
        local item_key = new_cursor_item .. "::" .. new_cursor_quality
        local source, quantity = find_inventory_change(player, pdata, item_key, -1)
        
        -- Item was taken - either from inventory or the world
        -- Item wurde genommen - entweder aus Inventar oder von der Welt
        if not source then
            source = {type = "world", id = 0, slot_name = "none"}
            quantity = new_cursor_count
        end
        
        local item = {
            name = new_cursor_item,
            quantity = quantity,
            quality = new_cursor_quality
        }
        create_logistics_event("TAKE", actor, source, item)

    -- CASE 2: GIVE - Something was put down (hand was full, now empty)
    -- FALL 2: GIVE - Etwas wurde abgelegt (Hand war voll, jetzt leer)
    elseif old_cursor_item ~= nil and new_cursor_item == nil then
        local item_key = old_cursor_item .. "::" .. old_cursor_quality
        local target, quantity = find_inventory_change(player, pdata, item_key, 1)
        
        -- Item was placed - either in inventory or on the world
        -- Item wurde abgelegt - entweder in Inventar oder auf die Welt
        if not target then
            target = {type = "world", id = 0, slot_name = "none"}
            quantity = old_cursor_count
        end
        
        local item = {
            name = old_cursor_item,
            quantity = quantity,
            quality = old_cursor_quality
        }
        create_logistics_event("GIVE", actor, target, item)

    -- CASE 3: Item swap or quantity change in hand
    -- FALL 3: Item-Wechsel oder Mengenänderung in der Hand
    elseif old_cursor_item ~= nil and new_cursor_item ~= nil then
        if old_cursor_item == new_cursor_item and old_cursor_quality == new_cursor_quality then
            -- Same item type, different quantity
            -- Gleicher Item-Typ, andere Menge
            local diff = new_cursor_count - old_cursor_count
            local item_key = new_cursor_item .. "::" .. new_cursor_quality
            
            if diff > 0 then
                -- More items in hand -> TAKE
                -- Mehr Items in der Hand -> TAKE
                local source, quantity = find_inventory_change(player, pdata, item_key, -1)
                if not source then
                    source = {type = "world", id = 0, slot_name = "none"}
                    quantity = diff
                end
                
                local item = {
                    name = new_cursor_item,
                    quantity = quantity,
                    quality = new_cursor_quality
                }
                create_logistics_event("TAKE", actor, source, item)
                
            elseif diff < 0 then
                -- Fewer items in hand -> GIVE
                -- Weniger Items in der Hand -> GIVE
                local target, quantity = find_inventory_change(player, pdata, item_key, 1)
                if not target then
                    target = {type = "world", id = 0, slot_name = "none"}
                    quantity = math.abs(diff)
                end
                
                local item = {
                    name = new_cursor_item,
                    quantity = quantity,
                    quality = new_cursor_quality
                }
                create_logistics_event("GIVE", actor, target, item)
            end
            
        else
            -- ITEM-SWAP: Completely different item or different quality
            -- ITEM-SWAP: Komplett anderes Item oder andere Qualität
            -- 1. GIVE: Old item is put down
            -- 1. GIVE: Altes Item wird abgelegt
            local old_item_key = old_cursor_item .. "::" .. old_cursor_quality
            local target, given_quantity = find_inventory_change(player, pdata, old_item_key, 1)
            
            if not target then
                target = {type = "world", id = 0, slot_name = "none"}
                given_quantity = old_cursor_count
            end
            
            local old_item = {
                name = old_cursor_item,
                quantity = given_quantity,
                quality = old_cursor_quality
            }
            create_logistics_event("GIVE", actor, target, old_item)
            
            -- 2. TAKE: New item is picked up
            -- 2. TAKE: Neues Item wird genommen
            local new_item_key = new_cursor_item .. "::" .. new_cursor_quality
            local source, taken_quantity = find_inventory_change(player, pdata, new_item_key, -1)
            
            if not source then
                source = {type = "world", id = 0, slot_name = "none"}
                taken_quantity = new_cursor_count
            end
            
            local new_item = {
                name = new_cursor_item,
                quantity = taken_quantity,
                quality = new_cursor_quality
            }
            create_logistics_event("TAKE", actor, source, new_item)
        end
    end

    -- Save new state
    -- Speichere neuen Zustand
    pdata.cursor_item = new_cursor_item
    pdata.cursor_count = new_cursor_count
    pdata.cursor_quality = new_cursor_quality
end)

-- Event: GUI closed
-- Event: GUI wird geschlossen
script.on_event(defines.events.on_gui_closed, function(event)
    local player = game.players[event.player_index]
    init_player_data(event.player_index)
    local pdata = storage.player_data[event.player_index]

    if event.gui_type == defines.gui_type.entity then
        pdata.opened_entity = nil
        pdata.entity_inventories = {}
    end
end)

-- Event: Quick Transfer (Control + Click)
-- This event fires AFTER the transfer has taken place
-- Event: Quick Transfer (Control + Click)
-- Dieses Event feuert NACHDEM der Transfer stattgefunden hat
-- Problem: We don't have snapshots of entities that are not open
-- Problem: Wir haben keine Snapshots von Entitäten die nicht geöffnet sind
-- Solution: We only compare the player inventory and derive from that
-- Lösung: Wir vergleichen nur das Spieler-Inventar und leiten daraus ab
script.on_event(defines.events.on_player_fast_transferred, function(event)
    local player = game.players[event.player_index]
    local entity = event.entity
    
    if not entity or not entity.valid then return end
    
    init_player_data(event.player_index)
    local pdata = storage.player_data[event.player_index]
    
    local actor = {
        type = "player-hand",
        id = event.player_index,
        name = player.name
    }
    
    -- Create current snapshot of player inventory
    -- Erstelle aktuellen Snapshot vom Spieler-Inventar
    local current_player_inv = create_inventory_snapshot(player.get_main_inventory())
    
    -- Compare with stored snapshot
    -- Vergleiche mit gespeichertem Snapshot
    local player_changes = compare_snapshots(pdata.main_inventory, current_player_inv)
    
    if event.from_player then
        -- QUICK GIVE: From player to entity
        -- QUICK GIVE: Vom Spieler zur Entität
        -- The player inventory has lost items
        -- Das Spieler-Inventar hat Items verloren
        for item_key, change in pairs(player_changes) do
            if change < 0 then
                local item_name, quality = parse_item_key(item_key)
                local quantity = math.abs(change)
                
                local item = {
                    name = item_name,
                    quantity = quantity,
                    quality = quality
                }
                
                -- 1. TAKE from player inventory
                -- 1. TAKE aus Spieler-Inventar
                local source = {
                    type = "player-inventory",
                    id = event.player_index,
                    slot_name = "main"
                }
                create_logistics_event("TAKE", actor, source, item)
                
                -- 2. GIVE to entity (determine the correct slot_name)
                -- 2. GIVE zur Entität (ermittle den richtigen slot_name)
                local inventories = get_all_entity_inventories(entity)
                local slot_name = "chest" -- Default
                
                -- Try to find the specific slot
                -- Versuche den spezifischen Slot zu finden
                for _, inv_data in pairs(inventories) do
                    slot_name = inv_data.slot_name
                    break -- Take the first available / Nimm den ersten verfügbaren
                end
                
                local target = {
                    type = entity.type,
                    id = entity.unit_number or 0,
                    slot_name = slot_name
                }
                create_logistics_event("GIVE", actor, target, item)
            end
        end
    else
        -- QUICK TAKE: From entity to player
        -- QUICK TAKE: Von der Entität zum Spieler
        -- The player inventory has gained items
        -- Das Spieler-Inventar hat Items gewonnen
        for item_key, change in pairs(player_changes) do
            if change > 0 then
                local item_name, quality = parse_item_key(item_key)
                local quantity = change
                
                local item = {
                    name = item_name,
                    quantity = quantity,
                    quality = quality
                }
                
                -- 1. TAKE from entity
                -- 1. TAKE von der Entität
                local inventories = get_all_entity_inventories(entity)
                local slot_name = "chest" -- Default
                
                -- Try to find the specific slot
                -- Versuche den spezifischen Slot zu finden
                for _, inv_data in pairs(inventories) do
                    slot_name = inv_data.slot_name
                    break
                end
                
                local source = {
                    type = entity.type,
                    id = entity.unit_number or 0,
                    slot_name = slot_name
                }
                create_logistics_event("TAKE", actor, source, item)
                
                -- 2. GIVE to player inventory
                -- 2. GIVE ins Spieler-Inventar
                local target = {
                    type = "player-inventory",
                    id = event.player_index,
                    slot_name = "main"
                }
                create_logistics_event("GIVE", actor, target, item)
            end
        end
    end
    
    -- Update player inventory snapshot
    -- Update Spieler-Inventar Snapshot
    pdata.main_inventory = current_player_inv
end)
-- Event: Player drops items on ground
-- Event: Spieler wirft Items auf den Boden
script.on_event(defines.events.on_player_dropped_item, function(event)
    local player = game.players[event.player_index]
    local entity = event.entity -- The dropped item entity on ground
    
    if not entity or not entity.valid or not entity.stack or not entity.stack.valid_for_read then return end
    
    init_player_data(event.player_index)
    
    local actor = {
        type = "player-hand",
        id = event.player_index,
        name = player.name
    }
    
    local item = {
        name = entity.stack.name,
        quantity = entity.stack.count,
        quality = entity.stack.quality and entity.stack.quality.name or "normal"
    }
    
    -- 1. TAKE from player inventory
    -- 1. TAKE aus Spieler-Inventar
    local source = {
        type = "player-inventory",
        id = event.player_index,
        slot_name = "main"
    }
    create_logistics_event("TAKE", actor, source, item)
    
    -- 2. GIVE to world/ground
    -- 2. GIVE auf den Boden/Welt
    local target = {
        type = "ground",
        id = entity.unit_number or 0,
        slot_name = "none"
    }
    create_logistics_event("GIVE", actor, target, item)
end)

-- Event: Player picks up items from ground
-- Event: Spieler hebt Items vom Boden auf
script.on_event(defines.events.on_picked_up_item, function(event)
    local player = game.players[event.player_index]
    local item_stack = event.item_stack
    
    if not item_stack or not item_stack.name then return end
    
    game.print("[DEBUG] on_picked_up_item: " .. item_stack.name .. " x" .. item_stack.count)
    
    init_player_data(event.player_index)
    
    local actor = {
        type = "player-hand",
        id = event.player_index,
        name = player.name
    }
    
    local item = {
        name = item_stack.name,
        quantity = item_stack.count,
        quality = item_stack.quality and item_stack.quality.name or "normal"
    }
    
    -- 1. TAKE from ground
    -- 1. TAKE vom Boden
    local source = {
        type = "ground",
        id = 0,
        slot_name = "none"
    }
    create_logistics_event("TAKE", actor, source, item)
    
    -- 2. GIVE to player inventory
    -- 2. GIVE ins Spieler-Inventar
    local target = {
        type = "player-inventory",
        id = event.player_index,
        slot_name = "main"
    }
    create_logistics_event("GIVE", actor, target, item)
end)

-- DEBUG: Test für Rechtsklick-Aufheben
script.on_event(defines.events.on_player_cursor_stack_changed, function(event)
    local player = game.players[event.player_index]
    game.print("[DEBUG] on_player_cursor_stack_changed ausgelöst - Cursor hat jetzt: " .. (player.cursor_stack.valid_for_read and player.cursor_stack.name or "nichts"))
end)

-- Event: Player crafts item (manually)
-- Event: Spieler craftet Item (manuell)
-- Uses retrograde booking: TAKE ingredients -> MAKE -> GIVE result
-- Nutzt retrograde Buchung: TAKE Zutaten -> MAKE -> GIVE Ergebnis
script.on_event(defines.events.on_player_crafted_item, function(event)
    local player = game.players[event.player_index]
    local item_stack = event.item_stack
    local recipe = event.recipe
    
    if not item_stack or not item_stack.valid_for_read or not recipe then return end
    
    init_player_data(event.player_index)
    
    local actor = {
        type = "player-hand",
        id = event.player_index,
        name = player.name
    }
    
    -- Crafting location (virtual)
    -- Crafting-Ort (virtuell)
    local crafting_location = {
        type = "crafting",
        id = event.player_index,
        slot_name = recipe.name
    }
    
    -- Player inventory as source/target
    -- Spieler-Inventar als Quelle/Ziel
    local player_inventory = {
        type = "player-inventory",
        id = event.player_index,
        slot_name = "main"
    }
    
    -- 1. RETROGRADE BOOKING: TAKE all ingredients from player inventory
    -- 1. RETROGRADE BUCHUNG: TAKE alle Zutaten aus Spieler-Inventar
    local ingredients = recipe.ingredients
    for _, ingredient in pairs(ingredients) do
        if ingredient.name then
            local ingredient_item = {
                name = ingredient.name,
                quantity = ingredient.amount * item_stack.count, -- Multiply by crafted quantity
                quality = "normal" -- Recipes don't specify quality, assume normal
            }
            
            -- TAKE ingredient from player inventory
            -- TAKE Zutat aus Spieler-Inventar
            create_logistics_event("TAKE", actor, player_inventory, ingredient_item)
            
            -- GIVE ingredient to crafting
            -- GIVE Zutat zum Crafting
            create_logistics_event("GIVE", actor, crafting_location, ingredient_item)
        end
    end
    
    -- 2. MAKE: The actual crafting process
    -- 2. MAKE: Der eigentliche Crafting-Vorgang
    local crafted_item = {
        name = item_stack.name,
        quantity = item_stack.count,
        quality = item_stack.quality and item_stack.quality.name or "normal"
    }
    
    create_logistics_event("MAKE", actor, crafting_location, crafted_item)
    
    -- 3. TAKE: Remove crafted item from crafting
    -- 3. TAKE: Gefertigtes Item aus dem Crafting nehmen
    create_logistics_event("TAKE", actor, crafting_location, crafted_item)
    
    -- 4. GIVE: Put crafted item into player inventory
    -- 4. GIVE: Gefertigtes Item ins Spieler-Inventar
    create_logistics_event("GIVE", actor, player_inventory, crafted_item)
end)

-- Event: BEFORE player mines entity - capture inventory contents
-- Event: BEVOR Spieler Entität abbaut - erfasse Inventar-Inhalte
script.on_event(defines.events.on_pre_player_mined_item, function(event)
    local player = game.players[event.player_index]
    local entity = event.entity
    
    if not entity or not entity.valid then return end
    
    init_player_data(event.player_index)
    
    local actor = {
        type = "player-hand",
        id = event.player_index,
        name = player.name
    }
    
    -- Special case: Item on ground (Rechtsklick auf Item am Boden)
    -- Spezialfall: Item am Boden (Rechtsklick auf Item am Boden)
    if entity.type == "item-entity" and entity.stack and entity.stack.valid_for_read then
        local item = {
            name = entity.stack.name,
            quantity = entity.stack.count,
            quality = entity.stack.quality and entity.stack.quality.name or "normal"
        }
        
        -- TAKE from ground
        local source = {
            type = "ground",
            id = 0,
            slot_name = "none"
        }
        create_logistics_event("TAKE", actor, source, item)
        
        -- GIVE to player inventory
        local target = {
            type = "player-inventory",
            id = event.player_index,
            slot_name = "main"
        }
        create_logistics_event("GIVE", actor, target, item)
        
        return -- Fertig für item-on-ground
    end
    
    -- Normal case: Entity with inventories (Kisten, Maschinen, etc.)
    -- Normalfall: Entity mit Inventaren (Kisten, Maschinen, etc.)
    -- Get all inventories of this entity
    -- Hole alle Inventare dieser Entity
    local inventories = get_all_entity_inventories(entity)
    
    -- DEBUG: Zeige was gefunden wurde
--    if #inventories > 0 then
--        game.print("[DEBUG PRE-MINING] Entity: " .. entity.type .. " [ID:" .. (entity.unit_number or 0) .. "] - Found " .. #inventories .. " inventory slots")
--    end
    
    for _, inv_data in pairs(inventories) do
        if inv_data.inventory and inv_data.inventory.valid then
            local contents = inv_data.inventory.get_contents()
            
            -- DEBUG: Zeige Slot-Info
            local item_count = 0
            for _ in pairs(contents) do item_count = item_count + 1 end
--            game.print("[DEBUG PRE-MINING]   Slot: " .. inv_data.slot_name .. " - Items: " .. item_count)
            
            for _, item_data in pairs(contents) do
                if type(item_data) == "table" and item_data.name then
                    local item = {
                        name = item_data.name,
                        quantity = item_data.count,
                        quality = item_data.quality or "normal"
                    }
                    
--                    game.print("[DEBUG PRE-MINING]     -> TAKE " .. item.quantity .. "x " .. item.name .. " from slot:" .. inv_data.slot_name)
                    
                    -- TAKE from entity inventory (chest content, module slots, etc.)
                    -- TAKE aus Entity-Inventar (Kisten-Inhalt, Modul-Slots, etc.)
                    local source = {
                        type = entity.type,
                        id = entity.unit_number or 0,
                        slot_name = inv_data.slot_name
                    }
                    create_logistics_event("TAKE", actor, source, item)
                    
                    -- GIVE to player inventory
                    -- GIVE ins Spieler-Inventar
                    local target = {
                        type = "player-inventory",
                        id = event.player_index,
                        slot_name = "main"
                    }
                    create_logistics_event("GIVE", actor, target, item)
                end
            end
        end
    end
end)

-- Event: Player mines/deconstructs entity and gets items
-- Event: Spieler baut Entität ab und bekommt Items
script.on_event(defines.events.on_player_mined_entity, function(event)
    local player = game.players[event.player_index]
    local entity = event.entity
    local buffer = event.buffer -- LuaInventory containing the mined items
    
    if not buffer or not buffer.valid then return end
    
    init_player_data(event.player_index)
    
    local actor = {
        type = "player-hand",
        id = event.player_index,
        name = player.name
    }
    
    -- Get all items from mining result
    -- Hole alle Items aus dem Abbau-Ergebnis
    local contents = buffer.get_contents()
    
    for _, item_data in pairs(contents) do
        if type(item_data) == "table" and item_data.name then
            local item = {
                name = item_data.name,
                quantity = item_data.count,
                quality = item_data.quality or "normal"
            }
            
            -- TAKE from mined entity
            -- TAKE von abgebauter Entität
            local source = {
                type = entity.type,
                id = entity.unit_number or 0,
                slot_name = "mining"
            }
            create_logistics_event("TAKE", actor, source, item)
            
            -- GIVE to player inventory
            -- GIVE ins Spieler-Inventar
            local target = {
                type = "player-inventory",
                id = event.player_index,
                slot_name = "main"
            }
            create_logistics_event("GIVE", actor, target, item)
        end
    end
end)