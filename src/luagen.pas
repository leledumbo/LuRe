unit luagen;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// Code generator: syntax tree (luaast) -> function prototypes (TProto).
//
// Register discipline: local variables occupy registers [0, NActRegs) in
// declaration order; temporaries live above them (FreeReg). Every statement
// starts and ends with FreeReg = NActRegs.

interface

uses
  SysUtils, Generics.Collections, luacore, luaast;

function GenerateProto(L: TLua; decl: TFuncDecl; const chunkId: string;
                       source: TStringObj): TProto;

implementation

const
  MAXREGS = 254;
  MAXSELFK = 255;   // largest constant index usable as the key of OP_SELF
  FIELDS_PER_FLUSH = 50;

type
  TJumpList = array of Integer;
  TStrMap = specialize TDictionary<RawByteString, Integer>;
  TIntMap = specialize TDictionary<Int64, Integer>;

  TLoopCtx = record
    Stmt: TStmt;
    Breaks: TJumpList;
  end;

  TPendingGoto = record
    Stmt: TStmt;
    PC: Integer;
  end;

  TLabelPos = record
    Stmt: TStmt;
    PC: Integer;
  end;

  TFuncGen = class
  public
    L: TLua;
    Decl: TFuncDecl;
    Parent: TFuncGen;
    ChunkId: string;
    Source: TStringObj;
    Code: array of TInstruction;
    Lines: array of Integer;
    NCode: Integer;
    K: array of TLuaValue;
    NK: Integer;
    KStrs: TStrMap;
    KInts, KFlts: TIntMap;
    KNil, KTrue, KFalse: Integer;
    Protos: array of TProto;
    NProtos: Integer;
    LocVars: array of TLocVar;
    NLocVars: Integer;
    ActLoc: array of Integer;      // indexes in LocVars of active variables
    NActLoc: Integer;
    FreeReg: Integer;
    NActRegs: Integer;
    MaxStack: Integer;
    CurLine: Integer;
    Loops: array of TLoopCtx;
    NLoops: Integer;
    PendGotos: array of TPendingGoto;
    NPend: Integer;
    LabelPCs: array of TLabelPos;
    NLabelPCs: Integer;
    BlockClose: array of Boolean;  // per open block: has captured/tbc variables
    NBlockClose: Integer;
    constructor Create(AL: TLua; ADecl: TFuncDecl; AParent: TFuncGen);
    destructor Destroy; override;
    function Generate: TProto;
    // emission
    function Emit(op, a, b, c: Integer): Integer;
    function EmitJmp: Integer;
    procedure PatchTo(const lst: TJumpList; target: Integer);
    procedure PatchHere(const lst: TJumpList);
    procedure PatchOne(pc, target: Integer);
    procedure AddJump(var lst: TJumpList; pc: Integer);
    procedure AppendJumps(var lst: TJumpList; const more: TJumpList);
    procedure Fail(const msg: string);
    procedure LimitError(const what: string);
    // registers & constants
    function AllocReg: Integer;
    procedure ReserveTo(n: Integer);
    function AddK(const v: TLuaValue): Integer;
    function KStr(s: TStringObj): Integer;
    function KOf(e: TExpr): Integer;
    function IsConstExpr(e: TExpr): Boolean;
    // variables
    procedure DeclareVar(v: TVarInfo; reg: Integer);
    procedure CloseScopeVars(toCount: Integer);
    procedure AddLocVar(v: TVarInfo; reg: Integer);
    // expressions
    procedure ExprTo(e: TExpr; t: Integer);
    procedure ExprToLocal(e: TExpr; t: Integer);
    function ExprAny(e: TExpr): Integer;
    function ExprRK(e: TExpr): Integer;
    procedure ExprMulti(e: TExpr; want: Integer);
    function GenCall(e: TExpr; want: Integer): Integer;
    procedure GenTable(e: TExpr; t: Integer);
    procedure GenClosure(f: TFuncDecl; t: Integer; line: Integer);
    procedure GenConcat(e: TExpr; t: Integer);
    procedure GenBinary(e: TExpr; t: Integer);
    procedure ExprListAdjust(const exprs: TExprArray; want: Integer; first: Integer);
    function CondJump(e: TExpr; whenTrue: Boolean): TJumpList;
    function IsMulti(e: TExpr): Boolean;
    // statements
    procedure GenBlock(blk: TBlock; closeAtEnd: Boolean);
    procedure GenStmts(blk: TBlock);
    procedure GenStmt(s: TStmt);
    procedure GenLocal(s: TStmt);
    procedure GenAssign(s: TStmt);
    procedure GenStore(target: TExpr; valueReg: Integer; checkNil: Boolean; line: Integer);
    procedure GenIf(s: TStmt);
    procedure GenWhile(s: TStmt);
    procedure GenRepeat(s: TStmt);
    procedure GenForNum(s: TStmt);
    procedure GenForIn(s: TStmt);
    procedure GenReturn(s: TStmt);
    procedure GenGoto(s: TStmt);
    procedure GenBreak(s: TStmt);
    procedure GenLabel(s: TStmt);
    function NeedsClose(const vars: TVarInfoArray; from: Integer): Boolean;
    function FindLoop(s: TStmt): Integer;
  end;

{ ===================================================================== }

constructor TFuncGen.Create(AL: TLua; ADecl: TFuncDecl; AParent: TFuncGen);
begin
  L := AL;
  Decl := ADecl;
  Parent := AParent;
  SetLength(Code, 64);
  SetLength(Lines, 64);
  SetLength(K, 16);
  KStrs := TStrMap.Create;
  KInts := TIntMap.Create;
  KFlts := TIntMap.Create;
  KNil := -1;
  KTrue := -1;
  KFalse := -1;
  MaxStack := 2;
  SetLength(LocVars, 8);
  SetLength(ActLoc, 8);
  SetLength(Loops, 4);
  SetLength(PendGotos, 4);
  SetLength(LabelPCs, 4);
  SetLength(BlockClose, 8);
  SetLength(Protos, 4);
end;

destructor TFuncGen.Destroy;
begin
  KStrs.Free;
  KInts.Free;
  KFlts.Free;
  inherited Destroy;
end;

procedure TFuncGen.Fail(const msg: string);
begin
  raise ELuaError.CreateMsg(Format('%s:%d: %s', [ChunkId, CurLine, msg]));
end;

procedure TFuncGen.LimitError(const what: string);
var
  where: string;
begin
  if Decl.LineDefined = 0 then where := 'main function'
  else where := Format('function at line %d', [Decl.LineDefined]);
  Fail(Format('too many %s (limit is 255) in %s', [what, where]));
