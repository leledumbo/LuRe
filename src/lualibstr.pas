unit lualibstr;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$POINTERMATH ON}

// The string library: basic functions, pattern matching, format, pack/unpack.

interface

uses
  SysUtils, Math, luacore, luavm, luaaux, luaparse;

procedure OpenString(L: TLua);

implementation

function c_snprintf(buf: PChar; size: SizeUInt; fmt: PChar): Integer; cdecl; varargs; external 'c' name 'snprintf';
function c_tolower(c: Integer): Integer; cdecl; external 'c' name 'tolower';
function c_toupper(c: Integer): Integer; cdecl; external 'c' name 'toupper';

const
  MAXSIZE = High(Int32) div 2;      // maximum size of a string result
  MAXPACK = High(Int64);            // maximum size for pack/unpack
  L_ESC = Ord('%');
  MAXCAPTURES = 32;
  MAXCCALLS = 200;
  CAP_UNFINISHED = -1;
  CAP_POSITION = -2;

// translates a relative initial position (negative from the end)
function PosRelatI(pos: Int64; len: SizeUInt): SizeUInt;
begin
  if pos > 0 then Result := SizeUInt(pos)
  else if pos = 0 then Result := 1
  else if pos < -Int64(len) then Result := 1
  else Result := SizeUInt(Int64(len) + pos + 1);
end;

// translates a relative end position
function GetEndPos(L: TLua; arg: Integer; def: Int64; len: SizeUInt): SizeUInt;
var
  pos: Int64;
begin
  pos := OptInteger(L, arg, def);
  if pos > Int64(len) then Result := len
  else if pos >= 0 then Result := SizeUInt(pos)
  else if pos < -Int64(len) then Result := 0
  else Result := SizeUInt(Int64(len) + pos + 1);
end;

{ ===================================================================== }
{ basic functions                                                        }
{ ===================================================================== }

function str_len(L: TLua): Integer;
begin
  PushInt(L, CheckStr(L, 1).Len);
  Result := 1;
end;

function str_sub(L: TLua): Integer;
var
  s: RawByteString;
  ln, start, e: SizeUInt;
begin
  s := CheckString(L, 1);
  ln := Length(s);
  start := PosRelatI(CheckInteger(L, 2), ln);
  e := GetEndPos(L, 3, -1, ln);
  if start <= e then
    PushStr(L, Copy(s, start, e - start + 1))
  else
    PushStr(L, '');
  Result := 1;
end;

function str_reverse(L: TLua): Integer;
var
  s, r: RawByteString;
  i, n: Integer;
begin
  s := CheckString(L, 1);
  n := Length(s);
  SetLength(r, n);
  for i := 1 to n do r[i] := s[n - i + 1];
  PushStr(L, r);
  Result := 1;
end;

function str_lower(L: TLua): Integer;
var
  s: RawByteString;
  i: Integer;
begin
  s := CheckString(L, 1);
  UniqueString(s);
  for i := 1 to Length(s) do
    s[i] := Chr(c_tolower(Byte(s[i])));
  PushStr(L, s);
  Result := 1;
end;

function str_upper(L: TLua): Integer;
var
  s: RawByteString;
  i: Integer;
begin
  s := CheckString(L, 1);
  UniqueString(s);
  for i := 1 to Length(s) do
    s[i] := Chr(c_toupper(Byte(s[i])));
  PushStr(L, s);
  Result := 1;
end;

function str_rep(L: TLua): Integer;
var
  s, sep, r: RawByteString;
  n: Int64;
  ln, lsep, total: Int64;
  i, pos: Int64;
begin
  s := CheckString(L, 1);
  n := CheckInteger(L, 2);
  sep := OptString(L, 3, '');
  ln := Length(s);
  lsep := Length(sep);
  if n <= 0 then
  begin
    PushStr(L, '');
    Exit(1);
  end;
  if (ln + lsep < ln) or (ln + lsep > MAXSIZE div n) then
    LuaError(L, 'resulting string too large');
  total := n * ln + (n - 1) * lsep;
  SetLength(r, total);
  pos := 1;
  for i := 1 to n do
  begin
    if ln > 0 then Move(s[1], r[pos], ln);
    Inc(pos, ln);
    if (i < n) and (lsep > 0) then
    begin
      Move(sep[1], r[pos], lsep);
      Inc(pos, lsep);
    end;
  end;
  PushStr(L, r);
  Result := 1;
end;

function str_byte(L: TLua): Integer;
var
  s: RawByteString;
  ln, posi, pose: SizeUInt;
  pi: Int64;
  n, i: Integer;
begin
  s := CheckString(L, 1);
  ln := Length(s);
  pi := OptInteger(L, 2, 1);
  pose := GetEndPos(L, 3, pi, ln);
  posi := PosRelatI(pi, ln);
  if posi > pose then Exit(0);
  if pose - posi >= MAXSIZE then
    LuaError(L, 'string slice too long');
  n := Integer(pose - posi) + 1;
  L.EnsureStack(L.Top + n + 5);
  for i := 0 to n - 1 do
    PushInt(L, Byte(s[posi + SizeUInt(i)]));
  Result := n;
end;

function str_char(L: TLua): Integer;
var
  n, i: Integer;
  r: RawByteString;
  c: Int64;
begin
  n := LuaGetTop(L);
  SetLength(r, n);
  for i := 1 to n do
  begin
    c := CheckInteger(L, i);
    if QWord(c) > 255 then ArgError(L, i, 'value out of range');
    r[i] := Chr(c);
  end;
  PushStr(L, r);
  Result := 1;
end;

function str_dump(L: TLua): Integer;
var
  f: TFunction;
  strip: Boolean;
begin
  if LuaArg(L, 1).Vt <> vtFunc then TypeErrorArg(L, 1, 'function');
  f := LuaArg(L, 1).F;
  strip := Truthy(LuaArg(L, 2));
  if f.IsC then LuaError(L, 'unable to dump given function');
  PushStr(L, LuaDump(L, f, strip));
  Result := 1;
end;

{ ===================================================================== }
{ pattern matching                                                       }
{ ===================================================================== }

type
  TCapture = record
    Init: PByte;
    Len: Integer;
  end;

  TMatchState = record
    L: TLua;
    SrcInit: PByte;
    SrcEnd: PByte;
    PatEnd: PByte;
    MatchDepth: Integer;
    Level: Integer;
    Capture: array[0..MAXCAPTURES - 1] of TCapture;
  end;
  PMatchState = ^TMatchState;

