unit luavm;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$POINTERMATH ON}
{$GOTO ON}

// The virtual machine: call frames, the instruction loop, metamethods,
// error handling with variable names, upvalues, to-be-closed variables,
// hooks and protected calls.

interface

uses
  SysUtils, Math, luacore, luaarith;

type
  // raised inside a coroutine to unwind its native stack when it is killed
  ELuaKill = class(Exception);

  TOperandKind = (okNone, okReg, okUpval);

var
  StackSlack: Integer = 0;         // extra stack allowed while handling errors
  MainMaxCI: Integer = CI_CAPACITY_MAIN - 512;     // maximum call depth of the main thread
  CoMaxCI: Integer = CI_CAPACITY_CO - 512;        // ... of a coroutine (smaller native stack)

// ---- stack API (functions implemented in Pascal use these)
function LuaGetTop(L: TThread): Integer;
function LuaArg(L: TThread; i: Integer): TLuaValue;
function ArgPtr(L: TThread; i: Integer): PLuaValue; inline;   // address of an argument (NilValue if absent)
function LuaAbsIndex(L: TThread; i: Integer): Integer;
procedure LuaPush(L: TThread; constref v: TLuaValue);
procedure LuaSetTop(L: TThread; n: Integer);
function LuaTypeName(L: TThread; i: Integer): string;
function ObjTypeName(L: TThread; constref v: TLuaValue): string;   // honours __name

// ---- errors
function ErrorPosition(L: TThread; level: Integer): string;
procedure LuaError(L: TLua; const msg: string);               // adds position (level 1)
procedure LuaErrorFmt(L: TLua; const msg: string; const args: array of const);
procedure LuaRuntimeError(L: TLua; const msg: string);        // adds position (level 0)
procedure LuaThrow(L: TLua; constref v: TLuaValue);              // raise a value as is
procedure RunError(L: TThread; const msg: string);            // position of the running function
function ErrorValueOf(L: TLua; E: ELuaError): TLuaValue;

// ---- calls
procedure DoCall(L: TLua; funcIdx, nargs, nresults: Integer);
procedure LuaCall(L: TLua; nargs, nresults: Integer);        // not yieldable
procedure LuaCallK(L: TLua; nargs, nresults: Integer);       // yieldable
function LuaProtectedCall(L: TLua; nargs, nresults, errfunc: Integer): Integer;
procedure CallFinalizer(L: TLua; constref obj: TLuaValue);
procedure LuaClose(L: TLua);                                  // runs all pending finalizers

// ---- operations with metamethods (used by libraries)
function GetMetatable(L: TThread; constref v: TLuaValue): TTable;
function GetTM(L: TThread; constref v: TLuaValue; tm: Integer): TLuaValue;
function GetMetaField(L: TThread; constref v: TLuaValue; const name: string): TLuaValue;
function LuaIndex(L: TLua; constref t, key: TLuaValue): TLuaValue;
procedure LuaSetIndex(L: TLua; constref t, key, val: TLuaValue);
function LuaEquals(L: TLua; constref a, b: TLuaValue): Boolean;
function LuaLessThan(L: TLua; constref a, b: TLuaValue): Boolean;
function LuaLessEqual(L: TLua; constref a, b: TLuaValue): Boolean;
function LuaLen(L: TLua; constref v: TLuaValue): TLuaValue;
function LuaArith(L: TLua; op: Integer; constref a, b: TLuaValue): TLuaValue;
function LuaConcat2(L: TLua; constref a, b: TLuaValue): TLuaValue;
function CallMeta(L: TLua; constref f: TLuaValue; const args: array of TLuaValue): TLuaValue;
function StrLess(const a, b: RawByteString): Boolean;

// ---- upvalues and to-be-closed variables
function FindUpval(L: TThread; idx: Integer): TUpval;
procedure CloseUpvals(L: TThread; level: Integer);
procedure CloseTbcUpTo(L: TLua; level: Integer);
// closes upvalues and variables of a thread; with hasErr, 'err' is passed to the handlers
procedure CloseThreadVars(L: TLua; level: Integer; var err: TLuaValue; hasErr: Boolean);

// ---- debug information
function ci_CurrentLine(const ci: TCallInfo): Integer;
function ProtoLineAt(p: TProto; pc: Integer): Integer;
function LocalNameAt(p: TProto; n: Integer; pc: Integer): string;   // n-th active local (1-based)
function GetObjName(p: TProto; lastpc, reg: Integer; var name: string): string;
function FuncNameFromCall(L: TThread; ciIdx: Integer; var name: string): string;
function UpvalName(p: TProto; idx: Integer): string;
procedure SetHookState(L: TThread; constref func: TLuaValue; mask, count: Integer);

procedure LuaInitVM(L: TLua);

// pushes a call-info record (used by the C API to give a state its base frame)
procedure PushCI(L: TThread; f: TFunction; funcIdx, base, top, nresults: Integer; isC: Boolean);

implementation

var
  PendingExtra: Integer = 0;   // extra arguments from a '__call' chain, handed to the next frame

type
  PInstruction = ^TInstruction;

const
  MAXTAGLOOP = 2000;
  LUA_MINSTACK = 20;
  MAXCCALLS = 200;

{ ===================================================================== }
{ stack API                                                              }
{ ===================================================================== }

function CurBase(L: TThread): Integer; inline;
begin
  if L.NCI = 0 then Result := 0 else Result := L.CI[L.NCI - 1].Base;
end;

function LuaGetTop(L: TThread): Integer;
begin
  Result := L.Top - CurBase(L);
end;

function LuaAbsIndex(L: TThread; i: Integer): Integer;
begin
  if i > 0 then Result := CurBase(L) + i - 1 else Result := L.Top + i;
end;

function ArgPtr(L: TThread; i: Integer): PLuaValue;
var
  idx: Integer;
begin
  if i > 0 then
  begin
    idx := L.CI[L.NCI - 1].Base + i - 1;
    if idx >= L.Top then Exit(@NilValue);
  end
  else
    idx := L.Top + i;
  Result := @L.Stack[idx];
end;

function LuaArg(L: TThread; i: Integer): TLuaValue;
var
  idx: Integer;
begin
  if i > 0 then
  begin
    idx := CurBase(L) + i - 1;
    if idx >= L.Top then
    begin
      Result.Vt := vtNil;
      Exit;
    end;
  end
  else
    idx := L.Top + i;
  CopyVal(@Result, @L.Stack[idx]);
end;

procedure LuaPush(L: TThread; constref v: TLuaValue);
begin
  if L.Top >= L.StackSize then L.EnsureStack(L.Top + 1);
  CopyVal(@L.Stack[L.Top], @v);
  Inc(L.Top);
end;

procedure LuaSetTop(L: TThread; n: Integer);
begin
  L.SetTop(CurBase(L) + n);
end;

function MetatableOf(L: TThread; constref v: TLuaValue): TTable; inline;
begin
  case v.Vt of
    vtTab: Result := v.T.Metatable;
    vtUser: Result := v.U.Metatable;
  else
    Result := L.Main.TypeMeta[v.Vt];
  end;
end;

function GetMetatable(L: TThread; constref v: TLuaValue): TTable;
begin
  Result := MetatableOf(L, v);
end;

function GetTM(L: TThread; constref v: TLuaValue; tm: Integer): TLuaValue;
var
  mt: TTable;
begin
  mt := MetatableOf(L, v);
  if mt = nil then
    Result.Vt := vtNil
  else
    Result := TableGetStr(mt, TMName(tm));
end;

function GetMetaField(L: TThread; constref v: TLuaValue; const name: string): TLuaValue;
var
  mt: TTable;
begin
  mt := MetatableOf(L, v);
  if mt = nil then
    Result.Vt := vtNil
  else
    Result := TableGetStr(mt, L.Main.NewString(RawByteString(name)));
end;

function ObjTypeName(L: TThread; constref v: TLuaValue): string;
var
  mt: TTable;
  n: TLuaValue;
begin
  if v.Vt in [vtTab, vtUser] then
  begin
    mt := MetatableOf(L, v);
    if mt <> nil then
    begin
      n := TableGetStr(mt, L.Main.NewString('__name'));
      if n.Vt = vtStr then Exit(string(n.S.Str));
    end;
  end;
  Result := VTypeName(v);
end;

function LuaTypeName(L: TThread; i: Integer): string;
begin
  Result := ObjTypeName(L, LuaArg(L, i));
end;

{ ===================================================================== }
{ debug information                                                      }
{ ===================================================================== }

function ProtoLineAt(p: TProto; pc: Integer): Integer;
begin
  if (pc >= 0) and (pc < Length(p.LineInfo)) then Result := p.LineInfo[pc] else Result := -1;
end;

function ci_CurrentLine(const ci: TCallInfo): Integer;
begin
  if ci.IsC or (ci.Func = nil) then Exit(-1);
  Result := ProtoLineAt(ci.Func.Proto, ci.SavedPC - 1);
end;

