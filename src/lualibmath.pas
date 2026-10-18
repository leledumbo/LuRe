unit lualibmath;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// The math library.

interface

uses
  SysUtils, Math, luacore, luavm, luaaux, luaarith;

procedure OpenMath(L: TLua);

implementation

function c_sin(x: Double): Double; cdecl; external 'm' name 'sin';
function c_frexp(x: Double; var e: Integer): Double; cdecl; external 'm' name 'frexp';
function c_ldexp(x: Double; e: Integer): Double; cdecl; external 'm' name 'ldexp';
function c_cos(x: Double): Double; cdecl; external 'm' name 'cos';
function c_tan(x: Double): Double; cdecl; external 'm' name 'tan';
function c_asin(x: Double): Double; cdecl; external 'm' name 'asin';
function c_acos(x: Double): Double; cdecl; external 'm' name 'acos';
function c_atan2(y, x: Double): Double; cdecl; external 'm' name 'atan2';
function c_exp(x: Double): Double; cdecl; external 'm' name 'exp';
function c_log(x: Double): Double; cdecl; external 'm' name 'log';
function c_log2(x: Double): Double; cdecl; external 'm' name 'log2';
function c_log10(x: Double): Double; cdecl; external 'm' name 'log10';
function c_sqrt(x: Double): Double; cdecl; external 'm' name 'sqrt';
function c_ceil(x: Double): Double; cdecl; external 'm' name 'ceil';

procedure PushNumInt(L: TLua; d: Double);
var
  n: Int64;
begin
  if FloatToInt(d, n, F2I_EQ) then PushInt(L, n) else PushNum(L, d);
end;

function math_abs(L: TLua): Integer;
var
  v: TLuaValue;
begin
  v := CheckNumberVal(L, 1);
  if v.Vt = vtInt then
  begin
    if v.I < 0 then PushInt(L, Int64(QWord(0) - QWord(v.I))) else PushInt(L, v.I);
  end
  else
    PushNum(L, Abs(v.N));
  Result := 1;
end;

function math_ceil(L: TLua): Integer;
var
  v: TLuaValue;
begin
  v := CheckNumberVal(L, 1);
  if v.Vt = vtInt then PushInt(L, v.I) else PushNumInt(L, c_ceil(v.N));
  Result := 1;
end;

function math_floor(L: TLua): Integer;
var
  v: TLuaValue;
begin
  v := CheckNumberVal(L, 1);
  if v.Vt = vtInt then PushInt(L, v.I) else PushNumInt(L, c_floor(v.N));
  Result := 1;
end;

function math_fmod(L: TLua): Integer;
var
  a, b: TLuaValue;
  d: Int64;
begin
  a := CheckNumberVal(L, 1);
  b := CheckNumberVal(L, 2);
  if (a.Vt = vtInt) and (b.Vt = vtInt) then
  begin
    d := b.I;
    if QWord(d) + 1 <= 1 then
    begin
      if d = 0 then ArgError(L, 2, 'zero');
      PushInt(L, 0);
    end
    else
      PushInt(L, a.I mod d);
  end
  else
  begin
    if a.Vt = vtInt then PushNum(L, c_fmod(a.I, CheckNumber(L, 2)))
    else PushNum(L, c_fmod(a.N, CheckNumber(L, 2)));
  end;
  Result := 1;
end;

function math_modf(L: TLua): Integer;
var
  v: TLuaValue;
  n, ip: Double;
begin
  v := CheckNumberVal(L, 1);
  if v.Vt = vtInt then
  begin
    LuaPush(L, v);
    PushNum(L, 0);
  end
  else
  begin
    n := v.N;
    if n < 0 then ip := c_ceil(n) else ip := c_floor(n);
    PushNum(L, ip);
    if IsInfinite(n) then PushNum(L, 0.0)
    else if n = ip then PushNum(L, 0.0)
    else PushNum(L, n - ip);
  end;
  Result := 2;
end;

function math_sqrt(L: TLua): Integer;
begin
  PushNum(L, c_sqrt(CheckNumber(L, 1)));
  Result := 1;
end;

function math_ult(L: TLua): Integer;
begin
  PushBool(L, QWord(CheckInteger(L, 1)) < QWord(CheckInteger(L, 2)));
  Result := 1;
end;

function math_log(L: TLua): Integer;
var
  x, base: Double;
begin
  x := CheckNumber(L, 1);
  if ArgIsNoneOrNil(L, 2) then
    PushNum(L, c_log(x))
  else
  begin
    base := CheckNumber(L, 2);
    if base = 2.0 then PushNum(L, c_log2(x))
    else if base = 10.0 then PushNum(L, c_log10(x))
    else PushNum(L, c_log(x) / c_log(base));
  end;
  Result := 1;
