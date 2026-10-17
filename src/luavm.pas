unit luavm;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, luacore, luaparse;

procedure LuaInitVM(L: TLua);
procedure LuaPush(L: TThread; const v: TLuaValue);
function LuaGetTop(L: TThread): Integer;
function LuaArg(L: TThread; i: Integer): TLuaValue;
function LuaAbsIndex(L: TThread; i: Integer): Integer;
procedure LuaSetTop(L: TThread; n: Integer);
procedure LuaError(L: TLua; const msg: string);
procedure LuaErrorFmt(L: TLua; const msg: string; const args: array of const);
procedure LuaRuntimeError(L: TLua; const msg: string);
function LuaTypeName(L: TThread; i: Integer): string;
procedure LuaCall(L: TThread; nargs, nresults: Integer);
function LuaProtectedCall(L: TThread; nargs, nresults, errfunc: Integer): Integer;
function LuaResume(L: TThread; co: TThread; nargs: Integer): Integer;
procedure LuaYield(L: TThread; nresults: Integer);
procedure CallFinalizer(L: TLua; f: TFunction; obj: TLuaValue);
function GetMM(L: TLua; const v: TLuaValue; const name: string): TFunction;

implementation

type
  ELuaYield = class(Exception)
  end;

// ---------------- error helpers ----------------

procedure LuaError(L: TLua; const msg: string);
begin
  raise ELuaError.CreateMsg(msg);
end;

procedure LuaErrorFmt(L: TLua; const msg: string; const args: array of const);
begin
  raise ELuaError.CreateMsg(Format(msg, args));
end;

function SrcName(th: TThread): string;
var
  ci: TCallInfo;
  p: TProto;
  i: Integer;
begin
  for i := th.NCI - 1 downto 0 do
  begin
    ci := th.CI[i];
    if (not ci.IsC) and (ci.Func <> nil) and (ci.Func.Proto <> nil) then
    begin
      p := ci.Func.Proto;
      if p.Source <> nil then
      begin
        Result := p.Source.ToStr;
        if (Length(Result) > 0) and (Result[1] = '=') then
          Delete(Result, 1, 1);
        Exit;
      end;
    end;
  end;
  Result := '?';
end;

function CurLine(th: TThread): Integer;
var
  ci: TCallInfo;
  p: TProto;
  pc: Integer;
  i: Integer;
begin
  for i := th.NCI - 1 downto 0 do
  begin
    ci := th.CI[i];
    if (not ci.IsC) and (ci.Func <> nil) and (ci.Func.Proto <> nil) then
    begin
      p := ci.Func.Proto;
      pc := ci.SavedPC - 1;
      if (pc >= 0) and (pc < Length(p.LineInfo)) then
        Exit(p.LineInfo[pc]);
    end;
  end;
  Result := 0;
end;

function VarInfoSuffix(th: TThread; reg: Integer): string;
var
  ci: TCallInfo;
  p: TProto;
  pc, r: Integer;
  ins: TInstruction;
  kind, name: string;
begin
  Result := '';
  if th.NCI <= 0 then Exit;
  ci := th.CI[th.NCI - 1];
  if ci.IsC or (ci.Func = nil) or (ci.Func.Proto = nil) then Exit;
  p := ci.Func.Proto;
  pc := ci.SavedPC;
  r := reg;
  while pc > 0 do
  begin
    ins := p.Code[pc - 1];
    if (ins.Op = OP_MOVE) and (ins.A = r) then
    begin
      r := ins.B;
      Dec(pc);
      continue;
    end;
    if ((ins.Op = OP_GETFIELD) or (ins.Op = OP_GETTABUP)) and (ins.A = r) then
    begin
      if ins.Op = OP_GETTABUP then kind := 'global' else kind := 'field';
      if (ins.C >= 0) and (ins.C < Length(p.K)) and (p.K[ins.C].Vt = vtStr) then
        name := p.K[ins.C].S.ToStr
      else
        name := '?';
      Exit(Format(' (%s ''%s'')', [kind, name]));
    end;
    Break;
  end;
end;

procedure VMError(th: TThread; const msg: string);
begin
  raise ELuaError.CreateMsg(Format('%s:%d: %s', [SrcName(th), CurLine(th), msg]));
end;

procedure LuaRuntimeError(L: TLua; const msg: string);
begin
  VMError(L.CurThread, msg);
end;

procedure VMErrorVar(th: TThread; reg: Integer; const msg: string);
begin
  VMError(th, msg + VarInfoSuffix(th, reg));
end;

// ---------------- upvalues ----------------

function FindOpenUpval(L: TThread; idx: Integer): TUpval;
var
  u: TUpval;
begin
  u := L.OpenUpvals;
  while u <> nil do
  begin
    if (u.Open <> nil) and (u.StackIdx = idx) then
      Exit(u);
    u := u.Next;
  end;
  u := TUpval.Create;
  u.Open := @L.Stack[idx];
  u.StackIdx := idx;
  u.Tbc := False;
  u.Next := L.OpenUpvals;
  L.OpenUpvals := u;
  Result := u;
end;

procedure MarkTbc(L: TThread; idx: Integer);
var
  u: TUpval;
begin
  u := FindOpenUpval(L, idx);
  u.Tbc := True;
end;

function GetCloseMM(const v: TLuaValue): TFunction;
var
  mt: TTable;
  mm: TLuaValue;
begin
  case v.Vt of
    vtTab: mt := v.T.Metatable;
    vtUser: mt := v.U.Metatable;
  else
    Exit(nil);
  end;
  if mt = nil then
    Exit(nil);
  mm := TableGetStr(mt, StaticStr('__close'));
  if mm.Vt = vtFunc then
    Result := mm.F
  else
    Result := nil;
end;

procedure CloseUpvals(L: TThread; idx: Integer);
var
  u, prev, next: TUpval;
  mm: TFunction;
  val: TLuaValue;
