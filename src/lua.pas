program lua;

{$mode objfpc}{$H+}

// The stand-alone interpreter (same behaviour as the reference 'lua' program).

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, Classes, Math, luacore, luavm, luaaux, luaparse, lualibbase, lualibos,
  lualibdbg, lualib;

function c_isatty(fd: Integer): Integer; cdecl; external 'c' name 'isatty';
function c_signal(sig: Integer; handler: Pointer): Pointer; cdecl; external 'c' name 'signal';
function c_dlopen(name: PChar; flags: Integer): Pointer; cdecl; external 'c' name 'dlopen';
function c_fputs(s: PChar; stream: Pointer): Integer; cdecl; external 'c' name 'fputs';
function c_fflush(stream: Pointer): Integer; cdecl; external 'c' name 'fflush';
function c_fgets(buf: PChar; n: Integer; stream: Pointer): PChar; cdecl; external 'c' name 'fgets';
var
  c_stderr: Pointer; external name 'stderr';
  c_stdin: Pointer; external name 'stdin';

const
  LuaCopyright = 'Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio';
  MAIN_STACK_SIZE = 768 * 1024 * 1024;

var
  ProgName: string = 'lua';
  Args: array of string;
  ExitStatus: Integer = 0;
  Done: PRTLEvent;
  GlobalL: TLua;

procedure WriteErr(const s: string);
begin
  c_fputs(PChar(s), c_stderr);
  c_fflush(c_stderr);
end;

