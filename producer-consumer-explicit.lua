-- Producer-consumer with explicit create/resume (two-way communication)
--
-- Same "parser feeding a processor" pattern as producer_consumer.lua,
-- but with the low-level coroutine API, which unlocks full control:
--
--   * coroutines are bidirectional: resume(co, ack) passes `ack` INTO
--     the producer -- it becomes the return value of yield() inside.
--     The yielded record travels back OUT as the second return value
--     of resume(). So `ack` here models a backpressure / "keep going?"
--     signal from consumer to producer.
--
--   * error handling: if the producer body raises an error, resume()
--     returns (false, errmsg) instead of crashing the whole program.
--     With coroutine.wrap the same error would propagate immediately.
--
--   * lifecycle detection: resume() returns true both for a yielded
--     value AND for the coroutine finishing, so you must check
--     coroutine.status(co) == "dead" to tell "here is a record" apart
--     from "I'm done" (the final `return "all lines parsed"`).
--
-- Trade-off vs the wrap() version: more boilerplate (the while-loop
-- driving protocol), but you get ack/backpressure, error isolation,
-- and explicit control over when the producer runs.

local function make_parser(lines)
  return coroutine.create(function()
    for _, raw in ipairs(lines) do
      local name, value = raw:match("(%w+)=(%d+)")
      -- yield the record out; the resume args (ack) come back in
      local ack = coroutine.yield({ name = name, value = tonumber(value) })
      if not ack then
        print("  producer: consumer says stop, aborting early")
        return
      end
    end
    return "all lines parsed"
  end)
end

local function process(rec)
  print(("processing %s -> %d (double: %d)")
    :format(rec.name, rec.value, rec.value * 2))
  return true -- ack: tell the producer to continue
end

local records = { "hp=100", "mp=50", "exp=250", "gold=999" }
local co = make_parser(records)

-- Drive the producer manually with resume
while true do
  local ok, rec = coroutine.resume(co, true) -- send ack=true into producer
  if not ok then
    print("producer errored:", rec)
    break
  elseif coroutine.status(co) == "dead" then
    print("producer finished:", rec) -- final return value
    break
  else
    if not process(rec) then
      coroutine.resume(co, false) -- send ack=false: stop early
      break
    end
  end
end