begin
  prev := nil;
  u := L.OpenUpvals;
  while u <> nil do
  begin
    next := u.Next;
    if (u.Open <> nil) and (u.StackIdx >= idx) then
    begin
      if u.Tbc and not IsNil(u.Open^) then
      begin
        val := u.Open^;
        u.Open^ := LuaNil;
        u.V := LuaNil;
        u.Open := nil;
        if prev = nil then L.OpenUpvals := next else prev.Next := next;
        u.NextClosed := L.ClosedUpvals;
        L.ClosedUpvals := u;
        mm := GetCloseMM(val);
        if mm <> nil then
        begin
          LuaPush(L, val);
          LuaCall(L, 1, 0);
        end;
      end
      else
      begin
        u.V := u.Open^;
        u.Open := nil;
        if prev = nil then L.OpenUpvals := next else prev.Next := next;
        u.NextClosed := L.ClosedUpvals;
        L.ClosedUpvals := u;
      end;
      u := next;
      continue;
    end;
    prev := u;
    u := next;
  end;
end;

// ---------------- metatables ----------------

function GetMetatable(const v: TLuaValue): TTable;
begin
  case v.Vt of
    vtTab: Result := v.T.Metatable;
    vtUser: Result := v.U.Metatable;
  else
    Result := nil;
  end;
end;

function GetMM(L: TLua; const v: TLuaValue; const name: string): TFunction;
var
  mt: TTable;
  mm: TLuaValue;
begin
  mt := GetMetatable(v);
  if (mt = nil) and (v.Vt = vtStr) and (L <> nil) then
    mt := L.MetaStr;
  if mt = nil then Exit(nil);
  mm := TableGetStr(mt, StaticStr(name));
  if mm.Vt = vtFunc then Result := mm.F else Result := nil;
end;

// ---------------- call helpers ----------------

procedure PushCI(L: TThread; f: TFunction; base: Integer; isC: Boolean);
var
  ci: TCallInfo;
begin
  if L.NCI >= Length(L.CI) then
    SetLength(L.CI, Length(L.CI) * 2);
  ci.Func := f;
  ci.Base := base;
  ci.Top := L.Top;
  ci.SavedPC := 0;
  ci.NResults := 0;
  ci.CallStatus := 0;
  ci.PrevCI := L.NCI - 1;
  ci.IsC := isC;
  L.CI[L.NCI] := ci;
  Inc(L.NCI);
end;

procedure ClearTable(t: TTable);
var
  i: Integer;
begin
  for i := 0 to Length(t.Arr) - 1 do
    t.Arr[i] := LuaNil;
  for i := 0 to Length(t.Bucket) - 1 do
    t.Bucket[i] := -1;
  for i := 0 to Length(t.Node) - 1 do
  begin
    t.Node[i].Key := LuaNil;
    t.Node[i].Val := LuaNil;
    t.Node[i].Next := i + 1;
  end;
  if Length(t.Node) > 0 then
  begin
    t.Node[Length(t.Node) - 1].Next := -1;
    t.LastFree := 0;
  end;
end;

function CallMeta2(L: TThread; mm: TFunction; const a, b: TLuaValue): TLuaValue;
begin
  LuaPush(L, LuaFunc(mm));
  LuaPush(L, a);
  LuaPush(L, b);
  LuaCall(L, 3, 1);
  Result := L.Stack[L.Top - 1];
end;

function CallMeta1(L: TThread; mm: TFunction; const a: TLuaValue): TLuaValue;
begin
  LuaPush(L, LuaFunc(mm));
  LuaPush(L, a);
  LuaCall(L, 2, 1);
  Result := L.Stack[L.Top - 1];
end;

procedure VMExecute(L: TThread); forward;

// Call function f with nargs args at [Top-nargs..Top-1].
// Results placed at resultBase (nresults = -1 for all).
procedure DoCall(L: TThread; f: TFunction; nargs, nresults, resultBase, argsBase: Integer);
var
  base, i, nres, n: Integer;
  vtab: TTable;
  p: TProto;
begin
  if L.NCI >= 20000 then
    VMError(L, 'stack overflow');
  base := argsBase;
  if f.IsC then
  begin
    PushCI(L, f, base, True);
    L.Main.CurThread := L;
    L.Top := base + nargs;
    try
      nres := f.CProc(L.Main);
    except
      on E: ELuaYield do
      begin
        Dec(L.NCI);
        raise;
      end;
      on E: ELuaError do
      begin
        Dec(L.NCI);
        raise;
      end;
    end;
    Dec(L.NCI);
    if nresults < 0 then
    begin
      n := nres;
      for i := 0 to n - 1 do
        L.Stack[resultBase + i] := L.Stack[base + i];
      L.Top := resultBase + n;
    end
    else
    begin
      for i := 0 to nresults - 1 do
      begin
        if i < nres then
          L.Stack[resultBase + i] := L.Stack[base + i]
        else
          L.Stack[resultBase + i] := LuaNil;
      end;
      L.Top := resultBase + nresults;
    end;
  end
  else
  begin
    p := f.Proto;
    L.EnsureStack(base + p.MaxStackSize + 10);
    PushCI(L, f, base, False);
    L.CI[L.NCI - 1].NResults := nresults;
    for i := nargs to p.NumParams - 1 do
      L.Stack[base + i] := LuaNil;
    if p.IsVararg then
    begin
      vtab := f.VarArgTable;
      if vtab = nil then
      begin
        vtab := L.Main.NewTable(0, 0);
        f.VarArgTable := vtab;
      end;
      if GetEnvironmentVariable('LUA_TRACE') <> '' then
        WriteLn(ErrOutput, 'DoCall vararg: preset=', f.VarArgPreset, ' vtab=', PtrUInt(vtab), ' [1]=', VTypeName(TableGetInt(vtab, 1)));
      if not f.VarArgPreset then
        ClearTable(vtab);
      n := 0;
      if GetEnvironmentVariable('LUA_TRACE') <> '' then
        WriteLn(ErrOutput, 'DoCall vararg: nargs=', nargs, ' NumParams=', p.NumParams, ' base=', base);
      for i := p.NumParams to nargs - 1 do
      begin
        Inc(n);
        TableSetInt(vtab, n, L.Stack[base + i]);
        if GetEnvironmentVariable('LUA_TRACE') <> '' then
          WriteLn(ErrOutput, '  var[', n, ']=', VTypeName(L.Stack[base + i]));
      end;
      TableSetStr(vtab, L.Main.NewString('n'), LuaInt(n));
      L.Stack[base + p.NumParams] := LuaTab(vtab);
    end;
    if L.Top < base + p.MaxStackSize then
      L.Top := base + p.MaxStackSize;
    L.CI[L.NCI - 1].Top := L.Top;
    VMExecute(L);
    Dec(L.NCI);
    if nresults < 0 then
    begin
      n := L.Top - base;
      for i := 0 to n - 1 do
        L.Stack[resultBase + i] := L.Stack[base + i];
      L.Top := resultBase + n;
    end
    else
    begin
      n := L.Top - base;
      if n > nresults then n := nresults;
      for i := 0 to nresults - 1 do
      begin
        if i < n then
          L.Stack[resultBase + i] := L.Stack[base + i]
        else
          L.Stack[resultBase + i] := LuaNil;
      end;
      L.Top := resultBase + nresults;
    end;
  end;
