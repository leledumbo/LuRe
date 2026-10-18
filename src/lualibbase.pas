unit lualibbase;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// The basic library (print, pairs, pcall, load, ...).

interface

uses
  SysUtils, Classes, Math, luacore, luavm, luaaux, luaparse;

procedure OpenBase(L: TLua);

// loads a chunk from memory: returns False and an error message on failure
function LoadBuffer(L: TLua; const buf: RawByteString; const name, mode: string;
                    var f: TFunction; var err: string): Boolean;
function ReadFileContent(const fname: string; var content: RawByteString): Boolean;
procedure PrepareFileChunk(var s: RawByteString);
procedure SetEnvUpvalue(L: TLua; f: TFunction; constref env: TLuaValue);
procedure OutWrite(const s: RawByteString);
procedure OutFlush;
procedure WarnMessage(L: TLua; const msg: RawByteString; tocont: Boolean);

implementation

function c_fwrite(buf: Pointer; size, n: SizeUInt; stream: Pointer): SizeUInt; cdecl; external 'c' name 'fwrite';
function c_fflush(stream: Pointer): Integer; cdecl; external 'c' name 'fflush';
var
  c_stdout: Pointer; external name 'stdout';
  c_stderr: Pointer; external name 'stderr';

procedure OutWrite(const s: RawByteString);
begin
  if Length(s) > 0 then
    c_fwrite(Pointer(s), 1, Length(s), c_stdout);
end;

procedure OutFlush;
begin
  c_fflush(c_stdout);
end;

{ ===================================================================== }
{ warnings                                                               }
{ ===================================================================== }

var
  WarnOn: Boolean = False;
  WarnCont: Boolean = False;
  WarnCtl: Boolean = False;   // first piece of a message was a control message

procedure WarnMessage(L: TLua; const msg: RawByteString; tocont: Boolean);
var
  s: RawByteString;
begin
  if (not WarnCont) and (Length(msg) > 0) and (msg[1] = '@') and (not tocont) then
  begin
    // control message
    if msg = '@on' then WarnOn := True
    else if msg = '@off' then WarnOn := False;
    Exit;
  end;
  if not WarnOn then
  begin
    WarnCont := tocont;
    WarnCtl := False;
    Exit;
  end;
  if not WarnCont then
  begin
    s := 'Lua warning: ';
    c_fwrite(Pointer(s), 1, Length(s), c_stderr);
  end;
  if Length(msg) > 0 then
    c_fwrite(Pointer(msg), 1, Length(msg), c_stderr);
  if not tocont then
  begin
    s := #10;
    c_fwrite(Pointer(s), 1, 1, c_stderr);
    c_fflush(c_stderr);
  end;
  WarnCont := tocont;
end;

{ ===================================================================== }
{ loading                                                                }
{ ===================================================================== }

procedure SetEnvUpvalue(L: TLua; f: TFunction; constref env: TLuaValue);
var
  i: Integer;
  u: TUpval;
begin
  for i := 0 to High(f.Upvals) do
  begin
    u := L.NewUpval;
    f.Upvals[i] := u;
  end;
  if Length(f.Upvals) > 0 then
    f.Upvals[0].V := env;
end;

function LoadBuffer(L: TLua; const buf: RawByteString; const name, mode: string;
                    var f: TFunction; var err: string): Boolean;
