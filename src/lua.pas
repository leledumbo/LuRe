program lua;

{$mode objfpc}{$H+}

uses
  SysUtils, Math, luacore, luaparse, luavm, lualib;

function libc_isatty(fd: Integer): Integer; cdecl; external 'c' name 'isatty';

var
  MainL: TLua;
  ProgName: string = 'lua';
  HasError: Boolean = False;
  scriptArgs: array of string;
  pt: TTable;
  argt: TLuaValue;
  preScriptIdx: Integer;
  sopt: string;
  interactive: Boolean;

function StrToLua(const s: string): TLuaValue;
begin
  Result := LuaStr(MainL.NewString(RawByteString(s)));
end;

procedure PrintVersion;
begin
  WriteLn('Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio');
end;

procedure PrintUsage;
begin
  WriteLn('usage: ', ProgName, ' [options] [script [args]]');
  WriteLn('Available options are:');
  WriteLn('  -e stat   execute string ''stat''');
  WriteLn('  -i        enter interactive mode after executing ''script''');
  WriteLn('  -l mod    require library ''mod'' into global ''mod''');
  WriteLn('  -l g=mod  require library ''mod'' into global ''g''');
  WriteLn('  -v        show version information');
  WriteLn('  -E        ignore environment variables');
  WriteLn('  --        stop handling options');
  WriteLn('  -         stop handling options and execute stdin');
end;

procedure RunChunk(const src: string; const name: string);
var
  f: TFunction;
  uv: TUpval;
begin
  f := LuaCompile(MainL, RawByteString(src), name);
  uv := TUpval.Create;
  uv.V := LuaTab(MainL.GlobalT);
  f.Upvals[0] := uv;
  argt := TableGetStr(MainL.GlobalT, MainL.NewString('arg'));
  if (argt.Vt <> vtNil) and (argt.Vt <> vtTab) then
  begin
    WriteLn(ErrOutput, '''arg'' is not a table');
    Halt(1);
  end;
  if argt.Vt = vtTab then
  begin
    f.VarArgTable := argt.T;
    f.VarArgPreset := True;
  end;
  MainL.PushValue(LuaFunc(f));
  try
    LuaCall(MainL, 0, 0);
  except
    on E: ELuaError do
    begin
      HasError := True;
      WriteLn(ErrOutput, E.Message);
      MainL.Top := 0;
    end;
  end;
end;

procedure RunFile(const name: string; args: array of string);
var
  f: TFunction;
  content: RawByteString;
  fs: File;
  buf: array[0..8191] of Byte;
  n: Integer;
  uv: TUpval;
  i: Integer;
begin
  AssignFile(fs, name);
  try
    Reset(fs, 1);
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'cannot open ', name);
      Halt(1);
    end;
  end;
  content := '';
  repeat
    BlockRead(fs, buf, SizeOf(buf), n);
    if n > 0 then
    begin
      SetLength(content, Length(content) + n);
      Move(buf, content[Length(content) - n + 1], n);
    end;
  until n <= 0;
  CloseFile(fs);
  try
    f := LuaCompile(MainL, content, '@' + name);
  except
    on E: ELuaError do
    begin
      WriteLn(ErrOutput, E.Message);
      Halt(1);
    end;
  end;
  uv := TUpval.Create;
  uv.V := LuaTab(MainL.GlobalT);
  f.Upvals[0] := uv;
  argt := TableGetStr(MainL.GlobalT, MainL.NewString('arg'));
  if argt.Vt = vtTab then
  begin
    f.VarArgTable := argt.T;
    f.VarArgPreset := True;
  end;
  MainL.PushValue(LuaFunc(f));
  for i := 0 to Length(args) - 1 do
    MainL.PushValue(StrToLua(args[i]));
  try
    LuaCall(MainL, Length(args), 0);
  except
    on E: ELuaError do
    begin
      WriteLn(ErrOutput, E.Message);
      Halt(1);
    end;
  end;
end;

procedure RunStdin;
var
  src, line: string;
  f: TFunction;
  uv: TUpval;
  argt: TLuaValue;
  pv: TLuaValue;
  nres, i: Integer;
begin
  src := '';
  if not interactive then
  begin
    while not Eof do
    begin
      ReadLn(line);
      src := src + line + #10;
    end;
    RunChunk(src, '=stdin');
    Exit;
  end;
  // simple REPL: evaluate each line and print results via global 'print'
  while not Eof do
  begin
    ReadLn(line);
    if line = '' then continue;
    f := nil;
    try
      f := LuaCompile(MainL, RawByteString('return ' + line), '=stdin');
    except
      f := nil;
    end;
    if f = nil then
    begin
      try
        f := LuaCompile(MainL, RawByteString(line), '=stdin');
      except
        on E: ELuaError do
        begin
          WriteLn(ErrOutput, E.Message);
          continue;
        end;
      end;
    end;
    uv := TUpval.Create;
    uv.V := LuaTab(MainL.GlobalT);
    f.Upvals[0] := uv;
    argt := TableGetStr(MainL.GlobalT, MainL.NewString('arg'));
    if argt.Vt = vtTab then
    begin
      f.VarArgTable := argt.T;
      f.VarArgPreset := True;
    end;
    MainL.PushValue(LuaFunc(f));
    try
      LuaCall(MainL, 0, -1);
    except
      on E: ELuaError do
      begin
        WriteLn(ErrOutput, E.Message);
        continue;
      end;
    end;
    nres := MainL.Top - MainL.CI[MainL.NCI - 1].Base;
    pv := TableGetStr(MainL.GlobalT, MainL.NewString('print'));
    if (nres > 0) and (pv.Vt = vtFunc) then
    begin
      MainL.PushValue(pv);
      for i := 0 to nres - 1 do
        MainL.PushValue(MainL.Stack[MainL.CI[MainL.NCI - 1].Base + i]);
      try
        LuaCall(MainL, nres, 0);
      except
        on E: ELuaError do
        begin
          WriteLn(ErrOutput, E.Message);
        end;
      end;
    end
    else if (nres > 0) and (pv.Vt <> vtFunc) then
    begin
      WriteLn(ErrOutput, 'error calling ''print''');
    end;
  end;
