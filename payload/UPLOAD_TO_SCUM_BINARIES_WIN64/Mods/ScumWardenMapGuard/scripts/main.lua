local okHelpers, UEHelpers = pcall(require, "UEHelpers")
if not okHelpers then UEHelpers = nil end

local TAG = "[ScumWardenMapGuard]"
local CONFIG_FILE = "ScumWarden\\configs\\map-guard.json"

local CONFIG = {
    Enabled = true,
    RequiredItemIdsText = "Magnifying_Glass|Magnifying_Glass1",
    OpenMapWithItem = true,
    BlockMapWithoutItem = true,
    GuardPollMs = 1500,
    GuardPollWhenMapOpenMs = 500,
    ConfigReloadMs = 10000,
    HudLookupCacheMs = 3000,
    ToggleCooldownSeconds = 0.45,
    DebugLogs = false,
}

local REQUIRED_ITEM_IDS = { "Magnifying_Glass", "Magnifying_Glass1" }
local LOOP_TICK_MS = 500
local MAP_HUD_MODE = 2
local NORMAL_HUD_MODE = 0
local lastToggleAt = 0
local lastDenyLogAt = 0
local mapOpenedByGuard = false
local lastConfigLoadAt = -1000
local lastGuardPollAt = -1000
local lastHudLookupAt = -1000
local cachedHudObjects = {}

local function log(message, force)
    if not force and not CONFIG.DebugLogs then return end
    print(string.format("%s %s\n", TAG, tostring(message)))
end

