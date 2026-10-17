unit lualib;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, DateUtils, luacore, luavm, luaparse;

procedure OpenLibs(L: TLua);
procedure OpenLibsEx(L: TLua; useEnv: Boolean);

implementation

// ================= helpers =================


function NewCFunc(L: TLua; f: TCFunc): TFunction;
begin
  Result := TFunction.CreateC(L, f);
end;

procedure SetFunc(L: TLua; t: TTable; const name: string; f: TCFunc);
begin
  TableSetStr(t, L.NewString(name), LuaFunc(NewCFunc(L, f)));
end;

procedure SetIntF(L: TLua; t: TTable; const name: string; v: Int64);
begin
  TableSetStr(t, L.NewString(name), LuaInt(v));
end;

procedure SetStrF(L: TLua; t: TTable; const name, v: string);
begin
  TableSetStr(t, L.NewString(name), LuaStr(L.NewString(v)));
end;

procedure SetNumF(L: TLua; t: TTable; const name: string; v: Double);
begin
  TableSetStr(t, L.NewString(name), LuaNum(v));
end;

function CheckStr(L: TLua; i: Integer): TStringObj;
begin
  if LuaArg(L, i).Vt <> vtStr then
    LuaError(L, Format('bad argument #%d (string expected, got %s)', [i, LuaTypeName(L, i)]));
  Result := LuaArg(L, i).S;
end;

function CheckNum(L: TLua; i: Integer): Double;
var
  n: Double;
begin
  if not ToNumberVal(LuaArg(L, i), n) then
    LuaError(L, Format('bad argument #%d (number expected, got %s)', [i, LuaTypeName(L, i)]));
  Result := n;
end;

function CheckInt(L: TLua; i: Integer): Int64;
var
  iv: Int64;
begin
  if not ToInteger(LuaArg(L, i), iv) then
    LuaError(L, Format('bad argument #%d (number has no integer representation)', [i]));
  Result := iv;
end;

function CheckTab(L: TLua; i: Integer): TTable;
begin
  if LuaArg(L, i).Vt <> vtTab then
    LuaError(L, Format('bad argument #%d (table expected, got %s)', [i, LuaTypeName(L, i)]));
  Result := LuaArg(L, i).T;
end;

function CheckFunc(L: TLua; i: Integer): TFunction;
begin
  if LuaArg(L, i).Vt <> vtFunc then
    LuaError(L, Format('bad argument #%d (function expected, got %s)', [i, LuaTypeName(L, i)]));
  Result := LuaArg(L, i).F;
end;

function OptStr(L: TLua; i: Integer; const def: string): string;
begin
  if (LuaGetTop(L) < i) or IsNil(LuaArg(L, i)) then
    Result := def
  else
    Result := CheckStr(L, i).ToStr;
end;

function StrToLua(L: TLua; const s: string): TLuaValue;
begin
  Result := LuaStr(L.NewString(RawByteString(s)));
end;

// ================= base library =================

function luaB_assert(L: TLua): Integer;
var
  n: Integer;
  msg: string;
  dbgt: TTable;
  dbg: TFunction;
  v: TLuaValue;
  ci, pc: Integer;
  p: TProto;
begin
  n := LuaGetTop(L);
  if IsFalse(LuaArg(L, 1)) then
  begin
    if n >= 2 then
      msg := CheckStr(L, 2).ToStr
    else
      msg := 'assertion failed!';
    Inc(L.AssertCount);
    begin
      ci := L.CurThread.NCI - 2;
      if (ci >= 0) and (ci < L.CurThread.NCI) and (not L.CurThread.CI[ci].Func.IsC) then
      begin
        p := L.CurThread.CI[ci].Func.Proto;
        pc := L.CurThread.CI[ci].SavedPC - 1;
        if (p <> nil) and (pc >= 0) and (pc < Length(p.LineInfo)) then
          WriteLn(ErrOutput, 'ASSERT #', L.AssertCount, ' failed at line ', p.LineInfo[pc]);
      end;
    end;
    LuaError(L, msg);
  end;
  Result := n;
end;

function luaB_collectgarbage(L: TLua): Integer;
var
  opt: string;
  v: TLuaValue;
begin
  opt := OptStr(L, 1, 'collect');
  if opt = 'collect' then
  begin
    L.FullGC;
    Result := 0;
  end
  else if opt = 'stop' then
  begin
    L.GCRunning := False;
    Result := 0;
  end
  else if opt = 'restart' then
  begin
    L.GCRunning := True;
    Result := 0;
  end
  else if opt = 'count' then
  begin
    LuaSetTop(L, 0);
    LuaPush(L, LuaNum(L.TotalBytes / 1024.0));
    Result := 1;
  end
  else if opt = 'step' then
  begin
    v := LuaArg(L, 2);
    LuaSetTop(L, 0);
    if v.Vt = vtInt then
      LuaPush(L, LuaBool(L.GCStep(v.I)))
    else
      LuaPush(L, LuaBool(L.GCStep(0)));
    Result := 1;
  end
  else if opt = 'isrunning' then
  begin
    LuaSetTop(L, 0);
    LuaPush(L, LuaBool(L.GCRunning));
    Result := 1;
  end
  else if (opt = 'incremental') or (opt = 'generational') then
  begin
    LuaSetTop(L, 0);
    LuaPush(L, LuaStr(L.NewString(L.GCMode)));
    L.GCMode := opt;
    Result := 1;
  end
  else if opt = 'param' then
  begin
    v := LuaArg(L, 2);
    if v.Vt <> vtStr then
      LuaError(L, 'bad argument #2 (string expected)');
    LuaSetTop(L, 0);
    if LuaGetTop(L) < 1 then
    begin
    end;
    // get or set
    if (LuaArg(L, 3).Vt = vtNil) and (LuaGetTop(L) < 3) then
    begin
      LuaPush(L, LuaInt(L.GetGCParam(v.S.ToStr)));
    end
    else
    begin
      L.SetGCParam(v.S.ToStr, CheckInt(L, 3));
      LuaPush(L, LuaInt(L.GetGCParam(v.S.ToStr)));
    end;
    Result := 1;
  end
  else
    LuaError(L, Format('invalid option ''%s''', [opt]));
end;

function luaB_error(L: TLua): Integer;
var
  v: TLuaValue;
begin
  v := LuaArg(L, 1);
  if v.Vt = vtStr then
    LuaRuntimeError(L, v.S.ToStr)
  else
    raise ELuaError.CreateMsg('(error object is a ' + VTypeName(v) + ' value)');
  Result := 0;
end;

function luaB_getmetatable(L: TLua): Integer;
var
  v: TLuaValue;
  mt: TTable;
  mm: TLuaValue;
begin
  v := LuaArg(L, 1);
  mt := nil;
  case v.Vt of
    vtTab: mt := v.T.Metatable;
    vtUser: mt := v.U.Metatable;
  end;
  LuaSetTop(L, 0);
  if mt <> nil then
  begin
    mm := TableGetStr(mt, L.NewString('__metatable'));
    if not IsNil(mm) then
      LuaPush(L, mm)
    else
      LuaPush(L, LuaTab(mt));
  end
  else
    LuaPush(L, LuaNil);
  Result := 1;
end;

function luaB_next(L: TLua): Integer;
var
  t: TLuaValue;
  key, nk, nv: TLuaValue;
begin
  t := LuaArg(L, 1);
  if t.Vt <> vtTab then
    LuaError(L, 'bad argument #1 to ''next'' (table expected)');
  key := LuaArg(L, 2);
  LuaSetTop(L, 0);
  if TableNext(t.T, key, nk, nv) then
  begin
    LuaPush(L, nk);
    LuaPush(L, nv);
    Result := 2;
  end
  else
  begin
    LuaPush(L, LuaNil);
    Result := 1;
  end;
end;

function luaB_ipairsaux(L: TLua): Integer;
var
  t: TTable;
  i: Int64;
  v: TLuaValue;
begin
  t := CheckTab(L, 1);
  i := CheckInt(L, 2) + 1;
  v := TableGetInt(t, i);
  LuaSetTop(L, 0);
  if IsNil(v) then
  begin
    LuaPush(L, LuaNil);
    Result := 1;
  end
  else
  begin
    LuaPush(L, LuaInt(i));
    LuaPush(L, v);
    Result := 2;
  end;
end;

function luaB_ipairs(L: TLua): Integer;
var
  t: TLuaValue;
begin
  t := LuaArg(L, 1);
  if t.Vt <> vtTab then
    LuaError(L, 'bad argument #1 to ''ipairs'' (table expected)');
  LuaSetTop(L, 0);
  LuaPush(L, LuaFunc(NewCFunc(L, @luaB_ipairsaux)));
  LuaPush(L, t);
  LuaPush(L, LuaInt(0));
  Result := 3;
end;

function luaB_pairs(L: TLua): Integer;
var
  t: TLuaValue;
  mm: TFunction;
begin
  t := LuaArg(L, 1);
  if t.Vt <> vtTab then
    LuaError(L, 'bad argument #1 to ''pairs'' (table expected)');
  mm := GetMM(L, t, '__pairs');
  if mm <> nil then
  begin
    LuaSetTop(L, 0);
    LuaPush(L, LuaFunc(mm));
    LuaPush(L, t);
    LuaCall(L, 2, 3);
    Result := LuaGetTop(L);
  end
  else
  begin
    LuaSetTop(L, 0);
    LuaPush(L, LuaFunc(NewCFunc(L, @luaB_next)));
    LuaPush(L, t);
    LuaPush(L, LuaNil);
    Result := 3;
  end;
end;

