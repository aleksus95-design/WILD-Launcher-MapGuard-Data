local okHelpers, UEHelpers = pcall(require, "UEHelpers")
if not okHelpers then
    UEHelpers = nil
end

local TAG = "[NativeMapGate]"

local REQUIRED_ITEM_IDS = {
    "Magnifying_Glass",
    "Magnifying_Glass1",
}

local MAP_HUD_MODE = 2
local NORMAL_HUD_MODE = 0
local TOGGLE_COOLDOWN_SECONDS = 0.45
local DEBUG_LOGS = false
local HUD_CACHE_SECONDS = 0.75
local CONTROLLER_CACHE_SECONDS = 0.25
local HANDS_CACHE_SECONDS = 0.20
local HUD_MODE_DEDUPE_SECONDS = 0.18

local ITEM_TEXT_METHODS = { "GetName", "GetPathName", "GetItemID", "GetItemId", "GetItemName", "GetDisplayName" }
local ITEM_TEXT_PROPERTIES = { "ItemId", "ItemID", "itemId", "ItemName", "Name", "_itemId", "_itemName" }
local HAND_ITEM_METHODS = { "GetItemInHands", "GetItemInHandsOnServer", "GetHeldItem", "GetCurrentItemInHands" }
local HAND_ITEM_PROPERTIES = { "ItemInHands", "_itemInHands", "CurrentItemInHands", "HeldItem", "EquippedItem" }
local HAND_COMPONENT_PROPERTIES = {
    "ItemDragComponent",
    "_itemDragComponent",
    "CharacterItemDragComponent",
    "itemDragComponent",
    "InventoryComponent",
    "_inventoryComponent",
}
local HUD_PROPERTIES = { "MyHUD", "HUD", "Hud", "PrisonerHUD", "PlayerHUD", "_hud", "_prisonerHUD" }
local HUD_METHODS = { "GetHUD", "GetHud", "GetPrisonerHUD", "GetPlayerHUD" }

local lastToggleAt = 0
local lastDenyLogAt = 0
local mapOpenedByMod = false
local hooksRegistered = false
local lastAllowedHit = "none"
local registeredHookPaths = {}
local cachedController = nil
local cachedControllerAt = -100
local cachedHudObjects = {}
local cachedHudObjectsAt = -100
local cachedHandsAt = -100
local cachedHandsHasItem = false
local cachedHandsHit = "required map item is not in hands"
local lastMapRefreshValue = nil
local lastMapRefreshAt = -100
local internalMapRefreshCall = false
local lastHudModeValue = nil
local lastHudModeAt = -100

local function log(message)
    print(string.format("%s %s\n", TAG, tostring(message)))
end

local function debugLog(message)
    if DEBUG_LOGS then
        log(message)
    end
end

local function safeCall(fn, fallback, ...)
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return fallback
end

local function unwrap(value)
    if value == nil then
        return nil
    end

    return safeCall(function()
        if value.get ~= nil then
            return value:get()
        end
        return value
    end, value)
end

local function isValidObject(object)
    if object == nil then
        return false
    end

    return safeCall(function()
        return object.IsValid ~= nil and object:IsValid()
    end, false)
end

local function fullName(object)
    if not isValidObject(object) then
        return ""
    end

    return safeCall(function()
        return object:GetFullName()
    end, tostring(object))
end

local function classPath(object)
    if not isValidObject(object) then
        return nil
    end

    local class = safeCall(function()
        return object:GetClass()
    end, nil)
    if not isValidObject(class) then
        return nil
    end

    local name = fullName(class)
    name = string.gsub(name, "^Class%s+", "")
    name = string.gsub(name, "^BlueprintGeneratedClass%s+", "")
    return name
end

local function normalizedClassPathFromClass(class)
    if not isValidObject(class) then
        return nil
    end

    local name = fullName(class)
    name = string.gsub(name, "^Class%s+", "")
    name = string.gsub(name, "^BlueprintGeneratedClass%s+", "")
    if name == "" then
        return nil
    end
    return name
end

