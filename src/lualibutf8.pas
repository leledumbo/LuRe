unit lualibutf8;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// The utf8 library.

interface

uses
  SysUtils, luacore, luavm, luaaux;

procedure OpenUtf8(L: TLua);

implementation

const
  MAXUNICODE = $10FFFF;
  MAXUTF = $7FFFFFFF;

// UTF-8 encoding of a code point (up to 6 bytes)
function Utf8Esc(x: Cardinal): RawByteString;
var
  buf: array[0..7] of Byte;
  n, i: Integer;
  mfb: Cardinal;
begin
  if x < $80 then Exit(Chr(x));
  n := 1;
  mfb := $3f;
  repeat
    buf[8 - n] := $80 or (x and $3f);
    Inc(n);
    x := x shr 6;
    mfb := mfb shr 1;
  until x <= mfb;
  buf[8 - n] := ((not mfb) shl 1) or x;
  SetLength(Result, n);
  for i := 0 to n - 1 do Result[i + 1] := Chr(buf[8 - n + i]);
end;

// decodes one sequence at position p (1-based); returns the next position or 0 on error
function Utf8Decode(const s: RawByteString; p: Integer; var val: Cardinal; strict: Boolean): Integer;
const
  Limits: array[0..5] of Cardinal = ($FFFFFFFF, $80, $800, $10000, $200000, $4000000);
var
  c, cc, res: Cardinal;
  count: Integer;
begin
  c := Byte(s[p]);
  res := 0;
  if c < $80 then
    res := c
  else if c >= $FE then
    Exit(0)
  else
  begin
    count := 0;
    while (c and $40) <> 0 do
    begin
      Inc(count);
      if p + count > Length(s) then Exit(0);
      cc := Byte(s[p + count]);
      if (cc and $C0) <> $80 then Exit(0);
      res := (res shl 6) or (cc and $3F);
      c := (c shl 1) and $FF;
      if count > 6 then Exit(0);
    end;
    res := res or (Cardinal(c and $7F) shl (count * 5));
    if (count > 5) or (res > MAXUTF) or (res < Limits[count]) then Exit(0);
    Inc(p, count);
  end;
  if strict then
    if (res > MAXUNICODE) or ((res >= $D800) and (res <= $DFFF)) then Exit(0);
  val := res;
  Result := p + 1;
end;

function IsCont(const s: RawByteString; p: Integer): Boolean; inline;
begin
  Result := (p >= 1) and (p <= Length(s)) and ((Byte(s[p]) and $C0) = $80);
end;

function PosRelat(pos: Int64; len: Integer): Int64;
begin
  if pos >= 0 then Result := pos
  else if -pos > len then Result := 0
  else Result := len + pos + 1;
end;

function utf8_len(L: TLua): Integer;
var
  s: RawByteString;
  n, posi, posj: Int64;
  lax: Boolean;
  code: Cardinal;
  nx: Integer;
begin
  s := CheckString(L, 1);
  posi := PosRelat(OptInteger(L, 2, 1), Length(s));
  posj := PosRelat(OptInteger(L, 3, -1), Length(s));
  lax := Truthy(LuaArg(L, 4));
  if not ((1 <= posi) and (posi - 1 <= Length(s))) then ArgError(L, 2, 'initial position out of bounds');
  Dec(posi);
  Dec(posj);
  if posj >= Length(s) then ArgError(L, 3, 'final position out of bounds');
  n := 0;
  while posi <= posj do
  begin
    nx := Utf8Decode(s, Integer(posi) + 1, code, not lax);
    if nx = 0 then
    begin
      PushFail(L);
      PushInt(L, posi + 1);
      Exit(2);
    end;
    posi := nx - 1;
    Inc(n);
  end;
  PushInt(L, n);
  Result := 1;
end;

function utf8_codepoint(L: TLua): Integer;
var
  s: RawByteString;
  posi, pose: Int64;
  lax: Boolean;
  n, p, nx: Integer;
  code: Cardinal;
begin
  s := CheckString(L, 1);
  posi := PosRelat(OptInteger(L, 2, 1), Length(s));
  pose := PosRelat(OptInteger(L, 3, posi), Length(s));
  lax := Truthy(LuaArg(L, 4));
  if posi < 1 then ArgError(L, 2, 'out of bounds');
  if pose > Length(s) then ArgError(L, 3, 'out of bounds');
  if posi > pose then Exit(0);
  if pose - posi >= High(Int32) then LuaError(L, 'string slice too long');
  n := Integer(pose - posi) + 1;
  L.EnsureStack(L.Top + n + 5);
  n := 0;
  p := Integer(posi);
  while p <= pose do
  begin
    nx := Utf8Decode(s, p, code, not lax);
    if nx = 0 then LuaError(L, 'invalid UTF-8 code');
    PushInt(L, code);
    Inc(n);
    p := nx;
  end;
  Result := n;