end;

// ---------------- numbers ----------------

function VToNum(const v: TLuaValue): Double;
begin
  if v.Vt = vtInt then Result := Double(v.I) else Result := v.N;
end;

function LuaVToNumber(L: TThread; const v: TLuaValue; var isInt: Boolean; var iv: Int64; var nv: Double): Boolean;
begin
  case v.Vt of
    vtInt: begin isInt := True; iv := v.I; nv := Double(v.I); Exit(True); end;
    vtFlt: begin isInt := False; nv := v.N; Exit(True); end;
    vtStr: begin
      if StrToIntVal(v.S.ToStr, iv) then begin isInt := True; nv := Double(iv); Exit(True); end;
      if StrToNumVal(v.S.ToStr, nv) then begin isInt := False; Exit(True); end;
      Exit(False);
    end;
  end;
  Result := False;
end;

function Arith(L: TThread; op: Byte; const a, b: TLuaValue): TLuaValue; forward;

function TryIntegral(n: Double; var i: Int64; var isInt: Boolean): Boolean;
begin
  if isInt then
    Exit(True);
  if FloatToInt(n, i, 0) then
  begin
    isInt := True;
    Result := True;
  end
  else
    Result := False;
end;

function Arith(L: TThread; op: Byte; const a, b: TLuaValue): TLuaValue;
var
  na, nb, rn: Double;
  ia, ib, ir: Int64;
  aInt, bInt: Boolean;
  i: Integer;
  mmName: string;
  mm: TFunction;
