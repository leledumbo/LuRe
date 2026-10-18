unit luaaux;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// Helpers for implementing library functions: argument checking, error
// messages, conversions and registration of functions in tables.

interface

uses
  SysUtils, Math, Generics.Collections, luacore, luavm;

type
  TLibFunc = record
    Name: string;
    Func: TCFunc;
  end;

// ---- errors
procedure ArgError(L: TLua; arg: Integer; const msg: string);
procedure TypeErrorArg(L: TLua; arg: Integer; const tname: string);
function GlobalFuncName(L: TLua; const f: TFunction): string;

// ---- argument checking
function ArgIsNone(L: TLua; arg: Integer): Boolean;
function ArgIsNoneOrNil(L: TLua; arg: Integer): Boolean;
procedure CheckAny(L: TLua; arg: Integer);
function CheckInteger(L: TLua; arg: Integer): Int64;
function OptInteger(L: TLua; arg: Integer; def: Int64): Int64;
function CheckNumber(L: TLua; arg: Integer): Double;
function OptNumber(L: TLua; arg: Integer; def: Double): Double;
function CheckNumberVal(L: TLua; arg: Integer): TLuaValue;   // keeps integer/float
function CheckStr(L: TLua; arg: Integer): TStringObj;
function CheckString(L: TLua; arg: Integer): RawByteString;
function OptString(L: TLua; arg: Integer; const def: RawByteString): RawByteString;
function CheckTable(L: TLua; arg: Integer): TTable;
function CheckFunction(L: TLua; arg: Integer): TFunction;
function CheckOption(L: TLua; arg: Integer; const def: string; const opts: array of string): Integer;
function ToIntegerArg(L: TLua; arg: Integer; var v: Int64): Boolean;

// ---- growable byte buffer (like luaL_Buffer) for building strings without temporaries
type
  TBuf = record
    P: PByte;
    Len, Cap: SizeInt;
  end;
procedure BufInit(var b: TBuf);
procedure BufAdd(var b: TBuf; p: PByte; n: SizeInt);
procedure BufAddByte(var b: TBuf; c: Byte);
procedure BufAddStr(var b: TBuf; const s: RawByteString);
procedure BufFree(var b: TBuf);

// ---- character classes of the current C locale (tables, rebuilt by RefreshCType)
const
  CT_ALPHA = 1; CT_DIGIT = 2; CT_LOWER = 4; CT_UPPER = 8; CT_SPACE = 16;
  CT_CNTRL = 32; CT_GRAPH = 64; CT_PUNCT = 128; CT_XDIGIT = 256; CT_ALNUM = 512;
var
  CTypeTab: array[0..255] of Word;
  ToLowerTab, ToUpperTab: array[0..255] of Byte;
procedure RefreshCType;   // call after the locale changed

// ---- results
procedure PushStr(L: TLua; const s: RawByteString);
procedure PushBuf(L: TLua; p: PByte; n: SizeUInt);   // a string made from raw bytes
procedure PushNil(L: TLua);
procedure PushBool(L: TLua; b: Boolean);
procedure PushInt(L: TLua; i: Int64);
procedure PushNum(L: TLua; n: Double);
procedure PushFail(L: TLua);
procedure PushCFunction(L: TLua; f: TCFunc);

// ---- conversions
function ToStringAux(L: TLua; constref v: TLuaValue): RawByteString;    // luaL_tolstring
function PointerString(constref v: TLuaValue): string;

// ---- registration
procedure SetField(L: TLua; t: TTable; const name: string; constref v: TLuaValue);
procedure RegisterFuncs(L: TLua; t: TTable; const funcs: array of TLibFunc);
function NewLib(L: TLua; const name: string; const funcs: array of TLibFunc): TTable;
function LightC(L: TLua; f: TCFunc; const name: string): TFunction;
function GetLoaded(L: TLua): TTable;
procedure SetLoaded(L: TLua; const name: string; constref v: TLuaValue);
function NewMetatable(L: TLua; const tname: string): TTable;
function GetMetatableByName(L: TLua; const tname: string): TTable;

// ---- misc
function NewStr(L: TLua; const s: RawByteString): TLuaValue;
function StrKey(L: TLua; const s: string): TStringObj;
function Where(L: TLua; level: Integer): string;

// results of operations that may fail with an OS error
function FileResult(L: TLua; ok: Boolean; const fname: string): Integer;
function StrError(code: Integer): string;
function GetErrno: Integer;

