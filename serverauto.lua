require "mobdebug"
local socket = require "socket"
local server = socket.bind('*', 8171)

print("Lua Remote Debugger")
print("Run the program you wish to debug")

local client = server:accept()

local commands = {
  'load test.lua', -- load Lua script and start debugger
  'over', 'over', 'step', 'over', 'setb test.lua 19', 'run', 
  'reload', -- reload the same script; breakpoints/watches still stay
  'run', 'eval tab.foo', 'eval tab.bar', 
  'exec old_tab = tab', 'exec tab = 2', 'eval tab',
  'exec tab = old_tab', 'eval tab.foo', 'run', 
  'eval tab.foo', 'delb test.lua 19', 'setw tab.foo == 32',
  'run', 'eval tab.foo', 'delw 1', 'run'
}

while #commands do
  local command = table.remove(commands, 1)
  print("> " .. command)
  mobdebug.handle(command, client)
end
