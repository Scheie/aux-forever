select(2, ...) 'aux.tabs.sniper'

local aux = require 'aux'
local info = require 'aux.util.info'
local money = require 'aux.util.money'
local sort_util = require 'aux.util.sort'
local gui = require 'aux.gui'
local auction_listing = require 'aux.gui.auction_listing'
local buy_bar = require 'aux.gui.buy_bar'
local search_tab = require 'aux.tabs.search'

-- auxForever: the Sniper tab, from the approved mockup: Start / Stop and the round status on the
-- left, the deal rule on the right, the deals in a table with the buy bar under it.

frame = CreateFrame('Frame', nil, aux.frame)
frame:SetAllPoints(aux.frame.body)
frame:SetScript('OnUpdate', function() update() end)
frame:Hide()

frame.listing = gui.panel(frame)
-- 0.9 build 4 (FB-055, Option A): leave 34px above Deals for the slim Watch bar
frame.listing:SetPoint('TOPLEFT', aux.frame.content, 'TOPLEFT', 0, -34)
frame.listing:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)

frame.listing.list = CreateFrame('Frame', nil, frame.listing)
-- exported for the gamepad: A on a deal moves the focus to the buy bar (gamepad.lua)
M.deals_list = frame.listing.list
frame.listing.list:SetPoint('TOPLEFT', 0, 0)
frame.listing.list:SetPoint('BOTTOMRIGHT', 0, buy_bar.HEIGHT + 4)

local function ago(t)
    local seconds = time() - t
    if seconds < 5 then
        return 'just now'
    elseif seconds < 60 then
        return seconds .. 's ago'
    elseif seconds < 3600 then
        return floor(seconds / 60) .. 'm ago'
    end
    return floor(seconds / 3600) .. 'h ago'
end
M.ago = ago

-- gone deals are shown dimmed
local function dim(record, text)
    return record.deal_gone and aux.color.label.disabled(text) or text
end

local function price_text(record, amount)
    if record.deal_gone then
        -- a deal that is gone: gray numbers, coin letters still in their colors (Tyler, 0.6)
        return money.to_string(amount, true, nil, aux.color.label.disabled)
    end
    return money.to_string(amount, true)
end

-- the price a deal was judged against: what a vendor pays, today's market, or the usual price (shown
-- only when it rests on enough history, as before)
function M.compared_price(record)
    if record.deal_reason == 'vendor' then
        return record.deal_vendor
    elseif record.deal_reason == 'market' then
        return record.deal_market
    end
    return record.deal_usual
end

M.columns = {
    {
        title = 'Found',
        width = .09,
        align = 'CENTER',
        fill = function(cell, record)
            if record.deal_gone then
                cell.text:SetText(aux.color.label.disabled(record.deal_bought and 'bought' or 'gone'))
            elseif time() - record.deal_found < 10 then
                cell.text:SetText(aux.color.green(ago(record.deal_found)))
            else
                cell.text:SetText(ago(record.deal_found))
            end
        end,
        cmp = function(a, b, desc)
            -- deals that sold sit below the ones still to buy, whichever way this column is sorted
            if not a.deal_gone ~= not b.deal_gone then
                return a.deal_gone and sort_util.GT or sort_util.LT
            end
            return sort_util.compare(a.deal_found, b.deal_found, desc)
        end,
    },
    auction_listing.requirement_column(),
    auction_listing.item_level_column(),
    {
        title = 'Item',
        width = .28,
        init = auction_listing.item_column_init,
        fill = function(cell, record, ...)
            auction_listing.item_column_fill(cell, record, ...)
            if record.deal_gone then
                cell.text:SetText(aux.color.label.disabled(record.name))
            end
        end,
        cmp = function(a, b, desc)
            return sort_util.compare(a.name, b.name, desc)
        end,
    },
    {
        title = 'For sale',
        width = .07,
        align = 'CENTER',
        fill = function(cell, record)
            local units = record.commodity and record.count or (record.auction_count or 1)
            cell.text:SetText(dim(record, units))
        end,
        cmp = function(a, b, desc)
            return sort_util.compare(a.count * (a.auction_count or 1), b.count * (b.auction_count or 1), desc)
        end,
    },
    {
        title = 'Price each',
        width = .12,
        align = 'RIGHT',
        fill = function(cell, record)
            cell.text:SetText(price_text(record, ceil(record.unit_buyout_price)))
        end,
        cmp = function(a, b, desc)
            return sort_util.compare(a.unit_buyout_price, b.unit_buyout_price, desc)
        end,
    },
    {
        -- review H-008, finding 7: the price the deal was compared with (usual price, today's market or
        -- vendor price, as the Why column says), so price, this, the percent and the profit add up
        title = 'Compared to',
        width = .12,
        align = 'RIGHT',
        fill = function(cell, record)
            local compared = compared_price(record)
            cell.text:SetText(compared and price_text(record, compared) or dim(record, '?'))
        end,
        cmp = function(a, b, desc)
            return sort_util.compare(compared_price(a) or 0, compared_price(b) or 0, desc)
        end,
    },
    {
        title = 'Why',
        width = .13,
        align = 'CENTER',
        fill = function(cell, record)
            -- 0.8.2 (FB-036): 'market' when today's listings put the item below its usual price
            local basis = record.deal_reason == 'market' and ' of market' or ' of usual'
            if record.deal_reason == 'vendor' then
                cell.text:SetText(record.deal_gone and aux.color.label.disabled('below vendor') or aux.color.blue('below vendor'))
            elseif record.deal_gone or not record.deal_percent then
                cell.text:SetText(aux.color.label.disabled((record.deal_percent or '?') .. '%' .. basis))
            else
                -- 0.8.2 build 5 (Tyler: "clean, consistent"): the percent in the colors of the Search
                -- tab's % Hist. Value column and the tooltip's "(67%)"
                cell.text:SetText(gui.percentage_historical(record.deal_percent) .. aux.color.label.enabled(basis))
            end
        end,
        cmp = function(a, b, desc)
            return sort_util.compare(a.deal_percent or 0, b.deal_percent or 0, desc)
        end,
    },
    {
        title = 'Profit each',
        width = .12,
        align = 'RIGHT',
        fill = function(cell, record)
            if record.deal_gone then
                cell.text:SetText(price_text(record, record.deal_profit))
            else
                cell.text:SetText(money.to_string(record.deal_profit, true, nil, aux.color.green))
            end
        end,
        cmp = function(a, b, desc)
            return sort_util.compare(a.deal_profit, b.deal_profit, desc)
        end,
    },
}