implementation

function c_errno_location: PInteger; cdecl; external 'c' name '__errno_location';
function c_strerror(code: Integer): PChar; cdecl; external 'c' name 'strerror';

function GetErrno: Integer;
begin
  Result := c_errno_location^;
end;

function StrError(code: Integer): string;
begin
  Result := string(StrPas(c_strerror(code)));
end;

function FileResult(L: TLua; ok: Boolean; const fname: string): Integer;
var
  en: Integer;
begin
  en := GetErrno;
  if ok then
  begin
    PushBool(L, True);
    Exit(1);
  end;
  PushFail(L);
  if fname <> '' then
    PushStr(L, RawByteString(fname + ': ' + StrError(en)))
  else
    PushStr(L, RawByteString(StrError(en)));
  PushInt(L, en);
  Result := 3;
end;

function StrKey(L: TLua; const s: string): TStringObj;
begin
  Result := L.NewString(RawByteString(s));
end;

function NewStr(L: TLua; const s: RawByteString): TLuaValue;
begin
  Result := LuaStr(L.NewString(s));
end;

function Where(L: TLua; level: Integer): string;
begin
  Result := ErrorPosition(L, level);
end;

{ ===================================================================== }
{ errors                                                                 }
{ ===================================================================== }

// name of a function as found in the loaded modules ("string.rep", "print")
function GlobalFuncName(L: TLua; const f: TFunction): string;
var
  loaded: TTable;
  k1, v1, k2, v2: TLuaValue;
  key: string;
begin
  Result := '';
  loaded := GetLoaded(L);
  k1.Vt := vtNil;
  while TableNext(loaded, k1, k1, v1) do
  begin
    if (k1.Vt <> vtStr) then Continue;
    if (v1.Vt = vtFunc) and (v1.F = f) then Exit(string(k1.S.Str));
    if v1.Vt = vtTab then
    begin
      k2.Vt := vtNil;
      while TableNext(v1.T, k2, k2, v2) do
        if (k2.Vt = vtStr) and (v2.Vt = vtFunc) and (v2.F = f) then
        begin
          key := string(k1.S.Str) + '.' + string(k2.S.Str);
          if Copy(key, 1, 3) = '_G.' then key := Copy(key, 4, MaxInt);
          Exit(key);
        end;
    end;
  end;
end;

procedure ArgError(L: TLua; arg: Integer; const msg: string);
var
  name, what: string;
  ci: TCallInfo;
begin
  name := '';
  what := '';
  if L.NCI > 0 then
  begin
    what := FuncNameFromCall(L, L.NCI - 1, name);
    if what = 'method' then
    begin
      Dec(arg);
      if arg = 0 then
        LuaError(L, Format('calling ''%s'' on bad self (%s)', [name, msg]));
    end;
    if (what = '') or (name = '') then
    begin
      ci := L.CI[L.NCI - 1];
      name := '';
      if ci.Func <> nil then name := GlobalFuncName(L, ci.Func);
      if name = '' then name := '?';
    end;
    LuaError(L, Format('bad argument #%d to ''%s'' (%s)', [arg, name, msg]));
  end;
  LuaError(L, Format('bad argument #%d (%s)', [arg, msg]));
end;

function TypeNameOfArg(L: TLua; arg: Integer): string;
var
  v: TLuaValue;
  n: TLuaValue;
begin
  if ArgIsNone(L, arg) then Exit('no value');
  v := LuaArg(L, arg);
  n := GetMetaField(L, v, '__name');
  if n.Vt = vtStr then Exit(string(n.S.Str));
  if v.Vt = vtLight then Exit('light userdata');
  Result := VTypeName(v);
end;

procedure TypeErrorArg(L: TLua; arg: Integer; const tname: string);
begin
  ArgError(L, arg, Format('%s expected, got %s', [tname, TypeNameOfArg(L, arg)]));
end;

{ ===================================================================== }
{ argument checking                                                      }
{ ===================================================================== }

function ArgIsNone(L: TLua; arg: Integer): Boolean;
begin
  Result := L.Top - L.CI[L.NCI - 1].Base < arg;
end;

function ArgIsNoneOrNil(L: TLua; arg: Integer): Boolean;
begin
  Result := ArgPtr(L, arg)^.Vt = vtNil;
end;

