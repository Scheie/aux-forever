-- auxForever price history sync between WoW accounts (union sync). macOS and Windows; Lua 5.3+.
--
-- usage: lua sync.lua <WTF/Account folder> [<state folder>]
--
-- Every WoW account has its own WTF/Account/<account>/SavedVariables/auxForever.lua, and an addon
-- can only read its own account's file. This script runs whenever one of those files changes
-- (macOS: launchd, no.auxforever.sync.plist; Windows: watch.ps1, started by Task Scheduler): it
-- merges the price history of all accounts' files and writes the merged history into every file
-- that lacks some of it.
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

local WINDOWS = package.config:sub(1, 1) == '\\'
local WTF_ACCOUNTS = assert(arg[1], 'usage: lua sync.lua <WTF/Account folder> [<state folder>]')
local HOME = arg[2] or (WINDOWS and (os.getenv('APPDATA') .. '/auxForever-sync')
    or (os.getenv('HOME') .. '/Library/Application Support/auxForever-sync'))
local FILE_NAME = 'auxForever.lua'
local BACKUPS = 5
local SETTLE_SECONDS = 3 -- a file must stay the same this long before it is used (WoW done writing)
local SETTLE_TRIES = 20
local MAX_POINTS = 14 -- core/history.lua MAX_POINTS
local LOG_LIMIT = 1024 * 1024

-- system: the few things Lua cannot do by itself

local function quote(s)
    if WINDOWS then
        return '"' .. s:gsub('/', '\\') .. '"'
    end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function command_lines(cmd)
    local lines = {}
    local p = io.popen(cmd)
    if p then
        for line in p:lines() do
            lines[#lines + 1] = line
        end
        p:close()
    end
    return lines
end

-- names in a folder: folders only, or files only
local function list(path, folders)
    if WINDOWS then
        return command_lines('dir /b ' .. (folders and '/ad ' or '/a-d ') .. quote(path) .. ' 2>nul')
    end
    return command_lines('find ' .. quote(path) .. ' -mindepth 1 -maxdepth 1 -type ' .. (folders and 'd' or 'f')
        .. ' -exec basename {} \\; 2>/dev/null')
end

local function sleep(seconds)
    if WINDOWS then
        os.execute('ping -n ' .. (seconds + 1) .. ' 127.0.0.1 >nul')
    else
        os.execute('sleep ' .. seconds)
    end
end

local function read_file(path)
    local f = io.open(path, 'rb')
    if not f then
        return nil
    end
    local content = f:read('a')
    f:close()
    return content
end

local function write_file(path, content)
    local f = io.open(path, 'wb')
    if not f then
        return false
    end
    local ok = f:write(content)
    f:close()
    return ok and true or false
end

-- a file's identity without stat (Windows has none in Lua): its size and a hash of every 997th
-- byte and the last 4 KB. Saved variables files change all over when they change at all.
local function fingerprint(content)
    if not content then
        return 'missing'
    end
    local h, n = 0, #content
    for i = 1, n, 997 do
        h = (h * 31 + content:byte(i)) % 4294967296
    end
    for i = math.max(1, n - 4095), n do
        h = (h * 31 + content:byte(i)) % 4294967296
    end
    return n .. ':' .. h
end

-- replaces path with tmp. macOS: one rename. Windows cannot rename over a file: the old one is moved
-- aside first and put back if the swap fails.
local function replace(tmp, path)
    if not WINDOWS then
        return os.rename(tmp, path)
    end
    local old = path .. '.auxsync-old'
    os.remove(old)
    if not os.rename(path, old) then
        return false
    end
    if not os.rename(tmp, path) then
        os.rename(old, path)
        return false
    end
    os.remove(old)
    return true
end

local function log(text)
    local path = HOME .. '/sync.log'
    local f = io.open(path, 'r')
    if f then
        local size = f:seek('end')
        f:close()
        if size > LOG_LIMIT then
            os.remove(path .. '.old')
            os.rename(path, path .. '.old')
        end
    end
    f = io.open(path, 'a')
    if f then
        f:write(os.date('%Y-%m-%d %H:%M:%S  '), text, '\n')
        f:close()
    end
end

-- the accounts' saved files, sorted (the merge order is then the same every run)
local function account_files()
    local files = {}
    for _, dir in ipairs(list(WTF_ACCOUNTS, true)) do
        local path = WTF_ACCOUNTS .. '/' .. dir .. '/SavedVariables/' .. FILE_NAME
        local f = io.open(path, 'rb')
        if f then
            f:close()
            files[#files + 1] = {account = dir, path = path}
        end
    end
    table.sort(files, function(a, b) return a.path < b.path end)
    return files
end

-- state: each file's fingerprint after the last run, so a run for a change it made itself (or for
-- another file in the folder) ends at once
local function read_state()
    local state = {}
    local f = io.open(HOME .. '/state', 'r')
    if f then
        for line in f:lines() do
            local print_, path = line:match('^(%S+) (.+)$')
            if path then
                state[path] = print_
            end
        end
        f:close()
    end
    return state
end

local function write_state(files)
    local f = io.open(HOME .. '/state', 'w')
    if f then
        for _, file in ipairs(files) do
            f:write(fingerprint(read_file(file.path)), ' ', file.path, '\n')
        end
        f:close()
    end
end

-- saved variables

local function load_saved(content, name)
    local env = {}
    local chunk, err = load(content, '=' .. name, 't', env)
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
    local prefix = file.account:gsub('[^%w]', '_') .. '-'
    if not write_file(dir .. '/' .. prefix .. os.date('%Y%m%d-%H%M%S') .. '.lua', file.content) then
        return false
    end
    local mine = {}
    for _, entry in ipairs(list(dir, false)) do
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
        if state[file.path] ~= fingerprint(read_file(file.path)) then
            changed = true
        end
    end
    if not changed then
        return
    end

    -- wait until no file changed for SETTLE_SECONDS (a game may still be writing)
    local prints = {}
    for _, file in ipairs(files) do prints[file.path] = fingerprint(read_file(file.path)) end
    for _ = 1, SETTLE_TRIES do
        sleep(SETTLE_SECONDS)
        local settled = true
        for _, file in ipairs(files) do
            local now = fingerprint(read_file(file.path))
            if now ~= prints[file.path] then
                settled, prints[file.path] = false, now
            end
        end
        if settled then
            break
        end
    end

    for _, file in ipairs(files) do
        file.content = read_file(file.path)
        local aux, err
        if file.content then
            aux, err = load_saved(file.content, file.account)
        else
            err = 'missing'
        end
        if not aux then
            -- half written, or damaged: leave everything alone, the next save runs this again
            log('skipped: cannot read ' .. file.account .. ' (' .. tostring(err) .. ')')
            return
        end
        file.aux = aux
        file.groups = faction_groups(aux)
        file.print = fingerprint(file.content)
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
            if fingerprint(read_file(file.path)) ~= file.print then
                log('skipped ' .. file.account .. ': it changed during the merge')
            else
                local tmp = file.path .. '.auxsync-tmp'
                local content = serialize(file.aux)
                local check = write_file(tmp, content) and load_saved(read_file(tmp) or '', file.account)
                if not check or not same(check, file.aux) then
                    os.remove(tmp)
                    log('ERROR: ' .. file.account .. ' did not read back identical; not written')
                elseif not backup(file) then
                    os.remove(tmp)
                    log('ERROR: could not back up ' .. file.account .. '; not written')
                elseif not replace(tmp, file.path) then
                    os.remove(tmp)
                    log('ERROR: could not replace ' .. file.account .. '; not written')
                else
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
