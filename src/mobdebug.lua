--
-- MobDebug -- Lua remote debugger
-- Copyright 2011-20 Paul Kulchenko
-- Based on RemDebug 1.0 Copyright Kepler Project 2005
--

-- use loaded modules or load explicitly on those systems that require that
local require = require
local function prequire(name)
  local ok, m = pcall(require, name)
  return ok and m or nil
end
local io = io or require "io"
local table = table or require "table"
local string = string or require "string"
local coroutine = coroutine or require "coroutine"
-- protect require "os" as it may fail on embedded systems without os module
local os = os or prequire "os"

-- patch to work with UServer 6.1.0 +
local debug = debug do
  local loader = prequire "module.loader"
  if loader then
    debug = assert(loader.debug())
  end
end

-- load third party library after `module.loader`
local socket = require "socket"

local mobdebug = {
  _NAME = "mobdebug",
  _VERSION = "0.801",
  _COPYRIGHT = "Paul Kulchenko",
  _DESCRIPTION = "Mobile Remote Debugger for the Lua programming language",
  port = os and os.getenv and tonumber((os.getenv("MOBDEBUG_PORT"))) or 8172,
  checkcount = 200,
  yieldtimeout = 0.02, -- yield timeout (s)
  connecttimeout = 2, -- connect timeout (s)
}

mobdebug.print = print

local HOOKMASK = "lcr"
local error = error
local getfenv = getfenv
local setfenv = setfenv
local loadstring = loadstring or load -- "load" replaced "loadstring" in Lua 5.2
local pairs = pairs
local setmetatable = setmetatable
local tonumber = tonumber
local unpack = table.unpack or unpack
local rawget = rawget
local string_format = string.format
local string_sub = string.sub
local string_find = string.find
local string_lower = string.lower
local string_gsub = string.gsub
local string_match = string.match

-- if strict.lua is used, then need to avoid referencing some global
-- variables, as they can be undefined;
-- use rawget to avoid complaints from strict.lua at run-time.
-- it's safe to do the initialization here as all these variables
-- should get defined values (if any) before the debugging starts.
-- there is also global 'wx' variable, which is checked as part of
-- the debug loop as 'wx' can be loaded at any time during debugging.
local genv = _G or _ENV
local jit = rawget(genv, "jit")
local MOAICoroutine = rawget(genv, "MOAICoroutine")

-- ngx_lua/Openresty requires special handling as its coroutine.*
-- methods use a different mechanism that doesn't allow resume calls
-- from debug hook handlers.
-- Instead, the "original" coroutine.* methods are used.
local ngx = rawget(genv, "ngx")
local corocreate = ngx and coroutine._create or coroutine.create
local cororesume = ngx and coroutine._resume or coroutine.resume
local coroyield = ngx and coroutine._yield or coroutine.yield
local corostatus = ngx and coroutine._status or coroutine.status
local corowrap = coroutine.wrap

if not setfenv then -- Lua 5.2+
  -- based on http://lua-users.org/lists/lua-l/2010-06/msg00314.html
  -- this assumes f is a function
  local function findenv(f)
    local level = 1
    repeat
      local name, value = debug.getupvalue(f, level)
      if name == '_ENV' then return level, value end
      level = level + 1
    until name == nil
    return nil end
  getfenv = function (f) return(select(2, findenv(f)) or _G) end
  setfenv = function (f, t)
    local level = findenv(f)
    if level then debug.setupvalue(f, level, t) end
    return f end
end

-- check for OS and convert file names to lower case on windows
-- (its file system is case insensitive, but case preserving), as setting a
-- breakpoint on x:\Foo.lua will not work if the file was loaded as X:\foo.lua.
-- OSX and Windows behave the same way (case insensitive, but case preserving).
-- OSX can be configured to be case-sensitive, so check for that. This doesn't
-- handle the case of different partitions having different case-sensitivity.
local win = os and os.getenv and (os.getenv('WINDIR') or (os.getenv('OS') or ''):match('[Ww]indows')) and true or false
local mac = not win and (os and os.getenv and os.getenv('DYLD_LIBRARY_PATH') or not io.open("/proc")) and true or false
local iscasepreserving = win or (mac and io.open('/library') ~= nil)

local coroutines = {}; setmetatable(coroutines, {__mode = "k"}) -- "weak" keys
local events = { BREAK = 1, WATCH = 2, RESTART = 3, STACK = 4 }
local PROTOCOLS = {MOBDEBUG = 1, VSCODE = 2}
local deferror = "execution aborted at default debugee"

-- turn jit off based on Mike Pall's comment in this discussion:
-- http://www.freelists.org/post/luajit/Debug-hooks-and-JIT,2
-- "You need to turn it off at the start if you plan to receive
-- reliable hook calls at any later point in time."
if jit and jit.off then jit.off() end

local state = {
  coro_debugger = nil,
  coro_debugee  = nil,
  breakpoints   = {},
  watchescnt    = 0,
  watches       = {},
  lastsource    = nil,
  lastfile      = nil,
  abort         = nil, -- default value is nil; this is used in start/loop distinction
  seen_hook     = false,
  step_into     = false,
  step_over     = false,
  step_level    = 0,
  stack_level   = 0,
  basedir       = "",
  protocol      = nil,
  debugee = function ()
    local a = 1
    for _ = 1, 10 do a = a + 1 end
    error(deferror)
  end,
  outputs = {},
}

local server
local coro_debugger
local coro_debugee
local abort -- default value is nil; this is used in start/loop distinction

local iobase = {print = print}
local function q(s) return string_gsub(s, '([%(%)%.%%%+%-%*%?%[%^%$%]])','%%%1') end

