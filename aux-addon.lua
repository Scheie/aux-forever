select(2, ...) 'aux'

local post = require 'aux.tabs.post'
local gui = require 'aux.gui'
local history = require 'aux.core.history'

function M.print(...)
	DEFAULT_CHAT_FRAME:AddMessage(LIGHTYELLOW_FONT_COLOR_CODE .. '<auxForever> ' .. join(map({...}, tostring), ' '))
end

-- The share of a sale the auction house keeps, in one place for every tab (0.8.2.1, outside review
-- R-20; it was written in three files). 5% is Outside in docs/forever-auction-house.md (section 4):
-- guides say so, and it has not been checked against a sale's mail yet (experiment E1).
M.AUCTION_CUT = .05

local event_frame = CreateFrame'Frame'
for _, event in pairs{'ADDON_LOADED', 'PLAYER_LOGIN', 'AUCTION_HOUSE_SHOW', 'AUCTION_HOUSE_CLOSED'} do
	event_frame:RegisterEvent(event)
end

local aux_events = {}
M.event = setmetatable({}, {__metatable=false, __newindex=function(_, k, v) aux_events[k](v) end})

do
	local handlers, handlers2, handlers3 = {}, {}, {}
	function aux_events.AUX_LOADED(f)
		tinsert(handlers, f)
	end
	function aux_events.PLAYER_LOGIN(f)
		tinsert(handlers2, f)
    end
    function aux_events.AUCTION_HOUSE_LOADED(f)
        tinsert(handlers3, f)
    end
	event_frame:SetScript('OnEvent', function(_, event, arg1, ...)
		if event == 'ADDON_LOADED' then
            if arg1 == 'auxForever' then
                for _, f in ipairs(handlers) do f(arg1, ...) end
            elseif arg1 == 'Blizzard_AuctionHouseUI' then
                for _, f in ipairs(handlers3) do f(arg1, ...) end
            end
		elseif event == 'PLAYER_LOGIN' then
            -- before anything reads the price history (core/history.lua takes it at login)
            if join_realms({[realm_data] = true, [faction_data] = true, [character_data] = true}) then
                realm_rejoined = true
            end
			for _, f in ipairs(handlers2) do f(arg1, ...) end
            if realm_rejoined then
                print('Your saved data is now one set for all ' .. realm_name() .. ' subrealms (prices, favorites and settings joined).')
            elseif realm_name() == '' then
                print('The game has not said which realm this is, so your saved prices are not loaded this session. /reload to load them.')
            end
            sort_item_names(account_data.auctionable_items)
            print('loaded. aux by shirsig, re-imagined by a fan. /aux for help')
            print(full_scan_reminder(account_data.replicate_time, time()))
		else
			_M[event](arg1, ...)
		end
	end)
end

-- The item names for autocompletion, shortest first. 0.8.2.1 (outside review, R-13): the whole list
-- (tens of thousands of names) was sorted at every login and /reload; it is sorted only when a name
-- was added since (they are added at the end), which one pass over the list tells.
local function name_before(a, b)
    return strlen(a) < strlen(b) or (strlen(a) == strlen(b) and a < b)
end

function M.sort_item_names(names)
    for i = 2, #names do
        if name_before(names[i], names[i - 1]) then
            sort(names, name_before)
            return true
        end
    end
    return false
end

-- auxForever (0.5): the second line at login and after /reload. Tooltip prices and recipe costs come
-- from scans, and a Full scan records every price at once, so it says when the last one was and
-- asks for one (Tyler, 2026-10-07: players should get the value out of auxForever).
function M.full_scan_reminder(last, now)
    local scan = color.accent.background('Full scan')
    if not last or last <= 0 then
        return 'Tip: at the auction house, click ' .. scan .. ' (top right of aux). It records every price, so your tooltips and recipe costs are right anywhere in the world.'
    end
    local hours = floor(max(0, now - last) / 3600)
    local age
    if hours < 1 then
        age = 'less than an hour ago'
    elseif hours < 24 then
        age = hours .. (hours == 1 and ' hour ago' or ' hours ago')
    else
        local days = floor(hours / 24)
        age = days .. (days == 1 and ' day ago' or ' days ago')
    end
    return 'Last ' .. scan .. ': ' .. age .. '. Run one on each visit to the auction house to keep your tooltip prices current.'
