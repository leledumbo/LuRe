unit lualibtab;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// The table library.

interface

uses
  SysUtils, Math, luacore, luavm, luaaux;

procedure OpenTable(L: TLua);

implementation

const
  TAB_R = 1;   // read
  TAB_W = 2;   // write
  TAB_L = 4;   // length
  RANLIMIT = 100;

function HasMeta(L: TLua; const v: TLuaValue; const name: string): Boolean;
begin
  Result := GetMetaField(L, v, name).Vt <> vtNil;
end;

// checks that the argument is a table or behaves like one
procedure CheckTab(L: TLua; arg, what: Integer);
var
  v: TLuaValue;
begin
  v := LuaArg(L, arg);
  if v.Vt = vtTab then Exit;
  if (GetMetatable(L, v) <> nil) and
     (((what and TAB_R) = 0) or HasMeta(L, v, '__index')) and
     (((what and TAB_W) = 0) or HasMeta(L, v, '__newindex')) and
     (((what and TAB_L) = 0) or HasMeta(L, v, '__len')) then
    Exit;
  TypeErrorArg(L, arg, 'table');
end;

function AuxGetN(L: TLua; arg, what: Integer): Int64;
var
  v: TLuaValue;
begin
  CheckTab(L, arg, what or TAB_L);
  v := LuaLen(L, LuaArg(L, arg));
  if v.Vt <> vtInt then
  begin
    if not ToInteger(v, Result) then
      LuaError(L, 'object length is not an integer');
    Exit;
  end;
  Result := v.I;
end;

function GetI(L: TLua; const t: TLuaValue; i: Int64): TLuaValue; inline;
begin
  if (t.Vt = vtTab) and (t.T.Metatable = nil) then
    Result := TableGetInt(t.T, i)
  else
    Result := LuaIndex(L, t, LuaInt(i));
end;

procedure SetI(L: TLua; const t: TLuaValue; i: Int64; const v: TLuaValue); inline;
begin
  if (t.Vt = vtTab) and (t.T.Metatable = nil) then
    TableSetInt(t.T, i, v)
  else
    LuaSetIndex(L, t, LuaInt(i), v);
end;

function tinsert(L: TLua): Integer;
var
  e, pos, i: Int64;
  t: TLuaValue;
begin
  e := AuxGetN(L, 1, TAB_R or TAB_W) + 1;
  t := LuaArg(L, 1);
  case LuaGetTop(L) of
    2: pos := e;
    3: begin
      pos := CheckInteger(L, 2);
      if QWord(pos) - 1 >= QWord(e) then ArgError(L, 2, 'position out of bounds');
      i := e;
      while i > pos do
      begin
        SetI(L, t, i, GetI(L, t, i - 1));
        Dec(i);
      end;
    end;
  else
    LuaError(L, 'wrong number of arguments to ''insert''');
    pos := 0;
  end;
  SetI(L, t, pos, LuaArg(L, -1));
  Result := 0;
end;

function tremove(L: TLua): Integer;
var
  size, pos: Int64;
  t, v: TLuaValue;
begin
  size := AuxGetN(L, 1, TAB_R or TAB_W);
  pos := OptInteger(L, 2, size);
  t := LuaArg(L, 1);
  if pos <> size then
    if QWord(pos) - 1 > QWord(size) then ArgError(L, 2, 'position out of bounds');
  v := GetI(L, t, pos);
  LuaPush(L, v);
  while pos < size do
  begin
    SetI(L, t, pos, GetI(L, t, pos + 1));
    Inc(pos);
  end;
  if pos <= size then SetI(L, t, pos, LuaNil)
  else if pos = size + 1 then SetI(L, t, pos, LuaNil);
  Result := 1;
end;

function tmove(L: TLua): Integer;
var
  f, e, t, n, i: Int64;
  tt: Integer;
  a1, a2: TLuaValue;