procedure CheckAny(L: TLua; arg: Integer);
begin
  if ArgIsNone(L, arg) then ArgError(L, arg, 'value expected');
end;

function ToIntegerArg(L: TLua; arg: Integer; var v: Int64): Boolean;
begin
  Result := ToInteger(LuaArg(L, arg), v);
end;

function CheckInteger(L: TLua; arg: Integer): Int64;
var
  v: TLuaValue;
  n: Double;
begin
  if ArgPtr(L, arg)^.Vt = vtInt then Exit(ArgPtr(L, arg)^.I);
  v := LuaArg(L, arg);
  if ToInteger(v, Result) then Exit;
  if ToNumberVal(v, n) then
    ArgError(L, arg, 'number has no integer representation')
  else
    TypeErrorArg(L, arg, 'number');
  Result := 0;
end;

function OptInteger(L: TLua; arg: Integer; def: Int64): Int64;
begin
  if ArgIsNoneOrNil(L, arg) then Result := def else Result := CheckInteger(L, arg);
end;

function CheckNumber(L: TLua; arg: Integer): Double;
begin
  if not ToNumberVal(LuaArg(L, arg), Result) then
  begin
    TypeErrorArg(L, arg, 'number');
    Result := 0;
  end;
end;

function OptNumber(L: TLua; arg: Integer; def: Double): Double;
begin
  if ArgIsNoneOrNil(L, arg) then Result := def else Result := CheckNumber(L, arg);
end;

function CheckNumberVal(L: TLua; arg: Integer): TLuaValue;
var
  v: TLuaValue;
  i: Int64;
  n: Double;
begin
  v := LuaArg(L, arg);
  case v.Vt of
    vtInt, vtFlt: Exit(v);
    vtStr: begin
      if StrToIntVal(v.S.Str, i) then Exit(LuaInt(i));
      if StrToNumVal(v.S.Str, n) then Exit(LuaNum(n));
    end;
  end;
  TypeErrorArg(L, arg, 'number');
  Result.Vt := vtNil;
end;

function CheckStr(L: TLua; arg: Integer): TStringObj;
var
  v: TLuaValue;
  idx: Integer;
begin
  if ArgPtr(L, arg)^.Vt = vtStr then Exit(ArgPtr(L, arg)^.S);
  v := LuaArg(L, arg);
  case v.Vt of
    vtStr: Exit(v.S);
    vtInt, vtFlt: begin
      Result := L.NewString(RawByteString(NumToStr(v)));
      // like lua_tolstring, convert the argument in place
      if arg > 0 then idx := LuaAbsIndex(L, arg) else idx := L.Top + arg;
      L.Stack[idx] := LuaStr(Result);
      Exit;
    end;
  end;
  TypeErrorArg(L, arg, 'string');
  Result := nil;
end;

function CheckString(L: TLua; arg: Integer): RawByteString;
begin
  Result := CheckStr(L, arg).Str;
end;

function OptString(L: TLua; arg: Integer; const def: RawByteString): RawByteString;
begin
  if ArgIsNoneOrNil(L, arg) then Result := def else Result := CheckString(L, arg);
end;

function CheckTable(L: TLua; arg: Integer): TTable;
var
  v: TLuaValue;
begin
  v := LuaArg(L, arg);
  if v.Vt <> vtTab then TypeErrorArg(L, arg, 'table');
  Result := v.T;
end;

function CheckFunction(L: TLua; arg: Integer): TFunction;
var
  v: TLuaValue;
begin
  v := LuaArg(L, arg);
  if v.Vt <> vtFunc then TypeErrorArg(L, arg, 'function');
  Result := v.F;
end;

function CheckOption(L: TLua; arg: Integer; const def: string; const opts: array of string): Integer;
var
  name: string;
  i: Integer;
begin
  if (def <> '') and ArgIsNoneOrNil(L, arg) then
    name := def
  else
    name := string(CheckString(L, arg));
  for i := 0 to High(opts) do
    if opts[i] = name then Exit(i);
  ArgError(L, arg, Format('invalid option ''%s''', [name]));
  Result := -1;
end;

{ ===================================================================== }
{ results                                                                }
{ ===================================================================== }

procedure PushStr(L: TLua; const s: RawByteString);
begin
  LuaPush(L, LuaStr(L.NewString(s)));
end;