end;

function TFuncGen.Emit(op, a, b, c: Integer): Integer;
begin
  if NCode >= Length(Code) then
  begin
    SetLength(Code, NCode * 2);
    SetLength(Lines, NCode * 2);
  end;
  Code[NCode].Op := op;
  Code[NCode].A := a;
  Code[NCode].B := b;
  Code[NCode].C := c;
  Lines[NCode] := CurLine;
  Result := NCode;
  Inc(NCode);
end;

function TFuncGen.EmitJmp: Integer;
begin
  Result := Emit(OP_JMP, -1, 0, 0);
end;

procedure TFuncGen.PatchOne(pc, target: Integer);
begin
  if Code[pc].Op = OP_JMP then
    Code[pc].A := target
  else
    Code[pc].B := target;
end;

procedure TFuncGen.PatchTo(const lst: TJumpList; target: Integer);
var
  i: Integer;
begin
  for i := 0 to Length(lst) - 1 do
    PatchOne(lst[i], target);
end;

procedure TFuncGen.PatchHere(const lst: TJumpList);
begin
  PatchTo(lst, NCode);
end;

procedure TFuncGen.AddJump(var lst: TJumpList; pc: Integer);
begin
  SetLength(lst, Length(lst) + 1);
  lst[High(lst)] := pc;
end;

procedure TFuncGen.AppendJumps(var lst: TJumpList; const more: TJumpList);
var
  i, n: Integer;
begin
  n := Length(lst);
  SetLength(lst, n + Length(more));
  for i := 0 to Length(more) - 1 do
    lst[n + i] := more[i];
end;

{ ---------------------------------------------------------------------- }
{ registers and constants                                                 }
{ ---------------------------------------------------------------------- }

function TFuncGen.AllocReg: Integer;
begin
  Result := FreeReg;
  Inc(FreeReg);
  if FreeReg > MAXREGS then
    LimitError('registers');
  if FreeReg > MaxStack then MaxStack := FreeReg;
end;

procedure TFuncGen.ReserveTo(n: Integer);
begin
  if n > MAXREGS then
    LimitError('registers');
  if n > MaxStack then MaxStack := n;
  FreeReg := n;
end;

function TFuncGen.AddK(const v: TLuaValue): Integer;

  function NewK: Integer;
  begin
    if NK >= Length(K) then SetLength(K, NK * 2);
    K[NK] := v;
    Result := NK;
    Inc(NK);
  end;

begin
  case v.Vt of
    vtNil: begin
      if KNil < 0 then KNil := NewK;
      Result := KNil;
    end;
    vtBool: begin
      if v.B then
      begin
        if KTrue < 0 then KTrue := NewK;
        Result := KTrue;
      end
      else
      begin
        if KFalse < 0 then KFalse := NewK;
        Result := KFalse;
      end;
    end;
    vtInt:
      if not KInts.TryGetValue(v.I, Result) then
      begin
        Result := NewK;
        KInts.Add(v.I, Result);
      end;
    vtFlt:
      if not KFlts.TryGetValue(PInt64(@v.N)^, Result) then
      begin
        Result := NewK;
        KFlts.Add(PInt64(@v.N)^, Result);
      end;
    vtStr:
      if not KStrs.TryGetValue(v.S.Str, Result) then
      begin
        Result := NewK;
        KStrs.Add(v.S.Str, Result);
      end;
  else
    Result := NewK;
  end;
end;

function TFuncGen.KStr(s: TStringObj): Integer;
begin
  Result := AddK(LuaStr(s));
end;

function TFuncGen.IsConstExpr(e: TExpr): Boolean;
begin
  Result := e.Kind in [ekNil, ekTrue, ekFalse, ekInt, ekFlt, ekStr];
end;

function TFuncGen.KOf(e: TExpr): Integer;
begin
  case e.Kind of
    ekNil: Result := AddK(LuaNil);
    ekTrue: Result := AddK(LuaBool(True));
    ekFalse: Result := AddK(LuaBool(False));
    ekInt: Result := AddK(LuaInt(e.IntVal));
    ekFlt: Result := AddK(LuaNum(e.FltVal));
  else
    Result := AddK(LuaStr(e.StrVal));
  end;
end;

{ ---------------------------------------------------------------------- }
{ variables                                                               }
{ ---------------------------------------------------------------------- }

procedure TFuncGen.AddLocVar(v: TVarInfo; reg: Integer);
begin
  if NLocVars >= Length(LocVars) then SetLength(LocVars, NLocVars * 2);
  LocVars[NLocVars].Name := v.Name;
  LocVars[NLocVars].StartPC := NCode;
  LocVars[NLocVars].EndPC := -1;
  LocVars[NLocVars].Reg := reg;
  if NActLoc >= Length(ActLoc) then SetLength(ActLoc, NActLoc * 2);
  ActLoc[NActLoc] := NLocVars;
  Inc(NActLoc);
  Inc(NLocVars);
end;

procedure TFuncGen.DeclareVar(v: TVarInfo; reg: Integer);
begin
  v.Reg := reg;
  if reg + 1 > NActRegs then NActRegs := reg + 1;
  AddLocVar(v, reg);
  if (v.Captured or (v.Kind = vkClose)) and (NBlockClose > 0) then
    BlockClose[NBlockClose - 1] := True;
end;

procedure TFuncGen.CloseScopeVars(toCount: Integer);
begin
  while NActLoc > toCount do
  begin
    Dec(NActLoc);
    LocVars[ActLoc[NActLoc]].EndPC := NCode;
  end;
end;

