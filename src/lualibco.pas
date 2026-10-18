unit lualibco;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// Coroutines. Every coroutine that has been started runs on its own native
// thread; only one thread runs at a time and control is handed over with
// events. This allows yielding from anywhere (inside pcall, metamethods,
// iterators, ...), except across non-yieldable native calls (see TThread.NNY).

interface

uses
  SysUtils, Math, luacore, luavm, luaaux;

procedure OpenCoroutine(L: TLua);

// closes a suspended or dead coroutine: returns True if no error;
// the error value (if any) is left in 'err'
function CloseCoroutine(L, co: TLua; var err: TLuaValue): Boolean;

const
  CO_STACK_SIZE = 16 * 1024 * 1024;

implementation

type
  TCoRunner = class
  public
    Co: TLua;
    ResumeEvt: PRTLEvent;
    YieldEvt: PRTLEvent;
    Started: Boolean;
    Finished: Boolean;
    KillFlag: Boolean;
    Failed: Boolean;
    ErrVal: TLuaValue;
    YieldBase: Integer;
    YieldN: Integer;
    ThreadId: TThreadID;
    constructor Create(AC: TLua);
    destructor Destroy; override;
  end;

constructor TCoRunner.Create(AC: TLua);
begin
  Co := AC;
  ResumeEvt := RTLEventCreate;
  YieldEvt := RTLEventCreate;
  ErrVal.Vt := vtNil;
end;

destructor TCoRunner.Destroy;
begin
  RTLEventDestroy(ResumeEvt);
  RTLEventDestroy(YieldEvt);
  inherited Destroy;
end;

function CoThreadMain(p: Pointer): PtrInt;
var
  r: TCoRunner;
  co: TLua;
  nargs: Integer;
begin
  Result := 0;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);
  r := TCoRunner(p);
  co := r.Co;
  try
    nargs := co.Top - 1;
    DoCall(co, 0, nargs, -1);
    co.Status := ST_DEAD;
  except
    on E: ELuaKill do
    begin
      r.Finished := True;
      RTLEventSetEvent(r.YieldEvt);
      Exit;     // killed (or closed itself): the resumer looks at 'Failed'
    end;
    on E: ELuaError do
    begin
      co.Status := ST_ERR;
      r.Failed := True;
      r.ErrVal := ErrorValueOf(co, E);
    end;
    on E: Exception do
    begin
      co.Status := ST_ERR;
      r.Failed := True;
      r.ErrVal := LuaStr(co.NewString(RawByteString(E.ClassName + ': ' + E.Message)));
    end;
  end;
  r.Finished := True;
  RTLEventSetEvent(r.YieldEvt);
end;

function RunnerOf(co: TLua): TCoRunner; inline;
begin
  Result := TCoRunner(co.Runner);
end;

// terminates the native thread of a suspended coroutine
procedure KillRunner(co: TLua);
var
  r: TCoRunner;
begin
  r := RunnerOf(co);
  if r = nil then Exit;
  if r.Started and not r.Finished then
  begin
    r.KillFlag := True;
    RTLEventSetEvent(r.ResumeEvt);
    RTLEventWaitFor(r.YieldEvt);
  end;
end;

procedure FreeCoThread(th: TThread);
var
  co: TLua;
  r: TCoRunner;
begin
  if not (th is TLua) then Exit;
  co := TLua(th);
  r := RunnerOf(co);
  if r = nil then Exit;
  if r.Started and not r.Finished then
  begin
    // the native thread is blocked in a yield: unwind it
    r.KillFlag := True;
    RTLEventSetEvent(r.ResumeEvt);
    RTLEventWaitFor(r.YieldEvt);
  end;
  co.Runner := nil;
  r.Free;
end;

{ ------------------------------------------------------------------ }

function CoStatusName(L, co: TLua): string;
var
  r: TCoRunner;
begin
  if co = L.Main.CurThread then Exit('running');
  case co.Status of
    ST_YIELD: Result := 'suspended';
    ST_DEAD, ST_ERR: Result := 'dead';
  else
    begin
      r := RunnerOf(co);
      if (co = co.Main) or ((r <> nil) and r.Started) then Result := 'normal' else Result := 'suspended';
    end;
  end;
end;

// moves n values from the top of 'from' to the top of 'dest'
procedure XMove(from, dest: TLua; n: Integer);
var
  i: Integer;
begin
  dest.EnsureStack(dest.Top + n + 5);
  for i := 0 to n - 1 do
    dest.Stack[dest.Top + i] := from.Stack[from.Top - n + i];
  Inc(dest.Top, n);
  Dec(from.Top, n);
end;

// Resumes 'co' passing 'nargs' values from the top of L's stack.
// On return, status = 0: values yielded/returned were pushed on L (count in
// nres); status <> 0: one error value was pushed on L.
function ResumeCo(L, co: TLua; nargs: Integer; var nres: Integer): Integer;
var
  r: TCoRunner;
  st: string;
  msg: string;
  tid: TThreadID;
