local t = {}
local seed = 42
for i = 1, 3e5 do seed = (seed * 1103515245 + 12345) % 2147483648; t[i] = seed end
table.sort(t)
local u = {}
for i = 1, 2e5 do u[i] = tostring(t[i]) end
table.sort(u, function(a, b) return a > b end)
print(t[1], u[1])
