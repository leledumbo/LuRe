unit lualibdbg;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// The debug library.

interface

uses
  SysUtils, Math, luacore, luavm, luaaux, lualibbase;

procedure OpenDebug(L: TLua);

// "stack traceback:" text for thread L1 starting at 'level'
function Traceback(L, L1: TLua; const msg: RawByteString; hasMsg: Boolean; level: Integer): RawByteString;

implementation

const
  LEVELS1 = 10;
  LEVELS2 = 11;

type
  TFrameInfo = record
    ShortSrc: string;
    Source: string;
    CurrentLine: Integer;
    LineDefined: Integer;
    LastLine: Integer;
    What: string;
    Name: string;
    NameWhat: string;
    IsTail: Boolean;
    Func: TFunction;
  end;

procedure FillFrame(L1: TLua; ciIdx: Integer; f: TFunction; var fi: TFrameInfo);
var
  p: TProto;
begin
  fi.Func := f;
  fi.Name := '';
  fi.NameWhat := '';
  fi.IsTail := False;
  fi.CurrentLine := -1;
  if f.IsC then
  begin
    fi.ShortSrc := '[C]';
    fi.Source := '=[C]';
    fi.LineDefined := -1;
    fi.LastLine := -1;
    fi.What := 'C';
  end
  else
  begin
    p := f.Proto;
    if p.Source = nil then
    begin
      fi.Source := '=?';
      fi.ShortSrc := '?';
    end
    else
    begin
      fi.Source := string(p.Source.Str);
      fi.ShortSrc := ChunkIdStr(fi.Source);
    end;
    fi.LineDefined := p.LineDefined;
    fi.LastLine := p.LastLineDefined;
    if p.LineDefined = 0 then fi.What := 'main' else fi.What := 'Lua';
  end;
  if ciIdx >= 0 then
  begin
    if not f.IsC then fi.CurrentLine := ci_CurrentLine(L1.CI[ciIdx]);
    fi.IsTail := L1.CI[ciIdx].IsTail;
    fi.NameWhat := FuncNameFromCall(L1, ciIdx, fi.Name);
  end;
end;

function PushGlobalName(L: TLua; f: TFunction): string;
begin
  Result := GlobalFuncName(L, f);
end;

function FuncNameText(L: TLua; const fi: TFrameInfo): string;
var
  g: string;
begin
  if fi.NameWhat <> '' then
    Exit(Format('%s ''%s''', [fi.NameWhat, fi.Name]));
  if fi.What = 'main' then Exit('main chunk');
  g := PushGlobalName(L, fi.Func);
  if g <> '' then Exit(Format('function ''%s''', [g]));
  if fi.What <> 'C' then
    Result := Format('function <%s:%d>', [fi.ShortSrc, fi.LineDefined])
  else
    Result := '?';
end;

function Traceback(L, L1: TLua; const msg: RawByteString; hasMsg: Boolean; level: Integer): RawByteString;
var
  last, limit2show, idx, n: Integer;
  fi: TFrameInfo;
  s: string;