begin
  if not LuaVToNumber(L, a, aInt, ia, na) then
  begin
    case op of
      OP_ADD: mmName := '__add'; OP_SUB: mmName := '__sub';
      OP_MUL: mmName := '__mul'; OP_DIV: mmName := '__div';
      OP_IDIV: mmName := '__idiv'; OP_MOD: mmName := '__mod';
      OP_POW: mmName := '__pow'; OP_BAND: mmName := '__band';
      OP_BOR: mmName := '__bor'; OP_BXOR: mmName := '__bxor';
      OP_SHL: mmName := '__shl'; OP_SHR: mmName := '__shr';
    end;
    mm := GetMM(L.Main, a, mmName);
    if mm = nil then
      VMErrorVar(L, -1, Format('attempt to perform arithmetic on a %s value', [VTypeName(a)]));
    Result := CallMeta2(L, mm, a, b);
    Exit;
  end;
  if not LuaVToNumber(L, b, bInt, ib, nb) then
  begin
    case op of
      OP_ADD: mmName := '__add'; OP_SUB: mmName := '__sub';
      OP_MUL: mmName := '__mul'; OP_DIV: mmName := '__div';
      OP_IDIV: mmName := '__idiv'; OP_MOD: mmName := '__mod';
      OP_POW: mmName := '__pow'; OP_BAND: mmName := '__band';
      OP_BOR: mmName := '__bor'; OP_BXOR: mmName := '__bxor';
      OP_SHL: mmName := '__shl'; OP_SHR: mmName := '__shr';
    end;
    mm := GetMM(L.Main, b, mmName);
    if mm = nil then
      VMErrorVar(L, -1, Format('attempt to perform arithmetic on a %s value', [VTypeName(b)]));
    Result := CallMeta2(L, mm, a, b);
    Exit;
  end;
  case op of
    OP_ADD: if aInt and bInt then begin
        if (ib > 0) and (ia > LUA_MAXINTEGER - ib) then Result := LuaNum(na + nb)
        else if (ib < 0) and (ia < LUA_MININTEGER - ib) then Result := LuaNum(na + nb)
        else Result := LuaInt(ia + ib);
      end else Result := LuaNum(na + nb);
    OP_SUB: if aInt and bInt then begin
        if (ib < 0) and (ia > LUA_MAXINTEGER + ib) then Result := LuaNum(na - nb)
        else if (ib > 0) and (ia < LUA_MININTEGER + ib) then Result := LuaNum(na - nb)
        else Result := LuaInt(ia - ib);
      end else Result := LuaNum(na - nb);
    OP_MUL: if aInt and bInt then begin
        if (ia = 0) or (ib = 0) then Result := LuaInt(0)
        else begin
          rn := na * nb;
          if (rn > LUA_MAXINTEGER) or (rn < LUA_MININTEGER) then Result := LuaNum(rn)
          else Result := LuaInt(ia * ib);
        end;
      end else Result := LuaNum(na * nb);
    OP_DIV: Result := LuaNum(na / nb);
    OP_IDIV: begin
      if aInt and bInt then begin
        if ib = 0 then VMError(L, 'attempt to divide by zero');
        ir := ia div ib;
        if ((ia mod ib) <> 0) and (((ia < 0) <> (ib < 0))) then Dec(ir);
        Result := LuaInt(ir);
      end else begin
        if nb = 0 then VMError(L, 'attempt to divide by zero');
        rn := Floor(na / nb);
        if FloatToInt(rn, ir, 0) then Result := LuaInt(ir) else Result := LuaNum(rn);
        if GetEnvironmentVariable('LUA_TRACE') <> '' then
          WriteLn(ErrOutput, 'IDIV: na=', na, ' nb=', nb, ' rn=', rn, ' ir=', ir);
      end;
    end;
    OP_MOD: begin
      if aInt and bInt then begin
        if ib = 0 then VMError(L, 'attempt to perform ''n%%0''');
        ir := ia mod ib;
        if (ir <> 0) and (((ir < 0) <> (ib < 0))) then ir := ir + ib;
        Result := LuaInt(ir);
      end else begin
        if nb = 0 then VMError(L, 'attempt to perform ''n%%0''');
        rn := na - Floor(na / nb) * nb;
        Result := LuaNum(rn);
      end;
    end;
    OP_POW: begin
      if aInt and bInt and (nb >= 0) and (nb <= 62) then
      begin
        // integer power with overflow check
        ir := 1;
        try
          for i := 1 to Trunc(nb) do
            ir := ir * ia;
          Result := LuaInt(ir);
        except
          on E: Exception do
          begin
            // overflow: fall back to float
            rn := Exp(nb * Ln(Abs(na)));
            if (na < 0) and ((Trunc(nb) mod 2) <> 0) then rn := -rn;
            Result := LuaNum(rn);
          end;
        end;
      end
      else if na < 0 then
      begin
        if (Frac(nb) = 0) and (abs(nb) <= 100) then
        begin
          try
            rn := Exp(nb * Ln(-na));
          except
            rn := Infinity;
          end;
          if (Trunc(nb) mod 2) <> 0 then rn := -rn;
        end
        else if nb > 0 then
          rn := Infinity
        else if nb < 0 then
          rn := 0
        else
          rn := NaN;
        Result := LuaNum(rn);
      end
      else if na = 0 then
      begin
        if nb < 0 then rn := Infinity
        else if nb = 0 then rn := 1
        else rn := 0;
        Result := LuaNum(rn);
      end
      else
      begin
        try
          rn := Exp(nb * Ln(na));
        except
          rn := Infinity;
        end;
        if IsInfinite(rn) then
          Result := LuaNum(rn)
        else if FloatToInt(rn, ir, 0) and (abs(rn - ir) < 1e-9) then
          Result := LuaInt(ir)
        else
          Result := LuaNum(rn);
      end;
    end;
    OP_BAND: begin
      TryIntegral(na, ia, aInt);
      TryIntegral(nb, ib, bInt);
      if not (aInt and bInt) then begin
        mm := GetMM(L.Main, a, '__band');
        if mm = nil then mm := GetMM(L.Main, b, '__band');
        if mm = nil then VMError(L, 'number has no integer representation');
        Result := CallMeta2(L, mm, a, b);
      end else Result := LuaInt(ia and ib);
    end;
    OP_BOR: begin
      TryIntegral(na, ia, aInt);
      TryIntegral(nb, ib, bInt);
      if not (aInt and bInt) then begin
        mm := GetMM(L.Main, a, '__bor');
        if mm = nil then mm := GetMM(L.Main, b, '__bor');
        if mm = nil then VMError(L, 'number has no integer representation');
        Result := CallMeta2(L, mm, a, b);
      end else Result := LuaInt(ia or ib);
    end;
    OP_BXOR: begin
      TryIntegral(na, ia, aInt);
      TryIntegral(nb, ib, bInt);
      if not (aInt and bInt) then begin
        mm := GetMM(L.Main, a, '__bxor');
        if mm = nil then mm := GetMM(L.Main, b, '__bxor');
        if mm = nil then VMError(L, 'number has no integer representation');
        Result := CallMeta2(L, mm, a, b);
      end else Result := LuaInt(ia xor ib);
    end;
    OP_SHL: begin
      TryIntegral(na, ia, aInt);
      TryIntegral(nb, ib, bInt);
      if not (aInt and bInt) then begin
        mm := GetMM(L.Main, a, '__shl');
        if mm = nil then mm := GetMM(L.Main, b, '__shl');
        if mm = nil then VMError(L, 'number has no integer representation');
        Result := CallMeta2(L, mm, a, b);
      end
      else begin
        if ib < 0 then
        begin
          if -ib >= 64 then begin
            if ia < 0 then Result := LuaInt(-1) else Result := LuaInt(0);
          end else
            Result := LuaInt(SarInt64(ia, -ib));
        end
        else if ib >= 64 then Result := LuaInt(0) else Result := LuaInt(ia shl ib);
      end;
    end;
    OP_SHR: begin
      TryIntegral(na, ia, aInt);
      TryIntegral(nb, ib, bInt);
      if not (aInt and bInt) then begin
        mm := GetMM(L.Main, a, '__shr');
        if mm = nil then mm := GetMM(L.Main, b, '__shr');
        if mm = nil then VMError(L, 'number has no integer representation');
        Result := CallMeta2(L, mm, a, b);
      end
      else begin
        if ib < 0 then
        begin
          if -ib >= 64 then Result := LuaInt(0) else Result := LuaInt(ia shl (-ib));
        end
        else if ib >= 64 then begin
          if ia < 0 then Result := LuaInt(-1) else Result := LuaInt(0);
        end else
          Result := LuaInt(SarInt64(ia, ib));
      end;
    end;
  end;
end;

// ---------------- table access ----------------

function TableGetMM(L: TThread; const t, key: TLuaValue; errReg: Integer): TLuaValue;
var
  mt: TTable;
  idx: TLuaValue;
begin
  mt := GetMetatable(t);
  if (mt = nil) and (t.Vt = vtStr) and (L.Main <> nil) then
    mt := L.Main.MetaStr;
  if mt = nil then
    VMErrorVar(L, errReg, Format('attempt to index a %s value', [VTypeName(t)]));
  idx := TableGetStr(mt, StaticStr('__index'));
  if idx.Vt = vtFunc then
    Result := CallMeta2(L, idx.F, t, key)
  else if idx.Vt = vtTab then
    Result := TableGet(idx.T, key)
  else
  begin
    VMErrorVar(L, errReg, Format('attempt to index a %s value', [VTypeName(t)]));
    Result := LuaNil;
  end;
end;

function GetTable(L: TThread; const t, key: TLuaValue; errReg: Integer): TLuaValue;
var
  v: TLuaValue;
begin
  case t.Vt of
    vtTab: begin
      v := TableGet(t.T, key);
      if IsNil(v) then
      begin
        if t.T.Metatable <> nil then
        begin
          Result := TableGetMM(L.Main, t, key, errReg);
          Exit;
        end;
      end;
      Result := v;
    end;
    vtUser: Result := TableGetMM(L.Main, t, key, errReg);
    vtStr: begin
      Result := LuaNil;
      if L.Main.MetaStr <> nil then
        Result := TableGetMM(L.Main, t, key, errReg);
    end;
  else
    VMErrorVar(L, errReg, Format('attempt to index a %s value', [VTypeName(t)]));
    Result := LuaNil;
  end;
end;

