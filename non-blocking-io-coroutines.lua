-- non_blocking_io_coroutines.lua
--
-- Non-blocking IO with plain coroutines + libuv (luv).
-- No frameworks: the callback IS the resumer.
--
-- Install: luarocks install luv
-- Run:     lua non_blocking_io_coroutines.lua

local uv = require "luv"

-- Async: run fn in a coroutine
local function async(fn)
  return function(...)
    local ok, err = coroutine.resume(coroutine.create(fn), ...)
    if not ok then error(err, 0) end
  end
end

-- Await: suspend this coroutine until the libuv callback fires,
-- then the callback resumes it with the IO results.
local function await(fn, ...)
  local co = coroutine.running()
  fn(function(err, ...)
    coroutine.resume(co, err, ...)
  end, ...)
  return coroutine.yield()   -- thread suspends here
end

local function sleep(ms)
  local co = coroutine.running()
  local t = uv.new_timer()
  t:start(ms, 0, function()
    uv.close(t)
    coroutine.resume(co)
  end)
  coroutine.yield()
end

-- Now IO reads like sequential, blocking code:
async(function()
  print "start; loop is NOT blocked"
  await(sleep, 500)

  local err, fd = await(uv.fs_open, "readme.md", "r", 438)
  if err then error(err) end

  local _, data = await(uv.fs_read, fd, 4096, -1)
  await(uv.fs_close, fd)

  print(("read %d bytes asynchronously"):format(#data))
  uv.stop()  -- optional: end the loop now
end)

-- A second coroutine running concurrently in the same loop,
-- to demonstrate that nothing is blocked:
async(function()
  for i = 1, 3 do
    await(sleep, 200)
    print("other coroutine tick", i)
  end
end)

uv.run()   -- drive the event loop; callbacks fire here,
           -- and each callback is the thing that calls coroutine.resume