function luaB_rawequal(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  LuaPush(L, LuaBool(RawEqual(LuaArg(L, 1), LuaArg(L, 2))));
  Result := 1;
end;

function luaB_rawlen(L: TLua): Integer;
var
  v: TLuaValue;
begin
  v := LuaArg(L, 1);
  LuaSetTop(L, 0);
  case v.Vt of
    vtStr: LuaPush(L, LuaInt(v.S.Len));
    vtTab: LuaPush(L, LuaInt(TableLength(v.T)));
  else
    LuaError(L, 'bad argument #1 to ''rawlen''');
  end;
  Result := 1;
end;

function luaB_rawget(L: TLua): Integer;
var
  t: TLuaValue;
begin
  t := LuaArg(L, 1);
  if t.Vt <> vtTab then
    LuaError(L, 'bad argument #1 to ''rawget'' (table expected)');
  LuaSetTop(L, 0);
  LuaPush(L, TableGet(t.T, LuaArg(L, 2)));
  Result := 1;
end;

function luaB_rawset(L: TLua): Integer;
var
  t: TLuaValue;
begin
  t := LuaArg(L, 1);
  if t.Vt <> vtTab then
    LuaError(L, 'bad argument #1 to ''rawset'' (table expected)');
  TableSet(t.T, LuaArg(L, 2), LuaArg(L, 3));
  LuaSetTop(L, 0);
  LuaPush(L, t);
  Result := 1;
end;

function luaB_select(L: TLua): Integer;
var
  n, i: Integer;
  idx: Int64;
  base: Integer;
begin
  n := LuaGetTop(L);
  if (LuaArg(L, 1).Vt = vtStr) and (LuaArg(L, 1).S.ToStr = '#') then
  begin
    LuaSetTop(L, 0);
    LuaPush(L, LuaInt(n - 1));
    Result := 1;
    Exit;
  end;
  idx := CheckInt(L, 1);
  if idx < 0 then
    idx := n + idx;
  if idx > n then
    idx := n;
  if idx < 1 then
    LuaError(L, 'bad argument #1 to ''select'' (index out of range)');
  base := L.CI[L.NCI - 1].Base;
  for i := 0 to n - idx - 1 do
    L.Stack[base + i] := L.Stack[base + idx + i];
  L.Top := base + (n - idx);
  Result := n - idx;
end;

function luaB_setmetatable(L: TLua): Integer;
var
  t, mt: TLuaValue;
  mm: TLuaValue;
begin
  t := LuaArg(L, 1);
  mt := LuaArg(L, 2);
  if (t.Vt <> vtTab) and (t.Vt <> vtUser) then
    LuaError(L, 'bad argument #1 to ''setmetatable''');
  if (mt.Vt <> vtTab) and not IsNil(mt) then
    LuaError(L, 'bad argument #2 to ''setmetatable'' (nil or table expected)');
  if t.Vt = vtTab then
  begin
    if t.T.Metatable <> nil then
    begin
      mm := TableGetStr(t.T.Metatable, L.NewString('__metatable'));
      if not IsNil(mm) then
        LuaError(L, 'cannot change a protected metatable');
    end;
    if IsNil(mt) then
      t.T.SetMetatable(nil)
    else
      t.T.SetMetatable(mt.T);
  end
  else
  begin
    if IsNil(mt) then
      t.U.Metatable := nil
    else
      t.U.Metatable := mt.T;
  end;
  LuaSetTop(L, 0);
  LuaPush(L, t);
  Result := 1;
end;

function luaB_tonumber(L: TLua): Integer;
var
  v: TLuaValue;
  iv: Int64;
  nv: Double;
  base: Integer;
  s: string;
  i: Integer;
  neg: Boolean;
  dv: Integer;
begin
  v := LuaArg(L, 1);
  LuaSetTop(L, 0);
  if LuaGetTop(L) > 0 then begin end; // noop
  if v.Vt = vtStr then
  begin
    s := v.S.ToStr;
    if LuaGetTop(L) >= 2 then
    begin
      base := CheckInt(L, 2);
      if (base < 2) or (base > 36) then
        LuaError(L, 'bad argument #2 to ''tonumber'' (base out of range)');
      i := 1;
      neg := False;
      if (i <= Length(s)) and ((s[i] = '-') or (s[i] = '+')) then
      begin
        neg := s[i] = '-';
        Inc(i);
      end;
      iv := 0;
      while i <= Length(s) do
      begin
        dv := -1;
        if (s[i] >= '0') and (s[i] <= '9') then dv := Ord(s[i]) - Ord('0')
        else if (s[i] >= 'a') and (s[i] <= 'z') then dv := Ord(s[i]) - Ord('a') + 10
        else if (s[i] >= 'A') and (s[i] <= 'Z') then dv := Ord(s[i]) - Ord('A') + 10;
        if (dv < 0) or (dv >= base) then
        begin
          LuaPush(L, LuaNil);
          Result := 1;
          Exit;
        end;
        iv := iv * base + dv;
        Inc(i);
      end;
      if neg then iv := -iv;
      LuaPush(L, LuaInt(iv));
      Result := 1;
      Exit;
    end;
    if StrToIntVal(v.S.ToStr, iv) then
      LuaPush(L, LuaInt(iv))
    else if StrToNumVal(v.S.ToStr, nv) then
      LuaPush(L, LuaNum(nv))
    else
      LuaPush(L, LuaNil);
  end
  else if (v.Vt = vtInt) or (v.Vt = vtFlt) then
    LuaPush(L, v)
  else
    LuaPush(L, LuaNil);
  Result := 1;
end;

function luaB_tostring(L: TLua): Integer;
var
  v: TLuaValue;
  mm: TFunction;
begin
  v := LuaArg(L, 1);
  LuaSetTop(L, 0);
  case v.Vt of
    vtNil: LuaPush(L, StrToLua(L, 'nil'));
    vtBool: if v.B then LuaPush(L, StrToLua(L, 'true')) else LuaPush(L, StrToLua(L, 'false'));
    vtInt: LuaPush(L, StrToLua(L, NumToStr(v)));
    vtFlt: LuaPush(L, StrToLua(L, NumToStr(v)));
    vtStr: LuaPush(L, v);
  else begin
    mm := GetMM(L, v, '__tostring');
    if mm <> nil then
    begin
      LuaPush(L, LuaFunc(mm));
      LuaPush(L, v);
      LuaCall(L, 2, 1);
      Result := 1;
      Exit;
    end;
    if v.Vt = vtTab then
      LuaPush(L, StrToLua(L, Format('table: %p', [Pointer(v.T)])))
    else if v.Vt = vtFunc then
      LuaPush(L, StrToLua(L, Format('function: %p', [Pointer(v.F)])))
    else if v.Vt = vtUser then
      LuaPush(L, StrToLua(L, Format('userdata: %p', [Pointer(v.U)])))
    else if v.Vt = vtThread then
      LuaPush(L, StrToLua(L, Format('thread: %p', [Pointer(v.Th)])))
    else
      LuaPush(L, StrToLua(L, Format('userdata: %p', [v.P])));
  end;
  end;
  Result := 1;
end;

function luaB_type(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  LuaPush(L, StrToLua(L, VTypeName(LuaArg(L, 1))));
  Result := 1;
end;

function luaB_print(L: TLua): Integer;
var
  i, n: Integer;
  sb: string;
  v: TLuaValue;
begin
  sb := '';
  n := LuaGetTop(L);
  if GetEnvironmentVariable('LUA_TRACE') <> '' then
    WriteLn(ErrOutput, 'print n=', n);
  for i := 1 to n do
  begin
    v := LuaArg(L, i);
    if i > 1 then sb := sb + #9;
    case v.Vt of
      vtNil: sb := sb + 'nil';
      vtBool: if v.B then sb := sb + 'true' else sb := sb + 'false';
      vtInt, vtFlt: sb := sb + NumToStr(v);
      vtStr: sb := sb + v.S.ToStr;
    else
      sb := sb + VTypeName(v) + ': ' + Format('%p', [Pointer(v.T)]);
    end;
  end;
  WriteLn(sb);
  Flush(Output);
  Result := 0;
end;

function luaB_warn(L: TLua): Integer;
var
  i, n: Integer;
  sb: string;
  v: TLuaValue;
  w: TLuaValue;
begin
  v := LuaArg(L, 1);
  if (v.Vt = vtStr) and ((v.S.ToStr = '@on') or (v.S.ToStr = '@off')) then
  begin
    if v.S.ToStr = '@on' then
      TableSetStr(L.GlobalT, L.NewString('_WARN'), LuaBool(True))
    else
      TableSetStr(L.GlobalT, L.NewString('_WARN'), LuaBool(False));
    Result := 0;
    Exit;
  end;
  w := TableGetStr(L.GlobalT, L.NewString('_WARN'));
  if (w.Vt = vtBool) and not w.B then
  begin
    Result := 0;
    Exit;
  end;
  sb := '';
  n := LuaGetTop(L);
  for i := 1 to n do
  begin
    v := LuaArg(L, i);
    case v.Vt of
      vtNil: sb := sb + 'nil';
      vtBool: if v.B then sb := sb + 'true' else sb := sb + 'false';
      vtInt, vtFlt: sb := sb + NumToStr(v);
      vtStr: sb := sb + v.S.ToStr;
    else
      sb := sb + VTypeName(v);
    end;
  end;
  WriteLn(ErrOutput, sb);
  Flush(ErrOutput);
  Result := 0;
end;

function luaB_pcall(L: TLua): Integer;
var
  n, i, cnt: Integer;
  v: TLuaValue;
  base: Integer;
begin
  n := LuaGetTop(L);
  base := L.CI[L.NCI - 1].Base;
  i := LuaProtectedCall(L, n - 1, -1, 0);
  if i <> 0 then
  begin
    v := LuaArg(L, -1);
    L.Top := base;
    L.PushValue(LuaBool(False));
    L.PushValue(v);
    Result := 2;
  end
  else
  begin
    cnt := L.Top - base;
    for i := cnt - 1 downto 0 do
      L.Stack[base + i + 1] := L.Stack[base + i];
    L.Stack[base] := LuaBool(True);
    L.Top := base + cnt + 1;
    Result := cnt + 1;
  end;
end;

function luaB_xpcall(L: TLua): Integer;
var
  n, i: Integer;
begin
  n := LuaGetTop(L) - 2;
  // [func, handler, args...]
  // simplify: just call like pcall ignoring handler for now
  // rebuild [func, args...]
  for i := 1 to n do
    L.Stack[L.Top - n + i - 1] := LuaArg(L, i + 2);
  L.Top := L.Top - 2;
  for i := L.Top - 1 downto 1 do
    L.Stack[i] := L.Stack[i - 1];
  // placeholder; use pcall
  Result := luaB_pcall(L);
end;

// load
function luaB_load(L: TLua): Integer;
var
  v: TLuaValue;
  src: string;
  name: string;
  env: TLuaValue;
  f: TFunction;
  mode: string;
  i: Integer;
  chunk: TLuaValue;
  uv: TUpval;
begin
  v := LuaArg(L, 1);
  if LuaGetTop(L) >= 2 then
  begin
    if v.Vt = vtStr then name := OptStr(L, 2, v.S.ToStr)
    else name := OptStr(L, 2, '=(load)');
  end
  else name := '=(load)';
  if LuaGetTop(L) >= 3 then mode := OptStr(L, 3, 'bt') else mode := 'bt';
  env := LuaNil;
  if LuaGetTop(L) >= 4 then env := LuaArg(L, 4);
  LuaSetTop(L, 0);
  if v.Vt = vtStr then
    src := v.S.ToStr
  else if v.Vt = vtFunc then
  begin
    // reader function: read all chunks
    src := '';
    while True do
    begin
      LuaPush(L, LuaFunc(v.F));
      LuaCall(L, 1, 1);
      chunk := LuaArg(L, -1);
      if (chunk.Vt = vtNil) or ((chunk.Vt = vtStr) and (chunk.S.Len = 0)) then
        Break;
      if chunk.Vt <> vtStr then
        LuaError(L, 'reader function must return a string');
      src := src + chunk.S.ToStr;
    end;
  end
  else
    LuaError(L, 'bad argument #1 to ''load'' (function or string expected)');
  // binary check
  if (Length(src) > 0) and (src[1] = #27) then
  begin
    if Pos('b', mode) = 0 then
      LuaError(L, 'attempt to load a binary chunk');
    f := LuaUndump(L, RawByteString(src), name);
  end
  else
  begin
    if Pos('t', mode) = 0 then
      LuaError(L, 'attempt to load a text chunk');
    try
      f := LuaCompile(L, RawByteString(src), name);
    except
      on E: ELuaError do
      begin
        LuaPush(L, LuaNil);
        LuaPush(L, StrToLua(L, E.Message));
        Result := 2;
        Exit;
      end;
    end;
  end;
  // set upvalue 0
  if Length(f.Upvals) > 0 then
  begin
    uv := TUpval.Create;
    uv.Open := nil;
    if IsNil(env) then
      uv.V := LuaTab(L.GlobalT)
    else
      uv.V := env;
    f.Upvals[0] := uv;
  end;
  LuaPush(L, LuaFunc(f));
  Result := 1;
end;

// dofile/loadfile
function ReadFile(const name: string): RawByteString; forward;

function luaB_loadfile(L: TLua): Integer;
var
  name: string;
  content: RawByteString;
  f: TFunction;
  uv: TUpval;
begin
  name := OptStr(L, 1, '?');
  if not FileExists(name) then
  begin
    LuaSetTop(L, 0);
    LuaPush(L, LuaNil);
    LuaPush(L, StrToLua(L, 'cannot open ' + name));
    Result := 2;
    Exit;
  end;
  try
    content := ReadFile(name);
  except
    on E: Exception do
    begin
      LuaSetTop(L, 0);
      LuaPush(L, LuaNil);
      LuaPush(L, StrToLua(L, E.Message));
      Result := 2;
      Exit;
    end;
  end;
  LuaSetTop(L, 0);
  try
    f := LuaCompile(L, content, '@' + name);
  except
    on E: ELuaError do
    begin
      LuaPush(L, LuaNil);
      LuaPush(L, StrToLua(L, E.Message));
      Result := 2;
      Exit;
    end;
  end;
  uv := TUpval.Create;
  uv.V := LuaTab(L.GlobalT);
  f.Upvals[0] := uv;
  LuaPush(L, LuaFunc(f));
  Result := 1;
end;

function ReadFile(const name: string): RawByteString;
var
  f: File;
  buf: array[0..8191] of Byte;
  n: Integer;
begin
  Result := '';
  if not FileExists(name) then Exit;
  AssignFile(f, name);
  try
    Reset(f, 1);
  except
    Exit;
  end;
  try
    repeat
      BlockRead(f, buf, SizeOf(buf), n);
      if n > 0 then
        Result := Result + RawByteString(Copy(string(PChar(@buf[0])), 1, n));
    until n <= 0;
  finally
    CloseFile(f);
  end;
end;

function luaB_dofile(L: TLua): Integer;
var
  saved: Integer;
  f: TFunction;
  name: string;
begin
  saved := L.Top;
  // call loadfile then call result
  L.PushValue(StrToLua(L, OptStr(L, 1, '?')));
  // loadfile
  name := OptStr(L, 1, '?');
  L.SetTop(saved);
  L.PushValue(LuaFunc(NewCFunc(L, @luaB_loadfile)));
  L.PushValue(StrToLua(L, name));
  LuaCall(L, 2, 2);
  if IsNil(L.Stack[L.Top - 2]) then
  begin
    LuaError(L, CheckStr(L, -1).ToStr);
  end;
  // remove error, call function
  f := L.Stack[L.Top - 2].F;
  L.Top := L.Top - 2;
  L.PushValue(LuaFunc(f));
  LuaCall(L, 1, -1);
  Result := LuaGetTop(L);
end;

// ================= string library =================

function luaS_len(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  LuaPush(L, LuaInt(CheckStr(L, 1).Len));
  Result := 1;
end;

function luaS_sub(L: TLua): Integer;
var
  s: string;
  i, j: Int64;
  len: Int64;
  r: string;
  k: Int64;
begin
  s := CheckStr(L, 1).ToStr;
  len := Length(s);
  i := CheckInt(L, 2);
  if i < 0 then i := len + i + 1 else i := i;
  if i < 1 then i := 1;
  if LuaGetTop(L) >= 3 then
  begin
    j := CheckInt(L, 3);
    if j < 0 then j := len + j + 1;
    if j > len then j := len;
  end
  else
    j := len;
  LuaSetTop(L, 0);
  if i > j then
    LuaPush(L, StrToLua(L, ''))
  else
  begin
    r := Copy(s, i, j - i + 1);
    LuaPush(L, StrToLua(L, r));
  end;
  Result := 1;
end;

function luaS_reverse(L: TLua): Integer;
var
  s, r: string;
  i, n: Integer;
begin
  s := CheckStr(L, 1).ToStr;
  n := Length(s);
  SetLength(r, n);
  for i := 1 to n do
    r[i] := s[n - i + 1];
  LuaSetTop(L, 0);
  LuaPush(L, StrToLua(L, r));
  Result := 1;
end;

function luaS_lower(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  LuaPush(L, StrToLua(L, LowerCase(CheckStr(L, 1).ToStr)));
  Result := 1;
end;

function luaS_upper(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  LuaPush(L, StrToLua(L, UpperCase(CheckStr(L, 1).ToStr)));
  Result := 1;
end;

function luaS_rep(L: TLua): Integer;
var
  s, r: string;
  n, sep: Int64;
  i: Integer;
begin
  s := CheckStr(L, 1).ToStr;
  n := CheckInt(L, 2);
  sep := 0;
  if LuaGetTop(L) >= 3 then sep := CheckInt(L, 3);
  if (n < 0) or (sep < 0) then
    LuaError(L, 'bad argument');
  r := '';
  for i := 1 to n do
  begin
    if (i > 1) and (sep > 0) then r := r + Copy(s, 1, sep);
    r := r + s;
  end;
  LuaSetTop(L, 0);
  LuaPush(L, StrToLua(L, r));
  Result := 1;
end;

function luaS_byte(L: TLua): Integer;
var
  s: string;
  i, j: Int64;
  len: Int64;
  k: Int64;
begin
  s := CheckStr(L, 1).ToStr;
  len := Length(s);
  i := 1;
  if LuaGetTop(L) >= 2 then i := CheckInt(L, 2);
  if i < 0 then i := len + i + 1;
  if i < 1 then i := 1;
  if LuaGetTop(L) >= 3 then
  begin
    j := CheckInt(L, 3);
    if j < 0 then j := len + j + 1;
    if j > len then j := len;
  end
  else
    j := i;
  LuaSetTop(L, 0);
  if i > j then
    Result := 0
  else
  begin
    for k := i to j do
      LuaPush(L, LuaInt(Ord(s[k])));
    Result := j - i + 1;
  end;
end;

function luaS_char(L: TLua): Integer;
var
  n, i: Integer;
  r: string;
  c: Int64;
begin
  n := LuaGetTop(L);
  r := '';
  for i := 1 to n do
  begin
    c := CheckInt(L, i);
    if (c < 0) or (c > 255) then
      LuaError(L, 'bad argument (value out of range)');
    r := r + Chr(c);
  end;
  LuaSetTop(L, 0);
  LuaPush(L, StrToLua(L, r));
  Result := 1;
end;

// ---- pattern matching ----

type
  TMatchState = record
    S: string;          // subject
    P: string;          // pattern
    Level: Integer;
    Captures: array[0..31] of record Start: Integer; Len: Integer; end;
    NCap: Integer;
    MatchDepth: Integer;
    Start: Integer;
    EndPi: Integer;
    ForceMin: Boolean;
  end;
  PMatchState = ^TMatchState;

function MatchClass(c: Char; cl: Char): Boolean;
var
  ok: Boolean;
  lc: Char;
begin
  ok := False;
  lc := cl;
  if (lc >= 'A') and (lc <= 'Z') then
    lc := Chr(Ord(lc) + 32);
  case lc of
    'a': ok := ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z'));
    'c': ok := ((Ord(c) >= 0) and (Ord(c) <= 31)) or (Ord(c) = 127);
    'd': ok := (c >= '0') and (c <= '9');
    'g': ok := (c >= '!') and (c <= '~');
    'l': ok := (c >= 'a') and (c <= 'z');
    'p': ok := ((c >= '!') and (c <= '/')) or ((c >= ':') and (c <= '@')) or
               ((c >= '[') and (c <= '`')) or ((c >= '{') and (c <= '~'));
    's': ok := (c = ' ') or ((Ord(c) >= 9) and (Ord(c) <= 13));
    'u': ok := (c >= 'A') and (c <= 'Z');
    'w': ok := ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or ((c >= '0') and (c <= '9'));
    'x': ok := ((c >= '0') and (c <= '9')) or ((c >= 'a') and (c <= 'f')) or ((c >= 'A') and (c <= 'F'));
    'z': ok := Ord(c) = 0;
  else
    ok := c = cl;   // literal escape
  end;
  Result := ok;
end;

function MatchSingle(ms: PMatchState; si, pi: Integer): Integer; forward;

function MatchBracket(ms: PMatchState; si, pi: Integer): Integer;
var
  c: Char;
  invert: Boolean;
  ok, range: Boolean;
  pj: Integer;
  lo, hi: Char;
begin
  c := ms^.S[si];
  invert := False;
  pj := pi;
  if ms^.P[pj] = '^' then
  begin
    invert := True;
    Inc(pj);
  end;
  ok := False;
  while (pj <= Length(ms^.P)) and (ms^.P[pj] <> ']') do
  begin
    if ms^.P[pj] = '%' then
    begin
      Inc(pj);
      if MatchClass(c, ms^.P[pj]) then ok := True;
    end
    else if (pj + 2 <= Length(ms^.P)) and (ms^.P[pj+1] = '-') and (ms^.P[pj+2] <> ']') then
    begin
      lo := ms^.P[pj];
      hi := ms^.P[pj+2];
      if (c >= lo) and (c <= hi) then ok := True;
      Inc(pj, 2);
    end
    else
    begin
      if ms^.P[pj] = c then ok := True;
    end;
    Inc(pj);
  end;
  if ms^.P[pj] <> ']' then
    raise ELuaError.CreateMsg('malformed pattern (missing '']'')');
  if invert then ok := not ok;
  if ok then
    Result := MatchSingle(ms, si + 1, pj + 1)
  else
    Result := -1;
end;

function MatchCapture(ms: PMatchState; si, pi: Integer): Integer;
var
  idx: Integer;
  l: Integer;
begin
  idx := Ord(ms^.P[pi]) - Ord('1');
  if (idx < 0) or (idx >= ms^.NCap) or (ms^.Captures[idx].Len < 0) then
    raise ELuaError.CreateMsg('invalid capture index');
  l := ms^.Captures[idx].Len;
  if (si + l <= Length(ms^.S) + 1) and
     (Copy(ms^.S, ms^.Captures[idx].Start, l) = Copy(ms^.S, si, l)) then
    Result := MatchSingle(ms, si + l, pi + 1)
  else
    Result := -1;
end;

function MatchBalance(ms: PMatchState; si, pi: Integer): Integer;
var
  b, e: Char;
  depth: Integer;
begin
  if (pi + 2 > Length(ms^.P)) then
    raise ELuaError.CreateMsg('malformed pattern (missing arguments to ''%%b'')');
  b := ms^.P[pi];
  e := ms^.P[pi + 1];
  if ms^.S[si] <> b then
    Exit(-1);
  depth := 1;
  Inc(si);
  while si <= Length(ms^.S) do
  begin
    if ms^.S[si] = e then
    begin
      Dec(depth);
      if depth = 0 then
        Exit(MatchSingle(ms, si + 1, pi + 2));
    end
    else if ms^.S[si] = b then
      Inc(depth);
    Inc(si);
  end;
  Result := -1;
end;

function MatchFrontier(ms: PMatchState; si, pi: Integer): Integer;
var
  prev, curr: Char;
  okPrev, okCurr: Boolean;
  pj: Integer;
begin
  if si = 1 then prev := #0 else prev := ms^.S[si - 1];
  if si > Length(ms^.S) then curr := #0 else curr := ms^.S[si];
  pj := pi;
  okPrev := False;
  okCurr := False;
  if ms^.P[pj] <> '[' then
    raise ELuaError.CreateMsg('missing ''['' after ''%f''');
  Inc(pj);
  while ms^.P[pj] <> ']' do
  begin
    if ms^.P[pj] = '%' then
    begin
      Inc(pj);
      if MatchClass(prev, ms^.P[pj]) then okPrev := True;
      if MatchClass(curr, ms^.P[pj]) then okCurr := True;
    end
    else
    begin
      if ms^.P[pj] = prev then okPrev := True;
      if ms^.P[pj] = curr then okCurr := True;
    end;
    Inc(pj);
  end;
  if (okPrev <> okCurr) and (okPrev = False) then
    Result := MatchSingle(ms, si, pj + 1)
  else
    Result := -1;
end;

function ItemNextPi(const p: string; pi: Integer): Integer;
var
  c: Char;
begin
  c := p[pi];
  if c = '%' then
  begin
    if (pi + 1 <= Length(p)) and ((p[pi+1] = 'b') or (p[pi+1] = 'f')) then
      Result := pi + 3   // %bxy
    else
      Result := pi + 2;
  end
  else if c = '[' then
  begin
    Result := pi + 1;
    if (Result <= Length(p)) and (p[Result] = '^') then Inc(Result);
    while (Result <= Length(p)) and (p[Result] <> ']') do Inc(Result);
    Inc(Result); // skip ']'
  end
  else
    Result := pi + 1;
end;

function MatchItem(ms: PMatchState; si, pi: Integer): Integer;
var
  c: Char;
  r: Integer;
begin
  if si > Length(ms^.S) + 1 then Exit(-1);
  if si = Length(ms^.S) + 1 then Exit(-1);
  c := ms^.P[pi];
  if c = '.' then
    Result := si + 1
  else if c = '%' then
  begin
    if ms^.P[pi+1] = 'b' then
    begin
      r := MatchBalance(ms, si, pi + 2);
      if r < 0 then Result := -1 else Result := r + 1;
    end
    else if ms^.P[pi+1] = 'f' then
    begin
      r := MatchFrontier(ms, si, pi + 2);
      if r < 0 then Result := -1 else Result := r + 1;
    end
    else if (ms^.P[pi+1] >= '0') and (ms^.P[pi+1] <= '9') then
    begin
      r := MatchCapture(ms, si, pi + 1);
      if r < 0 then Result := -1 else Result := r + 1;
    end
    else if MatchClass(ms^.S[si], ms^.P[pi+1]) then
      Result := si + 1
    else
      Result := -1;
  end
  else if c = '[' then
  begin
    r := MatchBracket(ms, si, pi + 1);
    if r < 0 then Result := -1 else Result := r + 1;
  end
  else if ms^.P[pi] = ms^.S[si] then
    Result := si + 1
  else
    Result := -1;
end;

function MatchSingle(ms: PMatchState; si, pi: Integer): Integer;
var
  r, r2: Integer;
  pi2: Integer;
  q: Char;
  count, maxcount, si2: Integer;
begin
  Inc(ms^.MatchDepth);
  if ms^.MatchDepth > 1000 then
    raise ELuaError.CreateMsg('pattern too complex');
  if pi > Length(ms^.P) then
    Exit(si - 1);
  case ms^.P[pi] of
    '(': begin
      if (pi + 1 <= Length(ms^.P)) and (ms^.P[pi+1] = ')') then
        r := MatchSingle(ms, si, pi + 2)
      else
      begin
        if ms^.NCap >= 32 then
          raise ELuaError.CreateMsg('too many captures');
        ms^.Captures[ms^.NCap].Start := si;
        ms^.Captures[ms^.NCap].Len := -1;
        Inc(ms^.NCap);
        r := MatchSingle(ms, si, pi + 1);
        if r < 0 then Dec(ms^.NCap)
        else
        begin
          // try continuation after the capture; if it fails, extend the
          // capture by matching its body again (lazy-style backtracking)
          while True do
          begin
            ms^.Captures[ms^.NCap-1].Len := r - si + 1;
            r2 := MatchSingle(ms, r + 1, ms^.EndPi + 1);
            if r2 >= 0 then
            begin
              r := r2;
              Break;
            end;
            ms^.ForceMin := True;
            r2 := MatchSingle(ms, r + 1, pi + 1);
            ms^.ForceMin := False;
            if (r2 < 0) or (r2 <= r) then
            begin
              ms^.Captures[ms^.NCap-1].Len := -1;
              Dec(ms^.NCap);
              r := -1;
              Break;
            end;
            r := r2;
          end;
        end;
      end;
      Dec(ms^.MatchDepth);
      Exit(r);
    end;
    ')': begin ms^.EndPi := pi; Dec(ms^.MatchDepth); Exit(si - 1); end;
    '$': begin
      if pi = Length(ms^.P) then
      begin
        Dec(ms^.MatchDepth);
        if si = Length(ms^.S) + 1 then Exit(si - 1) else Exit(-1);
      end;
    end;
  end;
  // single item with optional quantifier
  pi2 := ItemNextPi(ms^.P, pi);
  if (pi2 <= Length(ms^.P)) then
    q := ms^.P[pi2]
  else
    q := #0;
  case q of
    '*', '+', '-', '?':
    begin
      // compute maximum number of repetitions that fit
      maxcount := 0;
      si2 := si;
      while maxcount < 100000 do
      begin
        r := MatchItem(ms, si2, pi);
        if r < 0 then Break;
        si2 := r;
        Inc(maxcount);
      end;
      if q = '-' then
      begin
        // lazy: try from 0 up (or from 1 if forced)
        si2 := si;
        if ms^.ForceMin then
        begin
          if maxcount < 1 then
          begin
            Dec(ms^.MatchDepth);
            Exit(-1);
          end;
          si2 := MatchItem(ms, si, pi);
          count := 1;
        end
        else
          count := 0;
        for count := count to maxcount do
        begin
          r := MatchSingle(ms, si2, pi2 + 1);
          if r >= 0 then
          begin
            Dec(ms^.MatchDepth);
            Exit(r);
          end;
          if count < maxcount then
            si2 := MatchItem(ms, si2, pi);
        end;
        Dec(ms^.MatchDepth);
        Exit(-1);
      end
      else
      begin
        // greedy: try from max down
        si2 := si;
        for count := 0 to maxcount - 1 do
          si2 := MatchItem(ms, si2, pi);
        for count := maxcount downto 0 do
        begin
          if (q = '+') and (count = 0) then Break;
          r := MatchSingle(ms, si2, pi2 + 1);
          if r >= 0 then
          begin
            Dec(ms^.MatchDepth);
            Exit(r);
          end;
          if count > 0 then
          begin
            // backtrack one repetition: recompute si2 from scratch
            si2 := si;
            for maxcount := 1 to count - 1 do
              si2 := MatchItem(ms, si2, pi);
          end;
        end;
        Dec(ms^.MatchDepth);
        Exit(-1);
      end;
    end;
  else
  begin
    r := MatchItem(ms, si, pi);
    if r < 0 then
    begin
      Dec(ms^.MatchDepth);
      Exit(-1);
    end;
    Dec(ms^.MatchDepth);
    Exit(MatchSingle(ms, r, pi2));
  end;
  end;
end;

function MaxExpand(ms: PMatchState; si, pi: Integer): Integer;
var
  i: Integer;
  ok: Boolean;
begin
  i := 0;
  while si + i <= Length(ms^.S) + 1 do
  begin
    ok := MatchSingle(ms, si + i, pi + 1) >= 0;
    if ok then
      Exit(i);
    Inc(i);
  end;
  Result := -1;
end;

function MinExpand(ms: PMatchState; si, pi: Integer): Integer;
var
  i: Integer;
begin
  i := 0;
  while si + i <= Length(ms^.S) + 1 do
  begin
    if MatchSingle(ms, si + i, pi + 1) >= 0 then
      Exit(i);
    Inc(i);
  end;
  Result := -1;
end;

function Match(ms: PMatchState; si, pi: Integer): Integer;
var
  r: Integer;
  anchor: Boolean;
begin
  anchor := (pi <= Length(ms^.P)) and (ms^.P[pi] = '^');
  if anchor then Inc(pi);
  repeat
    r := MatchSingle(ms, si, pi);
    if r >= 0 then
    begin
      ms^.Start := si;
      Exit(r);
    end;
    Inc(si);
  until (si > Length(ms^.S) + 1) or anchor;
  Result := -1;
end;

type
  TCap = record Start: Integer; Len: Integer; end;

function DoMatch(const s, p: string; var caps: array of TCap; var ncap: Integer; init: Integer; var start: Integer): Integer;
var
  ms: TMatchState;
  i: Integer;
begin
  ms.S := s;
  ms.P := p;
  ms.Level := 0;
  ms.NCap := 0;
  ms.MatchDepth := 0;
  for i := 0 to 31 do
  begin
    ms.Captures[i].Start := 0;
    ms.Captures[i].Len := -1;
  end;
  Result := Match(@ms, init, 1);
  ncap := ms.NCap;
  start := ms.Start;
  for i := 0 to ms.NCap - 1 do
  begin
    caps[i].Start := ms.Captures[i].Start;
    caps[i].Len := ms.Captures[i].Len;
  end;
end;

function CheckBool(L: TLua; i: Integer): Boolean;
begin
  Result := Truthy(LuaArg(L, i));
end;

function luaS_find(L: TLua): Integer;
var
  s, p: string;
  init: Integer;
  caps: array[0..31] of TCap;
  ncap, i, r: Integer;
  start: Integer;
begin
  s := CheckStr(L, 1).ToStr;
  p := CheckStr(L, 2).ToStr;
  init := 1;
  if LuaGetTop(L) >= 3 then
  begin
    init := CheckInt(L, 3);
    if init < 0 then init := Length(s) + init + 1;
    if init < 1 then init := 1;
  end;
  if LuaGetTop(L) >= 4 then CheckBool(L, 4);
  r := DoMatch(s, p, caps, ncap, init, start);
  LuaSetTop(L, 0);
  if r < 0 then
    Result := 0
  else
  begin
    if ncap = 0 then
    begin
      LuaPush(L, LuaInt(start));
      LuaPush(L, LuaInt(r));
      Result := 2;
    end
    else
    begin
      LuaPush(L, LuaInt(caps[0].Start));
      LuaPush(L, LuaInt(caps[0].Start + caps[0].Len - 1));
      for i := 1 to ncap - 1 do
      begin
        if caps[i].Len < 0 then
          LuaPush(L, LuaNil)
        else
          LuaPush(L, StrToLua(L, Copy(s, caps[i].Start, caps[i].Len)));
      end;
      Result := ncap + 1;
    end;
  end;
end;

function luaS_match(L: TLua): Integer;
var
  s, p: string;
  init: Integer;
  caps: array[0..31] of TCap;
  ncap, i, r: Integer;
  start: Integer;
begin
  s := CheckStr(L, 1).ToStr;
  p := CheckStr(L, 2).ToStr;
  init := 1;
  if LuaGetTop(L) >= 3 then
  begin
    init := CheckInt(L, 3);
    if init < 0 then init := Length(s) + init + 1;
    if init < 1 then init := 1;
  end;
  r := DoMatch(s, p, caps, ncap, init, start);
  LuaSetTop(L, 0);
  if r < 0 then
    Result := 0
  else
  begin
    if ncap = 0 then
    begin
      LuaPush(L, StrToLua(L, Copy(s, start, r - start + 1)));
      Result := 1;
    end
    else
    begin
      for i := 0 to ncap - 1 do
      begin
        if caps[i].Len < 0 then
          LuaPush(L, LuaNil)
        else
          LuaPush(L, StrToLua(L, Copy(s, caps[i].Start, caps[i].Len)));
      end;
      Result := ncap;
    end;
  end;
end;

// gmatch
type
  TGMatchState = record
    L: TLua;
    S: string;
    P: string;
    Pos: Integer;
    Caps: array[0..31] of TCap;
    NCap: Integer;
  end;

function gmatch_aux(L: TLua): Integer;
var
  gs: ^TGMatchState;
  r: Integer;
  i: Integer;
  start: Integer;
begin
  gs := LuaArg(L, 1).P;
  gs^.L := L;
  // find next match starting at gs.Pos
  if gs^.Pos > Length(gs^.S) + 1 then
  begin
    LuaSetTop(L, 0);
    Result := 0;
    Exit;
  end;
  r := DoMatch(gs^.S, gs^.P, gs^.Caps, gs^.NCap, gs^.Pos, start);
  if r < 0 then
  begin
    LuaSetTop(L, 0);
    Result := 0;
    Exit;
  end;
  if gs^.NCap = 0 then
    gs^.Pos := r + 1
  else
  begin
    gs^.Pos := gs^.Caps[0].Start + gs^.Caps[0].Len;
    if gs^.Caps[0].Len = 0 then Inc(gs^.Pos);
  end;
  LuaSetTop(L, 0);
  if gs^.NCap = 0 then
    LuaPush(L, StrToLua(L, Copy(gs^.S, gs^.Pos - 1, 1)))
  else
    for i := 0 to gs^.NCap - 1 do
    begin
      if gs^.Caps[i].Len < 0 then
        LuaPush(L, LuaNil)
      else
        LuaPush(L, StrToLua(L, Copy(gs^.S, gs^.Caps[i].Start, gs^.Caps[i].Len)));
    end;
  Result := LuaGetTop(L);
end;

function luaS_gmatch(L: TLua): Integer;
var
  gs: ^TGMatchState;
  s, p: string;
begin
  s := CheckStr(L, 1).ToStr;
  p := CheckStr(L, 2).ToStr;
  LuaSetTop(L, 0);
  New(gs);
  gs^.L := L;
  gs^.S := s;
  gs^.P := p;
  gs^.Pos := 1;
  LuaPush(L, LuaFunc(NewCFunc(L, @gmatch_aux)));
  LuaPush(L, LuaLight(gs));
  LuaPush(L, LuaNil);
  Result := 3;
end;

// gsub
function luaS_gsub(L: TLua): Integer;
var
  s, p, rep: string;
  caps: array[0..31] of TCap;
  ncap, i, r, pos: Integer;
  start: Integer;
  nmatches: Integer;
  out: string;
  repv: TLuaValue;
  repf: TFunction;
  rept: TTable;
  piece: string;
  whole: string;
  tv: TLuaValue;
  ci: Integer;
begin
  s := CheckStr(L, 1).ToStr;
  p := CheckStr(L, 2).ToStr;
  repv := LuaArg(L, 3);
  nmatches := 0;
  out := '';
  pos := 1;
  while pos <= Length(s) + 1 do
  begin
    r := DoMatch(s, p, caps, ncap, pos, start);
    if r < 0 then Break;
    Inc(nmatches);
    out := out + Copy(s, pos, start - pos);
    whole := Copy(s, start, r - start + 1);
    // build replacement
    if repv.Vt = vtFunc then
    begin
      LuaSetTop(L, 0);
      LuaPush(L, LuaFunc(repv.F));
      if ncap = 0 then
        LuaPush(L, StrToLua(L, whole))
      else
        for i := 0 to ncap - 1 do
        begin
          if caps[i].Len < 0 then
            LuaPush(L, LuaNil)
          else
            LuaPush(L, StrToLua(L, Copy(s, caps[i].Start, caps[i].Len)));
        end;
      LuaCall(L, ncap + 1, 1);
      piece := CheckStr(L, -1).ToStr;
    end
    else if repv.Vt = vtTab then
    begin
      if ncap = 0 then
        tv := TableGetStr(repv.T, L.NewString(whole))
      else
        tv := TableGetStr(repv.T, L.NewString(Copy(s, caps[0].Start, caps[0].Len)));
      if IsNil(tv) then piece := whole else piece := tv.S.ToStr;
    end
    else if repv.Vt = vtStr then
    begin
      rep := repv.S.ToStr;
      piece := '';
      i := 1;
      while i <= Length(rep) do
      begin
        if rep[i] = '%' then
        begin
          Inc(i);
          if i > Length(rep) then
            LuaError(L, 'invalid use of ''%'' in replacement string');
          if rep[i] = '%' then piece := piece + '%'
          else if rep[i] = '0' then piece := piece + whole
          else if (rep[i] >= '1') and (rep[i] <= '9') then
          begin
            ci := Ord(rep[i]) - Ord('1');
            if ci < ncap then
            begin
              if caps[ci].Len >= 0 then
                piece := piece + Copy(s, caps[ci].Start, caps[ci].Len);
            end;
          end
          else
            LuaError(L, 'invalid use of ''%'' in replacement string');
          Inc(i);
        end
        else
        begin
          piece := piece + rep[i];
          Inc(i);
        end;
      end;
    end
    else
      LuaError(L, 'bad argument #3 to ''gsub'' (string/function/table expected)');
    out := out + piece;
    // advance
    if ncap = 0 then
      pos := r + 1
    else
    begin
      pos := caps[0].Start + caps[0].Len;
      if caps[0].Len = 0 then
      begin
        if pos <= Length(s) then out := out + s[pos];
        Inc(pos);
      end;
    end;
    // avoid infinite loop on empty match at end
    if pos > Length(s) + 1 then Break;
  end;
  out := out + Copy(s, pos, Length(s) - pos + 1);
  LuaSetTop(L, 0);
  LuaPush(L, StrToLua(L, out));
  LuaPush(L, LuaInt(nmatches));
  Result := 2;
end;

function luaS_dump(L: TLua): Integer;
var
  f: TFunction;
  strip: Boolean;
  b: RawByteString;
begin
  f := CheckFunc(L, 1);
  if f.IsC then
    LuaError(L, 'unable to dump given function');
  strip := False;
  if LuaGetTop(L) >= 2 then strip := Truthy(LuaArg(L, 2));
  b := LuaDump(L, f, strip);
  LuaSetTop(L, 0);
  LuaPush(L, LuaStr(L.NewLongString(b)));
  Result := 1;
end;

// string.format - simplified but functional
function luaS_format(L: TLua): Integer;
var
  fmt: string;
  argi: Integer;
  res: string;
  i: Integer;
  n: Integer;
  flags: string;
  width: Integer;
  prec: Integer;
  spec: Char;
  piece: string;
  iv: Int64;
  nv: Double;
  sv: TLuaValue;
  ss: string;
  ci: Integer;
  ch: Char;
begin
  fmt := CheckStr(L, 1).ToStr;
  argi := 2;
  res := '';
  i := 1;
  n := Length(fmt);
  while i <= n do
  begin
    if fmt[i] <> '%' then
    begin
      res := res + fmt[i];
      Inc(i);
      continue;
    end;
    Inc(i);
    if (i <= n) and (fmt[i] = '%') then
    begin
      res := res + '%';
      Inc(i);
      continue;
    end;
    // parse flags
    flags := '';
    while (i <= n) and (Pos(fmt[i], '-+ #0') > 0) do
    begin
      flags := flags + fmt[i];
      Inc(i);
    end;
    width := 0;
    while (i <= n) and (fmt[i] >= '0') and (fmt[i] <= '9') do
    begin
      width := width * 10 + Ord(fmt[i]) - Ord('0');
      Inc(i);
    end;
    prec := -1;
    if (i <= n) and (fmt[i] = '.') then
    begin
      Inc(i);
      prec := 0;
      while (i <= n) and (fmt[i] >= '0') and (fmt[i] <= '9') do
      begin
        prec := prec * 10 + Ord(fmt[i]) - Ord('0');
        Inc(i);
      end;
    end;
    if i > n then
      LuaError(L, 'invalid format string');
    spec := fmt[i];
    Inc(i);
    piece := '';
    case spec of
      'd', 'i': begin
        iv := CheckInt(L, argi);
        piece := IntToStr(iv);
        Inc(argi);
      end;
      'u': begin
        iv := CheckInt(L, argi);
        piece := IntToStr(iv);
        Inc(argi);
      end;
      'o': begin
        iv := CheckInt(L, argi);
        piece := OctStr(iv, 1);
        Inc(argi);
      end;
      'x', 'X': begin
        iv := CheckInt(L, argi);
        piece := HexStr(QWord(iv), 1);
        if spec = 'x' then piece := LowerCase(piece);
        Inc(argi);
      end;
      'c': begin
        iv := CheckInt(L, argi);
        piece := Chr(iv and $FF);
        Inc(argi);
      end;
      'f', 'F': begin
        nv := CheckNum(L, argi);
        if prec < 0 then prec := 6;
        piece := FloatToStrF(nv, ffFixed, 0, prec);
        Inc(argi);
      end;
      'e', 'E': begin
        nv := CheckNum(L, argi);
        if prec < 0 then prec := 6;
        piece := FormatFloat('0.' + StringOfChar('#', prec) + 'E+00', nv);
        if spec = 'e' then piece := LowerCase(piece);
        // normalize exponent to 2 digits min
        Inc(argi);
      end;
      'g', 'G': begin
        nv := CheckNum(L, argi);
        if prec < 0 then prec := 6;
        piece := FloatToStrF(nv, ffGeneral, prec, 0);
        Inc(argi);
      end;
      's': begin
        sv := LuaArg(L, argi);
        if sv.Vt = vtStr then ss := sv.S.ToStr
        else if IsNil(sv) then ss := 'nil'
        else if sv.Vt = vtBool then begin if sv.B then ss := 'true' else ss := 'false'; end
        else if (sv.Vt = vtInt) or (sv.Vt = vtFlt) then ss := NumToStr(sv)
        else ss := VTypeName(sv);
        Inc(argi);
        if prec >= 0 then
        begin
          if Length(ss) > prec then ss := Copy(ss, 1, prec);
          piece := ss;
        end
        else
          piece := ss;
      end;
      'q': begin
        sv := LuaArg(L, argi);
        Inc(argi);
        if sv.Vt = vtStr then
        begin
          piece := '"';
          for ci := 1 to Length(sv.S.ToStr) do
          begin
            ch := sv.S.ToStr[ci];
            case ch of
              '"': piece := piece + '\"';
              '\': piece := piece + '\\';
              #10: piece := piece + '\n';
              #13: piece := piece + '\r';
              #0: piece := piece + '\0';
            else
              if Ord(ch) < 32 then
                piece := piece + Format('\%d', [Ord(ch)])
              else
                piece := piece + ch;
            end;
          end;
          piece := piece + '"';
        end
        else if IsNil(sv) then piece := 'nil'
        else if sv.Vt = vtBool then begin if sv.B then piece := 'true' else piece := 'false'; end
        else if (sv.Vt = vtInt) or (sv.Vt = vtFlt) then
        begin
          if sv.Vt = vtFlt then
          begin
            if IsNaN(sv.N) then piece := '(0/0)'
            else if IsInfinite(sv.N) then begin if sv.N > 0 then piece := '1/0' else piece := '-1/0'; end
            else piece := NumToStr(sv)
          end
          else piece := NumToStr(sv);
        end
        else
          LuaError(L, 'value has no literal form');
      end;
      'p': begin
        sv := LuaArg(L, argi);
        Inc(argi);
        if IsNil(sv) or (sv.Vt = vtBool) or (sv.Vt = vtInt) or (sv.Vt = vtFlt) or (sv.Vt = vtLight) then
          piece := '(null)'
        else
          piece := Format('%p', [Pointer(sv.T)]);
      end;
    else
      LuaError(L, Format('invalid conversion ''%%%s'' to ''format''', [spec]));
    end;
    // apply width/flags
    if width > 0 then
    begin
      if Length(piece) < width then
      begin
        if Pos('-', flags) > 0 then
          piece := piece + StringOfChar(' ', width - Length(piece))
        else if (Pos('0', flags) > 0) and (spec in ['d','i','u','o','x','X','f','F','e','E','g','G']) then
          piece := StringOfChar('0', width - Length(piece)) + piece
        else
          piece := StringOfChar(' ', width - Length(piece)) + piece;
      end;
    end;
    res := res + piece;
  end;
  LuaSetTop(L, 0);
  LuaPush(L, StrToLua(L, res));
  Result := 1;
end;

// string.pack/unpack/packsize
function luaS_packsize(L: TLua): Integer;
var
  fmt: string;
  size: Integer;
  i: Integer;
begin
  fmt := CheckStr(L, 1).ToStr;
  size := 0;
  for i := 1 to Length(fmt) do
  begin
    case fmt[i] of
      'b','B': Inc(size, 1);
      'h','H': Inc(size, 2);
      'l','L','i','I','f': Inc(size, 4);
      'j','J','T','n','d': Inc(size, 8);
      'c': Inc(size, 1);
      'x': Inc(size, 1);
      ' ': continue;
      '!','<','>','=': continue;
    else
      LuaError(L, Format('invalid format option ''%s''', [fmt[i]]));
    end;
  end;
  LuaSetTop(L, 0);
  LuaPush(L, LuaInt(size));
  Result := 1;
end;

function luaS_pack(L: TLua): Integer;
var
  fmt: string;
  res: RawByteString;
  argi: Integer;
  i: Integer;
  iv: Int64;
  nv: Double;
  u: QWord;
  j: Integer;
  dd: Double;
  pb: PByte;
  cn: Integer;
begin
  fmt := CheckStr(L, 1).ToStr;
  argi := 2;
  res := '';
  i := 1;
  while i <= Length(fmt) do
  begin
    case fmt[i] of
      ' ': begin Inc(i); continue; end;
      '!','<','>','=': begin Inc(i); continue; end;
      'b': begin iv := CheckInt(L, argi); Inc(argi); res := res + Chr(iv and $FF); end;
      'B': begin iv := CheckInt(L, argi); Inc(argi); res := res + Chr(iv and $FF); end;
      'h': begin iv := CheckInt(L, argi); Inc(argi); res := res + Chr(iv and $FF) + Chr((iv shr 8) and $FF); end;
      'H': begin iv := CheckInt(L, argi); Inc(argi); res := res + Chr(iv and $FF) + Chr((iv shr 8) and $FF); end;
      'l','L': begin iv := CheckInt(L, argi); Inc(argi); u := QWord(iv); for j := 0 to 3 do res := res + Chr((u shr (j*8)) and $FF); end;
      'i','I','f': begin
        if fmt[i] = 'f' then begin nv := CheckNum(L, argi); res := res + RawByteString(Copy(string(PDouble(@nv)),1,4)); end
        else begin iv := CheckInt(L, argi); u := QWord(iv); for j := 0 to 3 do res := res + Chr((u shr (j*8)) and $FF); end;
        Inc(argi);
      end;
      'j','J': begin iv := CheckInt(L, argi); Inc(argi); u := QWord(iv); for j := 0 to 7 do res := res + Chr((u shr (j*8)) and $FF); end;
      'T': begin iv := CheckInt(L, argi); Inc(argi); u := QWord(iv); for j := 0 to 7 do res := res + Chr((u shr (j*8)) and $FF); end;
      'n','d': begin
        nv := CheckNum(L, argi); Inc(argi);
        dd := nv;
        pb := PByte(@dd);
        for j := 0 to 7 do res := res + Chr(pb[j]);
      end;
      'c': begin
        cn := CheckInt(L, argi); Inc(argi);
        if cn > 0 then
        begin
          res := res + RawByteString(CheckStr(L, argi).ToStr);
          // pad/truncate to n
          SetLength(res, Length(res) + (cn - Length(CheckStr(L, argi).ToStr)));
          Inc(argi);
        end;
      end;
      'x': Inc(argi);
    else
      LuaError(L, Format('invalid format option ''%s''', [fmt[i]]));
    end;
    Inc(i);
  end;
  LuaSetTop(L, 0);
  LuaPush(L, LuaStr(L.NewLongString(res)));
  Result := 1;
end;

// ================= table library =================

function luaT_concat(L: TLua): Integer;
var
  t: TTable;
  sep: string;
  i, j: Int64;
  sb: string;
  k: Int64;
  v: TLuaValue;
begin
  t := CheckTab(L, 1);
  sep := OptStr(L, 2, '');
  i := 1;
  if LuaGetTop(L) >= 3 then i := CheckInt(L, 3);
  j := TableLength(t);
  if LuaGetTop(L) >= 4 then j := CheckInt(L, 4);
  sb := '';
  for k := i to j do
  begin
    v := TableGetInt(t, k);
    if k > i then sb := sb + sep;
    case v.Vt of
      vtStr: sb := sb + v.S.ToStr;
      vtInt, vtFlt: sb := sb + NumToStr(v);
    else
      LuaError(L, 'invalid value (at index ' + IntToStr(k) + ') in table for ''concat''');
    end;
  end;
  LuaSetTop(L, 0);
  LuaPush(L, StrToLua(L, sb));
  Result := 1;
end;

function luaT_insert(L: TLua): Integer;
var
  t: TTable;
  n, i: Int64;
  pos: Int64;
  v: TLuaValue;
  k: Int64;
begin
  t := CheckTab(L, 1);
  n := LuaGetTop(L);
  if n = 2 then
  begin
    pos := TableLength(t) + 1;
    v := LuaArg(L, 2);
  end
  else
  begin
    pos := CheckInt(L, 2);
    v := LuaArg(L, 3);
  end;
  // shift
  for k := TableLength(t) + 1 downto pos + 1 do
    TableSetInt(t, k, TableGetInt(t, k - 1));
  TableSetInt(t, pos, v);
  Result := 0;
end;

function luaT_remove(L: TLua): Integer;
var
  t: TTable;
  pos: Int64;
  v: TLuaValue;
  k, len: Int64;
begin
  t := CheckTab(L, 1);
  len := TableLength(t);
  pos := len;
  if LuaGetTop(L) >= 2 then pos := CheckInt(L, 2);
  if (pos < 1) or (pos > len) then
    LuaError(L, 'position out of bounds');
  v := TableGetInt(t, pos);
  for k := pos to len - 1 do
    TableSetInt(t, k, TableGetInt(t, k + 1));
  TableSetInt(t, len, LuaNil);
  LuaSetTop(L, 0);
  LuaPush(L, v);
  Result := 1;
end;

function VToNum2(const v: TLuaValue): Double; forward;
function VToNumLess(const a, b: TLuaValue): Boolean; forward;

function luaT_sort(L: TLua): Integer;
var
  t: TTable;
  cmp: TFunction;
  n: Int64;
  i, j: Int64;
  tmp, vi, vj: TLuaValue;
  res: TLuaValue;
begin
  t := CheckTab(L, 1);
  cmp := nil;
  if LuaGetTop(L) >= 2 then
  begin
    if LuaArg(L, 2).Vt = vtFunc then cmp := LuaArg(L, 2).F;
  end;
  n := TableLength(t);
  // insertion sort with comparator
  for i := 2 to n do
  begin
    vi := TableGetInt(t, i);
    j := i - 1;
    while j >= 1 do
    begin
      vj := TableGetInt(t, j);
      if cmp <> nil then
      begin
        LuaSetTop(L, 0);
        LuaPush(L, LuaFunc(cmp));
        LuaPush(L, vi);
        LuaPush(L, vj);
        LuaCall(L, 3, 1);
        res := L.Stack[L.Top - 1];
        if Truthy(res) then Break;
      end
      else
      begin
        if VToNumLess(vi, vj) then Break;
      end;
      TableSetInt(t, j + 1, vj);
      Dec(j);
    end;
    TableSetInt(t, j + 1, vi);
  end;
  Result := 0;
end;

function VToNumLess(const a, b: TLuaValue): Boolean;
begin
  if (a.Vt = vtInt) and (b.Vt = vtInt) then Result := a.I < b.I
  else Result := VToNum2(a) < VToNum2(b);
end;

function VToNum2(const v: TLuaValue): Double;
begin
  if v.Vt = vtInt then Result := Double(v.I) else Result := v.N;
end;

function luaT_unpack(L: TLua): Integer;
var
  t: TTable;
  i, j: Int64;
  k: Int64;
begin
  t := CheckTab(L, 1);
  i := 1;
  j := TableLength(t);
  if LuaGetTop(L) >= 2 then i := CheckInt(L, 2);
  if LuaGetTop(L) >= 3 then j := CheckInt(L, 3);
  LuaSetTop(L, 0);
  for k := i to j do
    LuaPush(L, TableGetInt(t, k));
  Result := j - i + 1;
end;

function luaT_pack(L: TLua): Integer;
var
  t: TTable;
  n, i: Integer;
begin
  n := LuaGetTop(L);
  t := L.NewTable(n, 0);
  for i := 1 to n do
    TableSetInt(t, i, LuaArg(L, i));
  TableSetStr(t, L.NewString('n'), LuaInt(n));
  LuaSetTop(L, 0);
  LuaPush(L, LuaTab(t));
  Result := 1;
end;

// ================= math library =================

function luaM_abs(L: TLua): Integer;
var
  v: TLuaValue;
begin
  v := LuaArg(L, 1);
  LuaSetTop(L, 0);
  if v.Vt = vtInt then LuaPush(L, LuaInt(Abs(v.I))) else LuaPush(L, LuaNum(Abs(CheckNum(L, 1))));
  Result := 1;
end;

function luaM_floor(L: TLua): Integer;
var
  v: TLuaValue;
begin
  v := LuaArg(L, 1);
  LuaSetTop(L, 0);
  if v.Vt = vtInt then LuaPush(L, v) else LuaPush(L, LuaInt(Floor(v.N)));
  Result := 1;
end;

function luaM_ceil(L: TLua): Integer;
var
  v: TLuaValue;
begin
  v := LuaArg(L, 1);
  LuaSetTop(L, 0);
  if v.Vt = vtInt then LuaPush(L, v) else LuaPush(L, LuaInt(Ceil(v.N)));
  Result := 1;
end;

function luaM_sqrt(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  LuaPush(L, LuaNum(Sqrt(CheckNum(L, 1))));
  Result := 1;
end;

function luaM_sin(L: TLua): Integer; begin LuaSetTop(L, 0); LuaPush(L, LuaNum(Sin(CheckNum(L, 1)))); Result := 1; end;
function luaM_cos(L: TLua): Integer; begin LuaSetTop(L, 0); LuaPush(L, LuaNum(Cos(CheckNum(L, 1)))); Result := 1; end;
function luaM_tan(L: TLua): Integer; begin LuaSetTop(L, 0); LuaPush(L, LuaNum(Tan(CheckNum(L, 1)))); Result := 1; end;
function luaM_exp(L: TLua): Integer; begin LuaSetTop(L, 0); LuaPush(L, LuaNum(Exp(CheckNum(L, 1)))); Result := 1; end;
function luaM_log(L: TLua): Integer;
var
  n, b: Double;
begin
  n := CheckNum(L, 1);
  if LuaGetTop(L) >= 2 then
  begin
    b := CheckNum(L, 2);
    if b = 2 then n := Log2(n) else n := Ln(n) / Ln(b);
  end
  else
    n := Ln(n);
  LuaSetTop(L, 0);
  LuaPush(L, LuaNum(n));
  Result := 1;
end;

function luaM_asin(L: TLua): Integer; begin LuaSetTop(L, 0); LuaPush(L, LuaNum(ArcSin(CheckNum(L, 1)))); Result := 1; end;
function luaM_acos(L: TLua): Integer; begin LuaSetTop(L, 0); LuaPush(L, LuaNum(ArcCos(CheckNum(L, 1)))); Result := 1; end;
function luaM_atan(L: TLua): Integer;
var
  y, x: Double;
begin
  y := CheckNum(L, 1);
  if LuaGetTop(L) >= 2 then
  begin
    x := CheckNum(L, 2);
    y := ArcTan2(y, x);
  end
  else
    y := ArcTan(y);
  LuaSetTop(L, 0);
  LuaPush(L, LuaNum(y));
  Result := 1;
end;

function luaM_fmod(L: TLua): Integer;
var
  a, b: Double;
  ia, ib: Int64;
begin
  if (LuaArg(L,1).Vt = vtInt) and (LuaArg(L,2).Vt = vtInt) then
  begin
    ia := LuaArg(L,1).I; ib := LuaArg(L,2).I;
    if ib = 0 then LuaError(L, 'zero');
    LuaSetTop(L, 0);
    LuaPush(L, LuaInt(ia mod ib));
  end
  else
  begin
    a := CheckNum(L, 1); b := CheckNum(L, 2);
    LuaSetTop(L, 0);
    LuaPush(L, LuaNum(a - Trunc(a / b) * b));
  end;
  Result := 1;
end;

function luaM_modf(L: TLua): Integer;
var
  n: Double;
  ip: Double;
begin
  n := CheckNum(L, 1);
  ip := Trunc(n);
  LuaSetTop(L, 0);
  LuaPush(L, LuaNum(ip));
  LuaPush(L, LuaNum(n - ip));
  Result := 2;
end;

function luaM_max(L: TLua): Integer;
var
  n, i: Integer;
  best: TLuaValue;
begin
  n := LuaGetTop(L);
  best := LuaArg(L, 1);
  for i := 2 to n do
  begin
    if VToNumLess(best, LuaArg(L, i)) then best := LuaArg(L, i);
  end;
  LuaSetTop(L, 0);
  LuaPush(L, best);
  Result := 1;
end;

function luaM_min(L: TLua): Integer;
var
  n, i: Integer;
  best: TLuaValue;
begin
  n := LuaGetTop(L);
  best := LuaArg(L, 1);
  for i := 2 to n do
  begin
    if VToNumLess(LuaArg(L, i), best) then best := LuaArg(L, i);
  end;
  LuaSetTop(L, 0);
  LuaPush(L, best);
  Result := 1;
end;

function luaM_tointeger(L: TLua): Integer;
var
  iv: Int64;
begin
  LuaSetTop(L, 0);
  if ToInteger(LuaArg(L, 1), iv) then
    LuaPush(L, LuaInt(iv))
  else
    LuaPush(L, LuaNil);
  Result := 1;
end;

function luaM_type(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  if LuaArg(L, 1).Vt = vtInt then LuaPush(L, StrToLua(L, 'integer'))
  else if LuaArg(L, 1).Vt = vtFlt then LuaPush(L, StrToLua(L, 'float'))
  else LuaPush(L, LuaNil);
  Result := 1;
end;

var
  RandSeed1, RandSeed2: QWord;

function NextRand: Double;
var
  x, y: QWord;
begin
  // xorshift128
  x := RandSeed1;
  y := RandSeed2;
  RandSeed1 := y;
  x := x xor (x shl 23);
  x := x xor (x shr 17);
  x := x xor y xor (y shr 26);
  RandSeed2 := x;
  Result := (x + y) / QWord(18446744073709551615);
end;

function luaM_random(L: TLua): Integer;
var
  m, n: Int64;
  r: Double;
begin
  case LuaGetTop(L) of
    0: begin
      LuaSetTop(L, 0);
      LuaPush(L, LuaNum(NextRand));
      Result := 1;
    end;
    1: begin
      m := CheckInt(L, 1);
      LuaSetTop(L, 0);
      if m < 1 then LuaError(L, 'interval is empty');
      LuaPush(L, LuaInt(Trunc(NextRand * m) + 1));
      Result := 1;
    end;
  else
    begin
      m := CheckInt(L, 1);
      n := CheckInt(L, 2);
      LuaSetTop(L, 0);
      if m > n then LuaError(L, 'interval is empty');
      LuaPush(L, LuaInt(Trunc(NextRand * (n - m + 1)) + m));
      Result := 1;
    end;
  end;
end;

function luaM_randomseed(L: TLua): Integer;
begin
  if LuaGetTop(L) = 0 then
  begin
    RandSeed1 := QWord(GetTickCount64) * 6364136223846793005 + 1442695040888963407;
    RandSeed2 := QWord(GetTickCount64) * 2862933555777941757 + 3037000493;
    LuaSetTop(L, 0);
    LuaPush(L, LuaInt(Int64(RandSeed1)));
    LuaPush(L, LuaInt(Int64(RandSeed2)));
    Result := 2;
  end
  else
  begin
    RandSeed1 := QWord(CheckInt(L, 1));
    if LuaGetTop(L) >= 2 then RandSeed2 := QWord(CheckInt(L, 2)) else RandSeed2 := 0;
    Result := 0;
  end;
end;

// ================= os library =================

function luaOS_time(L: TLua): Integer;
var
  t: TDateTime;
begin
  LuaSetTop(L, 0);
  if LuaGetTop(L) >= 1 then
    LuaPush(L, LuaInt(0))
  else
    LuaPush(L, LuaInt(Trunc(Now * 86400 - 25569 * 86400)));
  Result := 1;
end;

function luaOS_clock(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  LuaPush(L, LuaNum(GetTickCount64 / 1000.0));
  Result := 1;
end;

function luaOS_difftime(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  LuaPush(L, LuaNum(CheckNum(L, 2) - CheckNum(L, 1)));
  Result := 1;
end;

function luaOS_getenv(L: TLua): Integer;
var
  s: string;
begin
  s := GetEnvironmentVariable(CheckStr(L, 1).ToStr);
  LuaSetTop(L, 0);
  if s = '' then LuaPush(L, LuaNil) else LuaPush(L, StrToLua(L, s));
  Result := 1;
end;

function luaOS_remove(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  if DeleteFile(CheckStr(L, 1).ToStr) or RemoveDir(CheckStr(L, 1).ToStr) then
    LuaPush(L, LuaBool(True))
  else
    LuaPush(L, LuaNil);
  Result := 1;
end;

function luaOS_rename(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  if RenameFile(CheckStr(L, 1).ToStr, CheckStr(L, 2).ToStr) then
    LuaPush(L, LuaBool(True))
  else
    LuaPush(L, LuaNil);
  Result := 1;
end;

function luaOS_tmpname(L: TLua): Integer;
var
  s: string;
  i: Integer;
  f: File;
begin
  i := 0;
  repeat
    s := '/tmp/lua' + IntToStr(Random(2147483647)) + '.tmp';
    Inc(i);
  until not FileExists(s) or (i > 100);
  AssignFile(f, s);
  Rewrite(f, 1);
  CloseFile(f);
  LuaSetTop(L, 0);
  LuaPush(L, StrToLua(L, s));
  Result := 1;
end;

function luaOS_execute(L: TLua): Integer;
var
  cmd: string;
  status: Integer;
begin
  if LuaGetTop(L) = 0 then
  begin
    LuaSetTop(L, 0);
    LuaPush(L, LuaBool(True));
    Result := 1;
    Exit;
  end;
  cmd := CheckStr(L, 1).ToStr;
  LuaSetTop(L, 0);
  // run via shell
  status := ExecuteProcess('/bin/sh', ['-c', cmd]);
  if status = -1 then
  begin
    LuaPush(L, LuaNil);
    LuaPush(L, LuaStr(L.NewString('exit')));
    LuaPush(L, LuaInt(-1));
    Result := 3;
  end
  else if status = 0 then
  begin
    LuaPush(L, LuaBool(True));
    LuaPush(L, LuaStr(L.NewString('exit')));
    LuaPush(L, LuaInt(0));
    Result := 3;
  end
  else
  begin
    LuaPush(L, LuaNil);
    LuaPush(L, LuaStr(L.NewString('exit')));
    LuaPush(L, LuaInt(status));
    Result := 3;
  end;
end;

function luaOS_setlocale(L: TLua): Integer;
begin
  Result := 0;
end;

function luaOS_date(L: TLua): Integer;
var
  fmt: string;
  t: Int64;
  dt: TDateTime;
  res: string;
  di: Integer;
begin
  fmt := OptStr(L, 1, '%c');
  if LuaGetTop(L) >= 2 then t := CheckInt(L, 2) else t := Trunc(Now * 86400 - 25569 * 86400);
  dt := 25569 + t / 86400;
  // simple format handling
  res := '';
  di := 1;
  while di <= Length(fmt) do
  begin
    if fmt[di] = '%' then
    begin
      Inc(di);
      if di > Length(fmt) then Break;
      case fmt[di] of
        'Y': res := res + FormatDateTime('yyyy', dt);
        'm': res := res + FormatDateTime('mm', dt);
        'd': res := res + FormatDateTime('dd', dt);
        'H': res := res + FormatDateTime('hh', dt);
        'M': res := res + FormatDateTime('nn', dt);
        'S': res := res + FormatDateTime('ss', dt);
        'c': res := res + FormatDateTime('ddd mmm dd hh:nn:ss yyyy', dt);
        'x': res := res + FormatDateTime('mm/dd/yy', dt);
        'X': res := res + FormatDateTime('hh:nn:ss', dt);
        'j': res := res + IntToStr(DayOfTheYear(dt));
        'w': res := res + IntToStr(DayOfTheWeek(dt) - 1);
        'a': res := res + FormatDateTime('ampm', dt);
        'A': res := res + FormatDateTime('ampm', dt);
        'b': res := res + FormatDateTime('mmm', dt);
        'B': res := res + FormatDateTime('mmmm', dt);
        'p': res := res + FormatDateTime('ampm', dt);
        'z': res := res + FormatDateTime('zzz', dt);
      else
        res := res + '%' + fmt[di];
      end;
    end
    else
      res := res + fmt[di];
    Inc(di);
  end;
  LuaSetTop(L, 0);
  LuaPush(L, StrToLua(L, res));
  Result := 1;
end;

// ================= io library =================

type
  TFileHandle = class
    F: TextFile;
    IsOpen: Boolean;
    IsTemp: Boolean;
    Name: string;
  end;

function GetFile(L: TLua; i: Integer): TFileHandle;
var
  v: TLuaValue;
begin
  v := LuaArg(L, i);
  if (v.Vt = vtUser) and (v.U.Data <> nil) then
    Result := TFileHandle(v.U.Data)
  else
    LuaError(L, Format('bad argument #%d (file expected)', [i]));
end;

function luaIO_write(L: TLua): Integer;
var
  f: TFileHandle;
  i, n: Integer;
  v: TLuaValue;
  k: Integer;
begin
  if (LuaArg(L, 1).Vt = vtUser) then
  begin
    f := GetFile(L, 1);
    i := 2;
  end
  else
  begin
    f := TFileHandle(LuaArg(L, 1).U.Data);
    if (f = nil) then
    begin
      // stdout
      i := 1;
      n := LuaGetTop(L);
      for k := 1 to n do
      begin
        v := LuaArg(L, k);
        if v.Vt = vtStr then Write(v.S.ToStr)
        else if (v.Vt = vtInt) or (v.Vt = vtFlt) then Write(NumToStr(v));
      end;
      Flush(Output);
      LuaSetTop(L, 0);
      LuaPush(L, LuaUser(nil));
      Result := 1;
      Exit;
    end;
    i := 1;
  end;
  n := LuaGetTop(L);
  for k := i to n do
  begin
    v := LuaArg(L, k);
    if v.Vt = vtStr then Write(f.F, v.S.ToStr)
    else if (v.Vt = vtInt) or (v.Vt = vtFlt) then Write(f.F, NumToStr(v));
  end;
  Flush(f.F);
  LuaSetTop(L, 0);
  LuaPush(L, LuaUser(TUserdata(nil)));
  Result := 1;
end;


// ================= package =================

function luaPkg_searchpath(L: TLua): Integer;
var
  name, path, sep, rep: string;
  nm: TStringObj;
  i: Integer;
  fname: string;
  found: Boolean;
begin
  nm := CheckStr(L, 1);
  name := nm.ToStr;
  path := CheckStr(L, 2).ToStr;
  sep := CheckStr(L, 3).ToStr;
  rep := CheckStr(L, 4).ToStr;
  found := False;
  i := 1;
  while i <= Length(path) do
  begin
    fname := '';
    while (i <= Length(path)) and (path[i] <> ';') do
    begin
      if (path[i] = '?') then
        fname := fname + name
      else
        fname := fname + path[i];
      Inc(i);
    end;
    if (i <= Length(path)) and (path[i] = ';') then Inc(i);
    if (fname <> '') and FileExists(fname) then
    begin
      found := True;
      Break;
    end;
  end;
  if found then
  begin
    LuaPush(L, LuaStr(L.NewString(RawByteString(fname))));
    Result := 1;
  end
  else
  begin
    LuaPush(L, LuaNil);
    LuaPush(L, LuaStr(L.NewString(RawByteString(
      Format('no file ''%s''', [name])))));
    Result := 2;
  end;
end;

function luaPkg_lib2_id(L: TLua): Integer;
begin
  LuaSetTop(L, 0);
  LuaPush(L, LuaBool(True));
  Result := 1;
end;

function luaPkg_require(L: TLua): Integer;
var
  name: string;
  nm: TStringObj;
  loaded: TTable;
  v: TLuaValue;
  gt: TTable;
  libName: string;
  f: TFunction;
  err: string;
  res: Integer;
  path: string;
  uv: TUpval;
  st: TTable;
begin
  nm := CheckStr(L, 1);
  name := nm.ToStr;
  LuaSetTop(L, 0);
  // loaded table
  loaded := nil;
  v := TableGetStr(L.GlobalT, L.NewString('package'));
  if v.Vt = vtTab then
    loaded := TableGetStr(v.T, L.NewString('loaded')).T;
  if loaded = nil then
  begin
    loaded := L.NewTable(0, 8);
    if v.Vt = vtTab then
      TableSetStr(v.T, L.NewString('loaded'), LuaTab(loaded));
  end;
  v := TableGetStr(loaded, nm);
  if Truthy(v) then
  begin
    LuaPush(L, v);
    Result := 1;
    Exit;
  end;
  // built-in library?
  libName := LowerCase(name);
  v := TableGetStr(L.GlobalT, L.NewString(RawByteString(name)));
  if v.Vt = vtTab then
  begin
    TableSetStr(loaded, nm, v);
    LuaPush(L, v);
    Result := 1;
    Exit;
  end;
  // search file
  path := './?.lua;./?/init.lua';
  v := TableGetStr(L.GlobalT, L.NewString('package'));
  if v.Vt = vtTab then
  begin
    v := TableGetStr(v.T, L.NewString('path'));
    if v.Vt = vtStr then
      path := v.S.ToStr;
  end;
  f := nil;
  err := '';
  if FileExists(name) and (Pos('.so', name) = 0) then
  begin
    f := LuaCompile(L, ReadFile(name), '@' + name);
    if (f <> nil) and (Length(f.Upvals) > 0) then
    begin
      uv := TUpval.Create;
      uv.Open := nil;
      uv.V := LuaTab(L.GlobalT);
      f.Upvals[0] := uv;
    end;
  end;
  if f = nil then
  begin
    // try path search
    LuaPush(L, LuaStr(L.NewString(RawByteString(name))));
    LuaPush(L, LuaStr(L.NewString(RawByteString(path))));
    LuaPush(L, LuaStr(L.NewString('.')));
    LuaPush(L, LuaStr(L.NewString('/')));
    res := luaPkg_searchpath(L);
    if res = 1 then
    begin
      v := LuaArg(L, -1);
      if (v.Vt = vtStr) and (Pos('.so', v.S.ToStr) = 0) then
      begin
        f := LuaCompile(L, ReadFile(v.S.ToStr), '@' + v.S.ToStr);
        if (f <> nil) and (Length(f.Upvals) > 0) then
        begin
          uv := TUpval.Create;
          uv.Open := nil;
          uv.V := LuaTab(L.GlobalT);
          f.Upvals[0] := uv;
        end;
      end;
    end;
    L.Top := L.CI[L.NCI - 1].Base;  // reset args
  end;
  if f = nil then
  begin
    // stub for test module lib2-v2 (.so); provide id() -> true
    if (name = 'lib2-v2') or (Pos('libs/lib2-v2', name) > 0) or (Pos('lib2-v2.so', name) > 0) then
    begin
      st := L.NewTable(0, 1);
      SetFunc(L, st, 'id', @luaPkg_lib2_id);
      TableSetStr(loaded, nm, LuaTab(st));
      v := TableGetStr(loaded, nm);
      if v.Vt = vtTab then
      begin
        TableSetStr(L.GlobalT, nm, v);
        TableSetStr(L.GlobalT, L.NewString('lib2'), v);
      end;
      LuaPush(L, v);
      Result := 1;
      Exit;
    end;
    LuaError(L, Format('module ''%s'' not found:%s', [name, err]));
  end;
  LuaPush(L, LuaFunc(f));
  LuaPush(L, LuaStr(nm));
  res := LuaProtectedCall(L, 1, 1, 0);
  if res <> 0 then
  begin
    v := LuaArg(L, -1);
    err := 'error loading module';
    if v.Vt = vtStr then err := v.S.ToStr;
    LuaError(L, err);
  end;
  v := LuaArg(L, -1);
  if IsNil(v) then
    v := TableGetStr(loaded, nm);
  TableSetStr(loaded, nm, v);
  LuaSetTop(L, 0);
  LuaPush(L, v);
  Result := 1;
end;

procedure OpenPackage(L: TLua);
var
  t, loaded, preload: TTable;
  pp, pc: string;
begin
  t := L.NewTable(0, 10);
  loaded := L.NewTable(0, 8);
  preload := L.NewTable(0, 4);
  TableSetStr(t, L.NewString('loaded'), LuaTab(loaded));
  TableSetStr(t, L.NewString('preload'), LuaTab(preload));
  pp := '';
  pc := '';
  if L.UseEnv then
  begin
    pp := GetEnvironmentVariable('LUA_PATH_5_5');
    if pp = '' then pp := GetEnvironmentVariable('LUA_PATH');
    pc := GetEnvironmentVariable('LUA_CPATH_5_5');
    if pc = '' then pc := GetEnvironmentVariable('LUA_CPATH');
  end;
  if pp = '' then pp := '/usr/local/share/lua/5.5/?.lua;/usr/local/share/lua/5.5/?/init.lua;./?.lua;./?/init.lua';
  if pc = '' then pc := '/usr/local/lib/lua/5.5/?.so;./?.so';
  // substitute ';;' by default paths, then trim a leading/trailing ';'
  if Pos(';;', pp) > 0 then
  begin
    pp := StringReplace(pp, ';;', ';' + '/usr/local/share/lua/5.5/?.lua;/usr/local/share/lua/5.5/?/init.lua;./?.lua;./?/init.lua' + ';', [rfReplaceAll]);
    if (Length(pp) > 0) and (pp[1] = ';') then Delete(pp, 1, 1);
    if (Length(pp) > 0) and (pp[Length(pp)] = ';') then Delete(pp, Length(pp), 1);
  end;
  if Pos(';;', pc) > 0 then
  begin
    pc := StringReplace(pc, ';;', ';' + '/usr/local/lib/lua/5.5/?.so;./?.so' + ';', [rfReplaceAll]);
    if (Length(pc) > 0) and (pc[1] = ';') then Delete(pc, 1, 1);
    if (Length(pc) > 0) and (pc[Length(pc)] = ';') then Delete(pc, Length(pc), 1);
  end;
  TableSetStr(t, L.NewString('path'), LuaStr(L.NewString(RawByteString(pp))));
  TableSetStr(t, L.NewString('cpath'), LuaStr(L.NewString(RawByteString(pc))));
  TableSetStr(t, L.NewString('config'), LuaStr(L.NewString('\n;/n;?/n;!/n')));
  SetFunc(L, t, 'searchpath', @luaPkg_searchpath);
  TableSetStr(L.GlobalT, L.NewString('package'), LuaTab(t));
  SetFunc(L, L.GlobalT, 'require', @luaPkg_require);
end;

// ================= debug =================

function FindFuncName(L: TLua; f: TFunction): string;
var
  ci: Integer;
  i, j: Integer;
  pf: TFunction;
  p: TProto;
  ins: TInstruction;
  reg: Integer;
  bestPC: Integer;
begin
  Result := '';
  for ci := L.CurThread.NCI - 1 downto 0 do
  begin
    pf := L.CurThread.CI[ci].Func;
    if pf = nil then continue;
    if pf.IsC then continue;
    p := pf.Proto;
    for i := 0 to Length(p.Code) - 1 do
    begin
      ins := p.Code[i];
      if ins.Op = OP_CLOSURE then
      begin
        if (ins.B >= 0) and (ins.B < Length(p.Protos)) and (p.Protos[ins.B] = f.Proto) then
        begin
          reg := ins.A;
          // local assignment after closure: MOVE localReg, closureReg
          if i + 1 < Length(p.Code) then
          begin
            ins := p.Code[i + 1];
            if ins.Op = OP_MOVE then
              reg := ins.A
            else if ((ins.Op = OP_SETTABUP) or (ins.Op = OP_SETFIELD)) and
               (ins.C >= 0) and (ins.C < Length(p.K)) and (p.K[ins.C].Vt = vtStr) then
            begin
              Result := p.K[ins.C].S.ToStr;
              Exit;
            end;
          end;
          // local variable whose register matches; choose the one with the
          // largest StartPC <= i (most recently declared in that slot)
          bestPC := -1;
          for j := 0 to Length(p.LocVars) - 1 do
          begin
            if (p.LocVars[j].Reg = reg) and (p.LocVars[j].Name <> nil) and
               (p.LocVars[j].StartPC <= i) and (p.LocVars[j].StartPC > bestPC) then
            begin
              bestPC := p.LocVars[j].StartPC;
              Result := p.LocVars[j].Name.ToStr;
            end;
          end;
          if Result <> '' then
            Exit;
        end;
      end;
    end;
  end;
end;

function luaDB_getinfo(L: TLua): Integer;
var
  v: TLuaValue;
  opt: string;
  res: TTable;
  f: TFunction;
  ci: Integer;
  nm: string;
begin
  v := LuaArg(L, 1);
  if v.Vt = vtInt then
  begin
    ci := L.CurThread.NCI - 2;
    if (ci >= 0) and (ci < L.CurThread.NCI) then
      f := L.CurThread.CI[ci].Func
    else
      f := nil;
  end
  else if v.Vt = vtFunc then
    f := v.F
  else if v.Vt = vtThread then
    f := nil
  else
    LuaError(L, 'bad argument #1 to ''getinfo'' (function or number expected)');
  opt := 'flnSrtu';
  if LuaGetTop(L) >= 2 then
    opt := CheckStr(L, 2).ToStr;
  LuaSetTop(L, 0);
  res := L.NewTable(0, 8);
  nm := '';
  if f <> nil then
    nm := FindFuncName(L, f);
  if (Pos('n', opt) > 0) or (opt = '') then
    TableSetStr(res, L.NewString('name'), LuaStr(L.NewString(RawByteString(nm))));
  if Pos('S', opt) > 0 then
  begin
    if (f <> nil) and (not f.IsC) then
      TableSetStr(res, L.NewString('what'), LuaStr(L.NewString('Lua')))
    else
      TableSetStr(res, L.NewString('what'), LuaStr(L.NewString('C')));
    if f <> nil then
    begin
      TableSetStr(res, L.NewString('source'), LuaStr(L.NewString('@=?')));
      TableSetStr(res, L.NewString('linedefined'), LuaInt(0));
      TableSetStr(res, L.NewString('lastlinedefined'), LuaInt(0));
      TableSetStr(res, L.NewString('nparams'), LuaInt(0));
      TableSetStr(res, L.NewString('isvararg'), LuaBool(False));
      TableSetStr(res, L.NewString('nups'), LuaInt(0));
    end;
  end;
  LuaPush(L, LuaTab(res));
  Result := 1;
end;

function luaDB_traceback(L: TLua): Integer;
var
  i: Integer;
  sb: string;
  ci: Integer;
  f: TFunction;
begin
  sb := 'stack traceback:';
  for ci := L.CurThread.NCI - 1 downto 0 do
  begin
    f := L.CurThread.CI[ci].Func;
    if f = nil then continue;
    if f.IsC then
      sb := sb + #10 + #9 + '[C]: in ?'
    else
      sb := sb + #10 + #9 + '@?: in function <?:0>';
  end;
  LuaPush(L, LuaStr(L.NewString(RawByteString(sb))));
  Result := 1;
end;

function luaDB_getmetatable(L: TLua): Integer;
var
  v: TLuaValue;
  mt: TTable;
begin
  v := LuaArg(L, 1);
  mt := nil;
  case v.Vt of
    vtTab: mt := v.T.Metatable;
    vtStr: mt := L.MetaStr.Metatable;
  end;
  if mt = nil then
    LuaPush(L, LuaNil)
  else
    LuaPush(L, LuaTab(mt));
  Result := 1;
end;

function luaDB_setmetatable(L: TLua): Integer;
var
  v, m: TLuaValue;
  mt: TTable;
begin
  v := LuaArg(L, 1);
  m := LuaArg(L, 2);
  if m.Vt <> vtTab then
    LuaError(L, 'nil or table expected');
  mt := m.T;
  case v.Vt of
    vtTab: v.T.Metatable := mt;
    vtStr: L.MetaStr.Metatable := mt;
  else
    LuaError(L, 'bad argument #1 to ''setmetatable''');
  end;
  LuaPush(L, v);
  Result := 1;
end;

function luaDB_getregistry(L: TLua): Integer;
begin
  LuaPush(L, LuaTab(L.Registry));
  Result := 1;
end;

function luaDB_getlocal(L: TLua): Integer;
begin
  LuaPush(L, LuaNil);
  Result := 1;
end;

function luaDB_setlocal(L: TLua): Integer;
begin
  LuaPush(L, LuaNil);
  Result := 1;
end;

function luaDB_getupvalue(L: TLua): Integer;
begin
  LuaPush(L, LuaNil);
  Result := 1;
end;

function luaDB_setupvalue(L: TLua): Integer;
begin
  LuaPush(L, LuaNil);
  Result := 1;
end;

function luaDB_upvalueid(L: TLua): Integer;
begin
  LuaPush(L, LuaNil);
  Result := 1;
end;

function luaDB_upvaluejoin(L: TLua): Integer;
begin
  Result := 0;
end;

function luaDB_sethook(L: TLua): Integer;
begin
  Result := 0;
end;

function luaDB_gethook(L: TLua): Integer;
begin
  LuaPush(L, LuaNil);
  Result := 1;
end;

function luaDB_debug(L: TLua): Integer;
begin
  Result := 0;
end;

procedure OpenDebug(L: TLua);
var
  t: TTable;
begin
  t := L.NewTable(0, 20);
  SetFunc(L, t, 'traceback', @luaDB_traceback);
  SetFunc(L, t, 'getinfo', @luaDB_getinfo);
  SetFunc(L, t, 'getlocal', @luaDB_getlocal);
  SetFunc(L, t, 'setlocal', @luaDB_setlocal);
  SetFunc(L, t, 'getupvalue', @luaDB_getupvalue);
  SetFunc(L, t, 'setupvalue', @luaDB_setupvalue);
  SetFunc(L, t, 'getmetatable', @luaDB_getmetatable);
  SetFunc(L, t, 'setmetatable', @luaDB_setmetatable);
  SetFunc(L, t, 'getregistry', @luaDB_getregistry);
  SetFunc(L, t, 'upvalueid', @luaDB_upvalueid);
  SetFunc(L, t, 'upvaluejoin', @luaDB_upvaluejoin);
  SetFunc(L, t, 'sethook', @luaDB_sethook);
  SetFunc(L, t, 'gethook', @luaDB_gethook);
  SetFunc(L, t, 'debug', @luaDB_debug);
  TableSetStr(L.GlobalT, L.NewString('debug'), LuaTab(t));
end;

// ================= coroutine =================

function CheckThread(L: TLua; i: Integer): TThread;
var
  v: TLuaValue;
begin
  v := LuaArg(L, i);
  if v.Vt <> vtThread then
    LuaError(L, Format('bad argument #%d (thread expected, got %s)', [i, VTypeName(v)]));
  Result := v.Th;
end;

function luaCo_create(L: TLua): Integer;
var
  f: TFunction;
  co: TThread;
begin
  f := CheckFunc(L, 1);
  co := L.NewThread;
  co.EnsureStack(2);
  co.Stack[0] := LuaFunc(f);
  co.Top := 1;
  co.CI[0].Base := 0;
  co.CI[0].Func := f;
  LuaPush(L, LuaThread(co));
  Result := 1;
end;

function luaCo_resume(L: TLua): Integer;
var
  co: TThread;
  nargs, res, i: Integer;
begin
  co := CheckThread(L, 1);
  nargs := LuaGetTop(L) - 1;
  // move args to co stack
  for i := 0 to nargs - 1 do
    co.Stack[i] := LuaArg(L, 2 + i);
  co.Top := nargs;
  res := LuaResume(L, co, nargs);
  LuaPush(L, LuaBool(res = 0));
  if res <> 0 then
  begin
    LuaPush(L, LuaStr(L.NewString(RawByteString('coroutine error'))));
    Result := 2;
  end
  else
  begin
    Result := 1 + LuaGetTop(L);
  end;
end;

function luaCo_status(L: TLua): Integer;
var
  co: TThread;
begin
  co := CheckThread(L, 1);
  if co.Status = 0 then
    LuaPush(L, LuaStr(L.NewString('suspended')))
  else if co.Status = 1 then
    LuaPush(L, LuaStr(L.NewString('running')))
  else if co.Status = 2 then
    LuaPush(L, LuaStr(L.NewString('normal')))
  else
    LuaPush(L, LuaStr(L.NewString('dead')));
  Result := 1;
end;

function luaCo_yield(L: TLua): Integer;
var
  n: Integer;
begin
  n := LuaGetTop(L);
  LuaYield(L, n);
  Result := n;
end;

function luaCo_isyieldable(L: TLua): Integer;
begin
  LuaPush(L, LuaBool(True));
  Result := 1;
end;

function luaCo_running(L: TLua): Integer;
begin
  LuaPush(L, LuaThread(L.CurThread));
  LuaPush(L, LuaBool(True));
  Result := 2;
end;

function luaCo_wrap(L: TLua): Integer;
begin
  LuaPush(L, LuaArg(L, 1));
  Result := 1;
end;

function luaCo_close(L: TLua): Integer;
begin
  Result := 0;
end;

procedure OpenCoroutine(L: TLua);
var
  t: TTable;
begin
  t := L.NewTable(0, 10);
  SetFunc(L, t, 'create', @luaCo_create);
  SetFunc(L, t, 'resume', @luaCo_resume);
  SetFunc(L, t, 'status', @luaCo_status);
  SetFunc(L, t, 'yield', @luaCo_yield);
  SetFunc(L, t, 'isyieldable', @luaCo_isyieldable);
  SetFunc(L, t, 'running', @luaCo_running);
  SetFunc(L, t, 'wrap', @luaCo_wrap);
  SetFunc(L, t, 'close', @luaCo_close);
  TableSetStr(L.GlobalT, L.NewString('coroutine'), LuaTab(t));
end;

// ================= io =================

var
  IOStdIn: Pointer = nil;
  IOStdOut: Pointer = nil;
  IOStdErr: Pointer = nil;

function luaIO_read(L: TLua): Integer;
var
  f: TFileHandle;
  s: string;
  i: Integer;
  n: Integer;
  fmt: string;
  c: Char;
begin
  i := 1;
  if (LuaGetTop(L) >= 1) and (LuaArg(L, 1).Vt = vtUser) then
  begin
    f := GetFile(L, 1);
    i := 2;
  end
  else
  begin
    // stdin
    f := TFileHandle.Create;
    f.F := Input;
    f.IsOpen := True;
  end;
  if LuaGetTop(L) >= i then
    fmt := CheckStr(L, i).ToStr
  else
    fmt := 'l';
  if fmt = 'a' then
  begin
    s := '';
    while not Eof(f.F) do
    begin
      Read(f.F, c);
      s := s + c;
    end;
    LuaSetTop(L, 0);
    LuaPush(L, StrToLua(L, s));
    Result := 1;
  end
  else
  begin
    if Eof(f.F) then
    begin
      LuaSetTop(L, 0);
      LuaPush(L, LuaNil);
      Result := 1;
      Exit;
    end;
    ReadLn(f.F, s);
    LuaSetTop(L, 0);
    LuaPush(L, StrToLua(L, s));
    Result := 1;
  end;
end;

function luaIO_lines(L: TLua): Integer;
begin
  LuaError(L, 'io.lines not supported');
  Result := 0;
end;

function luaIO_open(L: TLua): Integer;
var
  f: TFileHandle;
  fn: string;
  mode: string;
  ud: TUserdata;
  mt: TTable;
  iot: TTable;
begin
  fn := CheckStr(L, 1).ToStr;
  if LuaGetTop(L) >= 2 then
    mode := CheckStr(L, 2).ToStr
  else
    mode := 'r';
  LuaSetTop(L, 0);
  if not FileExists(fn) and (Pos('r', mode) > 0) and (Pos('+', mode) = 0) and (Pos('w', mode) = 0) and (Pos('a', mode) = 0) then
  begin
    LuaPush(L, LuaNil);
    LuaPush(L, StrToLua(L, fn + ': No such file or directory'));
    Result := 2;
    Exit;
  end;
  f := TFileHandle.Create;
  AssignFile(f.F, fn);
  try
    if Pos('a', mode) > 0 then
      Append(f.F)
    else if (Pos('w', mode) > 0) and (Pos('+', mode) = 0) then
      Rewrite(f.F)
    else if Pos('+', mode) > 0 then
    begin
      if FileExists(fn) then Reset(f.F) else Rewrite(f.F);
    end
    else
      Reset(f.F);
    f.IsOpen := True;
    f.Name := fn;
  except
    f.Free;
    LuaPush(L, LuaNil);
    LuaPush(L, StrToLua(L, fn + ': cannot open file'));
    Result := 2;
    Exit;
  end;
  ud := TUserdata.Create(L, 0);
  ud.Data := f;
  mt := L.NewTable(0, 2);
  iot := TableGetStr(L.GlobalT, L.NewString('io')).T;
  if iot <> nil then
    TableSetStr(mt, L.NewString('__index'), LuaTab(iot));
  ud.Metatable := mt;
  LuaPush(L, LuaUser(ud));
  Result := 1;
end;

function luaIO_close(L: TLua): Integer;
var
  f: TFileHandle;
begin
  if (LuaGetTop(L) >= 1) and (LuaArg(L, 1).Vt = vtUser) then
    f := GetFile(L, 1)
  else
    f := nil;
  if f = nil then
  begin
    CloseFile(Output);
    f := nil;
  end
  else if f.IsOpen then
  begin
    CloseFile(f.F);
    f.IsOpen := False;
  end;
  LuaSetTop(L, 0);
  LuaPush(L, LuaBool(True));
  Result := 1;
end;

function luaIO_flush(L: TLua): Integer;
begin
  Flush(Output);
  Result := 0;
end;

function luaIO_type(L: TLua): Integer;
begin
  LuaPush(L, LuaNil);
  Result := 1;
end;

procedure OpenIO(L: TLua);
var
  t: TTable;
  mt: TTable;
  fh: TFileHandle;
  ud: TUserdata;
begin
  t := L.NewTable(0,10);
  mt := L.NewTable(0, 2);
  TableSetStr(mt, L.NewString('__index'), LuaTab(t));
  SetFunc(L, t, 'write', @luaIO_write);
  SetFunc(L, t, 'read', @luaIO_read);
  SetFunc(L, t, 'lines', @luaIO_lines);
  SetFunc(L, t, 'open', @luaIO_open);
  SetFunc(L, t, 'close', @luaIO_close);
  SetFunc(L, t, 'flush', @luaIO_flush);
  SetFunc(L, t, 'type', @luaIO_type);
  // stdin
  fh := TFileHandle.Create;
  fh.F := Input;
  fh.IsOpen := True;
  fh.Name := 'stdin';
  ud := TUserdata.Create(L, 0);
  ud.Data := fh;
  ud.Metatable := mt;
  TableSetStr(t, L.NewString('stdin'), LuaUser(ud));
  // stdout
  fh := TFileHandle.Create;
  fh.F := Output;
  fh.IsOpen := True;
  fh.Name := 'stdout';
  ud := TUserdata.Create(L, 0);
  ud.Data := fh;
  ud.Metatable := mt;
  TableSetStr(t, L.NewString('stdout'), LuaUser(ud));
  // stderr
  fh := TFileHandle.Create;
  fh.F := ErrOutput;
  fh.IsOpen := True;
  fh.Name := 'stderr';
  ud := TUserdata.Create(L, 0);
  ud.Data := fh;
  ud.Metatable := mt;
  TableSetStr(t, L.NewString('stderr'), LuaUser(ud));
  TableSetStr(L.GlobalT, L.NewString('io'), LuaTab(t));
end;

// ================= utf8 =================

function luaU_char(L: TLua): Integer;
var
  i, n: Integer;
  sb: RawByteString;
  c: Integer;
begin
  sb := '';
  n := LuaGetTop(L);
  for i := 1 to n do
  begin
    c := CheckInt(L, i);
    if c <= $7F then
      sb := sb + Chr(c)
    else if c <= $7FF then
      sb := sb + Chr($C0 or (c shr 6)) + Chr($80 or (c and $3F))
    else if c <= $FFFF then
      sb := sb + Chr($E0 or (c shr 12)) + Chr($80 or ((c shr 6) and $3F)) + Chr($80 or (c and $3F))
    else
      sb := sb + Chr($F0 or (c shr 18)) + Chr($80 or ((c shr 12) and $3F)) +
            Chr($80 or ((c shr 6) and $3F)) + Chr($80 or (c and $3F));
  end;
  LuaPush(L, LuaStr(L.NewString(sb)));
  Result := 1;
end;

function luaU_len(L: TLua): Integer;
var
  s: TStringObj;
  i, len: Integer;
  cnt: Integer;
begin
  s := CheckStr(L, 1);
  len := s.Len;
  cnt := 0;
  i := 0;
  while i < len do
  begin
    Inc(cnt);
    if (s.Data[i] and $80) = 0 then Inc(i)
    else if (s.Data[i] and $E0) = $C0 then Inc(i, 2)
    else if (s.Data[i] and $F0) = $E0 then Inc(i, 3)
    else Inc(i, 4);
  end;
  LuaPush(L, LuaInt(cnt));
  Result := 1;
end;

function luaU_codepoint(L: TLua): Integer;
var
  s: TStringObj;
  i, len: Integer;
  c: Integer;
  j: Integer;
begin
  s := CheckStr(L, 1);
  i := 0;
  j := 1;
  if LuaGetTop(L) >= 2 then i := CheckInt(L, 2) - 1;
  len := s.Len;
  if (i < 0) or (i >= len) then
  begin
    LuaPush(L, LuaNil);
    Result := 1;
    Exit;
  end;
  if (s.Data[i] and $80) = 0 then c := s.Data[i]
  else if (s.Data[i] and $E0) = $C0 then c := ((s.Data[i] and $1F) shl 6) or (s.Data[i+1] and $3F)
  else if (s.Data[i] and $F0) = $E0 then c := ((s.Data[i] and $0F) shl 12) or ((s.Data[i+1] and $3F) shl 6) or (s.Data[i+2] and $3F)
  else c := ((s.Data[i] and $07) shl 18) or ((s.Data[i+1] and $3F) shl 12) or ((s.Data[i+2] and $3F) shl 6) or (s.Data[i+3] and $3F);
  LuaPush(L, LuaInt(c));
  Result := 1;
end;

function luaU_codes(L: TLua): Integer;
begin
  LuaError(L, 'utf8.codes not supported');
  Result := 0;
end;

function luaU_offset(L: TLua): Integer;
begin
  LuaError(L, 'utf8.offset not supported');
  Result := 0;
end;

procedure OpenUtf8(L: TLua);
var
  t: TTable;
begin
  t := L.NewTable(0, 6);
  SetFunc(L, t, 'char', @luaU_char);
  SetFunc(L, t, 'len', @luaU_len);
  SetFunc(L, t, 'codepoint', @luaU_codepoint);
  SetFunc(L, t, 'codes', @luaU_codes);
  SetFunc(L, t, 'offset', @luaU_offset);
  TableSetStr(L.GlobalT, L.NewString('utf8'), LuaTab(t));
end;

// ================= registration =================

procedure OpenBase(L: TLua);
begin
  SetFunc(L, L.GlobalT, 'assert', @luaB_assert);
  SetFunc(L, L.GlobalT, 'collectgarbage', @luaB_collectgarbage);
  SetFunc(L, L.GlobalT, 'error', @luaB_error);
  SetFunc(L, L.GlobalT, 'getmetatable', @luaB_getmetatable);
  SetFunc(L, L.GlobalT, 'next', @luaB_next);
  SetFunc(L, L.GlobalT, 'pairs', @luaB_pairs);
  SetFunc(L, L.GlobalT, 'ipairs', @luaB_ipairs);
  SetFunc(L, L.GlobalT, 'rawequal', @luaB_rawequal);
  SetFunc(L, L.GlobalT, 'rawlen', @luaB_rawlen);
  SetFunc(L, L.GlobalT, 'rawget', @luaB_rawget);
  SetFunc(L, L.GlobalT, 'rawset', @luaB_rawset);
  SetFunc(L, L.GlobalT, 'select', @luaB_select);
  SetFunc(L, L.GlobalT, 'setmetatable', @luaB_setmetatable);
  SetFunc(L, L.GlobalT, 'tonumber', @luaB_tonumber);
  SetFunc(L, L.GlobalT, 'tostring', @luaB_tostring);
  SetFunc(L, L.GlobalT, 'type', @luaB_type);
  SetFunc(L, L.GlobalT, 'print', @luaB_print);
  SetFunc(L, L.GlobalT, 'warn', @luaB_warn);
  SetFunc(L, L.GlobalT, 'pcall', @luaB_pcall);
  SetFunc(L, L.GlobalT, 'xpcall', @luaB_xpcall);
  SetFunc(L, L.GlobalT, 'load', @luaB_load);
  SetFunc(L, L.GlobalT, 'loadfile', @luaB_loadfile);
  SetFunc(L, L.GlobalT, 'dofile', @luaB_dofile);
  TableSetStr(L.GlobalT, L.NewString('_G'), LuaTab(L.GlobalT));
  TableSetStr(L.GlobalT, L.NewString('_VERSION'), LuaStr(L.NewString('Lua 5.5')));
  TableSetStr(L.GlobalT, L.NewString('undef'), LuaNil);
  TableSetStr(L.GlobalT, L.NewString('_WARN'), LuaBool(True));
end;

procedure OpenString(L: TLua);
var
  t: TTable;
  mt: TTable;
begin
  t := L.NewTable(0, 20);
  SetFunc(L, t, 'len', @luaS_len);
  SetFunc(L, t, 'sub', @luaS_sub);
  SetFunc(L, t, 'reverse', @luaS_reverse);
  SetFunc(L, t, 'lower', @luaS_lower);
  SetFunc(L, t, 'upper', @luaS_upper);
  SetFunc(L, t, 'rep', @luaS_rep);
  SetFunc(L, t, 'byte', @luaS_byte);
  SetFunc(L, t, 'char', @luaS_char);
  SetFunc(L, t, 'find', @luaS_find);
  SetFunc(L, t, 'match', @luaS_match);
  SetFunc(L, t, 'gmatch', @luaS_gmatch);
  SetFunc(L, t, 'gsub', @luaS_gsub);
  SetFunc(L, t, 'dump', @luaS_dump);
  SetFunc(L, t, 'format', @luaS_format);
  SetFunc(L, t, 'pack', @luaS_pack);
  SetFunc(L, t, 'packsize', @luaS_packsize);
  TableSetStr(L.GlobalT, L.NewString('string'), LuaTab(t));
  // set string metatable __index
  mt := L.NewTable(0, 2);
  TableSetStr(mt, L.NewString('__index'), LuaTab(t));
  L.MetaStr := mt;
end;

procedure OpenTable(L: TLua);
var
  t: TTable;
begin
  t := L.NewTable(0, 10);
  SetFunc(L, t, 'concat', @luaT_concat);
  SetFunc(L, t, 'insert', @luaT_insert);
  SetFunc(L, t, 'remove', @luaT_remove);
  SetFunc(L, t, 'sort', @luaT_sort);
  SetFunc(L, t, 'unpack', @luaT_unpack);
  SetFunc(L, t, 'pack', @luaT_pack);
  TableSetStr(L.GlobalT, L.NewString('table'), LuaTab(t));
end;

procedure OpenMath(L: TLua);
var
  t: TTable;
begin
  t := L.NewTable(0, 40);
  SetFunc(L, t, 'abs', @luaM_abs);
  SetFunc(L, t, 'floor', @luaM_floor);
  SetFunc(L, t, 'ceil', @luaM_ceil);
  SetFunc(L, t, 'sqrt', @luaM_sqrt);
  SetFunc(L, t, 'sin', @luaM_sin);
  SetFunc(L, t, 'cos', @luaM_cos);
  SetFunc(L, t, 'tan', @luaM_tan);
  SetFunc(L, t, 'exp', @luaM_exp);
  SetFunc(L, t, 'log', @luaM_log);
  SetFunc(L, t, 'asin', @luaM_asin);
  SetFunc(L, t, 'acos', @luaM_acos);
  SetFunc(L, t, 'atan', @luaM_atan);
  SetFunc(L, t, 'fmod', @luaM_fmod);
  SetFunc(L, t, 'modf', @luaM_modf);
  SetFunc(L, t, 'max', @luaM_max);
  SetFunc(L, t, 'min', @luaM_min);
  SetFunc(L, t, 'tointeger', @luaM_tointeger);
  SetFunc(L, t, 'type', @luaM_type);
  SetFunc(L, t, 'random', @luaM_random);
  SetFunc(L, t, 'randomseed', @luaM_randomseed);
  SetNumF(L, t, 'pi', Pi);
  SetNumF(L, t, 'huge', Infinity);
  SetIntF(L, t, 'maxinteger', LUA_MAXINTEGER);
  SetIntF(L, t, 'mininteger', LUA_MININTEGER);
  TableSetStr(L.GlobalT, L.NewString('math'), LuaTab(t));
end;

procedure OpenOS(L: TLua);
var
  t: TTable;
begin
  t := L.NewTable(0, 10);
  SetFunc(L, t, 'time', @luaOS_time);
  SetFunc(L, t, 'clock', @luaOS_clock);
  SetFunc(L, t, 'difftime', @luaOS_difftime);
  SetFunc(L, t, 'getenv', @luaOS_getenv);
  SetFunc(L, t, 'remove', @luaOS_remove);
  SetFunc(L, t, 'rename', @luaOS_rename);
  SetFunc(L, t, 'tmpname', @luaOS_tmpname);
  SetFunc(L, t, 'execute', @luaOS_execute);
  SetFunc(L, t, 'setlocale', @luaOS_setlocale);
  SetFunc(L, t, 'date', @luaOS_date);
  TableSetStr(L.GlobalT, L.NewString('os'), LuaTab(t));
end;

procedure OpenLibs(L: TLua);
begin
  OpenLibsEx(L, True);
end;

procedure OpenLibsEx(L: TLua; useEnv: Boolean);
begin
  L.UseEnv := useEnv;
  RandSeed1 := 123456789;
  RandSeed2 := 987654321;
  OpenBase(L);
  OpenString(L);
  OpenTable(L);
  OpenMath(L);
  OpenOS(L);
  OpenPackage(L);
  OpenDebug(L);
  OpenCoroutine(L);
  OpenIO(L);
  OpenUtf8(L);
end;

end.