begin
  last := L1.NCI - 1;       // highest valid level
  if last - level > LEVELS1 + LEVELS2 then limit2show := LEVELS1 else limit2show := -1;
  if hasMsg then Result := msg + #10 else Result := '';
  Result := Result + 'stack traceback:';
  while level <= last do
  begin
    idx := L1.NCI - 1 - level;
    Inc(level);
    if limit2show = 0 then
    begin
      n := last - level - LEVELS2 + 1;
      Result := Result + RawByteString(Format(#10#9'...'#9'(skipping %d levels)', [n]));
      Inc(level, n);
      Dec(limit2show);
      Continue;
    end;
    Dec(limit2show);
    FillFrame(L1, idx, L1.CI[idx].Func, fi);
    if fi.CurrentLine <= 0 then
      s := Format(#10#9'%s: in ', [fi.ShortSrc])
    else
      s := Format(#10#9'%s:%d: in ', [fi.ShortSrc, fi.CurrentLine]);
    s := s + FuncNameText(L, fi);
    Result := Result + RawByteString(s);
    if fi.IsTail then Result := Result + #10#9'(...tail calls...)';
  end;
end;

{ ------------------------------------------------------------------ }

// the thread argument: if the first argument is a thread, it is used
function GetThread(L: TLua; var arg: Integer): TLua;
var
  v: TLuaValue;
begin
  v := LuaArg(L, 1);
  if v.Vt = vtThread then
  begin
    arg := 1;
    Result := TLua(v.Th);
  end
  else
  begin
    arg := 0;
    Result := L;
  end;
end;

function db_getregistry(L: TLua): Integer;
begin
  LuaPush(L, LuaTab(L.Registry));
  Result := 1;
end;

function db_getmetatable(L: TLua): Integer;
var
  mt: TTable;
begin
  CheckAny(L, 1);
  mt := GetMetatable(L, LuaArg(L, 1));
  if mt = nil then PushNil(L) else LuaPush(L, LuaTab(mt));
  Result := 1;
end;

function db_setmetatable(L: TLua): Integer;
var
  v, mt: TLuaValue;
  t: TTable;
begin
  v := LuaArg(L, 1);
  mt := LuaArg(L, 2);
  if not ((mt.Vt = vtNil) or (mt.Vt = vtTab)) or ArgIsNone(L, 2) then
    TypeErrorArg(L, 2, 'nil or table');
  if mt.Vt = vtNil then t := nil else t := mt.T;
  case v.Vt of
    vtTab: begin
      v.T.Metatable := t;
      if (t <> nil) and (TableGetStr(t, TMName(TM_GC)).Vt <> vtNil) then L.SetFinalizer(v.T);
    end;
    vtUser: begin
      v.U.Metatable := t;
      if (t <> nil) and (TableGetStr(t, TMName(TM_GC)).Vt <> vtNil) then L.SetFinalizer(v.U);
    end;
  else
    L.Main.TypeMeta[v.Vt] := t;
    if v.Vt = vtInt then L.Main.TypeMeta[vtFlt] := t;
    if v.Vt = vtFlt then L.Main.TypeMeta[vtInt] := t;
  end;
  LuaPush(L, v);
  Result := 1;
end;

function db_getuservalue(L: TLua): Integer;
var
  v: TLuaValue;
  n: Int64;
begin
  v := LuaArg(L, 1);
  n := OptInteger(L, 2, 1);
  if (v.Vt <> vtUser) or (n < 1) or (n > v.U.NUserValues) then
  begin
    PushFail(L);
    Exit(1);
  end;
  LuaPush(L, v.U.UsrValue);
  PushBool(L, True);
  Result := 2;
end;

function db_setuservalue(L: TLua): Integer;
var
  v: TLuaValue;
  n: Int64;
begin
  v := LuaArg(L, 1);
  if v.Vt <> vtUser then TypeErrorArg(L, 1, 'userdata');
  CheckAny(L, 2);
  n := OptInteger(L, 3, 1);
  if (n < 1) or (n > v.U.NUserValues) then
  begin
    PushFail(L);
    Exit(1);
  end;
  v.U.UsrValue := LuaArg(L, 2);
  LuaPush(L, v);
  Result := 1;
end;

{ ------------------------------------------------------------------ }
{ getinfo                                                             }
{ ------------------------------------------------------------------ }

function db_getinfo(L: TLua): Integer;
var
  arg, ciIdx, ciSaved, i, ln: Integer;
  L1: TLua;
  options: string;
  v: TLuaValue;
  f: TFunction;
  fi: TFrameInfo;
  t, lines: TTable;
  p: TProto;
  level: Int64;
begin
  L1 := GetThread(L, arg);
  options := string(OptString(L, arg + 2, 'flnSrtu'));
  if (options <> '') and (options[1] = '>') then
    ArgError(L, arg + 2, 'invalid option ''>''');
  for i := 1 to Length(options) do
    if not (options[i] in ['S', 'l', 'n', 'r', 't', 'u', 'L', 'f']) then
      ArgError(L, arg + 2, 'invalid option');
  v := LuaArg(L, arg + 1);
  if v.Vt = vtFunc then
  begin
    f := v.F;
    ciIdx := -1;
  end
  else
  begin
    level := CheckInteger(L, arg + 1);
    if (level < 0) or (level >= L1.NCI) then
    begin
      PushFail(L);
      Exit(1);
    end;
    ciIdx := L1.NCI - 1 - Integer(level);
    f := L1.CI[ciIdx].Func;
  end;
  ciSaved := ciIdx;
  FillFrame(L1, ciIdx, f, fi);
  t := L.NewTable(0, 12);
  LuaPush(L, LuaTab(t));
  for i := 1 to Length(options) do
    case options[i] of
      'S': begin
        SetField(L, t, 'source', NewStr(L, RawByteString(fi.Source)));
        SetField(L, t, 'short_src', NewStr(L, RawByteString(fi.ShortSrc)));
        SetField(L, t, 'linedefined', LuaInt(fi.LineDefined));
        SetField(L, t, 'lastlinedefined', LuaInt(fi.LastLine));
        SetField(L, t, 'what', NewStr(L, RawByteString(fi.What)));
      end;
      'l': SetField(L, t, 'currentline', LuaInt(fi.CurrentLine));
      'u': begin
        if f.IsC then
        begin
          SetField(L, t, 'nups', LuaInt(Length(f.CVals)));
          SetField(L, t, 'nparams', LuaInt(0));
          SetField(L, t, 'isvararg', LuaBool(True));
        end
        else
        begin
          SetField(L, t, 'nups', LuaInt(Length(f.Upvals)));
          SetField(L, t, 'nparams', LuaInt(f.Proto.NumParams));
          SetField(L, t, 'isvararg', LuaBool(f.Proto.IsVararg));
        end;
      end;
      'n': begin
        if fi.NameWhat <> '' then
          SetField(L, t, 'name', NewStr(L, RawByteString(fi.Name)));
        SetField(L, t, 'namewhat', NewStr(L, RawByteString(fi.NameWhat)));
      end;
      'r': begin
        if (ciIdx >= 0) and (ciIdx < L1.NCI) then
        begin
          SetField(L, t, 'ftransfer', LuaInt(L1.CI[ciIdx].FTransfer));
          SetField(L, t, 'ntransfer', LuaInt(L1.CI[ciIdx].NTransfer));
        end
        else
        begin
          SetField(L, t, 'ftransfer', LuaInt(0));
          SetField(L, t, 'ntransfer', LuaInt(0));
        end;
      end;
      't': begin
        SetField(L, t, 'istailcall', LuaBool(fi.IsTail));
        if ciSaved >= 0 then
          SetField(L, t, 'extraargs', LuaInt(L1.CI[ciSaved].ExtraArgs))
        else
          SetField(L, t, 'extraargs', LuaInt(0));
      end;
      'L': begin
        if not f.IsC then
        begin
          p := f.Proto;
          lines := L.NewTable(0, 8);
          for ln := 0 to Length(p.LineInfo) - 1 do
            TableSetInt(lines, p.LineInfo[ln], LuaBool(True));
          SetField(L, t, 'activelines', LuaTab(lines));
        end;
      end;
      'f': SetField(L, t, 'func', LuaFunc(f));
    end;
  Result := 1;
end;

{ ------------------------------------------------------------------ }
{ locals                                                              }
{ ------------------------------------------------------------------ }

// finds local 'n' of the frame at ciIdx; returns its name and stack index
function FindLocal(L1: TLua; ciIdx, n: Integer; var stackIdx: Integer): string;
var
  ci: TCallInfo;
  limit, nextra: Integer;
begin
  Result := '';
  ci := L1.CI[ciIdx];
  if not ci.IsC then
  begin
    if n < 0 then
    begin
      nextra := ci.NExtra;
      if (-n <= nextra) and ci.Func.Proto.IsVararg then
      begin
        stackIdx := ci.Base - nextra + (-n - 1);
        Exit('(vararg)');
      end;
      Exit('');
    end;
    Result := LocalNameAt(ci.Func.Proto, n, ci.SavedPC - 1);
    if Result <> '' then
    begin
      stackIdx := ci.Base + n - 1;
      Exit;
    end;
  end;
  if n <= 0 then Exit('');
  if ciIdx = L1.NCI - 1 then limit := L1.Top
  else limit := L1.CI[ciIdx + 1].FuncIdx;
  if (limit - ci.Base >= n) then
  begin
    if ci.IsC then Result := '(C temporary)' else Result := '(temporary)';
    stackIdx := ci.Base + n - 1;
  end;
end;

function db_getlocal(L: TLua): Integer;
var
  arg, ciIdx, stackIdx, n: Integer;
  L1: TLua;
  v: TLuaValue;
  level: Int64;
  name: string;
begin
  L1 := GetThread(L, arg);
  n := Integer(CheckInteger(L, arg + 2));
  v := LuaArg(L, arg + 1);
  if v.Vt = vtFunc then
  begin
    // only parameter names
    if v.F.IsC then PushNil(L)
    else
    begin
      if (n >= 1) and (n <= v.F.Proto.NumParams) then name := LocalNameAt(v.F.Proto, n, 0) else name := '';
      if name = '' then PushNil(L) else PushStr(L, RawByteString(name));
    end;
    Exit(1);
  end;
  level := CheckInteger(L, arg + 1);
  if (level < 0) or (level >= L1.NCI) then
    ArgError(L, arg + 1, 'level out of range');
  ciIdx := L1.NCI - 1 - Integer(level);
  stackIdx := 0;
  name := FindLocal(L1, ciIdx, n, stackIdx);
  if name = '' then
  begin
    PushFail(L);
    Exit(1);
  end;
  PushStr(L, RawByteString(name));
  LuaPush(L, L1.Stack[stackIdx]);
  Result := 2;
end;

function db_setlocal(L: TLua): Integer;
var
  arg, ciIdx, stackIdx, n: Integer;
  L1: TLua;
  level: Int64;
  name: string;
begin
  L1 := GetThread(L, arg);
  level := CheckInteger(L, arg + 1);
  n := Integer(CheckInteger(L, arg + 2));
  CheckAny(L, arg + 3);
  if (level < 0) or (level >= L1.NCI) then
    ArgError(L, arg + 1, 'level out of range');
  ciIdx := L1.NCI - 1 - Integer(level);
  stackIdx := 0;
  name := FindLocal(L1, ciIdx, n, stackIdx);
  if name = '' then
  begin
    PushFail(L);
    Exit(1);
  end;
  L1.Stack[stackIdx] := LuaArg(L, arg + 3);
  PushStr(L, RawByteString(name));
  Result := 1;
end;

{ ------------------------------------------------------------------ }
{ upvalues                                                            }
{ ------------------------------------------------------------------ }

// name of an upvalue as shown by getupvalue/setupvalue
function DbgUpvalName(p: TProto; idx: Integer): string;
begin
  if (idx >= 0) and (idx < Length(p.UpvalDescs)) and (p.UpvalDescs[idx].Name <> nil) then
    Result := string(p.UpvalDescs[idx].Name.Str)
  else
    Result := '(no name)';
end;

function db_getupvalue(L: TLua): Integer;
var
  f: TFunction;
  n: Int64;
begin
  f := CheckFunction(L, 1);
  n := CheckInteger(L, 2);
  if f.IsC then
  begin
    if (n < 1) or (n > Length(f.CVals)) then Exit(0);
    PushStr(L, '');
    LuaPush(L, f.CVals[n - 1]);
  end
  else
  begin
    if (n < 1) or (n > Length(f.Upvals)) then Exit(0);
    PushStr(L, RawByteString(DbgUpvalName(f.Proto, Integer(n) - 1)));
    LuaPush(L, f.Upvals[n - 1].Get);
  end;
  Result := 2;
end;

function db_setupvalue(L: TLua): Integer;
var
  f: TFunction;
  n: Int64;
begin
  CheckAny(L, 3);
  f := CheckFunction(L, 1);
  n := CheckInteger(L, 2);
  if f.IsC then
  begin
    if (n < 1) or (n > Length(f.CVals)) then Exit(0);
    f.CVals[n - 1] := LuaArg(L, 3);
    PushStr(L, '');
  end
  else
  begin
    if (n < 1) or (n > Length(f.Upvals)) then Exit(0);
    f.Upvals[n - 1].SetVal(LuaArg(L, 3));
    PushStr(L, RawByteString(DbgUpvalName(f.Proto, Integer(n) - 1)));
  end;
  Result := 1;
end;

function CheckUpval(L: TLua; argf, argn: Integer; var nup: Integer): TFunction;
var
  n: Int64;
begin
  Result := CheckFunction(L, argf);
  n := CheckInteger(L, argn);
  if Result.IsC then
  begin
    if (n < 1) or (n > Length(Result.CVals)) then ArgError(L, argn, 'invalid upvalue index');
  end
  else if (n < 1) or (n > Length(Result.Upvals)) then
    ArgError(L, argn, 'invalid upvalue index');
  nup := Integer(n);
end;

function db_upvalueid(L: TLua): Integer;
var
  f: TFunction;
  n: Integer;
begin
  f := CheckFunction(L, 1);
  n := Integer(CheckInteger(L, 2));
  if f.IsC then
  begin
    if (n < 1) or (n > Length(f.CVals)) then begin PushFail(L); Exit(1); end;
    LuaPush(L, LuaLight(@f.CVals[n - 1]));
  end
  else
  begin
    if (n < 1) or (n > Length(f.Upvals)) then begin PushFail(L); Exit(1); end;
    LuaPush(L, LuaLight(Pointer(f.Upvals[n - 1])));
  end;
  Result := 1;
end;

function db_upvaluejoin(L: TLua): Integer;
var
  f1, f2: TFunction;
  n1, n2: Integer;
begin
  f1 := CheckUpval(L, 1, 2, n1);
  f2 := CheckUpval(L, 3, 4, n2);
  if f1.IsC then ArgError(L, 1, 'Lua function expected');
  if f2.IsC then ArgError(L, 3, 'Lua function expected');
  f1.Upvals[n1 - 1] := f2.Upvals[n2 - 1];
  Result := 0;
end;

{ ------------------------------------------------------------------ }
{ hooks                                                               }
{ ------------------------------------------------------------------ }

function db_sethook(L: TLua): Integer;
var
  arg, mask, count: Integer;
  L1: TLua;
  smask: string;
  func: TLuaValue;
begin
  L1 := GetThread(L, arg);
  if ArgIsNoneOrNil(L, arg + 1) then
  begin
    SetHookState(L1, LuaNil, 0, 0);
    Exit(0);
  end;
  func := LuaArg(L, arg + 1);
  if func.Vt <> vtFunc then TypeErrorArg(L, arg + 1, 'function');
  smask := string(CheckString(L, arg + 2));
  count := Integer(OptInteger(L, arg + 3, 0));
  mask := 0;
  if Pos('c', smask) > 0 then mask := mask or HOOK_CALL;
  if Pos('r', smask) > 0 then mask := mask or HOOK_RET;
  if Pos('l', smask) > 0 then mask := mask or HOOK_LINE;
  if count > 0 then mask := mask or HOOK_COUNT;
  SetHookState(L1, func, mask, count);
  Result := 0;
end;

function db_gethook(L: TLua): Integer;
var
  arg: Integer;
  L1: TLua;
  s: string;
begin
  L1 := GetThread(L, arg);
  if (L1.HookMask = 0) or (L1.HookFunc.Vt <> vtFunc) then
  begin
    PushFail(L);
    PushStr(L, '');
    PushInt(L, 0);
    Exit(3);
  end;
  LuaPush(L, L1.HookFunc);
  s := '';
  if (L1.HookMask and HOOK_CALL) <> 0 then s := s + 'c';
  if (L1.HookMask and HOOK_RET) <> 0 then s := s + 'r';
  if (L1.HookMask and HOOK_LINE) <> 0 then s := s + 'l';
  PushStr(L, RawByteString(s));
  PushInt(L, L1.HookCount);
  Result := 3;
end;

function db_traceback(L: TLua): Integer;
var
  arg: Integer;
  L1: TLua;
  v: TLuaValue;
  level: Int64;
  def: Integer;
begin
  L1 := GetThread(L, arg);
  v := LuaArg(L, arg + 1);
  if (v.Vt <> vtStr) and not (v.Vt in [vtInt, vtFlt]) and (v.Vt <> vtNil) then
  begin
    LuaPush(L, v);
    Exit(1);
  end;
  if L1 = L then def := 1 else def := 0;
  level := OptInteger(L, arg + 2, def);
  if v.Vt = vtNil then
    PushStr(L, Traceback(L, L1, '', False, Integer(level)))
  else
  begin
    if v.Vt <> vtStr then v := NewStr(L, RawByteString(NumToStr(v)));
    PushStr(L, Traceback(L, L1, v.S.Str, True, Integer(level)));
  end;
  Result := 1;
end;

function db_setcstacklimit(L: TLua): Integer;
begin
  PushInt(L, 200);
  Result := 1;
end;

function c_fgets(buf: PChar; n: Integer; stream: Pointer): PChar; cdecl; external 'c' name 'fgets';
function c_fputs(s: PChar; stream: Pointer): Integer; cdecl; external 'c' name 'fputs';
function c_fflush(stream: Pointer): Integer; cdecl; external 'c' name 'fflush';
var
  c_stderr: Pointer; external name 'stderr';
  c_stdin: Pointer; external name 'stdin';

procedure ErrWrite(const s: string);
begin
  c_fputs(PChar(s), c_stderr);
  c_fflush(c_stderr);
end;

function db_debug(L: TLua): Integer;
var
  buf: array[0..1023] of Char;
  line: string;
  f: TFunction;
  err: string;
  st: Integer;
begin
  while True do
  begin
    ErrWrite('lua_debug> ');
    if c_fgets(@buf[0], SizeOf(buf), c_stdin) = nil then Break;
    line := StrPas(PChar(@buf[0]));
    if (Length(line) > 0) and (line[Length(line)] = #10) then SetLength(line, Length(line) - 1);
    if line = 'cont' then Break;
    if LoadBuffer(L, RawByteString(line), '=(debug command)', 't', f, err) then
    begin
      SetEnvUpvalue(L, f, LuaTab(L.GlobalT));
      LuaPush(L, LuaFunc(f));
      st := LuaProtectedCall(L, 0, 0, 0);
      if st <> 0 then
      begin
        ErrWrite(string(ToStringAux(L, L.Stack[L.Top - 1])) + #10);
        Dec(L.Top);
      end;
    end
    else
      ErrWrite(err + #10);
  end;
  Result := 0;
end;

procedure OpenDebug(L: TLua);
const
  Funcs: array[0..16] of TLibFunc = (
    (Name: 'debug'; Func: @db_debug),
    (Name: 'getuservalue'; Func: @db_getuservalue),
    (Name: 'gethook'; Func: @db_gethook),
    (Name: 'getinfo'; Func: @db_getinfo),
    (Name: 'getlocal'; Func: @db_getlocal),
    (Name: 'getregistry'; Func: @db_getregistry),
    (Name: 'getmetatable'; Func: @db_getmetatable),
    (Name: 'getupvalue'; Func: @db_getupvalue),
    (Name: 'upvaluejoin'; Func: @db_upvaluejoin),
    (Name: 'upvalueid'; Func: @db_upvalueid),
    (Name: 'setuservalue'; Func: @db_setuservalue),
    (Name: 'sethook'; Func: @db_sethook),
    (Name: 'setlocal'; Func: @db_setlocal),
    (Name: 'setmetatable'; Func: @db_setmetatable),
    (Name: 'setupvalue'; Func: @db_setupvalue),
    (Name: 'traceback'; Func: @db_traceback),
    (Name: 'setcstacklimit'; Func: @db_setcstacklimit));
var
  hooks, mt: TTable;
begin
  NewLib(L, 'debug', Funcs);
  // registry._HOOKKEY: table with weak keys (hook functions are kept per thread)
  hooks := L.NewTable(0, 0);
  mt := L.NewTable(0, 1);
  TableSetStr(mt, TMName(TM_MODE), LuaStr(L.NewString('k')));
  hooks.Metatable := mt;
  TableSetStr(L.Registry, L.NewString('_HOOKKEY'), LuaTab(hooks));
end;

end.