local function controllerClassPaths(controller)
    local paths = {}
    local seen = {}

    local function add(path)
        if path == nil or path == "" or seen[path] then
            return
        end
        seen[path] = true
        table.insert(paths, path)
    end

    add(classPath(controller))

    local class = safeCall(function()
        return controller:GetClass()
    end, nil)
    local depth = 0
    while isValidObject(class) and depth < 16 do
        add(normalizedClassPathFromClass(class))
        class = safeCall(function()
            if class.GetSuperStruct ~= nil then
                return class:GetSuperStruct()
            end
            if class.GetSuperClass ~= nil then
                return class:GetSuperClass()
            end
            return nil
        end, nil)
        depth = depth + 1
    end

    for _, fallback in ipairs({
        "/Script/SCUM.ConZPlayerController",
        "/Script/SCUM.BP_ConZPlayerController_C",
        "/Script/SCUM.PrisonerController",
        "/Script/SCUM.PrisonerPlayerController",
        "/Script/SCUM.ConZBasePlayerController",
        "/Script/Engine.PlayerController",
    }) do
        add(fallback)
    end

    return paths
end

local function containsRequiredItemId(text)
    local source = tostring(text or ""):lower()
    for _, itemId in ipairs(REQUIRED_ITEM_IDS) do
        local clean = tostring(itemId or ""):lower()
        if clean ~= "" and string.find(source, clean, 1, true) then
            return true
        end
    end
    return false
end

local function looksLikeMapItem(object)
    local objectName = fullName(object)
    if containsRequiredItemId(objectName) then
        return true, objectName
    end

    for _, methodName in ipairs(ITEM_TEXT_METHODS) do
        local text = safeCall(function()
            if object ~= nil and object[methodName] ~= nil then
                return tostring(object[methodName](object))
            end
            return ""
        end, "")
        if containsRequiredItemId(text) then
            return true, text
        end
    end

    for _, propertyName in ipairs(ITEM_TEXT_PROPERTIES) do
        local text = tostring(unwrap(safeCall(function()
            if object ~= nil then
                return object[propertyName]
            end
            return nil
        end, nil)) or "")
        if containsRequiredItemId(text) then
            return true, text
        end
    end

    local class = safeCall(function()
        return object:GetClass()
    end, nil)
    local className = fullName(class)
    if containsRequiredItemId(className) then
        return true, className
    end

    return false, objectName
end

local function getLocalController()
    local now = os.clock()
    if now - cachedControllerAt < CONTROLLER_CACHE_SECONDS and isValidObject(cachedController) then
        return cachedController
    end

    local controller = nil
    if UEHelpers ~= nil and UEHelpers.GetPlayerController ~= nil then
        controller = safeCall(function()
            return UEHelpers.GetPlayerController()
        end, nil)
    end

    cachedController = controller
    cachedControllerAt = now
    return controller
end

local function getLocalPrisoner(controller)
    if not isValidObject(controller) then
        return nil
    end

    local prisoner = safeCall(function()
        if controller.GetPrisoner ~= nil then
            return controller:GetPrisoner()
        end
        return nil
    end, nil)
    if isValidObject(prisoner) then
        return prisoner
    end

    return unwrap(safeCall(function()
        return controller.Pawn
    end, nil))
end

local function getItemInHandsFrom(object)
    if not isValidObject(object) then
        return nil
    end

    for _, methodName in ipairs(HAND_ITEM_METHODS) do
        local item = safeCall(function()
            if object[methodName] ~= nil then
                return object[methodName](object)
            end
            return nil
        end, nil)
        if isValidObject(item) then
            return item
        end
    end

    for _, propertyName in ipairs(HAND_ITEM_PROPERTIES) do
        local item = unwrap(safeCall(function()
            return object[propertyName]
        end, nil))
        if isValidObject(item) then
            return item
        end
    end

    for _, componentName in ipairs(HAND_COMPONENT_PROPERTIES) do
        local component = unwrap(safeCall(function()
            return object[componentName]
        end, nil))
        if isValidObject(component) then
            for _, methodName in ipairs(HAND_ITEM_METHODS) do
                local item = safeCall(function()
                    if component[methodName] ~= nil then
                        return component[methodName](component)
                    end
                    return nil
                end, nil)
                if isValidObject(item) then
                    return item
                end
            end
        end
    end

    return nil
