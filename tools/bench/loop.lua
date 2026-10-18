local s = 0
for i = 1, 3e7 do s = s + i % 7 end
local x = 0.0
for i = 1, 1e7 do x = x + i * 0.5 end
print(s, x)
