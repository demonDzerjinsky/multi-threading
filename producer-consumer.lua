-- Producer-consumer with coroutines (iterator style, coroutine.wrap)
--
-- Demonstrates the "parser feeding a processor" pattern:
--   * PRODUCER: a coroutine that parses raw "key=value" lines into
--     records one at a time, pausing (yield) after each one.
--   * CONSUMER: a plain for-loop that pulls records and processes them.
--
-- Key ideas:
--   * coroutine.wrap turns the producer into an iterator function, so
--     the consumer can use a normal `for rec in ... do` loop.
--   * Each yield() freezes the producer mid-loop (loop index, locals
--     all preserved) and hands one record to the consumer. On the next
--     pull, execution continues exactly where it left off.
--   * No intermediate table of ALL parsed records is ever built --
--     records exist one at a time, lazily.
--   * When the producer runs out of input, its function returns and
--     the for-loop ends naturally. No manual resume/status checks.
--
-- This is the simplest, most idiomatic form: data flows one way
-- (producer -> consumer), and you never touch resume/status yourself.

-- Producer: pretends to parse a stream of raw lines into records
local function make_parser(lines)
  return coroutine.wrap(function()
    for _, raw in ipairs(lines) do
      local name, value = raw:match("(%w+)=(%d+)")
      -- looks like a normal function call, but pauses here
      -- and hands the parsed record to whoever pulls next
      coroutine.yield({ name = name, value = tonumber(value) })
    end
  end) -- done: producer is exhausted, wrap() loop ends naturally
end

-- Consumer: processes each record; also plain linear code
local function process(rec)
  print(("processing %s -> %d (double: %d)")
    :format(rec.name, rec.value, rec.value * 2))
end

-- Wire them together: consumer pulls from producer
local records = { "hp=100", "mp=50", "exp=250", "gold=999" }
for rec in make_parser(records) do
  process(rec)
end
