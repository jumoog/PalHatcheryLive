-- ============================================================================
-- PalHatcheryLive — keeps the Hatchery (Incubator) UI live while it is open.
-- UE4SS (Okaetsu fork, v3.0.1) Lua mod. Palworld 1.0.
--
-- WHAT IT DOES
--   Vanilla builds the incubator panel once, when it opens. If an egg finishes
--   while you are standing in that panel, the rows and the "collect hatched
--   Pals" button keep showing the state from the moment you opened it — you
--   have to close and re-open before you can collect.
--
--   For every incubator panel that is currently on screen (the world HUD over
--   the machine as well as the big interaction panel), this mod:
--     1. re-runs the panel's OWN display-update functions when something
--        actually changes — panel opened, hatch notify hook fired, or the
--        model's hatched-slot count moved,
--     2. never on a fixed interval: re-poking a panel whose state has not
--        changed re-applies its "complete" presentation and makes the collect
--        button flicker,
--     3. un-greys the collect button on such a transition, and only if the
--        button really is disabled.
--
--   Collecting stays vanilla — you click the button. AUTO_COLLECT = true makes
--   the mod send RequestObtainAllHatchedCharacter itself.
--
-- HOW THE NAMES ARE FOUND
--   Panel update functions are Blueprint-side, so their names live in the
--   (Oodle-compressed) game assets, not in the executable. Instead of guessing,
--   the mod asks each class what it has (ForEachFunction) and calls only names
--   that look like a display update and cannot be an action. Candidates that
--   turn out to need parameters raise a catchable UE4SS error and are dropped
--   for good. What that found live on Palworld 1.0 (DE client):
--     WBP_IngameMenu_Incubator_Multiple_C  -> OnEggArrayUpdated()
--     WBP_Ingame_Incubator_Multiple_C      -> OnEggArrayUpdated(), UpdateSimpleSlot()
--     WBP_Ingame_Incubator_C               -> UpdateEggDisplay()
--   The per-slot updates (OnSlotContentUpdate, "On Update Work Amount") all
--   take parameters, so the panel-level egg-array update is the entry point.
--
-- SAFETY
--   This runs on the game thread and touches live widgets, so an uncaught Lua
--   error is a game crash. Every game-object access is pcall-wrapped and every
--   object is IsValid()-checked before a member call: UE4SS returns a WRAPPER
--   (not nil) for a null/stale UObject, and the access violation from calling
--   a member on it is native — pcall cannot catch that.
--
--   No property is ever read blind by name (reading e.g. a SoftObjectProperty
--   can access-violate inside UE4SS); only reflected ObjectProperty values are
--   read.
--
-- DIAGNOSTICS
--   The first time a given panel class shows up, a full reflection dump goes
--   into UE4SS.log (class chain, functions, properties, widget tree with labels
--   and enabled/visibility state, model class chain). F8 repeats it for every
--   panel currently on screen.
-- ============================================================================

local VERSION = "1.5.1"