end

local function hasMapInHands(forceRefresh)
    local now = os.clock()
    if not forceRefresh and now - cachedHandsAt < HANDS_CACHE_SECONDS then
        return cachedHandsHasItem, cachedHandsHit
    end

    local controller = getLocalController()
    local prisoner = getLocalPrisoner(controller)
    local pawn = unwrap(safeCall(function()
        return controller.Pawn
    end, nil))

    for _, source in ipairs({ prisoner, pawn, controller }) do
        local item = getItemInHandsFrom(source)
        local ok, hit = looksLikeMapItem(item)
        if ok then
            cachedHandsAt = now
            cachedHandsHasItem = true
            cachedHandsHit = hit
            return true, hit
        end
    end

    cachedHandsAt = now
    cachedHandsHasItem = false
    cachedHandsHit = "required map item is not in hands"
    return false, "required map item is not in hands"
end

local function tryMethod(object, methodName, ...)
    if not isValidObject(object) then
        return false
    end

    return safeCall(function(...)
        local method = object[methodName]
        if method == nil then
            return false
        end
        method(object, ...)
        return true
    end, false, ...)
end

local function tryAnyMethod(object, methodNames, ...)
    local changed = false
    for _, methodName in ipairs(methodNames) do
        if tryMethod(object, methodName, ...) then
            changed = true
        end
    end
    return changed
end

local function getHudObjects()
    local now = os.clock()
    if now - cachedHudObjectsAt < HUD_CACHE_SECONDS then
        return cachedHudObjects
    end

    local huds = {}
    local seen = {}

    local function add(object)
        object = unwrap(object)
        if not isValidObject(object) then
            return
        end
        local key = fullName(object)
        if key == "" then
            key = tostring(object)
        end
        if seen[key] then
            return
        end
        seen[key] = true
        table.insert(huds, object)
    end

    local controller = getLocalController()
    for _, propertyName in ipairs(HUD_PROPERTIES) do
        add(safeCall(function()
            return controller[propertyName]
        end, nil))
    end

    for _, methodName in ipairs(HUD_METHODS) do
        add(safeCall(function()
            if controller[methodName] ~= nil then
                return controller[methodName](controller)
            end
            return nil
        end, nil))
    end

    cachedHudObjects = huds
    cachedHudObjectsAt = now
    return huds
end

local function getHudMode(hud)
    return safeCall(function()
        if hud.GetHUDMode ~= nil then
            return hud:GetHUDMode()
        end
        if hud.GetHudMode ~= nil then
            return hud:GetHudMode()
        end
        return nil
    end, nil)
end

local function isMapHudMode(mode)
    local raw = unwrap(mode)
    if type(raw) == "number" then
        return raw == 2 or raw == 4
    end

    local text = tostring(raw)
    return string.find(text, "EPrisonerHUDMode::Map", 1, true) ~= nil
        or string.find(text, "EPrisonerHUDMode::DroneMap", 1, true) ~= nil
end

local function vanillaMapLooksOpen()
    for _, hud in ipairs(getHudObjects()) do
        local mode = getHudMode(hud)
        if isMapHudMode(mode) then
            return true, tostring(unwrap(mode))
        end
    end
    return false, "no map HUD mode"
end

local function runGame(callback)
    if ExecuteInGameThread ~= nil then
        safeCall(function()
            ExecuteInGameThread(callback)
        end, nil)
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
        ExecuteWithDelay(delayMs, function()
            runGame(callback)
        end)
    end, nil)
end

