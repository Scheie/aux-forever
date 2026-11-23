-- usage: lua merge_accounts.lua <addon dir> <account #1 file> <account #2 file> <output file>
local root, src_file, dst_file, out_file = arg[1], arg[2], arg[3], arg[4]
local modules = {}
local function loadmod(name, file, M)
  M = M or {}
  local env = setmetatable({M = M, empty = setmetatable({}, {__newindex = function() end}), tinsert = table.insert, tremove = table.remove, sort = table.sort,
    min = math.min, max = math.max, floor = math.floor, ceil = math.ceil, strmatch = string.match, strsub = string.sub, strupper = string.upper,
    gsub = string.gsub, strfind = string.find, format = string.format, strlen = string.len, pass = function() end,
    require = function(n) modules[n] = modules[n] or {}; return modules[n] end, date = os.date, time = os.time,
    GetRealmName = function() return '' end,
    CreateFrame = function() return {RegisterEvent = function() end, SetScript = function() end} end},
    {__index = function(_, k) local v = M[k]; if v ~= nil then return v end; return _G[k] end, __newindex = function(_, k, v) M[k] = v end})
  assert(loadfile(root .. '/' .. file, 't', env))(nil, function() end)
  modules[name] = M
  return M
end
local util = loadmod('aux', 'util.lua'); util.event = setmetatable({}, {__newindex = function() end}); util.coro_thread = function() end
loadmod('aux.util.persistence', 'util/persistence.lua')
modules['aux.core.history'] = {}
local history = loadmod('aux.core.history', 'core/history.lua', modules['aux.core.history'])
local A = loadmod('aux', 'aux-addon.lua', util)

local function read_saved(file)
  local env = {}
  assert(loadfile(file, 't', env))()
  return env.aux
end
local src, dst = read_saved(src_file), read_saved(dst_file)

-- 1. #2's subrealm and blank keys joined into its realm groups, as the addon does at load
_G.aux = dst
print('account #2 keys joined:', A.join_realms(nil))

-- 2. #1's price history into #2, each faction only into the same faction
local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
for key, faction in pairs(src.faction or {}) do
  local realm, side = string.match(key, '^(.-)|(.+)$')
  if realm and faction.history and (faction.history_version == 2 or faction.history_version == 3) then
    local target_key = A.realm_group(realm) .. '|' .. side
    local target = dst.faction[target_key]
    if not target then
      target = {history = {}, post = {}, history_version = 3}
      dst.faction[target_key] = target
    end
    target.history = target.history or {}
    local before, merged, added = count(target.history), 0, 0
    for item, line in pairs(faction.history) do
      if target.history[item] then merged = merged + 1 else added = added + 1 end
      target.history[item] = history.merge_lines(target.history[item], line)
    end
    if faction.price_keys_since then
      target.price_keys_since = math.min(target.price_keys_since or faction.price_keys_since, faction.price_keys_since)
    end
    target.history_trimmed = nil
    print(string.format('%s -> %s: %d items before, %d merged with existing, %d new, %d after', key, target_key, before, merged, added, count(target.history)))
  else
    print('skipped ' .. key .. ' (no usable price history)')
  end
end

-- 3. written back as WoW writes saved variables: aux = { ... }
local out = {}
local function w(s) out[#out + 1] = s end
local function key_text(k)
  if type(k) == 'string' then return '[' .. string.format('%q', k) .. ']' end
  return '[' .. (math.type(k) == 'integer' and string.format('%d', k) or string.format('%.17g', k)) .. ']'
end
local function value_text(v)
  local t = type(v)
  if t == 'string' then return string.format('%q', v)
  elseif t == 'boolean' then return tostring(v)
  elseif t == 'number' then
    if math.type(v) == 'integer' or (v == math.floor(v) and math.abs(v) < 2^53) then return string.format('%d', v) end
    return string.format('%.17g', v)
  end
  error('cannot write a ' .. t)
end
local function write_table(t)
  w('{\n')
  for k, v in pairs(t) do
    w(key_text(k)); w(' = ')
    if type(v) == 'table' then write_table(v) else w(value_text(v)) end
    w(',\n')
  end
  w('}')
end
w('\naux = ')
write_table(dst)
w('\n')
local f = assert(io.open(out_file, 'w'))
f:write(table.concat(out))
f:close()

-- check: the written file reads back as the same data
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
print('written file reads back identical:', same(read_saved(out_file), dst))
local keys = {} for k in pairs(dst.faction) do keys[#keys + 1] = '[' .. k .. ']' end
print('account #2 faction tables now:', table.concat(keys, ' '))
