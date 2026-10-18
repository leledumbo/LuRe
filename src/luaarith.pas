unit luaarith;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// Arithmetic, bitwise and comparison semantics of Lua numbers.
// Shared by the compiler (constant folding) and the virtual machine.

interface

uses
  SysUtils, Math, luacore;

type
  // result of an arithmetic operation on two numbers
  TArithResult = (arOk, arDivZero, arModZero, arNoInteger);

function c_pow(x, y: Double): Double; cdecl; external 'm' name 'pow';
function c_fmod(x, y: Double): Double; cdecl; external 'm' name 'fmod';
function c_floor(x: Double): Double; cdecl; external 'm' name 'floor';

function IntDiv(m, n: Int64): Int64;       // n <> 0
function IntMod(m, n: Int64): Int64;       // n <> 0
function FltMod(a, b: Double): Double;
function ShiftLeft(x, y: Int64): Int64;
function ShiftRight(x, y: Int64): Int64;

// operations on two numbers (integers or floats); op is an OP_* code
function ArithNum(op: Integer; constref a, b: TLuaValue; var res: TLuaValue): TArithResult;

function NumLess(constref a, b: TLuaValue): Boolean;
function NumLessEq(constref a, b: TLuaValue): Boolean;
function IsNumber(constref v: TLuaValue): Boolean; inline;

implementation

function IsNumber(constref v: TLuaValue): Boolean;
begin
  Result := (v.Vt = vtInt) or (v.Vt = vtFlt);
end;

function IntDiv(m, n: Int64): Int64;
var
  q: Int64;
begin
  if n = -1 then Exit(Int64(QWord(0) - QWord(m)));  // avoids overflow of minint / -1
  q := m div n;
  if ((m xor n) < 0) and (m mod n <> 0) then Dec(q);
  Result := q;
end;

function IntMod(m, n: Int64): Int64;
var
  r: Int64;
begin
  if n = -1 then Exit(0);
  r := m mod n;
  if (r <> 0) and ((r xor n) < 0) then r := r + n;
  Result := r;
end;

function FltMod(a, b: Double): Double;
var
  m: Double;
begin
  m := c_fmod(a, b);
  if m > 0 then
  begin
    if b < 0 then m := m + b;
  end
  else if (m < 0) and (b <> m) then
  begin
    // 'm' has a sign different from 'b' unless b is -inf
    if b > 0 then m := m + b;
  end;
  Result := m;
end;

function ShiftLeft(x, y: Int64): Int64;
begin
  if y <= -64 then Exit(0);
  if y < 0 then Exit(Int64(QWord(x) shr QWord(-y)));
  if y >= 64 then Exit(0);
  Result := Int64(QWord(x) shl QWord(y));
end;

function ShiftRight(x, y: Int64): Int64;
begin
  if y = Low(Int64) then Exit(0);
  Result := ShiftLeft(x, -y);
end;

function ArithNum(op: Integer; constref a, b: TLuaValue; var res: TLuaValue): TArithResult;
var
  ia, ib: Int64;
  fa, fb: Double;
  bothInt: Boolean;