procedure SetTableMM(L: TThread; const t, key, val: TLuaValue);
var
  mm: TFunction;
begin
  mm := GetMM(L.Main, t, '__newindex');
  if mm = nil then
    VMError(L, Format('attempt to index a %s value', [VTypeName(t)]));
  LuaPush(L, LuaFunc(mm));
  LuaPush(L, t);
  LuaPush(L, key);
  LuaPush(L, val);
  LuaCall(L, 4, 0);
end;

procedure SetTable(L: TThread; const t, key, val: TLuaValue);
var
  cur: TLuaValue;
begin
  case t.Vt of
    vtTab: begin
      if key.Vt = vtNil then
        VMError(L, 'table index is nil');
      cur := TableGet(t.T, key);
      if (not IsNil(cur)) or (t.T.Metatable = nil) then
        TableSet(t.T, key, val)
      else
        SetTableMM(L, t, key, val);
    end;
    vtUser: SetTableMM(L, t, key, val);
  else
    VMError(L, Format('attempt to index a %s value', [VTypeName(t)]));
  end;
end;

// ---------------- comparisons ----------------

function ObjEquals(L: TThread; const a, b: TLuaValue): Boolean;
var
  mm: TFunction;
  r: TLuaValue;
begin
  if RawEqual(a, b) then
    Exit(True);
  if ((a.Vt = vtTab) or (a.Vt = vtUser)) and ((b.Vt = vtTab) or (b.Vt = vtUser)) then
  begin
    mm := GetMM(L.Main, a, '__eq');
    if (mm <> nil) and (mm = GetMM(L.Main, b, '__eq')) then
    begin
      r := CallMeta2(L, mm, a, b);
      Exit(Truthy(r));
    end;
  end;
  Result := False;
end;

function ObjLess(L: TThread; const a, b: TLuaValue): Boolean;
var
  mm: TFunction;
  r: TLuaValue;
  na, nb: Double;
begin
  if ((a.Vt = vtInt) or (a.Vt = vtFlt)) and ((b.Vt = vtInt) or (b.Vt = vtFlt)) then
  begin
    if (a.Vt = vtInt) and (b.Vt = vtInt) then Exit(a.I < b.I);
    na := VToNum(a);
    nb := VToNum(b);
    Exit(na < nb);
  end;
  if (a.Vt = vtStr) and (b.Vt = vtStr) then
    Exit(a.S.ToStr < b.S.ToStr);
  mm := GetMM(L.Main, a, '__lt');
  if mm <> nil then
  begin
    r := CallMeta2(L, mm, a, b);
    Exit(Truthy(r));
  end;
  mm := GetMM(L.Main, b, '__lt');
  if mm <> nil then
  begin
    r := CallMeta2(L, mm, b, a);
    Exit(not Truthy(r));
  end;
  VMError(L, Format('attempt to compare two %s values', [VTypeName(a)]));
  Result := False;
end;

function ObjLessEq(L: TThread; const a, b: TLuaValue): Boolean;
var
  mm: TFunction;
  r: TLuaValue;
begin
  if ((a.Vt = vtInt) or (a.Vt = vtFlt)) and ((b.Vt = vtInt) or (b.Vt = vtFlt)) then
  begin
    if (a.Vt = vtInt) and (b.Vt = vtInt) then Exit(a.I <= b.I);
    Exit(VToNum(a) <= VToNum(b));
  end;
  if (a.Vt = vtStr) and (b.Vt = vtStr) then
    Exit(a.S.ToStr <= b.S.ToStr);
  if ObjLess(L, b, a) then
    Exit(False);
  mm := GetMM(L.Main, a, '__le');
  if mm <> nil then
  begin
    r := CallMeta2(L, mm, a, b);
    Exit(Truthy(r));
  end;
  mm := GetMM(L.Main, b, '__le');
  if mm <> nil then
  begin
    r := CallMeta2(L, mm, b, a);
    Exit(not Truthy(r));
  end;
  VMError(L, Format('attempt to compare two %s values', [VTypeName(a)]));
  Result := False;
end;

// ---------------- concat ----------------

function IsStrNum(const v: TLuaValue): Boolean;
begin
  Result := (v.Vt = vtStr) or (v.Vt = vtInt) or (v.Vt = vtFlt);
end;

function ValueToStr(const v: TLuaValue): RawByteString;
begin
  if v.Vt = vtStr then
    Result := v.S.ToStr
  else
    Result := RawByteString(NumToStr(v));
end;

// ---------------- VM ----------------

procedure VMExecute(L: TThread);
var
  base: Integer;
  proto: TProto;
  code: array of TInstruction;
  pc: Integer;
  ins: TInstruction;
  f: TFunction;
  nargs, nres, i, n: Integer;
  v, a2, b2: TLuaValue;
  ci: TCallInfo;
  vtab: TTable;
  sb: RawByteString;
  mm: TFunction;
  cond: Boolean;
  step: Int64;
  cnt, lim: Double;
  nm: string;
  iv: Int64;
  np: TProto;
  nf: TFunction;
  u: TUpval;