function TFuncGen.NeedsClose(const vars: TVarInfoArray; from: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := from to Length(vars) - 1 do
    if vars[i].Captured or (vars[i].Kind = vkClose) then Exit(True);
end;

function TFuncGen.FindLoop(s: TStmt): Integer;
var
  i: Integer;
begin
  for i := NLoops - 1 downto 0 do
    if Loops[i].Stmt = s then Exit(i);
  Result := -1;
end;

{ ---------------------------------------------------------------------- }
{ expressions                                                             }
{ ---------------------------------------------------------------------- }

function TFuncGen.IsMulti(e: TExpr): Boolean;
begin
  Result := e.Kind in [ekCall, ekMethCall, ekVararg];
end;

function TFuncGen.ExprRK(e: TExpr): Integer;
begin
  if IsConstExpr(e) then
    Exit(-1 - KOf(e));
  if (e.Kind = ekParen) and IsConstExpr(e.A) then
    Exit(-1 - KOf(e.A));
  Result := ExprAny(e);
end;

function TFuncGen.ExprAny(e: TExpr): Integer;
begin
  case e.Kind of
    ekLocal: Exit(e.Variable.Reg);
    ekParen: if e.A.Kind in [ekLocal, ekParen] then Exit(ExprAny(e.A));
  end;
  if (e.Kind = ekBin) and not (e.Op in [opAnd, opOr, opEq, opNe, opLt, opLe, opGt, opGe, opConcat]) then
  begin
    // like a relocatable expression: the result takes the first free register
    // after the operands have been evaluated (and released)
    Result := FreeReg;
    ExprTo(e, Result);
    FreeReg := Result;
    AllocReg;
    Exit;
  end;
  Result := AllocReg;
  ExprTo(e, Result);
end;

procedure TFuncGen.ExprToLocal(e: TExpr; t: Integer);
var
  tmp, saved: Integer;
  inner: TExpr;
begin
  // expressions that write the target before reading all their operands
  inner := e;
  while inner.Kind = ekParen do inner := inner.A;
  if (inner.Kind = ekTable) or ((inner.Kind = ekBin) and (inner.Op in [opAnd, opOr])) then
  begin
    saved := FreeReg;
    tmp := AllocReg;
    ExprTo(e, tmp);
    Emit(OP_MOVE, t, tmp, 0);
    FreeReg := saved;
  end
  else
    ExprTo(e, t);
end;

procedure TFuncGen.GenClosure(f: TFuncDecl; t: Integer; line: Integer);
var
  child: TFuncGen;
  p: TProto;
begin
  child := TFuncGen.Create(L, f, Self);
  try
    child.ChunkId := ChunkId;
    child.Source := Source;
    p := child.Generate;
  finally
    child.Free;
  end;
  if NProtos >= Length(Protos) then SetLength(Protos, NProtos * 2);
  Protos[NProtos] := p;
  CurLine := line;
  Emit(OP_CLOSURE, t, NProtos, 0);
  Inc(NProtos);
end;

procedure TFuncGen.ExprMulti(e: TExpr; want: Integer);
var
  base: Integer;
begin
  base := FreeReg;
  CurLine := e.Line;
  case e.Kind of
    ekVararg: begin
      if (e.Variable <> nil) and e.Variable.NeedTable then
        Emit(OP_VARARG, base, e.Variable.Reg + 1, want + 1)
      else
        Emit(OP_VARARG, base, 0, want + 1);
      if want >= 0 then ReserveTo(base + want);
    end;
    ekCall, ekMethCall: begin
      GenCall(e, want);
      if want >= 0 then ReserveTo(base + want) else FreeReg := base;
    end;
  end;
  if (want >= 0) and (FreeReg < base + want) then ReserveTo(base + want);
end;

// compiles a call; function and arguments are placed from FreeReg on.
// Returns the base register; results start there.
function TFuncGen.GenCall(e: TExpr; want: Integer): Integer;
var
  base, objreg, nargs, i, b, kidx: Integer;
  last: TExpr;
  openCall: Boolean;
begin
  base := FreeReg;
  if e.Kind = ekMethCall then
  begin
    objreg := ExprAny(e.A);
    FreeReg := base;
    AllocReg;
    AllocReg;
    CurLine := e.Line;
    kidx := KStr(e.StrVal);
    if kidx <= MAXSELFK then
      Emit(OP_SELF, base, objreg, -1 - kidx)
    else
    begin
      // the key cannot be an operand of SELF: get the method with a plain index
      Emit(OP_MOVE, base + 1, objreg, 0);
      AllocReg;
      Emit(OP_LOADK, base + 2, kidx, 0);
      Emit(OP_GETTABLE, base, objreg, base + 2);
      FreeReg := base + 2;
    end;
    nargs := 1;
  end
  else
  begin
    AllocReg;
    ExprTo(e.A, base);
    FreeReg := base + 1;
    nargs := 0;
  end;
  openCall := False;
  for i := 0 to Length(e.Args) - 1 do
  begin
    last := e.Args[i];
    if (i = Length(e.Args) - 1) and IsMulti(last) then
    begin
      ExprMulti(last, -1);
      openCall := True;
    end
    else
    begin
      AllocReg;
      ExprTo(last, FreeReg - 1);
      Inc(nargs);
    end;
  end;
  if openCall then b := 0 else b := nargs + 1;
  CurLine := e.Line;
  Emit(OP_CALL, base, b, want + 1);
  FreeReg := base;
  Result := base;
end;

procedure TFuncGen.GenConcat(e: TExpr; t: Integer);
var
  parts: array of TExpr;
  n, i, base: Integer;
  cur: TExpr;
  saved: Integer;
begin
  // flatten the right spine: a .. (b .. (c .. d))
  n := 0;
  cur := e;
  while (cur.Kind = ekBin) and (cur.Op = opConcat) do
  begin
    SetLength(parts, n + 1);
    parts[n] := cur.A;
    Inc(n);
    cur := cur.B;
  end;
  SetLength(parts, n + 1);
  parts[n] := cur;
  Inc(n);
  saved := FreeReg;
  base := FreeReg;
  for i := 0 to n - 1 do
  begin
    AllocReg;
    ExprTo(parts[i], base + i);
    FreeReg := base + i + 1;
  end;
  CurLine := e.Line;
  Emit(OP_CONCAT, t, base, n);
  FreeReg := saved;
end;

procedure TFuncGen.GenBinary(e: TExpr; t: Integer);
var
  a, b, opc, saved, n0: Integer;
  jl: TJumpList;
  jend: Integer;
begin
  saved := FreeReg;
  case e.Op of
    opAnd, opOr: begin
      ExprTo(e.A, t);
      if e.Op = opAnd then
        jend := Emit(OP_JF, t, -1, 0)
      else
        jend := Emit(OP_JT, t, -1, 0);
      ExprTo(e.B, t);
      Code[jend].B := NCode;
    end;
    opEq, opNe, opLt, opLe, opGt, opGe: begin
      jl := CondJump(e, True);
      Emit(OP_LOADBOOL, t, 0, 0);
      jend := EmitJmp;
      PatchHere(jl);
      Emit(OP_LOADBOOL, t, 1, 0);
      Code[jend].A := NCode;
    end;
    opConcat: GenConcat(e, t);
  else
    begin
      n0 := NCode;
      a := ExprRK(e.A);
      // a pending index/upvalue operand is loaded when the operator is seen
      if (e.A.Kind in [ekIndex, ekUpval]) and (NCode > n0) then Lines[NCode - 1] := e.Line;
      b := ExprRK(e.B);
      case e.Op of
        opAdd: opc := OP_ADD;
        opSub: opc := OP_SUB;
        opMul: opc := OP_MUL;
        opMod: opc := OP_MOD;
        opPow: opc := OP_POW;
        opDiv: opc := OP_DIV;
        opIDiv: opc := OP_IDIV;
        opBAnd: opc := OP_BAND;
        opBOr: opc := OP_BOR;
        opBXor: opc := OP_BXOR;
        opShl: opc := OP_SHL;
      else
        opc := OP_SHR;
      end;
      CurLine := e.Line;
      Emit(opc, t, a, b);
    end;
  end;
  FreeReg := saved;
end;

procedure TFuncGen.GenTable(e: TExpr; t: Integer);
var
  tbl, saved, i, pending, stored, na, nh, r, kreg, vreg: Integer;
  f: TTableField;
  lastMulti: Boolean;
begin
  saved := FreeReg;
  if (t <> FreeReg - 1) or (t < NActRegs) then
  begin
    tbl := AllocReg;
  end
  else
    tbl := t;
  na := 0;
  nh := 0;
  for i := 0 to Length(e.Fields) - 1 do
    if e.Fields[i].Kind = fkList then Inc(na) else Inc(nh);
  lastMulti := (na > 0) and (e.Fields[High(e.Fields)].Kind = fkList) and
               IsMulti(e.Fields[High(e.Fields)].Val);
  if lastMulti then Dec(na);
  CurLine := e.Line;
  Emit(OP_NEWTABLE, tbl, na, nh);
  pending := 0;
  stored := 0;
  for i := 0 to Length(e.Fields) - 1 do
  begin
    f := e.Fields[i];
    if f.Kind = fkList then
    begin
      if (i = High(e.Fields)) and lastMulti then
      begin
        ExprMulti(f.Val, -1);
        CurLine := e.Line;
        Emit(OP_SETLIST, tbl, 0, stored);
        pending := 0;
        FreeReg := tbl + 1;
      end
      else
      begin
        r := AllocReg;
        ExprTo(f.Val, r);
        Inc(pending);
        if pending = FIELDS_PER_FLUSH then
        begin
          CurLine := e.Line;
          Emit(OP_SETLIST, tbl, pending, stored);
          Inc(stored, pending);
          pending := 0;
          FreeReg := tbl + 1;
        end;
      end;
    end
    else
    begin
      r := FreeReg;
      kreg := ExprRK(f.Key);
      vreg := ExprRK(f.Val);
      CurLine := f.Val.Line;
      Emit(OP_SETTABLE, tbl, kreg, vreg);
      FreeReg := r;
    end;
  end;
  if pending > 0 then
  begin
    CurLine := e.Line;
    Emit(OP_SETLIST, tbl, pending, stored);
  end;
  if tbl <> t then
    Emit(OP_MOVE, t, tbl, 0);
  FreeReg := saved;
end;

procedure TFuncGen.ExprTo(e: TExpr; t: Integer);
var
  saved, objr, keyr, base, tmpr: Integer;
  atTop: Boolean;
begin
  CurLine := e.Line;
  case e.Kind of
    ekNil: Emit(OP_LOADNIL, t, 0, 0);
    ekTrue: Emit(OP_LOADBOOL, t, 1, 0);
    ekFalse: Emit(OP_LOADBOOL, t, 0, 0);
    ekInt, ekFlt, ekStr: Emit(OP_LOADK, t, KOf(e), 0);
    ekVararg: begin
      if (e.Variable <> nil) and e.Variable.NeedTable then
        Emit(OP_VARARG, t, e.Variable.Reg + 1, 2)
      else
        Emit(OP_VARARG, t, 0, 2);
    end;
    ekFunc:
      if t = FreeReg - 1 then
        GenClosure(e.Func, t, e.Line)
      else
      begin
        // closures are always created in the topmost register
        saved := FreeReg;
        tmpr := AllocReg;
        GenClosure(e.Func, tmpr, e.Line);
        CurLine := e.Line;
        Emit(OP_MOVE, t, tmpr, 0);
        FreeReg := saved;
      end;
    ekLocal: if e.Variable.Reg <> t then Emit(OP_MOVE, t, e.Variable.Reg, 0);
    ekUpval: Emit(OP_GETUPVAL, t, e.UpIdx, 0);
    ekParen: ExprTo(e.A, t);
    ekIndex: begin
      saved := FreeReg;
      if (e.A.Kind = ekLocal) and (e.A.Variable.Kind = vkVarargParam) and
         not e.A.Variable.NeedTable then
      begin
        keyr := ExprRK(e.B);
        CurLine := e.Line;
        Emit(OP_GETVARG, t, 0, keyr);
      end
      else if e.A.Kind = ekUpval then
      begin
        keyr := ExprRK(e.B);
        CurLine := e.Line;
        Emit(OP_GETTABUP, t, e.A.UpIdx, keyr);
      end
      else
      begin
        objr := ExprAny(e.A);
        keyr := ExprRK(e.B);
        CurLine := e.Line;
        Emit(OP_GETTABLE, t, objr, keyr);
      end;
      FreeReg := saved;
    end;
    ekCall, ekMethCall: begin
      saved := FreeReg;
      atTop := (t = FreeReg - 1) and (t >= NActRegs);
      if atTop then
      begin
        FreeReg := t;
        GenCall(e, 1);
        FreeReg := saved;
      end
      else
      begin
        base := GenCall(e, 1);
        Emit(OP_MOVE, t, base, 0);
        FreeReg := saved;
      end;
    end;
    ekBin: GenBinary(e, t);
    ekUn: begin
      saved := FreeReg;
      objr := ExprAny(e.A);
      CurLine := e.Line;
      case e.Op of
        opNot: Emit(OP_NOT, t, objr, 0);
        opNeg: Emit(OP_UNM, t, objr, 0);
        opBNot: Emit(OP_BNOT, t, objr, 0);
        opLen: Emit(OP_LEN, t, objr, 0);
      end;
      FreeReg := saved;
    end;
    ekTable: GenTable(e, t);
  end;
end;

// adjusts 'exprs' to 'want' values placed in consecutive registers from
// 'first' (= FreeReg on entry). want = -1: all values (open).
procedure TFuncGen.ExprListAdjust(const exprs: TExprArray; want: Integer; first: Integer);
var
  i, n, need, saved: Integer;
  e: TExpr;
begin
  n := Length(exprs);
  for i := 0 to n - 1 do
  begin
    e := exprs[i];
    if (i = n - 1) and IsMulti(e) and ((want < 0) or (i < want)) then
    begin
      if want < 0 then need := -1 else need := want - i;
      ExprMulti(e, need);
      Exit;
    end;
    if (want < 0) or (i < want) then
    begin
      AllocReg;
      ExprTo(e, FreeReg - 1);
    end
    else
    begin
      // extra expression: evaluated and discarded
      saved := FreeReg;
      ExprAny(e);
      FreeReg := saved;
    end;
  end;
  if (want >= 0) and (n < want) then
  begin
    // missing values are nil
    if FreeReg < first + want then
    begin
      Emit(OP_LOADNIL, FreeReg, first + want - FreeReg - 1, 0);
      ReserveTo(first + want);
    end;
  end;
  if want >= 0 then ReserveTo(first + want);
end;

// jumps taken when the truthiness of 'e' equals 'whenTrue'
function TFuncGen.CondJump(e: TExpr; whenTrue: Boolean): TJumpList;
var
  a, b, saved, flag, jpc: Integer;
  fl, tl: TJumpList;
  op: Integer;
  r: Integer;
begin
  Result := nil;
  CurLine := e.Line;
  case e.Kind of
    ekParen: Exit(CondJump(e.A, whenTrue));
    ekTrue, ekInt, ekFlt, ekStr: begin
      if whenTrue then AddJump(Result, EmitJmp);
      Exit;
    end;
    ekNil, ekFalse: begin
      if not whenTrue then AddJump(Result, EmitJmp);
      Exit;
    end;
    ekUn: if e.Op = opNot then Exit(CondJump(e.A, not whenTrue));
    ekBin:
      case e.Op of
        opAnd:
          if not whenTrue then
          begin
            Result := CondJump(e.A, False);
            AppendJumps(Result, CondJump(e.B, False));
            Exit;
          end
          else
          begin
            fl := CondJump(e.A, False);
            Result := CondJump(e.B, True);
            PatchHere(fl);
            Exit;
          end;
        opOr:
          if whenTrue then
          begin
            Result := CondJump(e.A, True);
            AppendJumps(Result, CondJump(e.B, True));
            Exit;
          end
          else
          begin
            tl := CondJump(e.A, True);
            Result := CondJump(e.B, False);
            PatchHere(tl);
            Exit;
          end;
        opEq, opNe, opLt, opLe, opGt, opGe: begin
          saved := FreeReg;
          a := ExprRK(e.A);
          b := ExprRK(e.B);
          flag := Ord(whenTrue);
          case e.Op of
            opEq: op := OP_EQ;
            opNe: begin op := OP_EQ; flag := 1 - flag; end;
            opLt: op := OP_LT;
            opLe: op := OP_LE;
            opGt: begin op := OP_LT; r := a; a := b; b := r; end;
          else
            begin op := OP_LE; r := a; a := b; b := r; end;
          end;
          CurLine := e.Line;
          Emit(op, flag, a, b);
          jpc := EmitJmp;
          AddJump(Result, jpc);
          FreeReg := saved;
          Exit;
        end;
      end;
  end;
  // general case: evaluate and test
  saved := FreeReg;
  r := ExprAny(e);
  CurLine := e.Line;
  if whenTrue then
    jpc := Emit(OP_JT, r, -1, 0)
  else
    jpc := Emit(OP_JF, r, -1, 0);
  AddJump(Result, jpc);
  FreeReg := saved;
end;

{ ---------------------------------------------------------------------- }
{ statements                                                              }
{ ---------------------------------------------------------------------- }

procedure TFuncGen.GenStmts(blk: TBlock);
var
  i: Integer;
begin
  for i := 0 to Length(blk.Stmts) - 1 do
  begin
    GenStmt(blk.Stmts[i]);
    FreeReg := NActRegs;
  end;
end;

procedure TFuncGen.GenBlock(blk: TBlock; closeAtEnd: Boolean);
var
  level, nloc: Integer;
  needClose: Boolean;
begin
  level := NActRegs;
  nloc := NActLoc;
  if NBlockClose >= Length(BlockClose) then SetLength(BlockClose, NBlockClose * 2);
  BlockClose[NBlockClose] := False;
  Inc(NBlockClose);
  GenStmts(blk);
  Dec(NBlockClose);
  needClose := BlockClose[NBlockClose];
  if closeAtEnd and needClose then
    Emit(OP_CLOSE, level, 0, 0);
  CloseScopeVars(nloc);
  NActRegs := level;
  FreeReg := level;
end;

procedure TFuncGen.GenLocal(s: TStmt);
var
  nvars, nregs, i, base: Integer;
  exprs: TExprArray;
  last: TVarInfo;
  v: TVarInfo;
begin
  nvars := Length(s.Vars);
  last := s.Vars[nvars - 1];
  nregs := nvars;
  exprs := s.Exprs;
  if last.Kind = vkCtc then
  begin
    Dec(nregs);
    SetLength(exprs, Length(exprs) - 1);   // the constant needs no code
  end;
  base := FreeReg;
  CurLine := s.Line;
  ExprListAdjust(exprs, nregs, base);
  if (Length(exprs) = 0) and (nregs > 0) then
  begin
    // no initializer: all nil
  end;
  CurLine := s.EndLine;
  for i := 0 to nvars - 1 do
  begin
    v := s.Vars[i];
    if v.Kind = vkCtc then Continue;
    DeclareVar(v, base + i);
    if v.Kind = vkClose then
      Emit(OP_TBC, v.Reg, 0, 0);
  end;
  FreeReg := NActRegs;
end;

// stores the value in 'valueReg' into 'target'
procedure TFuncGen.GenStore(target: TExpr; valueReg: Integer; checkNil: Boolean; line: Integer);
var
  saved, objr, keyr, tmp: Integer;
begin
  CurLine := line;
  case target.Kind of
    ekLocal: if target.Variable.Reg <> valueReg then Emit(OP_MOVE, target.Variable.Reg, valueReg, 0);
    ekUpval: Emit(OP_SETUPVAL, valueReg, target.UpIdx, 0);
    ekIndex: begin
      saved := FreeReg;
      if checkNil then
      begin
        // a global declared with an initializer must not exist yet
        tmp := AllocReg;
        if target.A.Kind = ekUpval then
          Emit(OP_GETTABUP, tmp, target.A.UpIdx, -1 - KStr(target.B.StrVal))
        else
        begin
          objr := ExprAny(target.A);
          Emit(OP_GETTABLE, tmp, objr, -1 - KStr(target.B.StrVal));
        end;
        Emit(OP_ERRNNIL, tmp, KStr(target.B.StrVal), 0);
        FreeReg := saved;
      end;
      if target.A.Kind = ekUpval then
      begin
        keyr := ExprRK(target.B);
        Emit(OP_SETTABUP, target.A.UpIdx, keyr, valueReg);
      end
      else
      begin
        objr := ExprAny(target.A);
        keyr := ExprRK(target.B);
        Emit(OP_SETTABLE, objr, keyr, valueReg);
      end;
      FreeReg := saved;
    end;
  end;
end;

procedure TFuncGen.GenAssign(s: TStmt);
var
  nt, ne, i, base, saved, vr, kr, orr: Integer;
  t, e: TExpr;
  objr, keyr: array of Integer;
  assignedLocals: array of TVarInfo;
  assignedUps: array of Integer;

  function LocalAssigned(v: TVarInfo): Boolean;
  var
    j: Integer;
  begin
    for j := 0 to High(assignedLocals) do
      if assignedLocals[j] = v then Exit(True);
    Result := False;
  end;

  function UpAssigned(idx: Integer): Boolean;
  var
    j: Integer;
  begin
    for j := 0 to High(assignedUps) do
      if assignedUps[j] = idx then Exit(True);
    Result := False;
  end;

  // evaluates an operand of a target, copying it if the statement assigns it
  function Operand(x: TExpr; isKey: Boolean): Integer;
  var
    tmp: Integer;
  begin
    if (x.Kind = ekLocal) and LocalAssigned(x.Variable) then
    begin
      tmp := AllocReg;
      Emit(OP_MOVE, tmp, x.Variable.Reg, 0);
      Exit(tmp);
    end;
    if (x.Kind = ekUpval) and UpAssigned(x.UpIdx) then
    begin
      tmp := AllocReg;
      Emit(OP_GETUPVAL, tmp, x.UpIdx, 0);
      Exit(tmp);
    end;
    if isKey then Result := ExprRK(x) else Result := ExprAny(x);
  end;

begin
  nt := Length(s.Targets);
  ne := Length(s.Exprs);
  CurLine := s.Line;
  saved := FreeReg;
  if (nt = 1) and (ne = 1) then
  begin
    t := s.Targets[0];
    e := s.Exprs[0];
    case t.Kind of
      ekLocal: begin
        ExprToLocal(e, t.Variable.Reg);
      end;
      ekUpval: begin
        vr := ExprAny(e);
        GenStore(t, vr, False, s.EndLine);
      end;
      ekIndex: begin
        if s.CheckNil then
        begin
          vr := ExprAny(e);
          GenStore(t, vr, True, s.EndLine);
        end
        else if t.A.Kind = ekUpval then
        begin
          kr := ExprRK(t.B);
          vr := ExprRK(e);
          CurLine := s.EndLine;
          Emit(OP_SETTABUP, t.A.UpIdx, kr, vr);
        end
        else
        begin
          orr := ExprAny(t.A);
          kr := ExprRK(t.B);
          vr := ExprRK(e);
          CurLine := s.EndLine;
          Emit(OP_SETTABLE, orr, kr, vr);
        end;
      end;
    end;
    FreeReg := saved;
    Exit;
  end;
  // general case
  for i := 0 to nt - 1 do
  begin
    t := s.Targets[i];
    if t.Kind = ekLocal then
    begin
      SetLength(assignedLocals, Length(assignedLocals) + 1);
      assignedLocals[High(assignedLocals)] := t.Variable;
    end
    else if t.Kind = ekUpval then
    begin
      SetLength(assignedUps, Length(assignedUps) + 1);
      assignedUps[High(assignedUps)] := t.UpIdx;
    end;
  end;
  SetLength(objr, nt);
  SetLength(keyr, nt);
  for i := 0 to nt - 1 do
  begin
    t := s.Targets[i];
    if t.Kind = ekIndex then
    begin
      if (t.A.Kind = ekUpval) and not UpAssigned(t.A.UpIdx) then
        objr[i] := -1      // the store goes through SETTABUP
      else
        objr[i] := Operand(t.A, False);
      keyr[i] := Operand(t.B, True);
    end;
  end;
  base := FreeReg;
  ExprListAdjust(s.Exprs, nt, base);
  // assign from right to left
  for i := nt - 1 downto 0 do
  begin
    t := s.Targets[i];
    CurLine := s.EndLine;
    case t.Kind of
      ekLocal: if t.Variable.Reg <> base + i then Emit(OP_MOVE, t.Variable.Reg, base + i, 0);
      ekUpval: Emit(OP_SETUPVAL, base + i, t.UpIdx, 0);
      ekIndex: begin
        if s.CheckNil then
        begin
          vr := AllocReg;
          if objr[i] < 0 then
            Emit(OP_GETTABUP, vr, t.A.UpIdx, -1 - KStr(t.B.StrVal))
          else
            Emit(OP_GETTABLE, vr, objr[i], -1 - KStr(t.B.StrVal));
          Emit(OP_ERRNNIL, vr, KStr(t.B.StrVal), 0);
          FreeReg := vr;
        end;
        if objr[i] < 0 then
          Emit(OP_SETTABUP, t.A.UpIdx, keyr[i], base + i)
        else
          Emit(OP_SETTABLE, objr[i], keyr[i], base + i);
      end;
    end;
  end;
  FreeReg := saved;
end;

procedure TFuncGen.GenIf(s: TStmt);
var
  i, n: Integer;
  fl, ends: TJumpList;
  hasMore: Boolean;
begin
  n := Length(s.Exprs);
  ends := nil;
  for i := 0 to n - 1 do
  begin
    fl := CondJump(s.Exprs[i], False);
    GenBlock(s.Blocks[i], True);
    hasMore := (i < n - 1) or (s.ElseBlock <> nil);
    if hasMore then
    begin
      CurLine := s.Blocks[i].LastLine;
      AddJump(ends, EmitJmp);
    end;
    PatchHere(fl);
  end;
  if s.ElseBlock <> nil then
    GenBlock(s.ElseBlock, True);
  PatchHere(ends);
end;

procedure TFuncGen.GenWhile(s: TStmt);
var
  start, idx: Integer;
  exits: TJumpList;
begin
  start := NCode;
  exits := CondJump(s.Exprs[0], False);
  if NLoops >= Length(Loops) then SetLength(Loops, NLoops * 2);
  Loops[NLoops].Stmt := s;
  Loops[NLoops].Breaks := nil;
  idx := NLoops;
  Inc(NLoops);
  GenBlock(s.Body, True);
  CurLine := s.Body.LastLine;
  Emit(OP_JMP, start, 0, 0);
  PatchHere(exits);
  PatchHere(Loops[idx].Breaks);
  Dec(NLoops);
end;

procedure TFuncGen.GenRepeat(s: TStmt);
var
  start, idx, level, nloc: Integer;
  tj, fl: TJumpList;
  needClose: Boolean;
begin
  start := NCode;
  if NLoops >= Length(Loops) then SetLength(Loops, NLoops * 2);
  Loops[NLoops].Stmt := s;
  Loops[NLoops].Breaks := nil;
  idx := NLoops;
  Inc(NLoops);
  level := NActRegs;
  nloc := NActLoc;
  if NBlockClose >= Length(BlockClose) then SetLength(BlockClose, NBlockClose * 2);
  BlockClose[NBlockClose] := False;
  Inc(NBlockClose);
  GenStmts(s.Body);
  FreeReg := NActRegs;
  needClose := BlockClose[NBlockClose - 1];
  if needClose then
  begin
    tj := CondJump(s.Exprs[0], True);
    CurLine := s.EndLine;
    Emit(OP_CLOSE, level, 0, 0);
    Emit(OP_JMP, start, 0, 0);
    PatchHere(tj);
    Emit(OP_CLOSE, level, 0, 0);
  end
  else
  begin
    fl := CondJump(s.Exprs[0], False);
    PatchTo(fl, start);
  end;
  Dec(NBlockClose);
  CloseScopeVars(nloc);
  NActRegs := level;
  FreeReg := level;
  PatchHere(Loops[idx].Breaks);
  Dec(NLoops);
end;

procedure TFuncGen.GenForNum(s: TStmt);
var
  base, idx, prep, bodyStart, i: Integer;
  nloc: Integer;
  cv: TVarInfo;
  nexprs: Integer;
  r: Integer;
begin
  base := FreeReg;
  nloc := NActLoc;
  CurLine := s.Line;
  nexprs := Length(s.Exprs);
  for i := 0 to 1 do
  begin
    r := AllocReg;
    ExprTo(s.Exprs[i], r);
  end;
  r := AllocReg;
  if nexprs = 3 then
    ExprTo(s.Exprs[2], r)
  else
    Emit(OP_LOADK, r, AddK(LuaInt(1)), 0);
  DeclareVar(s.Hidden[0], base);
  DeclareVar(s.Hidden[1], base + 1);
  CurLine := s.Line;
  prep := Emit(OP_FORPREP, base, -1, 0);
  bodyStart := NCode;
  cv := s.Vars[0];
  if NLoops >= Length(Loops) then SetLength(Loops, NLoops * 2);
  Loops[NLoops].Stmt := s;
  Loops[NLoops].Breaks := nil;
  idx := NLoops;
  Inc(NLoops);
  if NBlockClose >= Length(BlockClose) then SetLength(BlockClose, NBlockClose * 2);
  BlockClose[NBlockClose] := False;
  Inc(NBlockClose);
  DeclareVar(cv, base + 2);
  FreeReg := NActRegs;
  GenBlock(s.Body, True);
  if cv.Captured then
    Emit(OP_CLOSE, base + 2, 0, 0);
  Dec(NBlockClose);
  CurLine := s.Line;
  Emit(OP_FORLOOP, base, bodyStart, 0);
  Code[prep].B := NCode;
  PatchHere(Loops[idx].Breaks);
  Dec(NLoops);
  CloseScopeVars(nloc);
  NActRegs := base;
  FreeReg := base;
end;

procedure TFuncGen.GenForIn(s: TStmt);
var
  base, idx, prep, bodyStart, i, nvars, nloc, callPC: Integer;
  anyCaptured, savedFlag: Boolean;
begin
  base := FreeReg;
  nloc := NActLoc;
  CurLine := s.Line;
  ExprListAdjust(s.Exprs, 4, base);
  savedFlag := BlockClose[NBlockClose - 1];
  for i := 0 to 2 do
    DeclareVar(s.Hidden[i], base + i);
  BlockClose[NBlockClose - 1] := savedFlag;
  prep := Emit(OP_TFORPREP, base, -1, 0);
  nvars := Length(s.Vars);
  if NLoops >= Length(Loops) then SetLength(Loops, NLoops * 2);
  Loops[NLoops].Stmt := s;
  Loops[NLoops].Breaks := nil;
  idx := NLoops;
  Inc(NLoops);
  bodyStart := NCode;
  anyCaptured := False;
  if NBlockClose >= Length(BlockClose) then SetLength(BlockClose, NBlockClose * 2);
  BlockClose[NBlockClose] := False;
  Inc(NBlockClose);
  for i := 0 to nvars - 1 do
  begin
    DeclareVar(s.Vars[i], base + 3 + i);
    if s.Vars[i].Captured then anyCaptured := True;
  end;
  ReserveTo(NActRegs);
  if MaxStack < base + 6 then MaxStack := base + 6;   // room to call the iterator
  GenBlock(s.Body, True);
  if anyCaptured then
    Emit(OP_CLOSE, base + 3, 0, 0);
  Dec(NBlockClose);
  callPC := NCode;
  Code[prep].B := callPC;
  CurLine := s.Line;
  Emit(OP_TFORCALL, base, 0, nvars);
  Emit(OP_TFORLOOP, base, bodyStart, 0);
  CloseScopeVars(nloc);
  NActRegs := base;
  FreeReg := base;
  // the closing value is closed when the loop ends
  Emit(OP_CLOSE, base, 0, 0);
  PatchHere(Loops[idx].Breaks);
  Dec(NLoops);
end;

procedure TFuncGen.GenReturn(s: TStmt);
var
  n, base, r, saved: Integer;
  e: TExpr;
begin
  CurLine := s.Line;
  n := Length(s.Exprs);
  saved := FreeReg;
  if n >= 255 then LimitError('returns');
  if n = 0 then
  begin
    CurLine := s.EndLine;
    Emit(OP_RETURN, NActRegs, 1, 0);
  end
  else if s.TailCall then
  begin
    e := s.Exprs[0];
    base := GenCall(e, -1);
    // turn the call into a tail call
    Code[NCode - 1].Op := OP_TAILCALL;
    Code[NCode - 1].C := 0;
    Emit(OP_RETURN, base, 0, 0);
  end
  else if (n = 1) and not IsMulti(s.Exprs[0]) then
  begin
    r := ExprAny(s.Exprs[0]);
    CurLine := s.EndLine;
    Emit(OP_RETURN, r, 2, 0);
  end
  else
  begin
    base := FreeReg;
    ExprListAdjust(s.Exprs, -1, base);
    CurLine := s.EndLine;
    if IsMulti(s.Exprs[n - 1]) then
      Emit(OP_RETURN, base, 0, 0)
    else
      Emit(OP_RETURN, base, n + 1, 0);
  end;
  FreeReg := saved;
end;

procedure TFuncGen.GenBreak(s: TStmt);
var
  idx: Integer;
begin
  CurLine := s.Line;
  idx := FindLoop(s.BreakTarget);
  if NeedsClose(s.Vars, s.NActVar) then
    Emit(OP_CLOSE, s.NActVar, 0, 0);
  AddJump(Loops[idx].Breaks, EmitJmp);
end;

procedure TFuncGen.GenGoto(s: TStmt);
var
  lab: TStmt;
  i, pc: Integer;
begin
  CurLine := s.Line;
  lab := s.Target;
  if NeedsClose(s.Vars, lab.NActVar) then
    Emit(OP_CLOSE, lab.NActVar, 0, 0);
  pc := EmitJmp;
  for i := 0 to NLabelPCs - 1 do
    if LabelPCs[i].Stmt = lab then
    begin
      Code[pc].A := LabelPCs[i].PC;   // backward jump
      Exit;
    end;
  if NPend >= Length(PendGotos) then SetLength(PendGotos, NPend * 2);
  PendGotos[NPend].Stmt := lab;
  PendGotos[NPend].PC := pc;
  Inc(NPend);
end;

procedure TFuncGen.GenLabel(s: TStmt);
var
  i, j: Integer;
begin
  if NLabelPCs >= Length(LabelPCs) then SetLength(LabelPCs, NLabelPCs * 2);
  LabelPCs[NLabelPCs].Stmt := s;
  LabelPCs[NLabelPCs].PC := NCode;
  Inc(NLabelPCs);
  j := 0;
  for i := 0 to NPend - 1 do
    if PendGotos[i].Stmt = s then
      Code[PendGotos[i].PC].A := NCode
    else
    begin
      PendGotos[j] := PendGotos[i];
      Inc(j);
    end;
  NPend := j;
end;

procedure TFuncGen.GenStmt(s: TStmt);
var
  base: Integer;
  v: TVarInfo;
begin
  CurLine := s.Line;
  case s.Kind of
    skLocal: GenLocal(s);
    skAssign: GenAssign(s);
    skCall: begin
      GenCall(s.Exprs[0], 0);
    end;
    skDo: GenBlock(s.Body, True);
    skWhile: GenWhile(s);
    skRepeat: GenRepeat(s);
    skIf: GenIf(s);
    skForNum: GenForNum(s);
    skForIn: GenForIn(s);
    skLocalFunc: begin
      v := s.Vars[0];
      base := FreeReg;
      v.Reg := base;
      AllocReg;
      GenClosure(s.Func, base, s.EndLine);
      DeclareVar(v, base);
    end;
    skReturn: GenReturn(s);
    skBreak: GenBreak(s);
    skGoto: GenGoto(s);
    skLabel: GenLabel(s);
  end;
end;

{ ---------------------------------------------------------------------- }

function TFuncGen.Generate: TProto;
var
  p: TProto;
  i, np: Integer;
  v: TVarInfo;
  u: TUpvalInfo;
begin
  p := L.NewProto;
  p.Source := Source;
  p.LineDefined := Decl.LineDefined;
  p.LastLineDefined := Decl.LastLine;
  np := Length(Decl.Params);
  p.NumParams := np;
  p.IsVararg := Decl.IsVararg;
  CurLine := Decl.LineDefined;
  NBlockClose := 1;
  BlockClose[0] := False;
  for i := 0 to np - 1 do
    DeclareVar(Decl.Params[i], i);
  if Decl.VarargVar <> nil then
  begin
    DeclareVar(Decl.VarargVar, np);
    if Decl.VarargVar.NeedTable then p.VarTabReg := np;
  end;
  FreeReg := NActRegs;
  if FreeReg > MaxStack then MaxStack := FreeReg;
  GenStmts(Decl.Body);
  CurLine := Decl.RetLine;
  Emit(OP_RETURN, NActRegs, 1, 0);
  CloseScopeVars(0);
  SetLength(p.Code, NCode);
  SetLength(p.LineInfo, NCode);
  for i := 0 to NCode - 1 do
  begin
    p.Code[i] := Code[i];
    p.LineInfo[i] := Lines[i];
  end;
  SetLength(p.K, NK);
  for i := 0 to NK - 1 do p.K[i] := K[i];
  SetLength(p.Protos, NProtos);
  for i := 0 to NProtos - 1 do p.Protos[i] := Protos[i];
  SetLength(p.LocVars, NLocVars);
  for i := 0 to NLocVars - 1 do
  begin
    p.LocVars[i] := LocVars[i];
    if p.LocVars[i].EndPC < 0 then p.LocVars[i].EndPC := NCode;
  end;
  SetLength(p.UpvalDescs, Length(Decl.Upvals));
  for i := 0 to Length(Decl.Upvals) - 1 do
  begin
    u := Decl.Upvals[i];
    p.UpvalDescs[i].Name := u.Name;
    p.UpvalDescs[i].IsConst := u.ReadOnly;
    if u.FromLocal <> nil then
    begin
      p.UpvalDescs[i].InStack := True;
      p.UpvalDescs[i].Idx := u.FromLocal.Reg;
    end
    else if Decl.Parent = nil then
    begin
      p.UpvalDescs[i].InStack := True;   // the environment of the main chunk
      p.UpvalDescs[i].Idx := 0;
    end
    else
    begin
      p.UpvalDescs[i].InStack := False;
      p.UpvalDescs[i].Idx := u.ParentIdx;
    end;
  end;
  p.MaxStackSize := MaxStack + 1;
  v := nil;
  if v <> nil then ;
  Result := p;
end;

function GenerateProto(L: TLua; decl: TFuncDecl; const chunkId: string;
                       source: TStringObj): TProto;
var
  g: TFuncGen;
begin
  g := TFuncGen.Create(L, decl, nil);
  try
    g.ChunkId := chunkId;
    g.Source := source;
    Result := g.Generate;
  finally
    g.Free;
  end;
end;

end.
