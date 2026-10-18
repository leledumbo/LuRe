unit luaast;

{$mode objfpc}{$H+}

// Syntax tree produced by the parser (luaparse) and consumed by the code
// generator (luagen). Names are already resolved: every variable reference
// points to its declaration, upvalues are numbered per function.

interface

uses
  SysUtils, luacore;

type
  // syntax tree nodes: pooled, owned by a TAstOwner and freed all together
  TAstNode = class(TPooledObject)
  public
    procedure FreeInstance; override;
  end;

  TAstOwner = class
  private
    Items: array of TObject;
    Count: Integer;
  public
    procedure Add(o: TObject); inline;
    destructor Destroy; override;
  end;

  TVarKind = (
    vkRegular,      // ordinary local
    vkConst,        // <const>
    vkClose,        // <close>
    vkVarargParam,  // named vararg parameter (read-only table)
    vkCtc);         // compile-time constant: has no register

  TFuncDecl = class;
  TVarInfo = class;
  TVarInfoArray = array of TVarInfo;

  // a local variable (user declared or internal)
  TVarInfo = class(TAstNode)
  public
    Name: TStringObj;
    Kind: TVarKind;
    Captured: Boolean;     // used as upvalue by an inner function
    Reg: Integer;          // register, assigned by the code generator
    ConstVal: TLuaValue;   // value of a compile-time constant
    Owner: TFuncDecl;
    NeedTable: Boolean;    // vararg parameter used other than as t[k] / t.k (read)
    function ReadOnly: Boolean;
  end;

  TUpvalInfo = class(TAstNode)
  public
    Name: TStringObj;
    FromLocal: TVarInfo;   // captures a local of the enclosing function...
    ParentIdx: Integer;    // ...or an upvalue of it
    ReadOnly: Boolean;
  end;

  TOp = (
    opAdd, opSub, opMul, opMod, opPow, opDiv, opIDiv,
    opBAnd, opBOr, opBXor, opShl, opShr,
    opConcat, opNe, opEq, opLt, opLe, opGt, opGe, opAnd, opOr,
    opNeg, opBNot, opNot, opLen);

  TExprKind = (
    ekNil, ekTrue, ekFalse, ekInt, ekFlt, ekStr, ekVararg, ekFunc,
    ekLocal, ekUpval, ekIndex, ekCall, ekMethCall, ekBin, ekUn, ekTable,
    ekParen);

  TExpr = class;

  TFieldKind = (fkList, fkKeyed);

  TTableField = record
    Kind: TFieldKind;
    Key: TExpr;
    Val: TExpr;
  end;

  TExprArray = array of TExpr;

  TExpr = class(TAstNode)
  public
    Kind: TExprKind;
    Line: Integer;          // line used for the main instruction of the node
    IntVal: Int64;
    FltVal: Double;
    StrVal: TStringObj;     // string literal / method name
    Op: TOp;
    A, B: TExpr;            // operands; index: A = object, B = key
    Args: TExprArray;       // call arguments
    Fields: array of TTableField;
    Func: TFuncDecl;
    Variable: TVarInfo;     // ekLocal
    UpIdx: Integer;         // ekUpval
    IsGlobal: Boolean;      // ekIndex written as a global name
    ReadOnly: Boolean;      // assignment target that cannot be assigned
    DisplayName: TStringObj; // variable name for messages
    EndLine: Integer;       // last line (tables, functions)
    destructor Destroy; override;
  end;

  TBlock = class;

  TStmtKind = (
    skLocal, skAssign, skCall, skDo, skWhile, skRepeat, skIf, skForNum,
    skForIn, skLocalFunc, skReturn, skBreak, skGoto, skLabel);

  TStmt = class(TAstNode)
  public
    Kind: TStmtKind;
    Line: Integer;
    EndLine: Integer;
    Vars: TVarInfoArray;           // declared variables / loop variables
    Targets: TExprArray;           // assignment targets
    Exprs: TExprArray;             // values / call expression / conditions
    Body: TBlock;
    Blocks: array of TBlock;       // 'if' branches (Exprs = conditions)
    ElseBlock: TBlock;
    Func: TFuncDecl;               // local function
    // goto / label
    LabelName: TStringObj;
    Target: TStmt;                 // resolved label of a goto
    NActVar: Integer;              // register-variables active at the goto/label
    NeedLoopVar: Boolean;
    // loops: hidden state variables
    Hidden: TVarInfoArray;
    BreakTarget: TStmt;            // for 'break': the loop statement
    TailCall: Boolean;
    CheckNil: Boolean;             // global declaration with initializer: target must be nil
    destructor Destroy; override;
  end;

  TBlock = class(TAstNode)
  public
    Stmts: array of TStmt;
    HasTbc: Boolean;
    HasUpvals: Boolean;
    NActVarStart: Integer;
    LastLine: Integer;      // line of the last token of the block
    destructor Destroy; override;
  end;

  TFuncDecl = class(TAstNode)
  public
    Parent: TFuncDecl;
    Params: array of TVarInfo;
    IsVararg: Boolean;
    VarargVar: TVarInfo;           // named vararg parameter
    Body: TBlock;
    Upvals: array of TUpvalInfo;
    LineDefined: Integer;
    LastLine: Integer;
    RetLine: Integer;       // line of the implicit final return
    IsMethod: Boolean;
    Source: TStringObj;
    destructor Destroy; override;
  end;

implementation

procedure TAstNode.FreeInstance;
begin
  ReleaseRaw;   // the destructors below release the dynamic arrays
end;

procedure TAstOwner.Add(o: TObject);
begin
  if Count >= Length(Items) then SetLength(Items, Length(Items) * 2 + 256);
  Items[Count] := o;
  Inc(Count);
end;

destructor TAstOwner.Destroy;
var
  i: Integer;
begin
  for i := Count - 1 downto 0 do Items[i].Free;
  inherited Destroy;
end;

destructor TExpr.Destroy;
begin
  Args := nil;
  Fields := nil;
  inherited Destroy;
end;

destructor TStmt.Destroy;
begin
  Vars := nil;
  Targets := nil;
  Exprs := nil;
  Blocks := nil;
  Hidden := nil;
  inherited Destroy;
end;

destructor TBlock.Destroy;
begin
  Stmts := nil;
  inherited Destroy;
end;

destructor TFuncDecl.Destroy;
begin
  Params := nil;
  Upvals := nil;
  inherited Destroy;
end;

function TVarInfo.ReadOnly: Boolean;
begin
  Result := Kind <> vkRegular;
end;

end.
