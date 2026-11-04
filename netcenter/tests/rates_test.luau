--!nonstrict

local rates = require("../rates.luau")

local cases = {
  { rates.compact, 0, "0B/s" },
  { rates.compact, 512, "512B/s" },
  { rates.compact, 999.6, "1.0KB/s" },
  { rates.compact, 9_800, "9.8KB/s" },
  { rates.compact, 9_960, "10KB/s" },
  { rates.compact, 120_000, "120KB/s" },
  { rates.compact, 999_700, "1.0MB/s" },
  { rates.compact, 3_800_000, "3.8MB/s" },
  { rates.full, 512, "512 B/s" },
  { rates.full, 120_000, "120 KB/s" },
  { rates.full, 3_800_000, "3.8 MB/s" },
}

return function(report)
  local failed = 0
  for _, case in cases do
    local format, input, expected = case[1], case[2], case[3]
    local actual = format(input)
    if actual == expected then
      report(`ok - {input} -> {expected}`)
    else
      failed += 1
      report(`not ok - {input}: expected "{expected}", got "{actual}"`)
    end
  end

  if failed > 0 then
    error(`{failed} of {#cases} cases failed`)
  end
end
