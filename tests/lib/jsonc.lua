-- Minimaler Ersatz fuer OpenWrts jsonc (C-Modul aus libubox), nur so weit,
-- wie Gluons site_config.lua und check-site.lua es brauchen: stringify und
-- load. Reines Lua 5.1, damit der Check ohne Buildumgebung laeuft.
local M = {}

local escape_map = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape(s)
  return (s:gsub('[%c"\\]', function(c)
    return escape_map[c] or string.format('\\u%04x', c:byte())
  end))
end

local function ist_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' then return false end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true, n
end

local function enc(v)
  local tv = type(v)
  if v == nil then return 'null'
  elseif tv == 'boolean' then return tostring(v)
  elseif tv == 'number' then
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
    return tostring(v)
  elseif tv == 'string' then return '"' .. escape(v) .. '"'
  elseif tv == 'table' then
    local arr, n = ist_array(v)
    if arr then
      if n == 0 then return '{}' end   -- leere Tabelle: wie jsonc als Objekt
      local teile = {}
      for i = 1, n do teile[i] = enc(v[i]) end
      return '[' .. table.concat(teile, ',') .. ']'
    end
    local schluessel = {}
    for k in pairs(v) do schluessel[#schluessel+1] = tostring(k) end
    table.sort(schluessel)
    local teile = {}
    for _, k in ipairs(schluessel) do
      teile[#teile+1] = '"' .. escape(k) .. '":' .. enc(v[k])
    end
    return '{' .. table.concat(teile, ',') .. '}'
  end
  error('jsonc-Ersatz: unbekannter Typ ' .. tv)
end

function M.stringify(v) return enc(v) end

-- Parser, knapp gehalten
local function skip(s, i)
  while i <= #s and s:sub(i,i):match('%s') do i = i + 1 end
  return i
end
local dec
local function dec_string(s, i)
  i = i + 1
  local out = {}
  while i <= #s do
    local c = s:sub(i,i)
    if c == '"' then return table.concat(out), i + 1 end
    if c == '\\' then
      local n = s:sub(i+1,i+1)
      local m = {['"']='"',['\\']='\\',['/']='/',b='\b',f='\f',n='\n',r='\r',t='\t'}
      if m[n] then out[#out+1] = m[n]; i = i + 2
      elseif n == 'u' then out[#out+1] = string.char(tonumber(s:sub(i+2,i+5),16) % 256); i = i + 6
      else error('jsonc-Ersatz: kaputte Escape-Sequenz') end
    else out[#out+1] = c; i = i + 1 end
  end
  error('jsonc-Ersatz: unbeendete Zeichenkette')
end
dec = function(s, i)
  i = skip(s, i)
  local c = s:sub(i,i)
  if c == '{' then
    local t = {}; i = skip(s, i+1)
    if s:sub(i,i) == '}' then return t, i+1 end
    while true do
      local k; k, i = dec_string(s, skip(s, i))
      i = skip(s, i); i = i + 1  -- ':'
      local v; v, i = dec(s, i); t[k] = v
      i = skip(s, i)
      if s:sub(i,i) == ',' then i = i + 1 else return t, i + 1 end
    end
  elseif c == '[' then
    local t = {}; i = skip(s, i+1)
    if s:sub(i,i) == ']' then return t, i+1 end
    while true do
      local v; v, i = dec(s, i); t[#t+1] = v
      i = skip(s, i)
      if s:sub(i,i) == ',' then i = i + 1 else return t, i + 1 end
    end
  elseif c == '"' then return dec_string(s, i)
  elseif s:sub(i,i+3) == 'true' then return true, i+4
  elseif s:sub(i,i+4) == 'false' then return false, i+5
  elseif s:sub(i,i+3) == 'null' then return nil, i+4
  else
    local z = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
    if not z then error('jsonc-Ersatz: unerwartetes Zeichen bei '..i) end
    return tonumber(z), i + #z
  end
end
function M.parse(s) local v = dec(s, 1); return v end
function M.load(pfad)
  local f = assert(io.open(pfad)); local s = f:read('*a'); f:close()
  return M.parse(s)
end
return M