begin
  CheckTab(L, 1, TAB_R);
  f := CheckInteger(L, 2);
  e := CheckInteger(L, 3);
  t := CheckInteger(L, 4);
  if ArgIsNoneOrNil(L, 5) then tt := 1 else tt := 5;
  CheckTab(L, tt, TAB_W);
  a1 := LuaArg(L, 1);
  a2 := LuaArg(L, tt);
  if e >= f then
  begin
    if not ((f > 0) or (e < LUA_MAXINTEGER + f)) then ArgError(L, 3, 'too many elements to move');
    n := e - f + 1;
    if t > LUA_MAXINTEGER - n + 1 then ArgError(L, 4, 'destination wrap around');
    if (t > e) or (t <= f) or ((tt <> 1) and not LuaEquals(L, a1, a2)) then
    begin
      for i := 0 to n - 1 do
        SetI(L, a2, t + i, GetI(L, a1, f + i));
    end
    else
    begin
      for i := n - 1 downto 0 do
        SetI(L, a2, t + i, GetI(L, a1, f + i));
    end;
  end;
  LuaPush(L, a2);
  Result := 1;
end;

function tconcat(L: TLua): Integer;
var
  last, i: Int64;
  sep, b: RawByteString;
  t, v: TLuaValue;
begin
  CheckTab(L, 1, TAB_R or TAB_L);
  last := AuxGetN(L, 1, TAB_R);
  sep := OptString(L, 2, '');
  i := OptInteger(L, 3, 1);
  last := OptInteger(L, 4, last);
  t := LuaArg(L, 1);
  b := '';
  while i <= last do
  begin
    v := GetI(L, t, i);
    if not (v.Vt in [vtStr, vtInt, vtFlt]) then
      LuaError(L, Format('invalid value (at index %d) in table for ''concat''', [i]));
    if v.Vt = vtStr then b := b + v.S.Str else b := b + RawByteString(NumToStr(v));
    if i <> last then b := b + sep;
    if i = High(Int64) then Break;
    Inc(i);
  end;
  PushStr(L, b);
  Result := 1;
end;

function tpack(L: TLua): Integer;
var
  n, i: Integer;
  t: TTable;
begin
  n := LuaGetTop(L);
  t := L.NewTable(n, 1);
  for i := 1 to n do TableSetInt(t, i, LuaArg(L, i));
  TableSetStr(t, StrKey(L, 'n'), LuaInt(n));
  LuaPush(L, LuaTab(t));
  Result := 1;
end;

function tunpack(L: TLua): Integer;
var
  i, e, n, k: Int64;
  t: TLuaValue;
begin
  i := OptInteger(L, 2, 1);
  if ArgIsNoneOrNil(L, 3) then e := AuxGetN(L, 1, TAB_R) else e := CheckInteger(L, 3);
  if i > e then Exit(0);
  if (QWord(e) - QWord(i) >= QWord(High(Int32))) or (QWord(e) - QWord(i) + 1 >= QWord(1000000 - L.Top)) then
    LuaError(L, 'too many results to unpack');
  n := e - i;
  t := LuaArg(L, 1);
  L.EnsureStack(L.Top + Integer(n) + 5);
  k := i;
  while k < e do
  begin
    LuaPush(L, GetI(L, t, k));
    Inc(k);
  end;
  LuaPush(L, GetI(L, t, e));
  Result := Integer(n) + 1;
end;

function tcreate(L: TLua): Integer;
var
  narr, nrec: Int64;
begin
  narr := CheckInteger(L, 1);
  nrec := OptInteger(L, 2, 0);
  if (narr < 0) or (narr > High(Int32)) then ArgError(L, 1, 'out of range');
  if (nrec < 0) or (nrec > High(Int32)) then ArgError(L, 2, 'out of range');
  if (nrec >= 1 shl 26) or (narr >= 1 shl 28) then LuaError(L, 'table overflow');
  LuaPush(L, LuaTab(L.NewTable(Integer(narr), Integer(nrec))));
  Result := 1;
end;

{ ------------------------------------------------------------------ }
{ sort                                                                }
{ ------------------------------------------------------------------ }

type
  TSortCtx = record
    L: TLua;
    T: TLuaValue;
    HasFunc: Boolean;
    Func: TLuaValue;
  end;

function SortLess(var c: TSortCtx; const a, b: TLuaValue): Boolean;
var
  r: TLuaValue;
begin
  if c.HasFunc then
  begin
    LuaPush(c.L, c.Func);
    LuaPush(c.L, a);
    LuaPush(c.L, b);
    LuaCall(c.L, 2, 1);
    r := c.L.Stack[c.L.Top - 1];
    Dec(c.L.Top);
    Result := Truthy(r);
  end
  else
    Result := LuaLessThan(c.L, a, b);
end;

