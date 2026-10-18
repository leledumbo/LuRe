unit lualibos;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// The operating system library.

interface

uses
  SysUtils, Math, luacore, luavm, luaaux, lualibbase;

type
  TCloseStateProc = procedure(L: TLua);

var
  // closes the Lua state (runs finalizers) before exiting; set by the CLI
  CloseStateHook: TCloseStateProc = nil;

procedure OpenOS(L: TLua);

implementation

type
  Ttm = record
    sec, min, hour, mday, mon, year, wday, yday, isdst: Integer;
    gmtoff: PtrInt;
    zone: PChar;
  end;
  Ptm = ^Ttm;
  Ptime_t = ^Int64;

function c_time(t: Ptime_t): Int64; cdecl; external 'c' name 'time';
function c_localtime_r(t: Ptime_t; r: Ptm): Ptm; cdecl; external 'c' name 'localtime_r';
function c_gmtime_r(t: Ptime_t; r: Ptm): Ptm; cdecl; external 'c' name 'gmtime_r';
function c_mktime(tm: Ptm): Int64; cdecl; external 'c' name 'mktime';
function c_strftime(buf: PChar; max: SizeUInt; fmt: PChar; tm: Ptm): SizeUInt; cdecl; external 'c' name 'strftime';
function c_clock: Int64; cdecl; external 'c' name 'clock';
function c_system(cmd: PChar): Integer; cdecl; external 'c' name 'system';
function c_getenv(name: PChar): PChar; cdecl; external 'c' name 'getenv';
function c_remove(name: PChar): Integer; cdecl; external 'c' name 'remove';
function c_rename(a, b: PChar): Integer; cdecl; external 'c' name 'rename';
function c_setlocale(cat: Integer; loc: PChar): PChar; cdecl; external 'c' name 'setlocale';
function c_mkstemp(templ: PChar): Integer; cdecl; external 'c' name 'mkstemp';
function c_close(fd: Integer): Integer; cdecl; external 'c' name 'close';
procedure c_exit(code: Integer); cdecl; external 'c' name 'exit';

const
  CLOCKS_PER_SEC = 1000000;

function os_clock(L: TLua): Integer;
begin
  PushNum(L, c_clock / CLOCKS_PER_SEC);
  Result := 1;
end;

{ ------------------------------------------------------------------ }
{ date and time                                                       }
{ ------------------------------------------------------------------ }

procedure SetField_(L: TLua; t: TTable; const key: string; value: Integer);
begin
  SetField(L, t, key, LuaInt(value));
end;

procedure SetAllFields(L: TLua; t: TTable; const tm: Ttm);
begin
  SetField_(L, t, 'year', tm.year + 1900);
  SetField_(L, t, 'month', tm.mon + 1);
  SetField_(L, t, 'day', tm.mday);
  SetField_(L, t, 'hour', tm.hour);
  SetField_(L, t, 'min', tm.min);
  SetField_(L, t, 'sec', tm.sec);
  SetField_(L, t, 'yday', tm.yday + 1);
  SetField_(L, t, 'wday', tm.wday + 1);
  if tm.isdst >= 0 then
    SetField(L, t, 'isdst', LuaBool(tm.isdst <> 0));
end;

function GetBoolField(L: TLua; t: TTable; const key: string): Integer;
var
  v: TLuaValue;
begin
  v := LuaIndex(L, LuaTab(t), NewStr(L, RawByteString(key)));
  if v.Vt = vtNil then Result := -1
  else if Truthy(v) then Result := 1
  else Result := 0;
end;

function GetField(L: TLua; t: TTable; const key: string; d, delta: Integer): Integer;
var
  v: TLuaValue;
  res: Int64;
begin
  v := LuaIndex(L, LuaTab(t), NewStr(L, RawByteString(key)));
  if not ToInteger(v, res) then
  begin
    if v.Vt <> vtNil then
      LuaError(L, Format('field ''%s'' is not an integer', [key]))
    else if d < 0 then
      LuaError(L, Format('field ''%s'' missing in date table', [key]))
    else
      res := d;
  end
  else
  begin
    if res >= 0 then
    begin
      if res - delta > High(Int32) then
        LuaError(L, Format('field ''%s'' is out-of-bound', [key]));
    end
    else if res < Int64(Low(Int32)) + delta then
      LuaError(L, Format('field ''%s'' is out-of-bound', [key]));
    Dec(res, delta);
  end;
  Result := Integer(res);
