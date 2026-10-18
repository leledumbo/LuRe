unit luaparser;

{$mode objfpc}{$H+}

// Recursive-descent parser: source text -> syntax tree (luaast).
// Scoping, upvalues, 'global' declarations, compile-time constants and
// goto/label rules are resolved here.

interface

uses
  SysUtils, Math, Contnrs, luacore, lualex, luaast, luaarith;

// Parses a chunk. 'owner' receives every node created (the caller frees it
// after code generation).
function ParseChunk(L: TLua; const source: RawByteString; const chunkName: string;
                    out owner: TObjectList): TFuncDecl;

implementation

const
  MAXVARS = 200;
  MAXUPVAL = 255;
  MAXLEVEL = 200;

type
  TActKind = (akLocal, akGlobal, akGlobalConst);

  TActEntry = record
    Name: TStringObj;      // nil for 'global *'
    Kind: TActKind;
    Info: TVarInfo;        // locals only
  end;

  TLabelRec = record
    Name: TStringObj;
    Line: Integer;
    NAct: Integer;
    Stmt: TStmt;
  end;

  TGotoRec = record
    Name: TStringObj;
    Line: Integer;
    NAct: Integer;
    Stmt: TStmt;
  end;

  TBlockScope = record
    NAct: Integer;
    IsLoop: Boolean;
    FirstLabel: Integer;
    FirstGoto: Integer;
    InsideTbc: Boolean;
    Block: TBlock;
    Stmt: TStmt;           // loop statement (for 'break')
  end;

  TFuncScope = class
  public
    Decl: TFuncDecl;
    Prev: TFuncScope;
    Act: array of TActEntry;
    NAct: Integer;
    Blocks: array of TBlockScope;
    NBlocks: Integer;
    Labels: array of TLabelRec;
    NLabels: Integer;
    Gotos: array of TGotoRec;
    NGotos: Integer;
  end;

  PBlockScope = ^TBlockScope;

  TVarResKind = (rkGlobal, rkLocal, rkUpval, rkConst);

  TVarRes = record
    Kind: TVarResKind;
    GState: Integer;       // -1 preambular, -2 invalidated, >= 0 declaration found
    GConst: Boolean;
    Local: TVarInfo;
    UpIdx: Integer;
    ConstVal: TLuaValue;
  end;

  TParser = class
  public
    L: TLua;
    Lex: TLexer;
    FS: TFuncScope;
    Owner: TObjectList;
    EnvName: TStringObj;
    Level: Integer;
    constructor Create(AL: TLua; const source: RawByteString; const chunkName: string;
                       AOwner: TObjectList);
    destructor Destroy; override;
    function Parse: TFuncDecl;
  private
    // helpers
    function Track(o: TObject): TObject;
    function NewExpr(k: TExprKind; line: Integer): TExpr;
    function NewStmt(k: TStmtKind; line: Integer): TStmt;
    procedure Next; inline;
    function TestNext(t: TTokenKind): Boolean;
    procedure Check(t: TTokenKind);
    procedure CheckNext(t: TTokenKind);
    procedure CheckMatch(what, who: TTokenKind; line: Integer);
    function CheckName: TStringObj;
    procedure SemError(const msg: string);
    procedure SyntaxError(const msg: string);
    procedure EnterLevel;
    procedure LeaveLevel;
    procedure CheckLimit(v, limit: Integer; const what: string);
    // scopes
    function RegLevel(scope: TFuncScope; n: Integer): Integer;
    procedure OpenFunc(decl: TFuncDecl);
    procedure CloseFunc;
    procedure EnterBlock(var bl: TBlockScope; isLoop: Boolean; blk: TBlock);
    procedure LeaveBlock;
    procedure Activate(scope: TFuncScope; const e: TActEntry);
    procedure ActivateLocal(v: TVarInfo);
    function NewLocal(name: TStringObj; kind: TVarKind): TVarInfo;
    function ActiveRegVars(scope: TFuncScope): TVarInfoArray;
    function CurBlock: PBlockScope;
    // variable resolution
    function SearchVar(scope: TFuncScope; name: TStringObj; var res: TVarRes): Boolean;
    function SearchUpvalue(scope: TFuncScope; name: TStringObj): Integer;
    function NewUpvalue(scope: TFuncScope; name: TStringObj; const v: TVarRes): Integer;
    procedure SingleVarAux(scope: TFuncScope; name: TStringObj; var res: TVarRes; base: Boolean);
    function BuildGlobal(name: TStringObj; line: Integer): TExpr;
    function BuildVar(name: TStringObj; line: Integer): TExpr;
    function ConstExpr(constref v: TLuaValue; line: Integer): TExpr;
    // goto / labels
    procedure NewGoto(name: TStringObj; line: Integer; stmt: TStmt);
    procedure CreateLabel(name: TStringObj; line: Integer; last: Boolean; stmt: TStmt);
    procedure SolveGotos(const bl: TBlockScope);
    procedure CloseGoto(g: Integer; const lab: TLabelRec);
    // expressions
    function Expr: TExpr;
    function SubExpr(limit: Integer; var nextOp: TOp; var hasNext: Boolean): TExpr;
    function SimpleExpr: TExpr;
    function SuffixedExp: TExpr;
    function PrimaryExp: TExpr;
    function Constructor_: TExpr;
    function FuncArgs(fn: TExpr; const method: TStringObj; isMethod: Boolean): TExpr;
    function ExprList: TExprArray;
    function Body(isMethod: Boolean; line: Integer): TFuncDecl;
    procedure ParList(decl: TFuncDecl);
    function MakeUnary(op: TOp; e: TExpr; line: Integer): TExpr;
    function MakeBinary(op: TOp; a, b: TExpr; line: Integer): TExpr;
    function Fold(opc: Integer; a, b: TExpr; line: Integer): TExpr;
    function IsNumeral(e: TExpr; var v: TLuaValue): Boolean;
    // statements
    function BlockFollow(withUntil: Boolean): Boolean;
    procedure StatList(blk: TBlock);
    function ParseBlock: TBlock;
    procedure Statement(blk: TBlock);
    procedure AddStmt(blk: TBlock; s: TStmt);
    procedure IfStat(blk: TBlock; line: Integer);
    procedure WhileStat(blk: TBlock; line: Integer);
    procedure RepeatStat(blk: TBlock; line: Integer);
    procedure ForStat(blk: TBlock; line: Integer);
    procedure ForNum(s: TStmt; varname: TStringObj; line: Integer);
    procedure ForList(s: TStmt; indexname: TStringObj; line: Integer);
    procedure ForBody(s: TStmt; var vars: TVarInfoArray; line: Integer);
    procedure FuncStat(blk: TBlock; line: Integer);
    procedure LocalFunc(blk: TBlock; line: Integer);
    procedure LocalStat(blk: TBlock; line: Integer);
    procedure GlobalStatFunc(blk: TBlock; line: Integer);
    procedure GlobalNames(blk: TBlock; defKind: TActKind; line: Integer);
    procedure ExprStat(blk: TBlock; line: Integer);
    procedure RetStat(blk: TBlock; line: Integer);
    function GetVarAttribute(def: TVarKind): TVarKind;
    function GetGlobalAttribute(def: TActKind): TActKind;
    procedure CheckReadonly(e: TExpr);
  end;