procedure SetPair(var c: TSortCtx; i, j: Int64; const vi, vj: TLuaValue);
begin
  SetI(c.L, c.T, i, vj);
  SetI(c.L, c.T, j, vi);
end;

function Partition(var c: TSortCtx; lo, up: Int64; const pv: TLuaValue): Int64;
var
  i, j: Int64;
  vi, vj: TLuaValue;
begin
  i := lo;
  j := up - 1;
  while True do
  begin
    // repeat ++i while a[i] < P
    while True do
    begin
      Inc(i);
      vi := GetI(c.L, c.T, i);
      if not SortLess(c, vi, pv) then Break;
      if i = up - 1 then LuaError(c.L, 'invalid order function for sorting');
    end;
    // repeat --j while P < a[j]
    while True do
    begin
      Dec(j);
      vj := GetI(c.L, c.T, j);
      if not SortLess(c, pv, vj) then Break;
      if j < i then LuaError(c.L, 'invalid order function for sorting');
    end;
    if j < i then
    begin
      // swap pivot (a[up - 1]) with a[i]
      SetPair(c, up - 1, i, GetI(c.L, c.T, up - 1), vi);
      Exit(i);
    end;
    SetPair(c, i, j, vi, vj);
  end;
end;

function ChoosePivot(lo, up: Int64; rnd: Cardinal): Int64;
var
  r4: Int64;
begin
  r4 := (up - lo) div 4;
  Result := Int64(rnd mod Cardinal(r4 * 2)) + (lo + r4);
end;

procedure AuxSort(var c: TSortCtx; lo, up: Int64; rnd: Cardinal);
var
  p, n: Int64;
  a, b, pv, vu: TLuaValue;
begin
  while lo < up do
  begin
    a := GetI(c.L, c.T, lo);
    b := GetI(c.L, c.T, up);
    if SortLess(c, b, a) then SetPair(c, lo, up, a, b);
    if up - lo = 1 then Break;
    if (up - lo < RANLIMIT) or (rnd = 0) then
      p := (lo + up) div 2
    else
      p := ChoosePivot(lo, up, rnd);
    a := GetI(c.L, c.T, p);
    b := GetI(c.L, c.T, lo);
    if SortLess(c, a, b) then
      SetPair(c, p, lo, a, b)
    else
    begin
      vu := GetI(c.L, c.T, up);
      if SortLess(c, vu, a) then SetPair(c, p, up, a, vu);
    end;
    if up - lo = 2 then Break;
    pv := GetI(c.L, c.T, p);
    vu := GetI(c.L, c.T, up - 1);
    SetPair(c, p, up - 1, pv, vu);
    p := Partition(c, lo, up, pv);
    if p - lo < up - p then
    begin
      AuxSort(c, lo, p - 1, rnd);
      n := p - lo;
      lo := p + 1;
    end
    else
    begin
      AuxSort(c, p + 1, up, rnd);
      n := up - p;
      up := p - 1;
    end;
    if (up - lo) div 128 > n then
      rnd := Cardinal(GetTickCount64 xor Cardinal(PtrUInt(@c)));
  end;
end;

function tsort(L: TLua): Integer;
var
  n: Int64;
  c: TSortCtx;
begin
  n := AuxGetN(L, 1, TAB_R or TAB_W);
  if n > 1 then
  begin
    if n >= High(Int32) then ArgError(L, 1, 'array too big');
    if not ArgIsNoneOrNil(L, 2) then
    begin
      if LuaArg(L, 2).Vt <> vtFunc then TypeErrorArg(L, 2, 'function');
    end;
    c.L := L;
    c.T := LuaArg(L, 1);
    c.HasFunc := not ArgIsNoneOrNil(L, 2);
    if c.HasFunc then c.Func := LuaArg(L, 2) else c.Func := LuaNil;
    AuxSort(c, 1, n, 0);
  end;
  Result := 0;
end;

procedure OpenTable(L: TLua);
const
  Funcs: array[0..7] of TLibFunc = (
    (Name: 'concat'; Func: @tconcat),
    (Name: 'create'; Func: @tcreate),
    (Name: 'insert'; Func: @tinsert),
    (Name: 'pack'; Func: @tpack),
    (Name: 'unpack'; Func: @tunpack),
    (Name: 'remove'; Func: @tremove),
    (Name: 'move'; Func: @tmove),
    (Name: 'sort'; Func: @tsort));
begin
  NewLib(L, 'table', Funcs);
end;

end.