end;

function os_time(L: TLua): Integer;
var
  t: Int64;
  tm: Ttm;
  tt: TTable;
begin
  if ArgIsNoneOrNil(L, 1) then
    t := c_time(nil)
  else
  begin
    tt := CheckTable(L, 1);
    FillChar(tm, SizeOf(tm), 0);
    tm.year := GetField(L, tt, 'year', -1, 1900);
    tm.mon := GetField(L, tt, 'month', -1, 1);
    tm.mday := GetField(L, tt, 'day', -1, 0);
    tm.hour := GetField(L, tt, 'hour', 12, 0);
    tm.min := GetField(L, tt, 'min', 0, 0);
    tm.sec := GetField(L, tt, 'sec', 0, 0);
    tm.isdst := GetBoolField(L, tt, 'isdst');
    t := c_mktime(@tm);
    SetAllFields(L, tt, tm);
  end;
  if t = -1 then
    LuaError(L, 'time result cannot be represented in this installation');
  PushInt(L, t);
  Result := 1;
end;

function os_difftime(L: TLua): Integer;
var
  t1, t2: Int64;
begin
  t1 := CheckInteger(L, 1);
  t2 := CheckInteger(L, 2);
  PushNum(L, Double(t1) - Double(t2));
  Result := 1;
end;

const
  ValidConv = 'aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%';
  ValidConvE = 'cCxXyY';
  ValidConvO = 'deHImMSuUVwWy';

function CheckConv(L: TLua; const conv: string; var ix: Integer): string;
var
  c: Char;
begin
  // conv[ix] is the character after '%'
  c := conv[ix];
  if Pos(c, ValidConv) > 0 then
  begin
    Result := '%' + c;
    Inc(ix);
    Exit;
  end;
  if (c = 'E') and (ix < Length(conv)) and (Pos(conv[ix + 1], ValidConvE) > 0) then
  begin
    Result := '%E' + conv[ix + 1];
    Inc(ix, 2);
    Exit;
  end;
  if (c = 'O') and (ix < Length(conv)) and (Pos(conv[ix + 1], ValidConvO) > 0) then
  begin
    Result := '%O' + conv[ix + 1];
    Inc(ix, 2);
    Exit;
  end;
  ArgError(L, 1, Format('invalid conversion specifier ''%%%s''', [Copy(conv, ix, 255)]));
  Result := '';
end;

function os_date(L: TLua): Integer;
var
  fmt, res, spec: string;
  t: Int64;
  tm: Ttm;
  utc: Boolean;
  i: Integer;
  buf: array[0..255] of Char;
  n: SizeUInt;
  tbl: TTable;
begin
  fmt := string(OptString(L, 1, '%c'));
  if ArgIsNoneOrNil(L, 2) then t := c_time(nil) else t := CheckInteger(L, 2);
  utc := (fmt <> '') and (fmt[1] = '!');
  if utc then Delete(fmt, 1, 1);
  if utc then
  begin
    if c_gmtime_r(@t, @tm) = nil then
      LuaError(L, 'date result cannot be represented in this installation');
  end
  else if c_localtime_r(@t, @tm) = nil then
    LuaError(L, 'date result cannot be represented in this installation');
  if Copy(fmt, 1, 2) = '*t' then
  begin
    tbl := L.NewTable(0, 9);
    SetAllFields(L, tbl, tm);
    LuaPush(L, LuaTab(tbl));
    Exit(1);
  end;
  res := '';
  i := 1;
  while i <= Length(fmt) do
  begin
    if fmt[i] <> '%' then
    begin
      res := res + fmt[i];
      Inc(i);
    end
    else
    begin
      Inc(i);
      if i > Length(fmt) then
        ArgError(L, 1, 'invalid conversion specifier ''%''');
      spec := CheckConv(L, fmt, i);
      n := c_strftime(@buf[0], SizeOf(buf), PChar(spec), @tm);
      SetString(spec, PChar(@buf[0]), n);
      res := res + spec;
    end;
  end;
  PushStr(L, RawByteString(res));
  Result := 1;