local serpent = (function() ---- include Serpent module for serialization
local n, v = "serpent", "0.302" -- (C) 2012-18 Paul Kulchenko; MIT License
local c, d = "Paul Kulchenko", "Lua serializer and pretty printer"
local snum = {[tostring(1/0)]='1/0 --[[math.huge]]',[tostring(-1/0)]='-1/0 --[[-math.huge]]',[tostring(0/0)]='0/0'}
local badtype = {thread = true, userdata = true, cdata = true}
local getmetatable = debug and debug.getmetatable or getmetatable
local pairs = function(t) return next, t end -- avoid using __pairs in Lua 5.2+
local keyword, globals, G = {}, {}, (_G or _ENV)
for _,k in ipairs({'and', 'break', 'do', 'else', 'elseif', 'end', 'false',
  'for', 'function', 'goto', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat',
  'return', 'then', 'true', 'until', 'while'}) do keyword[k] = true end
for k,v in pairs(G) do globals[v] = k end -- build func to name mapping
for _,g in ipairs({'coroutine', 'debug', 'io', 'math', 'string', 'table', 'os'}) do
  for k,v in pairs(type(G[g]) == 'table' and G[g] or {}) do globals[v] = g..'.'..k end end

local function s(t, opts)
  local name, indent, fatal, maxnum = opts.name, opts.indent, opts.fatal, opts.maxnum
  local sparse, custom, huge = opts.sparse, opts.custom, not opts.nohuge
  local space, maxl = (opts.compact and '' or ' '), (opts.maxlevel or math.huge)
  local maxlen, metatostring = tonumber(opts.maxlength), opts.metatostring
  local iname, comm = '_'..(name or ''), opts.comment and (tonumber(opts.comment) or math.huge)
  local numformat = opts.numformat or "%.17g"
  local seen, sref, syms, symn = {}, {'local '..iname..'={}'}, {}, 0
  local function gensym(val) return '_'..(tostring(tostring(val)):gsub("[^%w]",""):gsub("(%d%w+)",
    -- tostring(val) is needed because __tostring may return a non-string value
    function(s) if not syms[s] then symn = symn+1; syms[s] = symn end return tostring(syms[s]) end)) end
  local function safestr(s) return type(s) == "number" and tostring(huge and snum[tostring(s)] or numformat:format(s))
    or type(s) ~= "string" and tostring(s) -- escape NEWLINE/010 and EOF/026
    or ("%q"):format(s):gsub("\010","n"):gsub("\026","\\026") end
  local function comment(s,l) return comm and (l or 0) < comm and ' --[['..select(2, pcall(tostring, s))..']]' or '' end
  local function globerr(s,l) return globals[s] and globals[s]..comment(s,l) or not fatal
    and safestr(select(2, pcall(tostring, s))) or error("Can't serialize "..tostring(s)) end
  local function safename(path, name) -- generates foo.bar, foo[3], or foo['b a r']
    local n = name == nil and '' or name
    local plain = type(n) == "string" and n:match("^[%l%u_][%w_]*$") and not keyword[n]
    local safe = plain and n or '['..safestr(n)..']'
    return (path or '')..(plain and path and '.' or '')..safe, safe end
  local alphanumsort = type(opts.sortkeys) == 'function' and opts.sortkeys or function(k, o, n) -- k=keys, o=originaltable, n=padding
    local maxn, to = tonumber(n) or 12, {number = 'a', string = 'b'}
    local function padnum(d) return ("%0"..tostring(maxn).."d"):format(tonumber(d)) end
    table.sort(k, function(a,b)
      -- sort numeric keys first: k[key] is not nil for numerical keys
      return (k[a] ~= nil and 0 or to[type(a)] or 'z')..(tostring(a):gsub("%d+",padnum))
           < (k[b] ~= nil and 0 or to[type(b)] or 'z')..(tostring(b):gsub("%d+",padnum)) end) end
  local function val2str(t, name, indent, insref, path, plainindex, level)
    local ttype, level, mt = type(t), (level or 0), getmetatable(t)
    local spath, sname = safename(path, name)
    local tag = plainindex and
      ((type(name) == "number") and '' or name..space..'='..space) or
      (name ~= nil and sname..space..'='..space or '')
    if seen[t] then -- already seen this element
      sref[#sref+1] = spath..space..'='..space..seen[t]
      return tag..'nil'..comment('ref', level) end
    -- protect from those cases where __tostring may fail
    if type(mt) == 'table' and metatostring ~= false then
      local to, tr = pcall(function() return mt.__tostring(t) end)
      local so, sr = pcall(function() return mt.__serialize(t) end)
      if (to or so) then -- knows how to serialize itself
        seen[t] = insref or spath
        t = so and sr or tr
        ttype = type(t)
      end -- new value falls through to be serialized
    end
    if ttype == "table" then
      if level >= maxl then return tag..'{}'..comment('maxlvl', level) end
      seen[t] = insref or spath
      if next(t) == nil then return tag..'{}'..comment(t, level) end -- table empty
      if maxlen and maxlen < 0 then return tag..'{}'..comment('maxlen', level) end
      local maxn, o, out = math.min(#t, maxnum or #t), {}, {}
      for key = 1, maxn do o[key] = key end
      if not maxnum or #o < maxnum then
        local n = #o -- n = n + 1; o[n] is much faster than o[#o+1] on large tables
        for key in pairs(t) do if o[key] ~= key then n = n + 1; o[n] = key end end end
      if maxnum and #o > maxnum then o[maxnum+1] = nil end
      if opts.sortkeys and #o > maxn then alphanumsort(o, t, opts.sortkeys) end
      local sparse = sparse and #o > maxn -- disable sparsness if only numeric keys (shorter output)
      for n, key in ipairs(o) do
        local value, ktype, plainindex = t[key], type(key), n <= maxn and not sparse
        if opts.valignore and opts.valignore[value] -- skip ignored values; do nothing
        or opts.keyallow and not opts.keyallow[key]
        or opts.keyignore and opts.keyignore[key]
        or opts.valtypeignore and opts.valtypeignore[type(value)] -- skipping ignored value types
        or sparse and value == nil then -- skipping nils; do nothing
        elseif ktype == 'table' or ktype == 'function' or badtype[ktype] then
          if not seen[key] and not globals[key] then
            sref[#sref+1] = 'placeholder'
            local sname = safename(iname, gensym(key)) -- iname is table for local variables
            sref[#sref] = val2str(key,sname,indent,sname,iname,true) end
          sref[#sref+1] = 'placeholder'
          local path = seen[t]..'['..tostring(seen[key] or globals[key] or gensym(key))..']'
          sref[#sref] = path..space..'='..space..tostring(seen[value] or val2str(value,nil,indent,path))
        else
          out[#out+1] = val2str(value,key,indent,nil,seen[t],plainindex,level+1)
          if maxlen then
            maxlen = maxlen - #out[#out]
            if maxlen < 0 then break end
          end
        end
      end
      local prefix = string.rep(indent or '', level)
      local head = indent and '{\n'..prefix..indent or '{'
      local body = table.concat(out, ','..(indent and '\n'..prefix..indent or space))
      local tail = indent and "\n"..prefix..'}' or '}'
      return (custom and custom(tag,head,body,tail,level) or tag..head..body..tail)..comment(t, level)
    elseif badtype[ttype] then
      seen[t] = insref or spath
      return tag..globerr(t, level)
    elseif ttype == 'function' then
      seen[t] = insref or spath
      if opts.nocode then return tag.."function() --[[..skipped..]] end"..comment(t, level) end
      local ok, res = pcall(string.dump, t)
      local func = ok and "((loadstring or load)("..safestr(res)..",'@serialized'))"..comment(t, level)
      return tag..(func or globerr(t, level))
    else return tag..safestr(t) end -- handle all other types
  end
  local sepr = indent and "\n" or ";"..space
  local body = val2str(t, name, indent) -- this call also populates sref
  local tail = #sref>1 and table.concat(sref, sepr)..sepr or ''
  local warn = opts.comment and #sref>1 and space.."--[[incomplete output with shared/self-references skipped]]" or ''
  return not name and body..warn or "do local "..body..sepr..tail.."return "..name..sepr.."end"
end

local function deserialize(data, opts)
  local env = (opts and opts.safe == false) and G
    or setmetatable({}, {
        __index = function(t,k) return t end,
        __call = function(t,...) error("cannot call functions") end
      })
  local f, res = (loadstring or load)('return '..data, nil, nil, env)
  if not f then f, res = (loadstring or load)(data, nil, nil, env) end
  if not f then return f, res end
  if setfenv then setfenv(f, env) end
  return pcall(f)
end

local function merge(a, b) if b then for k,v in pairs(b) do a[k] = v end end; return a; end
return { _NAME = n, _COPYRIGHT = c, _DESCRIPTION = d, _VERSION = v, serialize = s,
  load = deserialize,
  dump = function(a, opts) return s(a, merge({name = '_', compact = true, sparse = true}, opts)) end,
  line = function(a, opts) return s(a, merge({sortkeys = true, comment = true}, opts)) end,
  block = function(a, opts) return s(a, merge({indent = '  ', sortkeys = true, comment = true}, opts)) end }
end)() ---- end of Serpent module

local log, tlog, flog do
  local logging = false
  local io_open = io.open
  local io_flush = io.flush or function() end
  
  local table_format_params = {comment = false, nocode = true}
  local function table_format(t)
    return serpent.block(t,table_format_params)
  end

  function log(...)
    mobdebug.print('[MOBDEBUG]' .. string_format(...))
    io_flush()
  end

  function flog(...)
    if not logging then return end
    local f = io_open([[d:\projects\vscode-mobdebug\lua\log.txt]], 'a+')
    if f then
      f:write('[MOBDEBUG]' .. string_format(...), '\n')
      f:close()
    end
  end

  function tlog(name, t)
    log("%s: %s", name, table_format(t))
  end
end

local Socket = {} do

function Socket.new(s)
  local self = {}
  for k, v in pairs(Socket) do
    self[k] = v
  end

  self.s   = s
  self.buf = nil

  return self
end

function Socket:buffer_append(data)
  if data and data ~= '' then
    if self.buf then
      self.buf = self.buf .. data
    else
      self.buf = data
    end
  end
end

function Socket:buffer_readn(n)
  if n == 0 then
    return ''
  end

  if not self.buf or #self.buf < n then
    return nil
  end

  local data = self.buf:sub(1, n)
  if #self.buf == n then
    self.buf = nil
  else
    self.buf = self.buf:sub(n + 1)
  end

  return data
end

function Socket:buffer_read_line()
  if not self.buf then
    return
  end

  local n = string_find(self.buf, '\n', nil, true)
  if not n then
    return
  end

  local line = self.buf:sub(1, n)
  self.buf = self.buf:sub(n + 2)
  if self.buf == '' then
    self.buf = nil
  end

  return line
end

function Socket:buffer_read_all()
  local data = self.buf
  self.buf = nil
  return data
end

function Socket:buffer_peek(n)
  if n == 0 then
    return ''
  end
  if not self.buf then
    return nil
  end
  if #self.buf < n then
    return nil
  end
  local res = self.buf:sub(1, n)
  return res
end

function Socket:buffer_size()
  return self.buf and #self.buf or 0
end

function Socket:settimeout(...)
  return self.s:settimeout(...)
end

function Socket:receive(...)
  return self.s:receive(...)
end

function Socket:peek(n, sync)
  local data = self:buffer_peek(n)
  if data then
    return data
  end

  local more = n - self:buffer_size()

  if sync == false then
    self:settimeout(0) -- non-blocking
  end
  local res, err, partial = self:receive(n) -- get the rest of the line
  if sync == false then
    self:settimeout() -- back to blocking
  end

  self:buffer_append(res or partial)

  return self:buffer_peek(n)
end

function Socket:receive_line(sync)
  local line = self:buffer_read_line()
  if line then
    return line
  end

  if sync == false then
    self:settimeout(0) -- non-blocking
  end
  local res, err, partial = self:receive("*l") -- get the rest of the line
  if sync == false then
    self:settimeout() -- back to blocking
  end

  self:buffer_append(res or partial)

  if not res then
    return nil, err
  end

  return self:buffer_read_all()
end

function Socket:receive_nread(n, sync)
  local data = self:buffer_readn(n)
  if data then
    return data
  end

  local more = n - self:buffer_size()
  if sync == false then
    self:settimeout(0) -- non-blocking
  end
  local res, err, partial = self:receive(n)
  if sync == false then
    self:settimeout() -- back to blocking
  end

  self:buffer_append(res or partial)

  data = self:buffer_readn(n)
  if not data then
    return nil, err
  end

  return data
end

function Socket:send(...)
  return self.s:send(...)
end

function Socket:nsend(str)
  local total_sent, attempt = 0, 5
  while total_sent < #str do
    local sent, err = self:send(str, total_sent + 1)
    if sent then
      if send == 0 then
        attempt = attempt - 1
        if attempt == 0 then
          return nil, err or 'no progress'
        end
      else
        total_sent = total_sent + sent
      end
    else
      return nil, err, total_sent
    end
  end
  return true
end

function Socket:is_pending()
  -- if there is something already in the buffer, skip check
  if self:buffer_size() == 0 and self.checkcount >= mobdebug.checkcount then
    self:settimeout(0) -- non-blocking
    local res, err, part = self:receive(1)
    self:settimeout() -- back to blocking
    self:buffer_append(res or part)
    self.checkcount = 0
  else
    self.checkcount = self.checkcount + 1
  end
  return self:buffer_size() > 0
end

function Socket:enforce_pending_check()
  self.checkcount = mobdebug.checkcount
end

function Socket:close()
  if self.s then
    self.s:close()
    self.buf = nil
    self.s = nil
  end
end

end

local debugger = {}

mobdebug.line = serpent.line
mobdebug.dump = serpent.dump
mobdebug.linemap = nil
mobdebug.loadstring = loadstring


-- path transformations
--  from source to internal - need to unify file paths getting from debuginfo
--  from IDE (debug client) to internal - need to match breakpoints
--  from internal to IDE (debug client) - need to be able to find file on the local storrage
-- E.g.
--  debug.getinfo - './script.lua'
--  IDE path      - '..\lua\script.lua'
--  internal path - 'script.lua'

-- internal format
--  dir separator - /
--  no basedir prefix

-- ZBS set base dir multiple times and can set it to releative path (`../`)


local function is_abs_path(file)
  return
    string_match(file, [[^\\]])
    or string_match(file, [[^/]])
    or string_match(file, [[^.:]])
end

local function removebasedir(path, basedir)
  if not iscasepreserving then
    return string_gsub(path, '^'..q(basedir), '')
  end

  -- check if the lowercased path matches the basedir
  -- if so, return substring of the original path (to not lowercase it)
  if string_find(string_lower(path), '^'..q(string_lower(basedir))) then
    return string_sub(path, #basedir + 1)
  end

  return path
end

local function normalize_path(file)
  local n
  repeat
    file, n = file:gsub("/+%.?/+","/") -- remove all `//` and `/./` references
  until n == 0

  -- collapse all up-dir references: this will clobber UNC prefix (\\?\)
  -- and disk on Windows when there are too many up-dir references: `D:\foo\..\..\bar`;
  -- handle the case of multiple up-dir references: `foo/bar/baz/../../../more`;
  -- only remove one at a time as otherwise `../../` could be removed;
  repeat
    file, n = file:gsub("[^/]+/%.%./", "", 1)
  until n == 0

  -- there may still be a leading up-dir reference left (as `/../` or `../`); remove it
  return (file:gsub("^(/?)%.%./", "%1"))
end

local function is_soucer_file_path(file)
  -- technically, users can supply names that may not use '@',
  -- for example when they call loadstring('...', 'filename.lua').
  -- Unfortunately, there is no reliable/quick way to figure out
  -- what is the filename and what is the source code.
  -- If the name doesn't start with `@`, assume it's a file name if it's all on one line.
  return string_find(file, "^@") or not string_find(file, "[\r\n]")
end

local function normalize_source_file(file)
  file = string_gsub(string_gsub(file, "^@", ""), "\\", "/")

  -- normalize paths that may include up-dir or same-dir references
  -- if the path starts from the up-dir or reference,
  -- prepend `basedir` to generate absolute path to keep breakpoints working.
  -- ignore qualified relative path (`D:../`) and UNC paths (`\\?\`)
  if string_find(file, "^%.%.?/") then file = state.basedir .. file end
  if string_find(file, "/%.%.?/") then file = normalize_path(file) end
  if string_find(file, "^%./")    then file = string_sub(file, 3) end

  -- need this conversion to be applied to relative and absolute
  -- file names as you may write "require 'Foo'" to
  -- load "foo.lua" (on a case insensitive file system) and breakpoints
  -- set on foo.lua will not work if not converted to the same case.
  if iscasepreserving then file = string_lower(file) end

  -- remove basedir, so that breakpoints are checked properly
  file = string_gsub(file, "^" .. q(state.basedir), "")

  -- some file systems allow newlines in file names; remove these.
  file = string_gsub(file, "\n", " ")

  return file
end

local function set_basedir(dir)
  if iscasepreserving then
    dir = string_lower(dir)
  end
  dir = string_gsub(dir, "\\", "/")        -- convert slashes
  dir = string_gsub(dir, "/+$", "") .. '/' -- ensure dir end
  state.basedir = dir
  -- reset cached source as it may change with basedir
  state.lastsource = nil

  log('Base dir: %s', state.basedir)
end

local function stack(start)
  local function vars(f)
    local func = debug.getinfo(f, "f").func
    local i = 1
    local locals = {}
    -- get locals
    while true do
      local name, value = debug.getlocal(f, i)
      if not name then break end
      if string_sub(name, 1, 1) ~= '(' then
        locals[name] = {value, select(2,pcall(tostring,value))}
      end
      i = i + 1
    end
    -- get varargs (these use negative indices)
    i = 1
    while true do
      local name, value = debug.getlocal(f, -i)
      if not name then break end
      locals[name:gsub("%)$"," "..i..")")] = {value, select(2,pcall(tostring,value))}
      i = i + 1
    end
    -- get upvalues
    i = 1
    local ups = {}
    while func do -- check for func as it may be nil for tail calls
      local name, value = debug.getupvalue(func, i)
      if not name then break end
      ups[name] = {value, select(2,pcall(tostring,value))}
      i = i + 1
    end
    return locals, ups
  end

  local stack = {}
  local linemap = mobdebug.linemap
  for i = (start or 0), 100 do
    local source = debug.getinfo(i, "Snl")
    if not source then break end

    local src = source.source
    if src:find("@") == 1 then
      src = src:sub(2):gsub("\\", "/")
      if src:find("%./") == 1 then src = src:sub(3) end
    end

    table.insert(stack, { -- remove basedir from source
      {source.name, removebasedir(src, state.basedir),
       linemap and linemap(source.linedefined, source.source) or source.linedefined,
       linemap and linemap(source.currentline, source.source) or source.currentline,
       source.what, source.namewhat, source.short_src},
      vars(i+1)})
  end
  return stack
end

local function set_breakpoint(file, line)
  if file == '-' and state.lastfile then file = state.lastfile
  elseif iscasepreserving then file = string_lower(file) end
  if not state.breakpoints[line] then state.breakpoints[line] = {} end
  state.breakpoints[line][file] = true
end

local function remove_breakpoint(file, line)
  if file == '-' and state.lastfile then file = state.lastfile
  elseif file == '*' and line == 0 then state.breakpoints = {}
  elseif iscasepreserving then file = string_lower(file) end
  if state.breakpoints[line] then state.breakpoints[line][file] = nil end
end

local function remove_file_breakpoint(file)
  if iscasepreserving then file = string_lower(file) end
  for line, file_breakpoints in pairs(state.breakpoints) do
    file_breakpoints[file] = nil
  end
end

local function has_breakpoint(file, line)
  return state.breakpoints[line]
     and state.breakpoints[line][iscasepreserving and string_lower(file) or file]
end

local function restore_vars(vars)
  if type(vars) ~= 'table' then return end

  -- locals need to be processed in the reverse order, starting from
  -- the inner block out, to make sure that the localized variables
  -- are correctly updated with only the closest variable with
  -- the same name being changed
  -- first loop find how many local variables there is, while
  -- the second loop processes them from i to 1
  local i = 1
  while true do
    local name = debug.getlocal(3, i)
    if not name then break end
    i = i + 1
  end
  i = i - 1
  local written_vars = {}
  while i > 0 do
    local name = debug.getlocal(3, i)
    if not written_vars[name] then
      if string_sub(name, 1, 1) ~= '(' then
        debug.setlocal(3, i, rawget(vars, name))
      end
      written_vars[name] = true
    end
    i = i - 1
  end

  i = 1
  local func = debug.getinfo(3, "f").func
  while true do
    local name = debug.getupvalue(func, i)
    if not name then break end
    if not written_vars[name] then
      if string_sub(name, 1, 1) ~= '(' then
        debug.setupvalue(func, i, rawget(vars, name))
      end
      written_vars[name] = true
    end
    i = i + 1
  end
end

local function capture_vars(level, thread)
  level = (level or 0)+2 -- add two levels for this and debug calls
  local func = (thread and debug.getinfo(thread, level, "f") or debug.getinfo(level, "f") or {}).func
  if not func then return {} end

  local vars = {['...'] = {}}
  local i = 1
  while true do
    local name, value = debug.getupvalue(func, i)
    if not name then break end
    if string_sub(name, 1, 1) ~= '(' then vars[name] = value end
    i = i + 1
  end
  i = 1
  while true do
    local name, value
    if thread then
      name, value = debug.getlocal(thread, level, i)
    else
      name, value = debug.getlocal(level, i)
    end
    if not name then break end
    if string_sub(name, 1, 1) ~= '(' then vars[name] = value end
    i = i + 1
  end
  -- get varargs (these use negative indices)
  i = 1
  while true do
    local name, value
    if thread then
      name, value = debug.getlocal(thread, level, -i)
    else
      name, value = debug.getlocal(level, -i)
    end
    if not name then break end
    vars['...'][i] = value
    i = i + 1
  end
  -- returned 'vars' table plays a dual role: (1) it captures local values
  -- and upvalues to be restored later (in case they are modified in "eval"),
  -- and (2) it provides an environment for evaluated chunks.
  -- getfenv(func) is needed to provide proper environment for functions,
  -- including access to globals, but this causes vars[name] to fail in
  -- restore_vars on local variables or upvalues with `nil` values when
  -- 'strict' is in effect. To avoid this `rawget` is used in restore_vars.
  setmetatable(vars, { __index = getfenv(func), __newindex = getfenv(func), __mode = "v" })
  return vars
end

local function stack_depth(start_depth)
  for i = start_depth, 0, -1 do
    if debug.getinfo(i, "l") then return i+1 end
  end
  return start_depth
end

local function is_safe(stack_level)
  -- the stack grows up: 0 is getinfo, 1 is is_safe, 2 is debug_hook, 3 is user function
  if stack_level == 3 then return true end
  for i = 3, stack_level do
    -- return if it is not safe to abort
    local info = debug.getinfo(i, "S")
    if not info then return true end
    if info.what == "C" then return false end
  end
  return true
end

local function in_debugger()
  local this = debug.getinfo(1, "S").source
  -- only need to check few frames as mobdebug frames should be close
  for i = 3, 9 do
    local info = debug.getinfo(i, "S")
    if not info then return false end
    if info.source == this then return true end
  end
  return false
end

local function debug_hook(event, line)
  -- (1) LuaJIT needs special treatment. Because debug_hook is set for
  -- *all* coroutines, and not just the one being debugged as in regular Lua
  -- (http://lua-users.org/lists/lua-l/2011-06/msg00513.html),
  -- need to avoid debugging mobdebug's own code as LuaJIT doesn't
  -- always correctly generate call/return hook events (there are more
  -- calls than returns, which breaks stack depth calculation and
  -- 'step' and 'step over' commands stop working; possibly because
  -- 'tail return' events are not generated by LuaJIT).
  -- the next line checks if the debugger is run under LuaJIT and if
  -- one of debugger methods is present in the stack, it simply returns.
  -- ngx_lua/Openresty requires a slightly different handling, as it
  -- creates a coroutine wrapper, so this processing needs to be skipped.
  if jit and not (ngx and type(ngx) == "table" and ngx.say) then
    -- when luajit is compiled with LUAJIT_ENABLE_LUA52COMPAT,
    -- coroutine.running() returns non-nil for the main thread.
    local coro, main = coroutine.running()
    if not coro or main then coro = 'main' end
    local disabled = coroutines[coro] == false
      or coroutines[coro] == nil and coro ~= (coro_debugee or 'main')
    if coro_debugee and disabled or not coro_debugee and (disabled or in_debugger()) then
      return
    end
  end

  -- (2) check if abort has been requested and it's safe to abort
  if abort and is_safe(state.stack_level) then error(abort) end

  -- (3) also check if this debug hook has not been visited for any reason.
  -- this check is needed to avoid stepping in too early
  -- (for example, when coroutine.resume() is executed inside start()).
  if not state.seen_hook and in_debugger() then return end

  if event == "call" then
    state.stack_level = state.stack_level + 1
  elseif event == "return" or event == "tail return" then
    state.stack_level = state.stack_level - 1
  elseif event == "line" then
    if mobdebug.linemap then
      local ok, mappedline = pcall(mobdebug.linemap, line, debug.getinfo(2, "S").source)
      if ok then line = mappedline end
      if not line then return end
    end

    -- may need to fall through because of the following:
    -- (1) step_into
    -- (2) step_over and stack_level <= step_level (need stack_level)
    -- (3) breakpoint; check for line first as it's known; then for file
    -- (4) socket call (only do every Xth check)
    -- (5) at least one watch is registered
    if not (
      state.step_into or state.step_over or state.breakpoints[line] or state.watchescnt > 0
      or server:is_pending()
    ) then return end

    server:enforce_pending_check() -- force check on the next command

    -- this is needed to check if the stack got shorter or longer.
    -- unfortunately counting call/return calls is not reliable.
    -- the discrepancy may happen when "pcall(load, '')" call is made
    -- or when "error()" is called in a function.
    -- in either case there are more "call" than "return" events reported.
    -- this validation is done for every "line" event, but should be "cheap"
    -- as it checks for the stack to get shorter (or longer by one call).
    -- start from one level higher just in case we need to grow the stack.
    -- this may happen after coroutine.resume call to a function that doesn't
    -- have any other instructions to execute. it triggers three returns:
    -- "return, tail return, return", which needs to be accounted for.
    state.stack_level = stack_depth(state.stack_level + 1)

    local caller = debug.getinfo(2, "S")

    -- grab the filename and fix it if needed
    local file = state.lastfile
    if (state.lastsource ~= caller.source) then
      file, state.lastsource = caller.source, caller.source
      if is_soucer_file_path(file) then
        file = normalize_source_file(file)
      else
        file = mobdebug.line(file)
      end

      log('NORM: %s -> %s', state.lastsource, file)

      -- set to true if we got here; this only needs to be done once per
      -- session, so do it here to at least avoid setting it for every line.
      state.seen_hook = true
      state.lastfile = file
    end

    local possible_pending_io = debugger.loop_pending_io()

    local vars, status, res
    if (state.watchescnt > 0) then
      vars = capture_vars(1)
      for index, value in pairs(state.watches) do
        setfenv(value, vars)
        local ok, fired = pcall(value)
        if ok and fired then
          status, res = cororesume(coro_debugger, events.WATCH, vars, file, line, index)
          break -- any one watch is enough; don't check multiple times
        end
      end
    end

    -- need to get into the "regular" debug handler, but only if there was
    -- no watch that was fired. If there was a watch, handle its result.
    local getin = (status == nil) and (
        state.step_into
      -- when coroutine.running() return `nil` (main thread in Lua 5.1),
      -- step_over will equal 'main', so need to check for that explicitly.
      or (state.step_over and state.step_over == (coroutine.running() or 'main') and state.stack_level <= state.step_level)
      or has_breakpoint(file, line)
      or (possible_pending_io == true)
    )

    if getin then
      log('debug hook interrupted')
      vars = vars or capture_vars(1)
      state.step_into = false
      state.step_over = false
      status, res = cororesume(coro_debugger, events.BREAK, vars, file, line)
    end

    -- handle 'stack' command that provides stack() information to the debugger
    while status and res == 'stack' do
      -- resume with the stack trace and variables
      if vars then restore_vars(vars) end -- restore vars so they are reflected in stack values
      status, res = cororesume(coro_debugger, events.STACK, stack(3), file, line)
    end

    -- need to recheck once more as resume after 'stack' command may
    -- return something else (for example, 'exit'), which needs to be handled
    if status and res and res ~= 'stack' then
      if not abort and res == "exit" then mobdebug.onexit(1, true); return end
      if not abort and res == "done" then mobdebug.done(); return end
      abort = res
      -- only abort if safe; if not, there is another (earlier) check inside
      -- debug_hook, which will abort execution at the first safe opportunity
      if is_safe(state.stack_level) then error(abort) end
    elseif not status and res then
      error(res, 2) -- report any other (internal) errors back to the application
    end

    if vars then restore_vars(vars) end

    -- last command requested Step Over/Out; store the current thread
    if state.step_over == true then state.step_over = coroutine.running() or 'main' end
  end
end

local function isrunning()
  return coro_debugger and (corostatus(coro_debugger) == 'suspended' or corostatus(coro_debugger) == 'running')
end

-- this is a function that removes all hooks and closes the socket to
-- report back to the controller that the debugging is done.
-- the script that called `done` can still continue.
local function done()
  if not (isrunning() and server) then return end

  if not jit then
    for co, debugged in pairs(coroutines) do
      if debugged then debug.sethook(co) end
    end
  end

  debug.sethook()
  server:close()

  coro_debugger = nil -- to make sure isrunning() returns `false`
  state.seen_hook = nil -- to make sure that the next start() call works
  abort = nil -- to make sure that callback calls use proper "abort" value
  state.basedir = "" -- to reset basedir in case the same module/state is reused
end

local mobdebug_debugger = {} do

local function stringify_results(params, status, ...)
  if not status then return status, ... end -- on error report as it

  params = params or {}
  if params.nocode == nil then params.nocode = true end
  if params.comment == nil then params.comment = 1 end

  local t = {...}
  for i,v in pairs(t) do -- stringify each of the returned values
    local ok, res = pcall(mobdebug.line, v, params)
    t[i] = ok and res or ("%q"):format(res):gsub("\010","n"):gsub("\026","\\026")
  end
  -- stringify table with all returned values
  -- this is done to allow each returned value to be used (serialized or not)
  -- intependently and to preserve "original" comments
  return pcall(mobdebug.dump, t, {sparse = false})
end

function mobdebug_debugger.path_to_ide(file)
  return file
end

function mobdebug_debugger.path_from_ide(file)
  return file
end

function mobdebug_debugger.send_response(status, message, data)
  if data then
    local msg = string_format("%d %s %d\n", status, message, #data)
    local ok, err = server:nsend(msg)
    if not ok then
      return nil, err
    end
    return server:nsend(data)
  end

  local msg = string_format("%d %s\n", status, message)
  return server:nsend(msg)
end

function mobdebug_debugger.send_ok_response(data)
  return mobdebug_debugger.send_response(200, 'OK', data)
end

function mobdebug_debugger.send_bad_request_response(data)
  return mobdebug_debugger.send_response(400, 'Bad Request', data)
end

function mobdebug_debugger.send_expression_error_response(data)
  return mobdebug_debugger.send_response(401, 'Error in Expression', data)
end

function mobdebug_debugger.send_execution_error_response(data)
  return mobdebug_debugger.send_response(401, 'Error in Execution', data)
end

function mobdebug_debugger.send_params_response(code, ...)
  return mobdebug_debugger.send_response(code, string_format(...))
end

-- extract any optional parameters
function mobdebug_debugger.load_params(line)
  local params = string.match(line, "--%s*(%b{})%s*$")
  local pfunc = params and loadstring("return " .. params) -- use internal function
  params = pfunc and pfunc()
  params = (type(params) == "table" and params or {})
  return params
end

function mobdebug_debugger.parse_breackpoint_command(line)
  local _, _, cmd, file, line_no = string_find(line, "^([A-Z]+)%s+(.-)%s+(%d+)%s*$")
  local local_file = mobdebug_debugger.path_from_ide(file)
  log('breakpoint path: %s -> %s', file, local_file)
  return local_file, tonumber(line_no), cmd
end

function mobdebug_debugger.parse_exec_command(line)
  local _, _, chunk = string_find(line, "^[A-Z]+%s+(.+)$")
  if not chunk then
    return
  end

  local params = mobdebug_debugger.load_params(line)

  return chunk, params
end

function mobdebug_debugger.parse_load_command(line)
  local _, _, size, name = string_find(line, "^[A-Z]+%s+(%d+)%s+(%S.-)%s*$")
  size = tonumber(size)
  local chunk = server:receive_nread(size)
  return size, name, chunk
end

function mobdebug_debugger.parse_set_watch_command(line)
  local _, _, exp = string_find(line, "^[A-Z]+%s+(.+)%s*$")
  return exp
end

function mobdebug_debugger.parse_del_watch_command(line)
  local _, _, index = string_find(line, "^[A-Z]+%s+(%d+)%s*$")
  return tonumber(index)
end

function mobdebug_debugger.parse_set_basedir_command(line)
  local _, _, dir = string_find(line, "^[A-Z]+%s+(.+)%s*$")
  return dir
end

function mobdebug_debugger.parse_stack_command(line)
  return mobdebug_debugger.load_params(line)
end

function mobdebug_debugger.parse_output_command(line)
  local _, _, stream, mode = string_find(line, "^[A-Z]+%s+(%w+)%s+([dcr])%s*$")
  return stream, mode
end

function mobdebug_debugger.loop(sev, svars, sfile, sline)
  local command, arguments
  local eval_env = svars or {}
  local function emptyWatch () return false end
  local loaded = {}
  for k in pairs(package.loaded) do loaded[k] = true end

  while true do
    local line, err
    if mobdebug.yield and server.settimeout then server:settimeout(mobdebug.yieldtimeout) end
    while true do
      line, err = server:receive_line()
      if line then
        break
      end
      if err == "timeout" then
        if mobdebug.yield then mobdebug.yield() end
      elseif err == "closed" then
        error("Debugger connection closed", 0)
      else
        error(("Unexpected socket error: %s"):format(err), 0)
      end
    end
    if server.settimeout then server:settimeout() end -- back to blocking

    command = string_sub(line, string_find(line, "^[A-Z]+"))
    if command == "SETB" then
      local file, line = mobdebug_debugger.parse_breackpoint_command(line)
      if file and line then
        set_breakpoint(file, line)
        mobdebug_debugger.send_ok_response()
      else
        mobdebug_debugger.send_bad_request_response()
      end
    elseif command == "DELB" then
      local file, line = mobdebug_debugger.parse_breackpoint_command(line)
      if file and line then
        remove_breakpoint(file, tonumber(line))
        mobdebug_debugger.send_ok_response()
      else
        mobdebug_debugger.send_bad_request_response()
      end
    elseif command == "EXEC" then
      -- extract any optional parameters
      local chunk, params = mobdebug_debugger.parse_exec_command(line)
      if chunk then
        local func, res = mobdebug.loadstring(chunk)
        local status
        if func then
          local stack = tonumber(params.stack)
          -- if the requested stack frame is not the current one, then use a new capture
          -- with a specific stack frame: `capture_vars(0, coro_debugee)`
          local env = stack and coro_debugee and capture_vars(stack-1, coro_debugee) or eval_env
          setfenv(func, env)
          status, res = stringify_results(params, pcall(func, unpack(rawget(env,'...') or {})))
          if status and mobdebug.onscratch then mobdebug.onscratch(res) end
        end

        if status then
          mobdebug_debugger.send_ok_response(res)
        else
          -- fix error if not set (for example, when loadstring is not present)
          if not res then res = "Unknown error" end
          mobdebug_debugger.send_expression_error_response(res)
        end
      else
        mobdebug_debugger.send_bad_request_response()
      end
    elseif command == "LOAD" then
      local size, name, chunk = mobdebug_debugger.parse_load_command(line)
      if not size then
        mobdebug_debugger.send_bad_request_response()
      else
        if abort == nil then -- no LOAD/RELOAD allowed inside start()
          if sfile and sline then
            mobdebug_debugger.send_params_response(201, "Started %s %d", sfile, sline)
          else
            mobdebug_debugger.send_ok_response('')
          end
        else
          -- reset environment to allow required modules to load again
          -- remove those packages that weren't loaded when debugger started
          for k in pairs(package.loaded) do
            if not loaded[k] then package.loaded[k] = nil end
          end
          if size == 0 and name == '-' then -- RELOAD the current script being debugged
            mobdebug_debugger.send_ok_response('')
            coroyield("load")
          elseif chunk then -- LOAD a new script for debugging
            local func, res = mobdebug.loadstring(chunk, "@"..name)
            if func then
              mobdebug_debugger.send_ok_response('')
              state.debugee = func
              coroyield("load")
            else
              mobdebug_debugger.send_expression_error_response(res)
            end
          else
            mobdebug_debugger.send_bad_request_response()
          end
        end
      end
    elseif command == "SETW" then
      local exp = mobdebug_debugger.parse_set_watch_command(line)
      if exp then
        local func, res = mobdebug.loadstring("return(" .. exp .. ")")
        if func then
          state.watchescnt = state.watchescnt + 1
          local newidx = #state.watches + 1
          state.watches[newidx] = func
          mobdebug_debugger.send_params_response(200, 'OK %d', newidx )
        else
          mobdebug_debugger.send_expression_error_response(res)
        end
      else
        mobdebug_debugger.send_bad_request_response()
      end
    elseif command == "DELW" then
      local index = mobdebug_debugger.parse_del_watch_command(line)
      if index and (index > 0 and index <= #state.watches) then
        state.watchescnt = state.watchescnt - (state.watches[index] ~= emptyWatch and 1 or 0)
        state.watches[index] = emptyWatch
        mobdebug_debugger.send_ok_response()
      else
        mobdebug_debugger.send_bad_request_response()
      end
    elseif command == "RUN" or command == "STEP" or command == "OVER" or command == "OUT" then
      mobdebug_debugger.send_ok_response()

      if command == "RUN" then
        state.step_into = false
        state.step_over = false
      elseif command == "STEP" then
        state.step_into = true
        state.step_over = false
      elseif command == "OVER" or command == "OUT" then
        state.step_into = false
        state.step_over = true
        state.step_level = (command == "OVER") and state.stack_level or state.stack_level - 1
      end

      local ev, vars, file, line, idx_watch = coroyield()
      if ev == events.BREAK or ev == events.WATCH then
        file = file and mobdebug_debugger.path_to_ide(file)
      end
      eval_env = vars
      if ev == events.BREAK then
        mobdebug_debugger.send_params_response(202, 'Paused %s %d', file, line)
      elseif ev == events.WATCH then
        mobdebug_debugger.send_params_response(203, 'Paused %s %d %d', file, line, idx_watch)
      elseif ev == events.RESTART then
        -- nothing to do
      else
        mobdebug_debugger.send_execution_error_response(file)
      end
    elseif command == "BASEDIR" then
      local dir = mobdebug_debugger.parse_set_basedir_command(line)
      if dir then
        set_basedir(dir)
        mobdebug_debugger.send_ok_response()
      else
        mobdebug_debugger.send_bad_request_response()
      end
    elseif command == "SUSPEND" then
      -- do nothing; it already fulfilled its role
    elseif command == "DONE" then
      coroyield("done")
      return -- done with all the debugging
    elseif command == "STACK" then
      -- first check if we can execute the stack command
      -- as it requires yielding back to debug_hook it cannot be executed
      -- if we have not seen the hook yet as happens after start().
      -- in this case we simply return an empty result
      local ev, vars
      if state.seen_hook then
        ev, vars = coroyield("stack")
      else
        ev, vars = events.STACK, {}
      end
      if ev ~= events.STACK then
        mobdebug_debugger.send_execution_error_response(vars)
      else
        local params = mobdebug_debugger.parse_stack_command(line)
        if params.nocode == nil then params.nocode = true end
        if params.sparse == nil then params.sparse = false end
        -- take into account additional levels for the stack frames and data management
        if tonumber(params.maxlevel) then params.maxlevel = tonumber(params.maxlevel)+4 end

        local ok, res = pcall(mobdebug.dump, vars, params)
        if ok then
          mobdebug_debugger.send_params_response(200, 'OK %s', tostring(res))
        else
          mobdebug_debugger.send_execution_error_response(res)
        end
      end
    elseif command == "OUTPUT" then
      local stream, mode = mobdebug_debugger.parse_output_command(line)
      if stream and mode and stream == "stdout" then
        -- assign "print" in the global environment
        local default = mode == 'd'
        genv.print = default and iobase.print or corowrap(function()
          -- wrapping into coroutine.wrap protects this function from
          -- being stepped through in the debugger.
          -- don't use vararg (...) as it adds a reference for its values,
          -- which may affect how they are garbage collected
          while true do
            local tbl = {coroutine.yield()}
            if mode == 'c' then iobase.print(unpack(tbl)) end
            for n = 1, #tbl do
              tbl[n] = select(2, pcall(mobdebug.line, tbl[n], {nocode = true, comment = false})) end
            local file = table.concat(tbl, "\t").."\n"
            mobdebug_debugger.send_response(204, "Output " .. stream, file)
          end
        end)
        if not default then genv.print() end -- "fake" print to start printing loop
        mobdebug_debugger.send_ok_response()
      else
        mobdebug_debugger.send_bad_request_response()
      end
    elseif command == "EXIT" then
      mobdebug_debugger.send_ok_response()
      coroyield("exit")
    else
      mobdebug_debugger.send_bad_request_response()
    end
  end
end

-- Handling command from inside debug hook during run state
function mobdebug_debugger.pending_io()
  local possible_pending_io = false
  while server:is_pending() do
    -- check if the buffer has the beginning of SETB/DELB command;
    -- this is to avoid reading the entire line for commands that
    -- don't need to be handled here.
    local ch = server:peek(1, false)
    if ch ~= 'S' and ch ~= 'D' then break end

    -- check second character to avoid reading STEP or other S* and D* commands
    local err
    ch, err = server:peek(2, false)
    if ch ~= 'SE' and ch ~= 'DE' then
      possible_pending_io = (err == 'timeout')
      break
    end

    -- need to read few more characters
    ch, err = server:peek(5, false)
    if ch ~= 'SETB ' and ch ~= 'DELB ' then
      possible_pending_io = (err == 'timeout')
      break
    end

    local line
    line, err = server:receive_line(true) -- get the rest of the line; blocking
    if not line then
      possible_pending_io = (err == 'timeout')
      break
    end

    local file, line_no, cmd = mobdebug_debugger.parse_breackpoint_command(line)
    if cmd == 'SETB' then set_breakpoint(file, line_no)
    elseif cmd == 'DELB' then remove_breakpoint(file, line_no)
    else
      log("unexpected command: %s", line)
      -- this looks like a breakpoint command, but something went wrong;
      -- return here to let the "normal" processing to handle,
      -- although this is likely to not go well.
      break
    end
  end

  if possible_pending_io then
    return false
  end

  return not not server:is_pending()
end

end

local vscode_debugger = {} do

local json = prequire'dkjson'

local vscode_message_size = nil
local vscode_thread_id    = 0
local vscode_thread_name  = 'main'
local vscode_init_failure = false
local vscode_scope_offset = 1000000
local vscode_scope_types  = {Locals = 1, Upvalues = 2}
local vscode_variables_ref
local vscode_variables_map
local vscode_fetched_message
local vscode_dir_sep
local vscode_stop_on_entry = false

local function pcall_vararg_pack(status, ...)
  if not status then return status, ... end -- on error report as it
  return status, {n = select('#', ...), ...}
end

function vscode_debugger.path_to_ide(file)
  if not is_abs_path(file) then
    file = state.basedir .. file
  end

  file = string_gsub(file, '/', vscode_dir_sep)

  return file
end

function vscode_debugger.path_from_ide(file)
  file = normalize_source_file(file)
  return file
end

function vscode_debugger.proto_error(message)
  error('[MOBDEBUG][PROTOCOL ERROR] ' .. message, 2)
end

function vscode_debugger.receive_message(sync)
  if vscode_fetched_message then
    local res = vscode_fetched_message
    vscode_fetched_message = nil
    return res
  end

  if (sync == false) and (not server:is_pending()) then
    return
  end

  if not vscode_message_size then
    local header, err = server:receive_line(sync)
    if not header then
      return nil, err
    end

    if (string_sub(header, 1, 1) ~= '#') then
      return vscode_debugger.proto_error('Invalid header:' .. header)
    end

    vscode_message_size = tonumber(string_sub(header, 2))
    if (not vscode_message_size) or (vscode_message_size < 0) then
      return vscode_debugger.proto_error('Invalid header:' .. header)
    end
  end

  local message, err = server:receive_nread(vscode_message_size, sync)
  if not message then
    return nil, err
  end

  vscode_message_size = nil

  local decoded_message = json.decode(message)
  if not decoded_message then
    return vscode_debugger.proto_error('Invalid message:' .. message)
  end

  return decoded_message
end

function vscode_debugger.push_back_message(msg)
  vscode_fetched_message = msg
end

function vscode_debugger.send_message(msg)
  local data = json.encode(msg)
  local ok, err = server:nsend(string_format('#%d\n%s', #data, data))
  if not ok then
    error('[MOBDEUG][SEND ERROR]: ' .. err)
  end
end

function vscode_debugger.send_success(req, body)
  vscode_debugger.send_message{
    type        = "response",
    request_seq = req.seq,
    command     = req.command,
    success     = true,
    body        = body
  }
end

function vscode_debugger.send_failure(req, msg)
  vscode_debugger.send_message{
    type        = "response",
    request_seq = req.seq,
    command     = req.command,
    success     = false,
    message     = msg
  }
end

function vscode_debugger.send_event(eventName, body)
  vscode_debugger.send_message{
    type  = "event",
    event = eventName,
    body  = body
  }
end

function vscode_debugger.send_console(str)
  vscode_debugger.send_event('output', {category = 'console', output = str})
end

function vscode_debugger.send_stdout(str)
  vscode_debugger.send_event('output', {category = 'stdout', output = str})
end

function vscode_debugger.send_stderr(str)
  vscode_debugger.send_event('output', {category = 'stderr', output = str})
end

function vscode_debugger.send_stop_event(reason)
  vscode_debugger.send_event('stopped', {
    reason            = reason,
    threadId          = vscode_thread_id,
    allThreadsStopped = true
  })
end

function vscode_debugger.loop(sev, svars, sfile, sline)
  local command, arguments
  local eval_env = svars or {}
  local loaded = {}
  for k in pairs(package.loaded) do loaded[k] = true end

  while true do
    local req, err
    if mobdebug.yield and server.settimeout then server:settimeout(mobdebug.yieldtimeout) end
    while true do
      req, err = vscode_debugger.receive_message()
      if req then
        break
      end
      if err == "timeout" then
        if mobdebug.yield then mobdebug.yield() end
      elseif err == "closed" then
        error("Debugger connection closed", 0)
      else
        error(("Unexpected socket error: %s"):format(err), 0)
      end
    end
    if server.settimeout then server:settimeout() end -- back to blocking

    command, args = req.command, req.arguments or {}
    log('New command: %s', tostring(command))

    if command == 'welcome' then
      set_basedir(args.sourceBasePath)
      vscode_dir_sep = args.directorySeperator
      vscode_stop_on_entry = args.stopOnEntry
      vscode_init_failure = false
      -- No response
    elseif command == 'configurationDone' then
      if vscode_init_failure then
        vscode_debugger.send_failure(req, 'Initialization failure')
      else
        vscode_debugger.send_success(req, {})
        if vscode_stop_on_entry then
          vscode_debugger.send_stop_event('entry')
        else -- continue command
          state.step_into = false
          state.step_over = false

          local ev, vars, file, line, idx_watch = coroyield()
          eval_env = vars
          if ev == events.BREAK then
            vscode_debugger.send_stop_event('breakpoint')
          elseif ev == events.WATCH then -- TODO: conditional breakpoint
            vscode_debugger.send_stop_event('breakpoint')
          elseif ev == events.RESTART then
            -- nothing to do
          else
            vscode_debugger.send_stop_event('exception')
            vscode_debugger.send_stderr(file)
          end
        end
      end
    elseif command == 'threads' then
      local result = {
        {
          id   = vscode_thread_id,
          name = vscode_thread_name,
        }
      }
      vscode_debugger.send_success(req, {threads = result})
    elseif command == 'setBreakpoints' then
      local file = vscode_debugger.path_from_ide(args.source.path)
      remove_file_breakpoint(file)
      local result = {}
      for i, breakpoint in ipairs(args.breakpoints) do
        set_breakpoint(file, breakpoint.line)
        result[i] = {
          verified = true,
          line     = breakpoint.line,
        }
      end
      vscode_debugger.send_success(req, {breakpoints = result})
    elseif command == 'stackTrace' then
      vscode_variables_ref = {}
      if not state.seen_hook then
        vscode_debugger.send_success(req, {stackFrames = {}})
      else
        local ev, frames = coroyield("stack")
        if ev ~= events.STACK then
          vscode_debugger.send_failure(req, tostring(frames))
        else
          local result = {}
          local start_frame = args.startFrame or 0
          local levels = args.levels or 20

          for i = 0, levels - 1 do
            local level = start_frame + i
            local stack = frames[level + 1]

            if not stack then
              break
            end

            local frame            = stack[1]
            local source_name      = frame[1]
            local file_path        = frame[2]
            local linedefined      = frame[3]
            local currentline      = frame[4]
            local source_what      = frame[5]
            local source_namewhat  = frame[6]
            local source_short_src = frame[7]

            if not frames[level + 2] and source_what == 'C' then
              break -- skip top C level
            end

            result[#result + 1] = {
              id     = level,
              name   = source_name or '?',
              source = {
                path = vscode_debugger.path_to_ide(file_path)
              },
              line = currentline,
              column = 1,
            }
          end
          vscode_debugger.send_success(req, {stackFrames = result})
        end
      end
    elseif command == 'scopes' then
      local frameId = args.frameId or 0
      local scopes = {}
      scopes[#scopes + 1] = {
        name      = 'Locals',
        expensive = false,
        variablesReference = (frameId + 1) * vscode_scope_offset + vscode_scope_types.Locals
      }
      scopes[#scopes + 1] = {
        name      = 'Upvalues',
        expensive = false,
        variablesReference = (frameId + 1) * vscode_scope_offset + vscode_scope_types.Upvalues
      }
      local result = {
        scopes = scopes,
        line   = nil, -- TODO: defenition line
      }
      vscode_debugger.send_success(req, result)
    elseif command == 'variables' then
      if not state.seen_hook then
        vscode_debugger.send_success(req, {variables = {}})
      else
        local ref, result, vars = args.variablesReference, {}
        local is_scope = ref > vscode_scope_offset
        if is_scope then
          local ev, frames = coroyield("stack")
          if ev ~= events.STACK then
            vscode_debugger.send_failure(req, tostring(frames))
          else
            local frameId   = math.floor(ref / vscode_scope_offset) - 1
            local scopeType = ref % vscode_scope_offset + 1
            local frame = frames[frameId + 1]
            vars = frame[scopeType]
          end
        else
          vars = vscode_variables_ref[ref]
        end
        if vars then
          for name, var in pairs(vars) do
            if type(name) == 'number' then
              name = '[' .. tostring(name) .. ']'
            else
              name = tostring(name)
            end

            local value, string_value
            if is_scope then
              value, string_value = var[1], var[2]
            else
              value, string_value = var, tostring(var)
            end

            local vt = type(value)
            if vt == 'table' then
              ref = #vscode_variables_ref + 1
              vscode_variables_ref[ref] = value
            else
              ref = -1
            end

            result[#result + 1] = {
              name               = name,
              type               = vt,
              variablesReference = ref,
              value              = string_value,
            }
          end
          vscode_debugger.send_success(req, {variables = result})
        end -- if vars
      end -- if not seen_hook
    elseif command == 'evaluate' then
      if not state.seen_hook then
        vscode_debugger.send_failure(req, "Invalid state")
      else
        tlog('evaluate', req)
        local chunk = req.arguments.expression
        local func, res = mobdebug.loadstring(string_format('return (%s)', chunk))
        local status
        if func then
          local stack = args.frameId
          if stack == 0 then stack = nil end
          -- if the requested stack frame is not the current one, then use a new capture
          -- with a specific stack frame: `capture_vars(0, coro_debugee)`
          local env = stack and coro_debugee and capture_vars(stack - 1, coro_debugee) or eval_env
          setfenv(func, env)
          status, res = pcall_vararg_pack(pcall(func, unpack(rawget(env, '...') or {})))
        end
        if status then
          tlog('res', res)
          -- TODO multiple values
          if res.n == 0 then
            vscode_debugger.send_success(req, {})
          else
            local value = res[1]
            local vt, ref = type(value), -1
            if vt == 'table' then
              ref = #vscode_variables_ref + 1
              vscode_variables_ref[ref] = value
            end
            vscode_debugger.send_success(req, {
              result             = tostring(value),
              type               = vt,
              variablesReference = ref,
            })
          end
        else
          -- fix error if not set (for example, when loadstring is not present)
          if not res then res = "Unknown error" end
          vscode_debugger.send_failure(req, res)
        end
      end
    elseif command == 'continue' or command == 'next' or command == 'stepIn' or command == 'stepOut' then
      vscode_debugger.send_success(req, {})
      if command == "continue" then
        state.step_into = false
        state.step_over = false
      elseif command == "stepIn" then
        state.step_into = true
        state.step_over = false
      elseif command == "next" or command == "stepOut" then
        state.step_into = false
        state.step_over = true
        state.step_level = (command == "next") and state.stack_level or state.stack_level - 1
      end

      local ev, vars, file, line, idx_watch = coroyield()
      eval_env = vars
      if ev == events.BREAK then
        vscode_debugger.send_stop_event('breakpoint')
      elseif ev == events.WATCH then -- TODO: conditional breakpoint
        vscode_debugger.send_stop_event('breakpoint')
      elseif ev == events.RESTART then
        -- nothing to do
      else
        vscode_debugger.send_stop_event('exception')
        vscode_debugger.send_stderr(file)
      end
    elseif command == 'disconnect' then
      vscode_debugger.send_success(req, {})
      coroyield("done")
      return
    else
      log('Unsupported command: %s', tostring(command or '<UNKNOWN>'))
      vscode_debugger.send_failure(req, 'Unsupported command')
    end -- if command
  end -- while protocol == 'vscode'
end

function vscode_debugger.pending_io()
  local possible_pending_io = false
  while server:is_pending() do
    local req, err = vscode_debugger.receive_message(false)
    if not req then
      log('  %s', err or 'unknown')
      possible_pending_io = (err == 'timeout')
      break
    end

    local command, args = req.command, req.arguments
    if command == 'setBreakpoints' then
      local file = vscode_debugger.path_from_ide(args.source.path)
      remove_file_breakpoint(file)
      local result = {}
      for i, breakpoint in ipairs(args.breakpoints) do
        set_breakpoint(file, breakpoint.line)
        result[i] = {
          verified = true,
          line     = breakpoint.line,
        }
      end
      vscode_debugger.send_success(req, {breakpoints = result})
    elseif command == 'threads' then
      local result = {
        {
          id   = vscode_thread_id,
          name = vscode_thread_name,
        }
      }
      vscode_debugger.send_success(req, {threads = result})
    else
      log('Unsupported pending command: %s', command)
      vscode_debugger.push_back_message(req)
      return true
    end
  end

  if possible_pending_io then
    return false
  end

  return not not server:is_pending()
end

end

do -- debugger

function debugger.loop_detect_protocol()
  if mobdebug.yield and server.settimeout then server:settimeout(mobdebug.yieldtimeout) end

  local data, err
  while true do
    data, err = server:peek(1, true)
    if data then
      break
    end
    if err == "timeout" then
      if mobdebug.yield then mobdebug.yield() end
    elseif err == "closed" then
      error("Debugger connection closed", 1)
    else
      error(("Unexpected socket error: %s"):format(err), 1)
    end
  end

  if server.settimeout then server:settimeout() end -- back to blocking

  state.protocol = (data == '#') and PROTOCOLS.VSCODE or PROTOCOLS.MOBDEBUG
end

function debugger.loop(sev, svars, sfile, sline)
  debugger.loop_detect_protocol()

  if state.protocol == PROTOCOLS.VSCODE then
    return vscode_debugger.loop(sev, svars, sfile, sline)
  end

  if state.protocol == PROTOCOLS.MOBDEBUG then
    return mobdebug_debugger.loop(sev, svars, sfile, sline)
  end
end

-- return
--   true - need to interrupt debug hook and switch to `debugger_loop`
function debugger.loop_pending_io()
  if state.protocol == PROTOCOLS.VSCODE then
    return vscode_debugger.pending_io()
  end

  if state.protocol == PROTOCOLS.MOBDEBUG then
    return mobdebug_debugger.pending_io()
  end
end

end

local function output(stream, data)
  if server then return server:send("204 Output "..stream.." "..tostring(#data).."\n"..data) end
end

local function connect(controller_host, controller_port)
  local sock, err = socket.tcp()
  if not sock then return nil, err end

  if sock.settimeout then sock:settimeout(mobdebug.connecttimeout) end
  local res, err = sock:connect(controller_host, tostring(controller_port))
  if sock.settimeout then sock:settimeout() end

  if not res then return nil, err end
  return sock
end

local lasthost, lastport

-- Starts a debug session by connecting to a controller
local function start(controller_host, controller_port)
  -- only one debugging session can be run (as there is only one debug hook)
  if isrunning() then return end

  lasthost = controller_host or lasthost
  lastport = controller_port or lastport

  controller_host = lasthost or "localhost"
  controller_port = lastport or mobdebug.port

  local err
  server, err = mobdebug.connect(controller_host, controller_port)
  if server then
    server = Socket.new(server)
    -- correct stack depth which already has some calls on it
    -- so it doesn't go into negative when those calls return
    -- as this breaks subsequence checks in stack_depth().
    -- start from 16th frame, which is sufficiently large for this check.
    state.stack_level = stack_depth(16)

    coro_debugger = corocreate(debugger.loop)
    debug.sethook(debug_hook, HOOKMASK)
    state.seen_hook = nil -- reset in case the last start() call was refused
    state.step_into = true -- start with step command
    return true
  else
    mobdebug.print(("Could not connect to %s:%s: %s")
      :format(controller_host, controller_port, err or "unknown error"))
  end
end

local function controller(controller_host, controller_port, scratchpad)
  -- only one debugging session can be run (as there is only one debug hook)
  if isrunning() then return end

  lasthost = controller_host or lasthost
  lastport = controller_port or lastport

  controller_host = lasthost or "localhost"
  controller_port = lastport or mobdebug.port

  local exitonerror = not scratchpad
  local err
  server, err = mobdebug.connect(controller_host, controller_port)
  if server then
    server = Socket.new(server)

    local function report(trace, err)
      local msg = err .. "\n" .. trace
      server:send("401 Error in Execution " .. tostring(#msg) .. "\n")
      server:send(msg)
      return err
    end

    state.seen_hook = true -- allow to accept all commands
    coro_debugger = corocreate(debugger.loop)

    while true do
      state.step_into = true -- start with step command
      abort = false -- reset abort flag from the previous loop
      if scratchpad then server:enforce_pending_check() end -- force suspend right away

      coro_debugee = corocreate(state.debugee)
      debug.sethook(coro_debugee, debug_hook, HOOKMASK)
      local status, err = cororesume(coro_debugee, unpack(arg or {}))

      -- was there an error or is the script done?
      -- 'abort' state is allowed here; ignore it
      if abort then
        if tostring(abort) == 'exit' then break end
      else
        if status then -- no errors
          if corostatus(coro_debugee) == "suspended" then
            -- the script called `coroutine.yield` in the "main" thread
            error("attempt to yield from the main thread", 3)
          end
          break -- normal execution is done
        elseif err and not string_find(tostring(err), deferror) then
          -- report the error back
          -- err is not necessarily a string, so convert to string to report
          report(debug.traceback(coro_debugee), tostring(err))
          if exitonerror then break end
          -- check if the debugging is done (coro_debugger is nil)
          if not coro_debugger then break end
          -- resume once more to clear the response the debugger wants to send
          -- need to use capture_vars(0) to capture only two (default) levels,
          -- as even though there is controller() call, because of the tail call,
          -- the caller may not exist for it;
          -- This is not entirely safe as the user may see the local
          -- variable from console, but they will be reset anyway.
          -- This functionality is used when scratchpad is paused to
          -- gain access to remote console to modify global variables.
          local status, err = cororesume(coro_debugger, events.RESTART, capture_vars(0))
          if not status or status and err == "exit" then break end
        end
      end
    end
  else
    print(("Could not connect to %s:%s: %s")
      :format(controller_host, controller_port, err or "unknown error"))
    return false
  end
  return true
end

local function scratchpad(controller_host, controller_port)
  return controller(controller_host, controller_port, true)
end

local function loop(controller_host, controller_port)
  return controller(controller_host, controller_port, false)
end

local function on()
  if not (isrunning() and server) then return end

  -- main is set to true under Lua5.2 for the "main" chunk.
  -- Lua5.1 returns co as `nil` in that case.
  local co, main = coroutine.running()
  if main then co = nil end
  if co then
    coroutines[co] = true
    debug.sethook(co, debug_hook, HOOKMASK)
  else
    if jit then coroutines.main = true end
    debug.sethook(debug_hook, HOOKMASK)
  end
end

local function off()
  if not (isrunning() and server) then return end

  -- main is set to true under Lua5.2 for the "main" chunk.
  -- Lua5.1 returns co as `nil` in that case.
  local co, main = coroutine.running()
  if main then co = nil end

  -- don't remove coroutine hook under LuaJIT as there is only one (global) hook
  if co then
    coroutines[co] = false
    if not jit then debug.sethook(co) end
  else
    if jit then coroutines.main = false end
    if not jit then debug.sethook() end
  end

  -- check if there is any thread that is still being debugged under LuaJIT;
  -- if not, turn the debugging off
  if jit then
    local remove = true
    for _, debugged in pairs(coroutines) do
      if debugged then remove = false; break end
    end
    if remove then debug.sethook() end
  end
end

-- Handles server debugging commands
local function handle(params, client, options)
  -- when `options.verbose` is not provided, use normal `print`; verbose output can be
  -- disabled (`options.verbose == false`) or redirected (`options.verbose == function()...end`)
  local verbose = not options or options.verbose ~= nil and options.verbose
  local print = verbose and (type(verbose) == "function" and verbose or print) or function() end
  local file, line, watch_idx
  local _, _, command = string_find(params, "^([a-z]+)")
  if command == "run" or command == "step" or command == "out"
  or command == "over" or command == "exit" then
    client:send(string.upper(command) .. "\n")
    client:receive("*l") -- this should consume the first '200 OK' response
    while true do
      local done = true
      local breakpoint = client:receive("*l")
      if not breakpoint then
        print("Program finished")
        return nil, nil, false
      end
      local _, _, status = string_find(breakpoint, "^(%d+)")
      if status == "200" then
        -- don't need to do anything
      elseif status == "202" then
        _, _, file, line = string_find(breakpoint, "^202 Paused%s+(.-)%s+(%d+)%s*$")
        if file and line then
          print("Paused at file " .. file .. " line " .. line)
        end
      elseif status == "203" then
        _, _, file, line, watch_idx = string_find(breakpoint, "^203 Paused%s+(.-)%s+(%d+)%s+(%d+)%s*$")
        if file and line and watch_idx then
          print("Paused at file " .. file .. " line " .. line .. " (watch expression " .. watch_idx .. ": [" .. state.watches[watch_idx] .. "])")
        end
      elseif status == "204" then
        local _, _, stream, size = string_find(breakpoint, "^204 Output (%w+) (%d+)$")
        if stream and size then
          local size = tonumber(size)
          local msg = size > 0 and client:receive(size) or ""
          print(msg)
          if state.outputs[stream] then state.outputs[stream](msg) end
          -- this was just the output, so go back reading the response
          done = false
        end
      elseif status == "401" then
        local _, _, size = string_find(breakpoint, "^401 Error in Execution (%d+)$")
        if size then
          local msg = client:receive(tonumber(size))
          print("Error in remote application: " .. msg)
          return nil, nil, msg
        end
      else
        print("Unknown error")
        return nil, nil, "Debugger error: unexpected response '" .. breakpoint .. "'"
      end
      if done then break end
    end
  elseif command == "done" then
    client:send(string.upper(command) .. "\n")
    -- no response is expected
  elseif command == "setb" or command == "asetb" then
    _, _, _, file, line = string_find(params, "^([a-z]+)%s+(.-)%s+(%d+)%s*$")
    if file and line then
      -- if this is a file name, and not a file source
      if not file:find('^".*"$') then
        file = string_gsub(file, "\\", "/") -- convert slash
        file = removebasedir(file, state.basedir)
      end
      client:send("SETB " .. file .. " " .. line .. "\n")
      if command == "asetb" or client:receive("*l") == "200 OK" then
        set_breakpoint(file, line)
      else
        print("Error: breakpoint not inserted")
      end
    else
      print("Invalid command")
    end
  elseif command == "setw" then
    local _, _, exp = string_find(params, "^[a-z]+%s+(.+)$")
    if exp then
      client:send("SETW " .. exp .. "\n")
      local answer = client:receive("*l")
      local _, _, watch_idx = string_find(answer, "^200 OK (%d+)%s*$")
      if watch_idx then
        state.watches[watch_idx] = exp
        print("Inserted watch exp no. " .. watch_idx)
      else
        local _, _, size = string_find(answer, "^401 Error in Expression (%d+)$")
        if size then
          local err = client:receive(tonumber(size)):gsub(".-:%d+:%s*","")
          print("Error: watch expression not set: " .. err)
        else
          print("Error: watch expression not set")
        end
      end
    else
      print("Invalid command")
    end
  elseif command == "delb" or command == "adelb" then
    _, _, _, file, line = string_find(params, "^([a-z]+)%s+(.-)%s+(%d+)%s*$")
    if file and line then
      -- if this is a file name, and not a file source
      if not file:find('^".*"$') then
        file = string_gsub(file, "\\", "/") -- convert slash
        file = removebasedir(file, state.basedir)
      end
      client:send("DELB " .. file .. " " .. line .. "\n")
      if command == "adelb" or client:receive("*l") == "200 OK" then
        remove_breakpoint(file, line)
      else
        print("Error: breakpoint not removed")
      end
    else
      print("Invalid command")
    end
  elseif command == "delallb" then
    local file, line = "*", 0
    client:send("DELB " .. file .. " " .. tostring(line) .. "\n")
    if client:receive("*l") == "200 OK" then
      remove_breakpoint(file, line)
    else
      print("Error: all breakpoints not removed")
    end
  elseif command == "delw" then
    local _, _, index = string_find(params, "^[a-z]+%s+(%d+)%s*$")
    if index then
      client:send("DELW " .. index .. "\n")
      if client:receive("*l") == "200 OK" then
        state.watches[index] = nil
      else
        print("Error: watch expression not removed")
      end
    else
      print("Invalid command")
    end
  elseif command == "delallw" then
    for index, exp in pairs(state.watches) do
      client:send("DELW " .. index .. "\n")
      if client:receive("*l") == "200 OK" then
        state.watches[index] = nil
      else
        print("Error: watch expression at index " .. index .. " [" .. exp .. "] not removed")
      end
    end
  elseif command == "eval" or command == "exec"
      or command == "load" or command == "loadstring"
      or command == "reload" then
    local _, _, exp = string_find(params, "^[a-z]+%s+(.+)$")
    if exp or (command == "reload") then
      if command == "eval" or command == "exec" then
        exp = exp:gsub("\n", "\r") -- convert new lines, so the fragment can be passed as one line
        if command == "eval" then exp = "return " .. exp end
        client:send("EXEC " .. exp .. "\n")
      elseif command == "reload" then
        client:send("LOAD 0 -\n")
      elseif command == "loadstring" then
        local _, _, _, file, lines = string_find(exp, "^([\"'])(.-)%1%s(.+)")
        if not file then
           _, _, file, lines = string_find(exp, "^(%S+)%s(.+)")
        end
        client:send("LOAD " .. tostring(#lines) .. " " .. file .. "\n")
        client:send(lines)
      else
        local file = io.open(exp, "r")
        if not file and pcall(require, "winapi") then
          -- if file is not open and winapi is there, try with a short path;
          -- this may be needed for unicode paths on windows
          winapi.set_encoding(winapi.CP_UTF8)
          local shortp = winapi.short_path(exp)
          file = shortp and io.open(shortp, "r")
        end
        if not file then return nil, nil, "Cannot open file " .. exp end
        -- read the file and remove the shebang line as it causes a compilation error
        local lines = file:read("*all"):gsub("^#!.-\n", "\n")
        file:close()

        local fname = string_gsub(exp, "\\", "/") -- convert slash
        fname = removebasedir(fname, state.basedir)
        client:send("LOAD " .. tostring(#lines) .. " " .. fname .. "\n")
        if #lines > 0 then client:send(lines) end
      end
      while true do
        local params, err = client:receive("*l")
        if not params then
          return nil, nil, "Debugger connection " .. (err or "error")
        end
        local done = true
        local _, _, status, len = string_find(params, "^(%d+).-%s+(%d+)%s*$")
        if status == "200" then
          len = tonumber(len)
          if len > 0 then
            local status, res
            local str = client:receive(len)
            -- handle serialized table with results
            local func, err = loadstring(str)
            if func then
              status, res = pcall(func)
              if not status then err = res
              elseif type(res) ~= "table" then
                err = "received "..type(res).." instead of expected 'table'"
              end
            end
            if err then
              print("Error in processing results: " .. err)
              return nil, nil, "Error in processing results: " .. err
            end
            print(unpack(res))
            return res[1], res
          end
        elseif status == "201" then
          _, _, file, line = string_find(params, "^201 Started%s+(.-)%s+(%d+)%s*$")
        elseif status == "202" or params == "200 OK" then
          -- do nothing; this only happens when RE/LOAD command gets the response
          -- that was for the original command that was aborted
        elseif status == "204" then
          local _, _, stream, size = string_find(params, "^204 Output (%w+) (%d+)$")
          if stream and size then
            local size = tonumber(size)
            local msg = size > 0 and client:receive(size) or ""
            print(msg)
            if state.outputs[stream] then state.outputs[stream](msg) end
            -- this was just the output, so go back reading the response
            done = false
          end
        elseif status == "401" then
          len = tonumber(len)
          local res = client:receive(len)
          print("Error in expression: " .. res)
          return nil, nil, res
        else
          print("Unknown error")
          return nil, nil, "Debugger error: unexpected response after EXEC/LOAD '" .. params .. "'"
        end
        if done then break end
      end
    else
      print("Invalid command")
    end
  elseif command == "listb" then
    for l, v in pairs(state.breakpoints) do
      for f in pairs(v) do
        print(f .. ": " .. l)
      end
    end
  elseif command == "listw" then
    for i, v in pairs(state.watches) do
      print("Watch exp. " .. i .. ": " .. v)
    end
  elseif command == "suspend" then
    client:send("SUSPEND\n")
  elseif command == "stack" then
    local opts = string.match(params, "^[a-z]+%s+(.+)$")
    client:send("STACK" .. (opts and " "..opts or "") .."\n")
    local resp = client:receive("*l")
    local _, _, status, res = string_find(resp, "^(%d+)%s+%w+%s+(.+)%s*$")
    if status == "200" then
      local func, err = loadstring(res)
      if func == nil then
        print("Error in stack information: " .. err)
        return nil, nil, err
      end
      local ok, stack = pcall(func)
      if not ok then
        print("Error in stack information: " .. stack)
        return nil, nil, stack
      end
      for _,frame in ipairs(stack) do
        print(mobdebug.line(frame[1], {comment = false}))
      end
      return stack
    elseif status == "401" then
      local _, _, len = string_find(resp, "%s+(%d+)%s*$")
      len = tonumber(len)
      local res = len > 0 and client:receive(len) or "Invalid stack information."
      print("Error in expression: " .. res)
      return nil, nil, res
    else
      print("Unknown error")
      return nil, nil, "Debugger error: unexpected response after STACK"
    end
  elseif command == "output" then
    local _, _, stream, mode = string_find(params, "^[a-z]+%s+(%w+)%s+([dcr])%s*$")
    if stream and mode then
      client:send("OUTPUT "..stream.." "..mode.."\n")
      local resp, err = client:receive("*l")
      if not resp then
        print("Unknown error: "..err)
        return nil, nil, "Debugger connection error: "..err
      end
      local _, _, status = string_find(resp, "^(%d+)%s+%w+%s*$")
      if status == "200" then
        print("Stream "..stream.." redirected")
        state.outputs[stream] = type(options) == 'table' and options.handler or nil
      -- the client knows when she is doing, so install the handler
      elseif type(options) == 'table' and options.handler then
        state.outputs[stream] = options.handler
      else
        print("Unknown error")
        return nil, nil, "Debugger error: can't redirect "..stream
      end
    else
      print("Invalid command")
    end
  elseif command == "basedir" then
    local _, _, dir = string_find(params, "^[a-z]+%s+(.+)$")
    if dir then
      dir = string_gsub(dir, "\\", "/") -- convert slash
      if not string_find(dir, "/$") then dir = dir .. "/" end

      local remdir = dir:match("\t(.+)")
      if remdir then dir = dir:gsub("/?\t.+", "/") end
      state.basedir = dir

      client:send("BASEDIR "..(remdir or dir).."\n")
      local resp, err = client:receive("*l")
      if not resp then
        print("Unknown error: "..err)
        return nil, nil, "Debugger connection error: "..err
      end
      local _, _, status = string_find(resp, "^(%d+)%s+%w+%s*$")
      if status == "200" then
        print("New base directory is " .. state.basedir)
      else
        print("Unknown error")
        return nil, nil, "Debugger error: unexpected response after BASEDIR"
      end
    else
      print(state.basedir)
    end
  elseif command == "help" then
    print("setb <file> <line>    -- sets a breakpoint")
    print("delb <file> <line>    -- removes a breakpoint")
    print("delallb               -- removes all breakpoints")
    print("setw <exp>            -- adds a new watch expression")
    print("delw <index>          -- removes the watch expression at index")
    print("delallw               -- removes all watch expressions")
    print("run                   -- runs until next breakpoint")
    print("step                  -- runs until next line, stepping into function calls")
    print("over                  -- runs until next line, stepping over function calls")
    print("out                   -- runs until line after returning from current function")
    print("listb                 -- lists breakpoints")
    print("listw                 -- lists watch expressions")
    print("eval <exp>            -- evaluates expression on the current context and returns its value")
    print("exec <stmt>           -- executes statement on the current context")
    print("load <file>           -- loads a local file for debugging")
    print("reload                -- restarts the current debugging session")
    print("stack                 -- reports stack trace")
    print("output stdout <d|c|r> -- capture and redirect io stream (default|copy|redirect)")
    print("basedir [<path>]      -- sets the base path of the remote application, or shows the current one")
    print("done                  -- stops the debugger and continues application execution")
    print("exit                  -- exits debugger and the application")
  else
    local _, _, spaces = string_find(params, "^(%s*)$")
    if spaces then
      return nil, nil, "Empty command"
    else
      print("Invalid command")
      return nil, nil, "Invalid command"
    end
  end
  return file, line
end

-- Starts debugging server
local function listen(host, port)
  host = host or "*"
  port = port or mobdebug.port

  local socket = require "socket"

  print("Lua Remote Debugger")
  print("Run the program you wish to debug")

  local server = socket.bind(host, port)
  local client = server:accept()

  client:send("STEP\n")
  client:receive("*l")

  local breakpoint = client:receive("*l")
  local _, _, file, line = string_find(breakpoint, "^202 Paused%s+(.-)%s+(%d+)%s*$")
  if file and line then
    print("Paused at file " .. file )
    print("Type 'help' for commands")
  else
    local _, _, size = string_find(breakpoint, "^401 Error in Execution (%d+)%s*$")
    if size then
      print("Error in remote application: ")
      print(client:receive(size))
    end
  end

  while true do
    io.write("> ")
    local file, _, err = handle(io.read("*line"), client)
    if not file and err == false then break end -- completed debugging
  end

  client:close()
end

local cocreate
local function coro()
  if cocreate then return end -- only set once
  cocreate = cocreate or coroutine.create
  coroutine.create = function(f, ...)
    return cocreate(function(...)
      mobdebug.on()
      return f(...)
    end, ...)
  end
end

local moconew
local function moai()
  if moconew then return end -- only set once
  moconew = moconew or (MOAICoroutine and MOAICoroutine.new)
  if not moconew then return end
  MOAICoroutine.new = function(...)
    local thread = moconew(...)
    -- need to support both thread.run and getmetatable(thread).run, which
    -- was used in earlier MOAI versions
    local mt = thread.run and thread or getmetatable(thread)
    local patched = mt.run
    mt.run = function(self, f, ...)
      return patched(self,  function(...)
        mobdebug.on()
        return f(...)
      end, ...)
    end
    return thread
  end
end

-- make public functions available
mobdebug.setbreakpoint = set_breakpoint
mobdebug.removebreakpoint = remove_breakpoint
mobdebug.listen = listen
mobdebug.loop = loop
mobdebug.scratchpad = scratchpad
mobdebug.handle = handle
mobdebug.connect = connect
mobdebug.start = start
mobdebug.on = on
mobdebug.off = off
mobdebug.moai = moai
mobdebug.coro = coro
mobdebug.done = done
mobdebug.pause = function() state.step_into = true end
mobdebug.yield = nil -- callback
mobdebug.output = output
mobdebug.onexit = os and os.exit or done
mobdebug.onscratch = nil -- callback
mobdebug.basedir = function(b) if b then state.basedir = b end return state.basedir end

return mobdebug