local function setHudMode(mode)
    local now = os.clock()
    if lastHudModeValue == mode and now - lastHudModeAt < HUD_MODE_DEDUPE_SECONDS then
        return false
    end

    local changed = false
    for _, hud in ipairs(getHudObjects()) do
        if tryMethod(hud, "SetHUDMode", mode) or tryMethod(hud, "SetHudMode", mode) then
            changed = true
            debugLog("called HUD SetHUDMode(" .. tostring(mode) .. ") on " .. fullName(hud))
        end
    end

    local controller = getLocalController()
    if tryAnyMethod(controller, { "SetHUDMode", "SetHudMode", "SetPrisonerHUDMode" }, mode) then
        changed = true
        debugLog("called controller HUD mode method(" .. tostring(mode) .. ") on " .. fullName(controller))
    end

    if changed then
        lastHudModeValue = mode
        lastHudModeAt = now
    end

    return changed
end

local function callMapRefresh(enabled)
    local now = os.clock()
    if lastMapRefreshValue == enabled and now - lastMapRefreshAt < 0.75 then
        return false
    end

    local controller = getLocalController()
    local changed = false
    internalMapRefreshCall = true
    if tryMethod(controller, "Server_SetRefreshPawnLocationForMap", enabled) then
        changed = true
        lastMapRefreshValue = enabled
        lastMapRefreshAt = now
        debugLog("called Server_SetRefreshPawnLocationForMap(" .. tostring(enabled) .. ")")
    end
    internalMapRefreshCall = false
    return changed
end

local function openHudMap()
    local changed = false
    if setHudMode(MAP_HUD_MODE) then
        changed = true
    end
    if callMapRefresh(true) then
        changed = true
    end

    return changed
end

local function releaseInputOnce(reason)
    local controller = getLocalController()
    if not isValidObject(controller) then
        return
    end

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

    local playerInput = unwrap(safeCall(function()
        return controller.PlayerInput
    end, nil))
    tryMethod(playerInput, "FlushPressedKeys")
end

local function closeMap(reason, suppressDelayedGuard)
    callMapRefresh(false)
    setHudMode(NORMAL_HUD_MODE)

    mapOpenedByMod = false
    releaseInputOnce(reason)
    schedule(120, function()
        releaseInputOnce(reason .. " delayed")
    end)

    log("map closed: " .. tostring(reason))

    if not suppressDelayedGuard then
        for _, delayMs in ipairs({ 180, 650 }) do
            schedule(delayMs, function()
                if vanillaMapLooksOpen() then
                    closeMap(tostring(reason) .. " delayed close guard", true)
                else
                    releaseInputOnce(tostring(reason) .. " delayed input guard")
                end
            end)
        end
    end

    return true
end

local function denyMap(reason)
    local now = os.clock()
    if now - lastDenyLogAt > 1.5 then
        lastDenyLogAt = now
        log("map denied: " .. tostring(reason))
    end

    if vanillaMapLooksOpen() or mapOpenedByMod then
        closeMap("denied")
    else
        mapOpenedByMod = false
    end

    for _, delayMs in ipairs({ 160, 480 }) do
        schedule(delayMs, function()
            local hasItem = hasMapInHands(true)
            if hasItem then
                return
            end
            if vanillaMapLooksOpen() or mapOpenedByMod then
                closeMap("denied delayed")
            end
        end)
    end
end

local function openMap(reason)
    local hasItem, hit = hasMapInHands(true)
    if not hasItem then
        denyMap(hit)
        return false
    end

    lastAllowedHit = tostring(hit)
    local changed = openHudMap()
    local confirmed, mode = vanillaMapLooksOpen()
    mapOpenedByMod = changed or confirmed

    for _, delayMs in ipairs({ 280 }) do
        schedule(delayMs, function()
            local stillHasItem = hasMapInHands(true)
            if stillHasItem then
                if not vanillaMapLooksOpen() then
                    openHudMap()
                else
                    callMapRefresh(true)
                end
            else
                denyMap("item removed while map is open")
            end
        end)
    end

    log("native map open requested: " .. tostring(reason) .. "; hit=" .. lastAllowedHit .. "; changed=" .. tostring(changed) .. "; confirmed=" .. tostring(confirmed) .. "; mode=" .. tostring(mode))
    return mapOpenedByMod