end

-- one character's saved settings with the defaults filled in. 0.8.2 (FB-035): the tooltip lines are
-- filled in one by one, so a line added later (Usually) starts on for a character that already had
-- tooltip settings (assign only fills what is missing at its own level)
TOOLTIP_DEFAULTS = {
    value = true,
    usually = true,
    crate = true, -- 0.8.2.1 build 7 (FB-041): the Waylaid Crate lines, now with a switch
    -- 0.9 (FB-058, jebbush; Tyler): full stack by default, hold Shift for 1 item
    stack = true,
    merchant_sell = true,
    merchant_buy = false,
    daily = false,
    disenchant_value = false,
    disenchant_distribution = false,
    money_icons = false,
}
function M.character_settings(saved)
    assign(saved, {bid_auction_ids = {}, tooltip = {}})
    assign(saved.tooltip, TOOLTIP_DEFAULTS)
    return saved
end

-- 0.9.1: on Forever GetRealmName() can be empty while the addon loads (Seen 2026-11-22). aux then
-- kept everything under a realm named "": a second, empty price history next to the real one, so
-- the Sniper had no usual prices and found no deals, and favorite searches seemed gone. Saved data
-- under "" is joined into the real realm's as soon as its name is known: at load, or else at login.
-- (GetNormalizedRealmName is no fallback: it drops the spaces, which would be a third key.)
-- Later the same day the game gave no realm name even after login, so aux has its own fallbacks.

-- 0.9.1 (the player, 2026-11-23): Forever runs all of a region's realms of one kind as one realm,
-- with subrealms under it ("CAMWOW EU4 Realm 7 PvE", "CAMWOW EU5 Realm 7 PvE" are both EU PvE), and
-- they share the auction house. aux keeps one set of data per region and kind: realm_group gives
-- "EU PvE" for both. A name not of that form (no region word, or no kind at its end) is kept whole.
REGIONS = {EU = true, US = true, NA = true, OCE = true, KR = true, TW = true, CN = true}
REALM_KINDS = {PVE = 'PvE', PVP = 'PvP', RP = 'RP', RPPVP = 'RPPvP'}
function M.realm_group(name)
    if not name or name == '' then
        return ''
    end
    local region, kind
    for word in string.gmatch(name, '%S+') do
        local letters = strmatch(word, '^(%a+)%d*$')
        if not region and letters and REGIONS[strupper(letters)] then
            region = strupper(letters)
        end
        kind = REALM_KINDS[strupper(word)]
    end
    if region and kind then
        return region .. ' ' .. kind
    end
    return name
end

-- The realm group aux keeps saved data under; "" only when nothing at all tells it. In order: the
-- game's realm name (remembered, by realm ID, for when it is missing); the name remembered for this
-- realm ID; the one realm group this account has saved data for; the last name the game gave.
function M.realm_name()
    local account = aux.account
    local id = GetRealmID and GetRealmID() or 0
    local name = GetRealmName()
    if name and name ~= '' then
        account.realm_names = account.realm_names or {}
        if id and id > 0 then
            account.realm_names[id] = name
        end
        account.last_realm = name
        return realm_group(name)
    end
    local remembered = account.realm_names and id and account.realm_names[id]
    if remembered then
        return realm_group(remembered)
    end
    local only
    for realm in pairs(aux.realm) do
        local group = realm_group(realm)
        if group ~= '' and group ~= only then
            if only then
                only = nil
                break
            end
            only = group
        end
    end
    return only or realm_group(account.last_realm)
end