end;

procedure CreateArgTable(args: array of string; scriptIdx: Integer);
var
  t: TTable;
  i: Integer;
  n: Integer;
begin
  n := Length(args);
  t := MainL.NewTable(0, 8);
  // negative indices: interpreter args
  for i := 0 to scriptIdx - 1 do
    TableSetInt(t, i - scriptIdx, StrToLua(args[i]));
  // 0: script name
  if scriptIdx < n then
    TableSetInt(t, 0, StrToLua(args[scriptIdx]))
  else
    TableSetInt(t, 0, StrToLua(ProgName));
  // positive: script args
  for i := scriptIdx + 1 to n - 1 do
    TableSetInt(t, i - scriptIdx, StrToLua(args[i]));
  TableSetStr(MainL.GlobalT, MainL.NewString('arg'), LuaTab(t));
end;

procedure DoRequire(const spec: string);
var
  modname, glob: string;
  p: Integer;
  req: TLuaValue;
begin
  p := Pos('=', spec);
  if p > 0 then
  begin
    glob := Copy(spec, 1, p - 1);
    modname := Copy(spec, p + 1, Length(spec));
  end
  else
  begin
    glob := spec;
    modname := spec;
  end;
  // call require(modname)
  req := TableGetStr(MainL.GlobalT, MainL.NewString('require'));
  if req.Vt <> vtFunc then
  begin
    WriteLn(ErrOutput, 'require not available');
    Exit;
  end;
  MainL.PushValue(req);
  MainL.PushValue(StrToLua(modname));
  try
    LuaCall(MainL, 1, 1);
    TableSetStr(MainL.GlobalT, MainL.NewString(glob), MainL.Stack[MainL.Top - 1]);
    MainL.Top := MainL.Top - 1;
  except
    on E: ELuaError do
    begin
      WriteLn(ErrOutput, E.Message);
      Halt(1);
    end;
  end;
end;

var
  i: Integer;
  argc: Integer;
  scriptIdx: Integer;
  hasFiles: Boolean;
  args: array of string;
  arg0: string;
  tmpArgs: array of string;
  ignoreEnv: Boolean;
  init: string;

procedure RunLuaInit;
var
  s: string;
