-- control.lua des Client-Mods (ohne storage - komplett clean)

local Registry = require("event_registry")

local PROVIDER_API = "logistics_events_api"

-- Flag: Wird bei on_load auf true gesetzt
local needs_registration = false

-- Funktion, die die Daten vom Provider verarbeitet
local function handle_logistics_event(event)
    local le = event.logistics_event
    if not le then return end
    
    -- Extrahiere Daten aus dem logistics_event
    local location_str = le.source_or_target.type .. " [ID:" .. le.source_or_target.id .. "] Slot:" .. le.source_or_target.slot_name
    
    if le.action == "TAKE" then
       game.print("[CLIENT] TAKE | Tick:" .. le.tick .. " | Actor:" .. le.actor.type .. "[" .. le.actor.id .. "," .. le.actor.name .. "] | Source:" .. location_str .. " | Item:" .. le.item.name .. " | Qty:" .. le.item.quantity .. " | Quality:" .. le.item.quality)
    elseif le.action == "MAKE" then
        game.print("[CLIENT] MAKE | Tick:" .. le.tick .. " | Actor:" .. le.actor.type .. "[" .. le.actor.id .. "," .. le.actor.name .. "] | Location:" .. location_str .. " | Item:" .. le.item.name .. " | Qty:" .. le.item.quantity .. " | Quality:" .. le.item.quality)
    else -- GIVE
        game.print("[CLIENT] GIVE | Tick:" .. le.tick .. " | Actor:" .. le.actor.type .. "[" .. le.actor.id .. "," .. le.actor.name .. "] | Target:" .. location_str .. " | Item:" .. le.item.name .. " | Qty:" .. le.item.quantity .. " | Quality:" .. le.item.quality)
    end
end

-- Funktion zur Registrierung des Events beim Provider
local function try_register_logistics_events()
    -- Prüfen, ob das Interface des Big Brother existiert
    if not remote.interfaces[PROVIDER_API] then
        return false
    end
    
    local event_id = remote.call(PROVIDER_API, "get_event_id")
    if not event_id then
        return false
    end
    
    -- Registry komplett neu aufbauen und Event registrieren
    event_registry = Registry.new()
    event_registry:add(event_id, handle_logistics_event)
    event_registry:bind()
    
    game.print("[Logistics-Client] Erfolgreich beim Big Brother registriert. Event-ID: " .. tostring(event_id))
    return true
end

-- 1. Beim Spielstart (frische Welt)
script.on_init(function()
    event_registry = Registry.new()
end)

-- 2. Beim Laden eines Spielstands
script.on_load(function()
    event_registry = Registry.new()
end)

-- 3. Bei Konfigurationsänderungen (Mods hinzugefügt/entfernt/umgeordnet)
script.on_configuration_changed(function()
    event_registry = Registry.new()
end)

-- 4. On Tick: Prüfe ob Registrierung nach on_load nötig ist
script.on_event(defines.events.on_tick, function(event)
end)

-- 5. Backup-Polling: Falls der Big Brother erst später verfügbar wird
-- (z.B. unterschiedliche Ladereihenfolge)
script.on_nth_tick(600, function()
  try_register_logistics_events()
end)