-- fills in what keep lacks from other, table by table, except the keys in skip
local function fill(keep, other, skip)
    for k, v in pairs(other) do
        if not (skip and skip[k]) then
            if keep[k] == nil then
                keep[k] = v
            elseif type(keep[k]) == 'table' and type(v) == 'table' then
                fill(keep[k], v)
            end
        end
    end
end

-- searches are lists: other's are added after keep's, each filter once
local function merge_searches(keep, other)
    for _, search in ipairs(other or empty) do
        if not any(keep, function(kept) return kept.filter_string == search.filter_string end) then
            tinsert(keep, search)
        end
    end
end

local function merge_realm(keep, other)
    keep.characters = keep.characters or {}
    for name, seen in pairs(other.characters or empty) do
        keep.characters[name] = max(keep.characters[name] or 0, seen)
    end
    keep.favorite_searches, keep.recent_searches = keep.favorite_searches or {}, keep.recent_searches or {}
    merge_searches(keep.favorite_searches, other.favorite_searches)
    merge_searches(keep.recent_searches, other.recent_searches)
    fill(keep, other, {characters = true, favorite_searches = true, recent_searches = true})
end

local function merge_faction(keep, other)
    keep.history = keep.history or {}
    -- a history from before version 2 was thrown away at load anyway (see AUX_LOADED)
    if other.history_version == 2 or other.history_version == 3 then
        for key, line in pairs(other.history or empty) do
            keep.history[key] = history.merge_lines(keep.history[key], line)
        end
    end
    if other.price_keys_since then
        keep.price_keys_since = min(keep.price_keys_since or other.price_keys_since, other.price_keys_since)
    end
    -- the old prices are looked over again at login (core/history.lua, forget_old_prices)
    keep.history_trimmed = nil
    fill(keep, other, {history = true, history_version = true, price_keys_since = true, history_trimmed = true})
end

local function merge_character(keep, other)
    keep.bid_auction_ids = keep.bid_auction_ids or {}
    for _, id in ipairs(other.bid_auction_ids or empty) do
        if not key(keep.bid_auction_ids, id) then
            tinsert(keep.bid_auction_ids, id)
        end
    end
    fill(keep, other, {bid_auction_ids = true})
end

-- moves store[old_key] to store[new_key], merged with what is there. The table in use this session
-- (in_use) is the one kept, since the tabs hold on to it; otherwise the one at new_key is kept.
local function rekey(store, old_key, new_key, merge, in_use)
    local old, new = store[old_key], store[new_key]
    store[old_key] = nil
    if not new then
        store[new_key] = old
    elseif in_use and in_use[old] then
        merge(old, new)
        store[new_key] = old
    else
        merge(new, old)
    end
end

-- Joins saved data kept under a subrealm's whole name, or under "" (no name from the game), into its
-- realm group's (realm_group); true when there was any. in_use: the session's tables (at login), nil
-- while loading. Data under "" waits while the current group is not known either.
function M.join_realms(in_use)
    local current = realm_name()
    local function target(realm)
        if realm == '' then
            return current ~= '' and current or nil
        end
        return realm_group(realm)
    end
    local found = false
    -- the realm store's keys are realm names; the others' are "realm|faction" and "realm|character"
    for _, entry in ipairs{{aux.realm, merge_realm, false}, {aux.faction, merge_faction, true}, {aux.character, merge_character, true}} do
        local store, merge, with_rest = entry[1], entry[2], entry[3]
        local moves = {}
        for k in pairs(store) do
            local realm, rest = k, ''
            if with_rest then
                realm, rest = strmatch(k, '^(.-)(|.*)$')
            end
            local group = realm and target(realm)
            if group and group .. rest ~= k then
                tinsert(moves, {k, group .. rest})
            end
        end
        for _, move in ipairs(moves) do
            rekey(store, move[1], move[2], merge, in_use)
            found = true
        end
    end
    return found
end