{ ===================================================================== }

constructor TParser.Create(AL: TLua; const source: RawByteString; const chunkName: string;
  AOwner: TObjectList);
begin
  L := AL;
  Owner := AOwner;
  Lex := TLexer.Create(AL, source, ChunkIdStr(chunkName));
  EnvName := AL.NewString('_ENV');
end;

destructor TParser.Destroy;
begin
  Lex.Free;
  inherited Destroy;
end;

function TParser.Track(o: TObject): TObject;
begin
  Owner.Add(o);
  Result := o;
end;

function TParser.NewExpr(k: TExprKind; line: Integer): TExpr;
begin
  Result := TExpr.Create;
  Owner.Add(Result);
  Result.Kind := k;
  Result.Line := line;
end;

function TParser.NewStmt(k: TStmtKind; line: Integer): TStmt;
begin
  Result := TStmt.Create;
  Owner.Add(Result);
  Result.Kind := k;
  Result.Line := line;
end;

procedure TParser.Next;
begin
  Lex.Next;
end;

function TParser.TestNext(t: TTokenKind): Boolean;
begin
  Result := Lex.Tok = t;
  if Result then Lex.Next;
end;

procedure TParser.Check(t: TTokenKind);
begin
  if Lex.Tok <> t then
    SyntaxError(Lex.TokenStr(t) + ' expected');
end;

procedure TParser.CheckNext(t: TTokenKind);
begin
  Check(t);
  Lex.Next;
end;

procedure TParser.CheckMatch(what, who: TTokenKind; line: Integer);
begin
  if not TestNext(what) then
  begin
    if line = Lex.Line then
      SyntaxError(Lex.TokenStr(what) + ' expected')
    else
      SyntaxError(Format('%s expected (to close %s at line %d)',
                         [Lex.TokenStr(what), Lex.TokenStr(who), line]));
  end;
end;

function TParser.CheckName: TStringObj;
begin
  Check(tkName);
  Result := Lex.NewStr(RawByteString(Lex.NameVal));
  Lex.Next;
end;

procedure TParser.SemError(const msg: string);
begin
  // reported at the line of the last token consumed, without a 'near' part
  raise ELuaError.CreateMsg(Format('%s:%d: %s', [Lex.ChunkId, Lex.LastLine, msg]));
end;

procedure TParser.SyntaxError(const msg: string);
begin
  Lex.SyntaxError(msg);
end;

procedure TParser.EnterLevel;
begin
  Inc(Level);
  if Level > MAXLEVEL then
    Lex.ErrorAt('C stack overflow', '');
end;

procedure TParser.LeaveLevel;
begin
  Dec(Level);
end;

procedure TParser.CheckLimit(v, limit: Integer; const what: string);
var
  line: Integer;
  where: string;
begin
  if v > limit then
  begin
    line := FS.Decl.LineDefined;
    if line = 0 then where := 'main function'
    else where := Format('function at line %d', [line]);
    SyntaxError(Format('too many %s (limit is %d) in %s', [what, limit, where]));
  end;
end;

{ ===================================================================== }
{ scopes                                                                 }
{ ===================================================================== }

