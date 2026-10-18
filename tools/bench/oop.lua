local Point = {}
Point.__index = Point
function Point.new(x, y) return setmetatable({x = x, y = y}, Point) end
function Point:add(o) return Point.new(self.x + o.x, self.y + o.y) end
function Point:len2() return self.x * self.x + self.y * self.y end
local p = Point.new(0, 0)
local d = Point.new(1, 2)
local acc = 0
for i = 1, 3e6 do p = p:add(d); acc = acc + p:len2() % 3 end
local function counter() local c = 0 return function() c = c + 1 return c end end
local f = counter()
for i = 1, 5e6 do f() end
print(p.x, p.y, acc, f())