function c_isalpha_(c: Integer): Integer; cdecl; external 'c' name 'isalpha';
function c_islower_(c: Integer): Integer; cdecl; external 'c' name 'islower';
function c_isupper_(c: Integer): Integer; cdecl; external 'c' name 'isupper';
function c_isspace_(c: Integer): Integer; cdecl; external 'c' name 'isspace';
function c_iscntrl_(c: Integer): Integer; cdecl; external 'c' name 'iscntrl';
function c_isgraph_(c: Integer): Integer; cdecl; external 'c' name 'isgraph';
function c_ispunct_(c: Integer): Integer; cdecl; external 'c' name 'ispunct';
function c_isxdigit_(c: Integer): Integer; cdecl; external 'c' name 'isxdigit';
function c_isalnum_(c: Integer): Integer; cdecl; external 'c' name 'isalnum';
function c_tolower_(c: Integer): Integer; cdecl; external 'c' name 'tolower';
function c_toupper_(c: Integer): Integer; cdecl; external 'c' name 'toupper';

procedure RefreshCType;
var
  c: Integer;
  m: Word;
begin
  for c := 0 to 255 do
  begin
    m := 0;
    if c_isalpha_(c) <> 0 then m := m or CT_ALPHA;
    if (c >= 48) and (c <= 57) then m := m or CT_DIGIT;
    if c_islower_(c) <> 0 then m := m or CT_LOWER;
    if c_isupper_(c) <> 0 then m := m or CT_UPPER;
    if c_isspace_(c) <> 0 then m := m or CT_SPACE;
    if c_iscntrl_(c) <> 0 then m := m or CT_CNTRL;
    if c_isgraph_(c) <> 0 then m := m or CT_GRAPH;
    if c_ispunct_(c) <> 0 then m := m or CT_PUNCT;
    if c_isxdigit_(c) <> 0 then m := m or CT_XDIGIT;
    if c_isalnum_(c) <> 0 then m := m or CT_ALNUM;
    CTypeTab[c] := m;
    ToLowerTab[c] := Byte(c_tolower_(c));
    ToUpperTab[c] := Byte(c_toupper_(c));
  end;
end;

procedure BufInit(var b: TBuf);
begin
  b.P := nil;
  b.Len := 0;
  b.Cap := 0;
end;

procedure BufGrow(var b: TBuf; need: SizeInt);
var
  nc: SizeInt;
begin
  nc := b.Cap * 2;
  if nc < 64 then nc := 64;
  while nc < need do nc := nc * 2;
  ReallocMem(b.P, nc);
  b.Cap := nc;
end;

procedure BufAdd(var b: TBuf; p: PByte; n: SizeInt);
begin
  if n <= 0 then Exit;
  if b.Len + n > b.Cap then BufGrow(b, b.Len + n);
  Move(p^, b.P[b.Len], n);
  Inc(b.Len, n);
end;

procedure BufAddByte(var b: TBuf; c: Byte);
begin
  if b.Len >= b.Cap then BufGrow(b, b.Len + 1);
  b.P[b.Len] := c;
  Inc(b.Len);
end;

procedure BufAddStr(var b: TBuf; const s: RawByteString);
begin
  BufAdd(b, PByte(Pointer(s)), Length(s));
end;

procedure BufFree(var b: TBuf);
begin
  if b.P <> nil then FreeMem(b.P);
  b.P := nil;
  b.Len := 0;
  b.Cap := 0;
end;

procedure PushBuf(L: TLua; p: PByte; n: SizeUInt);
var
  o: TStringObj;
begin
  o := L.NewStringBuf(p, n);
  if L.Top >= L.StackSize then L.EnsureStack(L.Top + 1);
  L.Stack[L.Top].S := o;
  L.Stack[L.Top].Vt := vtStr;
  Inc(L.Top);
end;

procedure PushNil(L: TLua);
begin
  LuaPush(L, LuaNil);
end;

procedure PushBool(L: TLua; b: Boolean);
begin
  LuaPush(L, LuaBool(b));
end;

procedure PushInt(L: TLua; i: Int64);
begin
  LuaPush(L, LuaInt(i));
end;

procedure PushNum(L: TLua; n: Double);
begin
  LuaPush(L, LuaNum(n));
end;

procedure PushFail(L: TLua);
begin
  LuaPush(L, LuaNil);
end;

procedure PushCFunction(L: TLua; f: TCFunc);
begin
  LuaPush(L, LuaFunc(LightC(L, f, '?')));