function LocalNameAt(p: TProto; n: Integer; pc: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to Length(p.LocVars) - 1 do
  begin
    if p.LocVars[i].StartPC > pc then Break;
    if pc < p.LocVars[i].EndPC then
    begin
      Dec(n);
      if n = 0 then
      begin
        if p.LocVars[i].Name <> nil then Result := string(p.LocVars[i].Name.Str);
        Exit;
      end;
    end;
  end;
end;

function UpvalName(p: TProto; idx: Integer): string;
begin
  if (idx >= 0) and (idx < Length(p.UpvalDescs)) and (p.UpvalDescs[idx].Name <> nil) then
    Result := string(p.UpvalDescs[idx].Name.Str)
  else
    Result := '?';
end;

// does the instruction write register 'reg'?
function InstrSetsReg(const ins: TInstruction; reg: Integer): Boolean;
begin
  case ins.Op of
    OP_LOADNIL: Result := (ins.A <= reg) and (reg <= ins.A + ins.B);
    OP_TFORCALL: Result := reg >= ins.A + 3;
    OP_CALL, OP_TAILCALL: Result := reg >= ins.A;
    OP_SELF: Result := (reg = ins.A) or (reg = ins.A + 1);
    OP_VARARG: Result := reg >= ins.A;
    OP_FORPREP, OP_FORLOOP: Result := (reg >= ins.A) and (reg <= ins.A + 2);
    OP_TFORPREP: Result := (reg >= ins.A + 2) and (reg <= ins.A + 3);
    OP_SETUPVAL, OP_SETTABUP, OP_SETTABLE, OP_SETLIST, OP_CLOSE, OP_TBC,
    OP_JMP, OP_JT, OP_JF, OP_EQ, OP_LT, OP_LE, OP_RETURN, OP_ERRNNIL,
    OP_NOP, OP_TFORLOOP: Result := False;
  else
    Result := reg = ins.A;
  end;
end;

function FindSetReg(p: TProto; lastpc, reg: Integer): Integer;
var
  pc, setreg, jmptarget, dest: Integer;
  ins: TInstruction;
begin
  setreg := -1;
  jmptarget := 0;
  for pc := 0 to lastpc - 1 do
  begin
    ins := p.Code[pc];
    case ins.Op of
      OP_JMP: begin
        dest := ins.A;
        if (dest > pc) and (dest <= lastpc) and (dest > jmptarget) then jmptarget := dest;
      end;
      OP_JT, OP_JF: begin
        dest := ins.B;
        if (dest > pc) and (dest <= lastpc) and (dest > jmptarget) then jmptarget := dest;
      end;
    end;
    if InstrSetsReg(ins, reg) then
    begin
      if pc < jmptarget then setreg := -1 else setreg := pc;
    end;
  end;
  Result := setreg;
end;

function KName(p: TProto; x: Integer; var name: string): string;
begin
  // x is an RK operand: constants are negative
  if (x < 0) and (-1 - x < Length(p.K)) and (p.K[-1 - x].Vt = vtStr) then
  begin
    name := string(p.K[-1 - x].S.Str);
    Result := 'constant';
  end
  else
  begin
    name := '?';
    Result := '';
  end;
end;

function BasicGetObjName(p: TProto; var pc: Integer; reg: Integer; var name: string): string;
var
  ins: TInstruction;
begin
  name := LocalNameAt(p, reg + 1, pc);
  if name <> '' then Exit('local');
  pc := FindSetReg(p, pc, reg);
  Result := '';
  if pc >= 0 then
  begin
    ins := p.Code[pc];
    case ins.Op of
      OP_MOVE:
        if ins.B < ins.A then
          Exit(BasicGetObjName(p, pc, ins.B, name));
      OP_GETUPVAL: begin
        name := UpvalName(p, ins.B);
        Exit('upvalue');
      end;
      OP_LOADK:
        if (ins.B < Length(p.K)) and (p.K[ins.B].Vt = vtStr) then
        begin
          name := string(p.K[ins.B].S.Str);
          Exit('constant');
        end;
    end;
  end;
  name := '';
end;

function RegName(p: TProto; pc, reg: Integer; var name: string): string;
var
  what: string;
begin
  what := BasicGetObjName(p, pc, reg, name);
  if what <> 'constant' then name := '?';
  Result := what;
end;

function IsEnvTable(p: TProto; pc: Integer; const ins: TInstruction; isUp: Boolean): string;
var
  name, what: string;
begin
  name := '';
  if isUp then
    name := UpvalName(p, ins.B)
  else
  begin
    what := BasicGetObjName(p, pc, ins.B, name);
    if (what <> 'local') and (what <> 'upvalue') then name := '';
  end;
  if name = '_ENV' then Result := 'global' else Result := 'field';
end;

function GetObjName(p: TProto; lastpc, reg: Integer; var name: string): string;
var
  pc: Integer;
  ins: TInstruction;
begin
  pc := lastpc;
  Result := BasicGetObjName(p, pc, reg, name);
  if Result <> '' then Exit;
  if pc < 0 then Exit;
  ins := p.Code[pc];
  case ins.Op of
    OP_GETTABUP: begin
      KName(p, ins.C, name);
      Result := IsEnvTable(p, pc, ins, True);
    end;
    OP_GETTABLE: begin
      if ins.C < 0 then KName(p, ins.C, name) else RegName(p, pc, ins.C, name);
      Result := IsEnvTable(p, pc, ins, False);
    end;
    OP_SELF: begin
      if ins.C < 0 then KName(p, ins.C, name) else RegName(p, pc, ins.C, name);
      Result := 'method';
    end;
    OP_GETVARG: begin
      if ins.C < 0 then KName(p, ins.C, name) else RegName(p, pc, ins.C, name);
      Result := 'field';
    end;
  end;
end;

function FuncNameFromCode(p: TProto; pc: Integer; var name: string): string;
var
  ins: TInstruction;
  tm: Integer;
begin
  Result := '';
  if (pc < 0) or (pc >= Length(p.Code)) then Exit;
  ins := p.Code[pc];
  tm := -1;
  case ins.Op of
    OP_CALL, OP_TAILCALL: Exit(GetObjName(p, pc, ins.A, name));
    OP_TFORCALL: begin
      name := 'for iterator';
      Exit('for iterator');
    end;
    OP_SELF, OP_GETTABUP, OP_GETTABLE: tm := TM_INDEX;
    OP_SETTABUP, OP_SETTABLE: tm := TM_NEWINDEX;
    OP_ADD: tm := TM_ADD;
    OP_SUB: tm := TM_SUB;
    OP_MUL: tm := TM_MUL;
    OP_MOD: tm := TM_MOD;
    OP_POW: tm := TM_POW;
    OP_DIV: tm := TM_DIV;
    OP_IDIV: tm := TM_IDIV;
    OP_BAND: tm := TM_BAND;
    OP_BOR: tm := TM_BOR;
    OP_BXOR: tm := TM_BXOR;
    OP_SHL: tm := TM_SHL;
    OP_SHR: tm := TM_SHR;
    OP_UNM: tm := TM_UNM;
    OP_BNOT: tm := TM_BNOT;
    OP_LEN: tm := TM_LEN;
    OP_CONCAT: tm := TM_CONCAT;
    OP_EQ: tm := TM_EQ;
    OP_LT: tm := TM_LT;
    OP_LE: tm := TM_LE;
    OP_CLOSE, OP_RETURN: tm := TM_CLOSE;
  else
    Exit;
  end;
  name := Copy(MT_NAMES[tm], 3, 100);
  Result := 'metamethod';
end;

function FuncNameFromCall(L: TThread; ciIdx: Integer; var name: string): string;
var
  caller: TCallInfo;
begin
  Result := '';
  if (ciIdx <= 0) or (ciIdx >= L.NCI) then Exit;
  if L.CI[ciIdx].IsTail then Exit;
  caller := L.CI[ciIdx - 1];
  if caller.Hooked then
  begin
    name := '?';
    Exit('hook');
  end;
  if caller.InFinalizer then
  begin
    name := '__gc';
    Exit('metamethod');
  end;
  if caller.IsC or (caller.Func = nil) then Exit;
  Result := FuncNameFromCode(caller.Func.Proto, caller.SavedPC - 1, name);
end;

{ ===================================================================== }
{ errors                                                                 }
{ ===================================================================== }

function ErrorPosition(L: TThread; level: Integer): string;
var
  idx: Integer;
  ci: TCallInfo;
  p: TProto;
begin
  Result := '';
  idx := L.NCI - 1 - level;
  if (idx < 0) or (idx >= L.NCI) then Exit;
  ci := L.CI[idx];
  if ci.IsC or (ci.Func = nil) then Exit;
  p := ci.Func.Proto;
  if p.Source = nil then
    Result := '?:?: '
  else
    Result := Format('%s:%d: ', [ChunkIdStr(string(p.Source.Str)), ProtoLineAt(p, ci.SavedPC - 1)]);
end;

procedure LuaError(L: TLua; const msg: string);
begin
  raise ELuaError.CreateMsg(ErrorPosition(L, 1) + msg);
end;

procedure LuaErrorFmt(L: TLua; const msg: string; const args: array of const);
begin
  LuaError(L, Format(msg, args));
end;

procedure RunError(L: TThread; const msg: string);
begin
  raise ELuaError.CreateMsg(ErrorPosition(L, 0) + msg);
end;

procedure LuaRuntimeError(L: TLua; const msg: string);
begin
  RunError(L, msg);
end;

procedure LuaThrow(L: TLua; constref v: TLuaValue);
begin
  raise ELuaError.CreateValue(v);
end;

function ErrorValueOf(L: TLua; E: ELuaError): TLuaValue;
begin
  if E.HasValue then
    Result := E.ErrValue
  else
    Result := LuaStr(L.NewString(RawByteString(E.Message)));
end;

function VarInfoOf(L: TThread; kind: TOperandKind; idx: Integer): string;
var
  ci: TCallInfo;
  p: TProto;
  k, name: string;
begin
  Result := '';
  if (L.NCI = 0) or (kind = okNone) then Exit;
  ci := L.CI[L.NCI - 1];
  if ci.IsC or (ci.Func = nil) then Exit;
  p := ci.Func.Proto;
  name := '';
  if kind = okUpval then
  begin
    name := UpvalName(p, idx);
    k := 'upvalue';
  end
  else
    k := GetObjName(p, ci.SavedPC - 1, idx, name);
  if k <> '' then Result := Format(' (%s ''%s'')', [k, name]);
end;

procedure TypeError(L: TThread; constref v: TLuaValue; const op: string;
                    kind: TOperandKind; idx: Integer);
begin
  RunError(L, Format('attempt to %s a %s value%s',
                     [op, ObjTypeName(L, v), VarInfoOf(L, kind, idx)]));
end;

procedure CallError(L: TThread; constref v: TLuaValue);
var
  ci: TCallInfo;
  name, kind, extra: string;
begin
  extra := '';
  if L.NCI > 0 then
  begin
    ci := L.CI[L.NCI - 1];
    if (not ci.IsC) and (ci.Func <> nil) then
    begin
      name := '';
      kind := FuncNameFromCode(ci.Func.Proto, ci.SavedPC - 1, name);
      if kind <> '' then
        extra := Format(' (%s ''%s'')', [kind, name]);
    end;
  end;
  RunError(L, Format('attempt to call a %s value%s', [ObjTypeName(L, v), extra]));
end;

{ ===================================================================== }
{ upvalues, to-be-closed variables                                       }
{ ===================================================================== }

function FindUpval(L: TThread; idx: Integer): TUpval;
var
  p, prev: TUpval;
begin
  prev := nil;
  p := L.OpenUpvals;
  while (p <> nil) and (p.Idx >= idx) do
  begin
    if p.Idx = idx then Exit(p);
    prev := p;
    p := p.NextOpen;
  end;
  Result := L.Main.NewUpval;
  Result.Th := L;
  Result.Idx := idx;
  Result.P := @L.Stack[idx];
  Result.NextOpen := p;
  if prev = nil then L.OpenUpvals := Result else prev.NextOpen := Result;
end;

procedure CloseUpvals(L: TThread; level: Integer);
var
  u: TUpval;
begin
  while (L.OpenUpvals <> nil) and (L.OpenUpvals.Idx >= level) do
  begin
    u := L.OpenUpvals;
    L.OpenUpvals := u.NextOpen;
    u.V := L.Stack[u.Idx];
    u.Idx := -1;
    u.P := @u.V;
    u.Th := nil;
    u.NextOpen := nil;
  end;
end;

procedure RegisterTbc(L: TLua; idx: Integer);
var
  v: TLuaValue;
  name: string;
  ci: TCallInfo;
begin
  v := L.Stack[idx];
  if IsFalse(v) then Exit;   // nil and false need no closing
  if GetTM(L, v, TM_CLOSE).Vt = vtNil then
  begin
    name := '?';
    ci := L.CI[L.NCI - 1];
    if (not ci.IsC) and (ci.Func <> nil) then
    begin
      name := LocalNameAt(ci.Func.Proto, idx - ci.Base + 1, ci.SavedPC - 1);
      if name = '' then name := '?';
    end;
    RunError(L, Format('variable ''%s'' got a non-closable value', [name]));
  end;
  if L.NTbc >= Length(L.TbcList) then SetLength(L.TbcList, L.NTbc * 2 + 8);
  L.TbcList[L.NTbc] := idx;
  Inc(L.NTbc);
end;

// calls the __close metamethod of the value at stack index idx
procedure CallClose(L: TLua; idx: Integer; constref err: TLuaValue; hasErr: Boolean);
var
  v, tm: TLuaValue;
  fi: Integer;
begin
  v := L.Stack[idx];
  tm := GetTM(L, v, TM_CLOSE);
  fi := L.Top;
  L.EnsureStack(fi + 5);
  L.Stack[fi] := tm;
  L.Stack[fi + 1] := v;
  if hasErr then
  begin
    L.Stack[fi + 2] := err;
    L.Top := fi + 3;
  end
  else
    L.Top := fi + 2;   // no error: the method receives no second argument
  if tm.Vt = vtNil then
    RunError(L, 'metamethod ''close'' is not callable');
  LuaCallK(L, Ord(hasErr) + 1, 0);
end;

// closes (normally) all to-be-closed variables at or above 'level'
procedure CloseTbcUpTo(L: TLua; level: Integer);
var
  idx: Integer;
  nilv: TLuaValue;
begin
  nilv.Vt := vtNil;
  while (L.NTbc > 0) and (L.TbcList[L.NTbc - 1] >= level) do
  begin
    idx := L.TbcList[L.NTbc - 1];
    Dec(L.NTbc);
    CallClose(L, idx, nilv, False);
  end;
end;

// closes upvalues and variables of a function that is finishing or being
// unwound because of an error; an error in a closing method replaces 'err'
procedure CloseThreadVars(L: TLua; level: Integer; var err: TLuaValue; hasErr: Boolean);
var
  idx, savedTop, savedNCI, savedCc, savedNNY: Integer;
  savedHook: Boolean;
begin
  CloseUpvals(L, level);
  savedTop := L.Top;
  savedNCI := L.NCI;
  savedCc := L.NCcalls;
  savedNNY := L.NNY;
  savedHook := L.InHook;
  L.EnsureStack(savedTop + 2);
  L.Stack[savedTop] := err;   // keeps the pending error visible to the GC
  while (L.NTbc > 0) and (L.TbcList[L.NTbc - 1] >= level) do
  begin
    idx := L.TbcList[L.NTbc - 1];
    Dec(L.NTbc);
    try
      L.Top := savedTop + 1;
      CallClose(L, idx, err, hasErr);
    except
      on E: ELuaError do
      begin
        err := ErrorValueOf(L, E);
        L.NCI := savedNCI;
        L.NCcalls := savedCc;
        L.NNY := savedNNY;
        L.InHook := savedHook;
        L.Stack[savedTop] := err;
        hasErr := True;
      end;
    end;
  end;
  L.Top := savedTop;
end;

{ ===================================================================== }
{ calls                                                                  }
{ ===================================================================== }

procedure PushCI(L: TThread; f: TFunction; funcIdx, base, top, nresults: Integer; isC: Boolean);
var
  ci: ^TCallInfo;
begin
  if L.NCI >= L.CISize then
    raise ELuaError.CreateMsg('stack overflow');
  ci := @L.CI[L.NCI];
  ci^.Func := f;
  ci^.FuncIdx := funcIdx;
  ci^.Base := base;
  ci^.Top := top;
  ci^.SavedPC := 0;
  ci^.NResults := nresults;
  ci^.NExtra := 0;
  ci^.IsC := isC;
  ci^.IsTail := False;
  ci^.Hooked := False;
  ci^.Fresh := False;
  ci^.InFinalizer := False;
  ci^.FTransfer := 0;
  ci^.NTransfer := 0;
  ci^.ExtraArgs := PendingExtra;
  PendingExtra := 0;
  Inc(L.NCI);
end;

function ThreadMaxCI(L: TThread): Integer; inline;
begin
  if L.Runner = nil then Result := MainMaxCI else Result := CoMaxCI;
end;

procedure CallHook(L: TLua; const ev: string; line: Integer); forward;
procedure CallHookTransfer(L: TLua; const ev: string; ftr, ntr: Integer); forward;

// moves 'n' results starting at 'first' to 'res'
procedure PostCall(L: TLua; res, first, n, wanted: Integer);
var
  i: Integer;
begin
  if wanted < 0 then
  begin
    if res <> first then
      for i := 0 to n - 1 do L.Stack[res + i] := L.Stack[first + i];
    L.Top := res + n;
  end
  else
  begin
    if n > wanted then n := wanted;
    if res <> first then
      for i := 0 to n - 1 do L.Stack[res + i] := L.Stack[first + i];
    for i := n to wanted - 1 do L.Stack[res + i].Vt := vtNil;
    L.Top := res + wanted;
  end;
end;

procedure CallC(L: TLua; f: TFunction; funcIdx, nargs, nresults: Integer);
var
  n: Integer;
begin
  L.EnsureStack(L.Top + LUA_MINSTACK + 5);
  PushCI(L, f, funcIdx, funcIdx + 1, L.Top + LUA_MINSTACK, nresults, True);
  if L.HookMask <> 0 then
    if (L.HookMask and HOOK_CALL) <> 0 then CallHookTransfer(L, 'call', 1, nargs);
  n := f.CProc(L);
  if L.HookMask <> 0 then
    if (L.HookMask and HOOK_RET) <> 0 then CallHookTransfer(L, 'return', L.Top - n - funcIdx, n);
  PostCall(L, funcIdx, L.Top - n, n, nresults);
  Dec(L.NCI);
  // a Lua caller continues after its call instruction (for line events)
  if (L.HookMask <> 0) and (L.NCI > 0) and not L.CI[L.NCI - 1].IsC then
    L.OldLine := L.CI[L.NCI - 1].SavedPC - 1;
end;

// raised when the stack is exhausted; while a message handler is already running
// on the reserve space, the error is a failure of the handler itself
procedure StackOverflow(L: TLua);
begin
  if StackSlack > 0 then
    raise ELuaError.CreateMsg('error in error handling')
  else
    RunError(L, 'stack overflow');
end;

// prepares the frame of a Lua function: returns the new base
procedure SetupLuaFrame(L: TLua; f: TFunction; funcIdx, nargs: Integer;
                        var base, nextra: Integer);
var
  p: TProto;
  nfix, i, need: Integer;
  tbl: TTable;
begin
  p := f.Proto;
  nfix := p.NumParams;
  need := funcIdx + 2 + nargs + nfix + p.MaxStackSize + LUA_MINSTACK;
  if need > MAXSTACK + StackSlack then
    StackOverflow(L);
  L.EnsureStack(need);
  for i := nargs to nfix - 1 do
    L.Stack[funcIdx + 1 + i].Vt := vtNil;
  if p.IsVararg then
  begin
    if nargs < nfix then nargs := nfix;
    nextra := nargs - nfix;
    base := funcIdx + 1 + nargs;
    for i := 0 to nfix - 1 do
    begin
      L.Stack[base + i] := L.Stack[funcIdx + 1 + i];
      L.Stack[funcIdx + 1 + i].Vt := vtNil;
    end;
    L.Stack[base + nfix].Vt := vtNil;   // the (virtual) vararg table local
    if p.VarTabReg >= 0 then
    begin
      tbl := L.Main.NewTable(nextra, 1);
      for i := 1 to nextra do
        TableSetInt(tbl, i, L.Stack[funcIdx + nfix + i]);
      TableSetStr(tbl, L.Main.NewString('n'), LuaInt(nextra));
      L.Stack[base + p.VarTabReg] := LuaTab(tbl);
    end;
  end
  else
  begin
    base := funcIdx + 1;
    nextra := 0;
  end;
end;

procedure VMExecute(L: TLua); forward;

procedure EnterLuaFrame(L: TLua; nf: TFunction; funcIdx, nargs, nres: Integer); forward;

procedure CallLua(L: TLua; f: TFunction; funcIdx, nargs, nresults: Integer);
begin
  EnterLuaFrame(L, f, funcIdx, nargs, nresults);
  L.CI[L.NCI - 1].Fresh := True;
  VMExecute(L);
  Dec(L.NCI);
end;

// replaces a non-function callee by its __call metamethod (shifting arguments)
procedure TryFuncTM(L: TLua; funcIdx: Integer; var nargs: Integer);
var
  v, tm: TLuaValue;
  i: Integer;
begin
  v := L.Stack[funcIdx];
  while v.Vt <> vtFunc do
  begin
    tm := GetTM(L, v, TM_CALL);
    if tm.Vt = vtNil then
      CallError(L, v);
    if PendingExtra >= 15 then
    begin
      PendingExtra := 0;
      RunError(L, '''__call'' chain too long');
    end;
    L.EnsureStack(L.Top + 2);
    for i := L.Top downto funcIdx + 1 do
      L.Stack[i] := L.Stack[i - 1];
    Inc(L.Top);
    Inc(nargs);
    Inc(PendingExtra);
    L.Stack[funcIdx] := tm;
    v := tm;
  end;
end;

procedure DoCall(L: TLua; funcIdx, nargs, nresults: Integer);
var
  f: TFunction;
begin
  if L.Stack[funcIdx].Vt <> vtFunc then
    TryFuncTM(L, funcIdx, nargs);
  f := L.Stack[funcIdx].F;
  if f.IsC then
    CallC(L, f, funcIdx, nargs, nresults)
  else
    CallLua(L, f, funcIdx, nargs, nresults);
end;

procedure IncCCalls(L: TLua);
begin
  Inc(L.NCcalls);
  if L.NCcalls >= MAXCCALLS then
  begin
    if L.NCcalls = MAXCCALLS then
      RunError(L, 'C stack overflow')
    else if L.NCcalls >= MAXCCALLS + 20 then
      raise ELuaError.CreateMsg('error in error handling');
  end;
end;

// (no try/finally here: whoever catches an error restores NCcalls/NNY, see
// LuaProtectedCall, CloseThreadVars and the coroutine entry point)
procedure LuaCall(L: TLua; nargs, nresults: Integer);
begin
  IncCCalls(L);
  Inc(L.NNY);
  DoCall(L, L.Top - nargs - 1, nargs, nresults);
  Dec(L.NNY);
  Dec(L.NCcalls);
end;

procedure LuaCallK(L: TLua; nargs, nresults: Integer);
begin
  IncCCalls(L);
  DoCall(L, L.Top - nargs - 1, nargs, nresults);
  Dec(L.NCcalls);
end;

// calls f(args) from the VM (metamethods); returns its first result
function CallMeta(L: TLua; constref f: TLuaValue; const args: array of TLuaValue): TLuaValue;
var
  idx, i, saveTop: Integer;
begin
  saveTop := L.Top;
  L.EnsureStack(saveTop + Length(args) + 2);
  idx := saveTop;
  L.Stack[idx] := f;
  for i := 0 to High(args) do
    L.Stack[idx + 1 + i] := args[i];
  L.Top := idx + 1 + Length(args);
  LuaCallK(L, Length(args), 1);
  Result := L.Stack[idx];
  L.Top := saveTop;
end;

{ ===================================================================== }
{ hooks                                                                  }
{ ===================================================================== }

procedure SetHookState(L: TThread; constref func: TLuaValue; mask, count: Integer);
begin
  if (func.Vt <> vtFunc) or (mask = 0) then
  begin
    L.HookFunc.Vt := vtNil;
    L.HookMask := 0;
    L.HookCount := 0;
  end
  else
  begin
    L.HookFunc := func;
    L.HookMask := mask;
    L.HookCount := count;
    L.HookCounter := count;
  end;
end;

procedure CallHook(L: TLua; const ev: string; line: Integer);
var
  saveTop, idx: Integer;
  fn: TLuaValue;
begin
  if L.InHook or (L.HookFunc.Vt <> vtFunc) then Exit;
  fn := L.HookFunc;
  saveTop := L.Top;
  if (L.NCI > 0) and (L.Top < L.CI[L.NCI - 1].Top) then
    L.Top := L.CI[L.NCI - 1].Top;
  idx := L.Top;
  L.EnsureStack(idx + 6);
  L.Stack[idx] := fn;
  L.Stack[idx + 1] := LuaStr(L.NewString(RawByteString(ev)));
  if line >= 0 then L.Stack[idx + 2] := LuaInt(line) else L.Stack[idx + 2].Vt := vtNil;
  L.Top := idx + 3;
  L.InHook := True;
  if L.NCI > 0 then L.CI[L.NCI - 1].Hooked := True;
  try
    DoCall(L, idx, 2, 0);
  finally
    if L.NCI > 0 then L.CI[L.NCI - 1].Hooked := False;
    L.InHook := False;
    L.Top := saveTop;
  end;
end;

// a call or return event: the hook can inspect the transferred values (getinfo 'r')
procedure CallHookTransfer(L: TLua; const ev: string; ftr, ntr: Integer);
begin
  if L.InHook or (L.HookFunc.Vt <> vtFunc) or (L.NCI = 0) then Exit;
  L.CI[L.NCI - 1].FTransfer := ftr;
  L.CI[L.NCI - 1].NTransfer := ntr;
  try
    CallHook(L, ev, -1);
  finally
    L.CI[L.NCI - 1].FTransfer := 0;
    L.CI[L.NCI - 1].NTransfer := 0;
  end;
end;

// called before executing the instruction at 'pc'
procedure TraceExec(L: TLua; p: TProto; pc: Integer);
var
  line, oldline: Integer;
begin
  if (L.HookMask and HOOK_INT) <> 0 then
  begin
    L.HookMask := L.HookMask and not HOOK_INT;
    raise ELuaError.CreateMsg('interrupted!');
  end;
  if L.InHook then Exit;
  if (L.HookMask and HOOK_COUNT) <> 0 then
  begin
    Dec(L.HookCounter);
    if L.HookCounter <= 0 then
    begin
      L.HookCounter := L.HookCount;
      CallHook(L, 'count', -1);
    end;
  end;
  if (L.HookMask and HOOK_LINE) <> 0 then
  begin
    line := ProtoLineAt(p, pc);
    oldline := ProtoLineAt(p, L.OldLine);
    if (pc <= L.OldLine) or (line <> oldline) then
      CallHook(L, 'line', line);   // without debug information the line is nil
    L.OldLine := pc;
  end;
end;

{ ===================================================================== }
{ strings, comparison                                                    }
{ ===================================================================== }

function c_strcoll(a, b: PChar): Integer; cdecl; external 'c' name 'strcoll';
function c_strlen(a: PChar): SizeUInt; cdecl; external 'c' name 'strlen';

// string comparison honouring the collation locale (like strcoll), with
// embedded zeros handled segment by segment
function StrCompareP(s1: PChar; rl1: SizeUInt; s2: PChar; rl2: SizeUInt): Integer;
var
  zl1, zl2: SizeUInt;
  t: Integer;
begin
  while True do
  begin
    t := c_strcoll(s1, s2);
    if t <> 0 then Exit(t);
    zl1 := c_strlen(s1);
    zl2 := c_strlen(s2);
    if zl2 = rl2 then
    begin
      if zl1 = rl1 then Exit(0) else Exit(1);
    end
    else if zl1 = rl1 then
      Exit(-1);
    Inc(zl1);
    Inc(zl2);
    Inc(s1, zl1);
    Dec(rl1, zl1);
    Inc(s2, zl2);
    Dec(rl2, zl2);
  end;
end;

function StrCompare(const a, b: RawByteString): Integer;
var
  s1, s2: PChar;
begin
  s1 := PChar(Pointer(a));
  s2 := PChar(Pointer(b));
  if s1 = nil then s1 := '';
  if s2 = nil then s2 := '';
  Result := StrCompareP(s1, Length(a), s2, Length(b));
end;

function StrLess(const a, b: RawByteString): Boolean;
begin
  Result := StrCompare(a, b) < 0;
end;

function StrLessEq(const a, b: RawByteString): Boolean;
begin
  Result := StrCompare(a, b) <= 0;
end;

function CallTMRes(L: TLua; constref tm, a, b: TLuaValue): TLuaValue;
begin
  Result := CallMeta(L, tm, [a, b]);
end;

procedure OrderError(L: TLua; constref a, b: TLuaValue);
var
  t1, t2: string;
begin
  t1 := ObjTypeName(L, a);
  t2 := ObjTypeName(L, b);
  if t1 = t2 then
    RunError(L, Format('attempt to compare two %s values', [t1]))
  else
    RunError(L, Format('attempt to compare %s with %s', [t1, t2]));
end;

function LuaEquals(L: TLua; constref a, b: TLuaValue): Boolean;
var
  tm: TLuaValue;
begin
  if RawEqual(a, b) then Exit(True);
  if a.Vt <> b.Vt then Exit(False);
  if a.Vt = vtTab then
  begin
    tm := GetTM(L, a, TM_EQ);
    if tm.Vt = vtNil then tm := GetTM(L, b, TM_EQ);
  end
  else if a.Vt = vtUser then
  begin
    tm := GetTM(L, a, TM_EQ);
    if tm.Vt = vtNil then tm := GetTM(L, b, TM_EQ);
  end
  else
    Exit(False);
  if tm.Vt = vtNil then Exit(False);
  Result := Truthy(CallTMRes(L, tm, a, b));
end;

function LuaLessThan(L: TLua; constref a, b: TLuaValue): Boolean;
var
  tm: TLuaValue;
begin
  if IsNumber(a) and IsNumber(b) then Exit(NumLess(a, b));
  if (a.Vt = vtStr) and (b.Vt = vtStr) then Exit(StrCompareP(PChar(a.S.Data), a.S.Len, PChar(b.S.Data), b.S.Len) < 0);
  tm := GetTM(L, a, TM_LT);
  if tm.Vt = vtNil then tm := GetTM(L, b, TM_LT);
  if tm.Vt = vtNil then OrderError(L, a, b);
  Result := Truthy(CallTMRes(L, tm, a, b));
end;

function LuaLessEqual(L: TLua; constref a, b: TLuaValue): Boolean;
var
  tm: TLuaValue;
begin
  if IsNumber(a) and IsNumber(b) then Exit(NumLessEq(a, b));
  if (a.Vt = vtStr) and (b.Vt = vtStr) then Exit(StrCompareP(PChar(a.S.Data), a.S.Len, PChar(b.S.Data), b.S.Len) <= 0);
  tm := GetTM(L, a, TM_LE);
  if tm.Vt = vtNil then tm := GetTM(L, b, TM_LE);
  if tm.Vt = vtNil then OrderError(L, a, b);
  Result := Truthy(CallTMRes(L, tm, a, b));
end;

{ ===================================================================== }
{ table access with metamethods                                          }
{ ===================================================================== }

function FinishGet(L: TLua; constref t, key: TLuaValue; kind: TOperandKind; idx: Integer): TLuaValue;
var
  cur, tm, v: TLuaValue;
  loop: Integer;
  mt: TTable;
begin
  cur := t;
  for loop := 1 to MAXTAGLOOP do
  begin
    if cur.Vt = vtTab then
    begin
      v := TableGet(cur.T, key);
      if v.Vt <> vtNil then Exit(v);
      mt := cur.T.Metatable;
      if mt = nil then Exit(v);
      tm := TableGetStr(mt, TMName(TM_INDEX));
      if tm.Vt = vtNil then Exit(v);
    end
    else
    begin
      tm := GetTM(L, cur, TM_INDEX);
      if tm.Vt = vtNil then
        TypeError(L, cur, 'index', kind, idx);
    end;
    if tm.Vt = vtFunc then
      Exit(CallTMRes(L, tm, cur, key));
    cur := tm;
    kind := okNone;
  end;
  RunError(L, '''__index'' chain too long; possible loop');
  Result.Vt := vtNil;
end;

procedure RawSetChecked(L: TLua; t: TTable; constref key, val: TLuaValue);
begin
  if key.Vt = vtNil then
    RunError(L, 'table index is nil');
  if (key.Vt = vtFlt) and IsNaN(key.N) then
    RunError(L, 'table index is NaN');
  TableSet(t, key, val);
end;

procedure FinishSet(L: TLua; constref t, key, val: TLuaValue; kind: TOperandKind; idx: Integer);
var
  cur, tm, old: TLuaValue;
  loop: Integer;
  mt: TTable;
begin
  cur := t;
  for loop := 1 to MAXTAGLOOP do
  begin
    if cur.Vt = vtTab then
    begin
      mt := cur.T.Metatable;
      if mt = nil then
      begin
        RawSetChecked(L, cur.T, key, val);
        Exit;
      end;
      old := TableGet(cur.T, key);
      if old.Vt <> vtNil then
      begin
        TableSet(cur.T, key, val);
        Exit;
      end;
      tm := TableGetStr(mt, TMName(TM_NEWINDEX));
      if tm.Vt = vtNil then
      begin
        RawSetChecked(L, cur.T, key, val);
        Exit;
      end;
    end
    else
    begin
      tm := GetTM(L, cur, TM_NEWINDEX);
      if tm.Vt = vtNil then
        TypeError(L, cur, 'index', kind, idx);
    end;
    if tm.Vt = vtFunc then
    begin
      CallMeta(L, tm, [cur, key, val]);
      Exit;
    end;
    cur := tm;
    kind := okNone;
  end;
  RunError(L, '''__newindex'' chain too long; possible loop');
end;

function LuaIndex(L: TLua; constref t, key: TLuaValue): TLuaValue;
begin
  Result := FinishGet(L, t, key, okNone, 0);
end;

procedure LuaSetIndex(L: TLua; constref t, key, val: TLuaValue);
begin
  FinishSet(L, t, key, val, okNone, 0);
end;

{ ===================================================================== }
{ arithmetic, length, concatenation                                      }
{ ===================================================================== }

function ArithEvent(op: Integer): Integer;
begin
  case op of
    OP_ADD: Result := TM_ADD;
    OP_SUB: Result := TM_SUB;
    OP_MUL: Result := TM_MUL;
    OP_MOD: Result := TM_MOD;
    OP_POW: Result := TM_POW;
    OP_DIV: Result := TM_DIV;
    OP_IDIV: Result := TM_IDIV;
    OP_BAND: Result := TM_BAND;
    OP_BOR: Result := TM_BOR;
    OP_BXOR: Result := TM_BXOR;
    OP_SHL: Result := TM_SHL;
    OP_SHR: Result := TM_SHR;
    OP_UNM: Result := TM_UNM;
  else
    Result := TM_BNOT;
  end;
end;

// converts strings to numbers for arithmetic (not bitwise) operations
function CoerceNum(constref v: TLuaValue; var r: TLuaValue): Boolean;
var
  i: Int64;
  n: Double;
begin
  case v.Vt of
    vtInt, vtFlt: begin r := v; Exit(True); end;
    vtStr: begin
      if StrToIntVal(v.S.Str, i) then begin r := LuaInt(i); Exit(True); end;
      if StrToNumVal(v.S.Str, n) then begin r := LuaNum(n); Exit(True); end;
    end;
  end;
  Result := False;
end;

procedure ArithStatusError(L: TLua; st: TArithResult; constref a, b: TLuaValue;
                           ka: TOperandKind; ia: Integer; kb: TOperandKind; ib: Integer);
var
  tmp: Int64;
begin
  case st of
    arDivZero: RunError(L, 'attempt to divide by zero');
    arModZero: RunError(L, 'attempt to perform ''n%0''');
    arNoInteger: begin
      // choose the operand that cannot be converted
      if (a.Vt = vtInt) or ((a.Vt = vtFlt) and FloatToInt(a.N, tmp, F2I_EQ)) then
        RunError(L, Format('number%s has no integer representation', [VarInfoOf(L, kb, ib)]))
      else
        RunError(L, Format('number%s has no integer representation', [VarInfoOf(L, ka, ia)]));
    end;
  end;
end;

function ArithSlow(L: TLua; op: Integer; constref a, b: TLuaValue;
                   ka: TOperandKind; ia: Integer; kb: TOperandKind; ib: Integer): TLuaValue;
var
  na, nb, res: TLuaValue;
  st: TArithResult;
  tm: TLuaValue;
  isBit: Boolean;
  oname: string;
begin
  isBit := op in [OP_BAND, OP_BOR, OP_BXOR, OP_SHL, OP_SHR, OP_BNOT];
  if IsNumber(a) and IsNumber(b) then
  begin
    st := ArithNum(op, a, b, res);
    if st <> arOk then ArithStatusError(L, st, a, b, ka, ia, kb, ib);
    Exit(res);
  end;
  // metamethods first (also for strings: a library may install them)
  tm := GetTM(L, a, ArithEvent(op));
  if tm.Vt = vtNil then tm := GetTM(L, b, ArithEvent(op));
  if tm.Vt <> vtNil then
    Exit(CallTMRes(L, tm, a, b));
  // strings are converted to numbers in arithmetic (not bitwise) operations
  if (not isBit) and CoerceNum(a, na) and CoerceNum(b, nb) then
  begin
    st := ArithNum(op, na, nb, res);
    if st <> arOk then ArithStatusError(L, st, na, nb, ka, ia, kb, ib);
    Exit(res);
  end;
  if isBit then
  begin
    if IsNumber(a) and IsNumber(b) then
      ArithStatusError(L, arNoInteger, a, b, ka, ia, kb, ib)
    else if not IsNumber(a) then
      TypeError(L, a, 'perform bitwise operation on', ka, ia)
    else
      TypeError(L, b, 'perform bitwise operation on', kb, ib);
  end;
  if (a.Vt = vtStr) or (b.Vt = vtStr) then
  begin
    oname := Copy(MT_NAMES[ArithEvent(op)], 3, 100);
    RunError(L, Format('attempt to %s a ''%s'' with a ''%s''',
                       [oname, VTypeName(a), VTypeName(b)]));
  end;
  if not IsNumber(a) then
    TypeError(L, a, 'perform arithmetic on', ka, ia)
  else
    TypeError(L, b, 'perform arithmetic on', kb, ib);
  Result.Vt := vtNil;
end;

function LuaArith(L: TLua; op: Integer; constref a, b: TLuaValue): TLuaValue;
begin
  Result := ArithSlow(L, op, a, b, okNone, 0, okNone, 0);
end;

function LuaLen(L: TLua; constref v: TLuaValue): TLuaValue;
var
  tm: TLuaValue;
begin
  case v.Vt of
    vtStr: Exit(LuaInt(v.S.Len));
    vtTab: begin
      if v.T.Metatable = nil then Exit(LuaInt(TableLength(v.T)));
      tm := TableGetStr(v.T.Metatable, TMName(TM_LEN));
      if tm.Vt = vtNil then Exit(LuaInt(TableLength(v.T)));
    end;
  else
    tm := GetTM(L, v, TM_LEN);
    if tm.Vt = vtNil then
      TypeError(L, v, 'get length of', okNone, 0);
  end;
  Result := CallMeta(L, tm, [v, v]);
end;

function ToStringForConcat(constref v: TLuaValue): RawByteString; inline;
begin
  if v.Vt = vtStr then Result := v.S.Str else Result := RawByteString(NumToStr(v));
end;

function LuaConcat2(L: TLua; constref a, b: TLuaValue): TLuaValue;
var
  tm: TLuaValue;
begin
  if (a.Vt in [vtStr, vtInt, vtFlt]) and (b.Vt in [vtStr, vtInt, vtFlt]) then
    Exit(LuaStr(L.NewString(ToStringForConcat(a) + ToStringForConcat(b))));
  tm := GetTM(L, a, TM_CONCAT);
  if tm.Vt = vtNil then tm := GetTM(L, b, TM_CONCAT);
  if tm.Vt = vtNil then
  begin
    if a.Vt in [vtStr, vtInt, vtFlt] then
      TypeError(L, b, 'concatenate', okNone, 0)
    else
      TypeError(L, a, 'concatenate', okNone, 0);
  end;
  Result := CallTMRes(L, tm, a, b);
end;

// formats an integer into the end of buf; returns the index of its first character
function IntToBuf(v: Int64; var buf: array of Byte): Integer;
var
  u: QWord;
  neg: Boolean;
  n: Integer;
begin
  u := QWord(v);
  neg := v < 0;
  if neg then u := QWord(0) - u;
  n := 32;
  repeat
    Dec(n);
    buf[n] := Ord('0') + Byte(u mod 10);
    u := u div 10;
  until u = 0;
  if neg then
  begin
    Dec(n);
    buf[n] := Ord('-');
  end;
  Result := n;
end;

// the strings and numbers in Stack[from .. from+k-1] are joined into Stack[from]
procedure ConcatPieces(L: TLua; from, k: Integer);
var
  i, j: Integer;
  tot: SizeUInt;
  buf: array[0..255] of Byte;
  num: array[0..31] of Byte;
  p, q: PByte;
begin
  tot := 0;
  for i := from to from + k - 1 do
  begin
    if L.Stack[i].Vt = vtStr then Inc(tot, L.Stack[i].S.Len)
    else if L.Stack[i].Vt = vtInt then Inc(tot, 32 - IntToBuf(L.Stack[i].I, num))
    else
    begin
      // floats go through the usual conversion (they are rare here)
      L.Stack[i] := LuaStr(L.NewString(RawByteString(NumToStr(L.Stack[i]))));
      Inc(tot, L.Stack[i].S.Len);
    end;
  end;
  if tot <= SizeOf(buf) then p := @buf[0] else p := GetMem(tot);
  q := p;
  for i := from to from + k - 1 do
  begin
    if L.Stack[i].Vt = vtStr then
    begin
      if L.Stack[i].S.Len > 0 then Move(L.Stack[i].S.Data^, q^, L.Stack[i].S.Len);
      Inc(q, L.Stack[i].S.Len);
    end
    else
    begin
      j := IntToBuf(L.Stack[i].I, num);
      Move(num[j], q^, 32 - j);
      Inc(q, 32 - j);
    end;
  end;
  L.Stack[from].S := L.NewStringBuf(p, tot);
  L.Stack[from].Vt := vtStr;
  if p <> @buf[0] then FreeMem(p);
end;

// R[first .. first+n-1] are concatenated into R[first]
procedure ConcatRegs(L: TLua; first, n: Integer);
var
  top, total, k: Integer;
  a, b, r: TLuaValue;
  tm: TLuaValue;
  base: Integer;
  ka: TOperandKind;
begin
  base := L.CI[L.NCI - 1].Base;
  total := n;
  top := first + n;      // exclusive
  while total > 1 do
  begin
    a := L.Stack[top - 2];
    b := L.Stack[top - 1];
    if (a.Vt in [vtStr, vtInt, vtFlt]) and (b.Vt in [vtStr, vtInt, vtFlt]) then
    begin
      // collect as many strings/numbers as possible
      k := 2;
      while (k < total) and (L.Stack[top - k - 1].Vt in [vtStr, vtInt, vtFlt]) do
        Inc(k);
      ConcatPieces(L, top - k, k);
      Dec(total, k - 1);
      Dec(top, k - 1);
    end
    else
    begin
      tm := GetTM(L, a, TM_CONCAT);
      if tm.Vt = vtNil then tm := GetTM(L, b, TM_CONCAT);
      if tm.Vt = vtNil then
      begin
        if a.Vt in [vtStr, vtInt, vtFlt] then
          TypeError(L, b, 'concatenate', okReg, top - 1 - base)
        else
          TypeError(L, a, 'concatenate', okReg, top - 2 - base);
      end;
      r := CallTMRes(L, tm, a, b);
      L.Stack[top - 2] := r;
      Dec(total);
      Dec(top);
    end;
  end;
  ka := okNone;
  if ka = okNone then ;
end;

{ ===================================================================== }
{ the instruction loop                                                   }
{ ===================================================================== }

function GetRK(L: TLua; base: Integer; kk: PLuaValue; x: Integer): PLuaValue; inline;
begin
  if x >= 0 then Result := @L.Stack[base + x] else Result := @kk[-1 - x];
end;

function RKKind(x: Integer): TOperandKind; inline;
begin
  if x >= 0 then Result := okReg else Result := okNone;
end;

// number of extra arguments recorded in the table of a named vararg parameter
function VarargTableCount(L: TLua; tbl: TTable): Integer;
var
  v: PLuaValue;
begin
  v := TableGetStrP(tbl, L.Main.NewString('n'));
  if (v^.Vt <> vtInt) or (v^.I < 0) or (v^.I > MAXSTACK div 2) then
    RunError(L, 'vararg table has no proper ''n''');
  Result := Integer(v^.I);
end;

procedure GlobalDefinedError(L: TLua; constref key: TLuaValue);
begin
  RunError(L, Format('global ''%s'' already defined', [string(key.S.Str)]));
end;

// arithmetic that is not a plain int/float case: coercions, metamethods, errors
procedure ArithGeneric(L: TLua; cidx, base: Integer; kk: PLuaValue; ins: PInstruction; pc: Integer);
var
  vb, vc: PLuaValue;
  st: TArithResult;
  res, v, key: TLuaValue;
  B, C: Integer;
begin
  L.CI[cidx].SavedPC := pc;
  B := ins^.B;
  C := ins^.C;
  vb := GetRK(L, base, kk, B);
  vc := GetRK(L, base, kk, C);
  if IsNumber(vb^) and IsNumber(vc^) then
  begin
    st := ArithNum(ins^.Op, vb^, vc^, res);
    if st <> arOk then
      ArithStatusError(L, st, vb^, vc^, RKKind(B), B, RKKind(C), C);
    L.Stack[base + ins^.A] := res;
  end
  else
  begin
    v := vb^;
    key := vc^;
    res := ArithSlow(L, ins^.Op, v, key, RKKind(B), B, RKKind(C), C);
    L.Stack[base + ins^.A] := res;
  end;
end;

procedure GCCheck(L: TLua; cidx: Integer); inline;
begin
  if L.Main.TotalBytes >= L.Main.GCThreshold then
    L.Main.CheckGC;
end;

// numeric 'for' preparation; returns True if the loop must be skipped
function ForPrep(L: TLua; ra: Integer): Boolean;
var
  init, limit, step: TLuaValue;
  ilimit, istep, iinit: Int64;
  count: QWord;
  fl, fs, fi: Double;
  tmp: TLuaValue;

  function ToNum(constref v: TLuaValue; var d: Double): Boolean;
  var
    r: TLuaValue;
  begin
    Result := CoerceNum(v, r);
    if Result then
      if r.Vt = vtInt then d := Double(r.I) else d := r.N;
  end;

  procedure ForError(constref v: TLuaValue; const what: string);
  begin
    RunError(L, Format('bad ''for'' %s (number expected, got %s)', [what, ObjTypeName(L, v)]));
  end;

begin
  init := L.Stack[ra];
  limit := L.Stack[ra + 1];
  step := L.Stack[ra + 2];
  if (init.Vt = vtInt) and (step.Vt = vtInt) then
  begin
    iinit := init.I;
    istep := step.I;
    if istep = 0 then RunError(L, '''for'' step is zero');
    // compute the integer limit
    if limit.Vt = vtInt then
      ilimit := limit.I
    else
    begin
      if limit.Vt = vtFlt then tmp := limit
      else if not CoerceNum(limit, tmp) then ForError(limit, 'limit');
      if tmp.Vt = vtInt then
        ilimit := tmp.I
      else
      begin
        if not FloatToInt(tmp.N, ilimit, ifthen(istep < 0, F2I_CEIL, F2I_FLOOR)) then
        begin
          // out of integer range (or NaN)
          if IsNaN(tmp.N) then Exit(True);
          if tmp.N > 0 then
          begin
            if istep < 0 then Exit(True);
            ilimit := LUA_MAXINTEGER;
          end
          else
          begin
            if istep > 0 then Exit(True);
            ilimit := LUA_MININTEGER;
          end;
        end;
      end;
    end;
    if istep > 0 then
    begin
      if iinit > ilimit then Exit(True);
      count := QWord(ilimit) - QWord(iinit);
      if istep <> 1 then count := count div QWord(istep);
    end
    else
    begin
      if iinit < ilimit then Exit(True);
      count := QWord(iinit) - QWord(ilimit);
      count := count div (QWord(-(istep + 1)) + 1);
    end;
    L.Stack[ra] := LuaInt(Int64(count));
    L.Stack[ra + 1] := LuaInt(istep);
    L.Stack[ra + 2] := LuaInt(iinit);
    Result := False;
  end
  else
  begin
    if not ToNum(limit, fl) then ForError(limit, 'limit');
    if not ToNum(step, fs) then ForError(step, 'step');
    if not ToNum(init, fi) then ForError(init, 'initial value');
    if fs = 0 then RunError(L, '''for'' step is zero');
    if fs > 0 then
    begin
      if fl < fi then Exit(True);
    end
    else if fi < fl then Exit(True);
    L.Stack[ra] := LuaNum(fl);
    L.Stack[ra + 1] := LuaNum(fs);
    L.Stack[ra + 2] := LuaNum(fi);
    Result := False;
  end;
end;

// looks 'key' up in a table following __index tables; nil when a metamethod function
// would have to be called (the caller then takes the slow path)
function IndexStrFast(t: TTable; key: TStringObj): PLuaValue;
var
  n: Integer;
  r: PLuaValue;
  mt: TTable;
begin
  for n := 1 to MAXTAGLOOP do
  begin
    r := TableGetStrP(t, key);
    if r^.Vt <> vtNil then Exit(r);
    mt := t.Metatable;
    if mt = nil then Exit(r);
    r := TableGetStrP(mt, TMName(TM_INDEX));
    if r^.Vt = vtNil then Exit(@NilValue);
    if r^.Vt <> vtTab then Exit(nil);
    t := r^.T;
  end;
  Result := nil;
end;

// True when assigning a new key to the table cannot involve __newindex
function NoNewIndex(t: TTable): Boolean; inline;
begin
  Result := (t.Metatable = nil) or (TableGetStrP(t.Metatable, TMName(TM_NEWINDEX))^.Vt = vtNil);
end;

procedure EnterLuaFrame(L: TLua; nf: TFunction; funcIdx, nargs, nres: Integer);
var
  nbase, nx, i, top: Integer;
  p: TProto;
  ci: PCallInfo;
begin
  p := nf.Proto;
  nbase := funcIdx + 1;
  top := nbase + p.MaxStackSize;
  // fast path: plain function, room on both stacks, no hook/handler slack in use
  if (not p.IsVararg) and (L.NCI < ThreadMaxCI(L)) and (StackSlack = 0) and
     (top + p.NumParams + LUA_MINSTACK + 2 + nargs <= L.StackSize) and
     (top + p.NumParams + LUA_MINSTACK + 2 + nargs <= MAXSTACK) then
  begin
    for i := nargs to p.NumParams - 1 do L.Stack[nbase + i].Vt := vtNil;
    L.Top := top;
    ci := @L.CI[L.NCI];
    ci^.Func := nf;
    ci^.FuncIdx := funcIdx;
    ci^.Base := nbase;
    ci^.Top := top;
    ci^.SavedPC := 0;
    ci^.NResults := nres;
    ci^.NExtra := 0;
    ci^.IsC := False;
    ci^.IsTail := False;
    ci^.Hooked := False;
    ci^.Fresh := False;
    ci^.InFinalizer := False;
    ci^.FTransfer := 0;
    ci^.NTransfer := 0;
    ci^.ExtraArgs := PendingExtra;
    PendingExtra := 0;
    Inc(L.NCI);
    Exit;
  end;
  if L.NCI >= ThreadMaxCI(L) + StackSlack div 9 then StackOverflow(L);
  SetupLuaFrame(L, nf, funcIdx, nargs, nbase, nx);
  L.Top := nbase + p.MaxStackSize;
  PushCI(L, nf, funcIdx, nbase, L.Top, nres, False);
  L.CI[L.NCI - 1].NExtra := nx;
end;

const
  EXEC_EXIT = -2;       // ExecOther: leave VMExecute
  EXEC_RELOAD = -1;     // ExecOther: the current frame was replaced, restart it
  EXEC_RETURNED = -3;   // ExecOther: the frame returned into its Lua caller

var
  LastRetNres: Integer = 0;   // number of results the returning frame was asked for

// executes the instruction at 'pc' with full semantics (slow paths and rare opcodes);
// returns the next pc or one of the EXEC_ codes
function ExecOther(L: TLua; ci: PCallInfo; f: TFunction; kk: PLuaValue; base, pc: Integer): Integer;
var
  cidx, nextra: Integer;
  p: TProto;
  code: PInstruction;
  ins: PInstruction;
  A, B, C, i, n, nargs, nres, first, funcIdx: Integer;
  vb, vc, vt, tmpv: PLuaValue;
  newt: TTable;
  ra: Integer;
  v, key, res, tmp: TLuaValue;
  st: TArithResult;
  up: TUpval;
  np: TProto;
  nf: TFunction;
  tbl: TTable;
  cnt: QWord;
  step, idx, lim: Int64;
  fstep, flim, fidx: Double;
  cond: Boolean;
  nbase, nx: Integer;
begin
  cidx := L.NCI - 1;
  p := f.Proto;
  code := @p.Code[0];
  nextra := ci^.NExtra;
  ins := @code[pc];
  Inc(pc);
  ci^.SavedPC := pc;
  A := ins^.A;
  B := ins^.B;
  C := ins^.C;
    case ins^.Op of
      OP_MOVE: CopyVal(@L.Stack[base + A], @L.Stack[base + B]);
      OP_LOADK: CopyVal(@L.Stack[base + A], @kk[B]);
      OP_LOADNIL: for i := 0 to B do L.Stack[base + A + i].Vt := vtNil;
      OP_LOADBOOL: SetBoolV(@L.Stack[base + A], B <> 0);
      OP_GETUPVAL: CopyVal(@L.Stack[base + A], f.Upvals[B].Ref);
      OP_SETUPVAL: CopyVal(f.Upvals[B].Ref, @L.Stack[base + A]);
      OP_GETTABUP: begin
        vb := f.Upvals[B].Ref;
        vc := GetRK(L, base, kk, C);
        if vb^.Vt = vtTab then
        begin
          if vc^.Vt = vtStr then vt := TableGetStrP(vb^.T, vc^.S) else vt := TableGetP(vb^.T, vc^);
          if (vt^.Vt <> vtNil) or (vb^.T.Metatable = nil) then
          begin
            CopyVal(@L.Stack[base + A], vt);
            begin Result := pc; Exit; end;
          end;
        end;
        ci^.SavedPC := pc;
        v := vb^;
        key := vc^;
        res := FinishGet(L, v, key, okUpval, B);
        L.Stack[base + A] := res;
      end;
      OP_SETTABUP: begin
        vb := f.Upvals[A].Ref;
        vc := GetRK(L, base, kk, B);
        vt := GetRK(L, base, kk, C);
        if (vb^.Vt = vtTab) and (vc^.Vt = vtStr) then
        begin
          ra := 0;
          if (vb^.T.Metatable = nil) then ra := 1
          else if TableGetStrP(vb^.T, vc^.S)^.Vt <> vtNil then ra := 1;
          if ra <> 0 then
          begin
            TableSetStr(vb^.T, vc^.S, vt^);
            begin Result := pc; Exit; end;
          end;
        end;
        ci^.SavedPC := pc;
        v := vb^;
        key := vc^;
        res := vt^;
        FinishSet(L, v, key, res, okUpval, A);
      end;
      OP_GETTABLE: begin
        vb := @L.Stack[base + B];
        vc := GetRK(L, base, kk, C);
        if vb^.Vt = vtTab then
        begin
          if vc^.Vt = vtInt then vt := TableGetIntP(vb^.T, vc^.I)
          else if vc^.Vt = vtStr then vt := TableGetStrP(vb^.T, vc^.S)
          else vt := TableGetP(vb^.T, vc^);
          if (vt^.Vt <> vtNil) or (vb^.T.Metatable = nil) then
          begin
            CopyVal(@L.Stack[base + A], vt);
            begin Result := pc; Exit; end;
          end;
        end;
        ci^.SavedPC := pc;
        v := vb^;
        key := vc^;
        res := FinishGet(L, v, key, okReg, B);
        L.Stack[base + A] := res;
      end;
      OP_SETTABLE: begin
        vb := @L.Stack[base + A];
        vc := GetRK(L, base, kk, B);
        vt := GetRK(L, base, kk, C);
        if (vb^.Vt = vtTab) and ((vc^.Vt = vtStr) or (vc^.Vt = vtInt)) then
        begin
          if vb^.T.Metatable = nil then ra := 1
          else
          begin
            // a metatable may intercept the creation of a new key
            if vc^.Vt = vtStr then tmpv := TableGetStrP(vb^.T, vc^.S)
            else tmpv := TableGetIntP(vb^.T, vc^.I);
            ra := Ord(tmpv^.Vt <> vtNil);
          end;
          if ra <> 0 then
          begin
            if vc^.Vt = vtStr then TableSetStr(vb^.T, vc^.S, vt^) else TableSetInt(vb^.T, vc^.I, vt^);
            begin Result := pc; Exit; end;
          end;
        end;
        ci^.SavedPC := pc;
        v := vb^;
        key := vc^;
        res := vt^;
        FinishSet(L, v, key, res, okReg, A);
      end;
      OP_NEWTABLE: begin
        ci^.SavedPC := pc;
        newt := L.Main.NewTable(B, C);
        L.Stack[base + A].Vt := vtTab;
        L.Stack[base + A].T := newt;
        // the new table is the topmost live register: everything above is dead
        if L.Main.TotalBytes >= L.Main.GCThreshold then
        begin
          L.GCLimit := base + A + 1;
          GCCheck(L, cidx);
          L.GCLimit := 0;
        end;
      end;
      OP_SELF: begin
        vb := @L.Stack[base + B];
        vc := GetRK(L, base, kk, C);
        v := vb^;
        CopyVal(@L.Stack[base + A + 1], @v);
        if v.Vt = vtTab then
        begin
          if vc^.Vt = vtStr then vt := TableGetStrP(v.T, vc^.S) else vt := TableGetP(v.T, vc^);
          if (vt^.Vt <> vtNil) or (v.T.Metatable = nil) then
          begin
            CopyVal(@L.Stack[base + A], vt);
            begin Result := pc; Exit; end;
          end;
        end;
        ci^.SavedPC := pc;
        key := vc^;
        res := FinishGet(L, v, key, okReg, B);
        L.Stack[base + A] := res;
      end;
      OP_ADD: begin
        vb := GetRK(L, base, kk, B);
        vc := GetRK(L, base, kk, C);
        if vb^.Vt = vtInt then
        begin
          if vc^.Vt = vtInt then begin SetIntV(@L.Stack[base + A], Int64(QWord(vb^.I) + QWord(vc^.I))); begin Result := pc; Exit; end; end;
          if vc^.Vt = vtFlt then begin SetFltV(@L.Stack[base + A], vb^.I + vc^.N); begin Result := pc; Exit; end; end;
        end
        else if vb^.Vt = vtFlt then
        begin
          if vc^.Vt = vtFlt then begin SetFltV(@L.Stack[base + A], vb^.N + vc^.N); begin Result := pc; Exit; end; end;
          if vc^.Vt = vtInt then begin SetFltV(@L.Stack[base + A], vb^.N + vc^.I); begin Result := pc; Exit; end; end;
        end;
        ArithGeneric(L, cidx, base, kk, ins, pc);
      end;
      OP_SUB: begin
        vb := GetRK(L, base, kk, B);
        vc := GetRK(L, base, kk, C);
        if vb^.Vt = vtInt then
        begin
          if vc^.Vt = vtInt then begin SetIntV(@L.Stack[base + A], Int64(QWord(vb^.I) - QWord(vc^.I))); begin Result := pc; Exit; end; end;
          if vc^.Vt = vtFlt then begin SetFltV(@L.Stack[base + A], vb^.I - vc^.N); begin Result := pc; Exit; end; end;
        end
        else if vb^.Vt = vtFlt then
        begin
          if vc^.Vt = vtFlt then begin SetFltV(@L.Stack[base + A], vb^.N - vc^.N); begin Result := pc; Exit; end; end;
          if vc^.Vt = vtInt then begin SetFltV(@L.Stack[base + A], vb^.N - vc^.I); begin Result := pc; Exit; end; end;
        end;
        ArithGeneric(L, cidx, base, kk, ins, pc);
      end;
      OP_MUL: begin
        vb := GetRK(L, base, kk, B);
        vc := GetRK(L, base, kk, C);
        if vb^.Vt = vtInt then
        begin
          if vc^.Vt = vtInt then begin SetIntV(@L.Stack[base + A], Int64(QWord(vb^.I) * QWord(vc^.I))); begin Result := pc; Exit; end; end;
          if vc^.Vt = vtFlt then begin SetFltV(@L.Stack[base + A], vb^.I * vc^.N); begin Result := pc; Exit; end; end;
        end
        else if vb^.Vt = vtFlt then
        begin
          if vc^.Vt = vtFlt then begin SetFltV(@L.Stack[base + A], vb^.N * vc^.N); begin Result := pc; Exit; end; end;
          if vc^.Vt = vtInt then begin SetFltV(@L.Stack[base + A], vb^.N * vc^.I); begin Result := pc; Exit; end; end;
        end;
        ArithGeneric(L, cidx, base, kk, ins, pc);
      end;
      OP_DIV: begin
        vb := GetRK(L, base, kk, B);
        vc := GetRK(L, base, kk, C);
        if (vb^.Vt = vtFlt) and (vc^.Vt = vtFlt) then
        begin
          SetFltV(@L.Stack[base + A], vb^.N / vc^.N);
          begin Result := pc; Exit; end;
        end;
        ArithGeneric(L, cidx, base, kk, ins, pc);
      end;
      OP_MOD: begin
        vb := GetRK(L, base, kk, B);
        vc := GetRK(L, base, kk, C);
        if (vb^.Vt = vtInt) and (vc^.Vt = vtInt) and (vc^.I > 0) then
        begin
          // positive modulus: the result takes the sign of the divisor
          step := vb^.I mod vc^.I;
          if step < 0 then step := step + vc^.I;
          SetIntV(@L.Stack[base + A], step);
          begin Result := pc; Exit; end;
        end;
        ArithGeneric(L, cidx, base, kk, ins, pc);
      end;
      OP_IDIV: begin
        vb := GetRK(L, base, kk, B);
        vc := GetRK(L, base, kk, C);
        if (vb^.Vt = vtInt) and (vc^.Vt = vtInt) and (vc^.I > 0) then
        begin
          step := vb^.I div vc^.I;
          if (vb^.I mod vc^.I) < 0 then Dec(step);
          SetIntV(@L.Stack[base + A], step);
          begin Result := pc; Exit; end;
        end;
        ArithGeneric(L, cidx, base, kk, ins, pc);
      end;
      OP_POW, OP_BAND, OP_BOR, OP_BXOR, OP_SHL, OP_SHR: begin
        vb := GetRK(L, base, kk, B);
        vc := GetRK(L, base, kk, C);
        if (vb^.Vt = vtInt) and (vc^.Vt = vtInt) and (ins^.Op in [OP_BAND, OP_BOR, OP_BXOR]) then
        begin
          case ins^.Op of
            OP_BAND: SetIntV(@L.Stack[base + A], vb^.I and vc^.I);
            OP_BOR: SetIntV(@L.Stack[base + A], vb^.I or vc^.I);
          else
            SetIntV(@L.Stack[base + A], vb^.I xor vc^.I);
          end;
          begin Result := pc; Exit; end;
        end;
        ArithGeneric(L, cidx, base, kk, ins, pc);
      end;
      OP_UNM: begin
        vb := @L.Stack[base + B];
        if vb^.Vt = vtInt then SetIntV(@L.Stack[base + A], Int64(QWord(0) - QWord(vb^.I)))
        else if vb^.Vt = vtFlt then SetFltV(@L.Stack[base + A], -vb^.N)
        else
        begin
          ci^.SavedPC := pc;
          v := vb^;
          res := ArithSlow(L, OP_UNM, v, v, okReg, B, okReg, B);
          L.Stack[base + A] := res;
        end;
      end;
      OP_BNOT: begin
        vb := @L.Stack[base + B];
        if vb^.Vt = vtInt then SetIntV(@L.Stack[base + A], not vb^.I)
        else
        begin
          ci^.SavedPC := pc;
          v := vb^;
          res := ArithSlow(L, OP_BNOT, v, v, okReg, B, okReg, B);
          L.Stack[base + A] := res;
        end;
      end;
      OP_NOT: SetBoolV(@L.Stack[base + A], IsFalse(L.Stack[base + B]));
      OP_LEN: begin
        vb := @L.Stack[base + B];
        if vb^.Vt = vtStr then
          SetIntV(@L.Stack[base + A], vb^.S.Len)
        else if (vb^.Vt = vtTab) and (vb^.T.Metatable = nil) then
          SetIntV(@L.Stack[base + A], TableLength(vb^.T))
        else
        begin
          ci^.SavedPC := pc;
          v := vb^;
          if (v.Vt <> vtTab) and (GetTM(L, v, TM_LEN).Vt = vtNil) then
            TypeError(L, v, 'get length of', okReg, B);
          res := LuaLen(L, v);
          L.Stack[base + A] := res;
        end;
      end;
      OP_CONCAT: begin
        ci^.SavedPC := pc;
        ConcatRegs(L, base + B, C);
        L.Stack[base + A] := L.Stack[base + B];
        if L.Main.TotalBytes >= L.Main.GCThreshold then
        begin
          if A > B then L.GCLimit := base + A + 1 else L.GCLimit := base + B + 1;
          GCCheck(L, cidx);
          L.GCLimit := 0;
        end;
      end;
      OP_JMP: pc := A;
      OP_JT: begin
        vb := @L.Stack[base + A];
        if (vb^.Vt <> vtNil) and ((vb^.Vt <> vtBool) or (vb^.B)) then pc := B;
      end;
      OP_JF: begin
        vb := @L.Stack[base + A];
        if (vb^.Vt = vtNil) or ((vb^.Vt = vtBool) and (not vb^.B)) then pc := B;
      end;
      OP_EQ: begin
        vb := GetRK(L, base, kk, B);
        vc := GetRK(L, base, kk, C);
        if vb^.Vt <> vc^.Vt then
        begin
          // different types are equal only for int/float with the same value
          if ((vb^.Vt = vtInt) and (vc^.Vt = vtFlt)) or ((vb^.Vt = vtFlt) and (vc^.Vt = vtInt)) then
          begin
            ci^.SavedPC := pc;
            cond := LuaEquals(L, vb^, vc^);
          end
          else cond := False;
        end
        else case vb^.Vt of
          vtNil: cond := True;
          vtBool: cond := vb^.B = vc^.B;
          vtInt: cond := vb^.I = vc^.I;
          vtFlt: cond := vb^.N = vc^.N;
          vtStr: begin
            if vb^.S = vc^.S then cond := True
            else if vb^.S.IsShort and vc^.S.IsShort then cond := False
            else cond := vb^.S.Eq(vc^.S);
          end;
          vtTab, vtUser: begin
            if vb^.T = vc^.T then cond := True
            else
            begin
              ci^.SavedPC := pc;
              v := vb^;
              key := vc^;
              cond := LuaEquals(L, v, key);
            end;
          end;
        else
          cond := LuaEquals(L, vb^, vc^);
        end;
        if cond = (A <> 0) then pc := code[pc].A else Inc(pc);
      end;
      OP_LT: begin
        vb := GetRK(L, base, kk, B);
        vc := GetRK(L, base, kk, C);
        if (vb^.Vt = vtInt) and (vc^.Vt = vtInt) then cond := vb^.I < vc^.I
        else if (vb^.Vt = vtFlt) and (vc^.Vt = vtFlt) then cond := vb^.N < vc^.N
        else
        begin
          ci^.SavedPC := pc;
          v := vb^;
          key := vc^;
          cond := LuaLessThan(L, v, key);
        end;
        if cond = (A <> 0) then pc := code[pc].A else Inc(pc);
      end;
      OP_LE: begin
        vb := GetRK(L, base, kk, B);
        vc := GetRK(L, base, kk, C);
        if (vb^.Vt = vtInt) and (vc^.Vt = vtInt) then cond := vb^.I <= vc^.I
        else if (vb^.Vt = vtFlt) and (vc^.Vt = vtFlt) then cond := vb^.N <= vc^.N
        else
        begin
          ci^.SavedPC := pc;
          v := vb^;
          key := vc^;
          cond := LuaLessEqual(L, v, key);
        end;
        if cond = (A <> 0) then pc := code[pc].A else Inc(pc);
      end;
      OP_TAILCALL: begin
        ci^.SavedPC := pc;
        funcIdx := base + A;
        if B <> 0 then
        begin
          nargs := B - 1;
          L.Top := funcIdx + 1 + nargs;
        end
        else
          nargs := L.Top - funcIdx - 1;
        if L.Stack[funcIdx].Vt <> vtFunc then TryFuncTM(L, funcIdx, nargs);
        nf := L.Stack[funcIdx].F;
        if nf.IsC then
        begin
          // C functions are called normally; their results are returned
          DoCall(L, funcIdx, nargs, -1);
          n := L.Top - funcIdx;
          first := funcIdx;
          nres := ci^.NResults;
          if (L.OpenUpvals <> nil) and (L.OpenUpvals.Idx >= base) then CloseUpvals(L, base);
          PostCall(L, ci^.FuncIdx, first, n, nres);
          if ci^.Fresh then begin Result := EXEC_EXIT; Exit; end;
          LastRetNres := nres;
          Dec(L.NCI);
          Result := EXEC_RETURNED;
          Exit;
        end;
        // Lua function: reuse the frame
        CloseUpvals(L, base);
        if (L.NTbc > 0) and (L.TbcList[L.NTbc - 1] >= base) then CloseTbcUpTo(L, base);
        nres := ci^.NResults;
        funcIdx := funcIdx;
        n := ci^.FuncIdx;
        // move function and arguments down to the frame's function slot
        for i := 0 to nargs do
          L.Stack[n + i] := L.Stack[funcIdx + i];
        L.Top := n + 1 + nargs;
        // replace the frame
        SetupLuaFrame(L, nf, n, nargs, first, nextra);
        L.Top := first + nf.Proto.MaxStackSize;
        ci^.Func := nf;
        ci^.Base := first;
        ci^.Top := L.Top;
        ci^.NExtra := nextra;
        ci^.IsTail := True;
        ci^.ExtraArgs := PendingExtra;
        PendingExtra := 0;
        ci^.SavedPC := 0;
        Result := EXEC_RELOAD;
        Exit;
      end;
      OP_RETURN: begin
        ci^.SavedPC := pc;
        first := base + A;
        if B <> 0 then n := B - 1 else n := L.Top - first;
        if ((L.OpenUpvals <> nil) and (L.OpenUpvals.Idx >= base)) or
           ((L.NTbc > 0) and (L.TbcList[L.NTbc - 1] >= base)) then
        begin
          L.Top := first + n;
          CloseUpvals(L, base);
          if (L.NTbc > 0) and (L.TbcList[L.NTbc - 1] >= base) then
          begin
            // the values being returned must survive the closing calls
            CloseTbcUpTo(L, base);
          end;
          base := ci^.Base;
          first := base + A;
        end;
        if L.HookMask <> 0 then
        begin
          L.Top := first + n;
          if (L.HookMask and HOOK_RET) <> 0 then
            CallHookTransfer(L, 'return', first - ci^.Base + 1, n);
          base := ci^.Base;
          first := base + A;
        end;
        PostCall(L, ci^.FuncIdx, first, n, ci^.NResults);
        if L.HookMask <> 0 then
        begin
          // the caller continues after its call instruction
          if cidx > 0 then L.OldLine := L.CI[cidx - 1].SavedPC - 1;
        end;
        if ci^.Fresh then begin Result := EXEC_EXIT; Exit; end;
        // return into the calling Lua frame (same loop)
        LastRetNres := ci^.NResults;
        Dec(L.NCI);
        Result := EXEC_RETURNED;
        Exit;
      end;
      OP_VARARG: begin
        ci^.SavedPC := pc;
        nres := C - 1;
        if B <> 0 then
        begin
          // named vararg parameter: the values come from its table
          tmp := L.Stack[base + B - 1];
          tbl := tmp.T;
          n := VarargTableCount(L, tbl);
          if nres < 0 then
          begin
            L.EnsureStack(base + A + n + LUA_MINSTACK);
            for i := 1 to n do L.Stack[base + A + i - 1] := TableGetInt(tbl, i);
            L.Top := base + A + n;
          end
          else
            for i := 1 to nres do
              if i <= n then L.Stack[base + A + i - 1] := TableGetInt(tbl, i)
              else L.Stack[base + A + i - 1].Vt := vtNil;
        end
        else
        begin
          n := nextra;
          if nres < 0 then
          begin
            L.EnsureStack(base + A + n + LUA_MINSTACK);
            for i := 0 to n - 1 do L.Stack[base + A + i] := L.Stack[base - nextra + i];
            L.Top := base + A + n;
          end
          else
            for i := 0 to nres - 1 do
              if i < n then L.Stack[base + A + i] := L.Stack[base - nextra + i]
              else L.Stack[base + A + i].Vt := vtNil;
        end;
      end;
      OP_CLOSURE: begin
        ci^.SavedPC := pc;
        np := p.Protos[B];
        nf := L.Main.NewLuaFunction(np);
        for i := 0 to Length(np.UpvalDescs) - 1 do
          if np.UpvalDescs[i].InStack then
            nf.Upvals[i] := FindUpval(L, base + np.UpvalDescs[i].Idx)
          else
            nf.Upvals[i] := f.Upvals[np.UpvalDescs[i].Idx];
        L.Stack[base + A] := LuaFunc(nf);
        L.GCLimit := base + A + 1;   // closures are created in the topmost register
        GCCheck(L, cidx);
        L.GCLimit := 0;
      end;
      OP_SETLIST: begin
        ci^.SavedPC := pc;
        tbl := L.Stack[base + A].T;
        if B = 0 then n := L.Top - (base + A + 1) else n := B;
        if C + n > tbl.ASize then
          TableResize(tbl, C + n, tbl.NSize);
        for i := 1 to n do
          TableSetInt(tbl, C + i, L.Stack[base + A + i]);
        L.Top := ci^.Top;
      end;
      OP_CLOSE: begin
        ci^.SavedPC := pc;
        CloseUpvals(L, base + A);
        if (L.NTbc > 0) and (L.TbcList[L.NTbc - 1] >= base + A) then
        begin
          L.Top := ci^.Top;
          CloseTbcUpTo(L, base + A);
          base := ci^.Base;
        end;
      end;
      OP_TBC: begin
        ci^.SavedPC := pc;
        RegisterTbc(L, base + A);
      end;
      OP_FORPREP: begin
        ci^.SavedPC := pc;
        if ForPrep(L, base + A) then pc := B;
      end;
      OP_FORLOOP: begin
        vb := @L.Stack[base + A];
        vc := vb + 1;
        vt := vb + 2;
        if vc^.Vt = vtInt then
        begin
          cnt := QWord(vb^.I);
          if cnt > 0 then
          begin
            SetIntV(vb, Int64(cnt - 1));
            SetIntV(vt, Int64(QWord(vt^.I) + QWord(vc^.I)));
            pc := B;
          end;
        end
        else
        begin
          fidx := vt^.N + vc^.N;
          if vc^.N > 0 then cond := fidx <= vb^.N else cond := vb^.N <= fidx;
          if cond then
          begin
            SetFltV(vt, fidx);
            pc := B;
          end;
        end;
      end;
      OP_TFORPREP: begin
        ci^.SavedPC := pc;
        ra := base + A;
        tmp := L.Stack[ra + 3];
        L.Stack[ra + 3] := L.Stack[ra + 2];
        L.Stack[ra + 2] := tmp;
        RegisterTbc(L, ra + 2);
        pc := B;
      end;
      OP_TFORCALL: begin
        ci^.SavedPC := pc;
        ra := base + A;
        L.Stack[ra + 5] := L.Stack[ra + 3];
        L.Stack[ra + 4] := L.Stack[ra + 1];
        L.Stack[ra + 3] := L.Stack[ra];
        L.Top := ra + 6;
        DoCall(L, ra + 3, 2, C);
        L.Top := ci^.Top;
        base := ci^.Base;
      end;
      OP_TFORLOOP: begin
        if L.Stack[base + A + 3].Vt <> vtNil then pc := B;
      end;
      OP_ERRNNIL: begin
        ci^.SavedPC := pc;
        if L.Stack[base + A].Vt <> vtNil then
        begin
          GlobalDefinedError(L, kk[B]);
        end;
      end;
      OP_GETVARG: begin
        ci^.SavedPC := pc;
        key := GetRK(L, base, kk, C)^;
        L.Stack[base + A].Vt := vtNil;
        if key.Vt = vtFlt then
          if FloatToInt(key.N, step, F2I_EQ) then key := LuaInt(step);
        if key.Vt = vtInt then
        begin
          if (key.I >= 1) and (key.I <= nextra) then
            L.Stack[base + A] := L.Stack[base - nextra + Integer(key.I) - 1];
        end
        else if (key.Vt = vtStr) and (key.S.Len = 1) and (key.S.Str[1] = 'n') then
          L.Stack[base + A] := LuaInt(nextra);
      end;
      OP_NOP: ;
    end;
  Result := pc;
end;

// The interpreter loop. It keeps only the hot opcodes (with their fast paths) and
// the frame switching of Lua-to-Lua calls; everything else is done by ExecOther.
procedure VMExecute(L: TLua);
var
  ci: PCallInfo;
  f: TFunction;
  p: TProto;
  code, ins, ip: PInstruction;
  kk, vb, vc, vt, tv: PLuaValue;
  np: TProto;
  base, nres, nargs, funcIdx, n, first, i, retNres, r: Integer;
  nf: TFunction;
  cnt: QWord;
  step: Int64;
  fidx: Double;
  cond, returning: Boolean;
begin
  returning := False;
  retNres := 0;
  while True do
  begin
    // (re)load the frame on top of the call stack
    ci := @L.CI[L.NCI - 1];
    f := ci^.Func;
    p := f.Proto;
    code := @p.Code[0];
    if Length(p.K) > 0 then kk := @p.K[0] else kk := nil;
    base := ci^.Base;
    if returning then
    begin
      // a Lua callee returned to this frame: continue after its call instruction
      returning := False;
      ip := code + ci^.SavedPC;
      if retNres >= 0 then L.Top := ci^.Top;
    end
    else
    begin
      ip := code;
      if L.HookMask <> 0 then
      begin
        if (L.HookMask and HOOK_CALL) <> 0 then
        begin
          ci^.SavedPC := 0;
          if ci^.IsTail then CallHookTransfer(L, 'tail call', 1, p.NumParams)
          else CallHookTransfer(L, 'call', 1, p.NumParams);
        end;
        L.OldLine := 0;
      end;
    end;
    while True do
    begin
      if L.HookMask <> 0 then
      begin
        ci^.SavedPC := (ip - code) + 1;
        TraceExec(L, p, ip - code);
      end;
      ins := ip;
      Inc(ip);
      case ins^.Op of
        OP_MOVE: CopyVal(@L.Stack[base + ins^.A], @L.Stack[base + ins^.B]);
        OP_LOADK: CopyVal(@L.Stack[base + ins^.A], @kk[ins^.B]);
        OP_LOADNIL: for i := 0 to ins^.B do L.Stack[base + ins^.A + i].Vt := vtNil;
        OP_LOADBOOL: SetBoolV(@L.Stack[base + ins^.A], ins^.B <> 0);
        OP_GETUPVAL: CopyVal(@L.Stack[base + ins^.A], f.Upvals[ins^.B].Ref);
        OP_SETUPVAL: CopyVal(f.Upvals[ins^.B].Ref, @L.Stack[base + ins^.A]);
        OP_GETTABUP: begin
          vb := f.Upvals[ins^.B].Ref;
          vc := GetRK(L, base, kk, ins^.C);
          vt := nil;
          if (vb^.Vt = vtTab) and (vc^.Vt = vtStr) then vt := IndexStrFast(vb^.T, vc^.S);
          if vt <> nil then CopyVal(@L.Stack[base + ins^.A], vt)
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_GETTABLE: begin
          vb := @L.Stack[base + ins^.B];
          vc := GetRK(L, base, kk, ins^.C);
          vt := nil;
          if vb^.Vt = vtTab then
          begin
            if vc^.Vt = vtStr then vt := IndexStrFast(vb^.T, vc^.S)
            else
            begin
              if vc^.Vt = vtInt then vt := TableGetIntP(vb^.T, vc^.I) else vt := TableGetP(vb^.T, vc^);
              if (vt^.Vt = vtNil) and (vb^.T.Metatable <> nil) then vt := nil;
            end;
          end;
          if vt <> nil then CopyVal(@L.Stack[base + ins^.A], vt)
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_SETTABLE: begin
          vb := @L.Stack[base + ins^.A];
          vc := GetRK(L, base, kk, ins^.B);
          vt := GetRK(L, base, kk, ins^.C);
          if (vb^.Vt = vtTab) and (vc^.Vt = vtStr) and NoNewIndex(vb^.T) then
            TableSetStr(vb^.T, vc^.S, vt^)
          else if (vb^.Vt = vtTab) and (vc^.Vt = vtInt) and NoNewIndex(vb^.T) then
            TableSetInt(vb^.T, vc^.I, vt^)
          else
            ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_SELF: begin
          vb := @L.Stack[base + ins^.B];
          vc := GetRK(L, base, kk, ins^.C);
          vt := nil;
          if vc^.Vt = vtStr then
          begin
            if vb^.Vt = vtTab then vt := IndexStrFast(vb^.T, vc^.S)
            else if (vb^.Vt = vtStr) and (L.Main.MetaStr <> nil) then
            begin
              // method call on a string: look in the table behind the string metatable
              tv := TableGetStrP(L.Main.MetaStr, TMName(TM_INDEX));
              if tv^.Vt = vtTab then vt := IndexStrFast(tv^.T, vc^.S);
            end;
          end;
          if vt <> nil then
          begin
            CopyVal(@L.Stack[base + ins^.A + 1], vb);
            CopyVal(@L.Stack[base + ins^.A], vt);
          end
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_ADD: begin
          vb := GetRK(L, base, kk, ins^.B);
          vc := GetRK(L, base, kk, ins^.C);
          if vb^.Vt = vtInt then
          begin
            if vc^.Vt = vtInt then SetIntV(@L.Stack[base + ins^.A], Int64(QWord(vb^.I) + QWord(vc^.I)))
            else if vc^.Vt = vtFlt then SetFltV(@L.Stack[base + ins^.A], vb^.I + vc^.N)
            else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
          end
          else if vb^.Vt = vtFlt then
          begin
            if vc^.Vt = vtFlt then SetFltV(@L.Stack[base + ins^.A], vb^.N + vc^.N)
            else if vc^.Vt = vtInt then SetFltV(@L.Stack[base + ins^.A], vb^.N + vc^.I)
            else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
          end
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_SUB: begin
          vb := GetRK(L, base, kk, ins^.B);
          vc := GetRK(L, base, kk, ins^.C);
          if vb^.Vt = vtInt then
          begin
            if vc^.Vt = vtInt then SetIntV(@L.Stack[base + ins^.A], Int64(QWord(vb^.I) - QWord(vc^.I)))
            else if vc^.Vt = vtFlt then SetFltV(@L.Stack[base + ins^.A], vb^.I - vc^.N)
            else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
          end
          else if vb^.Vt = vtFlt then
          begin
            if vc^.Vt = vtFlt then SetFltV(@L.Stack[base + ins^.A], vb^.N - vc^.N)
            else if vc^.Vt = vtInt then SetFltV(@L.Stack[base + ins^.A], vb^.N - vc^.I)
            else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
          end
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_MUL: begin
          vb := GetRK(L, base, kk, ins^.B);
          vc := GetRK(L, base, kk, ins^.C);
          if vb^.Vt = vtInt then
          begin
            if vc^.Vt = vtInt then SetIntV(@L.Stack[base + ins^.A], Int64(QWord(vb^.I) * QWord(vc^.I)))
            else if vc^.Vt = vtFlt then SetFltV(@L.Stack[base + ins^.A], vb^.I * vc^.N)
            else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
          end
          else if vb^.Vt = vtFlt then
          begin
            if vc^.Vt = vtFlt then SetFltV(@L.Stack[base + ins^.A], vb^.N * vc^.N)
            else if vc^.Vt = vtInt then SetFltV(@L.Stack[base + ins^.A], vb^.N * vc^.I)
            else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
          end
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_DIV: begin
          vb := GetRK(L, base, kk, ins^.B);
          vc := GetRK(L, base, kk, ins^.C);
          if (vb^.Vt = vtFlt) and (vc^.Vt = vtFlt) then SetFltV(@L.Stack[base + ins^.A], vb^.N / vc^.N)
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_MOD: begin
          vb := GetRK(L, base, kk, ins^.B);
          vc := GetRK(L, base, kk, ins^.C);
          if (vb^.Vt = vtInt) and (vc^.Vt = vtInt) and (vc^.I > 0) then
          begin
            // positive modulus: the result takes the sign of the divisor
            step := vb^.I mod vc^.I;
            if step < 0 then step := step + vc^.I;
            SetIntV(@L.Stack[base + ins^.A], step);
          end
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_IDIV: begin
          vb := GetRK(L, base, kk, ins^.B);
          vc := GetRK(L, base, kk, ins^.C);
          if (vb^.Vt = vtInt) and (vc^.Vt = vtInt) and (vc^.I > 0) then
          begin
            step := vb^.I div vc^.I;
            if (vb^.I mod vc^.I) < 0 then Dec(step);
            SetIntV(@L.Stack[base + ins^.A], step);
          end
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_UNM: begin
          vb := @L.Stack[base + ins^.B];
          if vb^.Vt = vtInt then SetIntV(@L.Stack[base + ins^.A], Int64(QWord(0) - QWord(vb^.I)))
          else if vb^.Vt = vtFlt then SetFltV(@L.Stack[base + ins^.A], -vb^.N)
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_NOT: SetBoolV(@L.Stack[base + ins^.A], IsFalse(L.Stack[base + ins^.B]));
        OP_LEN: begin
          vb := @L.Stack[base + ins^.B];
          if vb^.Vt = vtStr then SetIntV(@L.Stack[base + ins^.A], vb^.S.Len)
          else if (vb^.Vt = vtTab) and (vb^.T.Metatable = nil) then
            SetIntV(@L.Stack[base + ins^.A], TableLength(vb^.T))
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_JMP: ip := code + ins^.A;
        OP_JT: begin
          vb := @L.Stack[base + ins^.A];
          if (vb^.Vt <> vtNil) and ((vb^.Vt <> vtBool) or (vb^.B)) then ip := code + ins^.B;
        end;
        OP_JF: begin
          vb := @L.Stack[base + ins^.A];
          if (vb^.Vt = vtNil) or ((vb^.Vt = vtBool) and (not vb^.B)) then ip := code + ins^.B;
        end;
        OP_EQ: begin
          vb := GetRK(L, base, kk, ins^.B);
          vc := GetRK(L, base, kk, ins^.C);
          if vb^.Vt <> vc^.Vt then
          begin
            if ((vb^.Vt = vtInt) and (vc^.Vt = vtFlt)) or ((vb^.Vt = vtFlt) and (vc^.Vt = vtInt)) then
              ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1)
            else if (ins^.A <> 0) then Inc(ip)
            else ip := code + ip^.A;
          end
          else
          begin
            case vb^.Vt of
              vtNil: cond := True;
              vtBool: cond := vb^.B = vc^.B;
              vtInt: cond := vb^.I = vc^.I;
              vtFlt: cond := vb^.N = vc^.N;
              vtStr: cond := (vb^.S = vc^.S) or ((not (vb^.S.IsShort and vc^.S.IsShort)) and vb^.S.Eq(vc^.S));
              vtFunc, vtThread, vtLight: cond := vb^.T = vc^.T;
            else
              cond := vb^.T = vc^.T;
              if not cond then
              begin
                // tables and userdata of different identity may still have __eq
                ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
                continue;
              end;
            end;
            if cond = (ins^.A <> 0) then ip := code + ip^.A else Inc(ip);
          end;
        end;
        OP_LT: begin
          vb := GetRK(L, base, kk, ins^.B);
          vc := GetRK(L, base, kk, ins^.C);
          if (vb^.Vt = vtInt) and (vc^.Vt = vtInt) then
          begin
            if (vb^.I < vc^.I) = (ins^.A <> 0) then ip := code + ip^.A else Inc(ip);
          end
          else if (vb^.Vt = vtFlt) and (vc^.Vt = vtFlt) then
          begin
            if (vb^.N < vc^.N) = (ins^.A <> 0) then ip := code + ip^.A else Inc(ip);
          end
          else if (vb^.Vt = vtStr) and (vc^.Vt = vtStr) then
          begin
            if (StrCompareP(PChar(vb^.S.Data), vb^.S.Len, PChar(vc^.S.Data), vc^.S.Len) < 0) = (ins^.A <> 0) then
              ip := code + ip^.A
            else Inc(ip);
          end
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_LE: begin
          vb := GetRK(L, base, kk, ins^.B);
          vc := GetRK(L, base, kk, ins^.C);
          if (vb^.Vt = vtInt) and (vc^.Vt = vtInt) then
          begin
            if (vb^.I <= vc^.I) = (ins^.A <> 0) then ip := code + ip^.A else Inc(ip);
          end
          else if (vb^.Vt = vtFlt) and (vc^.Vt = vtFlt) then
          begin
            if (vb^.N <= vc^.N) = (ins^.A <> 0) then ip := code + ip^.A else Inc(ip);
          end
          else if (vb^.Vt = vtStr) and (vc^.Vt = vtStr) then
          begin
            if (StrCompareP(PChar(vb^.S.Data), vb^.S.Len, PChar(vc^.S.Data), vc^.S.Len) <= 0) = (ins^.A <> 0) then
              ip := code + ip^.A
            else Inc(ip);
          end
          else ip := code + ExecOther(L, ci, f, kk, base, (ip - code) - 1);
        end;
        OP_FORLOOP: begin
          vb := @L.Stack[base + ins^.A];
          vc := vb + 1;
          vt := vb + 2;
          if vc^.Vt = vtInt then
          begin
            cnt := QWord(vb^.I);
            if cnt > 0 then
            begin
              SetIntV(vb, Int64(cnt - 1));
              SetIntV(vt, Int64(QWord(vt^.I) + QWord(vc^.I)));
              ip := code + ins^.B;
            end;
          end
          else
          begin
            fidx := vt^.N + vc^.N;
            if vc^.N > 0 then cond := fidx <= vb^.N else cond := vb^.N <= fidx;
            if cond then
            begin
              SetFltV(vt, fidx);
              ip := code + ins^.B;
            end;
          end;
        end;
        OP_TFORLOOP: begin
          if L.Stack[base + ins^.A + 3].Vt <> vtNil then ip := code + ins^.B;
        end;
        OP_TFORCALL: begin
          ci^.SavedPC := ip - code;
          funcIdx := base + ins^.A;
          CopyVal(@L.Stack[funcIdx + 5], @L.Stack[funcIdx + 3]);
          CopyVal(@L.Stack[funcIdx + 4], @L.Stack[funcIdx + 1]);
          CopyVal(@L.Stack[funcIdx + 3], @L.Stack[funcIdx]);
          L.Top := funcIdx + 6;
          funcIdx := funcIdx + 3;
          nargs := 2;
          if L.Stack[funcIdx].Vt <> vtFunc then TryFuncTM(L, funcIdx, nargs);
          nf := L.Stack[funcIdx].F;
          if not nf.IsC then
          begin
            // Lua iterator: a new frame in this loop
            EnterLuaFrame(L, nf, funcIdx, nargs, ins^.C);
            Break;
          end;
          CallC(L, nf, funcIdx, nargs, ins^.C);
          L.Top := ci^.Top;
        end;
        OP_NEWTABLE: begin
          ci^.SavedPC := ip - code;
          vt := @L.Stack[base + ins^.A];
          vt^.T := L.Main.NewTable(ins^.B, ins^.C);
          vt^.Vt := vtTab;
          if L.Main.TotalBytes >= L.Main.GCThreshold then
          begin
            // the new table is the topmost live register: everything above is dead
            L.GCLimit := base + ins^.A + 1;
            GCCheck(L, L.NCI - 1);
            L.GCLimit := 0;
          end;
        end;
        OP_CALL, OP_TAILCALL: begin
          ci^.SavedPC := ip - code;
          funcIdx := base + ins^.A;
          if ins^.B <> 0 then
          begin
            nargs := ins^.B - 1;
            L.Top := funcIdx + 1 + nargs;
          end
          else
            nargs := L.Top - funcIdx - 1;
          nres := ins^.C - 1;
          if L.Stack[funcIdx].Vt <> vtFunc then
          begin
            if ins^.Op = OP_TAILCALL then
              nf := nil   // a callable object: ExecOther takes care of it
            else
            begin
              TryFuncTM(L, funcIdx, nargs);
              nf := L.Stack[funcIdx].F;
            end;
          end
          else
            nf := L.Stack[funcIdx].F;
          if (ins^.Op = OP_TAILCALL) and ((nf = nil) or (not nf.IsC)) then
          begin
            // tail call of a Lua function: the current frame is replaced
            if nf <> nil then
            begin
              np := nf.Proto;
              n := ci^.FuncIdx + 1 + np.MaxStackSize;
            end;
            if (nf <> nil) and (not np.IsVararg) and (L.HookMask = 0) and (StackSlack = 0) and
               ((L.OpenUpvals = nil) or (L.OpenUpvals.Idx < base)) and
               ((L.NTbc = 0) or (L.TbcList[L.NTbc - 1] < base)) and
               (n + np.NumParams + nargs + LUA_MINSTACK + 2 <= L.StackSize) and
               (n + np.NumParams + nargs + LUA_MINSTACK + 2 <= MAXSTACK) then
            begin
              first := ci^.FuncIdx;
              for i := 0 to nargs do CopyVal(@L.Stack[first + i], @L.Stack[funcIdx + i]);
              for i := nargs to np.NumParams - 1 do L.Stack[first + 1 + i].Vt := vtNil;
              L.Top := n;
              ci^.Func := nf;
              ci^.Base := first + 1;
              ci^.Top := n;
              ci^.NExtra := 0;
              ci^.IsTail := True;
              ci^.SavedPC := 0;
              ci^.ExtraArgs := PendingExtra;
              PendingExtra := 0;
              f := nf;
              p := np;
              code := @p.Code[0];
              if Length(p.K) > 0 then kk := @p.K[0] else kk := nil;
              base := first + 1;
              ip := code;
              continue;
            end;
            // the general case (upvalues to close, hooks, vararg callee, __call...)
            r := ExecOther(L, ci, f, kk, base, (ip - code) - 1);
            case r of
              EXEC_EXIT: Exit;
              EXEC_RELOAD: begin returning := False; Break; end;
            else
              begin returning := True; retNres := LastRetNres; Break; end;
            end;
          end
          else if not nf.IsC then
          begin
            // Lua to Lua call: a new frame in this same loop, no native recursion
            np := nf.Proto;
            n := funcIdx + 1 + np.MaxStackSize;
            if (not np.IsVararg) and (L.HookMask = 0) and (StackSlack = 0) and
               (L.NCI < ThreadMaxCI(L)) and
               (n + np.NumParams + nargs + LUA_MINSTACK + 2 <= L.StackSize) and
               (n + np.NumParams + nargs + LUA_MINSTACK + 2 <= MAXSTACK) then
            begin
              // fast path: switch to the new frame right here
              for i := nargs to np.NumParams - 1 do L.Stack[funcIdx + 1 + i].Vt := vtNil;
              L.Top := n;
              Inc(ci);
              ci^.Func := nf;
              ci^.FuncIdx := funcIdx;
              ci^.Base := funcIdx + 1;
              ci^.Top := n;
              ci^.SavedPC := 0;
              ci^.NResults := nres;
              ci^.NExtra := 0;
              ci^.IsC := False;
              ci^.IsTail := False;
              ci^.Hooked := False;
              ci^.Fresh := False;
              ci^.InFinalizer := False;
              ci^.FTransfer := 0;
              ci^.NTransfer := 0;
              ci^.ExtraArgs := PendingExtra;
              PendingExtra := 0;
              Inc(L.NCI);
              f := nf;
              p := np;
              code := @p.Code[0];
              if Length(p.K) > 0 then kk := @p.K[0] else kk := nil;
              base := funcIdx + 1;
              ip := code;
              continue;
            end;
            EnterLuaFrame(L, nf, funcIdx, nargs, nres);
            Break;
          end;
          CallC(L, nf, funcIdx, nargs, nres);
          if nres >= 0 then L.Top := ci^.Top;
          if L.Main.TotalBytes >= L.Main.GCThreshold then
          begin
            // after a call with fixed results only the registers up to the last result are live
            if nres > 0 then L.GCLimit := base + ins^.A + nres;
            GCCheck(L, L.NCI - 1);
            L.GCLimit := 0;
          end;
        end;
        OP_RETURN: begin
          if ((L.OpenUpvals <> nil) and (L.OpenUpvals.Idx >= base)) or
             ((L.NTbc > 0) and (L.TbcList[L.NTbc - 1] >= base)) or (L.HookMask <> 0) then
          begin
            r := ExecOther(L, ci, f, kk, base, (ip - code) - 1);
            case r of
              EXEC_EXIT: Exit;
              EXEC_RELOAD: begin returning := False; Break; end;
              EXEC_RETURNED: begin returning := True; retNres := LastRetNres; Break; end;
            else
              ip := code + r;
            end;
          end
          else
          begin
            first := base + ins^.A;
            if ins^.B <> 0 then n := ins^.B - 1 else n := L.Top - first;
            nres := ci^.NResults;
            funcIdx := ci^.FuncIdx;
            if nres = 1 then
            begin
              // the most common case: one result
              if n > 0 then CopyVal(@L.Stack[funcIdx], @L.Stack[first])
              else L.Stack[funcIdx].Vt := vtNil;
              L.Top := funcIdx + 1;
            end
            else PostCall(L, funcIdx, first, n, nres);
            if ci^.Fresh then Exit;
            // return into the calling Lua frame (same loop)
            retNres := nres;
            Dec(L.NCI);
            if L.HookMask = 0 then
            begin
              Dec(ci);
              f := ci^.Func;
              p := f.Proto;
              code := @p.Code[0];
              if Length(p.K) > 0 then kk := @p.K[0] else kk := nil;
              base := ci^.Base;
              ip := code + ci^.SavedPC;
              if nres >= 0 then L.Top := ci^.Top;
            end
            else
            begin
              returning := True;
              Break;
            end;
          end;
        end;
      else
        begin
          r := ExecOther(L, ci, f, kk, base, (ip - code) - 1);
          if r >= 0 then ip := code + r
          else case r of
            EXEC_EXIT: Exit;
            EXEC_RELOAD: begin returning := False; Break; end;
          else
            begin returning := True; retNres := LastRetNres; Break; end;
          end;
        end;
      end;
    end;
  end;
end;

{ ===================================================================== }
{ protected calls, finalizers                                            }
{ ===================================================================== }

// runs the message handler for error value 'ev'; returns the final value
function RunHandler(L: TLua; handlerIdx: Integer; ev: TLuaValue; var status: Integer): TLuaValue;
var
  idx, top, nested: Integer;
begin
  nested := 0;   // C levels used by handlers that failed (each failure calls the handler again)
  try
    while True do
    begin
      if L.NCcalls >= MAXCCALLS + 20 then
      begin
        status := 2;
        Exit(LuaStr(L.NewString('error in error handling')));
      end;
      if L.NCcalls = MAXCCALLS then
        ev := LuaStr(L.NewString('C stack overflow'));
      top := L.Top;
      if (L.NCI > 0) and (top < L.CI[L.NCI - 1].Top) then top := L.CI[L.NCI - 1].Top;
      L.Top := top;
      idx := L.Top;
      L.EnsureStack(idx + 5);
      L.Stack[idx] := L.Stack[handlerIdx];
      L.Stack[idx + 1] := ev;
      L.Top := idx + 2;
      try
        Inc(L.NCcalls);
        Inc(L.NNY);
        StackSlack := 900;
        try
          DoCall(L, idx, 1, 1);
        finally
          StackSlack := 0;
          Dec(L.NNY);
          Dec(L.NCcalls);
        end;
        Exit(L.Stack[idx]);
      except
        on E: ELuaError do
        begin
          ev := ErrorValueOf(L, E);
          Inc(L.NCcalls);
          Inc(nested);
        end;
      end;
    end;
  finally
    Dec(L.NCcalls, nested);
  end;
end;

function LuaProtectedCall(L: TLua; nargs, nresults, errfunc: Integer): Integer;
var
  funcIdx, oldNCI, oldNNY, oldCc, oldHook, errTop: Integer;
  oldInHook: Boolean;
  ev: TLuaValue;
begin
  funcIdx := L.Top - nargs - 1;
  oldNCI := L.NCI;
  oldNNY := L.NNY;
  oldCc := L.NCcalls;
  oldInHook := L.InHook;
  oldHook := 0;
  if oldHook <> 0 then ;
  try
    IncCCalls(L);
    DoCall(L, funcIdx, nargs, nresults);
    Dec(L.NCcalls);
    Result := 0;
  except
    on E: ELuaError do
    begin
      Result := 1;
      ev := ErrorValueOf(L, E);
      if ev.Vt = vtNil then
        ev := LuaStr(L.NewString('<no error object>'));
      errTop := L.Top;
      if (L.NCI > 0) and (L.CI[L.NCI - 1].Top > errTop) then errTop := L.CI[L.NCI - 1].Top;
      if errfunc <> 0 then
        ev := RunHandler(L, errfunc, ev, Result);
      // unwind (the stack above funcIdx stays intact while closing variables)
      L.NCI := oldNCI;
      L.NNY := oldNNY;
      L.NCcalls := oldCc;
      L.InHook := oldInHook;
      L.Top := errTop;
      CloseThreadVars(L, funcIdx, ev, True);
      L.NCI := oldNCI;
      L.NNY := oldNNY;
      L.NCcalls := oldCc;
      L.Stack[funcIdx] := ev;
      L.Top := funcIdx + 1;
    end;
  end;
end;

procedure CallFinalizer(L: TLua; constref obj: TLuaValue);
var
  tm: TLuaValue;
  idx, top, st, savedTop: Integer;
begin
  tm := GetTM(L, obj, TM_GC);
  if tm.Vt <> vtFunc then Exit;
  savedTop := L.Top;   // an open call may be using the stack up to Top
  top := L.Top;
  if (L.NCI > 0) and (top < L.CI[L.NCI - 1].Top) then top := L.CI[L.NCI - 1].Top;
  L.Top := top;
  idx := L.Top;
  L.EnsureStack(idx + 5);
  L.Stack[idx] := tm;
  L.Stack[idx + 1] := obj;
  L.Top := idx + 2;
  if L.NCI > 0 then L.CI[L.NCI - 1].InFinalizer := True;
  try
    st := LuaProtectedCall(L, 1, 0, 0);
  finally
    if L.NCI > 0 then L.CI[L.NCI - 1].InFinalizer := False;
  end;
  if st <> 0 then
  begin
    // errors in finalizers are only warnings
    if L.Main.WarnProc <> nil then
    begin
      L.Main.WarnProc(L, 'error in ', True);
      L.Main.WarnProc(L, '__gc', True);
      L.Main.WarnProc(L, ' (', True);
      if L.Stack[idx].Vt = vtStr then L.Main.WarnProc(L, L.Stack[idx].S.Str, True)
      else L.Main.WarnProc(L, 'error object is not a string', True);
      L.Main.WarnProc(L, ')', False);
    end;
    L.Top := idx;
  end;
  L.Top := savedTop;
end;

procedure LuaClose(L: TLua);
var
  m: TLua;
  err: TLuaValue;
  o: TGCObject;
  i: Integer;
begin
  m := L.Main;
  m.CurThread := m;
  m.NCI := 0;
  m.NCcalls := 0;
  m.NNY := 0;
  err.Vt := vtNil;
  CloseThreadVars(m, 0, err, False);
  m.InGC := True;
  m.Closing := True;   // objects marked for finalization from now on are never finalized
  try
    // all objects with finalizers become pending, newest first; a nested close
    // (os.exit inside a finalizer) continues with what is still pending
    for i := m.NFinObjs - 1 downto 0 do
    begin
      o := m.FinObjs[i];
      o.FinState := 0;
      if m.NToFinalize >= Length(m.ToFinalize) then
        SetLength(m.ToFinalize, Length(m.ToFinalize) * 2 + 16);
      m.ToFinalize[m.NToFinalize] := o;
      Inc(m.NToFinalize);
    end;
    m.NFinObjs := 0;
    while m.NToFinalize > 0 do
    begin
      o := m.ToFinalize[0];
      Move(m.ToFinalize[1], m.ToFinalize[0], (m.NToFinalize - 1) * SizeOf(TGCObject));
      Dec(m.NToFinalize);
      if o.ObjType = OBJ_TAB then CallFinalizer(m, LuaTab(TTable(o)))
      else if o.ObjType = OBJ_USER then CallFinalizer(m, LuaUser(TUserdata(o)));
    end;
  finally
    m.InGC := False;
  end;
end;

procedure FinalizerBridge(L: TLua; constref obj: TLuaValue);
begin
  CallFinalizer(TLua(L.Main.CurThread), obj);
end;

procedure LuaInitVM(L: TLua);
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);
  L.CurThread := L;
  L.FinalizerProc := @FinalizerBridge;
end;

end.