begin
  Result := arOk;
  case op of
    OP_BAND, OP_BOR, OP_BXOR, OP_SHL, OP_SHR, OP_BNOT: begin
      if a.Vt = vtInt then ia := a.I
      else if not FloatToInt(a.N, ia, F2I_EQ) then Exit(arNoInteger);
      if b.Vt = vtInt then ib := b.I
      else if not FloatToInt(b.N, ib, F2I_EQ) then Exit(arNoInteger);
      case op of
        OP_BAND: SetIntV(@res, ia and ib);
        OP_BOR: SetIntV(@res, ia or ib);
        OP_BXOR: SetIntV(@res, ia xor ib);
        OP_SHL: SetIntV(@res, ShiftLeft(ia, ib));
        OP_SHR: SetIntV(@res, ShiftRight(ia, ib));
        OP_BNOT: SetIntV(@res, not ia);
      end;
      Exit;
    end;
  end;
  bothInt := (a.Vt = vtInt) and (b.Vt = vtInt);
  if bothInt then
  begin
    ia := a.I;
    ib := b.I;
    case op of
      OP_ADD: begin SetIntV(@res, Int64(QWord(ia) + QWord(ib))); Exit; end;
      OP_SUB: begin SetIntV(@res, Int64(QWord(ia) - QWord(ib))); Exit; end;
      OP_MUL: begin SetIntV(@res, Int64(QWord(ia) * QWord(ib))); Exit; end;
      OP_UNM: begin SetIntV(@res, Int64(QWord(0) - QWord(ia))); Exit; end;
      OP_MOD: begin
        if ib = 0 then Exit(arModZero);
        SetIntV(@res, IntMod(ia, ib));
        Exit;
      end;
      OP_IDIV: begin
        if ib = 0 then Exit(arDivZero);
        SetIntV(@res, IntDiv(ia, ib));
        Exit;
      end;
    end;
  end;
  if a.Vt = vtInt then fa := Double(a.I) else fa := a.N;
  if b.Vt = vtInt then fb := Double(b.I) else fb := b.N;
  case op of
    OP_ADD: SetFltV(@res, fa + fb);
    OP_SUB: SetFltV(@res, fa - fb);
    OP_MUL: SetFltV(@res, fa * fb);
    OP_DIV: SetFltV(@res, fa / fb);
    OP_POW: if fb = 2 then SetFltV(@res, fa * fa) else SetFltV(@res, c_pow(fa, fb));
    OP_IDIV: SetFltV(@res, c_floor(fa / fb));
    OP_MOD: SetFltV(@res, FltMod(fa, fb));
    OP_UNM: SetFltV(@res, -fa);
  end;
end;

// i < f
function IntLtFlt(i: Int64; f: Double): Boolean;
var
  fi: Int64;
begin
  if (i >= -(Int64(1) shl 53)) and (i <= (Int64(1) shl 53)) then
    Exit(Double(i) < f);
  if FloatToInt(f, fi, F2I_CEIL) then Exit(i < fi);
  Result := f > 0;   // f is out of range or NaN
end;

function IntLeFlt(i: Int64; f: Double): Boolean;
var
  fi: Int64;
begin
  if (i >= -(Int64(1) shl 53)) and (i <= (Int64(1) shl 53)) then
    Exit(Double(i) <= f);
  if FloatToInt(f, fi, F2I_FLOOR) then Exit(i <= fi);
  Result := f > 0;
end;

function FltLtInt(f: Double; i: Int64): Boolean;
var
  fi: Int64;
begin
  if (i >= -(Int64(1) shl 53)) and (i <= (Int64(1) shl 53)) then
    Exit(f < Double(i));
  if FloatToInt(f, fi, F2I_FLOOR) then Exit(fi < i);
  Result := f < 0;
end;

function FltLeInt(f: Double; i: Int64): Boolean;
var
  fi: Int64;
begin
  if (i >= -(Int64(1) shl 53)) and (i <= (Int64(1) shl 53)) then
    Exit(f <= Double(i));
  if FloatToInt(f, fi, F2I_CEIL) then Exit(fi <= i);
  Result := f < 0;
end;

function NumLess(constref a, b: TLuaValue): Boolean;
begin
  if a.Vt = vtInt then
  begin
    if b.Vt = vtInt then Result := a.I < b.I
    else Result := IntLtFlt(a.I, b.N);
  end
  else
  begin
    if b.Vt = vtFlt then Result := a.N < b.N
    else Result := FltLtInt(a.N, b.I);
  end;
end;

function NumLessEq(constref a, b: TLuaValue): Boolean;
begin
  if a.Vt = vtInt then
  begin
    if b.Vt = vtInt then Result := a.I <= b.I
    else Result := IntLeFlt(a.I, b.N);
  end
  else
  begin
    if b.Vt = vtFlt then Result := a.N <= b.N
    else Result := FltLeInt(a.N, b.I);
  end;
end;

end.