listing = auction_listing.new(frame.listing.list, 19, columns)
-- each deal on its own row (0.8, review H-004, finding 4): a gone deal never hides a live one
listing.one_row_each = true
listing.keep_selection_only = true
listing:SetSort(-1)
listing:Reset()
listing:SetHandler('OnClick', function(row, button)
    if button == 'LeftButton' then
        click_deal(row.record)
    elseif button == 'RightButton' then
        local item_id = row.record.item_id
        aux.set_tab(1)
        search_tab.search_item(item_id)
    end
end)

do
    local label = gui.label(frame.listing.list, gui.font_size.medium)
    label:SetPoint('CENTER', 0, 0)
    label:SetWidth(600)
    label:SetWordWrap(true) -- two lines; gui.label is one line by default, which cut it to "round..."
    gui.text_color(label, aux.color.label.enabled)
    empty_label = label
end

-- top row: Start / Stop and the status
do
    local btn = gui.button(frame)
    btn:SetPoint('TOPLEFT', 5, -8)
    btn:SetHeight(25)
    btn:SetWidth(90)
    btn:SetScript('OnClick', function()
        if running then stop() else start() end
    end)
    -- exported for the gamepad's Y (gamepad.lua)
    M.run_button = btn
end
do
    local label = gui.label(frame, gui.font_size.medium)
    label:SetPoint('LEFT', run_button, 'RIGHT', 12, 0)
    label:SetJustifyH('LEFT')
    status_label = label
end

-- the deal rule, on the right
do
    local btn = gui.button(frame, gui.font_size.small)
    btn:SetPoint('TOPRIGHT', -5, -8)
    btn:SetHeight(25)
    btn:SetWidth(60)
    btn:SetText('Sound')
    btn:SetScript('OnClick', function()
        aux.account_data.sniper_sound = not aux.account_data.sniper_sound
        gui.set_selected(btn, aux.account_data.sniper_sound)
    end)
    sound_button = btn
end
do
    local editbox = gui.editbox(frame)
    editbox:SetPoint('RIGHT', sound_button, 'LEFT', -14, 0)
    editbox:SetWidth(60)
    editbox:SetHeight(25)
    editbox:SetAlignment('CENTER')
    editbox.formatter = function(text)
        return money.from_string(text) and text or aux.color.red(text)
    end
    editbox.change = function(self, user)
        local amount = money.from_string(self:GetText())
        if user and amount then
            aux.account_data.sniper_profit = amount
            settings_changed()
        end
    end
    editbox.enter = function(self) self:ClearFocus() end
    editbox.focus_loss = function(self)
        self:SetText(money.to_string(aux.account_data.sniper_profit, nil, true, nil, true))
    end
    profit_input = editbox
    local label = gui.label(frame, gui.font_size.medium)
    label:SetPoint('RIGHT', editbox, 'LEFT', -6, 0)
    label:SetText('% of usual, profit at least')
    gui.text_color(label, aux.color.label.enabled)
    profit_label = label
end
do
    local editbox = gui.editbox(frame)
    editbox:SetPoint('RIGHT', profit_label, 'LEFT', -6, 0)
    editbox:SetWidth(40)
    editbox:SetHeight(25)
    editbox:SetAlignment('CENTER')
    editbox:SetNumeric(true)
    editbox.change = function(self, user)
        local pct = tonumber(self:GetText())
        if user and pct and pct >= 1 and pct <= 100 then
            aux.account_data.sniper_percent = pct
            settings_changed()
        end
    end
    editbox.enter = function(self) self:ClearFocus() end
    editbox.focus_loss = function(self)
        self:SetText(tostring(aux.account_data.sniper_percent))
    end
    percent_input = editbox
    local label = gui.label(frame, gui.font_size.medium)
    label:SetPoint('RIGHT', editbox, 'LEFT', -6, 0)
    label:SetText('Deal: at most')
    gui.text_color(label, aux.color.label.enabled)
end

gui.horizontal_line(frame, -40)