// character classes follow the C locale functions (they depend on LC_CTYPE)
function c_isalpha(c: Integer): Integer; cdecl; external 'c' name 'isalpha';
function c_isdigit(c: Integer): Integer; cdecl; external 'c' name 'isdigit';
function c_islower(c: Integer): Integer; cdecl; external 'c' name 'islower';
function c_isupper(c: Integer): Integer; cdecl; external 'c' name 'isupper';
function c_isspace(c: Integer): Integer; cdecl; external 'c' name 'isspace';
function c_iscntrl(c: Integer): Integer; cdecl; external 'c' name 'iscntrl';
function c_isgraph(c: Integer): Integer; cdecl; external 'c' name 'isgraph';
function c_ispunct(c: Integer): Integer; cdecl; external 'c' name 'ispunct';
function c_isxdigit(c: Integer): Integer; cdecl; external 'c' name 'isxdigit';
function c_isalnum(c: Integer): Integer; cdecl; external 'c' name 'isalnum';

function IsAlpha(c: Byte): Boolean; inline;
begin
  Result := c_isalpha(c) <> 0;
end;

function IsDigit(c: Byte): Boolean; inline;
begin
  Result := (c >= 48) and (c <= 57);
end;

function IsLower(c: Byte): Boolean; inline;
begin
  Result := c_islower(c) <> 0;
end;

function IsUpper(c: Byte): Boolean; inline;
begin
  Result := c_isupper(c) <> 0;
end;

function IsSpace(c: Byte): Boolean; inline;
begin
  Result := c_isspace(c) <> 0;
end;

function IsCntrl(c: Byte): Boolean; inline;
begin
  Result := c_iscntrl(c) <> 0;
end;

function IsGraph(c: Byte): Boolean; inline;
begin
  Result := c_isgraph(c) <> 0;
end;

function IsPunct(c: Byte): Boolean; inline;
begin
  Result := c_ispunct(c) <> 0;
end;

function IsXDigit(c: Byte): Boolean; inline;
begin
  Result := c_isxdigit(c) <> 0;
end;

function IsAlnum(c: Byte): Boolean; inline;
begin
  Result := c_isalnum(c) <> 0;
end;

function ToLowerB(c: Byte): Byte; inline;
begin
  Result := Byte(c_tolower(c));
end;

function MatchClass(c, cl: Byte): Boolean;
var
  res: Boolean;
begin
  case ToLowerB(cl) of
    Ord('a'): res := IsAlpha(c);
    Ord('c'): res := IsCntrl(c);
    Ord('d'): res := IsDigit(c);
    Ord('g'): res := IsGraph(c);
    Ord('l'): res := IsLower(c);
    Ord('p'): res := IsPunct(c);
    Ord('s'): res := IsSpace(c);
    Ord('u'): res := IsUpper(c);
    Ord('w'): res := IsAlnum(c);
    Ord('x'): res := IsXDigit(c);
    Ord('z'): res := c = 0;   // deprecated
  else
    Exit(cl = c);
  end;
  if IsUpper(cl) then res := not res;
  Result := res;
end;

function Match(ms: PMatchState; s, p: PByte): PByte; forward;

function ClassEnd(ms: PMatchState; p: PByte): PByte;
var
  c: Byte;
begin
  c := p^;
  Inc(p);
  if c = L_ESC then
  begin
    if p = ms^.PatEnd then
      LuaError(ms^.L, 'malformed pattern (ends with ''%'')');
    Exit(p + 1);
  end;
  if c = Ord('[') then
  begin
    if (p < ms^.PatEnd) and (p^ = Ord('^')) then Inc(p);
    repeat
      if p = ms^.PatEnd then
        LuaError(ms^.L, 'malformed pattern (missing '']'')');
      c := p^;
      Inc(p);
      if (c = L_ESC) and (p < ms^.PatEnd) then Inc(p);
    until (p < ms^.PatEnd) and (p^ = Ord(']'));
    Exit(p + 1);
  end;
  Result := p;
end;

function MatchBracketClass(c: Byte; p, ec: PByte): Boolean;
var
  sig: Boolean;
begin
  sig := True;
  if p[1] = Ord('^') then
  begin
    sig := False;
    Inc(p);
  end;
  Inc(p);
  while p < ec do
  begin
    if p^ = L_ESC then
    begin
      Inc(p);
      if MatchClass(c, p^) then Exit(sig);
    end
    else if (p[1] = Ord('-')) and (p + 2 < ec) then
    begin
      Inc(p, 2);
      if (p[-2] <= c) and (c <= p^) then Exit(sig);
    end
    else if p^ = c then Exit(sig);
    Inc(p);
  end;
  Result := not sig;
end;

function SingleMatch(ms: PMatchState; s, p, ep: PByte): Boolean;
var
  c: Byte;
begin
  if s >= ms^.SrcEnd then Exit(False);
  c := s^;
  case p^ of
    Ord('.'): Result := True;
    L_ESC: Result := MatchClass(c, p[1]);
    Ord('['): Result := MatchBracketClass(c, p, ep - 1);
  else
    Result := p^ = c;
  end;
end;

function MatchBalance(ms: PMatchState; s, p: PByte): PByte;
var
  b, e: Byte;
  cont: Integer;
begin
  if p >= ms^.PatEnd - 1 then
    LuaError(ms^.L, 'malformed pattern (missing arguments to ''%b'')');
  if (s >= ms^.SrcEnd) or (s^ <> p^) then Exit(nil);
  b := p[0];
  e := p[1];
  cont := 1;
  Inc(s);
  while s < ms^.SrcEnd do
  begin
    if s^ = e then
    begin
      Dec(cont);
      if cont = 0 then Exit(s + 1);
    end
    else if s^ = b then Inc(cont);
    Inc(s);
  end;
  Result := nil;
end;

function MaxExpand(ms: PMatchState; s, p, ep: PByte): PByte;
var
  i: PtrInt;
  res: PByte;
begin
  i := 0;
  while SingleMatch(ms, s + i, p, ep) do Inc(i);
  while i >= 0 do
  begin
    res := Match(ms, s + i, ep + 1);
    if res <> nil then Exit(res);
    Dec(i);
  end;
  Result := nil;
end;

function MinExpand(ms: PMatchState; s, p, ep: PByte): PByte;
var
  res: PByte;
begin
  while True do
  begin
    res := Match(ms, s, ep + 1);
    if res <> nil then Exit(res);
    if SingleMatch(ms, s, p, ep) then Inc(s) else Exit(nil);
  end;