begin
  ci := L.CI[L.NCI - 1];
  f := ci.Func;
  proto := f.Proto;
  code := proto.Code;
  base := ci.Base;
  pc := ci.SavedPC;
  while True do
  begin
    ins := code[pc];
    Inc(pc);
    if GetEnvironmentVariable('LUA_TRACE') <> '' then
      if (base = 0) and (L.Stack[1].Vt = vtInt) and (L.Stack[1].I = 7) then
        WriteLn(ErrOutput, 'WATCH Stack1=7 pc=', pc-1, ' op=', ins.Op);
    L.CI[L.NCI - 1].SavedPC := pc;
    case ins.Op of
      OP_MOVE: L.Stack[base + ins.A] := L.Stack[base + ins.B];
      OP_LOADNIL: for i := 0 to ins.B do L.Stack[base + ins.A + i] := LuaNil;
      OP_LOADBOOL: L.Stack[base + ins.A] := LuaBool(ins.B <> 0);
      OP_LOADK: L.Stack[base + ins.A] := proto.K[ins.B];
      OP_GETUPVAL: begin
        if f.Upvals[ins.B].Open <> nil then
          L.Stack[base + ins.A] := f.Upvals[ins.B].Open^
        else
          L.Stack[base + ins.A] := f.Upvals[ins.B].V;
      end;
      OP_SETUPVAL: begin
        if f.Upvals[ins.B].Open <> nil then
          f.Upvals[ins.B].Open^ := L.Stack[base + ins.A]
        else
          f.Upvals[ins.B].V := L.Stack[base + ins.A];
      end;
      OP_GETTABUP: begin
        if f.Upvals[ins.B].Open <> nil then
          v := f.Upvals[ins.B].Open^
        else
          v := f.Upvals[ins.B].V;
        L.Stack[base + ins.A] := GetTable(L, v, proto.K[ins.C], ins.A);
      end;
      OP_SETTABUP: begin
        if f.Upvals[ins.A].Open <> nil then
          v := f.Upvals[ins.A].Open^
        else
          v := f.Upvals[ins.A].V;
        SetTable(L, v, proto.K[ins.B], L.Stack[base + ins.C]);
      end;
      OP_GETTABLE: L.Stack[base + ins.A] := GetTable(L, L.Stack[base + ins.B], L.Stack[base + ins.C], ins.B);
      OP_SETTABLE: SetTable(L, L.Stack[base + ins.A], L.Stack[base + ins.B], L.Stack[base + ins.C]);
      OP_GETFIELD: L.Stack[base + ins.A] := GetTable(L, L.Stack[base + ins.B], proto.K[ins.C], ins.B);
      OP_SETFIELD: SetTable(L, L.Stack[base + ins.A], proto.K[ins.B], L.Stack[base + ins.C]);
      OP_NEWTABLE: L.Stack[base + ins.A] := LuaTab(L.Main.NewTable(ins.B, 0));
      OP_SELF: begin
        L.Stack[base + ins.A + 1] := L.Stack[base + ins.B];
        L.Stack[base + ins.A] := GetTable(L, L.Stack[base + ins.B], proto.K[ins.C], ins.B);
      end;
      OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_IDIV, OP_MOD, OP_POW,
      OP_BAND, OP_BOR, OP_BXOR, OP_SHL, OP_SHR:
        L.Stack[base + ins.A] := Arith(L, ins.Op, L.Stack[base + ins.B], L.Stack[base + ins.C]);
      OP_UNM: begin
        v := L.Stack[base + ins.B];
        case v.Vt of
          vtInt: L.Stack[base + ins.A] := LuaInt(-v.I);
          vtFlt: L.Stack[base + ins.A] := LuaNum(-v.N);
        else begin
          mm := GetMM(L.Main, v, '__unm');
          if mm = nil then
            VMError(L, Format('attempt to perform arithmetic on a %s value', [VTypeName(v)]));
          L.Stack[base + ins.A] := CallMeta1(L, mm, v);
        end;
        end;
      end;
      OP_BNOT: begin
        v := L.Stack[base + ins.B];
        if (v.Vt = vtInt) or ((v.Vt = vtFlt) and FloatToInt(v.N, iv, 0)) then
        begin
          if v.Vt = vtFlt then
            L.Stack[base + ins.A] := LuaInt(not iv)
          else
            L.Stack[base + ins.A] := LuaInt(not v.I);
        end
        else begin
          mm := GetMM(L.Main, v, '__bnot');
          if mm = nil then
            VMError(L, 'number has no integer representation');
          L.Stack[base + ins.A] := CallMeta1(L, mm, v);
        end;
      end;
      OP_NOT: L.Stack[base + ins.A] := LuaBool(IsFalse(L.Stack[base + ins.B]));
      OP_LEN: begin
        v := L.Stack[base + ins.B];
        case v.Vt of
          vtStr: L.Stack[base + ins.A] := LuaInt(v.S.Len);
          vtTab: begin
            mm := GetMM(L.Main, v, '__len');
            if mm <> nil then
              L.Stack[base + ins.A] := CallMeta1(L, mm, v)
            else
              L.Stack[base + ins.A] := LuaInt(TableLength(v.T));
          end;
        else
          VMError(L, Format('attempt to get length of a %s value', [VTypeName(v)]));
        end;
      end;
      OP_CONCAT: begin
        a2 := L.Stack[base + ins.A];
        b2 := L.Stack[base + ins.A + 1];
        if IsStrNum(a2) and IsStrNum(b2) then
        begin
          sb := ValueToStr(a2) + ValueToStr(b2);
          L.Stack[base + ins.A] := LuaStr(L.Main.NewString(sb));
        end
        else
        begin
          mm := GetMM(L.Main, a2, '__concat');
          if mm = nil then mm := GetMM(L.Main, b2, '__concat');
          if mm = nil then
            VMError(L, Format('attempt to concatenate a %s value',
                   [VTypeName(a2)]));
          L.Stack[base + ins.A] := CallMeta2(L, mm, a2, b2);
        end;
      end;
      OP_JMP: pc := ins.A;
      OP_JFALSE: if IsFalse(L.Stack[base + ins.A]) then pc := ins.B;
      OP_JTRUE: if Truthy(L.Stack[base + ins.A]) then pc := ins.B;
      OP_TEST: begin
        if Truthy(L.Stack[base + ins.A]) = (ins.C <> 0) then
          pc := ins.B;
      end;
      OP_TESTSET: begin
        if Truthy(L.Stack[base + ins.A]) = (ins.C <> 0) then
          pc := ins.B
        else
          L.Stack[base + ins.A] := L.Stack[base + ins.B];
      end;
      OP_EQ, OP_LT, OP_LE: begin
        if ins.Op = OP_EQ then cond := ObjEquals(L, L.Stack[base+ins.A], L.Stack[base+ins.B])
        else if ins.Op = OP_LT then cond := ObjLess(L, L.Stack[base+ins.A], L.Stack[base+ins.B])
        else cond := ObjLessEq(L, L.Stack[base+ins.A], L.Stack[base+ins.B]);
        if cond = (ins.C = 0) then
          Inc(pc);
      end;
      OP_LFALSESKIP: begin
        L.Stack[base + ins.A] := LuaBool(False);
        Inc(pc);
      end;
      OP_CALL: begin
        nargs := ins.B - 1;
        if ins.B = 0 then nargs := L.Top - (base + ins.A + 1);
        nres := ins.C - 1;
        if ins.C = 0 then nres := -1;
        v := L.Stack[base + ins.A];
        if v.Vt = vtFunc then
          DoCall(L, v.F, nargs, nres, base + ins.A, base + ins.A + 1)
        else if v.Vt = vtTab then
        begin
          mm := GetMM(L.Main, v, '__call');
          if mm = nil then
            VMError(L, Format('attempt to call a %s value', [VTypeName(v)]));
          // insert function at argsBase-1
          L.Stack[base + ins.A] := LuaFunc(mm);
          DoCall(L, mm, nargs + 1, nres, base + ins.A, base + ins.A);
        end
        else
          VMError(L, Format('attempt to call a %s value', [VTypeName(v)]));
        L.CI[L.NCI - 1].SavedPC := pc;
      end;
      OP_TAILCALL: begin
        nargs := ins.B - 1;
        if ins.B = 0 then nargs := L.Top - (base + ins.A + 1);
        f := L.Stack[base + ins.A].F;
        for i := 0 to nargs - 1 do
          L.Stack[base + i] := L.Stack[base + ins.A + 1 + i];
        L.Top := base + nargs;
        CloseUpvals(L, base);
        Dec(L.NCI);
        DoCall(L, f, nargs, ci.NResults, base, base);
        Exit;
      end;
      OP_RETURN: begin
        n := ins.B - 1;
        if ins.B = 0 then n := L.Top - (base + ins.A);
        if (ci.NResults >= 0) and (n > ci.NResults) then n := ci.NResults;
        for i := 0 to n - 1 do
          L.Stack[base + i] := L.Stack[base + ins.A + i];
        if ci.NResults >= 0 then
        begin
          for i := n to ci.NResults - 1 do
            L.Stack[base + i] := LuaNil;
          L.Top := base + ci.NResults;
        end
        else
          L.Top := base + n;
        CloseUpvals(L, base);
        Exit;
      end;
      OP_VARARG: begin
        vtab := L.Stack[base + proto.NumParams].T;
        if GetEnvironmentVariable('LUA_TRACE') <> '' then
        begin
          WriteLn(ErrOutput, 'OP_VARARG base=', base, ' A=', ins.A, ' B=', ins.B, ' vtab=', PtrUInt(vtab));
          if vtab <> nil then
          begin
            WriteLn(ErrOutput, '  Asize=', vtab.Asize, ' nNode=', Length(vtab.Node), ' LastFree=', vtab.LastFree);
            if vtab.Asize > 0 then
              WriteLn(ErrOutput, '  arr0=', VTypeName(vtab.Arr[0]));
            if Length(vtab.Node) > 0 then
              WriteLn(ErrOutput, '  node0k=', VTypeName(vtab.Node[0].Key), ' node0v=', VTypeName(vtab.Node[0].Val), ' node0next=', vtab.Node[0].Next, ' node1k=', VTypeName(vtab.Node[1].Key), ' node1v=', VTypeName(vtab.Node[1].Val), ' node1next=', vtab.Node[1].Next);
            WriteLn(ErrOutput, '  len=', TableLength(vtab), ' [1]=', VTypeName(TableGetInt(vtab, 1)), ' [2]=', VTypeName(TableGetInt(vtab, 2)));
          end;
        end;
        if ins.B > 0 then
        begin
          for i := 0 to ins.B - 1 do
            L.Stack[base + ins.A + i] := TableGetInt(vtab, i + 1);
          L.Top := base + ins.A + ins.B;
        end
        else
        begin
          n := TableLength(vtab);
          for i := 0 to n - 1 do
            L.Stack[base + ins.A + i] := TableGetInt(vtab, i + 1);
          L.Top := base + ins.A + n;
        end;
      end;
      OP_CLOSURE: begin
        np := proto.Protos[ins.B];
        nf := TFunction.CreateLua(L.Main, np);
        for i := 0 to Length(np.UpvalDescs) - 1 do
        begin
          if np.UpvalDescs[i].InStack then
            u := FindOpenUpval(L, base + np.UpvalDescs[i].Idx)
          else
            u := f.Upvals[np.UpvalDescs[i].Idx];
          nf.Upvals[i] := u;
        end;
        L.Stack[base + ins.A] := LuaFunc(nf);
      end;
      OP_SETLIST: begin
        vtab := L.Stack[base + ins.A].T;
        if ins.B = 0 then
          n := L.Top - (base + ins.A + 1)
        else
          n := ins.B;
        for i := 0 to n - 1 do
          TableSetInt(vtab, ins.C + i, L.Stack[base + ins.A + 1 + i]);
      end;
      OP_CLOSE: CloseUpvals(L, base + ins.A);
      OP_TBC: MarkTbc(L, base + ins.A);
      OP_FORPREP: begin
        v := L.Stack[base + ins.A + 2];
        if v.Vt = vtInt then step := v.I else step := Trunc(v.N);
        v := L.Stack[base + ins.A];
        if v.Vt = vtInt then
          L.Stack[base + ins.A] := LuaInt(v.I - step)
        else
          L.Stack[base + ins.A] := LuaNum(v.N - step);
        pc := ins.B;
      end;
      OP_FORLOOP: begin
        v := L.Stack[base + ins.A + 2];
        if v.Vt = vtInt then step := v.I else step := Trunc(v.N);
        v := L.Stack[base + ins.A];
        if v.Vt = vtInt then
          L.Stack[base + ins.A] := LuaInt(v.I + step)
        else
          L.Stack[base + ins.A] := LuaNum(v.N + step);
        cnt := VToNum(L.Stack[base + ins.A]);
        lim := VToNum(L.Stack[base + ins.A + 1]);
        if step >= 0 then cond := cnt <= lim else cond := cnt >= lim;
        if cond then
        begin
          L.Stack[base + ins.A + 3] := L.Stack[base + ins.A];
          pc := ins.B;
        end;
      end;
      OP_TFORCALL: begin
        nargs := 2;
        nres := ins.C;
        L.EnsureStack(base + ins.A + 6);
        // copy function, state, control to call base A+3 (results overwrite)
        L.Stack[base + ins.A + 3] := L.Stack[base + ins.A];
        L.Stack[base + ins.A + 4] := L.Stack[base + ins.A + 1];
        L.Stack[base + ins.A + 5] := L.Stack[base + ins.A + 2];
        if GetEnvironmentVariable('LUA_TRACE') <> '' then
          WriteLn(ErrOutput, 'TFORCALL ctrlcopy=', L.Stack[base+ins.A+2].I, ' ctrl2=', L.Stack[base+ins.A+5].I);
        DoCall(L, L.Stack[base + ins.A + 3].F, nargs, nres, base + ins.A + 3, base + ins.A + 4);
        if GetEnvironmentVariable('LUA_TRACE') <> '' then
          WriteLn(ErrOutput, 'TFORCALL post A=', ins.A, ' res0vt=', L.Stack[base+ins.A+3].Vt,
            ' res0I=', L.Stack[base+ins.A+3].I, ' ctrlvt=', L.Stack[base+ins.A+2].Vt);
        L.CI[L.NCI - 1].SavedPC := pc;
      end;
      OP_TFORLOOP: begin
        if GetEnvironmentVariable('LUA_TRACE') <> '' then
          WriteLn(ErrOutput, 'TFORLOOP A=', ins.A, ' res0vt=', L.Stack[base+ins.A+3].Vt,
            ' res0I=', L.Stack[base+ins.A+3].I, ' ctrlI=', L.Stack[base+ins.A+2].I, ' B=', ins.B);
        if not IsNil(L.Stack[base + ins.A + 3]) then
        begin
          L.Stack[base + ins.A + 2] := L.Stack[base + ins.A + 3];
          pc := ins.B;
        end;
      end;
      OP_ERRNNIL: begin
        if not IsNil(L.Stack[base + ins.A]) then
        begin
          if (ins.B >= 0) and (ins.B < Length(proto.K)) and (proto.K[ins.B].Vt = vtStr) then
            nm := proto.K[ins.B].S.ToStr
          else
            nm := '?';
          VMError(L, Format('global ''%s'' already defined', [nm]));
        end;
      end;
    end;
  end;