begin
  st := CoStatusName(L, co);
  if st <> 'suspended' then
  begin
    if st = 'dead' then msg := 'cannot resume dead coroutine'
    else msg := 'cannot resume non-suspended coroutine';
    Dec(L.Top, nargs);
    PushStr(L, RawByteString(msg));
    nres := 1;
    Exit(1);
  end;
  if L.NCcalls >= 195 then
  begin
    Dec(L.Top, nargs);
    PushStr(L, 'C stack overflow');
    nres := 1;
    Exit(1);
  end;
  r := RunnerOf(co);
  if r = nil then
  begin
    r := TCoRunner.Create(co);
    co.Runner := r;
  end;
  if not r.Started then
  begin
    // first resume: the function is at slot 0; arguments follow
    XMove(L, co, nargs);
    r.Started := True;
    co.Parent := L;
    co.Status := ST_OK;
    co.NCcalls := L.NCcalls + 1;
    L.Main.CurThread := co;
    r.ThreadId := BeginThread(@CoThreadMain, Pointer(r), tid, CO_STACK_SIZE);
    if r.ThreadId = TThreadID(0) then
    begin
      L.Main.CurThread := L;
      PushStr(L, 'not enough memory');
      nres := 1;
      Exit(1);
    end;
  end
  else
  begin
    // resume after a yield: drop the yielded values, push the new arguments
    co.Top := r.YieldBase;
    XMove(L, co, nargs);
    co.Parent := L;
    co.Status := ST_OK;
    co.NCcalls := L.NCcalls + 1;
    L.Main.CurThread := co;
    RTLEventSetEvent(r.ResumeEvt);
  end;
  // wait for the coroutine to yield, finish or fail
  RTLEventWaitFor(r.YieldEvt);
  L.Main.CurThread := L;
  co.Parent := nil;
  if r.Failed then
  begin
    LuaPush(L, r.ErrVal);
    nres := 1;
    Exit(1);
  end;
  if r.Finished then
  begin
    nres := co.Top;
    XMove(co, L, nres);
    Exit(0);
  end;
  // yielded
  nres := r.YieldN;
  L.EnsureStack(L.Top + nres + 5);
  XMove(co, L, nres);
  Result := 0;
end;

function auxresume(L: TLua; co: TLua; nargs: Integer; var nres: Integer): Integer;
begin
  Result := ResumeCo(L, co, nargs, nres);
end;

function CheckCo(L: TLua; arg: Integer): TLua;
var
  v: TLuaValue;
begin
  v := LuaArg(L, arg);
  if v.Vt <> vtThread then TypeErrorArg(L, arg, 'coroutine');
  Result := TLua(v.Th);
end;

function luaCo_create(L: TLua): Integer;
var
  co: TLua;
begin
  if LuaArg(L, 1).Vt <> vtFunc then TypeErrorArg(L, 1, 'function');
  co := L.NewThread;
  co.HookFunc := L.HookFunc;
  co.HookMask := L.HookMask;
  co.HookCount := L.HookCount;
  co.HookCounter := L.HookCount;
  co.Stack[0] := LuaArg(L, 1);
  co.Top := 1;
  LuaPush(L, LuaThread(co));
  Result := 1;
end;

function luaCo_resume(L: TLua): Integer;
var
  co: TLua;
  nargs, nres, st: Integer;
  err: TLuaValue;
begin
  co := CheckCo(L, 1);
  nargs := LuaGetTop(L) - 1;
  st := auxresume(L, co, nargs, nres);
  if st <> 0 then
  begin
    // [.., error]  ->  false, error
    err := L.Stack[L.Top - 1];
    Dec(L.Top);
    PushBool(L, False);
    LuaPush(L, err);
    Exit(2);
  end;
  // push 'true' below the results
  L.EnsureStack(L.Top + 2);
  Move(L.Stack[L.Top - nres], L.Stack[L.Top - nres + 1], nres * SizeOf(TLuaValue));
  L.Stack[L.Top - nres] := LuaBool(True);
  Inc(L.Top);
  Result := nres + 1;
end;

function luaCo_yield(L: TLua): Integer;
var
  r: TCoRunner;
  n: Integer;
begin
  if (L.Runner = nil) or (L = L.Main) then
    LuaError(L, 'attempt to yield from outside a coroutine');
  if L.NNY > 0 then
    LuaError(L, 'attempt to yield across a C-call boundary');
  r := RunnerOf(L);
  n := LuaGetTop(L);
  r.YieldBase := L.Top - n;
  r.YieldN := n;
  L.Status := ST_YIELD;
  RTLEventSetEvent(r.YieldEvt);
  RTLEventWaitFor(r.ResumeEvt);
  if r.KillFlag then
    raise ELuaKill.Create('coroutine killed');
  // resumed: the arguments of resume are on the stack top
  Result := L.Top - r.YieldBase;
end;

function luaCo_status(L: TLua): Integer;
var
  co: TLua;
begin
  co := CheckCo(L, 1);
  PushStr(L, RawByteString(CoStatusName(L, co)));
  Result := 1;
end;

