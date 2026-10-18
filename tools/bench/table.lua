local t = {}
for i = 1, 3e6 do t[i] = i end
local s = 0
for i = 1, #t do s = s + t[i] end
local h = {}
for i = 1, 5e5 do h["k" .. i] = i end
local c = 0
for k, v in pairs(h) do c = c + v end
for i = 1, 5e5 do h["k" .. i] = nil end
print(s, c)