end;

function StartCapture(ms: PMatchState; s, p: PByte; what: Integer): PByte;
var
  level: Integer;
begin
  level := ms^.Level;
  if level >= MAXCAPTURES then LuaError(ms^.L, 'too many captures');
  ms^.Capture[level].Init := s;
  ms^.Capture[level].Len := what;
  ms^.Level := level + 1;
  Result := Match(ms, s, p);
  if Result = nil then Dec(ms^.Level);
end;

function CaptureToClose(ms: PMatchState): Integer;
var
  level: Integer;
begin
  level := ms^.Level;
  Dec(level);
  while level >= 0 do
  begin
    if ms^.Capture[level].Len = CAP_UNFINISHED then Exit(level);
    Dec(level);
  end;
  LuaError(ms^.L, 'invalid pattern capture');
  Result := 0;
end;

function EndCapture(ms: PMatchState; s, p: PByte): PByte;
var
  l: Integer;
begin
  l := CaptureToClose(ms);
  ms^.Capture[l].Len := s - ms^.Capture[l].Init;
  Result := Match(ms, s, p);
  if Result = nil then ms^.Capture[l].Len := CAP_UNFINISHED;
end;

function CheckCapture(ms: PMatchState; l: Integer): Integer;
begin
  Dec(l, Ord('1'));
  if (l < 0) or (l >= ms^.Level) or (ms^.Capture[l].Len = CAP_UNFINISHED) then
    LuaError(ms^.L, Format('invalid capture index %%%d', [l + 1]));
  Result := l;
end;

function MatchCapture(ms: PMatchState; s: PByte; l: Integer): PByte;
var
  len: PtrInt;
begin
  l := CheckCapture(ms, l);
  len := ms^.Capture[l].Len;
  if (ms^.SrcEnd - s >= len) and (CompareByte(ms^.Capture[l].Init^, s^, len) = 0) then
    Result := s + len
  else
    Result := nil;
end;

function Match(ms: PMatchState; s, p: PByte): PByte;
var
  ep: PByte;
  epc: Byte;
  prev: Byte;
  res: PByte;
  dflt: Boolean;
begin
  Dec(ms^.MatchDepth);
  if ms^.MatchDepth = 0 then LuaError(ms^.L, 'pattern too complex');
  while True do
  begin
    if p = ms^.PatEnd then Break;
    dflt := False;
    case p^ of
      Ord('('): begin
        if p[1] = Ord(')') then
          s := StartCapture(ms, s, p + 2, CAP_POSITION)
        else
          s := StartCapture(ms, s, p + 1, CAP_UNFINISHED);
        Break;
      end;
      Ord(')'): begin
        s := EndCapture(ms, s, p + 1);
        Break;
      end;
      Ord('$'):
        if p + 1 = ms^.PatEnd then
        begin
          if s <> ms^.SrcEnd then s := nil;
          Break;
        end
        else
          dflt := True;
      L_ESC:
        case p[1] of
          Ord('b'): begin
            s := MatchBalance(ms, s, p + 2);
            if s <> nil then
            begin
              Inc(p, 4);
              Continue;
            end;
            Break;
          end;
          Ord('f'): begin
            Inc(p, 2);
            if (p >= ms^.PatEnd) or (p^ <> Ord('[')) then
              LuaError(ms^.L, 'missing ''['' after ''%f'' in pattern');
            ep := ClassEnd(ms, p);
            if s = ms^.SrcInit then prev := 0 else prev := (s - 1)^;
            if (not MatchBracketClass(prev, p, ep - 1)) and
               MatchBracketClass(s^, p, ep - 1) then
            begin
              p := ep;
              Continue;
            end;
            s := nil;
            Break;
          end;
          Ord('0')..Ord('9'): begin
            s := MatchCapture(ms, s, p[1]);
            if s <> nil then
            begin
              Inc(p, 2);
              Continue;
            end;
            Break;
          end;
        else
          dflt := True;
        end;
    else
      dflt := True;
    end;
    if dflt then
    begin
      ep := ClassEnd(ms, p);
      if ep < ms^.PatEnd then epc := ep^ else epc := 0;
      if not SingleMatch(ms, s, p, ep) then
      begin
        if (epc = Ord('*')) or (epc = Ord('?')) or (epc = Ord('-')) then
        begin
          p := ep + 1;
          Continue;
        end;
        s := nil;
        Break;
      end
      else
      begin
        case epc of
          Ord('?'): begin
            res := Match(ms, s + 1, ep + 1);
            if res <> nil then
            begin
              s := res;
              Break;
            end;
            p := ep + 1;
            Continue;
          end;
          Ord('+'): begin
            s := MaxExpand(ms, s + 1, p, ep);
            Break;
          end;
          Ord('*'): begin
            s := MaxExpand(ms, s, p, ep);
            Break;
          end;
          Ord('-'): begin
            s := MinExpand(ms, s, p, ep);
            Break;
          end;
        else
          Inc(s);
          p := ep;
          Continue;
        end;
      end;
    end;
  end;
  Inc(ms^.MatchDepth);
  Result := s;
end;


var
  EmptyByte: Byte = 0;

// pointer to the bytes of a string (valid even for the empty string)
function StrPtr(const s: RawByteString): PByte;
begin
  if s = '' then Result := @EmptyByte else Result := PByte(Pointer(s));
end;

function StrFromMem(p: PByte; n: PtrInt): RawByteString;
begin
  SetLength(Result, n);
  if n > 0 then Move(p^, Result[1], n);
end;

procedure PrepState(var ms: TMatchState; L: TLua; s, p: PByte; ls, lp: SizeUInt);
begin
  ms.L := L;
  ms.MatchDepth := MAXCCALLS;
  ms.SrcInit := s;
  ms.SrcEnd := s + ls;
  ms.PatEnd := p + lp;
  ms.Level := 0;
end;

procedure RePrepState(var ms: TMatchState);
begin
  ms.Level := 0;
  ms.MatchDepth := MAXCCALLS;
end;

// pushes capture i (or the whole match when there are no captures)
procedure PushOneCapture(var ms: TMatchState; i: Integer; s, e: PByte);
var
  l: Integer;
begin
  if i >= ms.Level then
  begin
    if i <> 0 then
      LuaError(ms.L, Format('invalid capture index %%%d', [i + 1]));
    PushStr(ms.L, StrFromMem(s, e - s));
  end
  else
  begin
    l := ms.Capture[i].Len;
    if l = CAP_UNFINISHED then
      LuaError(ms.L, 'unfinished capture')
    else if l = CAP_POSITION then
      PushInt(ms.L, (ms.Capture[i].Init - ms.SrcInit) + 1)
    else
      PushStr(ms.L, StrFromMem(ms.Capture[i].Init, l));
  end;
