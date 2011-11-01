local debug = require "debug"
local coro_debugger
local events = { BREAK = 1, WATCH = 2 }
local step_into = true
local abort = false
local load

local function debug_hook(event, line)
  if event == "line" then
    if step_into then
      step_into = false
      coroutine.resume(coro_debugger, events.BREAK, vars, file, line)
    elseif abort then 
print("Abort requested; back to controller...")
      error("aborted")
    end
  end
end

local function test()
  print("Start")
  local foo = 0
  for i = 1, 3 do
    local function bar()
      print("In bar")
    end
    foo = i
    print("Loop")
    bar()
  end
  print("End")
end

local test1 = [[
  print("Start 1")
  for i = 1, 3 do
    print("Loop " .. i)
  end
  print("End 1")
]]

local commands = {'step', 'step', 'reload', 'step', 'load', 'step', 'run'}

local function debugger_loop()
  while #commands do
    local line = table.remove(commands, 1)
    local command = string.sub(line, string.find(line, "^[a-z]+"))
print("Executing '" .. command .. "'")
    if command == "run" then
      local ev, vars, file, line = coroutine.yield()
    elseif command == "step" then
      step_into = true
      local ev, vars, file, line = coroutine.yield()
    elseif command == "reload" then
      abort = true
      coroutine.yield()
    elseif command == "load" then
      load = loadstring(test1)
      abort = true
      coroutine.yield()
    else
      print("Invalid command")
    end
  end
end
  
load = test

coro_debugger = coroutine.create(debugger_loop)

local n = 0
while true do 
  n = n + 1
  step_into = true
  abort = false
  print("Starting a new debugging session")
  local coro_debugee = coroutine.create(load)
  debug.sethook(coro_debugee, debug_hook, "lcr")
  coroutine.resume(coro_debugee)
  print("Done " .. n .. " " .. coroutine.status(coro_debugee))
  if not abort then break end
end

print "Done all"