end;

// ---------------- public API ----------------

procedure LuaInitVM(L: TLua);
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);
  L.CurThread := L;
  L.FinalizerProc := @CallFinalizer;
end;

procedure LuaPush(L: TThread; const v: TLuaValue);
begin
  L.PushValue(v);
end;

function LuaGetTop(L: TThread): Integer;
begin
  if L.NCI = 0 then
    Result := L.Top
  else
    Result := L.Top - L.CI[L.NCI - 1].Base;
end;

function LuaAbsIndex(L: TThread; i: Integer): Integer;
var
  base: Integer;
begin
  if L.NCI = 0 then base := 0 else base := L.CI[L.NCI - 1].Base;
  if i > 0 then
    Result := base + i - 1
  else
    Result := L.Top + i;
end;

function LuaArg(L: TThread; i: Integer): TLuaValue;
begin
  Result := L.Stack[LuaAbsIndex(L, i)];
end;

procedure LuaSetTop(L: TThread; n: Integer);
var
  base: Integer;
begin
  if L.NCI = 0 then base := 0 else base := L.CI[L.NCI - 1].Base;
  L.SetTop(base + n);
end;

function LuaTypeName(L: TThread; i: Integer): string;
begin
  Result := VTypeName(LuaArg(L, i));
end;

procedure LuaCall(L: TThread; nargs, nresults: Integer);
var
  f: TFunction;
  resBase: Integer;