end;

function math_exp(L: TLua): Integer;
begin
  PushNum(L, c_exp(CheckNumber(L, 1)));
  Result := 1;
end;

function math_deg(L: TLua): Integer;
begin
  PushNum(L, CheckNumber(L, 1) * (180.0 / Pi));
  Result := 1;
end;

function math_rad(L: TLua): Integer;
begin
  PushNum(L, CheckNumber(L, 1) * (Pi / 180.0));
  Result := 1;
end;

function math_frexp(L: TLua): Integer;
var
  e: Integer;
begin
  PushNum(L, c_frexp(CheckNumber(L, 1), e));
  PushInt(L, e);
  Result := 2;
end;

function math_ldexp(L: TLua): Integer;
var
  x: Double;
begin
  x := CheckNumber(L, 1);
  PushNum(L, c_ldexp(x, Integer(CheckInteger(L, 2))));
  Result := 1;
end;

function math_sin(L: TLua): Integer;
begin
  PushNum(L, c_sin(CheckNumber(L, 1)));
  Result := 1;
end;

function math_cos(L: TLua): Integer;
begin
  PushNum(L, c_cos(CheckNumber(L, 1)));
  Result := 1;
end;

function math_tan(L: TLua): Integer;
begin
  PushNum(L, c_tan(CheckNumber(L, 1)));
  Result := 1;
end;

function math_asin(L: TLua): Integer;
begin
  PushNum(L, c_asin(CheckNumber(L, 1)));
  Result := 1;
end;

function math_acos(L: TLua): Integer;
begin
  PushNum(L, c_acos(CheckNumber(L, 1)));
  Result := 1;
end;

function math_atan(L: TLua): Integer;
begin
  PushNum(L, c_atan2(CheckNumber(L, 1), OptNumber(L, 2, 1.0)));
  Result := 1;
end;

function math_tointeger(L: TLua): Integer;
var
  v: TLuaValue;
  n: Int64;
begin
  v := LuaArg(L, 1);
  case v.Vt of
    vtInt: PushInt(L, v.I);
    vtFlt: if FloatToInt(v.N, n, F2I_EQ) then PushInt(L, n) else PushFail(L);
    vtStr: begin
      if ToInteger(v, n) then PushInt(L, n) else PushFail(L);
    end;
  else
    CheckAny(L, 1);
    PushFail(L);
  end;
  Result := 1;
end;

function math_type(L: TLua): Integer;
var
  v: TLuaValue;
begin
  v := LuaArg(L, 1);
  case v.Vt of
    vtInt: PushStr(L, 'integer');
    vtFlt: PushStr(L, 'float');
  else
    CheckAny(L, 1);
    PushFail(L);
  end;
  Result := 1;
end;

function math_max(L: TLua): Integer;
var
  n, i, imax: Integer;
  vmax, v: TLuaValue;
begin
  n := LuaGetTop(L);
  if n < 1 then ArgError(L, 1, 'value expected');
  imax := 1;
  vmax := CheckNumberVal(L, 1);
  for i := 2 to n do
  begin
    v := CheckNumberVal(L, i);
    if NumLess(vmax, v) then
    begin
      imax := i;
      vmax := v;
    end;
  end;
  LuaPush(L, LuaArg(L, imax));
  if imax < 0 then ;
  Result := 1;
end;

function math_min(L: TLua): Integer;
var
  n, i, imin: Integer;
  vmin, v: TLuaValue;
begin
  n := LuaGetTop(L);
  if n < 1 then ArgError(L, 1, 'value expected');
  imin := 1;
  vmin := CheckNumberVal(L, 1);
  for i := 2 to n do
  begin
    v := CheckNumberVal(L, i);
    if NumLess(v, vmin) then
    begin
      imin := i;
      vmin := v;
    end;
  end;
  LuaPush(L, LuaArg(L, imin));
  Result := 1;
end;

{ ------------------------------------------------------------------ }
{ xoshiro256** random generator                                       }
{ ------------------------------------------------------------------ }

var
  RState: array[0..3] of QWord;

function Rotl(x: QWord; n: Integer): QWord; inline;
begin
  Result := (x shl n) or (x shr (64 - n));
end;

function NextRand: QWord;
var
  s0, s1, s2, s3, res: QWord;