local CONFIG = {
    -- Tick cadence (ms). Scanning for panels is the expensive part (one full
    -- UObject-array sweep per class), so it happens on a slow multiple of the
    -- tick: every 8 ticks (~4s) while nothing is open, every 12 (~6s) to notice
    -- a second panel opening on top of one already being serviced.
    POLL_MS = 500,
    IDLE_EVERY_NTH_TICK = 8,
    RESCAN_EVERY_NTH_TICK = 12,

    -- Refreshes are CHANGE-DRIVEN, not periodic: on panel open, on a hatch
    -- notify hook, and when the model's hatched-slot count changes (polled with
    -- a cheap native getter every tick — that costs nothing and never touches
    -- the UI). Re-poking the panel on a fixed interval made the finished-state
    -- button flicker, because re-running the panel's update re-applies its
    -- "complete" presentation (these widgets carry Anm_* animations).
    --
    -- Heartbeat fallback, used ONLY for panels whose model exposes no
    -- hatched-state readout (the single-egg incubator has no
    -- GetHatchedStateArray), i.e. where there is no change detector. 0 = off.
    HEARTBEAT_MS = 15000,

    -- Which reflected functions count as "redraw the display". Allow-list by
    -- name shape, then a hard deny-list of anything that could act rather than
    -- display (RPCs, clicks, teardown, audio, animation, setters).
    REFRESH_ALLOW = { "[Uu]pdate", "^Refresh", "^Reflect", "^Redraw" },
    REFRESH_DENY = {
        "Server", "Client", "Request", "Obtain", "Send", "Notify", "RPC",
        "Click", "Press", "Push", "Decide", "Select", "Commit", "Apply",
        "Close", "Open", "Destroy", "Destruct", "Remove", "Delete", "Clear",
        "Construct", "Tick", "Sound", "Anim", "Fade", "Cursor", "Focus",
        "Input", "Key", "Gamepad", "Scroll", "Drag", "Set", "Add", "Start",
        "Stop", "Exec", "Save", "Load", "Delegate",
    },

    -- Un-grey the collect button when the model reports hatched pals.
    --
    -- OFF by default, because on this build there is nothing to un-grey: the
    -- dump of WBP_CommonButton_C shows it derives straight from UserWidget, not
    -- from CommonButtonBase — it has no enabled/disabled state at all
    -- (GetIsInteractionEnabled does not even exist on it, GetIsEnabled is
    -- always true). Its look is driven by animations (Anm_DefaultToRed,
    -- AnmEvent_Red/Normal/Focus), which is also why re-poking the panel while
    -- the state sat still replayed that animation and looked like flicker.
    -- Kept for other builds/locales where a panel really does gate its button.
    ENABLE_BUTTONS = false,
    -- Preferred path: the panel names its buttons as reflected properties.
    -- Verified on WBP_IngameMenu_Incubator_Multiple_C: WBP_CommonButton_OpenAll
    -- ("collect all", bound to ..._OpenAll_..._OnClicked) next to
    -- WBP_CommonButton_SetAll ("set all eggs") — which we deliberately leave
    -- alone.
    COLLECT_BUTTON_PROPS = { "WBP_CommonButton_OpenAll" },
    -- Fallback when no named property matches: scan for a disabled button whose
    -- label matches one of these (lower-case Lua patterns). Every disabled
    -- button's label is logged once, so a missing language can be added here.
    COLLECT_LABELS = { "collect", "einsammeln", "abholen", "erhalten" },

    -- Widget subtrees never worth walking: the incubator panel embeds the whole
    -- player inventory, which is hundreds of nodes of unrelated item slots.
    PRUNE_CLASSES = { "Inventory", "ItemSlot" },

    -- Press collect for you instead of only enabling the button.
    AUTO_COLLECT = false,

    -- Reflection dump: once per panel class, and on demand via DUMP_KEY.
    DUMP_ON_FIRST_OPEN = true,
    DUMP_KEY = "F8",
}

-- Panel classes we handle. Palworld has one widget per incubator kind, and the
-- world HUD over the machine can be on screen at the same time as the big
-- interaction panel — so ALL visible ones are serviced, not just the first.
-- The _C suffix is required: FindAllOf finds nothing for BP classes without it.
local MENU_CLASSES = {
    "WBP_IngameMenu_Incubator_Multiple_C", -- interaction panel, multi hatchery
    "WBP_Ingame_Incubator_Multiple_C",     -- world HUD, multi hatchery
    "WBP_Ingame_Incubator_C",              -- world HUD, single incubator
}
-- Deliberately NOT serviced: WBP_Ingame_Incubator_AllOpen_C. Its dump showed it
-- derives from PalUIObtainCharactersPerformance and holds `Hatched IDs` /
-- `HatchedList` plus a Close button and open/close animations — it is the
-- "these Pals hatched" result screen shown AFTER collecting, built once from
-- the collect result. It has no refresh function and no model, so servicing it
-- was pure overhead plus two misleading warnings per appearance.

-- Native model behind a panel: hatch state and the collect RPC live here.
-- Verified: WBP_Ingame_Incubator_C.Model -> PalMapObjectHatchingEggModel.
local MODEL_BASE_CLASS = "/Script/Pal.PalMapObjectHatchingEggModelBase"

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------
local function log(msg)
    print(string.format("[PalHatcheryLive] %s\n", msg))
end

local logged = {}
local function logOnce(tag, msg)
    if logged[tag] then return end
    logged[tag] = true
    log(msg)
end

log(string.format("v%s loading...", VERSION))

-- ---------------------------------------------------------------------------
-- Guarded object helpers
-- ---------------------------------------------------------------------------