begin
  resBase := L.Top - nargs - 1;
  if resBase < 0 then resBase := 0;
  f := L.Stack[resBase].F;
  DoCall(L, f, nargs, nresults, resBase, resBase + 1);
end;

function LuaProtectedCall(L: TThread; nargs, nresults, errfunc: Integer): Integer;
var
  f: TFunction;
  resBase: Integer;
  errmsg: TLuaValue;
begin
  resBase := L.Top - nargs - 1;
  if resBase < 0 then resBase := 0;
  f := L.Stack[resBase].F;
  try
    DoCall(L, f, nargs, nresults, resBase, resBase + 1);
    Result := 0;
  except
    on E: ELuaError do
    begin
      errmsg := LuaStr(L.Main.NewString(RawByteString(E.Message)));
      L.Top := resBase;
      L.PushValue(errmsg);
      Result := 1;
    end;
  end;
end;

function LuaResume(L: TThread; co: TThread; nargs: Integer): Integer;
var
  base: Integer;
  i, n: Integer;
begin
  if co.Status = ST_DEAD then
  begin
    L.PushValue(LuaBool(False));
    L.PushValue(LuaStr(L.Main.NewString('cannot resume dead coroutine')));
    Result := 2;
    Exit;
  end;
  base := co.YieldResumeBase;
  n := co.YieldResumeN;
  if n < 0 then n := nargs;
  co.EnsureStack(base + n);
  for i := 0 to n - 1 do
  begin
    if i < nargs then
      co.Stack[base + i] := L.Stack[L.Top - nargs + i]
    else
      co.Stack[base + i] := LuaNil;
  end;
  co.Top := base + n;
  co.Status := ST_OK;
  try
    VMExecute(co);
    Dec(co.NCI);
    n := co.Top - base;
    L.PushValue(LuaBool(True));
    for i := 0 to n - 1 do
      L.PushValue(co.Stack[base + i]);
    co.Status := ST_DEAD;
    Result := 0;
  except
    on E: ELuaYield do
    begin
      co.Status := ST_YIELD;
      L.PushValue(LuaBool(True));
      for i := 0 to co.YieldN - 1 do
        L.PushValue(co.YieldVals[i]);
      Result := 1;
    end;
    on E: ELuaError do
    begin
      co.Status := ST_ERR;
      L.PushValue(LuaBool(False));
      L.PushValue(LuaStr(L.Main.NewString(RawByteString(E.Message))));
      Result := 2;
    end;
  end;
end;

procedure LuaYield(L: TThread; nresults: Integer);
var
  base: Integer;
  i: Integer;
begin
  base := L.CI[L.NCI - 1].Base;
  L.YieldN := nresults;
  SetLength(L.YieldVals, nresults);
  for i := 0 to nresults - 1 do
    L.YieldVals[i] := L.Stack[base + i];
  L.Status := ST_YIELD;
  raise ELuaYield.Create('yield');
end;

procedure CallFinalizer(L: TLua; f: TFunction; obj: TLuaValue);
var
  base: Integer;
begin
  L.CurThread := L;
  base := L.Top;
  L.PushValue(obj);
  try
    DoCall(L, f, 1, 0, base, base);
  except
    on E: Exception do
    begin
      L.Top := base;
    end;
  end;
end;

end.