begin
  s0 := RState[0];
  s1 := RState[1];
  s2 := RState[2] xor s0;
  s3 := RState[3] xor s1;
  res := Rotl(s1 * 5, 7) * 9;
  RState[0] := s0 xor s3;
  RState[1] := s1 xor s2;
  RState[2] := s2 xor (s1 shl 17);
  RState[3] := Rotl(s3, 45);
  Result := res;
end;

function I2d(x: QWord): Double;
begin
  Result := Double(x shr 11) * (0.5 / Double(QWord(1) shl 52));
end;

function Project(ran, n: QWord): QWord;
var
  lim: QWord;
  sh: Integer;
begin
  lim := n;
  sh := 1;
  while (lim and (lim + 1)) <> 0 do
  begin
    lim := lim or (lim shr sh);
    sh := sh * 2;
  end;
  ran := ran and lim;
  while ran > n do
    ran := NextRand and lim;
  Result := ran;
end;

procedure SetSeed(L: TLua; n1, n2: QWord; push: Boolean);
var
  i: Integer;
begin
  RState[0] := n1;
  RState[1] := $FF;
  RState[2] := n2;
  RState[3] := 0;
  for i := 1 to 16 do NextRand;
  if push then
  begin
    PushInt(L, Int64(n1));
    PushInt(L, Int64(n2));
  end;
end;

function math_random(L: TLua): Integer;
var
  low, up: Int64;
  rv, p: QWord;
begin
  rv := NextRand;
  case LuaGetTop(L) of
    0: begin
      PushNum(L, I2d(rv));
      Exit(1);
    end;
    1: begin
      low := 1;
      up := CheckInteger(L, 1);
      if up = 0 then
      begin
        PushInt(L, Int64(rv));
        Exit(1);
      end;
    end;
    2: begin
      low := CheckInteger(L, 1);
      up := CheckInteger(L, 2);
    end;
  else
    LuaError(L, 'wrong number of arguments');
    low := 0;
    up := 0;
  end;
  if low > up then ArgError(L, LuaGetTop(L), 'interval is empty');
  p := Project(rv, QWord(up) - QWord(low));
  PushInt(L, Int64(p + QWord(low)));
  Result := 1;
end;

function math_randomseed(L: TLua): Integer;
var
  n1, n2: QWord;
begin
  if ArgIsNone(L, 1) then
  begin
    n1 := QWord(GetTickCount64) xor (QWord(Now * 86400000) shl 20) xor QWord(PtrUInt(L));
    n2 := NextRand;
  end
  else
  begin
    n1 := QWord(CheckInteger(L, 1));
    n2 := QWord(OptInteger(L, 2, 0));
  end;
  SetSeed(L, n1, n2, True);
  Result := 2;
end;

procedure OpenMath(L: TLua);
const
  Funcs: array[0..24] of TLibFunc = (
    (Name: 'abs'; Func: @math_abs),
    (Name: 'ceil'; Func: @math_ceil),
    (Name: 'floor'; Func: @math_floor),
    (Name: 'fmod'; Func: @math_fmod),
    (Name: 'modf'; Func: @math_modf),
    (Name: 'sqrt'; Func: @math_sqrt),
    (Name: 'ult'; Func: @math_ult),
    (Name: 'log'; Func: @math_log),
    (Name: 'exp'; Func: @math_exp),
    (Name: 'deg'; Func: @math_deg),
    (Name: 'rad'; Func: @math_rad),
    (Name: 'frexp'; Func: @math_frexp),
    (Name: 'ldexp'; Func: @math_ldexp),
    (Name: 'sin'; Func: @math_sin),
    (Name: 'cos'; Func: @math_cos),
    (Name: 'tan'; Func: @math_tan),
    (Name: 'asin'; Func: @math_asin),
    (Name: 'acos'; Func: @math_acos),
    (Name: 'atan'; Func: @math_atan),
    (Name: 'tointeger'; Func: @math_tointeger),
    (Name: 'type'; Func: @math_type),
    (Name: 'max'; Func: @math_max),
    (Name: 'min'; Func: @math_min),
    (Name: 'random'; Func: @math_random),
    (Name: 'randomseed'; Func: @math_randomseed));
var
  t: TTable;
begin
  t := NewLib(L, 'math', Funcs);
  SetField(L, t, 'pi', LuaNum(3.141592653589793238462643383279502884));
  SetField(L, t, 'huge', LuaNum(Infinity));
  SetField(L, t, 'maxinteger', LuaInt(LUA_MAXINTEGER));
  SetField(L, t, 'mininteger', LuaInt(LUA_MININTEGER));
  SetSeed(L, QWord(GetTickCount64) xor QWord(PtrUInt(L)), 0, False);
end;

end.