begin
  if ignoreEnv then Exit;
  // emulate readline library load failure warning
  s := GetEnvironmentVariable('LUA_READLINELIB');
  if s <> '' then
    WriteLn(ErrOutput, 'warning: unable to load readline library ''', s, '''');
  s := GetEnvironmentVariable('LUA_INIT_5_5');
  if s = '' then s := GetEnvironmentVariable('LUA_INIT');
  if s = '' then Exit;
  if (Length(s) > 1) and (s[1] = '@') then
    RunFile(Copy(s, 2, Length(s) - 1), [])
  else
    RunChunk(s, '=LUA_INIT');
end;

begin
  MainL := TLua.CreateMain;
  LuaInitVM(MainL);
  interactive := False;
  scriptIdx := -1;
  ignoreEnv := False;
  // pre-scan for -E so libraries ignore environment
  for i := 1 to ParamCount do
    if ParamStr(i) = '-E' then ignoreEnv := True;
  // pre-scan for the script index (first non-option argument)
  preScriptIdx := -1;
  i := 1;
  while i <= ParamCount do
  begin
    sopt := ParamStr(i);
    if (sopt = '-e') or (sopt = '-l') then
    begin
      Inc(i, 2);  // skip the option argument too
      continue;
    end;
    if (sopt <> '') and (sopt[1] <> '-') then
    begin
      preScriptIdx := i;
      Break;
    end;
    if sopt = '--' then
    begin
      if i < ParamCount then preScriptIdx := i + 1;
      Break;
    end;
    if sopt = '-' then
    begin
      preScriptIdx := i;
      Break;
    end;
    Inc(i);
  end;
  OpenLibsEx(MainL, not ignoreEnv);
  argc := ParamCount;
  SetLength(tmpArgs, argc + 1);
  tmpArgs[0] := ParamStr(0);
  for i := 1 to argc do
    tmpArgs[i] := ParamStr(i);
  ProgName := tmpArgs[0];
  // create the arg table before running -e/-l modules
  if preScriptIdx >= 1 then
    CreateArgTable(tmpArgs, preScriptIdx)
  else
  begin
    pt := MainL.NewTable(0, 4);
    TableSetInt(pt, 0, StrToLua(ParamStr(0)));
    TableSetStr(MainL.GlobalT, MainL.NewString('arg'), LuaTab(pt));
  end;
  i := 1;
  while i <= argc do
  begin
    if tmpArgs[i] = '-' then
    begin
      // stdin
      RunLuaInit;
      RunStdin;
      i := argc + 1;
      scriptIdx := i;
      Break;
    end
    else if tmpArgs[i] = '--' then
    begin
      Inc(i);
      scriptIdx := i;
      Break;
    end
    else if (tmpArgs[i] = '-v') and (Length(tmpArgs[i]) = 2) then
    begin
      PrintVersion;
      if argc = 1 then Halt(0);
    end
    else if (tmpArgs[i] = '-i') and (Length(tmpArgs[i]) = 2) then
      interactive := True
    else if (tmpArgs[i] = '-W') and (Length(tmpArgs[i]) = 2) then
    begin
      // warnings flag: accepted (warning output always on for now)
    end
    else if (Length(tmpArgs[i]) > 2) and (tmpArgs[i][1] = '-') and (tmpArgs[i][2] = 'l') then
    begin
      DoRequire(Copy(tmpArgs[i], 3, Length(tmpArgs[i]) - 2));
    end
    else if (Length(tmpArgs[i]) >= 3) and (tmpArgs[i][1] = '-') and (tmpArgs[i][2] = 'e') and (tmpArgs[i][3] = ' ') then
    begin
      // "-e " with the chunk embedded (possibly empty)
      RunChunk(Copy(tmpArgs[i], 4, Length(tmpArgs[i]) - 3), '=(command line)');
      if HasError then Halt(1);
    end
    else if (tmpArgs[i] = '-e') and (Length(tmpArgs[i]) = 2) then
    begin
      Inc(i);
      if i > argc then
      begin
        PrintUsage;
        Halt(1);
      end;
      RunChunk(tmpArgs[i], '=(command line)');
    end
    else if (tmpArgs[i] = '-l') and (Length(tmpArgs[i]) = 2) then
    begin
      Inc(i);
      if i > argc then
      begin
        PrintUsage;
        Halt(1);
      end;
      DoRequire(tmpArgs[i]);
    end
    else if (tmpArgs[i] = '-E') and (Length(tmpArgs[i]) = 2) then
    begin
      ignoreEnv := True;
    end
    else if (tmpArgs[i] <> '') and (tmpArgs[i][1] = '-') then
    begin
      WriteLn(ErrOutput, 'unrecognized option ''', tmpArgs[i], '''');
      PrintUsage;
      Halt(1);
    end
    else
    begin
      scriptIdx := i;
      Break;
    end;
    Inc(i);
  end;
  if (scriptIdx >= 1) and (scriptIdx <= argc) then
  begin
    RunLuaInit;
    begin
      SetLength(scriptArgs, argc - scriptIdx);
      for i := 0 to argc - scriptIdx - 1 do
        scriptArgs[i] := tmpArgs[scriptIdx + 1 + i];
      RunFile(tmpArgs[scriptIdx], scriptArgs);
    end;
  end
  else
  begin
    CreateArgTable(tmpArgs, argc + 1);
    RunLuaInit;
    if HasError then Halt(1);
  if interactive or (libc_isatty(0) = 0) then
      RunStdin;
  end;
  MainL.Free;
end.
