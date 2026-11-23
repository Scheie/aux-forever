-- auxForever price history sync between WoW accounts (union sync).
--
-- usage: lua sync.lua <WTF/Account folder> [<state folder>]
--
-- Every WoW account has its own WTF/Account/<account>/SavedVariables/auxForever.lua, and an addon
-- can only read its own account's file. This script runs whenever one of those files changes
-- (launchd, no.auxforever.sync.plist): it merges the price history of all accounts' files and writes
-- the merged history into every file that lacks some of it.
--
-- - Union, not one-way: a running game overwrites its own file at its next save, but the other files
--   keep everything, and the next run (after that save) restores the full set. Nothing is lost.
-- - A running game only sees the merged prices after it enters the world again (log out to character
--   select, wait a few seconds, log in). /reload does not help: WoW saves first, then reads that.
-- - Per realm group and faction, as auxForever 0.9.1 keys them ("EU PvE|Alliance"): Alliance prices
--   only ever join Alliance prices, Horde only Horde.
-- - Only the price history (faction .history) is synced. Settings, favorites, Post data and
--   character data stay per account.
-- - A file is written only when it gains something, through a temporary file that is read back and
--   checked before it replaces the original; the original is kept in backups/ (the last BACKUPS).

local WTF_ACCOUNTS = assert(arg[1], 'usage: lua sync.lua <WTF/Account folder> [<state folder>]')
local HOME = arg[2] or (os.getenv('HOME') .. '/Library/Application Support/auxForever-sync')
local FILE_NAME = 'auxForever.lua'
local BACKUPS = 5
local SETTLE_SECONDS = 3 -- a file must be this old before it is read (WoW done writing it)
local SETTLE_WAIT = 60
local MAX_POINTS = 14 -- core/history.lua MAX_POINTS
local LOG_LIMIT = 1024 * 1024

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function log(text)
    local path = HOME .. '/sync.log'
    local f = io.open(path, 'r')
    if f then
        local size = f:seek('end')
        f:close()
        if size > LOG_LIMIT then
            os.rename(path, path .. '.old')
        end
    end
    f = io.open(path, 'a')
    if f then
        f:write(os.date('%Y-%m-%d %H:%M:%S  '), text, '\n')
        f:close()
    end
end