end;

function PushCaptures(var ms: TMatchState; s, e: PByte): Integer;
var
  nlevels, i: Integer;
begin
  if (ms.Level = 0) and (s <> nil) then nlevels := 1 else nlevels := ms.Level;
  ms.L.EnsureStack(ms.L.Top + nlevels + 5);
  for i := 0 to nlevels - 1 do
    PushOneCapture(ms, i, s, e);
  Result := nlevels;
end;

function NoSpecials(p: PByte; l: SizeUInt): Boolean;
var
  i: SizeUInt;
begin
  for i := 0 to l - 1 do
    if p[i] in [Ord('^'), Ord('$'), Ord('*'), Ord('+'), Ord('?'), Ord('.'), Ord('('),
                Ord(')'), Ord('['), Ord(']'), Ord('%'), Ord('-')] then
      Exit(False);
  Result := True;
end;

function MemFind(s1: PByte; l1: SizeUInt; s2: PByte; l2: SizeUInt): PByte;
var
  p: PByte;
  last: PByte;
begin
  if l2 = 0 then Exit(s1);
  if l2 > l1 then Exit(nil);
  last := s1 + (l1 - l2);
  p := s1;
  while p <= last do
  begin
    if (p^ = s2^) and (CompareByte(p[1], s2[1], l2 - 1) = 0) then Exit(p);
    Inc(p);
  end;
  Result := nil;
end;

function StrFindAux(L: TLua; find: Boolean): Integer;
var
  sstr, pstr: TStringObj;
  ls, lp, init: SizeUInt;
  s, p, s1, res: PByte;
  ms: TMatchState;
  anchor: Boolean;
begin
  sstr := CheckStr(L, 1);
  pstr := CheckStr(L, 2);
  ls := sstr.Len;
  lp := pstr.Len;
  init := PosRelatI(OptInteger(L, 3, 1), ls) - 1;
  if init > ls then
  begin
    PushFail(L);
    Exit(1);
  end;
  s := StrPtr(sstr.Str);
  p := StrPtr(pstr.Str);
  if find and (Truthy(LuaArg(L, 4)) or NoSpecials(p, lp)) then
  begin
    res := MemFind(s + init, ls - init, p, lp);
    if res <> nil then
    begin
      PushInt(L, (res - s) + 1);
      PushInt(L, (res - s) + lp);
      Exit(2);
    end;
  end
  else
  begin
    s1 := s + init;
    anchor := (lp > 0) and (p^ = Ord('^'));
    if anchor then
    begin
      Inc(p);
      Dec(lp);
    end;
    PrepState(ms, L, s, p, ls, lp);
    repeat
      RePrepState(ms);
      res := Match(@ms, s1, p);
      if res <> nil then
      begin
        if find then
        begin
          PushInt(L, (s1 - s) + 1);
          PushInt(L, res - s);
          Exit(PushCaptures(ms, nil, nil) + 2);
        end
        else
          Exit(PushCaptures(ms, s1, res));
      end;
      Inc(s1);
    until (s1 > ms.SrcEnd) or anchor;
  end;
  PushFail(L);
  Result := 1;
end;

function str_find(L: TLua): Integer;
begin
  Result := StrFindAux(L, True);
end;

function str_match(L: TLua): Integer;
begin
  Result := StrFindAux(L, False);
end;

// gmatch: upvalues: 0 = subject, 1 = pattern, 2 = current position, 3 = last match end
function gmatch_aux(L: TLua): Integer;
var
  f: TFunction;
  sstr, pstr: TStringObj;
  ms: TMatchState;
  src, e, lastmatch, s0, p0: PByte;
  pos, lastpos: Int64;
begin
  f := L.CI[L.NCI - 1].Func;
  sstr := f.CVals[0].S;
  pstr := f.CVals[1].S;
  pos := f.CVals[2].I;
  lastpos := f.CVals[3].I;
  s0 := StrPtr(sstr.Str);
  p0 := StrPtr(pstr.Str);
  PrepState(ms, L, s0, p0, sstr.Len, pstr.Len);
  if lastpos >= 0 then lastmatch := s0 + lastpos else lastmatch := nil;
  src := s0 + pos;
  while src <= ms.SrcEnd do
  begin
    RePrepState(ms);
    e := Match(@ms, src, p0);
    if (e <> nil) and (e <> lastmatch) then
    begin
      f.CVals[2] := LuaInt(e - s0);
      f.CVals[3] := LuaInt(e - s0);
      Exit(PushCaptures(ms, src, e));
    end;
    Inc(src);
  end;
  Result := 0;
end;

function str_gmatch(L: TLua): Integer;
var
  s, p: TStringObj;
  init: SizeUInt;
  f: TFunction;
begin
  s := CheckStr(L, 1);
  p := CheckStr(L, 2);
  init := PosRelatI(OptInteger(L, 3, 1), s.Len) - 1;
  if init > s.Len then init := s.Len + 1;
  f := L.NewCFunction(@gmatch_aux, 4);
  f.CVals[0] := LuaStr(s);
  f.CVals[1] := LuaStr(p);
  f.CVals[2] := LuaInt(init);
  f.CVals[3] := LuaInt(-1);
  LuaPush(L, LuaFunc(f));
  Result := 1;
end;

// appends the replacement for a match
function AddValue(var ms: TMatchState; var b: RawByteString; s, e: PByte; tr: TValueType): Boolean;
var
  L: TLua;
  r: TLuaValue;
  news: RawByteString;
  i, n, base: Integer;
  c: Byte;
  cap: PByte;
  capl: Integer;
  idx: Integer;
