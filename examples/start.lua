require("mobdebug").start() -- same as start("localhost", 8171)

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