end;

function utf8_char(L: TLua): Integer;
var
  n, i: Integer;
  b: RawByteString;
  code: Int64;
begin
  n := LuaGetTop(L);
  b := '';
  for i := 1 to n do
  begin
    code := CheckInteger(L, i);
    if QWord(code) > MAXUTF then ArgError(L, i, 'value out of range');
    b := b + Utf8Esc(Cardinal(code));
  end;
  PushStr(L, b);
  Result := 1;
end;

function utf8_offset(L: TLua): Integer;
var
  s: RawByteString;
  n, posi: Int64;
  len: Integer;
begin
  s := CheckString(L, 1);
  len := Length(s);
  n := CheckInteger(L, 2);
  if n >= 0 then posi := 1 else posi := len + 1;
  posi := PosRelat(OptInteger(L, 3, posi), len);
  if not ((1 <= posi) and (posi - 1 <= len)) then ArgError(L, 3, 'position out of bounds');
  Dec(posi);   // 0-based index
  if n = 0 then
  begin
    while (posi > 0) and IsCont(s, Integer(posi) + 1) do Dec(posi);
  end
  else
  begin
    if IsCont(s, Integer(posi) + 1) then LuaError(L, 'initial position is a continuation byte');
    if n < 0 then
    begin
      while (n < 0) and (posi > 0) do
      begin
        repeat
          Dec(posi);
        until not ((posi > 0) and IsCont(s, Integer(posi) + 1));
        Inc(n);
      end;
    end
    else
    begin
      Dec(n);
      while (n > 0) and (posi < len) do
      begin
        repeat
          Inc(posi);
        until not IsCont(s, Integer(posi) + 1);
        Dec(n);
      end;
    end;
  end;
  if n <> 0 then
  begin
    PushFail(L);
    Exit(1);
  end;
  PushInt(L, posi + 1);
  if (posi < len) and ((Byte(s[posi + 1]) and $80) <> 0) then
  begin
    if IsCont(s, Integer(posi) + 1) then LuaError(L, 'initial position is a continuation byte');
    while IsCont(s, Integer(posi) + 2) do Inc(posi);
  end;
  PushInt(L, posi + 1);
  Result := 2;
end;

function IterAux(L: TLua; strict: Boolean): Integer;
var
  s: RawByteString;
  n: QWord;
  code: Cardinal;
  nx: Integer;
begin
  s := CheckString(L, 1);
  n := QWord(CheckInteger(L, 2));
  if n < QWord(Length(s)) then
    while IsCont(s, Integer(n) + 1) do Inc(n);
  if n >= QWord(Length(s)) then Exit(0);
  nx := Utf8Decode(s, Integer(n) + 1, code, strict);
  if (nx = 0) or IsCont(s, nx) then LuaError(L, 'invalid UTF-8 code');
  PushInt(L, Int64(n) + 1);
  PushInt(L, code);
  Result := 2;
end;

function iter_auxstrict(L: TLua): Integer;
begin
  Result := IterAux(L, True);
end;

function iter_auxlax(L: TLua): Integer;
begin
  Result := IterAux(L, False);
end;

function utf8_codes(L: TLua): Integer;
var
  lax: Boolean;
  s: RawByteString;
begin
  lax := Truthy(LuaArg(L, 2));
  s := CheckString(L, 1);
  if (Length(s) > 0) and IsCont(s, 1) then ArgError(L, 1, 'invalid UTF-8 code');
  if lax then
    LuaPush(L, LuaFunc(LightC(L, @iter_auxlax, 'codes_iter')))
  else
    LuaPush(L, LuaFunc(LightC(L, @iter_auxstrict, 'codes_iter')));
  LuaPush(L, LuaArg(L, 1));
  PushInt(L, 0);
  Result := 3;
end;

procedure OpenUtf8(L: TLua);
const
  Funcs: array[0..4] of TLibFunc = (
    (Name: 'offset'; Func: @utf8_offset),
    (Name: 'codepoint'; Func: @utf8_codepoint),
    (Name: 'char'; Func: @utf8_char),
    (Name: 'len'; Func: @utf8_len),
    (Name: 'codes'; Func: @utf8_codes));
var
  t: TTable;
begin
  t := NewLib(L, 'utf8', Funcs);
  SetField(L, t, 'charpattern', NewStr(L, #$5B#0'-'#$7F#$C2'-'#$FD#$5D#$5B#$80'-'#$BF#$5D'*'));
end;

end.