begin
  L := ms.L;
  case tr of
    vtFunc: begin
      LuaPush(L, LuaArg(L, 3));
      n := PushCaptures(ms, s, e);
      LuaCall(L, n, 1);
      r := L.Stack[L.Top - 1];
      Dec(L.Top);
    end;
    vtTab: begin
      PushOneCapture(ms, 0, s, e);
      r := LuaIndex(L, LuaArg(L, 3), L.Stack[L.Top - 1]);
      Dec(L.Top);
    end;
  else
    begin
      // string replacement
      news := LuaArg(L, 3).S.Str;
      base := 1;
      i := 1;
      while i <= Length(news) do
      begin
        if news[i] <> '%' then
        begin
          b := b + news[i];
          Inc(i);
          Continue;
        end;
        Inc(i);
        if i > Length(news) then
          LuaError(L, 'invalid use of ''%'' in replacement string');
        c := Byte(news[i]);
        if c = L_ESC then
          b := b + '%'
        else if c = Ord('0') then
          b := b + StrFromMem(s, e - s)
        else if IsDigit(c) then
        begin
          idx := c - Ord('1');
          if idx >= ms.Level then
          begin
            if idx <> 0 then
              LuaError(L, Format('invalid capture index %%%d in replacement string', [idx + 1]));
            b := b + StrFromMem(s, e - s);
          end
          else
          begin
            capl := ms.Capture[idx].Len;
            cap := ms.Capture[idx].Init;
            if capl = CAP_UNFINISHED then
              LuaError(L, 'unfinished capture')
            else if capl = CAP_POSITION then
              b := b + RawByteString(IntToStr((cap - ms.SrcInit) + 1))
            else
              b := b + StrFromMem(cap, capl);
          end;
        end
        else
          LuaError(L, 'invalid use of ''%'' in replacement string');
        Inc(i);
      end;
      if base < 0 then ;
      Exit(True);
    end;
  end;
  if not Truthy(r) then
  begin
    b := b + StrFromMem(s, e - s);   // keep original text
    Exit(False);
  end;
  if r.Vt = vtStr then
    b := b + r.S.Str
  else if r.Vt in [vtInt, vtFlt] then
    b := b + RawByteString(NumToStr(r))
  else
    LuaError(L, Format('invalid replacement value (a %s)', [VTypeName(r)]));
  Result := True;
end;

function str_gsub(L: TLua): Integer;
var
  sstr, pstr: TStringObj;
  src, p, lastmatch, e: PByte;
  tr: TValueType;
  maxS, n: Int64;
  anchor, changed: Boolean;
  ms: TMatchState;
  b: RawByteString;
  lp: SizeUInt;
  v: TLuaValue;
begin
  sstr := CheckStr(L, 1);
  pstr := CheckStr(L, 2);
  v := LuaArg(L, 3);
  tr := v.Vt;
  if tr = vtInt then tr := vtStr;
  if tr = vtFlt then tr := vtStr;
  if not (tr in [vtStr, vtFunc, vtTab]) or ArgIsNone(L, 3) then
    TypeErrorArg(L, 3, 'string/function/table');
  if v.Vt in [vtInt, vtFlt] then
    L.Stack[LuaAbsIndex(L, 3)] := LuaStr(L.NewString(RawByteString(NumToStr(v))));
  maxS := OptInteger(L, 4, Int64(sstr.Len) + 1);
  src := StrPtr(sstr.Str);
  p := StrPtr(pstr.Str);
  lp := pstr.Len;
  anchor := (lp > 0) and (p^ = Ord('^'));
  if anchor then
  begin
    Inc(p);
    Dec(lp);
  end;
  PrepState(ms, L, StrPtr(sstr.Str), p, sstr.Len, lp);
  lastmatch := nil;
  n := 0;
  changed := False;
  b := '';
  while n < maxS do
  begin
    RePrepState(ms);
    e := Match(@ms, src, p);
    if (e <> nil) and (e <> lastmatch) then
    begin
      Inc(n);
      if AddValue(ms, b, src, e, tr) then changed := True;
      src := e;
      lastmatch := e;
    end
    else if src < ms.SrcEnd then
    begin
      b := b + Chr(src^);
      Inc(src);
    end
    else
      Break;
    if anchor then Break;
  end;
  if not changed then
    LuaPush(L, LuaArg(L, 1))
  else
  begin
    b := b + StrFromMem(src, ms.SrcEnd - src);
    PushStr(L, b);
  end;
  PushInt(L, n);
  Result := 2;
end;

{ ===================================================================== }
{ format                                                                 }
{ ===================================================================== }

procedure AddQuoted(var b: RawByteString; const s: RawByteString);
var
  i: Integer;
  c: Byte;
