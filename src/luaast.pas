unit luaast;

{$mode objfpc}{$H+}

// Syntax tree produced by the parser (luaparse) and consumed by the code
// generator (luagen). Names are already resolved: every variable reference
// points to its declaration, upvalues are numbered per function.

interface

uses
  SysUtils, luacore;

type
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
  TVarInfo = class(TObject)
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

  TUpvalInfo = class
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

  TExpr = class
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
    DisplayName: string;    // variable name for messages
    EndLine: Integer;       // last line (tables, functions)
  end;

  TBlock = class;

  TStmtKind = (
    skLocal, skAssign, skCall, skDo, skWhile, skRepeat, skIf, skForNum,
    skForIn, skLocalFunc, skReturn, skBreak, skGoto, skLabel);

  TStmt = class
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
  end;

  TBlock = class
  public
    Stmts: array of TStmt;
    HasTbc: Boolean;
    HasUpvals: Boolean;
    NActVarStart: Integer;
    LastLine: Integer;      // line of the last token of the block
  end;

  TFuncDecl = class
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
  end;

implementation

function TVarInfo.ReadOnly: Boolean;
begin
  Result := Kind <> vkRegular;
end;

end.
