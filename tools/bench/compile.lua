-- front end benchmark: compiles (does not run) a large generated program many times
local lines = {}
for i = 1, 400 do
  lines[#lines + 1] = string.format([[
function f%d(a, b, ...)
  local t = {x = a, y = b, [1] = "s%d", 3.5, n = select('#', ...)}
  if a > b then return t.x + t.y * %d elseif a == b then return -a else
    for i = 1, 10 do t[i] = (t[i] or 0) + i %% 3 end
  end
  local s = "abc" .. a .. 'def' .. %d
  while b > 0 do b = b - 1; if b == 5 then break end end
  return function(q) return q and s or t, #t, not a end
end]], i, i, i, i)
end
local src = table.concat(lines, "\n")
local t = os.clock()
for i = 1, 25 do assert(load(src)) end
print(#src, os.clock() - t)