end;

{ ===================================================================== }
{ conversions                                                            }
{ ===================================================================== }

function PointerString(constref v: TLuaValue): string;
var
  p: PtrUInt;
begin
  case v.Vt of
    vtTab, vtFunc, vtUser, vtThread, vtStr: p := PtrUInt(v.T);
    vtLight: p := PtrUInt(v.P);
  else
    p := 0;
  end;
  Result := '0x' + LowerCase(IntToHex(p, 14));
end;

function ToStringAux(L: TLua; constref v: TLuaValue): RawByteString;
var
  tm, r, nm: TLuaValue;
begin
  tm := GetMetaField(L, v, '__tostring');
  if tm.Vt <> vtNil then
  begin
    r := CallMeta(L, tm, [v]);
    if r.Vt <> vtStr then
      LuaError(L, '''__tostring'' must return a string');
    Exit(r.S.Str);
  end;
  case v.Vt of
    vtInt, vtFlt: Result := RawByteString(NumToStr(v));
    vtStr: Result := v.S.Str;
    vtBool: if v.B then Result := 'true' else Result := 'false';
    vtNil, vtDead: Result := 'nil';
  else
    begin
      nm := GetMetaField(L, v, '__name');
      if nm.Vt = vtStr then
        Result := RawByteString(Format('%s: %s', [string(nm.S.Str), PointerString(v)]))
      else
        Result := RawByteString(Format('%s: %s', [VTypeName(v), PointerString(v)]));
    end;
  end;
end;

{ ===================================================================== }
{ registration                                                           }
{ ===================================================================== }

procedure SetField(L: TLua; t: TTable; const name: string; constref v: TLuaValue);
begin
  TableSetStr(t, L.NewString(RawByteString(name)), v);
end;

var
  LightFuncs: specialize TDictionary<Pointer, TFunction>;

// C functions without upvalues are shared objects, so that two references
// to the same function compare equal (like light C functions)
function LightC(L: TLua; f: TCFunc; const name: string): TFunction;
begin
  if LightFuncs = nil then LightFuncs := specialize TDictionary<Pointer, TFunction>.Create;
  if not LightFuncs.TryGetValue(Pointer(f), Result) then
  begin
    Result := L.NewCFunction(f);
    Result.Fixed := True;
    Result.CName := name;
    LightFuncs.Add(Pointer(f), Result);
  end;
end;

procedure RegisterFuncs(L: TLua; t: TTable; const funcs: array of TLibFunc);
var
  i: Integer;
begin
  for i := 0 to High(funcs) do
    SetField(L, t, funcs[i].Name, LuaFunc(LightC(L, funcs[i].Func, funcs[i].Name)));
end;

function GetLoaded(L: TLua): TTable;
var
  v: TLuaValue;
begin
  v := TableGetStr(L.Registry, StrKey(L, '_LOADED'));
  if v.Vt <> vtTab then
  begin
    Result := L.NewTable(0, 8);
    TableSetStr(L.Registry, StrKey(L, '_LOADED'), LuaTab(Result));
  end
  else
    Result := v.T;
end;

procedure SetLoaded(L: TLua; const name: string; constref v: TLuaValue);
begin
  SetField(L, GetLoaded(L), name, v);
end;

function NewLib(L: TLua; const name: string; const funcs: array of TLibFunc): TTable;
begin
  Result := L.NewTable(0, Length(funcs));
  RegisterFuncs(L, Result, funcs);
  if name <> '' then
  begin
    SetField(L, L.GlobalT, name, LuaTab(Result));
    SetLoaded(L, name, LuaTab(Result));
  end;
end;

function NewMetatable(L: TLua; const tname: string): TTable;
var
  v: TLuaValue;
begin
  v := TableGetStr(L.Registry, StrKey(L, tname));
  if v.Vt = vtTab then Exit(v.T);
  Result := L.NewTable(0, 4);
  SetField(L, Result, '__name', NewStr(L, RawByteString(tname)));
  TableSetStr(L.Registry, StrKey(L, tname), LuaTab(Result));
end;

function GetMetatableByName(L: TLua; const tname: string): TTable;
var
  v: TLuaValue;
begin
  v := TableGetStr(L.Registry, StrKey(L, tname));
  if v.Vt = vtTab then Result := v.T else Result := nil;
end;

initialization
  RefreshCType;

end.