// number of register-occupying variables among the first n active ones
function TParser.RegLevel(scope: TFuncScope; n: Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to n - 1 do
    if (scope.Act[i].Kind = akLocal) and (scope.Act[i].Info.Kind <> vkCtc) then
      Inc(Result);
end;

function TParser.ActiveRegVars(scope: TFuncScope): TVarInfoArray;
var
  i, n: Integer;
begin
  SetLength(Result, scope.NAct);
  n := 0;
  for i := 0 to scope.NAct - 1 do
    if (scope.Act[i].Kind = akLocal) and (scope.Act[i].Info.Kind <> vkCtc) then
    begin
      Result[n] := scope.Act[i].Info;
      Inc(n);
    end;
  SetLength(Result, n);
end;

function TParser.CurBlock: PBlockScope;
begin
  Result := @FS.Blocks[FS.NBlocks - 1];
end;

procedure TParser.OpenFunc(decl: TFuncDecl);
var
  scope: TFuncScope;
begin
  scope := TFuncScope.Create;
  Owner.Add(scope);
  scope.Decl := decl;
  scope.Prev := FS;
  SetLength(scope.Act, 16);
  SetLength(scope.Blocks, 8);
  SetLength(scope.Labels, 8);
  SetLength(scope.Gotos, 8);
  FS := scope;
end;

procedure TParser.CloseFunc;
begin
  FS := FS.Prev;
end;

procedure TParser.EnterBlock(var bl: TBlockScope; isLoop: Boolean; blk: TBlock);
begin
  bl.NAct := FS.NAct;
  bl.IsLoop := isLoop;
  bl.FirstLabel := FS.NLabels;
  bl.FirstGoto := FS.NGotos;
  bl.InsideTbc := (FS.NBlocks > 0) and FS.Blocks[FS.NBlocks - 1].InsideTbc;
  bl.Block := blk;
  bl.Stmt := nil;
  if FS.NBlocks >= Length(FS.Blocks) then
    SetLength(FS.Blocks, FS.NBlocks * 2);
  FS.Blocks[FS.NBlocks] := bl;
  Inc(FS.NBlocks);
end;

procedure TParser.LeaveBlock;
var
  bl: TBlockScope;
begin
  bl := FS.Blocks[FS.NBlocks - 1];
  FS.NAct := bl.NAct;                 // remove block variables
  SolveGotos(bl);
  Dec(FS.NBlocks);
  if FS.NBlocks = 0 then
  begin
    // outermost block of the function: pending gotos have no label
    if bl.FirstGoto < FS.NGotos then
      SemError(Format('no visible label ''%s'' for <goto> at line %d',
                      [FS.Gotos[bl.FirstGoto].Name.ToStr, FS.Gotos[bl.FirstGoto].Line]));
  end;
end;

procedure TParser.Activate(scope: TFuncScope; const e: TActEntry);
begin
  if scope.NAct >= Length(scope.Act) then
    SetLength(scope.Act, scope.NAct * 2);
  scope.Act[scope.NAct] := e;
  Inc(scope.NAct);
end;

function TParser.NewLocal(name: TStringObj; kind: TVarKind): TVarInfo;
begin
  Result := TVarInfo.Create;
  Owner.Add(Result);
  Result.Name := name;
  Result.Kind := kind;
  Result.Owner := FS.Decl;
  Result.Reg := -1;
  Result.ConstVal.Vt := vtNil;
end;

procedure TParser.ActivateLocal(v: TVarInfo);
var
  e: TActEntry;
begin
  e.Name := v.Name;
  e.Kind := akLocal;
  e.Info := v;
  Activate(FS, e);
  if v.Kind <> vkCtc then
    CheckLimit(RegLevel(FS, FS.NAct), MAXVARS, 'local variables');
end;

{ ===================================================================== }
{ variable resolution                                                    }
{ ===================================================================== }

function TParser.SearchVar(scope: TFuncScope; name: TStringObj; var res: TVarRes): Boolean;
var
  i: Integer;
  e: TActEntry;
begin
  for i := scope.NAct - 1 downto 0 do
  begin
    e := scope.Act[i];
    if e.Kind <> akLocal then
    begin
      if e.Name = nil then
      begin
        // collective declaration
        if res.GState < 0 then
        begin
          res.GState := 0;
          res.GConst := e.Kind = akGlobalConst;
        end;
      end
      else if e.Name = name then
      begin
        res.Kind := rkGlobal;
        res.GState := 0;
        res.GConst := e.Kind = akGlobalConst;
        Exit(True);
      end
      else if res.GState = -1 then
        res.GState := -2;
    end
    else if e.Name = name then
    begin
      if e.Info.Kind = vkCtc then
      begin
        res.Kind := rkConst;
        res.ConstVal := e.Info.ConstVal;
      end
      else
      begin
        res.Kind := rkLocal;
        res.Local := e.Info;
      end;
      Exit(True);
    end;
  end;
  Result := False;
end;

function TParser.SearchUpvalue(scope: TFuncScope; name: TStringObj): Integer;
var
  i: Integer;
begin
  for i := 0 to Length(scope.Decl.Upvals) - 1 do
    if scope.Decl.Upvals[i].Name = name then Exit(i);
  Result := -1;
end;

function TParser.NewUpvalue(scope: TFuncScope; name: TStringObj; const v: TVarRes): Integer;
var
  u: TUpvalInfo;
  n: Integer;
  saved: TFuncScope;
begin
  n := Length(scope.Decl.Upvals);
  saved := FS;
  FS := scope;
  CheckLimit(n + 1, MAXUPVAL, 'upvalues');
  FS := saved;
  u := TUpvalInfo.Create;
  Owner.Add(u);
  u.Name := name;
  u.ParentIdx := -1;
  if v.Kind = rkLocal then
  begin
    u.FromLocal := v.Local;
    u.ReadOnly := v.Local.ReadOnly;
  end
  else
  begin
    u.ParentIdx := v.UpIdx;
    u.ReadOnly := scope.Prev.Decl.Upvals[v.UpIdx].ReadOnly;
  end;
  SetLength(scope.Decl.Upvals, n + 1);
  scope.Decl.Upvals[n] := u;
  Result := n;
end;

procedure TParser.SingleVarAux(scope: TFuncScope; name: TStringObj; var res: TVarRes; base: Boolean);
var
  idx: Integer;
begin
  if SearchVar(scope, name, res) then
  begin
    if (not base) and (res.Kind = rkLocal) then
    begin
      res.Local.Captured := True;
      if res.Local.Kind = vkVarargParam then res.Local.NeedTable := True;
    end;
    Exit;
  end;
  idx := SearchUpvalue(scope, name);
  if idx < 0 then
  begin
    if scope.Prev <> nil then
      SingleVarAux(scope.Prev, name, res, False);
    if res.Kind in [rkLocal, rkUpval] then
      idx := NewUpvalue(scope, name, res)
    else
      Exit;   // global or constant
  end;
  res.Kind := rkUpval;
  res.UpIdx := idx;
end;

function TParser.ConstExpr(constref v: TLuaValue; line: Integer): TExpr;
begin
  case v.Vt of
    vtNil: Result := NewExpr(ekNil, line);
    vtBool: if v.B then Result := NewExpr(ekTrue, line) else Result := NewExpr(ekFalse, line);
    vtInt: begin Result := NewExpr(ekInt, line); Result.IntVal := v.I; end;
    vtFlt: begin Result := NewExpr(ekFlt, line); Result.FltVal := v.N; end;
  else
    begin
      Result := NewExpr(ekStr, line);
      Result.StrVal := v.S;
    end;
  end;
end;

function TParser.BuildGlobal(name: TStringObj; line: Integer): TExpr;
var
  res: TVarRes;
  env, key: TExpr;
begin
  res.Kind := rkGlobal;
  res.GState := -1;
  res.GConst := False;
  SingleVarAux(FS, EnvName, res, True);
  case res.Kind of
    rkGlobal:
      SemError(Format('_ENV is global when accessing variable ''%s''', [name.ToStr]));
    rkLocal: begin
      env := NewExpr(ekLocal, line);
      env.Variable := res.Local;
      if res.Local.Kind = vkVarargParam then res.Local.NeedTable := True;
    end;
    rkUpval: begin
      env := NewExpr(ekUpval, line);
      env.UpIdx := res.UpIdx;
    end;
  else
    env := ConstExpr(res.ConstVal, line);
  end;
  key := NewExpr(ekStr, line);
  key.StrVal := name;
  Result := NewExpr(ekIndex, line);
  Result.A := env;
  Result.B := key;
  Result.IsGlobal := True;
  Result.DisplayName := name.ToStr;
end;

function TParser.BuildVar(name: TStringObj; line: Integer): TExpr;
var
  res: TVarRes;
begin
  res.Kind := rkGlobal;
  res.GState := -1;
  res.GConst := False;
  SingleVarAux(FS, name, res, True);
  case res.Kind of
    rkLocal: begin
      Result := NewExpr(ekLocal, line);
      Result.Variable := res.Local;
      Result.DisplayName := name.ToStr;
      Result.ReadOnly := res.Local.ReadOnly;
    end;
    rkUpval: begin
      Result := NewExpr(ekUpval, line);
      Result.UpIdx := res.UpIdx;
      Result.DisplayName := name.ToStr;
      Result.ReadOnly := FS.Decl.Upvals[res.UpIdx].ReadOnly;
    end;
    rkConst: begin
      Result := ConstExpr(res.ConstVal, line);
      Result.ReadOnly := True;
      Result.DisplayName := name.ToStr;
    end;
  else
    begin
      if res.GState = -2 then
        SemError(Format('variable ''%s'' not declared', [name.ToStr]));
      Result := BuildGlobal(name, line);
      if (res.GState >= 0) and res.GConst then
        Result.ReadOnly := True;
    end;
  end;
end;

{ ===================================================================== }
{ goto / labels                                                          }
{ ===================================================================== }

procedure TParser.NewGoto(name: TStringObj; line: Integer; stmt: TStmt);
begin
  if FS.NGotos >= Length(FS.Gotos) then
    SetLength(FS.Gotos, FS.NGotos * 2);
  FS.Gotos[FS.NGotos].Name := name;
  FS.Gotos[FS.NGotos].Line := line;
  FS.Gotos[FS.NGotos].NAct := FS.NAct;
  FS.Gotos[FS.NGotos].Stmt := stmt;
  Inc(FS.NGotos);
end;

procedure TParser.CreateLabel(name: TStringObj; line: Integer; last: Boolean; stmt: TStmt);
var
  i, n: Integer;
begin
  // check repeated labels in the whole function
  for i := 0 to FS.NLabels - 1 do
    if FS.Labels[i].Name = name then
      SemError(Format('label ''%s'' already defined on line %d', [name.ToStr, FS.Labels[i].Line]));
  if FS.NLabels >= Length(FS.Labels) then
    SetLength(FS.Labels, FS.NLabels * 2);
  FS.Labels[FS.NLabels].Name := name;
  FS.Labels[FS.NLabels].Line := line;
  if last then
    n := CurBlock^.NAct   // locals are already out of scope
  else
    n := FS.NAct;
  FS.Labels[FS.NLabels].NAct := n;
  FS.Labels[FS.NLabels].Stmt := stmt;
  stmt.NActVar := RegLevel(FS, n);
  Inc(FS.NLabels);
end;

procedure TParser.CloseGoto(g: Integer; const lab: TLabelRec);
var
  gt: TGotoRec;
  vname: string;
  i: Integer;
begin
  gt := FS.Gotos[g];
  if gt.NAct < lab.NAct then
  begin
    // jumps into the scope of a local
    if (gt.NAct < Length(FS.Act)) and (FS.Act[gt.NAct].Name <> nil) then
      vname := FS.Act[gt.NAct].Name.ToStr
    else
      vname := '*';
    SemError(Format('<goto %s> at line %d jumps into the scope of ''%s''',
                    [gt.Name.ToStr, gt.Line, vname]));
  end;
  gt.Stmt.Target := lab.Stmt;
  for i := g to FS.NGotos - 2 do
    FS.Gotos[i] := FS.Gotos[i + 1];
  Dec(FS.NGotos);
end;

procedure TParser.SolveGotos(const bl: TBlockScope);
var
  igt, j: Integer;
  found: Integer;
begin
  igt := bl.FirstGoto;
  while igt < FS.NGotos do
  begin
    found := -1;
    for j := bl.FirstLabel to FS.NLabels - 1 do
      if FS.Labels[j].Name = FS.Gotos[igt].Name then
      begin
        found := j;
        Break;
      end;
    if found >= 0 then
      CloseGoto(igt, FS.Labels[found])
    else
    begin
      FS.Gotos[igt].NAct := bl.NAct;   // adjust 'goto' for the outer block
      Inc(igt);
    end;
  end;
  FS.NLabels := bl.FirstLabel;
end;

{ ===================================================================== }
{ expressions                                                            }
{ ===================================================================== }

function TParser.IsNumeral(e: TExpr; var v: TLuaValue): Boolean;
begin
  case e.Kind of
    ekInt: begin v := LuaInt(e.IntVal); Result := True; end;
    ekFlt: begin v := LuaNum(e.FltVal); Result := True; end;
  else
    Result := False;
  end;
end;

// constant folding of arithmetic/bitwise operations on numerals
function TParser.Fold(opc: Integer; a, b: TExpr; line: Integer): TExpr;
var
  va, vb, res: TLuaValue;
  r: TArithResult;
begin
  Result := nil;
  if not IsNumeral(a, va) then Exit;
  if (b = nil) then
    vb := va
  else if not IsNumeral(b, vb) then Exit;
  case opc of
    OP_DIV, OP_IDIV, OP_MOD:
      if ((vb.Vt = vtInt) and (vb.I = 0)) or ((vb.Vt = vtFlt) and (vb.N = 0)) then Exit;
  end;
  r := ArithNum(opc, va, vb, res);
  if r <> arOk then Exit;
  if res.Vt = vtFlt then
  begin
    // folds neither NaN nor 0.0 (to avoid problems with -0.0)
    if IsNaN(res.N) or (res.N = 0) then Exit;
    Result := NewExpr(ekFlt, line);
    Result.FltVal := res.N;
  end
  else
  begin
    Result := NewExpr(ekInt, line);
    Result.IntVal := res.I;
  end;
end;

function TParser.MakeUnary(op: TOp; e: TExpr; line: Integer): TExpr;
begin
  Result := nil;
  case op of
    opNeg: Result := Fold(OP_UNM, e, nil, line);
    opBNot: Result := Fold(OP_BNOT, e, nil, line);
    opNot:
      case e.Kind of
        ekNil, ekFalse: Result := NewExpr(ekTrue, line);
        ekTrue, ekInt, ekFlt, ekStr: Result := NewExpr(ekFalse, line);
      end;
  end;
  if Result = nil then
  begin
    Result := NewExpr(ekUn, line);
    Result.Op := op;
    Result.A := e;
  end;
end;

function TParser.MakeBinary(op: TOp; a, b: TExpr; line: Integer): TExpr;
var
  opc: Integer;
begin
  Result := nil;
  opc := -1;
  case op of
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
    opShr: opc := OP_SHR;
  end;
  if opc >= 0 then
    Result := Fold(opc, a, b, line);
  if Result = nil then
  begin
    Result := NewExpr(ekBin, line);
    Result.Op := op;
    Result.A := a;
    Result.B := b;
  end;
end;

function TParser.Expr: TExpr;
var
  nextOp: TOp;
  hasNext: Boolean;
begin
  Result := SubExpr(0, nextOp, hasNext);
end;

function BinOpOf(t: TTokenKind; var op: TOp; var left, right: Integer): Boolean;
begin
  Result := True;
  case t of
    tkPlus: begin op := opAdd; left := 10; right := 10; end;
    tkMinus: begin op := opSub; left := 10; right := 10; end;
    tkStar: begin op := opMul; left := 11; right := 11; end;
    tkPercent: begin op := opMod; left := 11; right := 11; end;
    tkCaret: begin op := opPow; left := 14; right := 13; end;
    tkSlash: begin op := opDiv; left := 11; right := 11; end;
    tkDblSlash: begin op := opIDiv; left := 11; right := 11; end;
    tkAmp: begin op := opBAnd; left := 6; right := 6; end;
    tkPipe: begin op := opBOr; left := 4; right := 4; end;
    tkTilde: begin op := opBXor; left := 5; right := 5; end;
    tkShl: begin op := opShl; left := 7; right := 7; end;
    tkShr: begin op := opShr; left := 7; right := 7; end;
    tkConcat: begin op := opConcat; left := 9; right := 8; end;
    tkNe: begin op := opNe; left := 3; right := 3; end;
    tkEq: begin op := opEq; left := 3; right := 3; end;
    tkLt: begin op := opLt; left := 3; right := 3; end;
    tkLe: begin op := opLe; left := 3; right := 3; end;
    tkGt: begin op := opGt; left := 3; right := 3; end;
    tkGe: begin op := opGe; left := 3; right := 3; end;
    tkAnd: begin op := opAnd; left := 2; right := 2; end;
    tkOr: begin op := opOr; left := 1; right := 1; end;
  else
    Result := False;
  end;
end;

// subexpr -> (simpleexp | unop subexpr) { binop subexpr }
function TParser.SubExpr(limit: Integer; var nextOp: TOp; var hasNext: Boolean): TExpr;
var
  op, nop: TOp;
  hasNop: Boolean;
  left, right: Integer;
  line: Integer;
  e2: TExpr;
  uop: TOp;
  isUnary: Boolean;
begin
  EnterLevel;
  isUnary := True;
  case Lex.Tok of
    tkNot: uop := opNot;
    tkMinus: uop := opNeg;
    tkTilde: uop := opBNot;
    tkHash: uop := opLen;
  else
    isUnary := False;
  end;
  if isUnary then
  begin
    line := Lex.Line;
    Next;
    Result := SubExpr(12, nop, hasNop);
    Result := MakeUnary(uop, Result, line);
  end
  else
    Result := SimpleExpr;
  // expand while operators have priorities higher than 'limit'
  while BinOpOf(Lex.Tok, op, left, right) and (left > limit) do
  begin
    line := Lex.Line;
    Next;
    e2 := SubExpr(right, nop, hasNop);
    Result := MakeBinary(op, Result, e2, line);
  end;
  hasNext := BinOpOf(Lex.Tok, op, left, right);
  nextOp := op;
  LeaveLevel;
end;

function TParser.PrimaryExp: TExpr;
var
  line: Integer;
  e: TExpr;
begin
  case Lex.Tok of
    tkLParen: begin
      line := Lex.Line;
      Next;
      e := Expr;
      CheckMatch(tkRParen, tkLParen, line);
      Result := NewExpr(ekParen, line);
      Result.A := e;
    end;
    tkName: begin
      line := Lex.Line;
      Result := BuildVar(CheckName, line);
    end;
  else
    SyntaxError('unexpected symbol');
    Result := nil;
  end;
end;

function TParser.ExprList: TExprArray;
var
  n: Integer;
begin
  n := 1;
  SetLength(Result, 1);
  Result[0] := Expr;
  while TestNext(tkComma) do
  begin
    SetLength(Result, n + 1);
    Result[n] := Expr;
    Inc(n);
  end;
end;

function TParser.FuncArgs(fn: TExpr; const method: TStringObj; isMethod: Boolean): TExpr;
var
  line: Integer;
  args: TExprArray;
  e: TExpr;
begin
  line := Lex.Line;
  args := nil;
  case Lex.Tok of
    tkLParen: begin
      Next;
      if Lex.Tok <> tkRParen then
        args := ExprList;
      CheckMatch(tkRParen, tkLParen, line);
    end;
    tkLBrace: begin
      SetLength(args, 1);
      args[0] := Constructor_;
    end;
    tkString: begin
      e := NewExpr(ekStr, line);
      e.StrVal := Lex.StrVal;
      SetLength(args, 1);
      args[0] := e;
      Next;
    end;
  else
    SyntaxError('function arguments expected');
  end;
  if isMethod then
  begin
    Result := NewExpr(ekMethCall, line);
    Result.StrVal := method;
  end
  else
    Result := NewExpr(ekCall, line);
  Result.A := fn;
  Result.Args := args;
end;

function TParser.SuffixedExp: TExpr;
var
  e, key: TExpr;
  name: TStringObj;
begin
  Result := PrimaryExp;
  // a vararg parameter needs a real table unless it is only indexed
  if (Result.Kind = ekLocal) and (Result.Variable.Kind = vkVarargParam) and
     not ((Lex.Tok = tkDot) or (Lex.Tok = tkLBracket)) then
    Result.Variable.NeedTable := True;
  while True do
  begin
    case Lex.Tok of
      tkDot: begin
        Next;
        name := CheckName;
        key := NewExpr(ekStr, Lex.LastLine);
        key.StrVal := name;
        e := NewExpr(ekIndex, Lex.LastLine);
        e.A := Result;
        e.B := key;
        Result := e;
      end;
      tkLBracket: begin
        Next;
        key := Expr;
        CheckNext(tkRBracket);
        e := NewExpr(ekIndex, Lex.LastLine);
        e.A := Result;
        e.B := key;
        Result := e;
      end;
      tkColon: begin
        Next;
        name := CheckName;
        Result := FuncArgs(Result, name, True);
      end;
      tkLParen, tkString, tkLBrace:
        Result := FuncArgs(Result, nil, False);
    else
      Exit;
    end;
  end;
end;

function TParser.Constructor_: TExpr;
var
  line: Integer;
  n: Integer;
  f: TTableField;
  name: TStringObj;
begin
  line := Lex.Line;
  Result := NewExpr(ekTable, line);
  n := 0;
  CheckNext(tkLBrace);
  while Lex.Tok <> tkRBrace do
  begin
    case Lex.Tok of
      tkName:
        if Lex.LookAhead = tkAssign then
        begin
          name := CheckName;
          Next;  // '='
          f.Kind := fkKeyed;
          f.Key := NewExpr(ekStr, Lex.LastLine);
          f.Key.StrVal := name;
          f.Val := Expr;
        end
        else
        begin
          f.Kind := fkList;
          f.Key := nil;
          f.Val := Expr;
        end;
      tkLBracket: begin
        Next;
        f.Kind := fkKeyed;
        f.Key := Expr;
        CheckNext(tkRBracket);
        CheckNext(tkAssign);
        f.Val := Expr;
      end;
    else
      f.Kind := fkList;
      f.Key := nil;
      f.Val := Expr;
    end;
    SetLength(Result.Fields, n + 1);
    Result.Fields[n] := f;
    Inc(n);
    if not (TestNext(tkComma) or TestNext(tkSemi)) then
      Break;
  end;
  Result.EndLine := Lex.Line;
  CheckMatch(tkRBrace, tkLBrace, line);
end;

procedure TParser.ParList(decl: TFuncDecl);
var
  v: TVarInfo;
  np: Integer;
  varargk: Boolean;
begin
  np := Length(decl.Params);
  varargk := False;
  if Lex.Tok <> tkRParen then
  begin
    repeat
      case Lex.Tok of
        tkName: begin
          v := NewLocal(CheckName, vkRegular);
          SetLength(decl.Params, np + 1);
          decl.Params[np] := v;
          Inc(np);
          ActivateLocal(v);
        end;
        tkDots: begin
          varargk := True;
          Next;
          decl.IsVararg := True;
          // a vararg function always has a local for the vararg table (hidden if unnamed)
          if Lex.Tok = tkName then
            v := NewLocal(CheckName, vkVarargParam)
          else
            v := NewLocal(L.NewString('(vararg table)'), vkVarargParam);
          decl.VarargVar := v;
          ActivateLocal(v);
        end;
      else
        SyntaxError('<name> or ''...'' expected');
      end;
    until varargk or not TestNext(tkComma);
  end;
end;

function TParser.Body(isMethod: Boolean; line: Integer): TFuncDecl;
var
  decl: TFuncDecl;
  v: TVarInfo;
  bl: TBlockScope;
begin
  decl := TFuncDecl.Create;
  Owner.Add(decl);
  decl.Parent := FS.Decl;
  decl.LineDefined := line;
  decl.IsMethod := isMethod;
  decl.Source := FS.Decl.Source;
  OpenFunc(decl);
  decl.Body := TBlock.Create;
  Owner.Add(decl.Body);
  EnterBlock(bl, False, decl.Body);
  CheckNext(tkLParen);
  if isMethod then
  begin
    v := NewLocal(L.NewString('self'), vkRegular);
    SetLength(decl.Params, 1);
    decl.Params[0] := v;
    ActivateLocal(v);
  end;
  ParList(decl);
  CheckNext(tkRParen);
  StatList(decl.Body);
  decl.LastLine := Lex.Line;
  CheckMatch(tkEnd, tkFunction, line);
  decl.RetLine := Lex.LastLine;
  LeaveBlock;
  CloseFunc;
  Result := decl;
end;

function TParser.SimpleExpr: TExpr;
var
  line: Integer;
  decl: TFuncDecl;
begin
  line := Lex.Line;
  case Lex.Tok of
    tkFlt: begin
      Result := NewExpr(ekFlt, line);
      Result.FltVal := Lex.FltVal;
    end;
    tkInt: begin
      Result := NewExpr(ekInt, line);
      Result.IntVal := Lex.IntVal;
    end;
    tkString: begin
      Result := NewExpr(ekStr, line);
      Result.StrVal := Lex.StrVal;
    end;
    tkNil: Result := NewExpr(ekNil, line);
    tkTrue: Result := NewExpr(ekTrue, line);
    tkFalse: Result := NewExpr(ekFalse, line);
    tkDots: begin
      if not FS.Decl.IsVararg then
        SyntaxError('cannot use ''...'' outside a vararg function');
      Result := NewExpr(ekVararg, line);
      if FS.Decl.VarargVar <> nil then
      begin
        Result.Variable := FS.Decl.VarargVar;
      end;
    end;
    tkLBrace: begin
      Result := Constructor_;
      Exit;
    end;
    tkFunction: begin
      Next;
      decl := Body(False, Lex.Line);
      Result := NewExpr(ekFunc, Lex.LastLine);
      Result.Func := decl;
      Exit;
    end;
  else
    Result := SuffixedExp;
    Exit;
  end;
  Next;
end;

{ ===================================================================== }
{ statements                                                             }
{ ===================================================================== }

function TParser.BlockFollow(withUntil: Boolean): Boolean;
begin
  case Lex.Tok of
    tkElse, tkElseIf, tkEnd, tkEof: Result := True;
    tkUntil: Result := withUntil;
  else
    Result := False;
  end;
end;

procedure TParser.AddStmt(blk: TBlock; s: TStmt);
var
  n: Integer;
begin
  n := Length(blk.Stmts);
  SetLength(blk.Stmts, n + 1);
  blk.Stmts[n] := s;
end;

procedure TParser.StatList(blk: TBlock);
begin
  while not BlockFollow(True) do
  begin
    if Lex.Tok = tkReturn then
    begin
      Statement(blk);
      blk.LastLine := Lex.LastLine;
      Exit;     // 'return' must be last statement
    end;
    Statement(blk);
  end;
  blk.LastLine := Lex.LastLine;
end;

// block -> statlist (with its own scope)
function TParser.ParseBlock: TBlock;
var
  bl: TBlockScope;
begin
  Result := TBlock.Create;
  Owner.Add(Result);
  EnterBlock(bl, False, Result);
  StatList(Result);
  LeaveBlock;
end;

procedure TParser.CheckReadonly(e: TExpr);
begin
  case e.Kind of
    ekLocal, ekUpval, ekIndex:
      if e.ReadOnly then
        SemError(Format('attempt to assign to const variable ''%s''', [e.DisplayName]));
    ekInt, ekFlt, ekStr, ekNil, ekTrue, ekFalse:
      if e.ReadOnly then
        SemError(Format('attempt to assign to const variable ''%s''', [e.DisplayName]));
  end;
end;

function TParser.GetVarAttribute(def: TVarKind): TVarKind;
var
  attr: string;
begin
  Result := def;
  if TestNext(tkLt) then
  begin
    attr := Lex.NameVal;
    CheckName;
    CheckNext(tkGt);
    if attr = 'const' then Result := vkConst
    else if attr = 'close' then Result := vkClose
    else SemError(Format('unknown attribute ''%s''', [attr]));
  end;
end;

function TParser.GetGlobalAttribute(def: TActKind): TActKind;
var
  k: TVarKind;
begin
  Result := def;
  if Lex.Tok = tkLt then
  begin
    k := GetVarAttribute(vkRegular);
    if k = vkClose then
      SemError('global variables cannot be to-be-closed');
    if k = vkConst then Result := akGlobalConst;
  end;
end;

procedure TParser.IfStat(blk: TBlock; line: Integer);
var
  s: TStmt;
  n: Integer;
  b: TBlock;
begin
  s := NewStmt(skIf, line);
  n := 0;
  repeat
    Next;   // skip IF / ELSEIF
    SetLength(s.Exprs, n + 1);
    s.Exprs[n] := Expr;
    CheckNext(tkThen);
    b := ParseBlock;
    SetLength(s.Blocks, n + 1);
    s.Blocks[n] := b;
    Inc(n);
  until Lex.Tok <> tkElseIf;
  if TestNext(tkElse) then
    s.ElseBlock := ParseBlock;
  s.EndLine := Lex.Line;
  CheckMatch(tkEnd, tkIf, line);
  AddStmt(blk, s);
end;

procedure TParser.WhileStat(blk: TBlock; line: Integer);
var
  s: TStmt;
  bl: TBlockScope;
  dummy: TBlock;
begin
  Next;
  s := NewStmt(skWhile, line);
  dummy := TBlock.Create;
  Owner.Add(dummy);
  EnterBlock(bl, True, dummy);
  CurBlock^.Stmt := s;
  SetLength(s.Exprs, 1);
  s.Exprs[0] := Expr;
  CheckNext(tkDo);
  s.Body := ParseBlock;
  s.EndLine := Lex.Line;
  CheckMatch(tkEnd, tkWhile, line);
  LeaveBlock;
  AddStmt(blk, s);
end;

procedure TParser.RepeatStat(blk: TBlock; line: Integer);
var
  s: TStmt;
  bl1, bl2: TBlockScope;
  dummy: TBlock;
begin
  s := NewStmt(skRepeat, line);
  dummy := TBlock.Create;
  Owner.Add(dummy);
  EnterBlock(bl1, True, dummy);     // loop block
  CurBlock^.Stmt := s;
  s.Body := TBlock.Create;
  Owner.Add(s.Body);
  EnterBlock(bl2, False, s.Body);   // scope block
  Next;
  StatList(s.Body);
  s.EndLine := Lex.Line;
  CheckMatch(tkUntil, tkRepeat, line);
  SetLength(s.Exprs, 1);
  s.Exprs[0] := Expr;               // condition inside the scope block
  LeaveBlock;
  LeaveBlock;
  AddStmt(blk, s);
end;

procedure TParser.ForBody(s: TStmt; var vars: TVarInfoArray; line: Integer);
var
  bl: TBlockScope;
  i: Integer;
  dummy: TBlock;
begin
  CheckNext(tkDo);
  dummy := TBlock.Create;
  Owner.Add(dummy);
  EnterBlock(bl, False, dummy);     // scope for declared variables
  for i := 0 to Length(vars) - 1 do
    ActivateLocal(vars[i]);
  s.Vars := vars;
  s.Body := ParseBlock;
  LeaveBlock;
end;

procedure TParser.ForNum(s: TStmt; varname: TStringObj; line: Integer);
var
  h1, h2, cv: TVarInfo;
  vars: TVarInfoArray;
begin
  s.Kind := skForNum;
  h1 := NewLocal(L.NewString('(for state)'), vkRegular);
  h2 := NewLocal(L.NewString('(for state)'), vkRegular);
  cv := NewLocal(varname, vkConst);   // control variable is read-only
  CheckNext(tkAssign);
  SetLength(s.Exprs, 2);
  s.Exprs[0] := Expr;
  CheckNext(tkComma);
  s.Exprs[1] := Expr;
  if TestNext(tkComma) then
  begin
    SetLength(s.Exprs, 3);
    s.Exprs[2] := Expr;
  end;
  ActivateLocal(h1);
  ActivateLocal(h2);
  SetLength(s.Hidden, 2);
  s.Hidden[0] := h1;
  s.Hidden[1] := h2;
  SetLength(vars, 1);
  vars[0] := cv;
  s.EndLine := line;
  ForBody(s, vars, line);
end;

procedure TParser.ForList(s: TStmt; indexname: TStringObj; line: Integer);
var
  h1, h2, h3: TVarInfo;
  vars: TVarInfoArray;
  n: Integer;
begin
  s.Kind := skForIn;
  h1 := NewLocal(L.NewString('(for state)'), vkRegular);
  h2 := NewLocal(L.NewString('(for state)'), vkRegular);
  h3 := NewLocal(L.NewString('(for state)'), vkClose);
  SetLength(vars, 1);
  vars[0] := NewLocal(indexname, vkConst);   // control variable
  n := 1;
  while TestNext(tkComma) do
  begin
    SetLength(vars, n + 1);
    vars[n] := NewLocal(CheckName, vkRegular);
    Inc(n);
  end;
  CheckNext(tkIn);
  line := Lex.Line;   // calls to the iterator are reported at the line of the first expression
  s.Line := line;
  s.Exprs := ExprList;
  ActivateLocal(h1);
  ActivateLocal(h2);
  ActivateLocal(h3);
  SetLength(s.Hidden, 3);
  s.Hidden[0] := h1;
  s.Hidden[1] := h2;
  s.Hidden[2] := h3;
  CurBlock^.InsideTbc := True;   // the closing value is to-be-closed
  ForBody(s, vars, line);
end;

procedure TParser.ForStat(blk: TBlock; line: Integer);
var
  s: TStmt;
  bl: TBlockScope;
  dummy: TBlock;
  varname: TStringObj;
begin
  s := NewStmt(skForNum, line);
  dummy := TBlock.Create;
  Owner.Add(dummy);
  EnterBlock(bl, True, dummy);
  CurBlock^.Stmt := s;
  Next;   // skip 'for'
  varname := CheckName;
  case Lex.Tok of
    tkAssign: ForNum(s, varname, line);
    tkComma, tkIn: ForList(s, varname, line);
  else
    SyntaxError('''='' or ''in'' expected');
  end;
  s.EndLine := Lex.Line;
  CheckMatch(tkEnd, tkFor, line);
  LeaveBlock;
  AddStmt(blk, s);
end;

procedure TParser.FuncStat(blk: TBlock; line: Integer);
var
  s: TStmt;
  target, key, e: TExpr;
  isMethod: Boolean;
  name: TStringObj;
  decl: TFuncDecl;
  fexp: TExpr;
begin
  Next;   // skip FUNCTION
  // funcname -> NAME {fieldsel} [':' NAME]
  target := BuildVar(CheckName, Lex.LastLine);
  isMethod := False;
  while (Lex.Tok = tkDot) or (Lex.Tok = tkColon) do
  begin
    if Lex.Tok = tkColon then isMethod := True;
    Next;
    name := CheckName;
    key := NewExpr(ekStr, Lex.LastLine);
    key.StrVal := name;
    e := NewExpr(ekIndex, Lex.LastLine);
    e.A := target;
    e.B := key;
    target := e;
    if isMethod then Break;
  end;
  CheckReadonly(target);
  decl := Body(isMethod, line);
  fexp := NewExpr(ekFunc, Lex.LastLine);
  fexp.Func := decl;
  s := NewStmt(skAssign, line);
  SetLength(s.Targets, 1);
  s.Targets[0] := target;
  SetLength(s.Exprs, 1);
  s.Exprs[0] := fexp;
  s.EndLine := line;     // definition "happens" in the first line
  AddStmt(blk, s);
end;

procedure TParser.LocalFunc(blk: TBlock; line: Integer);
var
  s: TStmt;
  v: TVarInfo;
begin
  v := NewLocal(CheckName, vkRegular);
  ActivateLocal(v);       // function visible inside its own body
  s := NewStmt(skLocalFunc, line);
  SetLength(s.Vars, 1);
  s.Vars[0] := v;
  s.Func := Body(False, Lex.Line);
  s.EndLine := Lex.LastLine;
  AddStmt(blk, s);
end;

procedure TParser.LocalStat(blk: TBlock; line: Integer);
var
  s: TStmt;
  defKind, kind: TVarKind;
  vars: TVarInfoArray;
  nvars, i, toclose: Integer;
  last: TVarInfo;
  v: TLuaValue;
  e: TExpr;
begin
  s := NewStmt(skLocal, line);
  defKind := GetVarAttribute(vkRegular);
  nvars := 0;
  toclose := -1;
  repeat
    SetLength(vars, nvars + 1);
    vars[nvars] := NewLocal(CheckName, vkRegular);
    kind := GetVarAttribute(defKind);
    vars[nvars].Kind := kind;
    if kind = vkClose then
    begin
      if toclose <> -1 then
        SemError('multiple to-be-closed variables in local list');
      toclose := nvars;
    end;
    Inc(nvars);
  until not TestNext(tkComma);
  if TestNext(tkAssign) then
    s.Exprs := ExprList;
  s.EndLine := Lex.LastLine;
  last := vars[nvars - 1];
  // compile-time constant?
  if (Length(s.Exprs) = nvars) and (last.Kind = vkConst) then
  begin
    e := s.Exprs[nvars - 1];
    case e.Kind of
      ekNil: v := LuaNil;
      ekTrue: v := LuaBool(True);
      ekFalse: v := LuaBool(False);
      ekInt: v := LuaInt(e.IntVal);
      ekFlt: v := LuaNum(e.FltVal);
      ekStr: v := LuaStr(e.StrVal);
    else
      e := nil;
    end;
    if e <> nil then
    begin
      last.Kind := vkCtc;
      last.ConstVal := v;
    end;
  end;
  s.Vars := vars;
  for i := 0 to nvars - 1 do
    ActivateLocal(vars[i]);
  if toclose >= 0 then
    CurBlock^.InsideTbc := True;
  AddStmt(blk, s);
end;

procedure TParser.GlobalNames(blk: TBlock; defKind: TActKind; line: Integer);
var
  s: TStmt;
  names: array of TStringObj;
  kinds: array of TActKind;
  n, i: Integer;
  e: TActEntry;
begin
  n := 0;
  repeat
    SetLength(names, n + 1);
    SetLength(kinds, n + 1);
    names[n] := CheckName;
    kinds[n] := GetGlobalAttribute(defKind);
    Inc(n);
  until not TestNext(tkComma);
  s := NewStmt(skAssign, line);
  if TestNext(tkAssign) then
  begin
    SetLength(s.Targets, n);
    for i := 0 to n - 1 do
      s.Targets[i] := BuildGlobal(names[i], line);
    s.Exprs := ExprList;
    s.CheckNil := True;
    s.EndLine := Lex.LastLine;
    AddStmt(blk, s);
  end;
  for i := 0 to n - 1 do
  begin
    e.Name := names[i];
    e.Kind := kinds[i];
    e.Info := nil;
    Activate(FS, e);
  end;
end;

procedure TParser.GlobalStatFunc(blk: TBlock; line: Integer);
var
  defKind: TActKind;
  e: TActEntry;
  fname: TStringObj;
  s: TStmt;
  target: TExpr;
  decl: TFuncDecl;
  fexp: TExpr;
begin
  Next;   // skip 'global'
  if TestNext(tkFunction) then
  begin
    fname := CheckName;
    e.Name := fname;
    e.Kind := akGlobal;
    e.Info := nil;
    Activate(FS, e);
    target := BuildGlobal(fname, line);
    decl := Body(False, Lex.Line);
    fexp := NewExpr(ekFunc, Lex.LastLine);
    fexp.Func := decl;
    s := NewStmt(skAssign, line);
    SetLength(s.Targets, 1);
    s.Targets[0] := target;
    SetLength(s.Exprs, 1);
    s.Exprs[0] := fexp;
    s.CheckNil := True;
    s.EndLine := line;
    AddStmt(blk, s);
  end
  else
  begin
    defKind := GetGlobalAttribute(akGlobal);
    if TestNext(tkStar) then
    begin
      e.Name := nil;
      e.Kind := defKind;
      e.Info := nil;
      Activate(FS, e);
    end
    else
      GlobalNames(blk, defKind, line);
  end;
end;

procedure TParser.ExprStat(blk: TBlock; line: Integer);
var
  s: TStmt;
  e: TExpr;
  targets: TExprArray;
  n, i: Integer;
begin
  e := SuffixedExp;
  if (Lex.Tok = tkAssign) or (Lex.Tok = tkComma) then
  begin
    n := 1;
    SetLength(targets, 1);
    targets[0] := e;
    while True do
    begin
      if not (targets[n - 1].Kind in [ekLocal, ekUpval, ekIndex, ekInt, ekFlt, ekStr, ekNil, ekTrue, ekFalse]) then
        SyntaxError('syntax error');
      CheckReadonly(targets[n - 1]);
      if (targets[n - 1].Kind = ekIndex) and (targets[n - 1].A.Kind = ekLocal) and
         (targets[n - 1].A.Variable.Kind = vkVarargParam) then
        targets[n - 1].A.Variable.NeedTable := True;
      if TestNext(tkComma) then
      begin
        SetLength(targets, n + 1);
        targets[n] := SuffixedExp;
        Inc(n);
        EnterLevel;
      end
      else
        Break;
    end;
    for i := 1 to n - 1 do LeaveLevel;
    CheckNext(tkAssign);
    s := NewStmt(skAssign, line);
    s.Targets := targets;
    s.Exprs := ExprList;
    s.EndLine := Lex.LastLine;
    AddStmt(blk, s);
  end
  else
  begin
    if not (e.Kind in [ekCall, ekMethCall]) then
      SyntaxError('syntax error');
    s := NewStmt(skCall, line);
    SetLength(s.Exprs, 1);
    s.Exprs[0] := e;
    s.EndLine := Lex.LastLine;
    AddStmt(blk, s);
  end;
end;

procedure TParser.RetStat(blk: TBlock; line: Integer);
var
  s: TStmt;
begin
  s := NewStmt(skReturn, line);
  if not (BlockFollow(True) or (Lex.Tok = tkSemi)) then
    s.Exprs := ExprList;
  s.TailCall := (Length(s.Exprs) = 1) and (s.Exprs[0].Kind in [ekCall, ekMethCall]) and
                not CurBlock^.InsideTbc;
  TestNext(tkSemi);
  s.EndLine := Lex.LastLine;
  AddStmt(blk, s);
end;

procedure TParser.Statement(blk: TBlock);
var
  line: Integer;
  s: TStmt;
  name: TStringObj;
  i: Integer;
  found: Boolean;
  look: TTokenKind;
begin
  line := Lex.Line;
  EnterLevel;
  case Lex.Tok of
    tkSemi: Next;
    tkIf: IfStat(blk, line);
    tkWhile: WhileStat(blk, line);
    tkDo: begin
      Next;
      s := NewStmt(skDo, line);
      s.Body := ParseBlock;
      s.EndLine := Lex.Line;
      CheckMatch(tkEnd, tkDo, line);
      AddStmt(blk, s);
    end;
    tkFor: ForStat(blk, line);
    tkRepeat: RepeatStat(blk, line);
    tkFunction: FuncStat(blk, line);
    tkLocal: begin
      Next;
      if TestNext(tkFunction) then LocalFunc(blk, line) else LocalStat(blk, line);
    end;
    tkDblColon: begin
      Next;
      name := CheckName;
      CheckNext(tkDblColon);
      while (Lex.Tok = tkSemi) or (Lex.Tok = tkDblColon) do
        Statement(blk);   // skip other no-op statements
      s := NewStmt(skLabel, line);
      s.LabelName := name;
      CreateLabel(name, line, BlockFollow(False), s);
      AddStmt(blk, s);
    end;
    tkReturn: begin
      Next;
      RetStat(blk, line);
    end;
    tkBreak: begin
      found := False;
      for i := FS.NBlocks - 1 downto 0 do
        if FS.Blocks[i].IsLoop then
        begin
          found := True;
          s := NewStmt(skBreak, line);
          s.BreakTarget := FS.Blocks[i].Stmt;
          s.Vars := ActiveRegVars(FS);
          s.NActVar := RegLevel(FS, FS.Blocks[i].NAct);
          Break;
        end;
      if not found then
        SyntaxError('break outside loop');
      Next;
      AddStmt(blk, s);
    end;
    tkGoto: begin
      Next;
      name := CheckName;
      s := NewStmt(skGoto, line);
      s.LabelName := name;
      s.Vars := ActiveRegVars(FS);
      NewGoto(name, line, s);
      AddStmt(blk, s);
    end;
  else
    begin
      if (Lex.Tok = tkName) and (Lex.NameVal = 'global') then
      begin
        look := Lex.LookAhead;
        if (look = tkLt) or (look = tkName) or (look = tkStar) or (look = tkFunction) then
        begin
          GlobalStatFunc(blk, line);
          LeaveLevel;
          Exit;
        end;
      end;
      ExprStat(blk, line);
    end;
  end;
  LeaveLevel;
end;

function TParser.Parse: TFuncDecl;
var
  decl: TFuncDecl;
  u: TUpvalInfo;
  bl: TBlockScope;
begin
  decl := TFuncDecl.Create;
  Owner.Add(decl);
  decl.IsVararg := True;
  decl.LineDefined := 0;
  decl.Source := nil;
  OpenFunc(decl);
  decl.Body := TBlock.Create;
  Owner.Add(decl.Body);
  EnterBlock(bl, False, decl.Body);
  // the environment upvalue
  u := TUpvalInfo.Create;
  Owner.Add(u);
  u.Name := EnvName;
  u.ParentIdx := -1;
  SetLength(decl.Upvals, 1);
  decl.Upvals[0] := u;
  StatList(decl.Body);
  Check(tkEof);
  decl.LastLine := Lex.Line;
  decl.RetLine := Lex.LastLine;
  LeaveBlock;
  CloseFunc;
  Result := decl;
end;

function ParseChunk(L: TLua; const source: RawByteString; const chunkName: string;
                    out owner: TObjectList): TFuncDecl;
var
  p: TParser;
begin
  owner := TObjectList.Create(True);
  try
    p := TParser.Create(L, source, chunkName, owner);
    try
      Result := p.Parse;
    finally
      p.Free;
    end;
  except
    owner.Free;
    owner := nil;
    raise;
  end;
end;

end.