begin
  Result := False;
  try
    if (Length(buf) > 0) and (buf[1] = #27) then
    begin
      if Pos('b', mode) = 0 then
      begin
        err := Format('attempt to load a binary chunk (mode is ''%s'')', [mode]);
        Exit;
      end;
      f := LuaUndump(L, buf, name);
    end
    else
    begin
      if Pos('t', mode) = 0 then
      begin
        err := Format('attempt to load a text chunk (mode is ''%s'')', [mode]);
        Exit;
      end;
      f := LuaCompile(L, buf, name);
    end;
    Result := True;
  except
    on E: ELuaError do
      err := E.Message;
  end;
end;

function ReadFileContent(const fname: string; var content: RawByteString): Boolean;
var
  fs: TFileStream;
  n: Int64;
begin
  Result := False;
  try
    fs := TFileStream.Create(fname, fmOpenRead or fmShareDenyNone);
    try
      n := fs.Size;
      SetLength(content, n);
      if n > 0 then fs.ReadBuffer(content[1], n);
      Result := True;
    finally
      fs.Free;
    end;
  except
    on E: Exception do Result := False;
  end;
end;

procedure PrepareFileChunk(var s: RawByteString);
var
  i: Integer;
begin
  // skip an UTF-8 BOM
  if (Length(s) >= 3) and (s[1] = #$EF) and (s[2] = #$BB) and (s[3] = #$BF) then
    Delete(s, 1, 3);
  if (Length(s) > 0) and (s[1] = '#') then
  begin
    // skip the first line, keeping its end-of-line for line numbers
    i := 1;
    while (i <= Length(s)) and (s[i] <> #10) do Inc(i);
    Delete(s, 1, i - 1);
    // a binary chunk after the comment line: skip the newline too
    if (Length(s) > 1) and (s[2] = #27) then Delete(s, 1, 1);
  end;
end;

{ ===================================================================== }
{ base functions                                                         }
{ ===================================================================== }

function luaB_print(L: TLua): Integer;
var
  n, i: Integer;
begin
  n := LuaGetTop(L);
  for i := 1 to n do
  begin
    if i > 1 then OutWrite(#9);
    OutWrite(ToStringAux(L, LuaArg(L, i)));
  end;
  OutWrite(#10);
  OutFlush;
  Result := 0;
end;

function luaB_warn(L: TLua): Integer;
var
  n, i: Integer;
begin
  n := LuaGetTop(L);
  CheckString(L, 1);
  for i := 2 to n do CheckString(L, i);
  for i := 1 to n - 1 do
    WarnMessage(L, CheckString(L, i), True);
  WarnMessage(L, CheckString(L, n), False);
  Result := 0;
end;

function luaB_tonumber(L: TLua): Integer;
var
  v: TLuaValue;
  base, i, d: Integer;
  s: RawByteString;
  n: Int64;
  neg, any: Boolean;
  iv: Int64;
  nv: Double;
begin
  if ArgIsNoneOrNil(L, 2) then
  begin
    v := LuaArg(L, 1);
    case v.Vt of
      vtInt, vtFlt: begin LuaPush(L, v); Exit(1); end;
      vtStr: begin
        if StrToIntVal(v.S.Str, iv) then begin PushInt(L, iv); Exit(1); end;
        if StrToNumVal(v.S.Str, nv) then begin PushNum(L, nv); Exit(1); end;
      end;
    else
      CheckAny(L, 1);
    end;
    PushFail(L);
    Exit(1);
  end;
  // with a base
  if LuaArg(L, 1).Vt <> vtStr then TypeErrorArg(L, 1, 'string');
  s := LuaArg(L, 1).S.Str;
  base := Integer(CheckInteger(L, 2));
  if (base < 2) or (base > 36) then ArgError(L, 2, 'base out of range');
  i := 1;
  while (i <= Length(s)) and (s[i] in [' ', #9, #10, #11, #12, #13]) do Inc(i);
  neg := False;
  if (i <= Length(s)) and (s[i] = '-') then begin neg := True; Inc(i); end
  else if (i <= Length(s)) and (s[i] = '+') then Inc(i);
  any := False;
  n := 0;
  while (i <= Length(s)) and (s[i] in ['0'..'9', 'a'..'z', 'A'..'Z']) do
  begin
    if s[i] in ['0'..'9'] then d := Ord(s[i]) - Ord('0')
    else d := Ord(UpCase(s[i])) - Ord('A') + 10;
    if d >= base then begin PushFail(L); Exit(1); end;
    n := Int64(QWord(n) * QWord(base) + QWord(d));
    any := True;
    Inc(i);
  end;
  while (i <= Length(s)) and (s[i] in [' ', #9, #10, #11, #12, #13]) do Inc(i);
  if (not any) or (i <= Length(s)) then
  begin
    PushFail(L);
    Exit(1);
  end;
  if neg then n := Int64(QWord(0) - QWord(n));
  PushInt(L, n);
  Result := 1;
end;

function luaB_tostring(L: TLua): Integer;
begin
  CheckAny(L, 1);
  PushStr(L, ToStringAux(L, LuaArg(L, 1)));
  Result := 1;
end;

function luaB_type(L: TLua): Integer;
begin
  CheckAny(L, 1);
  PushStr(L, RawByteString(VTypeName(LuaArg(L, 1))));
  Result := 1;
end;

function luaB_next(L: TLua): Integer;
var
  t: TTable;
  k, v: TLuaValue;
begin
  t := CheckTable(L, 1);
  k := LuaArg(L, 2);
  if TableNext(t, k, k, v) then
  begin
    LuaPush(L, k);
    LuaPush(L, v);
    Result := 2;
  end
  else
  begin
    PushNil(L);
    Result := 1;
  end;
end;

function luaB_pairs(L: TLua): Integer;
var
  tm: TLuaValue;
begin
  CheckAny(L, 1);
  tm := GetMetaField(L, LuaArg(L, 1), '__pairs');
  if tm.Vt = vtNil then
  begin
    LuaPush(L, LuaFunc(LightC(L, @luaB_next, 'next')));
    LuaPush(L, LuaArg(L, 1));
    PushNil(L);
    PushNil(L);
  end
  else
  begin
    LuaPush(L, tm);
    LuaPush(L, LuaArg(L, 1));
    LuaCallK(L, 1, 4);
  end;
  Result := 4;
end;

function ipairsaux(L: TLua): Integer;
var
  i: Int64;
  v: TLuaValue;
begin
  i := CheckInteger(L, 2) + 1;
  v := LuaIndex(L, LuaArg(L, 1), LuaInt(i));
  if v.Vt = vtNil then
  begin
    PushNil(L);
    Exit(1);
  end;
  PushInt(L, i);
  LuaPush(L, v);
  Result := 2;
end;

function luaB_ipairs(L: TLua): Integer;
begin
  CheckAny(L, 1);
  LuaPush(L, LuaFunc(LightC(L, @ipairsaux, 'ipairs_aux')));
  LuaPush(L, LuaArg(L, 1));
  PushInt(L, 0);
  Result := 3;
end;

function luaB_rawequal(L: TLua): Integer;
begin
  CheckAny(L, 1);
  CheckAny(L, 2);
  PushBool(L, RawEqual(LuaArg(L, 1), LuaArg(L, 2)));
  Result := 1;
end;

function luaB_rawlen(L: TLua): Integer;
var
  v: TLuaValue;
begin
  v := LuaArg(L, 1);
  case v.Vt of
    vtTab: PushInt(L, TableLength(v.T));
    vtStr: PushInt(L, v.S.Len);
  else
    ArgError(L, 1, 'table or string expected');
  end;
  Result := 1;
end;

function luaB_rawget(L: TLua): Integer;
var
  t: TTable;
begin
  t := CheckTable(L, 1);
  CheckAny(L, 2);
  LuaPush(L, TableGet(t, LuaArg(L, 2)));
  Result := 1;
end;

function luaB_rawset(L: TLua): Integer;
var
  t: TTable;
  k: TLuaValue;
begin
  t := CheckTable(L, 1);
  CheckAny(L, 2);
  CheckAny(L, 3);
  k := LuaArg(L, 2);
  if k.Vt = vtNil then raise ELuaError.CreateMsg('table index is nil');
  if (k.Vt = vtFlt) and IsNaN(k.N) then raise ELuaError.CreateMsg('table index is NaN');
  TableSet(t, k, LuaArg(L, 3));
  LuaPush(L, LuaArg(L, 1));
  Result := 1;
end;

function luaB_select(L: TLua): Integer;
var
  n, top: Int64;
  v: TLuaValue;
begin
  top := LuaGetTop(L);
  v := LuaArg(L, 1);
  if (v.Vt = vtStr) and (v.S.Len = 1) and (v.S.Str[1] = '#') then
  begin
    PushInt(L, top - 1);
    Exit(1);
  end;
  n := CheckInteger(L, 1);
  if n < 0 then n := top + n
  else if n > top then n := top;
  if n < 1 then ArgError(L, 1, 'index out of range');
  Result := Integer(top - n);
end;

function luaB_getmetatable(L: TLua): Integer;
var
  mt: TTable;
  f: TLuaValue;
begin
  CheckAny(L, 1);
  mt := GetMetatable(L, LuaArg(L, 1));
  if mt = nil then
  begin
    PushNil(L);
    Exit(1);
  end;
  f := TableGetStr(mt, StrKey(L, '__metatable'));
  if f.Vt <> vtNil then LuaPush(L, f) else LuaPush(L, LuaTab(mt));
  Result := 1;
end;

function luaB_setmetatable(L: TLua): Integer;
var
  t: TTable;
  v, mt: TLuaValue;
begin
  v := LuaArg(L, 1);
  if v.Vt <> vtTab then TypeErrorArg(L, 1, 'table');
  t := v.T;
  mt := LuaArg(L, 2);
  if not ((mt.Vt = vtNil) or (mt.Vt = vtTab)) or ArgIsNone(L, 2) then
    TypeErrorArg(L, 2, 'nil or table');
  if (t.Metatable <> nil) and (TableGetStr(t.Metatable, StrKey(L, '__metatable')).Vt <> vtNil) then
    LuaError(L, 'cannot change a protected metatable');
  if mt.Vt = vtNil then
    t.Metatable := nil
  else
  begin
    t.Metatable := mt.T;
    if TableGetStr(mt.T, TMName(TM_GC)).Vt <> vtNil then
      L.SetFinalizer(t);
  end;
  LuaPush(L, v);
  Result := 1;
end;

function luaB_assert(L: TLua): Integer;
var
  msg: TLuaValue;
begin
  if Truthy(LuaArg(L, 1)) then
    Exit(LuaGetTop(L));
  CheckAny(L, 1);
  if LuaGetTop(L) >= 2 then
    msg := LuaArg(L, 2)
  else
    msg := NewStr(L, 'assertion failed!');
  if msg.Vt = vtStr then
    LuaThrow(L, NewStr(L, ErrorPosition(L, 1) + msg.S.Str))
  else
    LuaThrow(L, msg);
  Result := 0;
end;

function luaB_error(L: TLua): Integer;
var
  level: Int64;
  v: TLuaValue;
begin
  level := OptInteger(L, 2, 1);
  v := LuaArg(L, 1);
  if (v.Vt = vtStr) and (level > 0) then
    v := NewStr(L, RawByteString(Where(L, Integer(level))) + v.S.Str);
  LuaThrow(L, v);
  Result := 0;
end;

function luaB_pcall(L: TLua): Integer;
var
  n, i, funcIdx, st: Integer;
  base: Integer;
begin
  CheckAny(L, 1);
  n := LuaGetTop(L);
  base := L.CI[L.NCI - 1].Base;
  // [true, f, args...] above the arguments
  L.EnsureStack(L.Top + n + 3);
  LuaPush(L, LuaBool(True));
  for i := 1 to n do LuaPush(L, LuaArg(L, i));
  funcIdx := L.Top - n;
  st := LuaProtectedCall(L, n - 1, -1, 0);
  if st <> 0 then
  begin
    L.Stack[funcIdx - 1] := LuaBool(False);
    Result := 2;
  end
  else
    Result := L.Top - (funcIdx - 1);
  if base < 0 then ;
end;

function luaB_xpcall(L: TLua): Integer;
var
  n, i, funcIdx, st, errIdx: Integer;
begin
  n := LuaGetTop(L);
  if (n < 2) or (LuaArg(L, 2).Vt <> vtFunc) then TypeErrorArg(L, 2, 'function');
  errIdx := LuaAbsIndex(L, 2);
  L.EnsureStack(L.Top + n + 3);
  LuaPush(L, LuaBool(True));
  LuaPush(L, LuaArg(L, 1));
  for i := 3 to n do LuaPush(L, LuaArg(L, i));
  funcIdx := L.Top - (n - 1);
  st := LuaProtectedCall(L, n - 2, -1, errIdx);
  if st <> 0 then
  begin
    L.Stack[funcIdx - 1] := LuaBool(False);
    Result := 2;
  end
  else
    Result := L.Top - (funcIdx - 1);
end;

function luaB_load(L: TLua): Integer;
var
  v: TLuaValue;
  chunk, src: RawByteString;
  name, mode, err: string;
  f: TFunction;
  piece: TLuaValue;
  r: Integer;
begin
  v := LuaArg(L, 1);
  mode := string(OptString(L, 3, 'bt'));
  if Pos('B', mode) > 0 then ArgError(L, 3, 'invalid mode');   // Lua code cannot use fixed buffers
  if v.Vt = vtStr then
  begin
    src := v.S.Str;
    name := string(OptString(L, 2, src));
  end
  else
  begin
    if v.Vt <> vtFunc then TypeErrorArg(L, 1, 'function');
    name := string(OptString(L, 2, '=(load)'));
    // read the chunk piece by piece
    src := '';
    while True do
    begin
      LuaPush(L, v);
      r := LuaProtectedCall(L, 0, 1, 0);
      if r <> 0 then
      begin
        err := string(ToStringAux(L, L.Stack[L.Top - 1]));
        PushNil(L);
        PushStr(L, RawByteString(err));
        Exit(2);
      end;
      piece := L.Stack[L.Top - 1];
      Dec(L.Top);
      if piece.Vt = vtNil then Break;
      if piece.Vt <> vtStr then
      begin
        PushNil(L);
        PushStr(L, 'reader function must return a string');
        Exit(2);
      end;
      if piece.S.Len = 0 then Break;
      src := src + piece.S.Str;
    end;
  end;
  if not LoadBuffer(L, src, name, mode, f, err) then
  begin
    PushNil(L);
    PushStr(L, RawByteString(err));
    Exit(2);
  end;
  if LuaGetTop(L) >= 4 then
    SetEnvUpvalue(L, f, LuaArg(L, 4))
  else
    SetEnvUpvalue(L, f, LuaTab(L.GlobalT));
  LuaPush(L, LuaFunc(f));
  Result := 1;
end;

function LoadFileInto(L: TLua; const fname, mode: string; var f: TFunction; var err: string): Boolean;
var
  content: RawByteString;
  stdinText: RawByteString;
  line: string;
begin
  Result := False;
  if fname = '' then
  begin
    // standard input
    stdinText := '';
    while not Eof(Input) do
    begin
      ReadLn(line);
      stdinText := stdinText + RawByteString(line) + #10;
    end;
    content := stdinText;
    PrepareFileChunk(content);
    Exit(LoadBuffer(L, content, '=stdin', mode, f, err));
  end;
  if not ReadFileContent(fname, content) then
  begin
    err := Format('cannot open %s', [fname]);
    if not FileExists(fname) then err := err + ': No such file or directory'
    else err := err + ': Permission denied';
    Exit;
  end;
  PrepareFileChunk(content);
  Result := LoadBuffer(L, content, '@' + fname, mode, f, err);
end;

function luaB_loadfile(L: TLua): Integer;
var
  fname, mode, err: string;
  f: TFunction;
begin
  if ArgIsNoneOrNil(L, 1) then fname := '' else fname := string(CheckString(L, 1));
  mode := string(OptString(L, 2, 'bt'));
  if Pos('B', mode) > 0 then ArgError(L, 2, 'invalid mode');
  if not LoadFileInto(L, fname, mode, f, err) then
  begin
    PushNil(L);
    PushStr(L, RawByteString(err));
    Exit(2);
  end;
  if LuaGetTop(L) >= 3 then
    SetEnvUpvalue(L, f, LuaArg(L, 3))
  else
    SetEnvUpvalue(L, f, LuaTab(L.GlobalT));
  LuaPush(L, LuaFunc(f));
  Result := 1;
end;

function luaB_dofile(L: TLua): Integer;
var
  fname, err: string;
  f: TFunction;
  base: Integer;
begin
  if ArgIsNoneOrNil(L, 1) then fname := '' else fname := string(CheckString(L, 1));
  base := LuaGetTop(L);
  if not LoadFileInto(L, fname, 'bt', f, err) then
    LuaThrow(L, NewStr(L, RawByteString(err)));
  SetEnvUpvalue(L, f, LuaTab(L.GlobalT));
  LuaSetTop(L, 0);
  LuaPush(L, LuaFunc(f));
  LuaCallK(L, 0, -1);
  Result := LuaGetTop(L);
  if base < 0 then ;
end;

function luaB_collectgarbage(L: TLua): Integer;
const
  Opts: array[0..8] of string = ('stop', 'restart', 'collect', 'count', 'step',
    'isrunning', 'generational', 'incremental', 'param');
  Params: array[0..5] of string = ('minormul', 'majorminor', 'minormajor',
    'pause', 'stepmul', 'stepsize');
var
  o, p: Integer;
  old: string;
  value: Int64;
  m: TLua;
begin
  m := L.Main;
  o := CheckOption(L, 1, 'collect', Opts);
  case o of
    0: begin m.GCStopped := True; PushInt(L, 0); end;
    1: begin m.GCStopped := False; PushInt(L, 0); end;
    2: begin
      if m.InGC then PushFail(L)   // the collector is not reentrant (inside a finalizer)
      else
      begin
        m.FullGC;
        PushInt(L, 0);
      end;
    end;
    3: PushNum(L, m.TotalBytes / 1024.0);
    4: begin
      if m.InGC then PushFail(L)
      else if m.GCMode = 'generational' then
      begin
        m.FullGC;   // a step is a (young) collection: always completes a cycle
        PushBool(L, True);
      end
      else PushBool(L, m.GCStep(Integer(OptInteger(L, 2, 0))));
    end;
    5: PushBool(L, not m.GCStopped);
    6, 7: begin
      old := m.GCMode;
      if o = 6 then m.GCMode := 'generational' else m.GCMode := 'incremental';
      PushStr(L, RawByteString(old));
    end;
    8: begin
      p := CheckOption(L, 2, '', Params);
      value := OptInteger(L, 3, -1);
      case p of
        3: begin PushInt(L, m.GCPause); if value >= 0 then m.GCPause := Integer(value); end;
        4: begin PushInt(L, m.GCStepMul); if value >= 0 then m.GCStepMul := Integer(value); end;
        5: begin PushInt(L, m.GCStepSize); if value >= 0 then m.GCStepSize := Integer(value); end;
      else
        PushInt(L, 0);
      end;
    end;
  end;
  Result := 1;
end;

procedure OpenBase(L: TLua);
const
  Funcs: array[0..22] of TLibFunc = (
    (Name: 'assert'; Func: @luaB_assert),
    (Name: 'collectgarbage'; Func: @luaB_collectgarbage),
    (Name: 'dofile'; Func: @luaB_dofile),
    (Name: 'error'; Func: @luaB_error),
    (Name: 'getmetatable'; Func: @luaB_getmetatable),
    (Name: 'ipairs'; Func: @luaB_ipairs),
    (Name: 'loadfile'; Func: @luaB_loadfile),
    (Name: 'load'; Func: @luaB_load),
    (Name: 'next'; Func: @luaB_next),
    (Name: 'pairs'; Func: @luaB_pairs),
    (Name: 'pcall'; Func: @luaB_pcall),
    (Name: 'print'; Func: @luaB_print),
    (Name: 'warn'; Func: @luaB_warn),
    (Name: 'rawequal'; Func: @luaB_rawequal),
    (Name: 'rawlen'; Func: @luaB_rawlen),
    (Name: 'rawget'; Func: @luaB_rawget),
    (Name: 'rawset'; Func: @luaB_rawset),
    (Name: 'select'; Func: @luaB_select),
    (Name: 'setmetatable'; Func: @luaB_setmetatable),
    (Name: 'tonumber'; Func: @luaB_tonumber),
    (Name: 'tostring'; Func: @luaB_tostring),
    (Name: 'type'; Func: @luaB_type),
    (Name: 'xpcall'; Func: @luaB_xpcall));
begin
  RegisterFuncs(L, L.GlobalT, Funcs);
  L.Main.WarnProc := @WarnMessage;
  SetField(L, L.GlobalT, '_G', LuaTab(L.GlobalT));
  SetField(L, L.GlobalT, '_VERSION', NewStr(L, 'Lua 5.5'));
  SetLoaded(L, '_G', LuaTab(L.GlobalT));
end;

end.