end

local function toggleMap(reason)
    local mapOpen = vanillaMapLooksOpen()
    if mapOpenedByMod then
        return closeMap(reason)
    end

    if mapOpen then
        local hasItem, hit = hasMapInHands(true)
        if hasItem then
            lastAllowedHit = tostring(hit)
            mapOpenedByMod = true
            callMapRefresh(true)
        log("native map adopted from vanilla input: " .. tostring(reason) .. "; hit=" .. lastAllowedHit)
        return true
        end
        denyMap(hit)
        return false
    end

    return openMap(reason)
end

local function tryRegisterHook(path, callback)
    if RegisterHook == nil then
        return false
    end

    if registeredHookPaths[path] then
        return true
    end

    local ok = safeCall(function()
        RegisterHook(path, callback)
        return true
    end, false)

    if ok then
        registeredHookPaths[path] = true
        log("hook registered: " .. path)
    else
        log("hook failed: " .. path)
    end
    return ok
end

local function registerDynamicHooks()
    if hooksRegistered then
        return
    end

    local controller = getLocalController()
    if not isValidObject(controller) then
        debugLog("dynamic hooks wait: no local controller")
        return
    end

    local currentPath = classPath(controller)
    debugLog("local controller class: " .. tostring(currentPath))
    if currentPath == nil or string.find(currentPath, "MenuPlayerController", 1, true) then
        return
    end

    local any = false
    for _, path in ipairs({ "/Script/SCUM.ConZPlayerController" }) do
        any = tryRegisterHook(path .. ":Server_SetRefreshPawnLocationForMap", function(self, requestedParam)
            if internalMapRefreshCall then
                return
            end
            runGame(function()
                local requested = unwrap(requestedParam)
                if requested == false then
                    return
                end
            local hasItem, hit = hasMapInHands()
            if hasItem then
                debugLog("map refresh allowed by item: " .. tostring(hit))
                else
                    denyMap("Server_SetRefreshPawnLocationForMap; " .. tostring(hit))
                end
            end)
        end) or any

        any = tryRegisterHook(path .. ":Client_SendPackedPlayerLocationsForMap", function()
            runGame(function()
            local hasItem, hit = hasMapInHands()
            if hasItem then
                debugLog("packed map locations allowed by item: " .. tostring(hit))
                else
                    denyMap("Client_SendPackedPlayerLocationsForMap; " .. tostring(hit))
                end
            end)
        end) or any
    end

    hooksRegistered = any
end

local function status()
    runGame(function()
        registerDynamicHooks()
        local controller = getLocalController()
        local huds = getHudObjects()
        local hasItem, hit = hasMapInHands()
        local open, mode = vanillaMapLooksOpen()
        log(string.format(
            "status: controller=%s huds=%d hasItemInHands=%s hit=%s nativeMapOpen=%s hudMode=%s lastAllowedHit=%s hooksRegistered=%s",
            tostring(classPath(controller)),
            #huds,
            tostring(hasItem),
            tostring(hit),
            tostring(open),
            tostring(mode),
            tostring(lastAllowedHit),
            tostring(hooksRegistered)
        ))
    end)
end

if RegisterKeyBind ~= nil and Key ~= nil and Key.M ~= nil then
    RegisterKeyBind(Key.M, function()
        runGame(function()
            registerDynamicHooks()
            local now = os.clock()
            if now - lastToggleAt < TOGGLE_COOLDOWN_SECONDS then
                return
            end
            lastToggleAt = now
            toggleMap("M key")
        end)
    end)
else
    log("RegisterKeyBind M unavailable")
end

if RegisterKeyBind ~= nil and Key ~= nil and Key.F10 ~= nil then
    RegisterKeyBind(Key.F10, status)
end

tryRegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    runGame(function()
        log("ClientRestart observed")
        registerDynamicHooks()
    end)
end)

log("loaded. Native map gate by item in hands: " .. table.concat(REQUIRED_ITEM_IDS, ", ") .. ". F10=status.")