begin
  b := b + '"';
  for i := 1 to Length(s) do
  begin
    c := Byte(s[i]);
    if (c = Ord('"')) or (c = Ord('\')) or (c = 10) then
      b := b + '\' + Chr(c)
    else if IsCntrl(c) then
    begin
      if (i < Length(s)) and IsDigit(Byte(s[i + 1])) then
        b := b + RawByteString(Format('\%.3d', [c]))
      else
        b := b + RawByteString(Format('\%d', [c]));
    end
    else
      b := b + Chr(c);
  end;
  b := b + '"';
end;

function HexFloat(x: Double; upper: Boolean): string;
begin
  if upper then Result := CFormatDouble('%A', x) else Result := CFormatDouble('%a', x);
end;

function QuoteFloat(n: Double): RawByteString;
var
  dp: Char;
  i: Integer;
begin
  if IsInfinite(n) then
  begin
    if n > 0 then Result := '1e9999' else Result := '-1e9999';
  end
  else if IsNaN(n) then
    Result := '(0/0)'
  else
  begin
    Result := RawByteString(HexFloat(n, False));
    dp := LocaleDecPoint;
    for i := 1 to Length(Result) do
      if Result[i] = dp then Result[i] := '.';
  end;
end;

procedure AddLiteral(L: TLua; var b: RawByteString; arg: Integer);
var
  v: TLuaValue;
begin
  v := LuaArg(L, arg);
  case v.Vt of
    vtStr: AddQuoted(b, v.S.Str);
    vtInt: begin
      if v.I = LUA_MININTEGER then
        b := b + '0x8000000000000000'
      else
        b := b + RawByteString(IntToStr(v.I));
    end;
    vtFlt: b := b + QuoteFloat(v.N);
    vtNil, vtBool: b := b + ToStringAux(L, v);
  else
    ArgError(L, arg, 'value has no literal form');
  end;
end;

// copies the conversion specification "%..." starting at position i
// (after the '%'); returns the spec and the index of the conversion char
function GetFormat(L: TLua; const fmt: RawByteString; var i: Integer): string;
var
  start, len: Integer;
begin
  start := i;
  while (i <= Length(fmt)) and (fmt[i] in ['-', '+', '#', '0', ' ', '1'..'9', '.']) do Inc(i);
  len := i - start + 1;      // plus the conversion character
  if len >= 22 then LuaError(L, 'invalid format (too long)');
  Result := '%' + string(Copy(fmt, start, len));
end;

procedure CheckFormat(L: TLua; const form: string; const flags: string; precision: Boolean);
var
  i: Integer;
begin
  i := 2;
  while (i <= Length(form)) and (Pos(form[i], flags) > 0) do Inc(i);
  if (i <= Length(form)) and (form[i] <> '0') then
  begin
    if (i <= Length(form)) and (form[i] in ['0'..'9']) then
    begin
      Inc(i);
      if (i <= Length(form)) and (form[i] in ['0'..'9']) then Inc(i);
    end;
    if (i <= Length(form)) and (form[i] = '.') and precision then
    begin
      Inc(i);
      if (i <= Length(form)) and (form[i] in ['0'..'9']) then
      begin
        Inc(i);
        if (i <= Length(form)) and (form[i] in ['0'..'9']) then Inc(i);
      end;
    end;
  end;
  if (i > Length(form)) or not (form[i] in ['a'..'z', 'A'..'Z']) or (i <> Length(form)) then
    LuaError(L, Format('invalid conversion specification: ''%s''', [form]));
end;

function FormatWith(const form: string; n: Int64): RawByteString; overload;
var
  buf: array[0..511] of Char;
  len: Integer;
begin
  len := c_snprintf(@buf[0], SizeOf(buf), PChar(form), n);
  SetString(Result, PChar(@buf[0]), len);
end;

function FormatWithStr(const form: string; const s: RawByteString): RawByteString;
var
  buf: array[0..511] of Char;
  len: Integer;
begin
  len := c_snprintf(@buf[0], SizeOf(buf), PChar(form), PChar(Pointer(s)));
  SetString(Result, PChar(@buf[0]), len);
end;

function FormatWithDouble(const form: string; d: Double): RawByteString;
var
  buf: array[0..1023] of Char;
  len: Integer;
begin
  len := c_snprintf(@buf[0], SizeOf(buf), PChar(form), d);
  if len >= SizeOf(buf) then len := SizeOf(buf) - 1;
  SetString(Result, PChar(@buf[0]), len);
end;

function str_format(L: TLua): Integer;
var
  top, arg, i: Integer;
  fmt, b, tmp: RawByteString;
  form, flags: string;
  conv: Char;
  n: Int64;
  d: Double;
  v: TLuaValue;
  sv: RawByteString;
begin
  top := LuaGetTop(L);
  arg := 1;
  fmt := CheckString(L, 1);
  b := '';
  i := 1;
  while i <= Length(fmt) do
  begin
    if fmt[i] <> '%' then
    begin
      b := b + fmt[i];
      Inc(i);
      Continue;
    end;
    Inc(i);
    if (i <= Length(fmt)) and (fmt[i] = '%') then
    begin
      b := b + '%';
      Inc(i);
      Continue;
    end;
    // a format item
    Inc(arg);
    if arg > top then ArgError(L, arg, 'no value');
    form := GetFormat(L, fmt, i);
    if i > Length(fmt) then
      LuaError(L, Format('invalid conversion ''%s'' to ''format''', [form]));
    conv := Char(fmt[i]);
    Inc(i);
    case conv of
      'c': begin
        CheckFormat(L, form, '-', False);
        n := CheckInteger(L, arg);
        b := b + FormatWith(form, n);
      end;
      'd', 'i', 'u', 'o', 'x', 'X': begin
        case conv of
          'd', 'i': flags := '-+0 ';
          'u': flags := '-0';
        else
          flags := '-#0';
        end;
        n := CheckInteger(L, arg);
        CheckFormat(L, form, flags, True);
        form := Copy(form, 1, Length(form) - 1) + 'll' + conv;
        b := b + FormatWith(form, n);
      end;
      'a', 'A': begin
        CheckFormat(L, form, '-+#0 ', True);
        d := CheckNumber(L, arg);
        b := b + FormatWithDouble(form, d);
      end;
      'e', 'E', 'f', 'g', 'G': begin
        d := CheckNumber(L, arg);
        CheckFormat(L, form, '-+#0 ', True);
        b := b + FormatWithDouble(form, d);
      end;
      'p': begin
        v := LuaArg(L, arg);
        CheckFormat(L, form, '-', False);
        if v.Vt in [vtTab, vtFunc, vtUser, vtThread, vtLight, vtStr] then
        begin
          form := Copy(form, 1, Length(form) - 1) + 's';
          b := b + FormatWithStr(form, RawByteString(PointerString(v)));
        end
        else
        begin
          form := Copy(form, 1, Length(form) - 1) + 's';
          b := b + FormatWithStr(form, '(null)');
        end;
      end;
      'q': begin
        if Length(form) > 2 then
          LuaError(L, 'specifier ''%q'' cannot have modifiers');
        AddLiteral(L, b, arg);
      end;
      's': begin
        sv := ToStringAux(L, LuaArg(L, arg));
        if Length(form) = 2 then
          b := b + sv
        else
        begin
          if Pos(#0, sv) > 0 then ArgError(L, arg, 'string contains zeros');
          CheckFormat(L, form, '-', True);
          if (Pos('.', form) = 0) and (Length(sv) >= 100) then
            b := b + sv
          else
            b := b + FormatWithStr(form, sv);
        end;
      end;
    else
      LuaError(L, Format('invalid conversion ''%s'' to ''format''', [form]));
    end;
  end;
  PushStr(L, b);
  Result := 1;
end;

{ ===================================================================== }
{ pack / unpack                                                          }
{ ===================================================================== }

type
  TKOption = (kInt, kUint, kFloat, kNumber, kDouble, kChar, kString, kZstr,
              kPadding, kPaddAlign, kNop);

  THeader = record
    L: TLua;
    IsLittle: Boolean;
    MaxAlign: Integer;
  end;

const
  MAXINTSIZE = 16;
  SZINT = 8;

function PackDigit(c: Char): Boolean; inline;
begin
  Result := c in ['0'..'9'];
end;

function GetNum(const fmt: RawByteString; var i: Integer; df: Int64): Int64;
var
  a: Int64;
begin
  if (i > Length(fmt)) or not PackDigit(fmt[i]) then Exit(df);
  a := 0;
  repeat
    a := a * 10 + (Ord(fmt[i]) - Ord('0'));
    Inc(i);
  until (i > Length(fmt)) or not PackDigit(fmt[i]) or (a > (MAXPACK - 9) div 10);
  Result := a;
end;

function GetNumLimit(var h: THeader; const fmt: RawByteString; var i: Integer; df: Int64): Integer;
var
  sz: Int64;
begin
  sz := GetNum(fmt, i, df);
  if (sz > MAXINTSIZE) or (sz <= 0) then
    LuaError(h.L, Format('integral size (%d) out of limits [1,%d]', [sz, MAXINTSIZE]));
  Result := Integer(sz);
end;

function GetOption(var h: THeader; const fmt: RawByteString; var i: Integer; var size: Int64): TKOption;
var
  opt: Char;
begin
  opt := fmt[i];
  Inc(i);
  size := 0;
  Result := kNop;
  case opt of
    'b': begin size := 1; Result := kInt; end;
    'B': begin size := 1; Result := kUint; end;
    'h': begin size := 2; Result := kInt; end;
    'H': begin size := 2; Result := kUint; end;
    'l': begin size := 8; Result := kInt; end;
    'L': begin size := 8; Result := kUint; end;
    'j': begin size := 8; Result := kInt; end;
    'J': begin size := 8; Result := kUint; end;
    'T': begin size := 8; Result := kUint; end;
    'f': begin size := 4; Result := kFloat; end;
    'n': begin size := 8; Result := kNumber; end;
    'd': begin size := 8; Result := kDouble; end;
    'i': begin size := GetNumLimit(h, fmt, i, 4); Result := kInt; end;
    'I': begin size := GetNumLimit(h, fmt, i, 4); Result := kUint; end;
    's': begin size := GetNumLimit(h, fmt, i, 8); Result := kString; end;
    'c': begin
      size := GetNum(fmt, i, -1);
      if size = -1 then LuaError(h.L, 'missing size for format option ''c''');
      Result := kChar;
    end;
    'z': Result := kZstr;
    'x': begin size := 1; Result := kPadding; end;
    'X': Result := kPaddAlign;
    ' ': ;
    '<': h.IsLittle := True;
    '>': h.IsLittle := False;
    '=': h.IsLittle := True;
    '!': h.MaxAlign := GetNumLimit(h, fmt, i, 8);
  else
    LuaError(h.L, Format('invalid format option ''%s''', [opt]));
  end;
end;

function GetDetails(var h: THeader; totalsize: Int64; const fmt: RawByteString;
                    var i: Integer; var size: Int64; var ntoalign: Int64): TKOption;
var
  align, szmoda: Int64;
  opt2: TKOption;
begin
  Result := GetOption(h, fmt, i, size);
  align := size;
  if Result = kPaddAlign then
  begin
    if i > Length(fmt) then
      ArgError(h.L, 1, 'invalid next option for option ''X''');
    opt2 := GetOption(h, fmt, i, align);
    if (opt2 = kChar) or (align = 0) then
      ArgError(h.L, 1, 'invalid next option for option ''X''');
  end;
  if (align <= 1) or (Result = kChar) then
    ntoalign := 0
  else
  begin
    if align > h.MaxAlign then align := h.MaxAlign;
    if (align and (align - 1)) <> 0 then
      ArgError(h.L, 1, 'format asks for alignment not power of 2');
    szmoda := Integer(totalsize and (align - 1));
    ntoalign := (align - szmoda) and (align - 1);
  end;
end;

procedure PackInt(var b: RawByteString; n: QWord; isLittle: Boolean; size: Integer; neg: Boolean);
var
  buf: RawByteString;
  i: Integer;
begin
  SetLength(buf, size);
  if isLittle then buf[1] := Chr(n and $FF) else buf[size] := Chr(n and $FF);
  for i := 1 to size - 1 do
  begin
    n := n shr 8;
    if isLittle then buf[1 + i] := Chr(n and $FF) else buf[size - i] := Chr(n and $FF);
  end;
  if neg and (size > SZINT) then
    for i := SZINT to size - 1 do
      if isLittle then buf[1 + i] := #$FF else buf[size - i] := #$FF;
  b := b + buf;
end;

procedure CopyWithEndian(var dest; const src; size: Integer; isLittle: Boolean);
var
  d, s: PByte;
  i: Integer;
begin
  d := @dest;
  s := @src;
  if isLittle then
    Move(s^, d^, size)
  else
    for i := 0 to size - 1 do d[size - 1 - i] := s[i];
end;

function str_pack(L: TLua): Integer;
var
  h: THeader;
  fmt, b, s: RawByteString;
  arg, i: Integer; size, ntoalign: Int64;
  totalsize: Int64;
  opt: TKOption;
  n, lim: Int64;
  fl: Single;
  d: Double;
  len: SizeUInt;
begin
  fmt := CheckString(L, 1);
  h.L := L;
  h.IsLittle := True;
  h.MaxAlign := 1;
  arg := 1;
  totalsize := 0;
  b := '';
  i := 1;
  while i <= Length(fmt) do
  begin
    opt := GetDetails(h, totalsize, fmt, i, size, ntoalign);
    if size + ntoalign > MAXPACK - totalsize then ArgError(L, arg, 'result too long');
    Inc(totalsize, ntoalign + size);
    while ntoalign > 0 do begin b := b + #0; Dec(ntoalign); end;
    Inc(arg);
    case opt of
      kInt: begin
        n := CheckInteger(L, arg);
        if size < SZINT then
        begin
          lim := Int64(1) shl (size * 8 - 1);
          if not ((-lim <= n) and (n < lim)) then ArgError(L, arg, 'integer overflow');
        end;
        PackInt(b, QWord(n), h.IsLittle, size, n < 0);
      end;
      kUint: begin
        n := CheckInteger(L, arg);
        if size < SZINT then
          if QWord(n) >= (QWord(1) shl (size * 8)) then ArgError(L, arg, 'unsigned overflow');
        PackInt(b, QWord(n), h.IsLittle, size, False);
      end;
      kFloat: begin
        fl := CheckNumber(L, arg);
        SetLength(s, 4);
        CopyWithEndian(s[1], fl, 4, h.IsLittle);
        b := b + s;
      end;
      kNumber, kDouble: begin
        d := CheckNumber(L, arg);
        SetLength(s, 8);
        CopyWithEndian(s[1], d, 8, h.IsLittle);
        b := b + s;
      end;
      kChar: begin
        s := CheckString(L, arg);
        len := Length(s);
        if len > SizeUInt(size) then ArgError(L, arg, 'string longer than given size');
        b := b + s;
        if len < SizeUInt(size) then b := b + StringOfChar(#0, size - len);
      end;
      kString: begin
        s := CheckString(L, arg);
        len := Length(s);
        if not ((size >= SZINT) or (QWord(len) < (QWord(1) shl (size * 8)))) then
          ArgError(L, arg, 'string length does not fit in given size');
        PackInt(b, len, h.IsLittle, size, False);
        b := b + s;
        Inc(totalsize, len);
      end;
      kZstr: begin
        s := CheckString(L, arg);
        if Pos(#0, s) > 0 then ArgError(L, arg, 'string contains zeros');
        b := b + s + #0;
        Inc(totalsize, Length(s) + 1);
      end;
      kPadding: begin
        b := b + #0;
        Dec(arg);
      end;
      kPaddAlign, kNop: Dec(arg);
    end;
  end;
  PushStr(L, b);
  Result := 1;
end;

function str_packsize(L: TLua): Integer;
var
  h: THeader;
  fmt: RawByteString;
  size, ntoalign: Int64; i: Integer;
  totalsize: Int64;
  opt: TKOption;
begin
  fmt := CheckString(L, 1);
  h.L := L;
  h.IsLittle := True;
  h.MaxAlign := 1;
  totalsize := 0;
  i := 1;
  while i <= Length(fmt) do
  begin
    opt := GetDetails(h, totalsize, fmt, i, size, ntoalign);
    if (opt = kString) or (opt = kZstr) then ArgError(L, 1, 'variable-length format');
    Inc(size, ntoalign);
    if totalsize > MAXPACK - size then ArgError(L, 1, 'format result too large');
    Inc(totalsize, size);
  end;
  PushInt(L, totalsize);
  Result := 1;
end;

function UnpackInt(L: TLua; const data: RawByteString; pos: Integer; isLittle: Boolean;
                   size: Integer; isSigned: Boolean): Int64;
var
  res, mask: QWord;
  i, limit: Integer;
  m: Byte;
begin
  res := 0;
  if size <= SZINT then limit := size else limit := SZINT;
  for i := limit - 1 downto 0 do
  begin
    res := res shl 8;
    if isLittle then res := res or Byte(data[pos + i])
    else res := res or Byte(data[pos + size - 1 - i]);
  end;
  if size < SZINT then
  begin
    if isSigned then
    begin
      mask := QWord(1) shl (size * 8 - 1);
      res := (res xor mask) - mask;
    end;
  end
  else if size > SZINT then
  begin
    if (not isSigned) or (Int64(res) >= 0) then m := 0 else m := $FF;
    for i := limit to size - 1 do
    begin
      if isLittle then
      begin
        if Byte(data[pos + i]) <> m then
          LuaError(L, Format('%d-byte integer does not fit into Lua Integer', [size]));
      end
      else if Byte(data[pos + size - 1 - i]) <> m then
        LuaError(L, Format('%d-byte integer does not fit into Lua Integer', [size]));
    end;
  end;
  Result := Int64(res);
end;

function str_unpack(L: TLua): Integer;
var
  h: THeader;
  fmt, data, s: RawByteString;
  ld, pos: Int64;
  i, n: Integer; size, ntoalign: Int64;
  opt: TKOption;
  fl: Single;
  d: Double;
  len: QWord;
  zlen: Integer;
begin
  fmt := CheckString(L, 1);
  data := CheckString(L, 2);
  ld := Length(data);
  pos := Int64(PosRelatI(OptInteger(L, 3, 1), SizeUInt(ld))) - 1;
  n := 0;
  if pos > ld then ArgError(L, 3, 'initial position out of string');
  h.L := L;
  h.IsLittle := True;
  h.MaxAlign := 1;
  i := 1;
  while i <= Length(fmt) do
  begin
    opt := GetDetails(h, pos, fmt, i, size, ntoalign);
    if Int64(ntoalign) + size > ld - pos then ArgError(L, 2, 'data string too short');
    Inc(pos, ntoalign);
    L.EnsureStack(L.Top + 5);
    Inc(n);
    case opt of
      kInt, kUint: PushInt(L, UnpackInt(L, data, Integer(pos) + 1, h.IsLittle, size, opt = kInt));
      kFloat: begin
        CopyWithEndian(fl, data[pos + 1], 4, h.IsLittle);
        PushNum(L, fl);
      end;
      kNumber, kDouble: begin
        CopyWithEndian(d, data[pos + 1], 8, h.IsLittle);
        PushNum(L, d);
      end;
      kChar: PushStr(L, Copy(data, pos + 1, size));
      kString: begin
        len := QWord(UnpackInt(L, data, Integer(pos) + 1, h.IsLittle, size, False));
        if len > QWord(ld - pos - size) then ArgError(L, 2, 'data string too short');
        PushStr(L, Copy(data, pos + size + 1, len));
        Inc(pos, Int64(len));
      end;
      kZstr: begin
        zlen := 0;
        while (pos + zlen < ld) and (data[pos + zlen + 1] <> #0) do Inc(zlen);
        if pos + zlen >= ld then ArgError(L, 2, 'unfinished string for format ''z''');
        PushStr(L, Copy(data, pos + 1, zlen));
        Inc(pos, zlen + 1);
      end;
      kPaddAlign, kPadding, kNop: Dec(n);
    end;
    Inc(pos, size);
  end;
  PushInt(L, pos + 1);
  Result := n + 1;
  if s <> '' then ;
end;

{ ===================================================================== }

function str_tostring_meta(L: TLua): Integer;
begin
  Result := 0;
end;

procedure OpenString(L: TLua);
const
  Funcs: array[0..16] of TLibFunc = (
    (Name: 'byte'; Func: @str_byte),
    (Name: 'char'; Func: @str_char),
    (Name: 'dump'; Func: @str_dump),
    (Name: 'find'; Func: @str_find),
    (Name: 'format'; Func: @str_format),
    (Name: 'gmatch'; Func: @str_gmatch),
    (Name: 'gsub'; Func: @str_gsub),
    (Name: 'len'; Func: @str_len),
    (Name: 'lower'; Func: @str_lower),
    (Name: 'match'; Func: @str_match),
    (Name: 'rep'; Func: @str_rep),
    (Name: 'reverse'; Func: @str_reverse),
    (Name: 'sub'; Func: @str_sub),
    (Name: 'upper'; Func: @str_upper),
    (Name: 'pack'; Func: @str_pack),
    (Name: 'packsize'; Func: @str_packsize),
    (Name: 'unpack'; Func: @str_unpack));
var
  t, mt: TTable;
begin
  t := NewLib(L, 'string', Funcs);
  mt := L.NewTable(0, 2);
  SetField(L, mt, '__index', LuaTab(t));
  L.MetaStr := mt;
end;

end.