function luaCo_running(L: TLua): Integer;
var
  cur: TLua;
begin
  cur := TLua(L.Main.CurThread);
  LuaPush(L, LuaThread(cur));
  PushBool(L, cur = L.Main);
  Result := 2;
end;

function luaCo_isyieldable(L: TLua): Integer;
var
  co: TLua;
begin
  if ArgIsNone(L, 1) then co := L else co := CheckCo(L, 1);
  PushBool(L, (co <> co.Main) and (co.NNY = 0));
  Result := 1;
end;

function CloseCoroutine(L, co: TLua; var err: TLuaValue): Boolean;
var
  r: TCoRunner;
  ev: TLuaValue;
  savedTop: Integer;
  savedCur: TThread;
  hadError: Boolean;
begin
  r := RunnerOf(co);
  hadError := (co.Status = ST_ERR) and (r <> nil) and r.Failed;
  if hadError then ev := r.ErrVal else ev.Vt := vtNil;
  // close pending to-be-closed variables (running their handlers here)
  savedCur := L.Main.CurThread;
  savedTop := co.Top;
  if co.NTbc > 0 then
  begin
    L.Main.CurThread := co;
    co.NCcalls := L.NCcalls;   // closing handlers nest in the C stack of the closer
    try
      if co.NCI > 0 then
        co.Top := Max(co.Top, co.CI[co.NCI - 1].Top);
      try
        CloseThreadVars(co, 0, ev, hadError);
      except
        on E: ELuaKill do ;   // the coroutine closed itself while being closed
      end;
    finally
      L.Main.CurThread := savedCur;
    end;
  end;
  CloseUpvals(co, 0);
  if savedTop < 0 then ;
  KillRunner(co);
  co.NCI := 0;
  co.Top := 0;
  co.Status := ST_DEAD;
  if r <> nil then r.Failed := False;
  err := ev;
  Result := not (hadError or (ev.Vt <> vtNil));
end;

function luaCo_close(L: TLua): Integer;
var
  co: TLua;
  st: string;
  err: TLuaValue;
  r: TCoRunner;
begin
  if ArgIsNone(L, 1) then co := TLua(L.Main.CurThread) else co := CheckCo(L, 1);
  st := CoStatusName(L, co);
  if st = 'running' then
  begin
    if co = co.Main then LuaError(L, 'cannot close main thread');
    // a coroutine closing itself: it ends here
    err.Vt := vtNil;
    CloseThreadVars(co, 0, err, False);
    r := RunnerOf(co);
    co.Status := ST_DEAD;
    if err.Vt <> vtNil then
    begin
      co.Status := ST_ERR;
      r.Failed := True;
      r.ErrVal := err;
    end;
    co.Top := 0;
    raise ELuaKill.Create('coroutine closed itself');
  end;
  if (st <> 'suspended') and (st <> 'dead') then
    LuaError(L, Format('cannot close a %s coroutine', [st]));
  if CloseCoroutine(L, co, err) then
  begin
    PushBool(L, True);
    Exit(1);
  end;
  PushBool(L, False);
  LuaPush(L, err);
  Result := 2;
end;

function auxwrap(L: TLua): Integer;
var
  f: TFunction;
  co: TLua;
  nargs, nres, st: Integer;
  err: TLuaValue;
  ev: TLuaValue;
begin
  f := L.CI[L.NCI - 1].Func;
  co := TLua(f.CVals[0].Th);
  nargs := LuaGetTop(L);
  st := auxresume(L, co, nargs, nres);
  if st <> 0 then
  begin
    ev := L.Stack[L.Top - 1];
    Dec(L.Top);
    if co.Status = ST_ERR then
    begin
      // error in the coroutine: close it and take the final error
      if not CloseCoroutine(L, co, err) then ev := err;
    end;
    if ev.Vt = vtStr then
      ev := NewStr(L, RawByteString(ErrorPosition(L, 1)) + ev.S.Str);
    LuaThrow(L, ev);
  end;
  Result := nres;
end;

function luaCo_wrap(L: TLua): Integer;
var
  f: TFunction;
begin
  luaCo_create(L);
  f := L.NewCFunction(@auxwrap, 1);
  f.CVals[0] := L.Stack[L.Top - 1];
  L.Stack[L.Top - 1] := LuaFunc(f);
  Result := 1;
end;

procedure OpenCoroutine(L: TLua);
const
  Funcs: array[0..7] of TLibFunc = (
    (Name: 'create'; Func: @luaCo_create),
    (Name: 'resume'; Func: @luaCo_resume),
    (Name: 'running'; Func: @luaCo_running),
    (Name: 'status'; Func: @luaCo_status),
    (Name: 'wrap'; Func: @luaCo_wrap),
    (Name: 'yield'; Func: @luaCo_yield),
    (Name: 'isyieldable'; Func: @luaCo_isyieldable),
    (Name: 'close'; Func: @luaCo_close));
begin
  NewLib(L, 'coroutine', Funcs);
  L.Main.FreeThreadProc := @FreeCoThread;
end;

end.