local function command_lines(cmd)
    local lines = {}
    local p = io.popen(cmd)
    for line in p:lines() do
        lines[#lines + 1] = line
    end
    p:close()
    return lines
end

-- modification time and size, or nil when the file is missing
local function stat(path)
    local out = command_lines('stat -f "%m %z" ' .. shell_quote(path) .. ' 2>/dev/null')[1]
    if out then
        local mtime, size = out:match('^(%d+) (%d+)$')
        return tonumber(mtime), tonumber(size)
    end
end

-- the accounts' saved files, sorted (the merge order is then the same every run)
local function account_files()
    local files = {}
    for _, dir in ipairs(command_lines('ls -1 ' .. shell_quote(WTF_ACCOUNTS) .. ' 2>/dev/null')) do
        local path = WTF_ACCOUNTS .. '/' .. dir .. '/SavedVariables/' .. FILE_NAME
        if stat(path) then
            files[#files + 1] = {account = dir, path = path}
        end
    end
    table.sort(files, function(a, b) return a.path < b.path end)
    return files
end

-- state: each file's "mtime size" after the last run, so a run for a change it made itself (or for
-- another file in the folder) ends at once
local function read_state()
    local state = {}
    local f = io.open(HOME .. '/state', 'r')
    if f then
        for line in f:lines() do
            local mtime, size, path = line:match('^(%d+) (%d+) (.+)$')
            if path then
                state[path] = mtime .. ' ' .. size
            end
        end
        f:close()
    end
    return state
end

local function write_state(files)
    local f = io.open(HOME .. '/state', 'w')
    for _, file in ipairs(files) do
        local mtime, size = stat(file.path)
        if mtime then
            f:write(mtime, ' ', size, ' ', file.path, '\n')
        end
    end
    f:close()
end

-- saved variables

local function load_saved(path)
    local env = {}
    local chunk, err = loadfile(path, 't', env)
    if not chunk then
        return nil, err
    end
    local ok, run_err = pcall(chunk)
    if not ok then
        return nil, run_err
    end
    if type(env.aux) ~= 'table' then
        return nil, 'no aux table'
    end
    return env.aux
end

-- written as WoW writes saved variables: aux = { ... }
local function serialize(aux)
    local out = {}
    local function w(s) out[#out + 1] = s end
    local function number_text(v)
        if math.type(v) == 'integer' or (v == math.floor(v) and math.abs(v) < 2 ^ 53) then
            return string.format('%d', v)
        end
        return string.format('%.17g', v)
    end
    local function key_text(k)
        if type(k) == 'string' then
            return '[' .. string.format('%q', k) .. ']'
        end
        return '[' .. number_text(k) .. ']'
    end
    local function value(v)
        local t = type(v)
        if t == 'table' then
            w('{\n')
            for k, x in pairs(v) do
                w(key_text(k)); w(' = '); value(x); w(',\n')
            end
            w('}')
        elseif t == 'string' then
            w(string.format('%q', v))
        elseif t == 'number' then
            w(number_text(v))
        elseif t == 'boolean' then
            w(tostring(v))
        else
            error('cannot write a ' .. t)
        end
    end
    w('\naux = ')
    value(aux)
    w('\n')
    return table.concat(out)
end

local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- realm groups, as auxForever 0.9.1's realm_group (aux-addon.lua)

local REGIONS = {EU = true, US = true, NA = true, OCE = true, KR = true, TW = true, CN = true}
local REALM_KINDS = {PVE = 'PvE', PVP = 'PvP', RP = 'RP', RPPVP = 'RPPvP'}
local function realm_group(name)
    if not name or name == '' then
        return ''
    end
    local region, kind
    for word in name:gmatch('%S+') do
        local letters = word:match('^(%a+)%d*$')
        if not region and letters and REGIONS[letters:upper()] then
            region = letters:upper()
        end
        kind = REALM_KINDS[word:upper()]
    end
    if region and kind then
        return region .. ' ' .. kind
    end
    return name
end

-- history lines, as auxForever 0.9.1's history.merge_lines (core/history.lua):
-- day#low#market#units#points, points day@value@units joined by ';'

local function split(s, sep)
    local parts, from = {}, 1
    while true do
        local i = s:find(sep, from, true)
        if not i then
            parts[#parts + 1] = s:sub(from)
            return parts
        end
        parts[#parts + 1] = s:sub(from, i - 1)
        from = i + 1
    end
end

-- nil for a 0.4 line (it starts with a timestamp); the addon converts those when it reads them
local function parse(line)
    local first = tonumber(line:match('^[^#]*'))
    if first and first > 1e7 then
        return nil
    end
    local p = split(line, '#')
    local record = {day = tonumber(p[1]), low = tonumber(p[2]), market = tonumber(p[3]), units = tonumber(p[4]), points = {}}
    if p[5] and p[5] ~= '' then
        for _, part in ipairs(split(p[5], ';')) do
            local q = split(part, '@')
            record.points[#record.points + 1] = {day = tonumber(q[1]), value = tonumber(q[2]), units = tonumber(q[3])}
        end
    end
    return record
end

local function text(n)
    return n and tostring(n) or ''
end

local function merge_lines(a, b)
    if not a or not b then
        return a or b
    end
    if a == b then
        return a
    end
    local ra, rb = parse(a), parse(b)
    if not ra or not rb then
        -- a 0.4 line: keep the newer-format one, else the first
        return ra and a or rb and b or a
    end
    local days, order = {}, {}
    local function add(day, low, market, units)
        if not day then
            return
        end
        local known = days[day]
        if not known then
            days[day] = {low = low, market = market, units = market and units or nil}
            order[#order + 1] = day
            return
        end
        -- two markets for one day: the look that saw more units wins (ties: the lower price)
        if market and (not known.market or (units or 0) > (known.units or 0)
            or (units or 0) == (known.units or 0) and market < known.market) then
            known.market, known.units = market, units
        end
        if low and (not known.low or low < known.low) then
            known.low = low
        end
    end
    for _, record in ipairs{ra, rb} do
        if record.low or record.market then
            add(record.day, record.low, record.market, record.units)
        end
        for _, point in ipairs(record.points) do
            add(point.day, not point.units and point.value or nil, point.units and point.value or nil, point.units)
        end
    end
    if not order[1] then
        return a
    end
    table.sort(order, function(x, y) return x > y end)
    local newest = days[order[1]]
    local points = {}
    for i = 2, math.min(#order, MAX_POINTS + 1) do
        local day = days[order[i]]
        local units = day.market and day.units or nil
        points[#points + 1] = text(order[i]) .. '@' .. text(day.market or day.low) .. '@' .. text(units)
    end
    return table.concat({text(order[1]), text(newest.low), text(newest.market), text(newest.units), table.concat(points, ';')}, '#')
end

-- the realm group a faction key belongs to in one file ("" realm: the file's one group, if one)
local function faction_groups(aux)
    local groups, only = {}, nil
    for key in pairs(aux.faction or {}) do
        local realm = key:match('^(.-)|')
        if realm and realm ~= '' then
            local group = realm_group(realm)
            if only == nil then
                only = group
            elseif only ~= group then
                only = false
            end
        end
    end
    for key, faction in pairs(aux.faction or {}) do
        local realm, side = key:match('^(.-)|(.+)$')
        if realm and type(faction) == 'table' and type(faction.history) == 'table'
            and (faction.history_version == 2 or faction.history_version == 3) then
            local group = realm ~= '' and realm_group(realm) or only or nil
            if group then
                groups[key] = group .. '|' .. side
            end
        end
    end
    return groups
end

local function backup(file)
    local dir = HOME .. '/backups'
    local name = file.account:gsub('[^%w]', '_') .. '-' .. os.date('%Y%m%d-%H%M%S') .. '.lua'
    local ok = os.execute('cp -p ' .. shell_quote(file.path) .. ' ' .. shell_quote(dir .. '/' .. name))
    if not ok then
        return false
    end
    local mine = {}
    local prefix = file.account:gsub('[^%w]', '_') .. '-'
    for _, entry in ipairs(command_lines('ls -1 ' .. shell_quote(dir))) do
        if entry:sub(1, #prefix) == prefix then
            mine[#mine + 1] = entry
        end
    end
    table.sort(mine)
    for i = 1, #mine - BACKUPS do
        os.remove(dir .. '/' .. mine[i])
    end
    return true
end

-- run

local function main()
    local files = account_files()
    if #files < 2 then
        return
    end
    local state = read_state()
    local changed = false
    for _, file in ipairs(files) do
        local mtime, size = stat(file.path)
        if state[file.path] ~= mtime .. ' ' .. size then
            changed = true
        end
    end
    if not changed then
        return
    end

    -- wait until no file was written in the last SETTLE_SECONDS
    local waited = 0
    while true do
        local newest = 0
        for _, file in ipairs(files) do
            newest = math.max(newest, stat(file.path) or 0)
        end
        if os.time() - newest >= SETTLE_SECONDS or waited >= SETTLE_WAIT then
            break
        end
        os.execute('sleep 1')
        waited = waited + 1
    end

    for _, file in ipairs(files) do
        local aux, err = load_saved(file.path)
        if not aux then
            -- half written, or damaged: leave everything alone, the next save runs this again
            log('skipped: cannot read ' .. file.account .. ' (' .. tostring(err) .. ')')
            return
        end
        file.aux = aux
        file.groups = faction_groups(aux)
        file.mtime = stat(file.path)
    end

    -- the union of every file's history, per realm group and faction
    local union = {}
    for _, file in ipairs(files) do
        local keys = {}
        for key in pairs(file.groups) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local target = file.groups[key]
            union[target] = union[target] or {}
            local u = union[target]
            for item, line in pairs(file.aux.faction[key].history) do
                if type(line) == 'string' then
                    u[item] = merge_lines(u[item], line)
                end
            end
        end
    end

    for _, file in ipairs(files) do
        local added, updated = 0, 0
        for target, history in pairs(union) do
            local faction = file.aux.faction[target]
            if not faction then
                faction = {history = {}, post = {}, history_version = 3}
            end
            faction.history = faction.history or {}
            local missing = false
            for item, line in pairs(history) do
                local current = faction.history[item]
                if current ~= line then
                    missing = true
                    if current then updated = updated + 1 else added = added + 1 end
                    faction.history[item] = line
                end
            end
            if missing then
                file.aux.faction = file.aux.faction or {}
                file.aux.faction[target] = faction
            end
        end
        if added + updated > 0 then
            -- a game saved this file while we worked: leave it, the run after that save merges it
            if stat(file.path) ~= file.mtime then
                log('skipped ' .. file.account .. ': it changed during the merge')
            else
                local tmp = file.path .. '.auxsync-tmp'
                local f = assert(io.open(tmp, 'w'))
                f:write(serialize(file.aux))
                f:close()
                local check = load_saved(tmp)
                if not check or not same(check, file.aux) then
                    os.remove(tmp)
                    log('ERROR: ' .. file.account .. ' did not read back identical; not written')
                elseif not backup(file) then
                    os.remove(tmp)
                    log('ERROR: could not back up ' .. file.account .. '; not written')
                else
                    assert(os.rename(tmp, file.path))
                    log(string.format('%s: %d items added, %d items updated', file.account, added, updated))
                end
            end
        end
    end
    write_state(files)
end

local ok, err = pcall(main)
if not ok then
    log('ERROR: ' .. tostring(err))
    os.exit(1)
end
