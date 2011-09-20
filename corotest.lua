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
print("resuming debugger...")
      coroutine.resume(coro_debugger, events.BREAK, vars, file, line)
    elseif abort then 
      abort = false
print("aborting back to controller...")
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

local function test1()
  print("Start 1")
  for i = 1, 3 do
    print("Loop " .. i)
  end
  print("End 1")
end

local function debugger_loop(server)
  while true do
    io.write("> ")
    local line = io.read("*line")
    local command = string.sub(line, string.find(line, "^[a-z]+"))
    if command == "run" then
      local ev, vars, file, line = coroutine.yield()
    elseif command == "step" then
      step_into = true
      local ev, vars, file, line = coroutine.yield()
    elseif command == "reload" then
      abort = true
      coroutine.yield()
    elseif command == "load" then
      load = test1
      abort = true
      coroutine.yield()
    else
      print("Invalid command")
    end
  end
end
  
load = test

coro_debugger = coroutine.create(debugger_loop)

while true do 
  step_into = true
  local coro_debugee = coroutine.create(load)
  debug.sethook(coro_debugee, debug_hook, "lcr")
  coroutine.resume(coro_debugee)
  print("done " .. coroutine.status(coro_debugee))
end