-- 0.9 build 4 (FB-055, approved Option A mockup): slim Watch bar with quick chips, More... menu
-- (Forever Categories + Search Favorites), and minimum Quality picker.
do
    local CHIP_HEIGHT = 22
    local CHIP_WIDTHS = {38, 86, 92, 62}
    local MAX_FAVORITE_ROWS = 12
    local MENU_ROW_H = 22

    local watch_bar = CreateFrame('Frame', nil, frame)
    watch_bar:SetPoint('TOPLEFT', frame, 'TOPLEFT', 0, -45)
    watch_bar:SetPoint('TOPRIGHT', frame, 'TOPRIGHT', 0, -45)
    watch_bar:SetHeight(24)

    local watch_label = gui.label(watch_bar, gui.font_size.small)
    watch_label:SetPoint('LEFT', watch_bar, 'LEFT', 10, 0)
    watch_label:SetText('Watch')
    gui.text_color(watch_label, aux.color.label.enabled)

    local chips = {}
    local prev = watch_label
    for i, entry in ipairs(QUICK_SCOPES) do
        local btn = gui.button(watch_bar, gui.font_size.small)
        gui.set_size(btn, CHIP_WIDTHS[i] or 76, CHIP_HEIGHT)
        if i == 1 then
            btn:SetPoint('LEFT', prev, 'RIGHT', 8, 0)
        else
            btn:SetPoint('LEFT', prev, 'RIGHT', 4, 0)
        end
        btn:SetText(entry.label)
        btn.scope = entry
        btn:SetScript('OnClick', function()
            set_scope(entry)
        end)
        chips[i] = btn
        prev = btn
    end
    M.watch_chips = chips

    local more_btn = gui.button(watch_bar, gui.font_size.small)
    gui.set_size(more_btn, 148, CHIP_HEIGHT)
    more_btn:SetPoint('LEFT', prev, 'RIGHT', 4, 0)
    more_btn:SetText('More... v')
    M.more_button = more_btn

    local quality_title = gui.label(watch_bar, gui.font_size.small)
    quality_title:SetPoint('LEFT', more_btn, 'RIGHT', 16, 0)
    quality_title:SetText('Quality')
    gui.text_color(quality_title, aux.color.label.enabled)

    local quality_btn = gui.button(watch_bar, gui.font_size.small)
    gui.set_size(quality_btn, 96, CHIP_HEIGHT)
    quality_btn:SetPoint('LEFT', quality_title, 'RIGHT', 6, 0)
    quality_btn:SetText('Common+ v')
    M.quality_button = quality_btn

    local hint = gui.label(watch_bar, gui.font_size.small)
    hint:SetPoint('LEFT', quality_btn, 'RIGHT', 12, 0)
    hint:SetPoint('RIGHT', watch_bar, 'RIGHT', -10, 0)
    hint:SetJustifyH('RIGHT')
    hint:SetWordWrap(false)
    gui.text_color(hint, aux.color.label.disabled)
    M.scope_hint_label = hint

    -- Grouped More... popup menu (Categories + Search Favorites)
    local watch_menu = CreateFrame('Frame', nil, frame, 'BackdropTemplate')
    gui.set_panel_style(watch_menu)
    watch_menu:SetFrameStrata('DIALOG')
    watch_menu:SetClampedToScreen(true)
    watch_menu:EnableMouse(true)
    watch_menu:SetPoint('TOPLEFT', more_btn, 'BOTTOMLEFT', 0, -3)
    watch_menu:Hide()
    M.watch_menu = watch_menu

    local watch_menu_buttons, watch_menu_headers = {}, {}
    M.watch_menu_buttons = watch_menu_buttons

    local function menu_header(index, y, text)
        local lbl = watch_menu_headers[index]
        if not lbl then
            lbl = gui.label(watch_menu, gui.font_size.small)
            gui.text_color(lbl, aux.color.accent.background)
            watch_menu_headers[index] = lbl
        end
        lbl:ClearAllPoints()
        lbl:SetPoint('TOPLEFT', 10, y)
        lbl:SetText(text)
        lbl:Show()
        return lbl
    end

    local function menu_button(index, y, width, text, selected, on_click, full_tip)
        local btn = watch_menu_buttons[index]
        if not btn then
            btn = gui.button(watch_menu, gui.font_size.small)
            local fs = btn:GetFontString()
            if fs then
                fs:SetJustifyH('LEFT')
                fs:ClearAllPoints()
                fs:SetPoint('LEFT', 8, 0)
                fs:SetPoint('RIGHT', -8, 0)
            end
            watch_menu_buttons[index] = btn
        end
        btn:ClearAllPoints()
        btn:SetPoint('TOPLEFT', 8, y)
        gui.set_size(btn, width, MENU_ROW_H)
        btn:SetText(text)
        gui.style_choice(btn, selected)
        btn:SetScript('OnClick', on_click)
        if full_tip then
            btn:SetScript('OnEnter', function(self)
                GameTooltip:SetOwner(self, 'ANCHOR_RIGHT')
                GameTooltip:AddLine(full_tip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            btn:SetScript('OnLeave', function() GameTooltip:Hide() end)
        else
            btn:SetScript('OnEnter', nil)
            btn:SetScript('OnLeave', nil)
        end
        btn:Show()
        return btn
    end

    local empty_fav_note = gui.label(watch_menu, gui.font_size.small)
    gui.text_color(empty_fav_note, aux.color.label.disabled)
    empty_fav_note:SetText('Pin searches on Search tab')
    empty_fav_note:Hide()

    local function populate_watch_menu()
        local MENU_W = 246
        local BTN_W = MENU_W - 16
        local current = get_scope()
        local hi, bi = 0, 0
        local y = -8

        for _, h in ipairs(watch_menu_headers) do h:Hide() end
        for _, b in ipairs(watch_menu_buttons) do b:Hide() end
        empty_fav_note:Hide()

        -- Section 1: Categories
        hi = hi + 1
        menu_header(hi, y, 'CATEGORIES')
        y = y - 16
        for _, cat_name in ipairs(available_categories()) do
            local entry = {kind = 'category', name = cat_name}
            bi = bi + 1
            menu_button(bi, y, BTN_W, cat_name, same_scope(current, entry), function()
                watch_menu:Hide()
                set_scope(entry)
            end)
            y = y - (MENU_ROW_H + 2)
        end

        -- Section 2: Search Favorites
        y = y - 6
        hi = hi + 1
        menu_header(hi, y, 'SEARCH FAVORITES')
        y = y - 16
        local favs = favorite_scopes()
        if #favs == 0 then
            empty_fav_note:ClearAllPoints()
            empty_fav_note:SetPoint('TOPLEFT', 10, y - 2)
            empty_fav_note:Show()
            y = y - 20
        else
            local shown = min(#favs, MAX_FAVORITE_ROWS)
            for i = 1, shown do
                local fav = favs[i]
                local label = #fav.name > 28 and (strsub(fav.name, 1, 26) .. '..') or fav.name
                bi = bi + 1
                menu_button(bi, y, BTN_W, label, same_scope(current, fav), function()
                    watch_menu:Hide()
                    set_scope(fav)
                end, fav.filter_string)
                y = y - (MENU_ROW_H + 2)
            end
        end

        gui.set_size(watch_menu, MENU_W, max(40, -y + 8))
    end

    -- Minimum Quality popup menu
    local quality_menu = CreateFrame('Frame', nil, frame, 'BackdropTemplate')
    gui.set_panel_style(quality_menu)
    quality_menu:SetFrameStrata('DIALOG')
    quality_menu:SetClampedToScreen(true)
    quality_menu:EnableMouse(true)
    quality_menu:SetPoint('TOPLEFT', quality_btn, 'BOTTOMLEFT', 0, -3)
    quality_menu:Hide()
    M.quality_menu = quality_menu

    local quality_menu_buttons = {}
    for i, opt in ipairs(QUALITY_OPTIONS) do
        local q_val, q_text = opt[1], opt[2]
        local b = gui.button(quality_menu, gui.font_size.small)
        gui.set_size(b, 108, MENU_ROW_H)
        b:SetPoint('TOPLEFT', 8, -8 - (i - 1) * (MENU_ROW_H + 2))
        b:SetText(q_text)
        b:SetScript('OnClick', function()
            quality_menu:Hide()
            set_quality(q_val)
        end)
        quality_menu_buttons[i] = b
    end
    gui.set_size(quality_menu, 124, 16 + #QUALITY_OPTIONS * (MENU_ROW_H + 2) - 2)
    M.quality_menu_buttons = quality_menu_buttons

    local function bind_outside_close(menu_frame, anchor_btn)
        menu_frame:SetScript('OnEvent', function(self)
            if self:IsShown() and not self:IsMouseOver() and not anchor_btn:IsMouseOver() then
                self:Hide()
            end
        end)
        menu_frame:HookScript('OnShow', function(self)
            pcall(self.RegisterEvent, self, 'GLOBAL_MOUSE_DOWN')
        end)
        menu_frame:HookScript('OnHide', function(self)
            pcall(self.UnregisterEvent, self, 'GLOBAL_MOUSE_DOWN')
        end)
    end
    bind_outside_close(watch_menu, more_btn)
    bind_outside_close(quality_menu, quality_btn)

    more_btn:SetScript('OnClick', function()
        quality_menu:Hide()
        if watch_menu:IsShown() then
            watch_menu:Hide()
        else
            populate_watch_menu()
            watch_menu:Show()
        end
    end)
    more_btn:SetScript('OnEnter', function(self)
        local current = get_scope()
        local matched_chip = false
        for _, chip in ipairs(chips) do
            if same_scope(current, chip.scope) then
                matched_chip = true
                break
            end
        end
        GameTooltip:SetOwner(self, 'ANCHOR_BOTTOM')
        if not matched_chip and (current.kind == 'favorite' or current.kind == 'category') then
            GameTooltip:AddLine('Watch: ' .. scope_label(current))
            if current.filter_string then
                GameTooltip:AddLine(current.filter_string, 1, 1, 1, true)
            end
        else
            GameTooltip:AddLine('More categories and Search Favorites')
            GameTooltip:AddLine('Watch any auction house category or any pinned Search Favorite.', 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    more_btn:SetScript('OnLeave', function() GameTooltip:Hide() end)

    quality_btn:SetScript('OnClick', function()
        watch_menu:Hide()
        if quality_menu:IsShown() then
            quality_menu:Hide()
        else
            local cur_q = get_quality()
            for i, opt in ipairs(QUALITY_OPTIONS) do
                gui.style_choice(quality_menu_buttons[i], opt[1] == cur_q)
            end
            quality_menu:Show()
        end
    end)

    frame:HookScript('OnHide', function()
        watch_menu:Hide()
        quality_menu:Hide()
    end)

    function M.update_scope_controls()
        local current = get_scope()
        local cur_q = get_quality()
        local matched_chip = false
        for _, chip in ipairs(chips) do
            local active = same_scope(current, chip.scope)
            if active then matched_chip = true end
            gui.style_choice(chip, active)
        end
        if matched_chip then
            more_btn:SetText('More... v')
            gui.style_choice(more_btn, false)
        else
            local label = scope_label(current)
            if #label > 17 then
                label = strsub(label, 1, 15) .. '..'
            end
            more_btn:SetText(label .. ' v')
            gui.style_choice(more_btn, true)
        end
        quality_btn:SetText(quality_label(cur_q) .. ' v')
        gui.style_choice(quality_btn, cur_q > 1)
        if current.kind == 'all' and cur_q <= 1 then
            hint:SetText('Whole AH (grays skipped)')
            gui.text_color(hint, aux.color.label.disabled)
        else
            hint:SetText('Narrow scope: ' .. watch_summary(current, cur_q))
            gui.text_color(hint, aux.color.label.enabled)
        end
    end
end

gui.horizontal_line(frame, -74)

-- third row: the deals and what to do with them (anchored above frame.listing)
do
    local label = gui.label(frame, gui.font_size.large)
    label:SetPoint('BOTTOMLEFT', frame.listing, 'TOPLEFT', 10, 10)
    label:SetJustifyH('LEFT')
    deals_label = label
end
do
    local btn = gui.button(frame, gui.font_size.small)
    btn:SetPoint('BOTTOMRIGHT', frame.listing, 'TOPRIGHT', -10, 6)
    btn:SetHeight(22)
    btn:SetWidth(60)
    btn:SetText('Clear')
    btn:SetScript('OnClick', function() clear_deals() end)
    clear_button = btn
end
-- 0.9.1: the ignore list as text, to copy out (Ctrl+C) or paste in from another account or computer
do
    local W, H = 460, 340
    local dialog = CreateFrame('Frame', nil, frame, 'BackdropTemplate')
    gui.set_panel_style(dialog)
    dialog:SetFrameStrata('FULLSCREEN_DIALOG')
    dialog:SetClampedToScreen(true)
    dialog:EnableMouse(true)
    dialog:SetPoint('CENTER', aux.frame, 'CENTER', 0, 0)
    gui.set_size(dialog, W, H)
    dialog:Hide()
    M.ignore_text_dialog = dialog

    local title = gui.label(dialog, gui.font_size.medium)
    title:SetPoint('TOPLEFT', 12, -10)
    title:SetText('Sniper ignore list')
    gui.text_color(title, aux.color.accent.background)
    local note = gui.label(dialog, gui.font_size.small)
    note:SetPoint('TOPLEFT', title, 'BOTTOMLEFT', 0, -4)
    note:SetPoint('RIGHT', -12, 0)
    note:SetJustifyH('LEFT')
    note:SetWordWrap(true)
    gui.text_color(note, aux.color.label.enabled)
    note:SetText('Ctrl+C copies the selected text. To import, paste an exported list here (Ctrl+V) and press Import: its entries are added to yours.')

    local box = CreateFrame('Frame', nil, dialog, 'BackdropTemplate')
    gui.set_frame_style(box, aux.color.input.background, aux.color.input.border)
    box:SetPoint('TOPLEFT', 10, -54)
    box:SetPoint('BOTTOMRIGHT', -10, 40)

    local scroll = CreateFrame('ScrollFrame', nil, box)
    scroll:SetPoint('TOPLEFT', 6, -6)
    scroll:SetPoint('BOTTOMRIGHT', -6, 6)
    scroll:EnableMouseWheel(true)

    local edit = CreateFrame('EditBox', nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(W - 32)
    edit:SetScript('OnEscapePressed', function() dialog:Hide() end)
    -- the view follows the cursor
    edit:SetScript('OnCursorChanged', function(_, _, y, _, height)
        local top = scroll:GetVerticalScroll()
        local view = scroll:GetHeight()
        if -y < top then
            scroll:SetVerticalScroll(-y)
        elseif -y + height > top + view then
            scroll:SetVerticalScroll(-y + height - view)
        end
    end)
    scroll:SetScrollChild(edit)
    scroll:SetScript('OnMouseWheel', function(self, delta)
        local most = max(0, edit:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(aux.bounded(0, most, self:GetVerticalScroll() - delta * 40))
    end)
    box:EnableMouse(true)
    box:SetScript('OnMouseDown', function() edit:SetFocus() end)

    local function button(text, width)
        local b = gui.button(dialog, gui.font_size.small)
        gui.set_size(b, width, 22)
        b:SetText(text)
        return b
    end
    local close = button('Close', 70)
    close:SetPoint('BOTTOMRIGHT', -10, 10)
    close:SetScript('OnClick', function() dialog:Hide() end)
    local import = button('Import', 70)
    import:SetPoint('RIGHT', close, 'LEFT', -5, 0)
    local select_all = button('Select all', 80)
    select_all:SetPoint('RIGHT', import, 'LEFT', -5, 0)
    select_all:SetScript('OnClick', function() edit:SetFocus(); edit:HighlightText() end)
    local result = gui.label(dialog, gui.font_size.small)
    result:SetPoint('LEFT', 12, 0)
    result:SetPoint('BOTTOM', 0, 15)
    gui.text_color(result, aux.color.label.enabled)

    import:SetScript('OnClick', function()
        local added = import_ignored(edit:GetText())
        result:SetText(added == 1 and '1 entry added.' or added .. ' entries added.')
        edit:SetText(export_ignored())
        if ignored_menu:IsShown() then populate_ignored_menu() end
    end)

    function M.show_ignore_text()
        result:SetText('')
        edit:SetText(export_ignored())
        scroll:SetVerticalScroll(0)
        dialog:Show()
        edit:SetFocus()
        edit:HighlightText()
    end
    dialog:HookScript('OnHide', function() edit:ClearFocus() end)
    frame:HookScript('OnHide', function() dialog:Hide() end)
end

-- 0.9.1: the ignored items and words in a panel under the Ignored button: a click on one takes it
-- back, and a word ("of the hierophant") ignores every item whose name holds it
do
    local MENU_W = 300
    local ROW_H = 20
    local ITEM_ROWS = 12
    local offset = 0 -- the first ignored item shown (mouse wheel)

    local btn = gui.button(frame, gui.font_size.small)
    btn:SetPoint('RIGHT', clear_button, 'LEFT', -5, 0)
    btn:SetHeight(22)
    btn:SetWidth(120)
    unignore_button = btn

    local menu = CreateFrame('Frame', nil, frame, 'BackdropTemplate')
    gui.set_panel_style(menu)
    menu:SetFrameStrata('DIALOG')
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    menu:EnableMouseWheel(true)
    menu:SetPoint('TOPRIGHT', btn, 'BOTTOMRIGHT', 0, -3)
    menu:Hide()
    M.ignored_menu = menu

    local function header(text)
        local label = gui.label(menu, gui.font_size.small)
        gui.text_color(label, aux.color.accent.background)
        label:SetText(text)
        return label
    end

    local rows = {}
    local function row(i)
        local r = rows[i]
        if not r then
            r = gui.button(menu, gui.font_size.small)
            local fs = r:GetFontString()
            if fs then
                fs:SetJustifyH('LEFT')
                fs:ClearAllPoints()
                fs:SetPoint('LEFT', 8, 0)
                fs:SetPoint('RIGHT', -64, 0)
                fs:SetWordWrap(false)
            end
            local hint = gui.label(r, gui.font_size.small)
            hint:SetPoint('RIGHT', -8, 0)
            gui.text_color(hint, aux.color.label.disabled)
            r.hint = hint
            r:SetScript('OnEnter', function(self)
                GameTooltip:SetOwner(self, 'ANCHOR_RIGHT')
                GameTooltip:AddLine(self.tip, 1, 1, 1, true)
                GameTooltip:AddLine(self.click_tip, nil, nil, nil, true)
                GameTooltip:Show()
            end)
            r:SetScript('OnLeave', function() GameTooltip:Hide() end)
            rows[i] = r
        end
        gui.set_size(r, MENU_W - 16, ROW_H)
        r.hint:SetText('unignore')
        r.click_tip = 'Click to unignore.'
        return r
    end

    local words_title = header('IGNORE NAMES CONTAINING')
    local word_input = gui.editbox(menu)
    gui.set_size(word_input, MENU_W - 16 - 54, 22)
    local add_button = gui.button(menu, gui.font_size.small)
    gui.set_size(add_button, 50, 22)
    add_button:SetText('Add')
    local items_title = header('')
    local snoozed_title = header('SNOOZED')
    local empty_note = gui.label(menu, gui.font_size.small)
    gui.text_color(empty_note, aux.color.label.disabled)
    empty_note:SetText('Nothing ignored. Select a deal and press Ignore item.')
    local all_button = gui.button(menu, gui.font_size.small)
    gui.set_size(all_button, (MENU_W - 20) / 2, 22)
    all_button:SetText('Unignore all')
    local export_button = gui.button(menu, gui.font_size.small)
    gui.set_size(export_button, (MENU_W - 20) / 2, 22)
    export_button:SetText('Export / Import')
    export_button:SetPoint('LEFT', all_button, 'RIGHT', 4, 0)
    export_button:SetScript('OnClick', function()
        menu:Hide()
        show_ignore_text()
    end)

    local function populate()
        for _, r in ipairs(rows) do r:Hide() end
        local y = -8
        local n = 0
        words_title:ClearAllPoints()
        words_title:SetPoint('TOPLEFT', 10, y)
        y = y - 16
        word_input:ClearAllPoints()
        word_input:SetPoint('TOPLEFT', 8, y)
        add_button:ClearAllPoints()
        add_button:SetPoint('LEFT', word_input, 'RIGHT', 4, 0)
        y = y - 26
        for _, word in ipairs(ignored_words()) do
            n = n + 1
            local r = row(n)
            r:ClearAllPoints()
            r:SetPoint('TOPLEFT', 8, y)
            r:SetText('"' .. word .. '"')
            r.tip = 'Every item whose name contains "' .. word .. '" is ignored.'
            r:SetScript('OnClick', function() unignore_word(word); populate() end)
            r:Show()
            y = y - (ROW_H + 2)
        end

        local items = ignored_items()
        offset = max(0, min(offset, #items - ITEM_ROWS))
        y = y - 6
        items_title:ClearAllPoints()
        items_title:SetPoint('TOPLEFT', 10, y)
        if #items > ITEM_ROWS then
            items_title:SetText(format('IGNORED ITEMS  %d-%d of %d (scroll)', offset + 1, offset + ITEM_ROWS, #items))
        else
            items_title:SetText('IGNORED ITEMS')
        end
        y = y - 16
        if #items == 0 then
            empty_note:ClearAllPoints()
            empty_note:SetPoint('TOPLEFT', 10, y - 2)
            empty_note:Show()
            y = y - 20
        else
            empty_note:Hide()
        end
        for i = offset + 1, min(#items, offset + ITEM_ROWS) do
            local item = items[i]
            n = n + 1
            local r = row(n)
            r:ClearAllPoints()
            r:SetPoint('TOPLEFT', 8, y)
            r:SetText(item.name)
            r.tip = item.name
            r:SetScript('OnClick', function() unignore(item.key); populate() end)
            r:Show()
            y = y - (ROW_H + 2)
        end

        local snoozes = snoozed_items()
        if #snoozes > 0 then
            y = y - 6
            snoozed_title:ClearAllPoints()
            snoozed_title:SetPoint('TOPLEFT', 10, y)
            snoozed_title:Show()
            y = y - 16
            for _, item in ipairs(snoozes) do
                n = n + 1
                local r = row(n)
                r:ClearAllPoints()
                r:SetPoint('TOPLEFT', 8, y)
                r:SetText(item.name)
                r.hint:SetText(ceil(item.left / 60) .. 'm left')
                r.tip = item.name
                r.click_tip = 'Click to show it again now.'
                r:SetScript('OnClick', function() unsnooze(item.key); populate() end)
                r:Show()
                y = y - (ROW_H + 2)
            end
        else
            snoozed_title:Hide()
        end

        y = y - 6
        all_button:ClearAllPoints()
        all_button:SetPoint('TOPLEFT', 8, y)
        if ignored_count() > 0 then all_button:Enable() else all_button:Disable() end
        y = y - 22
        gui.set_size(menu, MENU_W, -y + 8)
    end
    M.populate_ignored_menu = populate

    local function add_word()
        if ignore_word(word_input:GetText()) then
            word_input:SetText('')
            populate()
        end
        word_input:ClearFocus()
    end
    word_input.enter = add_word
    add_button:SetScript('OnClick', add_word)
    add_button:SetScript('OnEnter', function(self)
        GameTooltip:SetOwner(self, 'ANCHOR_RIGHT')
        GameTooltip:AddLine('Ignore names containing')
        GameTooltip:AddLine('Every item whose name contains the text (at least 3 letters, any case) is never shown as a deal, for example "of the hierophant".', 1, 1, 1, true)
        GameTooltip:Show()
    end)
    add_button:SetScript('OnLeave', function() GameTooltip:Hide() end)
    all_button:SetScript('OnClick', function() unignore_all(); populate() end)

    menu:SetScript('OnMouseWheel', function(_, delta)
        offset = offset - delta * 3
        populate()
    end)
    menu:SetScript('OnEvent', function(self)
        if self:IsShown() and not self:IsMouseOver() and not btn:IsMouseOver() then
            self:Hide()
        end
    end)
    menu:HookScript('OnShow', function(self) pcall(self.RegisterEvent, self, 'GLOBAL_MOUSE_DOWN') end)
    menu:HookScript('OnHide', function(self)
        pcall(self.UnregisterEvent, self, 'GLOBAL_MOUSE_DOWN')
        word_input:ClearFocus()
    end)
    frame:HookScript('OnHide', function() menu:Hide() end)

    btn:SetScript('OnClick', function()
        if menu:IsShown() then
            menu:Hide()
        else
            offset = 0
            populate()
            menu:Show()
        end
    end)
end
do
    local btn = gui.button(frame, gui.font_size.small)
    btn:SetPoint('RIGHT', unignore_button, 'LEFT', -5, 0)
    btn:SetHeight(22)
    btn:SetWidth(90)
    btn:SetText('Ignore item')
    btn:SetScript('OnClick', function()
        local selection = listing:GetSelection()
        if selection then
            ignore(selection.record)
        end
    end)
    btn:SetScript('OnEnter', function(self)
        GameTooltip:SetOwner(self, 'ANCHOR_BOTTOM')
        GameTooltip:AddLine('Ignore item')
        GameTooltip:AddLine('The selected item is never shown as a deal again.', 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript('OnLeave', function() GameTooltip:Hide() end)
    ignore_button = btn
end
-- 0.9.1: Snooze hides the selected deal for the minutes in the box next to it
do
    local label = gui.label(frame, gui.font_size.small)
    label:SetPoint('RIGHT', ignore_button, 'LEFT', -8, 0)
    label:SetText('min')
    gui.text_color(label, aux.color.label.enabled)
    local editbox = gui.editbox(frame)
    editbox:SetPoint('RIGHT', label, 'LEFT', -3, 0)
    editbox:SetWidth(36)
    editbox:SetHeight(22)
    editbox:SetAlignment('CENTER')
    editbox:SetNumeric(true)
    editbox.change = function(self, user)
        local minutes = tonumber(self:GetText())
        if user and minutes and minutes >= 1 then
            set_snooze_minutes(minutes)
        end
    end
    editbox.enter = function(self) self:ClearFocus() end
    editbox.focus_loss = function(self)
        self:SetText(tostring(aux.account_data.sniper_snooze_minutes))
    end
    snooze_input = editbox
    local btn = gui.button(frame, gui.font_size.small)
    btn:SetPoint('RIGHT', editbox, 'LEFT', -5, 0)
    btn:SetHeight(22)
    btn:SetWidth(70)
    btn:SetText('Snooze')
    btn:SetScript('OnClick', function()
        local selection = listing:GetSelection()
        if selection then
            snooze(selection.record)
        end
    end)
    btn:SetScript('OnEnter', function(self)
        GameTooltip:SetOwner(self, 'ANCHOR_BOTTOM')
        GameTooltip:AddLine('Snooze')
        GameTooltip:AddLine('The selected item is not shown as a deal for the minutes in the box. Snoozed items are listed under Ignored, where a click brings one back early.', 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript('OnLeave', function() GameTooltip:Hide() end)
    snooze_button = btn
end
do
    local btn = gui.button(frame, gui.font_size.small)
    btn:SetPoint('RIGHT', snooze_button, 'LEFT', -5, 0)
    btn:SetHeight(22)
    btn:SetWidth(80)
    btn:SetText('Snooze all')
    btn:SetScript('OnClick', function() snooze_all() end)
    btn:SetScript('OnEnter', function(self)
        GameTooltip:SetOwner(self, 'ANCHOR_BOTTOM')
        GameTooltip:AddLine('Snooze all')
        GameTooltip:AddLine('Every deal still to buy in the list is not shown for the minutes in the box. They are listed under Ignored, where a click brings one back early.', 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript('OnLeave', function() GameTooltip:Hide() end)
    snooze_all_button = btn
end

-- next to the deal count: the price history notice (history_notice) and a Full scan button
do
    local label = gui.label(frame, gui.font_size.small)
    label:SetPoint('LEFT', deals_label, 'RIGHT', 18, 0)
    label:SetJustifyH('LEFT')
    notice_label = label
    local btn = gui.button(frame, gui.font_size.small)
    btn:SetPoint('LEFT', label, 'RIGHT', 8, 0)
    btn:SetHeight(22)
    btn:SetWidth(70)
    btn:SetText('Full scan')
    btn:SetScript('OnClick', function()
        -- calls start_full_scan directly so cooldown reports when the next scan is ready (PR #37)
        aux.start_full_scan()
    end)
    btn:SetScript('OnEnter', function(self)
        GameTooltip:SetOwner(self, 'ANCHOR_BOTTOM')
        GameTooltip:AddLine('Full scan')
        GameTooltip:AddLine('Records the price of everything on the auction house, like the Full scan button at the top right. The game allows one every 15 minutes.', 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript('OnLeave', function() GameTooltip:Hide() end)
    btn:Hide()
    notice_button = btn
end

-- "2 to buy, 1 gone": a list of only gone deals no longer reads "0 found"
function M.deals_count(shown)
    local open, gone = 0, 0
    for _, deal in ipairs(shown) do
        if deal.deal_gone then gone = gone + 1 else open = open + 1 end
    end
    local text = open .. ' to buy'
    if gone > 0 then
        text = text .. ', ' .. gone .. ' gone'
    end
    return text
end

-- the table follows the deals; called when they change
function M.update_deals()
    local shown = shown_deals()
    listing:SetDatabase(shown)
    deals_label:SetText(aux.color.accent.background('Deals') .. '  ' .. aux.color.label.enabled(deals_count(shown)))
    if #shown > 0 then
        empty_label:SetText('')
    elseif running then
        local scope, q = get_scope(), get_quality()
        local watching = (scope.kind == 'all' and q <= 1) and 'the auction house (gray items skipped)' or watch_summary(scope, q)
        empty_label:SetText('No deals yet. Watching ' .. watching .. '.\nUsual-price deals need ' .. MIN_DAYS .. ' days of Full scans.')
    else
        empty_label:SetText('Press Start to watch ' .. watch_summary() .. ' for deals.')
    end
end

do
    local last_run, last_status, last_ignored, last_notice
    -- the controls follow the state; only touched when something changed
    function M.update_controls()
        if running ~= last_run then
            last_run = running
            run_button:SetText(running and 'Stop' or 'Start')
            if running then
                gui.set_default(run_button)
                local _, size = run_button:GetFontString():GetFont()
                run_button:GetFontString():SetFont(gui.font, size and size > 0 and size or gui.font_size.medium)
            else
                gui.set_primary(run_button)
            end
            update_deals()
        end
        local title, detail = status()
        local text = aux.color.text.enabled(title) .. '   ' .. aux.color.label.enabled(detail)
        if text ~= last_status then
            last_status = text
            status_label:SetText(text)
        end
        -- the price history notice; redrawn, and its button shown or hidden, only when it changes
        local notice, kind = history_notice(time(), aux.account_data.replicate_time, history_days, history_days_known)
        if notice ~= last_notice then
            last_notice = notice
            notice_label:SetText(notice and (kind == 'stale' and aux.color.orange(notice) or aux.color.label.enabled(notice)) or '')
            if notice then notice_button:Show() else notice_button:Hide() end
        end
        local ignored = ignored_count()
        if ignored ~= last_ignored then
            last_ignored = ignored
            unignore_button:SetText(ignored > 0 and 'Ignored (' .. ignored .. ') v' or 'Ignored v')
            if ignored_menu:IsShown() then populate_ignored_menu() end
        end
    end
end

function aux.event.AUX_LOADED()
    percent_input:SetText(tostring(aux.account_data.sniper_percent))
    profit_input:SetText(money.to_string(aux.account_data.sniper_profit, nil, true, nil, true))
    snooze_input:SetText(tostring(aux.account_data.sniper_snooze_minutes))
    gui.set_selected(sound_button, aux.account_data.sniper_sound)
    update_scope_controls()
end