procedure PrintUsage(const badoption: string);
begin
  WriteErr(ProgName + ': ');
  if (Length(badoption) > 1) and (badoption[2] in ['e', 'l']) then
    WriteErr(Format('''%s'' needs argument'#10, [badoption]))
  else
    WriteErr(Format('unrecognized option ''%s'''#10, [badoption]));
  WriteErr(Format(
    'usage: %s [options] [script [args]]'#10 +
    'Available options are:'#10 +
    '  -e stat   execute string ''stat'''#10 +
    '  -i        enter interactive mode after executing ''script'''#10 +
    '  -l mod    require library ''mod'' into global ''mod'''#10 +
    '  -l g=mod  require library ''mod'' into global ''g'''#10 +
    '  -v        show version information'#10 +
    '  -E        ignore environment variables'#10 +
    '  -W        turn warnings on'#10 +
    '  --        stop handling options'#10 +
    '  -         stop handling options and execute stdin'#10, [ProgName]));
end;

procedure Message(const pname, msg: string);
begin
  if pname <> '' then WriteErr(pname + ': ');
  WriteErr(msg + #10);
end;

// reports the error value on the stack top; returns the status
function Report(L: TLua; status: Integer): Integer;
var
  v: TLuaValue;
  msg: string;
begin
  if status <> 0 then
  begin
    v := L.Stack[L.Top - 1];
    if v.Vt = vtStr then msg := string(v.S.Str)
    else if v.Vt in [vtInt, vtFlt] then msg := NumToStr(v)
    else msg := '(error message not a string)';
    Message(ProgName, msg);
    Dec(L.Top);
  end;
  Result := status;
end;

function MsgHandler(L: TLua): Integer;
var
  v, tm: TLuaValue;
  msg: RawByteString;
begin
  v := LuaArg(L, 1);
  if v.Vt = vtStr then
    msg := v.S.Str
  else if v.Vt in [vtInt, vtFlt] then
    msg := RawByteString(NumToStr(v))
  else
  begin
    tm := GetMetaField(L, v, '__tostring');
    if tm.Vt <> vtNil then
    begin
      tm := CallMeta(L, tm, [v]);
      if tm.Vt = vtStr then
      begin
        LuaPush(L, tm);
        Exit(1);
      end;
    end;
    msg := RawByteString(Format('(error object is a %s value)', [VTypeName(v)]));
  end;
  PushStr(L, Traceback(L, L, msg, True, 1));
  Result := 1;
end;

const
  SIGINT = 2;

// SIGINT handler: the next signal kills the program; this one makes the running
// thread raise an error at its next VM safe point
procedure OnSigInt(sig: Integer); cdecl;
begin
  c_signal(SIGINT, nil);   // SIG_DFL
  if GlobalL <> nil then
    GlobalL.CurThread.HookMask := GlobalL.CurThread.HookMask or HOOK_INT;
end;

// calls the function below 'narg' arguments in protected mode
function DoCallChunk(L: TLua; narg, nres: Integer): Integer;
var
  base: Integer;
begin
  base := L.Top - narg - 1;
  LuaPush(L, LuaNil);
  Move(L.Stack[base], L.Stack[base + 1], (narg + 1) * SizeOf(TLuaValue));
  L.Stack[base] := LuaFunc(LightC(L, @MsgHandler, 'msghandler'));
  c_signal(SIGINT, @OnSigInt);
  Result := LuaProtectedCall(L, narg, nres, base);
  c_signal(SIGINT, nil);
  // remove the handler
  Move(L.Stack[base + 1], L.Stack[base], (L.Top - base - 1) * SizeOf(TLuaValue));
  Dec(L.Top);
end;

function LoadAndCall(L: TLua; const src: RawByteString; const name, mode: string): Integer;
var
  f: TFunction;
  err: string;
begin
  if not LoadBuffer(L, src, name, mode, f, err) then
  begin
    PushStr(L, RawByteString(err));
    Exit(1);
  end;
  SetEnvUpvalue(L, f, LuaTab(L.GlobalT));
  LuaPush(L, LuaFunc(f));
  Result := DoCallChunk(L, 0, 0);
end;

function DoString(L: TLua; const s, name: string): Integer;
begin
  Result := Report(L, LoadAndCall(L, RawByteString(s), name, 't'));
end;

function DoFile(L: TLua; const fname: string): Integer;
var
  content: RawByteString;
  f: TFunction;
  err: string;
begin
  if not ReadFileContent(fname, content) then
  begin
    PushStr(L, RawByteString('cannot open ' + fname));
    Exit(Report(L, 1));
  end;
  PrepareFileChunk(content);
  if not LoadBuffer(L, content, '@' + fname, 'bt', f, err) then
  begin
    PushStr(L, RawByteString(err));
    Exit(Report(L, 1));
  end;
  SetEnvUpvalue(L, f, LuaTab(L.GlobalT));
  LuaPush(L, LuaFunc(f));
  Result := Report(L, DoCallChunk(L, 0, 0));
end;

function ReadStdin: RawByteString;
var
  buf: array[0..4095] of Char;
begin
  Result := '';
  while c_fgets(@buf[0], SizeOf(buf), c_stdin) <> nil do
    Result := Result + RawByteString(StrPas(PChar(@buf[0])));
end;

function DoStdin(L: TLua): Integer;
var
  s: RawByteString;
begin
  s := ReadStdin;
  PrepareFileChunk(s);
  Result := Report(L, LoadAndCall(L, s, '=stdin', 'bt'));
end;

function DoLibrary(L: TLua; const spec: string): Integer;
var
  globname, modname: string;
  k, status: Integer;
begin
  k := Pos('=', spec);
  if k = 0 then
  begin
    modname := spec;
    globname := spec;
    k := Pos('-', globname);
    if k > 0 then globname := Copy(globname, 1, k - 1);
  end
  else
  begin
    globname := Copy(spec, 1, k - 1);
    modname := Copy(spec, k + 1, MaxInt);
  end;
  LuaPush(L, TableGetStr(L.GlobalT, StrKey(L, 'require')));
  PushStr(L, RawByteString(modname));
  status := DoCallChunk(L, 1, 1);
  if status = 0 then
  begin
    TableSetStr(L.GlobalT, StrKey(L, globname), L.Stack[L.Top - 1]);
    Dec(L.Top);
  end;
  Result := Report(L, status);
end;

procedure CreateArgTable(L: TLua; script: Integer);
var
  t: TTable;
  i: Integer;
begin
  t := L.NewTable(Length(Args) - (script + 1), script + 1);
  for i := 0 to High(Args) do
    TableSetInt(t, i - script, NewStr(L, RawByteString(Args[i])));
  SetField(L, L.GlobalT, 'arg', LuaTab(t));
end;

{ ------------------------------------------------------------------ }
{ REPL                                                                }
{ ------------------------------------------------------------------ }

function GetPrompt(L: TLua; firstline: Boolean): string;
var
  v: TLuaValue;
begin
  if firstline then v := TableGetStr(L.GlobalT, StrKey(L, '_PROMPT'))
  else v := TableGetStr(L.GlobalT, StrKey(L, '_PROMPT2'));
  if v.Vt = vtNil then
  begin
    if firstline then Exit('> ') else Exit('>> ');
  end;
  Result := string(ToStringAux(L, v));
end;

function PushLine(L: TLua; firstline: Boolean): Boolean;
var
  buf: array[0..511] of Char;
  s: string;
  prompt: string;
begin
  prompt := GetPrompt(L, firstline);
  Result := False;
  OutWrite(RawByteString(prompt));
  OutFlush;
  if c_fgets(@buf[0], SizeOf(buf), c_stdin) = nil then Exit;
  s := StrPas(PChar(@buf[0]));
  if (Length(s) > 0) and (s[Length(s)] = #10) then Delete(s, Length(s), 1);
  PushStr(L, RawByteString(s));
  Result := True;
end;

// lines are read with plain stdio; only checks that the readline library can be loaded
// (a warning is emitted when it cannot, as lua.c does)
procedure InitReadline(L: TLua);
var
  rllib: string;
  noenv: Boolean;
begin
  noenv := TableGetStr(L.Registry, StrKey(L, 'LUA_NOENV')).Vt <> vtNil;
  rllib := '';
  if not noenv then rllib := GetEnvironmentVariable('LUA_READLINELIB');
  if rllib = '' then rllib := 'libreadline.so';
  if c_dlopen(PChar(rllib), 2) = nil then   // RTLD_NOW
  begin
    WarnMessage(L, 'unable to load readline library ''', True);
    WarnMessage(L, RawByteString(rllib), True);
    WarnMessage(L, '''', False);
  end;
end;

// warns when a line starts a local declaration (locals do not survive across lines)
procedure CheckLocal(const line: RawByteString);
var
  p: Integer;
begin
  p := 1;
  while (p <= Length(line)) and (line[p] in [' ', #9]) do Inc(p);
  if (Copy(line, p, 5) = 'local') and (p + 5 <= Length(line)) and (line[p + 5] in [' ', #9]) then
    WriteErr('warning: locals do not survive across lines in interactive mode'#10);
end;

procedure DoREPL(L: TLua);
var
  line, full: RawByteString;
  f: TFunction;
  err: string;
  status, i: Integer;
  oldname: string;
  incomplete, loaded: Boolean;
  n, base: Integer;
begin
  oldname := ProgName;
  ProgName := '';
  InitReadline(L);
  while True do
  begin
    LuaSetTop(L, 0);
    if not PushLine(L, True) then Break;
    line := L.Stack[L.Top - 1].S.Str;
    Dec(L.Top);
    // try as an expression first
    loaded := LoadBuffer(L, 'return ' + line + ';', '=stdin', 't', f, err);
    if not loaded then
    begin
      CheckLocal(line);
      full := line;
      repeat
        loaded := LoadBuffer(L, full, '=stdin', 't', f, err);
        incomplete := (not loaded) and (Length(err) >= 5) and (Copy(err, Length(err) - 4, 5) = '<eof>');
        if incomplete then
        begin
          if not PushLine(L, False) then Break;
          full := full + #10 + L.Stack[L.Top - 1].S.Str;
          Dec(L.Top);
        end;
      until not incomplete;
    end;
    if not loaded then
    begin
      PushStr(L, RawByteString(err));
      Report(L, 1);
      Continue;
    end;
    SetEnvUpvalue(L, f, LuaTab(L.GlobalT));
    LuaPush(L, LuaFunc(f));
    status := DoCallChunk(L, 0, -1);
    if status = 0 then
    begin
      n := LuaGetTop(L);
      if n > 0 then
      begin
        // print the results with the global 'print'
        L.EnsureStack(L.Top + 25);
        base := L.Top - n;
        Move(L.Stack[base], L.Stack[base + 1], n * SizeOf(TLuaValue));
        L.Stack[base] := TableGetStr(L.GlobalT, StrKey(L, 'print'));
        Inc(L.Top);
        status := LuaProtectedCall(L, n, 0, 0);
        if status <> 0 then
        begin
          Message(ProgName, Format('error calling ''print'' (%s)',
                  [string(ToStringAux(L, L.Stack[L.Top - 1]))]));
        end;
      end;
    end
    else
      Report(L, status);
  end;
  LuaSetTop(L, 0);
  OutWrite(#10);
  OutFlush;
  ProgName := oldname;
end;

{ ------------------------------------------------------------------ }

function pmain(L: TLua): Integer;
var
  i, script, nargs, status, last: Integer;
  hasI, hasV, hasE, noEnv, afterDash: Boolean;
  opt, extra, init, initname: string;
  f: TFunction;
  err: string;
  content: RawByteString;
  chunkname: string;
  argv: TLuaValue;
begin
  script := 0;
  hasI := False;
  hasV := False;
  hasE := False;
  noEnv := False;
  afterDash := False;
  last := High(Args);
  i := 1;
  while i <= last do
  begin
    script := i;
    if (Args[i] = '') or (Args[i][1] <> '-') then Break;
    opt := Args[i];
    if Length(opt) = 1 then Break;     // '-': script is stdin
    case opt[2] of
      '-': begin
        if Length(opt) > 2 then begin PrintUsage(opt); Exit(0); end;
        if i + 1 <= last then script := i + 1 else script := 0;
        afterDash := True;
        i := last + 1;
        Break;
      end;
      'E': begin
        if Length(opt) > 2 then begin PrintUsage(opt); Exit(0); end;
        noEnv := True;
      end;
      'W': if Length(opt) > 2 then begin PrintUsage(opt); Exit(0); end;
      'i', 'v': begin
        if Length(opt) > 2 then begin PrintUsage(opt); Exit(0); end;
        if opt[2] = 'i' then hasI := True;
        hasV := True;
      end;
      'e', 'l': begin
        if opt[2] = 'e' then hasE := True;
        if Length(opt) = 2 then
        begin
          Inc(i);
          if (i > last) or ((Args[i] <> '') and (Args[i][1] = '-')) then
          begin
            PrintUsage(opt);
            Exit(0);
          end;
        end;
      end;
    else
      PrintUsage(opt);
      Exit(0);
    end;
    Inc(i);
    script := 0;
  end;
  if (i > last) and not afterDash then
  begin
    if script <> 0 then
    begin
      // no script name (all arguments were options)
      if (Args[script] <> '') and (Args[script][1] = '-') and (Length(Args[script]) > 1) and
         (Args[script][2] <> '-') then script := 0;
    end;
  end;
  if hasV then
  begin
    OutWrite(LuaCopyright + #10);
    OutFlush;
  end;
  if noEnv then
    TableSetStr(L.Registry, StrKey(L, 'LUA_NOENV'), LuaBool(True));
  OpenLibs(L);
  CreateArgTable(L, script);
  L.GCStopped := False;
  L.Main.GCMode := 'generational';
  // LUA_INIT
  if not noEnv then
  begin
    initname := 'LUA_INIT_5_5';
    init := GetEnvironmentVariable(initname);
    if init = '' then
    begin
      initname := 'LUA_INIT';
      init := GetEnvironmentVariable(initname);
    end;
    if init <> '' then
    begin
      if init[1] = '@' then status := DoFile(L, Copy(init, 2, MaxInt))
      else status := DoString(L, init, '=' + initname);
      if status <> 0 then Exit(0);
    end;
  end;
  // -e, -l, -W
  WarnMessage(L, '@off', False);
  if script > 0 then nargs := script else nargs := Length(Args);
  i := 1;
  while i < nargs do
  begin
    opt := Args[i];
    case opt[2] of
      'e', 'l': begin
        if Length(opt) > 2 then extra := Copy(opt, 3, MaxInt)
        else begin Inc(i); extra := Args[i]; end;
        if opt[2] = 'e' then status := DoString(L, extra, '=(command line)')
        else status := DoLibrary(L, extra);
        if status <> 0 then Exit(0);
      end;
      'W': WarnMessage(L, '@on', False);
    end;
    Inc(i);
  end;
  if script > 0 then
  begin
    if (Args[script] = '-') and not ((script > 1) and (Args[script - 1] = '--')) then
    begin
      // the script is the standard input
      content := ReadStdin;
      chunkname := '=stdin';
    end
    else
    begin
      if not ReadFileContent(Args[script], content) then
      begin
        PushStr(L, RawByteString(Format('cannot open %s', [Args[script]])));
        Report(L, 1);
        Exit(0);
      end;
      chunkname := '@' + Args[script];
    end;
    PrepareFileChunk(content);
    if not LoadBuffer(L, content, chunkname, 'bt', f, err) then
    begin
      PushStr(L, RawByteString(err));
      Report(L, 1);
      Exit(0);
    end;
    SetEnvUpvalue(L, f, LuaTab(L.GlobalT));
    LuaPush(L, LuaFunc(f));
    // the arguments are the current contents of the 'arg' table
    argv := TableGetStr(L.GlobalT, StrKey(L, 'arg'));
    if argv.Vt <> vtTab then LuaError(L, '''arg'' is not a table');
    nargs := Integer(TableLength(argv.T));
    L.EnsureStack(L.Top + nargs + 25);
    for i := 1 to nargs do LuaPush(L, TableGetInt(argv.T, i));
    status := DoCallChunk(L, nargs, -1);
    if Report(L, status) <> 0 then Exit(0);
  end;
  if hasI then
    DoREPL(L)
  else if (script < 1) and not (hasE or hasV) then
  begin
    if c_isatty(0) <> 0 then
    begin
      OutWrite(LuaCopyright + #10);
      OutFlush;
      DoREPL(L);
    end
    else
      DoStdin(L);
  end;
  PushBool(L, True);
  Result := 1;
end;

procedure CloseStateImpl(L: TLua);
begin
  LuaClose(L);
end;

function MainThread(p: Pointer): PtrInt;
var
  L: TLua;
  status: Integer;
begin
  Result := 0;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);
  L := TLua.CreateMain;
  GlobalL := L;
  LuaInitVM(L);
  L.GCStopped := True;      // while building the state
  LuaPush(L, LuaFunc(LightC(L, @pmain, 'pmain')));
  status := LuaProtectedCall(L, 0, 1, 0);
  if status <> 0 then
    Report(L, status);
  if (status = 0) and Truthy(L.Stack[L.Top - 1]) then ExitStatus := 0 else ExitStatus := 1;
  LuaClose(L);
  OutFlush;
  c_fflush(nil);
  RTLEventSetEvent(Done);
end;

var
  i: Integer;
  tid: TThreadID;
begin
  SetLength(Args, ParamCount + 1);
  for i := 0 to ParamCount do Args[i] := ParamStr(i);
  ProgName := Args[0];
  CloseStateHook := @CloseStateImpl;
  Done := RTLEventCreate;
  BeginThread(@MainThread, nil, tid, MAIN_STACK_SIZE);
  RTLEventWaitFor(Done);
  c_fflush(nil);
  Halt(ExitStatus);
end.
