local parts = {}
for i = 1, 3e5 do parts[#parts + 1] = tostring(i) .. "," end
local s = table.concat(parts)
local n = 0
for w in s:gmatch("%d+") do n = n + #w end
local r = s:gsub("1", "one")
local u = 0
for i = 1, 1e6 do u = u + #(("x"):rep(i % 10)) + (s:byte(i % 1000 + 1)) end
local f = 0
for i = 1, 3e5 do f = f + #string.format("%d:%s:%5.2f", i, "a", i / 3) end
print(#s, n, #r, u, f, s:find("299999,", 1, true))
