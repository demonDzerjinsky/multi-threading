-- Simple Lua coroutine example

-- Create a coroutine that acts like a counter/generator
local co = coroutine.create(function(limit)
  for i = 1, limit do
    print("  coroutine: counting", i)
    coroutine.yield(i) -- pause and hand control back to the main program
  end
  return "finished counting"
end)

-- Drive the coroutine manually
for step = 1, 3 do
  print("main: resuming coroutine (step " .. step .. ")")
  local ok, value = coroutine.resume(co, 3)
  print("  main: got", value) -- first resume passes 3 as `limit`
end

print("status:", coroutine.status(co))
