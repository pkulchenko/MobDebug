local mobdebug = require "mobdebug"
local socket = require "socket"
local server = socket.bind('*', 8172)

local realprint = print
-- uncomment the next line if you ONLY want to see debug output
-- _G.print = function () end

print("Lua Remote Debugger")
print("Run the program you wish to debug")

local client = server:accept()

local commands = {
  'load auto/test.lua', -- load Lua script and start debugger
  'over', 'over', 'step', 'over', 'setb auto/test.lua 15', 'run',
  'reload', -- reload the same script; breakpoints/watches still stay
  'run',
  {'eval tab.foo', 2, "this should fail"}, -- should display "not ok"
  {'eval tab.bar', 2, "this should work"}, -- should display "ok"
  'exec old_tab = tab', 'exec tab = 2', 'eval tab',
  'exec tab = old_tab', 'eval tab.foo', 'run',
  'eval tab.foo',
  'listb',
  'delb auto\\test.lua 15', -- this removes breakpoint set with "setb - 15"
  'setw tab.foo == 32',
  'listw',
  'stack',
  'basedir foo', -- set `foo` as the current basedir
  'basedir',
  'output stdout c', -- copy print output
  'run', 'eval tab.foo', 'delw 1', 'run'
}

local test = 0
local curfile, curline = '', ''
while #commands > 0 do
  local command = table.remove(commands, 1)
  local expected, msg
  if type(command) == 'table' then
    command, expected, msg = command[1], command[2], (command[3] or '')
  end  

  print("> " .. command)
  local result, line, err = mobdebug.handle(command, client)

  if not err and expected then
    local ok = tostring(result) == tostring(expected)
    test = test + 1
    realprint((not ok and "not " or "") .. "ok " .. test .. (msg and (" - " .. msg) or ""))
    realprint((not ok and ("#     Failed test (" .. curfile .. " at line " .. curline .. ")" ..
                           "\n#          got: " .. result .. 
                           "\n#     expected: " .. expected) or ""))
  else
    curfile, curline = result, line
  end
end