-- The only gate we trust before touching a game object (see SAFETY above).
local function alive(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local function nameOf(obj)
    if not alive(obj) then return nil end
    local n = nil
    pcall(function() n = obj:GetFName():ToString() end)
    return n
end

local function classNameOf(obj)
    if not alive(obj) then return nil end
    local n = nil
    pcall(function() n = obj:GetClass():GetFName():ToString() end)
    return n
end

local function fullNameOf(obj)
    local n = nil
    pcall(function() n = obj:GetFullName() end)
    return n
end

-- Iterate a UE4SS TArray. ForEach hands a RemoteUnrealParam, so unwrap via
-- :get(); falls back to numeric indexing, then gives up quietly.
local function arrayForEach(arr, fn)
    if arr == nil then return false end
    local ok = pcall(function()
        arr:ForEach(function(_, elem)
            local v = elem
            local okg, got = pcall(function() return elem:get() end)
            if okg then v = got end
            fn(v)
        end)
    end)
    if ok then return true end
    return pcall(function()
        local n = nil
        pcall(function() n = arr:GetArrayNum() end)
        if n == nil then n = #arr end
        for i = 1, n do fn(arr[i]) end
    end)
end

-- ---------------------------------------------------------------------------
-- Widget tree walking
-- ---------------------------------------------------------------------------

-- Subtrees that are never relevant (the embedded player inventory). Pruning
-- them is what keeps the walk inside its budget: without it, the item slots
-- ate the whole budget before the walk ever reached the panel's own buttons.
local function isPruned(cn)
    if not cn then return false end
    for _, pat in ipairs(CONFIG.PRUNE_CLASSES) do
        if cn:find(pat) then return true end
    end
    return false
end

-- Visit every widget below `w`. UUserWidget children live in their own
-- WidgetTree, panel widgets expose GetChildrenCount/GetChildAt; both paths are
-- tried, both are guarded, and `budget` caps the walk so a pathological tree
-- cannot spin the game thread.
local function walkWidgets(w, fn, depth, budget)
    depth = depth or 0
    budget = budget or { n = 800 }
    if not alive(w) or depth > 12 or budget.n <= 0 then return end
    if depth > 0 and isPruned(classNameOf(w)) then return end
    budget.n = budget.n - 1

    fn(w, depth)

    local tree = nil
    pcall(function() tree = w.WidgetTree end)
    if alive(tree) then
        local root = nil
        pcall(function() root = tree.RootWidget end)
        if alive(root) then walkWidgets(root, fn, depth + 1, budget) end
    end

    local n = nil
    pcall(function() n = w:GetChildrenCount() end)
    if type(n) == "number" and n > 0 and n < 200 then
        for i = 0, n - 1 do
            local child = nil
            pcall(function() child = w:GetChildAt(i) end)
            if alive(child) then walkWidgets(child, fn, depth + 1, budget) end
        end
    end
end

-- Concatenated, lower-cased text of every text widget below `w` — used to
-- identify a button by its label.
local function widgetLabel(w)
    local parts = {}
    walkWidgets(w, function(node)
        local txt = nil
        pcall(function() txt = node:GetText():ToString() end)
        if type(txt) == "string" and #txt > 0 then parts[#parts + 1] = txt end
    end, 0, { n = 80 })
    return string.lower(table.concat(parts, " "))
end

-- ---------------------------------------------------------------------------
-- Class reflection helpers
-- ---------------------------------------------------------------------------

-- Walk the class chain of `obj`, calling fn(class, className) per level, and
-- stop at the engine base classes (only the game's own layers matter to us).
local function forEachClassInChain(obj, fn)
    local cls = nil
    pcall(function() cls = obj:GetClass() end)
    local guard = 0
    while alive(cls) and guard < 16 do
        guard = guard + 1
        local cname = nameOf(cls)
        fn(cls, cname)
        if cname == "UserWidget" or cname == "Widget" or cname == "Object" then return end
        local sup = nil
        pcall(function() sup = cls:GetSuperStruct() end)
        cls = sup
    end
end

-- ---------------------------------------------------------------------------
-- Panel discovery
-- ---------------------------------------------------------------------------
local function isShowing(w)
    local ok, vis = pcall(function() return w:IsVisible() end)
    if not ok then return true end -- probe unavailable: assume shown
    return vis == true
end

-- Every visible incubator panel right now. Several instances of a class can
-- coexist (a stale hidden one next to the live one), so visibility is required.
--
-- Each FindAllOf sweeps the whole UObject array, so this is the single most
-- expensive thing the mod does: classes we already service are skipped, and the
-- caller keeps the scan rate low.
local function findMenus(skipClasses)
    local out = {}
    for _, cls in ipairs(MENU_CLASSES) do
        if not (skipClasses and skipClasses[cls]) then
            local found = nil
            pcall(function() found = FindAllOf(cls) end)
            if found then
                for _, w in ipairs(found) do
                    if alive(w) then
                        local fn = fullNameOf(w)
                        if fn and not fn:find("Default__", 1, true) and isShowing(w) then
                            out[#out + 1] = { widget = w, class = cls, id = fn }
                        end
                    end
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Refresh-function resolution
-- ---------------------------------------------------------------------------
local refreshCache = {} -- class name -> array of function names
local dropped = {}      -- "class.function" -> true once a call failed

local function nameLooksLikeRefresh(n)
    if type(n) ~= "string" or #n == 0 then return false end
    for _, deny in ipairs(CONFIG.REFRESH_DENY) do
        if n:find(deny) then return false end
    end
    for _, allow in ipairs(CONFIG.REFRESH_ALLOW) do
        if n:find(allow) then return true end
    end
    return false
end

-- Cached list of refresh-candidate function names for this object's class.
local function refreshNamesFor(obj)
    local cn = classNameOf(obj)
    if cn == nil then return {} end
    if refreshCache[cn] then return refreshCache[cn] end

    local names, seen = {}, {}
    forEachClassInChain(obj, function(cls)
        pcall(function()
            cls:ForEachFunction(function(fn)
                local n = nameOf(fn)
                if n and not seen[n] and nameLooksLikeRefresh(n) then
                    seen[n] = true
                    names[#names + 1] = n
                end
            end)
        end)
    end)

    refreshCache[cn] = names
    log(string.format("refresh candidates on %s: %s", cn,
        #names > 0 and table.concat(names, ", ") or "(none)"))
    return names
end

-- Call a reflected, zero-parameter function by name. Returns true if it ran.
local function callNoArg(obj, cn, fname)
    local key = cn .. "." .. fname
    if dropped[key] then return false end

    local f = nil
    local okGet = pcall(function() f = obj[fname] end)
    if not okGet or f == nil then
        dropped[key] = true
        return false
    end

    local okCall, err = pcall(function() f() end)
    if not okCall then
        -- Parameter-count mismatch or a Blueprint-side error: drop it for good.
        dropped[key] = true
        -- UE4SS appends a Lua traceback; keep only the first line.
        local msg = tostring(err):gsub("\n.*", "")
        logOnce("drop:" .. key, string.format("dropped %s (%s)", key, msg))
        return false
    end
    logOnce("call:" .. key, "refresh via " .. key .. "()")
    return true
end

-- The incubator's own sub-widgets, collected ONCE per panel open.
--
-- This used to be a full widget-tree walk on every refresh — hundreds of
-- reflection calls (GetClass/GetFName/ToString per node) every interval, on the
-- game thread. That is what made the game hitch once per interval. The tree of
-- an open panel does not change identity, so it is walked once and cached; a
-- dead entry invalidates the cache and triggers a single re-walk.
local function resolveSubWidgets(menu)
    local out = {}
    walkWidgets(menu, function(w)
        local cn = classNameOf(w)
        if cn and cn:find("_C$") and cn:find("Incubator") then
            out[#out + 1] = { widget = w, class = cn }
        end
    end)
    return out
end

-- Re-run one panel's own display update (the panel itself plus its slot rows).
local function refreshPanel(st)
    local menu = st.widget
    local ran = 0

    local mcn = classNameOf(menu)
    if mcn then
        for _, fname in ipairs(refreshNamesFor(menu)) do
            if callNoArg(menu, mcn, fname) then ran = ran + 1 end
        end
    end

    if st.subWidgets == nil then st.subWidgets = resolveSubWidgets(menu) end
    for _, sub in ipairs(st.subWidgets) do
        if not alive(sub.widget) then
            st.subWidgets = nil -- stale tree: re-walk once, next interval
            break
        end
        for _, fname in ipairs(refreshNamesFor(sub.widget)) do
            if callNoArg(sub.widget, sub.class, fname) then ran = ran + 1 end
        end
    end

    if ran == 0 then
        logOnce("norefresh:" .. tostring(mcn),
            "no usable refresh function on " .. tostring(mcn) .. " — press " ..
            CONFIG.DUMP_KEY .. " with the panel open and keep UE4SS.log")
    end
    return ran
end

-- ---------------------------------------------------------------------------
-- Model resolution + hatch state
--
-- The panel holds the map-object model it displays (verified: property `Model`).
-- Only reflected ObjectProperty values are read — see SAFETY.
-- ---------------------------------------------------------------------------
local function objectPropertyNames(obj)
    local names = {}
    forEachClassInChain(obj, function(cls)
        pcall(function()
            cls:ForEachProperty(function(prop)
                local isObj = false
                pcall(function() isObj = prop:IsA(PropertyTypes.ObjectProperty) end)
                if isObj then
                    local n = nameOf(prop)
                    if n then names[#names + 1] = n end
                end
            end)
        end)
    end)
    return names
end

local function looksLikeModel(o)
    if not alive(o) then return false end
    local isit = false
    pcall(function() isit = o:IsA(MODEL_BASE_CLASS) end)
    if isit then return true end
    local cn = classNameOf(o)
    return cn ~= nil and cn:find("HatchingEggModel") ~= nil
end

-- Which property of a panel class holds its model. The panel INSTANCE is
-- recreated on every open (its full name changes, so an instance cache misses),
-- but the property name is a property of the class and never changes:
-- learn it once, then resolving a model is a single read instead of a widget
-- walk plus a full ObjectProperty enumeration.
--   WBP_IngameMenu_Incubator_Multiple_C -> "Hatching Egg Model"
--   WBP_Ingame_Incubator_Multiple_C     -> "Model"
--   WBP_Ingame_Incubator_C              -> "Model"
local modelPropByClass = {}

local function resolveModel(menu)
    local mcn = classNameOf(menu)

    local known = mcn and modelPropByClass[mcn]
    if known then
        local val = nil
        pcall(function() val = menu[known] end)
        if looksLikeModel(val) then return val end
        -- Class changed shape (game patch): forget and fall through to the scan.
        modelPropByClass[mcn] = nil
    end

    local holders = { menu }
    walkWidgets(menu, function(w)
        local cn = classNameOf(w)
        if cn and (cn:find("Incubator") or cn:find("Egg")) then holders[#holders + 1] = w end
    end)

    for _, holder in ipairs(holders) do
        for _, pname in ipairs(objectPropertyNames(holder)) do
            local val = nil
            pcall(function() val = holder:GetPropertyValue(pname) end)
            if looksLikeModel(val) then
                -- Remember the shortcut, but only when the model hangs off the
                -- panel itself — a sub-widget's property is not reachable
                -- without walking to that sub-widget again.
                if holder == menu and mcn then modelPropByClass[mcn] = pname end
                -- Once per class: the world HUD opens and closes constantly as
                -- the player moves past a machine, and re-logging every time
                -- floods UE4SS.log during normal play.
                logOnce("model:" .. tostring(mcn),
                    string.format("model found via %s.%s (%s)",
                        classNameOf(holder) or "?", pname, classNameOf(val) or "?"))
                return val
            end
        end
    end

    -- Fallback: a single hatchery in the world is unambiguous.
    local live = {}
    for _, cls in ipairs({ "PalMapObjectMultiHatchingEggModel", "PalMapObjectHatchingEggModel" }) do
        local models = nil
        pcall(function() models = FindAllOf(cls) end)
        if models then
            for _, m in ipairs(models) do
                local fn = alive(m) and fullNameOf(m) or nil
                if fn and not fn:find("Default__", 1, true) then live[#live + 1] = m end
            end
        end
    end
    if #live == 1 then
        log("model found via world search (single hatchery)")
        return live[1]
    end

    logOnce("model-none:" .. tostring(classNameOf(menu)), string.format(
        "model not resolvable for %s (%d candidates) — refresh still runs, button " ..
        "un-greying stays off", tostring(classNameOf(menu)), #live))
    return nil
end

-- Number of slots reporting a hatched pal, or nil when that is not readable
-- (the single-egg model has no GetHatchedStateArray — that is expected).
local function hatchedCount(model)
    if not alive(model) then return nil end
    local arr = nil
    local ok = pcall(function() arr = model:GetHatchedStateArray() end)
    if not ok or arr == nil then
        logOnce("nostatearray:" .. tostring(classNameOf(model)),
            "GetHatchedStateArray unavailable on " .. tostring(classNameOf(model)) ..
            " — relying on the hatch notify hooks")
        return nil
    end
    local n = 0
    arrayForEach(arr, function(v)
        if v == true or v == 1 then n = n + 1 end
    end)
    return n
end

-- ---------------------------------------------------------------------------
-- Hatch notify hooks
--
-- The exact notify names differ per model class, so they are resolved from the
-- model's own class chain the first time a model shows up, instead of being
-- guessed from a hardcoded list.
-- ---------------------------------------------------------------------------
local hatchSignal = false
local hookedFns = {}

-- Verified on this build: PalMapObjectHatchingEggModelBase has
-- NotifyHatchComplete_ClientInternal, NotifyHatchFailed_NoEmptySlot_ClientInternal
-- and OnRepEggInfoArray (fires whenever the slot/egg state replicates to the
-- client — the tightest "something changed" signal there is). The exe also
-- mentions NotifyMultiHatchComplete_ToClient, which does NOT exist on this
-- build's class chain, hence discovery instead of a hardcoded list.
local function hookHatchNotifies(model)
    forEachClassInChain(model, function(cls, cname)
        if not cname or cname:sub(1, 3) ~= "Pal" then return end
        pcall(function()
            cls:ForEachFunction(function(fn)
                local n = nameOf(fn)
                if not n then return end
                if not (n:find("Hatch") or n:find("EggInfoArray") or n:find("EggArray")) then return end
                if not (n:find("^Notify") or n:find("^OnRep")) then return end
                local target = "/Script/Pal." .. cname .. ":" .. n
                if hookedFns[target] then return end
                hookedFns[target] = true
                local ok, err = pcall(function()
                    RegisterHook(target, function()
                        hatchSignal = true -- plain Lua write; the tick reacts
                    end)
                end)
                if ok then
                    log("hatch hook: " .. target)
                else
                    log("hatch hook failed (" .. target .. "): " ..
                        tostring(err):gsub("\n.*", ""))
                end
            end)
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Collect button
-- ---------------------------------------------------------------------------
local function labelMatches(label)
    if #CONFIG.COLLECT_LABELS == 0 then return true end
    for _, pat in ipairs(CONFIG.COLLECT_LABELS) do
        if label:find(pat) then return true end
    end
    return false
end

-- Enable one button widget, and ONLY if it is actually disabled.
--
-- Writing the flag unconditionally is what made the button flicker once per
-- refresh interval: SetIsEnabled/SetIsInteractionEnabled re-apply the CommonUI
-- button style even when the value does not change. Since this button reports
-- enabled=true even with an empty hatchery, the unconditional write was a pure
-- cosmetic defect with no upside. Returns true when the button is usable —
-- whether we had to touch it or not.
local function enableButton(w, why)
    local enabled, interaction = nil, nil
    pcall(function() enabled = w:GetIsEnabled() end)
    pcall(function() interaction = w:GetIsInteractionEnabled() end)

    -- Already usable: leave it completely alone.
    if enabled ~= false and interaction ~= false then return true end

    if enabled == false then pcall(function() w:SetIsEnabled(true) end) end
    if interaction == false then pcall(function() w:SetIsInteractionEnabled(true) end) end

    local after = nil
    pcall(function() after = w:GetIsEnabled() end)
    logOnce("enable:" .. tostring(classNameOf(w)) .. ":" .. why,
        string.format("collect button (%s, %s): enabled %s/interaction %s -> %s",
            why, tostring(classNameOf(w)), tostring(enabled), tostring(interaction),
            tostring(after)))
    return after == true
end

-- Preferred path: the panel exposes its buttons as named ObjectProperties, so
-- no tree walk and no language-dependent label matching is needed.
local function enableNamedCollectButtons(menu)
    local touched = 0
    for _, pname in ipairs(CONFIG.COLLECT_BUTTON_PROPS) do
        local btn = nil
        local ok = pcall(function() btn = menu[pname] end)
        if ok and alive(btn) then
            if enableButton(btn, pname) then touched = touched + 1 end
        end
    end
    return touched
end

-- Does this panel have a named collect button at all? Cached per panel, so the
-- label fallback (which walks the tree) can never run on a panel that has one.
local function hasNamedCollectButton(menu)
    for _, pname in ipairs(CONFIG.COLLECT_BUTTON_PROPS) do
        local btn = nil
        local ok = pcall(function() btn = menu[pname] end)
        if ok and alive(btn) then return true end
    end
    return false
end

local function enableCollectButtonsByLabel(menu)
    local touched = 0
    walkWidgets(menu, function(w)
        local cn = classNameOf(w)
        if not cn or not cn:find("[Bb]utton") then return end
        local enabled = nil
        pcall(function() enabled = w:GetIsEnabled() end)
        if enabled ~= false then return end

        local label = widgetLabel(w)
        -- Log every disabled button once, so an unmatched language shows up.
        logOnce("btnlabel:" .. cn .. ":" .. label,
            string.format("disabled button %s label='%s'", cn, label))
        if not labelMatches(label) then return end

        if enableButton(w, "label '" .. label .. "'") then touched = touched + 1 end
    end)
    return touched
end

-- Named property first; the tree-walking label scan is a fallback for panels
-- that have no named button at all, and is decided once per panel (st.named),
-- never per refresh.
local function enableCollectButtons(st)
    if st.named == nil then st.named = hasNamedCollectButton(st.widget) end
    if st.named then return enableNamedCollectButtons(st.widget) end
    return enableCollectButtonsByLabel(st.widget)
end

local function autoCollect(model)
    if not alive(model) then return end
    local ok, err = pcall(function() model:RequestObtainAllHatchedCharacter() end)
    if ok then
        log("auto-collect: RequestObtainAllHatchedCharacter sent")
    else
        logOnce("autocollect", "auto-collect failed: " .. tostring(err):gsub("\n.*", ""))
    end
end

-- ---------------------------------------------------------------------------
-- Reflection dump (first sighting of a panel class, and on DUMP_KEY)
-- ---------------------------------------------------------------------------
local function dumpClassChain(obj, label)
    log("--- " .. label .. ": " .. tostring(classNameOf(obj)) .. " ---")
    forEachClassInChain(obj, function(cls, cname)
        log("class " .. tostring(cname))
        pcall(function()
            cls:ForEachFunction(function(fn)
                local flags = nil
                pcall(function() flags = fn:GetFunctionFlags() end)
                log(string.format("    fn   %s (flags 0x%X)", tostring(nameOf(fn)), flags or 0))
            end)
        end)
        pcall(function()
            cls:ForEachProperty(function(prop)
                local pc = nil
                pcall(function() pc = prop:GetClass():GetFName():ToString() end)
                log(string.format("    prop %s : %s", tostring(nameOf(prop)), tostring(pc)))
            end)
        end)
    end)
end

local function dumpPanel(entry)
    local menu = entry.widget
    log("=== HATCHERY PANEL DUMP ===")
    log("panel: " .. entry.class .. "  " .. tostring(entry.id))
    dumpClassChain(menu, "panel class chain")

    log("--- widget tree ---")
    walkWidgets(menu, function(w, depth)
        local extra = ""
        local txt = nil
        pcall(function() txt = w:GetText():ToString() end)
        if type(txt) == "string" and #txt > 0 then extra = extra .. " text='" .. txt .. "'" end
        local en = nil
        pcall(function() en = w:GetIsEnabled() end)
        if en ~= nil then extra = extra .. " enabled=" .. tostring(en) end
        local vis = nil
        pcall(function() vis = w:GetVisibility() end)
        if vis ~= nil then extra = extra .. " vis=" .. tostring(vis) end
        log(string.format("%s%s (%s)%s", string.rep("  ", depth + 1),
            tostring(nameOf(w)), tostring(classNameOf(w)), extra))
    end)

    log("--- named collect buttons ---")
    for _, pname in ipairs(CONFIG.COLLECT_BUTTON_PROPS) do
        local btn = nil
        local ok = pcall(function() btn = menu[pname] end)
        if ok and alive(btn) then
            local en, ie, vis = nil, nil, nil
            pcall(function() en = btn:GetIsEnabled() end)
            pcall(function() ie = btn:GetIsInteractionEnabled() end)
            pcall(function() vis = btn:GetVisibility() end)
            log(string.format("%s (%s) enabled=%s interaction=%s vis=%s label='%s'", pname,
                tostring(classNameOf(btn)), tostring(en), tostring(ie), tostring(vis),
                widgetLabel(btn)))
            -- The class-chain dump that used to sit here has served its purpose:
            -- WBP_CommonButton_C derives straight from UserWidget, has no
            -- enabled/disabled state, and drives its look purely through
            -- animations (Anm_DefaultToRed, AnmEvent_Red/Normal/Focus).
        else
            log(pname .. ": not present on this panel")
        end
    end

    local model = entry.model
    if alive(model) then
        dumpClassChain(model, "model class chain")
        log("hatched slots: " .. tostring(hatchedCount(model)))
    else
        log("--- model: not resolved ---")
    end
    log("=== END DUMP ===")
end

-- ---------------------------------------------------------------------------
-- Tick
-- ---------------------------------------------------------------------------
local HEARTBEAT_TICKS = CONFIG.HEARTBEAT_MS > 0
    and math.max(1, math.floor(CONFIG.HEARTBEAT_MS / CONFIG.POLL_MS)) or 0

local tickCount = 0
local panels = {}        -- id -> state { widget, class, id, model, ticks, lastHatched }
local panelCount = 0
local dumpedClasses = {} -- class name -> true
local dumpRequested = false

-- The world HUD over a machine closes and re-opens constantly while the player
-- moves around, and each fresh entry would otherwise redo the expensive setup:
-- resolveModel walks the widget tree and reflects every ObjectProperty, and the
-- sub-widget list is another walk. The widget instance is reused, so its full
-- name is a stable key — remember the resolved state for the last few panels.
local panelCache = {}      -- id -> { model, subWidgets, named, lastHatched }
local panelCacheIds = {}   -- insertion order, for eviction
local PANEL_CACHE_MAX = 8

local function cachePanel(st)
    if panelCache[st.id] == nil then
        panelCacheIds[#panelCacheIds + 1] = st.id
        if #panelCacheIds > PANEL_CACHE_MAX then
            local oldest = table.remove(panelCacheIds, 1)
            panelCache[oldest] = nil
        end
    end
    panelCache[st.id] = {
        model = st.model,
        subWidgets = st.subWidgets,
        named = st.named,
        lastHatched = st.lastHatched,
    }
end

local function servicePanel(st)
    local hatched = hatchedCount(st.model)

    -- A change in either direction matters: up = something finished, down =
    -- the player collected, and the panel has to follow both.
    local countChanged = hatched ~= nil and st.lastHatched ~= nil and hatched ~= st.lastHatched
    local changed = st.forceRefresh or hatchSignal or countChanged

    -- Heartbeat only where we have no change detector at all.
    st.ticks = st.ticks + 1
    local heartbeat = hatched == nil and HEARTBEAT_TICKS > 0 and st.ticks >= HEARTBEAT_TICKS

    if changed or heartbeat then
        st.forceRefresh = false
        st.ticks = 0
        refreshPanel(st)

        -- Button and collect act on real transitions only. Repeating them while
        -- the state sits still is what flickered the button / would have spammed
        -- the same RPC at the server.
        if changed and hatched ~= nil and hatched > 0 then
            if CONFIG.ENABLE_BUTTONS then enableCollectButtons(st) end
            if CONFIG.AUTO_COLLECT then autoCollect(st.model) end
        end
    end

    if hatched ~= nil then
        -- Only real transitions are worth a line. The first read after a panel
        -- opens is not one: panels are recreated on every open, so logging it
        -- meant a "0 hatched slot(s)" every time the player glanced at a machine.
        if st.lastHatched ~= nil and st.lastHatched ~= hatched then
            log(string.format("%s: %d hatched slot(s) (was %d)",
                st.class, hatched, st.lastHatched))
        end
        st.lastHatched = hatched
    end
end

local function tickBody()
    tickCount = tickCount + 1

    -- Drop panels that closed or died, keeping their resolved state around for
    -- the very likely re-open.
    for id, st in pairs(panels) do
        if not alive(st.widget) or not isShowing(st.widget) then
            cachePanel(st)
            panels[id] = nil
            panelCount = panelCount - 1
        end
    end

    -- Scan for panels. Every findMenus() sweeps the UObject array once per
    -- class that is not already being serviced, so it runs rarely: a few
    -- seconds of delay before the mod picks a panel up is irrelevant (the
    -- point of the mod plays out over minutes of incubation), while a sweep
    -- every couple of ticks is a hitch the player can feel.
    local scanDue = dumpRequested or
        (panelCount == 0 and (tickCount % CONFIG.IDLE_EVERY_NTH_TICK) == 0) or
        (panelCount > 0 and (tickCount % CONFIG.RESCAN_EVERY_NTH_TICK) == 0)

    if scanDue then
        local have = {}
        for _, st in pairs(panels) do have[st.class] = true end
        for _, entry in ipairs(findMenus(have)) do
            if panels[entry.id] == nil then
                local cached = panelCache[entry.id]
                if cached and alive(cached.model) then
                    entry.model = cached.model
                    entry.subWidgets = cached.subWidgets
                    entry.named = cached.named
                    entry.lastHatched = cached.lastHatched
                else
                    entry.model = resolveModel(entry.widget)
                    if alive(entry.model) then hookHatchNotifies(entry.model) end
                    entry.lastHatched = nil
                end
                entry.ticks = 0
                entry.forceRefresh = true -- one refresh on the opening tick
                panels[entry.id] = entry
                panelCount = panelCount + 1
                logOnce("open:" .. entry.class, "panel serviced: " .. entry.class)
                if CONFIG.DUMP_ON_FIRST_OPEN and not dumpedClasses[entry.class] then
                    dumpedClasses[entry.class] = true
                    pcall(dumpPanel, entry)
                end
            end
        end
    end

    if dumpRequested then
        dumpRequested = false
        local any = false
        for _, st in pairs(panels) do
            any = true
            pcall(dumpPanel, st)
        end
        if not any then log("F8: no incubator panel on screen") end
    end

    for _, st in pairs(panels) do
        pcall(servicePanel, st)
    end

    hatchSignal = false -- consumed by every panel serviced this tick
end

-- LoopAsync runs off the game thread, so every game access is hopped onto the
-- game thread. Return false to keep looping (UE4SS convention).
pcall(function()
    LoopAsync(CONFIG.POLL_MS, function()
        local ok, err = pcall(function()
            ExecuteInGameThread(function()
                local okt, errt = pcall(tickBody)
                if not okt then logOnce("tick", "tick error: " .. tostring(errt)) end
            end)
        end)
        if not ok then logOnce("loop", "LoopAsync error: " .. tostring(err)) end
        return false
    end)
end)

-- ---------------------------------------------------------------------------
-- Manual dump key
-- ---------------------------------------------------------------------------
pcall(function()
    local key = Key[CONFIG.DUMP_KEY]
    if key == nil then
        log("dump key " .. tostring(CONFIG.DUMP_KEY) .. " unavailable in this UE4SS build")
        return
    end
    RegisterKeyBind(key, function()
        dumpRequested = true -- the tick performs it on the game thread
    end)
    log("dump key bound: " .. CONFIG.DUMP_KEY)
end)

log(string.format("v%s ready. Change-driven refresh; heartbeat %s.",
    VERSION, HEARTBEAT_TICKS > 0 and (CONFIG.HEARTBEAT_MS .. "ms (detector-less panels only)") or "off"))