local function safeCall(fn, fallback, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return fallback
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function extractString(text, key)
    local source = tostring(text or "")
    local needle = '"' .. tostring(key or "") .. '"'
    local pos = source:find(needle, 1, true)
    if pos == nil then return nil end
    local colon = source:find(":", pos + #needle, true)
    if colon == nil then return nil end
    local quote = source:find('"', colon + 1, true)
    if quote == nil then return nil end
    local out = {}
    local escaped = false
    local i = quote + 1
    while i <= #source do
        local ch = source:sub(i, i)
        if escaped then
            table.insert(out, ch)
            escaped = false
        elseif ch == "\\" then
            escaped = true
        elseif ch == '"' then
            return table.concat(out)
        else
            table.insert(out, ch)
        end
        i = i + 1
    end
    return nil
end

local function extractNumber(text, key, fallback)
    local raw = tostring(text or ""):match('"' .. key .. '"%s*:%s*([%-%.%d]+)')
    return tonumber(raw) or fallback
end

local function extractBool(text, key, fallback)
    local raw = tostring(text or ""):match('"' .. key .. '"%s*:%s*(true)') or tostring(text or ""):match('"' .. key .. '"%s*:%s*(false)')
    if raw == "true" then return true end
    if raw == "false" then return false end
    local asString = extractString(text, key)
    if asString ~= nil then
        local normalized = tostring(asString):lower()
        if normalized == "true" or normalized == "1" or normalized == "yes" then return true end
        if normalized == "false" or normalized == "0" or normalized == "no" then return false end
    end
    return fallback
end

local function splitRequiredItems(text)
    local items = {}
    for token in tostring(text or ""):gmatch("[^,;|%s]+") do
        if token ~= "" then table.insert(items, token) end
    end
    if #items == 0 then
        items = { "Magnifying_Glass", "Magnifying_Glass1" }
    end
    return items
end

local function loadConfig()
    lastConfigLoadAt = os.clock()
    local text = readAll(CONFIG_FILE)
    if text == nil or text == "" then
        REQUIRED_ITEM_IDS = splitRequiredItems(CONFIG.RequiredItemIdsText)
        return
    end
    CONFIG.Enabled = extractBool(text, "Enabled", extractBool(text, "enabled", CONFIG.Enabled))
    CONFIG.RequiredItemIdsText = extractString(text, "RequiredItemIdsText") or extractString(text, "requiredItemIdsText") or CONFIG.RequiredItemIdsText
    CONFIG.OpenMapWithItem = extractBool(text, "OpenMapWithItem", extractBool(text, "openMapWithItem", CONFIG.OpenMapWithItem))
    CONFIG.BlockMapWithoutItem = extractBool(text, "BlockMapWithoutItem", extractBool(text, "blockMapWithoutItem", CONFIG.BlockMapWithoutItem))
    CONFIG.GuardPollMs = math.max(500, extractNumber(text, "GuardPollMs", extractNumber(text, "guardPollMs", CONFIG.GuardPollMs)))
    CONFIG.GuardPollWhenMapOpenMs = math.max(250, extractNumber(text, "GuardPollWhenMapOpenMs", extractNumber(text, "guardPollWhenMapOpenMs", CONFIG.GuardPollWhenMapOpenMs)))
    CONFIG.ConfigReloadMs = math.max(1000, extractNumber(text, "ConfigReloadMs", extractNumber(text, "configReloadMs", CONFIG.ConfigReloadMs)))
    CONFIG.HudLookupCacheMs = math.max(500, extractNumber(text, "HudLookupCacheMs", extractNumber(text, "hudLookupCacheMs", CONFIG.HudLookupCacheMs)))
    CONFIG.ToggleCooldownSeconds = math.max(0.1, extractNumber(text, "ToggleCooldownSeconds", extractNumber(text, "toggleCooldownSeconds", CONFIG.ToggleCooldownSeconds)))
    CONFIG.DebugLogs = extractBool(text, "DebugLogs", extractBool(text, "debugLogs", CONFIG.DebugLogs))
    REQUIRED_ITEM_IDS = splitRequiredItems(CONFIG.RequiredItemIdsText)
end

local function reloadConfigIfNeeded()
    local reloadSeconds = math.max(1.0, (tonumber(CONFIG.ConfigReloadMs) or 5000) / 1000.0)
    if os.clock() - lastConfigLoadAt < reloadSeconds then return end
    loadConfig()
end

local function unwrap(value)
    if value == nil then return nil end
    return safeCall(function()
        if value.get ~= nil then return value:get() end
        return value
    end, value)
end

local function isValidObject(object)
    if object == nil then return false end
    return safeCall(function()
        return object.IsValid ~= nil and object:IsValid()
    end, false)
end

local function fullName(object)
    if not isValidObject(object) then return "" end
    return safeCall(function()
        return object:GetFullName()
    end, tostring(object))
end

local function addUniqueObject(list, seen, object)
    local raw = unwrap(object)
    if not isValidObject(raw) then return end
    local key = fullName(raw)
    if key == "" then key = tostring(raw) end
    if seen[key] then return end
    seen[key] = true
    table.insert(list, raw)
end

local function getObjectByMethod(object, methodName)
    if not isValidObject(object) then return nil end
    return unwrap(safeCall(function()
        local method = object[methodName]
        if method == nil then return nil end
        return method(object)
    end, nil))
end

local function getObjectByProperty(object, propertyName)
    if not isValidObject(object) then return nil end
    return unwrap(safeCall(function() return object[propertyName] end, nil))
end

local function containsRequiredItemId(text)
    local source = tostring(text or ""):lower()
    for _, itemId in ipairs(REQUIRED_ITEM_IDS) do
        local cleanId = tostring(itemId or ""):lower()
        if cleanId ~= "" and source:find(cleanId, 1, true) then return true end
    end
    return false
end

local function looksLikeMapItem(object)
    local objectName = fullName(object)
    if containsRequiredItemId(objectName) then return true, objectName end
    for _, method in ipairs({ "GetName", "GetPathName", "GetItemID", "GetItemId", "GetItemName", "GetDisplayName" }) do
        local text = safeCall(function()
            if object ~= nil and object[method] ~= nil then return tostring(object[method](object)) end
            return ""
        end, "")
        if containsRequiredItemId(text) then return true, text end
    end
    for _, prop in ipairs({ "ItemId", "ItemID", "itemId", "ItemName", "Name", "_itemId", "_itemName" }) do
        local text = tostring(unwrap(safeCall(function()
            if object ~= nil then return object[prop] end
            return nil
        end, nil)) or "")
        if containsRequiredItemId(text) then return true, text end
    end
    local class = safeCall(function() return object:GetClass() end, nil)
    local className = fullName(class)
    if containsRequiredItemId(className) then return true, className end
    for _, method in ipairs({ "GetName", "GetPathName" }) do
        local text = safeCall(function()
            if class ~= nil and class[method] ~= nil then return tostring(class[method](class)) end
            return ""
        end, "")
        if containsRequiredItemId(text) then return true, text end
    end
    return false, objectName
end

local function getLocalController()
    if UEHelpers ~= nil and UEHelpers.GetPlayerController ~= nil then
        return safeCall(function() return UEHelpers.GetPlayerController() end, nil)
    end
    return nil
end

local function getLocalPrisoner(controller)
    if not isValidObject(controller) then return nil end
    local prisoner = safeCall(function()
        if controller.GetPrisoner ~= nil then return controller:GetPrisoner() end
        return nil
    end, nil)
    if isValidObject(prisoner) then return prisoner end
    return unwrap(safeCall(function() return controller.Pawn end, nil))
end

local function getItemInHandsFrom(object)
    if not isValidObject(object) then return nil end
    for _, method in ipairs({ "GetItemInHands", "GetItemInHandsOnServer", "GetHeldItem", "GetCurrentItemInHands" }) do
        local direct = safeCall(function()
            if object[method] ~= nil then return object[method](object) end
            return nil
        end, nil)
        if isValidObject(direct) then return direct end
    end
    for _, prop in ipairs({ "ItemInHands", "_itemInHands", "CurrentItemInHands", "HeldItem", "EquippedItem" }) do
        local direct = unwrap(safeCall(function() return object[prop] end, nil))
        if isValidObject(direct) then return direct end
    end
    for _, componentName in ipairs({
        "ItemDragComponent",
        "_itemDragComponent",
        "CharacterItemDragComponent",
        "itemDragComponent",
        "InventoryComponent",
        "_inventoryComponent",
    }) do
        local component = unwrap(safeCall(function() return object[componentName] end, nil))
        if isValidObject(component) then
            for _, method in ipairs({ "GetItemInHands", "GetItemInHandsOnServer", "GetHeldItem", "GetCurrentItemInHands" }) do
                local item = safeCall(function()
                    if component[method] ~= nil then return component[method](component) end
                    return nil
                end, nil)
                if isValidObject(item) then return item end
            end
            for _, prop in ipairs({ "ItemInHands", "_itemInHands", "CurrentItemInHands", "HeldItem", "EquippedItem" }) do
                local item = unwrap(safeCall(function() return component[prop] end, nil))
                if isValidObject(item) then return item end
            end
        end
    end
    return nil
end

local function hasMapInHands()
    local controller = getLocalController()
    local prisoner = getLocalPrisoner(controller)
    local pawn = unwrap(safeCall(function() return controller.Pawn end, nil))
    local sources = {}
    if isValidObject(prisoner) then table.insert(sources, prisoner) end
    if isValidObject(pawn) and pawn ~= prisoner then table.insert(sources, pawn) end
    if isValidObject(controller) then table.insert(sources, controller) end
    for _, source in ipairs(sources) do
        local item = getItemInHandsFrom(source)
        local ok, hit = looksLikeMapItem(item)
        if ok then return true, hit end
    end
    return false, "required map item is not in hands"
end

local function tryMethod(object, methodName, ...)
    if not isValidObject(object) then return false end
    return safeCall(function(...)
        local method = object[methodName]
        if method == nil then return false end
        method(object, ...)
        return true
    end, false, ...)
end

local function tryAnyMethod(object, methodNames, ...)
    local changed = false
    for _, methodName in ipairs(methodNames) do
        if tryMethod(object, methodName, ...) then changed = true end
    end
    return changed
end

local function getHudObjects()
    local now = os.clock()
    local cacheSeconds = math.max(0.5, (tonumber(CONFIG.HudLookupCacheMs) or 2000) / 1000.0)
    if now - lastHudLookupAt < cacheSeconds and #cachedHudObjects > 0 then
        return cachedHudObjects
    end
    local huds = {}
    local seen = {}
    local controller = getLocalController()
    for _, propertyName in ipairs({ "MyHUD", "HUD", "Hud", "PrisonerHUD", "PlayerHUD", "_hud", "_prisonerHUD" }) do
        addUniqueObject(huds, seen, getObjectByProperty(controller, propertyName))
    end
    for _, methodName in ipairs({ "GetHUD", "GetHud", "GetPrisonerHUD", "GetPlayerHUD" }) do
        addUniqueObject(huds, seen, getObjectByMethod(controller, methodName))
    end
    if FindAllOf ~= nil then
        for _, className in ipairs({ "PrisonerHUD", "BP_PrisonerHUD_C", "PrisonerHUD_C", "BP_PrisonerHUD" }) do
            local found = safeCall(function() return FindAllOf(className) end, nil)
            if type(found) == "table" then
                for _, hud in pairs(found) do addUniqueObject(huds, seen, hud) end
            end
        end
    end
    cachedHudObjects = huds
    lastHudLookupAt = now
    return cachedHudObjects
end

local function getHudMode(hud)
    return safeCall(function()
        if hud.GetHUDMode ~= nil then return hud:GetHUDMode() end
        if hud.GetHudMode ~= nil then return hud:GetHudMode() end
        return nil
    end, nil)
end

local function isMapHudMode(mode)
    local raw = unwrap(mode)
    if type(raw) == "number" then return raw == 2 or raw == 4 end
    local text = tostring(raw)
    return text:find("EPrisonerHUDMode::Map", 1, true) ~= nil
        or text:find("EPrisonerHUDMode::DroneMap", 1, true) ~= nil
end

local function vanillaMapLooksOpen()
    for _, hud in ipairs(getHudObjects()) do
        local mode = getHudMode(hud)
        if isMapHudMode(mode) then return true, tostring(unwrap(mode)) end
    end
    return false, "no map HUD mode"
end

local function setHudMode(mode)
    local changed = false
    for _, hud in ipairs(getHudObjects()) do
        if tryMethod(hud, "SetHUDMode", mode) or tryMethod(hud, "SetHudMode", mode) then changed = true end
    end
    local controller = getLocalController()
    if tryAnyMethod(controller, { "SetHUDMode", "SetHudMode", "SetPrisonerHUDMode" }, mode) then changed = true end
    return changed
end

local function openHudMap()
    local changed = false
    local openMethods = {
        "OpenMap",
        "OpenMapScreen",
        "OpenWorldMap",
        "OpenMapWidget",
        "ShowMap",
        "ShowMapScreen",
        "ShowWorldMap",
        "ShowMapWidget",
        "ShowPrisonerMap",
        "DisplayMap",
        "DisplayMapScreen",
        "ToggleMap",
        "ToggleMapScreen",
    }
    for _, hud in ipairs(getHudObjects()) do
        if tryAnyMethod(hud, openMethods) then changed = true end
        if tryMethod(hud, "SetMapVisible", true) or tryMethod(hud, "SetMapVisibility", true) then changed = true end
    end
    if tryAnyMethod(getLocalController(), openMethods) then changed = true end
    if tryMethod(getLocalController(), "SetMapVisible", true) or tryMethod(getLocalController(), "SetMapVisibility", true) then changed = true end
    if setHudMode(MAP_HUD_MODE) then changed = true end
    return changed
end

local function releaseInputOnce()
    local controller = getLocalController()
    if not isValidObject(controller) then return end
    safeCall(function()
        controller.bBlockInput = false
        controller.bShowMouseCursor = false
        controller.bEnableClickEvents = false
        controller.bEnableMouseOverEvents = false
        controller.bIgnoreMoveInput = false
        controller.bIgnoreLookInput = false
    end, nil)
    tryMethod(controller, "SetInputModeGameOnly")
    tryMethod(controller, "SetIgnoreMoveInput", false)
    tryMethod(controller, "SetIgnoreLookInput", false)
    tryMethod(controller, "ResetIgnoreMoveInput")
    tryMethod(controller, "ResetIgnoreLookInput")
    tryMethod(controller, "FlushPressedKeys")
    local playerInput = unwrap(safeCall(function() return controller.PlayerInput end, nil))
    tryMethod(playerInput, "FlushPressedKeys")
end

local function runGame(callback)
    if ExecuteInGameThread ~= nil then
        safeCall(function() ExecuteInGameThread(callback) end, nil)
    else
        safeCall(callback, nil)
    end
end

local function schedule(delayMs, callback)
    if delayMs <= 0 or ExecuteWithDelay == nil then
        runGame(callback)
        return
    end
    safeCall(function()
        ExecuteWithDelay(delayMs, function() runGame(callback) end)
    end, nil)
end

local function closeMap(reason)
    local closeMethods = {
        "CloseMap",
        "CloseMapScreen",
        "CloseWorldMap",
        "CloseMapWidget",
        "HideMap",
        "HideMapScreen",
        "HideWorldMap",
        "HideMapWidget",
    }
    for _, hud in ipairs(getHudObjects()) do
        tryAnyMethod(hud, closeMethods)
        tryMethod(hud, "SetMapVisible", false)
        tryMethod(hud, "SetMapVisibility", false)
    end
    tryAnyMethod(getLocalController(), closeMethods)
    tryMethod(getLocalController(), "SetMapVisible", false)
    tryMethod(getLocalController(), "SetMapVisibility", false)
    local changed = setHudMode(NORMAL_HUD_MODE)
    mapOpenedByGuard = false
    releaseInputOnce()
    schedule(120, releaseInputOnce)
    log("map closed: " .. tostring(reason) .. "; hudChanged=" .. tostring(changed))
    return true
end

local function closeMapIfStillMap(reason)
    local mapOpen = vanillaMapLooksOpen()
    if mapOpen then return closeMap(reason) end
    mapOpenedByGuard = false
    return false
end

local function denyMap(reason)
    local now = os.clock()
    if now - lastDenyLogAt > 1.5 then
        lastDenyLogAt = now
        log("map denied: " .. tostring(reason))
    end
    if vanillaMapLooksOpen() then
        closeMap("denied")
    else
        mapOpenedByGuard = false
    end
    schedule(50, function() closeMapIfStillMap("denied delayed 50ms") end)
    schedule(180, function() closeMapIfStillMap("denied delayed 180ms") end)
    schedule(420, function() closeMapIfStillMap("denied delayed 420ms") end)
end

local function openMap(reason)
    local hasItem, hit = hasMapInHands()
    if not hasItem then
        if CONFIG.BlockMapWithoutItem then denyMap(hit) end
        return false
    end
    if not CONFIG.OpenMapWithItem then
        schedule(80, function()
            if not vanillaMapLooksOpen() then return end
            local stillHasItem, stillHit = hasMapInHands()
            if stillHasItem then
                mapOpenedByGuard = true
            elseif CONFIG.BlockMapWithoutItem then
                denyMap("vanilla M guard; " .. tostring(stillHit))
            end
        end)
        return true
    end
    local changed = openHudMap()
    local confirmedOpen = vanillaMapLooksOpen()
    mapOpenedByGuard = changed or confirmedOpen
    schedule(80, function()
        if vanillaMapLooksOpen() then
            mapOpenedByGuard = true
            return
        end
        local stillHasItem = hasMapInHands()
        if stillHasItem then mapOpenedByGuard = openHudMap() or vanillaMapLooksOpen() end
    end)
    schedule(220, function()
        if vanillaMapLooksOpen() then
            mapOpenedByGuard = true
            return
        end
        local stillHasItem = hasMapInHands()
        if stillHasItem then mapOpenedByGuard = openHudMap() or vanillaMapLooksOpen() end
    end)
    log("map opened: " .. tostring(reason) .. "; hit=" .. tostring(hit) .. "; hudChanged=" .. tostring(changed) .. "; confirmed=" .. tostring(confirmedOpen))
    return mapOpenedByGuard
end

local function toggleMap(reason)
    local mapOpen = vanillaMapLooksOpen()
    if not mapOpen then mapOpenedByGuard = false end
    if mapOpen then return closeMap(reason) end
    return openMap(reason)
end

local function guardOpenMap()
    reloadConfigIfNeeded()
    if not CONFIG.Enabled then return end
    local now = os.clock()
    local pollMs = mapOpenedByGuard and CONFIG.GuardPollWhenMapOpenMs or CONFIG.GuardPollMs
    local pollSeconds = math.max(0.25, (tonumber(pollMs) or 1500) / 1000.0)
    if now - lastGuardPollAt < pollSeconds then return end
    lastGuardPollAt = now
    local mapOpen = vanillaMapLooksOpen()
    if not mapOpen then
        mapOpenedByGuard = false
        return
    end
    local hasItem, hit = hasMapInHands()
    if hasItem then
        mapOpenedByGuard = true
    elseif CONFIG.BlockMapWithoutItem then
        denyMap("guard loop; " .. tostring(hit))
    end
end

loadConfig()

if not CONFIG.Enabled then
    log("disabled by config; live reload remains active", true)
end

if RegisterKeyBind ~= nil and Key ~= nil and Key.M ~= nil then
    safeCall(function()
        RegisterKeyBind(Key.M, function()
            runGame(function()
                reloadConfigIfNeeded()
                if not CONFIG.Enabled then return end
                local now = os.clock()
                if now - lastToggleAt < CONFIG.ToggleCooldownSeconds then return end
                lastToggleAt = now
                if not CONFIG.OpenMapWithItem then
                    schedule(80, function()
                        if not vanillaMapLooksOpen() then return end
                        local hasItem, hit = hasMapInHands()
                        if hasItem then
                            mapOpenedByGuard = true
                        elseif CONFIG.BlockMapWithoutItem then
                            denyMap("M key guard; " .. tostring(hit))
                        end
                    end)
                    return
                end
                toggleMap("M key")
            end)
        end)
    end, nil)
else
    log("RegisterKeyBind Key.M is unavailable; guard loop remains active")
end

if LoopAsync ~= nil then
    safeCall(function()
        LoopAsync(LOOP_TICK_MS, function()
            runGame(guardOpenMap)
        end)
    end, nil)
end

log("loaded. Required item in hands: " .. table.concat(REQUIRED_ITEM_IDS, ", "), true)