function event.AUX_LOADED()
    _G.aux = aux or {}
    assign(aux, {
        account = {},
        realm = {},
        faction = {},
        character = {},
    })
    -- subrealms' data joined into their realm group's; data under "" waits for login if the realm is
    -- not known yet (join_realms)
    realm_rejoined = join_realms()
    M.account_data = assign(aux.account, {
        scale = 1,
        ignore_owner = true,
        action_shortcuts = false,
        post_full_scan = nil,
        post_bid = nil,
        post_duration = post.DURATION_8,
        post_undercut = false,
        -- auxForever (0.8.2.2, FB-049): a second click on Confirm before anything is bought
        buy_confirm = false,
        -- 0.9 build 4 (FB-066, user_ivpyccljovcjne72): Search buy bar starting quantity ('1' or 'stack')
        buy_default = '1',
        -- 0.9: Phase 1 switches (FB-061, FB-062, FB-032; Tyler 2026-11-21: right_click_post on by default)
        crafting_cost = true,
        right_click_post = true,
        auto_full_scan = false,
        full_search = false,
        sniper_percent = 60,
        sniper_profit = 500,
        sniper_sound = true,
        -- 0.9 build 4 (FB-055, khorrs; Tyler): narrower Sniper scope and minimum quality
        sniper_scope = {kind = 'all'},
        sniper_quality = 1,
        sniper_ignored = {},
        -- 0.9.1: words that ignore every item whose name holds them ("of the hierophant"), lower case
        sniper_ignored_words = {},
        -- 0.9.1: deals hidden for a while (Snooze): price key -> {until = time(), name = ...}
        sniper_snoozed = {},
        sniper_snooze_minutes = 30,
        replicate_time = 0,
        window = {},
        background_opacity = 1,
        -- auxForever (0.6): the look, 'new' (webster's UI Kit) or 'classic' (the 0.5 look),
        -- chosen in Settings and applied at the next login or /reload
        theme = 'new',
        items = {},
        item_ids = {},
        unused_item_ids = {},
        auctionable_items = {},
        merchant_buy = {},
    })
    do
        local key = format('%s|%s', realm_name(), UnitName'player')
        aux.character[key] = aux.character[key] or {}
        M.character_data = character_settings(aux.character[key])
    end
    do
        local key = realm_name()
        aux.realm[key] = aux.realm[key] or {}
        M.realm_data = assign(aux.realm[key], {
            characters = {},
            recent_searches = {},
            favorite_searches = {},
        })
    end
    do
        local key = format('%s|%s', realm_name(), UnitFactionGroup 'player')
        aux.faction[key] = aux.faction[key] or {}
        M.faction_data = assign(aux.faction[key], {
            history = {},
            post = {},
        })
        -- Forever: the first test version recorded item prices divided by the number of auctions
        -- in a search row, which made recorded values far too low. Start the price history over.
        -- auxForever (0.5): version 3 adds market prices and day numbers. A version 2 line (0.4) is
        -- converted when it is first read (core/history.lua), keeping every daily low.
        if faction_data.history_version == 2 then
            faction_data.history_version = 3
        elseif faction_data.history_version ~= 3 then
            faction_data.history = {}
            faction_data.history_version = 3
        end
    end
    -- every file has built its widgets by now; paint them in the chosen look (gui.settle_theme)
    account_data.theme = gui.settle_theme(account_data.theme)
end

tab_info = {}
function M.tab(name)
	local tab = { name = name }
	local tab_event = {
		OPEN = function(f) tab.OPEN = f end,
		CLOSE = function(f) tab.CLOSE = f end,
		USE_ITEM = function(f) tab.USE_ITEM = f end,
		CLICK_LINK = function(f) tab.CLICK_LINK = f end,
	}
	tinsert(tab_info, tab)
	return setmetatable({}, {__metatable=false, __newindex=function(_, k, v) tab_event[k](v) end})
end

function M.tab_index_by_name(name)
	for i, tab in ipairs(tab_info) do
		if tab.name == name then
			return i
		end
	end
end

-- 0.9 (FB-057): shared by both /aux clear ... and the Options > AddOns > auxForever panel
function M.clear_item_cache()
	account_data.items = {}
	account_data.item_ids = {}
	account_data.unused_item_ids = {}
	account_data.auctionable_items = {}
	print('Item cache cleared.')
end

function M.clear_post_data()
	-- emptied in place (outside review R-06): tabs/post keeps this same table reference
	wipe(faction_data.post)
	print('Post data cleared.')
end

do
	local index
	function M.get_tab() return tab_info[index] end
	function on_tab_click(i)
		do (index and get_tab().CLOSE or pass)() end
		index = i
		do (index and get_tab().OPEN or pass)() end
	end
end

M.orig = setmetatable({[_G]={}}, {__index=function(self, key) return self[_G][key] end})
function M.hook(...)
	local name, object, handler
	if select('#', ...) == 3 then
		name, object, handler = ...
	else
		object, name, handler = _G, ...
	end
	handler = handler or getfenv(3)[name]
	orig[object] = orig[object] or {}
	orig[object][name], object[name] = object[name], handler
	return hook
end

do
	local locked

	function M.bid_in_progress()
        return locked
    end

	-- Forever: bids and buyouts go through C_AuctionHouse.PlaceBid with the auction's ID.
	-- Must be called from a click handler (hardware event).
	function M.place_bid(auction_id, amount, on_success, on_failure)
		if locked or not auction_id then
            return
        end
		if GetMoney() < amount then
			UIErrorsFrame:AddExternalErrorMessage(ERR_NOT_ENOUGH_MONEY)
			return
		end
		locked = true
		local result
		local purchased = false
		local listeners = {
			event_listener('AUCTION_HOUSE_PURCHASE_COMPLETED', function(id)
				if id == auction_id then
					result = true
					purchased = true
				end
			end),
			event_listener('BID_ADDED', function()
				result = true
			end),
			event_listener('CHAT_MSG_SYSTEM', function(message)
				if message == ERR_AUCTION_BID_PLACED then result = true end
			end),
			event_listener('AUCTION_HOUSE_SHOW_ERROR', function(error)
				result = result or error
			end),
			event_listener('AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED', function()
				result = result or 'throttled'
			end),
			event_listener('AUCTION_HOUSE_CLOSED', function()
				result = result or 'closed'
			end),
		}
		-- 0.9: register listeners and lock before calling PlaceBid so synchronous errors or
		-- completions are captured instead of hanging 5s for a timeout.
		C_AuctionHouse.PlaceBid(auction_id, amount)
		local function finish()
			for _, listener_id in ipairs(listeners) do
				kill_listener(listener_id)
			end
			locked = false
			-- no answer in 5 seconds: on a slow server the purchase may still go through later, so
			-- the player is told so instead of nothing (found with the slow test auction house)
			if result == nil then
				result = 'timeout'
				print('No answer from the auction house yet. The purchase may still go through: check your mail before buying again.')
			end
			if result == true then
				-- 0.9: only real bids belong in bid_auction_ids; gear buyouts end immediately and
				-- used to push active bids out of the 200-entry list.
				if not purchased then
					tinsert(character_data.bid_auction_ids, auction_id)
					while #character_data.bid_auction_ids > 200 do
						tremove(character_data.bid_auction_ids, 1)
					end
				end
				do (on_success or pass)() end
			else
				do (on_failure or pass)(result) end
			end
		end
		if result ~= nil then
			finish()
			return
		end
		coro_thread(function()
			local t0 = GetTime()
			while result == nil and GetTime() - t0 < 5 do
				coro_wait()
			end
			finish()
		end)
	end
end

-- Forever: Blizzard's AuctionHouseFrame must stay "shown" while the auction house is open,
-- because hiding it closes the auction house. Instead it is kept invisible behind aux.
do
    local blizzard_visible = false
    local HIDDEN_SCALE = .01

    -- The game lays out its side windows (UIParentPanelManager) with offsets divided by the
    -- window's scale. Any layout while the Blizzard window is shrunk (opening the character sheet,
    -- spellbook, a vendor...) therefore puts it 100 times too far away, off screen, and growing
    -- it back left it there: the Blizzard UI button seemed to do nothing. Bring such an anchor
    -- back to what the layout meant.
    function M.fix_blizzard_frame_position()
        local point, relative_to, relative_point, x, y = AuctionHouseFrame:GetPoint(1)
        if point and y and abs(y) > UIParent:GetHeight() then
            AuctionHouseFrame:ClearAllPoints()
            AuctionHouseFrame:SetPoint(point, relative_to, relative_point, x * HIDDEN_SCALE, y * HIDDEN_SCALE)
        end
    end

    -- Blizzard sizes its tabs to their text when they are shown. While the window is shrunk to
    -- 1% that measurement can come out far too wide, and the tabs (Buy, Sell, Auctions) then ran
    -- off the screen once the window was shown at full size (Tyler, 2026-10-05, not reproduced).
    -- Measure them again at full size with Blizzard's own code.
    function M.resize_blizzard_tabs()
        local auctions_frame = AuctionHouseFrame.AuctionsFrame
        for _, tabs in ipairs{AuctionHouseFrame.Tabs, type(auctions_frame) == 'table' and auctions_frame.Tabs} do
            for _, tab in ipairs(type(tabs) == 'table' and tabs or empty) do
                local on_show = tab.GetScript and tab:GetScript('OnShow')
                if on_show and tab:IsShown() then
                    on_show(tab)
                end
            end
        end
    end

    function M.blizzard_frame_shown()
        return blizzard_visible
    end

    -- 0.8.0.1 (FB-034, reported by Chawitsch): Blizzard's auction house window takes the left and
    -- center places of the game's window layout ("doublewide"), so a side window such as
    -- Professions goes to the right of it. Shrunk to 1% and invisible, that window is only a few
    -- pixels wide, so the side window moved a little to the right whenever aux was open
    -- (Blizzard_UIParentPanelManager, UpdateUIPanelPositions: the right place starts after the
    -- doublewide window's width and offset, plus the gap). While Blizzard's window is hidden, the side
    -- window goes back to where it stands without the auction house: the left place, at the game's
    -- own offsets. aux only moves that window after the game placed it (a hook that runs after the
    -- game's code), never changes the game's layout tables, and skips protected windows in combat.
    -- 0.8.1 build 2 (Tyler's test): only a window standing exactly where the game's right place puts
    -- it is moved. A window the player placed themselves (with an addon that keeps windows where they
    -- were dragged) was pulled to the left, behind aux; it is now left where it is.
    local function number(v) return type(v) == 'number' and v or 0 end

    function M.settle_side_panel()
        if blizzard_visible or not AuctionHouseFrame or not GetUIPanel or GetUIPanel('doublewide') ~= AuctionHouseFrame then
            return
        end
        local side = GetUIPanel('right')
        if not side or (side.IsProtected and side:IsProtected() and InCombatLockdown()) then
            return
        end
        local point, relative_to, relative_point, x, y = side:GetPoint(1)
        if point ~= 'TOPLEFT' or type(x) ~= 'number' or not GetUIPanelLayoutAttribute or not GetUIPanelWidth then
            return
        end
        local scale = side:GetScale()
        local left = number(GetUIPanelLayoutAttribute('LEFT_OFFSET')) + number(side:GetAttribute('UIPanelLayout-xoffset'))
        -- where the game puts the right place: after the auction house window as it is now (1%), or
        -- at full size when the layout ran before aux shrank it
        local gap = number(AuctionHouseFrame:GetAttribute('UIPanelLayout-xoffset')) + number(GetUIPanelLayoutAttribute('PANEl_SPACING_X'))
        local widths = {number(GetUIPanelWidth(AuctionHouseFrame)), GetUIPanelWidthUnscaled and number(GetUIPanelWidthUnscaled(AuctionHouseFrame)) or nil}
        for _, width in ipairs(widths) do
            if abs(x * scale - (left + width + gap)) < 1.5 then
                side:SetPoint('TOPLEFT', relative_to, relative_point, left / scale, y)
                return
            end
        end
    end

    local layout_hooked
    function M.hook_panel_layout()
        if layout_hooked or not UpdateUIPanelPositions then return end
        layout_hooked = true
        hooksecurefunc('UpdateUIPanelPositions', function() settle_side_panel() end)
    end

    function M.set_blizzard_frame_shown(shown)
        if not AuctionHouseFrame then return end
        blizzard_visible = shown
        if shown then
            AuctionHouseFrame:SetScale(1)
            fix_blizzard_frame_position()
            resize_blizzard_tabs()
            -- never off screen, whatever moved it
            AuctionHouseFrame:SetClampedToScreen(true)
            AuctionHouseFrame:SetAlpha(1)
            AuctionHouseFrame:EnableMouse(true)
            -- both windows sit in the same layer, and whichever was shown or clicked last is on top
            AuctionHouseFrame:Raise()
        else
            AuctionHouseFrame:SetScale(HIDDEN_SCALE)
            AuctionHouseFrame:SetAlpha(0)
            AuctionHouseFrame:EnableMouse(false)
            -- the game may have placed a side window while this window was still full size
            settle_side_panel()
        end
        do (update_blizzard_button or pass)() end
    end

    -- hooked once, whoever loaded Blizzard's auction house first (another addon may load it
    -- before aux, and then its load event has already passed)
    local hooked
    function M.hook_blizzard_frame()
        if hooked or not AuctionHouseFrame then return end
        hooked = true
        AuctionHouseFrame:HookScript('OnShow', function(self)
            set_blizzard_frame_shown(false)
            -- aux handles posting confirmations itself; stop the hidden frame from popping its own dialog
            self:UnregisterEvent('AUCTION_HOUSE_POST_WARNING')
            self:UnregisterEvent('AUCTION_HOUSE_POST_ERROR')
        end)
        AuctionHouseFrame:HookScript('OnHide', function()
            blizzard_visible = false
            do (update_blizzard_button or pass)() end
        end)
    end

    function event.AUCTION_HOUSE_LOADED()
        hook_blizzard_frame()
        hook_panel_layout()
    end
end

function AUCTION_HOUSE_SHOW()
    compat_load_auction_house_ui()
    hook_blizzard_frame()
    hook_panel_layout()
    if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
        set_blizzard_frame_shown(false)
    end
    frame:Show()
    set_tab(1)
    -- auxForever: undercut mode is a choice for the moment, so it starts off every visit and stays
    -- as clicked until the auction house closes (Tyler, 2026-10-17, FB-018: no setting for it)
    post.set_undercut_mode(false)
    query_owned_auctions()
    query_bids()
    -- 0.9 (FB-032, Chawitsch): optional automatic Full scan when the auction house opens.
    -- Quietly skipped if the 15-minute cooldown or another scan is already active.
    if account_data.auto_full_scan and start_full_scan then
        start_full_scan(true)
    end
end

function M.query_owned_auctions()
    C_AuctionHouse.QueryOwnedAuctions({{sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false}})
end

function M.query_bids()
    local ids = {}
    for _, id in ipairs(character_data.bid_auction_ids) do
        tinsert(ids, id)
    end
    for _, id in ipairs(_G.g_activeBidAuctionIDs or empty) do
        tinsert(ids, id)
    end
    C_AuctionHouse.QueryBids({{sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false}}, ids)
end

do
	local handlers = {}
	function aux_events.CLOSE(f)
		tinsert(handlers, f)
	end
	function AUCTION_HOUSE_CLOSED()
		for _, handler in pairs(handlers) do
			handler()
		end
		set_tab()
		frame:Hide()
	end
end