end;

{ ------------------------------------------------------------------ }

function os_getenv(L: TLua): Integer;
var
  p: PChar;
begin
  p := c_getenv(PChar(string(CheckString(L, 1))));
  if p = nil then PushFail(L) else PushStr(L, RawByteString(StrPas(p)));
  Result := 1;
end;

function os_execute(L: TLua): Integer;
var
  cmd: string;
  stat: Integer;
begin
  if ArgIsNoneOrNil(L, 1) then
  begin
    PushBool(L, c_system(nil) <> 0);
    Exit(1);
  end;
  cmd := string(CheckString(L, 1));
  stat := c_system(PChar(cmd));
  if stat = -1 then Exit(FileResult(L, False, ''));
  // decode the wait status
  if (stat and $7F) = 0 then
  begin
    stat := (stat shr 8) and $FF;
    if stat = 0 then PushBool(L, True) else PushFail(L);
    PushStr(L, 'exit');
    PushInt(L, stat);
  end
  else
  begin
    PushFail(L);
    PushStr(L, 'signal');
    PushInt(L, stat and $7F);
  end;
  Result := 3;
end;

function os_remove(L: TLua): Integer;
var
  f: string;
begin
  f := string(CheckString(L, 1));
  Result := FileResult(L, c_remove(PChar(f)) = 0, f);
end;

function os_rename(L: TLua): Integer;
var
  a, b: string;
begin
  a := string(CheckString(L, 1));
  b := string(CheckString(L, 2));
  Result := FileResult(L, c_rename(PChar(a), PChar(b)) = 0, '');
end;

function os_tmpname(L: TLua): Integer;
var
  name: array[0..31] of Char;
  fd: Integer;
begin
  StrPCopy(name, '/tmp/lua_XXXXXX');
  fd := c_mkstemp(@name[0]);
  if fd = -1 then LuaError(L, 'unable to generate a unique filename');
  c_close(fd);
  PushStr(L, RawByteString(StrPas(@name[0])));
  Result := 1;
end;

function os_exit(L: TLua): Integer;
var
  status: Integer;
  v: TLuaValue;
begin
  v := LuaArg(L, 1);
  if v.Vt = vtBool then
  begin
    if v.B then status := 0 else status := 1;
  end
  else
    status := Integer(OptInteger(L, 1, 0));
  if Truthy(LuaArg(L, 2)) and Assigned(CloseStateHook) then
    CloseStateHook(L.Main);
  OutFlush;
  c_exit(status);
  Result := 0;
end;

function os_setlocale(L: TLua): Integer;
const
  Cats: array[0..5] of string = ('all', 'collate', 'ctype', 'monetary', 'numeric', 'time');
  CatNum: array[0..5] of Integer = (6, 3, 0, 4, 1, 2);
var
  loc: PChar;
  locName: string;
  cat: Integer;
begin
  if ArgIsNoneOrNil(L, 1) then loc := nil
  else
  begin
    locName := string(CheckString(L, 1));
    loc := PChar(locName);
  end;
  cat := CheckOption(L, 2, 'all', Cats);
  loc := c_setlocale(CatNum[cat], loc);
  RefreshCType;
  if loc = nil then PushFail(L) else PushStr(L, RawByteString(StrPas(loc)));
  Result := 1;
end;

procedure OpenOS(L: TLua);
const
  Funcs: array[0..10] of TLibFunc = (
    (Name: 'clock'; Func: @os_clock),
    (Name: 'date'; Func: @os_date),
    (Name: 'difftime'; Func: @os_difftime),
    (Name: 'execute'; Func: @os_execute),
    (Name: 'exit'; Func: @os_exit),
    (Name: 'getenv'; Func: @os_getenv),
    (Name: 'remove'; Func: @os_remove),
    (Name: 'rename'; Func: @os_rename),
    (Name: 'setlocale'; Func: @os_setlocale),
    (Name: 'time'; Func: @os_time),
    (Name: 'tmpname'; Func: @os_tmpname));
begin
  NewLib(L, 'os', Funcs);
end;

end.
