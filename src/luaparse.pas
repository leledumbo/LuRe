unit luaparse;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, luacore, lualex;

function LuaCompile(L: TLua; const source: RawByteString; const name: string): TFunction;
function LuaDump(L: TLua; f: TFunction; strip: Boolean): RawByteString;
function LuaUndump(L: TLua; const data: RawByteString; const name: string): TFunction;

implementation

type
  TVarKind = (vkLocal, vkConst, vkClose, vkGlobal, vkGlobalConst, vkVararg);

  TVarDesc = record
    Name: TStringObj;
    Kind: TVarKind;
    Reg: Integer;
  end;

  TBlock = record
    PrevIdx: Integer;
    IsLoop: Integer;
    NActVar: Integer;
    FreeReg: Integer;
    ActiveReg: Integer;
    FirstLabel: Integer;
    FirstGoto: Integer;
    HasTbc: Boolean;
  end;

  TLabelDesc = record
    Name: TStringObj;
    PC: Integer;
    NActVar: Integer;
    RegLevel: Integer;
    Line: Integer;
  end;

  TGotoDesc = record
    Name: TStringObj;
    PC: Integer;
    NActVar: Integer;
    RegLevel: Integer;
    Close: Boolean;
    Line: Integer;
  end;

  PGotoDesc = ^TGotoDesc;
  PLabelDesc = ^TLabelDesc;

  TFuncState = class
  public
    L: TLua;
    Prev: TFuncState;
    Proto: TProto;
    Code: array of TInstruction;
    NCode: Integer;
    K: array of TLuaValue;
    NK: Integer;
    Protos: array of TProto;
    NProtos: Integer;
    Upvals: array of TUpvalDesc;
    NUpvals: Integer;
    ActVars: array of TVarDesc;
    NActVar: Integer;
    Blocks: array of TBlock;
    NBlocks: Integer;
    Labels: array of TLabelDesc;
    NLabels: Integer;
    Gotos: array of TGotoDesc;
    NGotos: Integer;
    LocVars: array of TLocVar;
    NLocVars: Integer;
    FreeReg: Integer;
    ActiveReg: Integer;
    VarArgReg: Integer;
    NeedClose: Boolean;
    CurBlock: Integer;
    constructor Create(AL: TLua; APrev: TFuncState; AProto: TProto);
    function Emit(op, a, b, c: Integer): Integer;
    function AddConst(const v: TLuaValue): Integer;
    function AddStr(const s: RawByteString): Integer;
    function AddProto(p: TProto): Integer;
    function AddUpval(name: TStringObj; instack: Boolean; idx: Integer; isConst: Boolean = False): Integer;
    function SearchUpval(name: TStringObj; var isConst: Boolean): Integer;
    function AllocReg: Integer;
    function AllocRegs(n: Integer): Integer;
    procedure EnsureFree(n: Integer);
    procedure FreeTo(reg: Integer);
    procedure OpenBlock(isLoop: Integer);
    procedure AddLocal(name: TStringObj; kind: TVarKind; reg: Integer);
    procedure AddLocVar(name: TStringObj; startpc: Integer; reg: Integer);
    procedure MarkTbc(reg: Integer);
  end;

  TResKind = (rkLocal, rkUpval, rkGlobal);

  TLvKind = (lvLocal, lvUpval, lvGlobal, lvField, lvTable, lvValue);

  TMultiKind = (mkNone, mkCall, mkVararg);

  TLValue = record
    Kind: TLvKind;
    BaseTemp: Boolean;
    Reg: Integer;
    KeyReg: Integer;
    KeyConst: Integer;
    UpIdx: Integer;
    EnvIsUpval: Boolean;
    EnvIdx: Integer;
    IsConst: Boolean;
    IsMulti: Boolean;
    MultiKind: TMultiKind;
    MultiPC: Integer;
    Name: string;
  end;

  TExprInfo = record
    Reg: Integer;
    IsMulti: Boolean;
    MultiKind: TMultiKind;
    MultiPC: Integer;
  end;

  TCompiler = class
  public
    L: TLua;
    Lex: TLexer;
    FS: TFuncState;
    MainFS: TFuncState;
    CallWant: Integer;
    ExplistMulti: Boolean;
    LastExplist: TExprInfo;
    // lookahead
    LookAhead: Boolean;
    LA_Tok: TTokenKind;
    LA_Str: TStringObj;
    LA_Int: Int64;
    LA_Flt: Double;
    LA_Name: string;
    constructor Create(AL: TLua; const source: RawByteString; const name: string);
    destructor Destroy; override;
    function Compile: TFunction;
  private
    procedure Next;
    function PeekTok: TTokenKind;
    procedure Error(const msg: string);
    procedure Expect(t: TTokenKind);
    function TestNext(t: TTokenKind): Boolean;
    function Emit(op, a, b, c: Integer): Integer;
    // statements
    procedure Chunk;
    procedure Statement;
    procedure Block;
    procedure CloseBlockHere;
    procedure IfStat;
    procedure WhileStat;
    procedure RepeatStat;
    procedure DoStat;
    procedure ForStat;
    procedure LocalStat;
    procedure GlobalStat;
    procedure FuncStat(isLocal, isGlobal: Boolean);
    procedure ReturnStat;
    procedure BreakStat;
    procedure GotoStat;
    procedure LabelStat;
    procedure ExprStat;
    // expressions
    function ExprInfo(limit: Integer): TExprInfo;
    function SimpleExpr: TExprInfo;
    function CompileLValue: TLValue;
    function CompileVarRead(const lv: TLValue): Integer;
    procedure ResolveEnv(var isUpval: Boolean; var idx: Integer);
    function ReadEnvReg: Integer;
    function CompileCall(funcReg, selfReg, want: Integer): TExprInfo;
    function CompileArgs(funcReg, selfReg: Integer): Integer;
    function CompileExplist(need: Integer): Integer;
    function CompileTable: TExprInfo;
    function CompileFunctionBody(isMethod: Boolean): TProto;
    function CompileFunctionValue: Integer;
    procedure EmitCompare(r, r1, r2, k: Integer; op: Byte);
    function ForceSingle(e: TExprInfo): Integer;
    procedure MakeMulti(e: TExprInfo; count: Integer);
    procedure AssignTo(const lv: TLValue; valueReg: Integer);
    function GetVarAttribute(def: TVarKind): TVarKind;
    // goto
    function FindLabel(name: TStringObj): Integer;
    procedure CreateLabel(name: TStringObj; last: Boolean);
    procedure NewGoto(name: TStringObj);
    procedure SolveGotos(blockIdx: Integer);
    procedure CloseGoto(g, lab: Integer; bup: Boolean);
  end;

procedure ResolveVar(fs: TFuncState; name: TStringObj;
                     var kind: TResKind; var idx: Integer; var isConst: Boolean);
var
  i, gInfo: Integer;
  vd: TVarDesc;
  pk: TResKind;
  pidx: Integer;
  pconst: Boolean;
begin
  gInfo := -1;
  for i := fs.NActVar - 1 downto 0 do
  begin
    vd := fs.ActVars[i];
    if (vd.Kind = vkGlobal) or (vd.Kind = vkGlobalConst) then
    begin
      if vd.Name = nil then
      begin
        if gInfo < 0 then gInfo := i;
      end
      else if vd.Name.Eq(name) then
      begin
        kind := rkGlobal;
        idx := 0;
        isConst := vd.Kind = vkGlobalConst;
        Exit;
      end
      else if gInfo = -1 then
        gInfo := -2;
    end
    else if vd.Name.Eq(name) then
    begin
      kind := rkLocal;
      idx := vd.Reg;
      isConst := (vd.Kind = vkConst) or (vd.Kind = vkClose) or (vd.Kind = vkVararg);
      Exit;
    end;
  end;
  if gInfo = -2 then
    raise ELuaError.CreateMsg(Format('variable ''%s'' not declared', [name.ToStr]));
  i := fs.SearchUpval(name, isConst);
  if i >= 0 then
  begin
    kind := rkUpval;
    idx := i;
    Exit;
  end;
  if fs.Prev <> nil then
  begin
    ResolveVar(fs.Prev, name, pk, pidx, pconst);
    if (pk = rkLocal) or (pk = rkUpval) then
    begin
      idx := fs.AddUpval(name, pk = rkLocal, pidx, pconst);
      kind := rkUpval;
      isConst := pconst;
      Exit;
    end
    else
    begin
      kind := rkGlobal;
      idx := 0;
      isConst := pconst;
      Exit;
    end;
  end;
  kind := rkGlobal;
  idx := 0;
  if gInfo >= 0 then
    isConst := fs.ActVars[gInfo].Kind = vkGlobalConst
  else
    isConst := False;
end;

function BinaryPrio(t: TTokenKind): Integer;
begin
  case t of
    tkOr: Result := 1;
    tkAnd: Result := 2;
    tkLt, tkGt, tkLe, tkGe, tkNe, tkEq: Result := 3;
    tkPipe: Result := 4;
    tkTilde: Result := 5;
    tkAmp: Result := 6;
    tkShl, tkShr: Result := 7;
    tkConcat: Result := 8;
    tkPlus, tkMinus: Result := 9;
    tkCaret: Result := 12;
    tkStar, tkSlash, tkDblSlash, tkPercent: Result := 10;
  else
    Result := -1;
  end;
end;

// ================= TFuncState =================

constructor TFuncState.Create(AL: TLua; APrev: TFuncState; AProto: TProto);
begin
  L := AL;
  Prev := APrev;
  Proto := AProto;
  NCode := 0;
  SetLength(Code, 64);
  NK := 0;
  SetLength(K, 16);
  NProtos := 0;
  SetLength(Protos, 4);
  NUpvals := 0;
  SetLength(Upvals, 4);
  NActVar := 0;
  SetLength(ActVars, 16);
  NBlocks := 0;
  SetLength(Blocks, 16);
  NLabels := 0;
  SetLength(Labels, 16);
  NGotos := 0;
  SetLength(Gotos, 16);
  NLocVars := 0;
  SetLength(LocVars, 16);
  FreeReg := 0;
  VarArgReg := -1;
  NeedClose := False;
  CurBlock := -1;
end;

function TFuncState.Emit(op, a, b, c: Integer): Integer;
begin
  if GetEnvironmentVariable('LUA_TRACE') <> '' then
    WriteLn(ErrOutput, '  emit pc=', NCode, ' op=', op, ' a=', a, ' b=', b, ' c=', c);
  if NCode >= Length(Code) then
    SetLength(Code, Length(Code) * 2);
  Code[NCode].Op := op;
  Code[NCode].A := a;
  Code[NCode].B := b;
  Code[NCode].C := c;
  Result := NCode;
  Inc(NCode);
end;

function TFuncState.AddConst(const v: TLuaValue): Integer;
begin
  if NK >= Length(K) then
    SetLength(K, Length(K) * 2);
  K[NK] := v;
  Result := NK;
  Inc(NK);
end;

function TFuncState.AddStr(const s: RawByteString): Integer;
var
  i: Integer;
  so: TStringObj;
begin
  so := L.NewString(s);
  for i := 0 to NK - 1 do
  begin
    if (K[i].Vt = vtStr) and K[i].S.Eq(so) then
      Exit(i);
  end;
  Result := AddConst(LuaStr(so));
end;

function TFuncState.AddProto(p: TProto): Integer;
begin
  if NProtos >= Length(Protos) then
    SetLength(Protos, Length(Protos) * 2);
  Protos[NProtos] := p;
  Result := NProtos;
  Inc(NProtos);
end;

function TFuncState.AddUpval(name: TStringObj; instack: Boolean; idx: Integer; isConst: Boolean = False): Integer;
var
  i: Integer;
begin
  for i := 0 to NUpvals - 1 do
  begin
    if (Upvals[i].InStack = instack) and (Upvals[i].Idx = idx) and
       Upvals[i].Name.Eq(name) then
    begin
      if isConst then Upvals[i].IsConst := True;
      Exit(i);
    end;
  end;
  if NUpvals >= Length(Upvals) then
    SetLength(Upvals, Length(Upvals) * 2);
  Upvals[NUpvals].Name := name;
  Upvals[NUpvals].InStack := instack;
  Upvals[NUpvals].Idx := idx;
  Upvals[NUpvals].IsConst := isConst;
  Result := NUpvals;
  Inc(NUpvals);
end;

function TFuncState.SearchUpval(name: TStringObj; var isConst: Boolean): Integer;
var
  i: Integer;
begin
  for i := 0 to NUpvals - 1 do
    if Upvals[i].Name.Eq(name) then
    begin
      isConst := Upvals[i].IsConst;
      Exit(i);
    end;
  Result := -1;
end;

function TFuncState.AllocReg: Integer;
begin
  Result := FreeReg;
  Inc(FreeReg);
  if FreeReg > Proto.MaxStackSize then
    Proto.MaxStackSize := FreeReg;
end;

function TFuncState.AllocRegs(n: Integer): Integer;
begin
  Result := FreeReg;
  Inc(FreeReg, n);
  if FreeReg > Proto.MaxStackSize then
    Proto.MaxStackSize := FreeReg;
end;

procedure TFuncState.EnsureFree(n: Integer);
begin
  while FreeReg < n do
    AllocReg;
end;

procedure TFuncState.FreeTo(reg: Integer);
begin
  if reg < ActiveReg then
    reg := ActiveReg;
  FreeReg := reg;
end;

procedure TFuncState.OpenBlock(isLoop: Integer);
var
  b: TBlock;
begin
  b.PrevIdx := CurBlock;
  b.IsLoop := isLoop;
  b.NActVar := NActVar;
  b.FreeReg := FreeReg;
  b.ActiveReg := ActiveReg;
  b.FirstLabel := NLabels;
  b.FirstGoto := NGotos;
  b.HasTbc := False;
  if NBlocks >= Length(Blocks) then
    SetLength(Blocks, Length(Blocks) * 2);
  Blocks[NBlocks] := b;
  CurBlock := NBlocks;
  Inc(NBlocks);
end;

procedure TFuncState.AddLocal(name: TStringObj; kind: TVarKind; reg: Integer);
var
  v: TVarDesc;
begin
  v.Name := name;
  v.Kind := kind;
  v.Reg := reg;
  if NActVar >= Length(ActVars) then
    SetLength(ActVars, Length(ActVars) * 2);
  ActVars[NActVar] := v;
  Inc(NActVar);
  if reg + 1 > ActiveReg then
    ActiveReg := reg + 1;
end;

procedure TFuncState.AddLocVar(name: TStringObj; startpc: Integer; reg: Integer);
begin
  if NLocVars >= Length(LocVars) then
    SetLength(LocVars, Length(LocVars) * 2);
  LocVars[NLocVars].Name := name;
  LocVars[NLocVars].StartPC := startpc;
  LocVars[NLocVars].EndPC := 0;
  LocVars[NLocVars].Reg := reg;
  Inc(NLocVars);
end;

procedure TFuncState.MarkTbc(reg: Integer);
begin
  NeedClose := True;
end;

// ================= TCompiler =================

constructor TCompiler.Create(AL: TLua; const source: RawByteString; const name: string);
var
  proto: TProto;
begin
  L := AL;
  Lex := TLexer.Create(AL, source);
  LookAhead := False;
  CallWant := 1;
  ExplistMulti := False;
  proto := TProto.Create(AL);
  proto.Source := AL.NewString(RawByteString(name));
  proto.Linedefined := 1;
  proto.IsVararg := True;
  FS := TFuncState.Create(AL, nil, proto);
  MainFS := FS;
  FS.AddUpval(AL.NewString('_ENV'), False, 0);
  FS.VarArgReg := 0;
  FS.FreeReg := 1;
  proto.MaxStackSize := 2;
  FS.OpenBlock(0);
end;

destructor TCompiler.Destroy;
begin
  inherited Destroy;
end;

procedure TCompiler.Next;
begin
  if LookAhead then
  begin
    Lex.Tok := LA_Tok;
    Lex.StrVal := LA_Str;
    Lex.IntVal := LA_Int;
    Lex.FltVal := LA_Flt;
    Lex.NameVal := LA_Name;
    LookAhead := False;
  end
  else
    Lex.Next;
end;

function TCompiler.PeekTok: TTokenKind;
var
  saved: TTokenKind;
  sStr: TStringObj;
  sInt: Int64;
  sFlt: Double;
  sName: string;
begin
  if not LookAhead then
  begin
    saved := Lex.Tok;
    sStr := Lex.StrVal;
    sInt := Lex.IntVal;
    sFlt := Lex.FltVal;
    sName := Lex.NameVal;
    Lex.Next;
    LA_Tok := Lex.Tok;
    LA_Str := Lex.StrVal;
    LA_Int := Lex.IntVal;
    LA_Flt := Lex.FltVal;
    LA_Name := Lex.NameVal;
    Lex.Tok := saved;
    Lex.StrVal := sStr;
    Lex.IntVal := sInt;
    Lex.FltVal := sFlt;
    Lex.NameVal := sName;
    LookAhead := True;
  end;
  Result := LA_Tok;
end;

procedure TCompiler.Error(const msg: string);
begin
  raise ELuaError.CreateMsg(Format('%s:%d: %s (near %s)', ['?', Lex.Line, msg, Lex.TokenName(Lex.Tok)]));
end;

procedure TCompiler.Expect(t: TTokenKind);
begin
  if Lex.Tok <> t then
    Error(Format('''%s'' expected near ''%s''', [Lex.TokenName(t), Lex.TokenName(Lex.Tok)]));
  Next;
end;

function TCompiler.TestNext(t: TTokenKind): Boolean;
begin
  if Lex.Tok = t then
  begin
    Next;
    Result := True;
  end
  else
    Result := False;
end;

function TCompiler.Emit(op, a, b, c: Integer): Integer;
begin
  Result := FS.Emit(op, a, b, c);
  if Result >= Length(FS.Proto.LineInfo) then
    SetLength(FS.Proto.LineInfo, Result + 1);
  FS.Proto.LineInfo[Result] := Lex.Line;
end;

// ================= variable helpers =================

procedure TCompiler.ResolveEnv(var isUpval: Boolean; var idx: Integer);
var
  name: TStringObj;
  kind: TResKind;
  isConst: Boolean;
begin
  name := L.NewString('_ENV');
  ResolveVar(FS, name, kind, idx, isConst);
  if kind = rkGlobal then
    Error('_ENV must be a local or an upvalue');
  isUpval := kind = rkUpval;
end;

function TCompiler.ReadEnvReg: Integer;
var
  name: TStringObj;
  kind: TResKind;
  idx: Integer;
  isConst: Boolean;
  r: Integer;
begin
  name := L.NewString('_ENV');
  ResolveVar(FS, name, kind, idx, isConst);
  if kind = rkGlobal then
    Error('_ENV must be a local or an upvalue');
  r := FS.AllocReg;
  if kind = rkLocal then
    Emit(OP_MOVE, r, idx, 0)
  else
    Emit(OP_GETUPVAL, r, idx, 0);
  Result := r;
end;

function TCompiler.CompileLValue: TLValue;
var
  lv: TLValue;
  name: TStringObj;
  kind: TResKind;
  idx: Integer;
  isConst: Boolean;
  baseReg, keyReg: Integer;
  funcReg: Integer;
  fn: string;
  e: TExprInfo;
begin
  if GetEnvironmentVariable('LUA_TRACE') <> '' then
    WriteLn(ErrOutput, 'CompileLValue tok=', Lex.TokenName(Lex.Tok));
  lv.Name := '';
  if Lex.Tok = tkName then
  begin
    fn := Lex.NameVal;
    name := L.NewString(RawByteString(fn));
    Next;
    ResolveVar(FS, name, kind, idx, isConst);
    lv.IsConst := isConst;
    lv.Name := fn;
    case kind of
      rkLocal: begin lv.Kind := lvLocal; lv.Reg := idx; end;
      rkUpval: begin lv.Kind := lvUpval; lv.UpIdx := idx; end;
      rkGlobal: begin
        lv.Kind := lvGlobal;
        ResolveEnv(lv.EnvIsUpval, lv.EnvIdx);
        lv.KeyConst := FS.AddStr(name.ToStr);
      end;
    end;
  end
  else if Lex.Tok = tkLParen then
  begin
    Next;
    lv.Reg := ForceSingle(ExprInfo(0));
    lv.Kind := lvValue;
    lv.KeyReg := -1;
    lv.IsConst := False;
    Expect(tkRParen);
  end
  else
    Error('unexpected symbol');
  // suffixes and call suffixes
  lv.IsMulti := False;
  lv.MultiKind := mkNone;
  lv.MultiPC := -1;
  while True do
  begin
    if Lex.Tok = tkDot then
    begin
      Next;
      if Lex.Tok <> tkName then Error('<name> expected');
      fn := Lex.NameVal;
      Next;
      baseReg := CompileVarRead(lv);
      lv.Kind := lvField;
      lv.BaseTemp := True;
      lv.Reg := baseReg;
      lv.KeyConst := FS.AddStr(RawByteString(fn));
      lv.IsConst := False;
      lv.IsMulti := False;
      lv.MultiKind := mkNone;
      lv.MultiPC := -1;
    end
    else if Lex.Tok = tkLBracket then
    begin
      Next;
      keyReg := ForceSingle(ExprInfo(0));
      Expect(tkRBracket);
      baseReg := CompileVarRead(lv);
      lv.Kind := lvTable;
      lv.BaseTemp := True;
      lv.Reg := baseReg;
      lv.KeyReg := keyReg;
      lv.IsConst := False;
      lv.IsMulti := False;
      lv.MultiKind := mkNone;
      lv.MultiPC := -1;
    end
    else if Lex.Tok = tkColon then
    begin
      Next;
      if Lex.Tok <> tkName then Error('<name> expected');
      fn := Lex.NameVal;
      Next;
      baseReg := CompileVarRead(lv);
      funcReg := FS.AllocReg;
      Emit(OP_SELF, funcReg, baseReg, FS.AddStr(RawByteString(fn)));
      e := CompileCall(funcReg, funcReg + 1, 1);
      lv.Kind := lvValue;
      lv.BaseTemp := False;
      lv.Reg := e.Reg;
      lv.KeyReg := -1;
      lv.IsConst := False;
      lv.IsMulti := e.IsMulti;
      lv.MultiKind := e.MultiKind;
      lv.MultiPC := e.MultiPC;
      // if this is the last call in the chain and caller wants multret
      if (CallWant = 0) and not ((Lex.Tok = tkLParen) or (Lex.Tok = tkString) or
         (Lex.Tok = tkLBrace) or (Lex.Tok = tkDot) or (Lex.Tok = tkLBracket) or
         (Lex.Tok = tkColon)) then
        FS.Code[e.MultiPC].C := 0;
    end
    else if (Lex.Tok = tkLParen) or (Lex.Tok = tkString) or (Lex.Tok = tkLBrace) then
    begin
      baseReg := CompileVarRead(lv);
      e := CompileCall(baseReg, -1, 1);
      lv.Kind := lvValue;
      lv.BaseTemp := False;
      lv.Reg := e.Reg;
      lv.KeyReg := -1;
      lv.IsConst := False;
      lv.IsMulti := e.IsMulti;
      lv.MultiKind := e.MultiKind;
      lv.MultiPC := e.MultiPC;
      // if this is the last call in the chain and caller wants multret
      if (CallWant = 0) and not ((Lex.Tok = tkLParen) or (Lex.Tok = tkString) or
         (Lex.Tok = tkLBrace) or (Lex.Tok = tkDot) or (Lex.Tok = tkLBracket) or
         (Lex.Tok = tkColon)) then
        FS.Code[e.MultiPC].C := 0;
    end
    else
      Break;
  end;
  Result := lv;
end;

function TCompiler.CompileVarRead(const lv: TLValue): Integer;
var
  r: Integer;
begin
  r := FS.AllocReg;
  case lv.Kind of
    lvLocal: Emit(OP_MOVE, r, lv.Reg, 0);
    lvUpval: Emit(OP_GETUPVAL, r, lv.UpIdx, 0);
    lvGlobal: if lv.EnvIsUpval then Emit(OP_GETTABUP, r, lv.EnvIdx, lv.KeyConst)
              else Emit(OP_GETFIELD, r, lv.EnvIdx, lv.KeyConst);
    lvField: begin
      if lv.BaseTemp then
      begin
        Emit(OP_GETFIELD, lv.Reg, lv.Reg, lv.KeyConst);
        r := lv.Reg;
      end
      else
        Emit(OP_GETFIELD, r, lv.Reg, lv.KeyConst);
    end;
    lvTable: begin
      if lv.BaseTemp then
      begin
        Emit(OP_GETTABLE, lv.Reg, lv.Reg, lv.KeyReg);
        r := lv.Reg;
      end
      else
        Emit(OP_GETTABLE, r, lv.Reg, lv.KeyReg);
    end;
    lvValue: Emit(OP_MOVE, r, lv.Reg, 0);
  end;
  Result := r;
end;

procedure TCompiler.AssignTo(const lv: TLValue; valueReg: Integer);
begin
  if lv.IsConst then
    Error(Format('attempt to assign to const variable ''%s''', [lv.Name]));
  case lv.Kind of
    lvLocal: Emit(OP_MOVE, lv.Reg, valueReg, 0);
    lvUpval: Emit(OP_SETUPVAL, valueReg, lv.UpIdx, 0);
    lvGlobal: if lv.EnvIsUpval then Emit(OP_SETTABUP, lv.EnvIdx, lv.KeyConst, valueReg)
              else Emit(OP_SETFIELD, lv.EnvIdx, lv.KeyConst, valueReg);
    lvField: Emit(OP_SETFIELD, lv.Reg, lv.KeyConst, valueReg);
    lvTable: Emit(OP_SETTABLE, lv.Reg, lv.KeyReg, valueReg);
    lvValue: Error('cannot assign to expression');
  end;
end;

// ================= expressions =================

procedure TCompiler.EmitCompare(r, r1, r2, k: Integer; op: Byte);
var
  pcjmp: Integer;
begin
  Emit(OP_LOADBOOL, r, 0, 0);
  Emit(op, r1, r2, k);
  pcjmp := Emit(OP_JMP, -1, 0, 0);
  Emit(OP_LOADBOOL, r, 1, 0);
  FS.Code[pcjmp].A := FS.NCode;
end;

function TCompiler.ForceSingle(e: TExprInfo): Integer;
begin
  if e.IsMulti then
  begin
    if e.MultiKind = mkCall then
      FS.Code[e.MultiPC].C := 2
    else if e.MultiKind = mkVararg then
    begin
      if FS.Code[e.MultiPC].Op = OP_VARARG then
        FS.Code[e.MultiPC].B := 1;
    end;
    e.IsMulti := False;
  end;
  Result := e.Reg;
end;

procedure TCompiler.MakeMulti(e: TExprInfo; count: Integer);
begin
  if not e.IsMulti then
    Exit;
  if e.MultiKind = mkCall then
  begin
    if count = 0 then
      FS.Code[e.MultiPC].C := 0
    else
      FS.Code[e.MultiPC].C := count + 1;
  end
  else if e.MultiKind = mkVararg then
  begin
    FS.Code[e.MultiPC].Op := OP_VARARG;
    FS.Code[e.MultiPC].B := count;
  end;
end;

function TCompiler.ExprInfo(limit: Integer): TExprInfo;
var
  e1, e2: TExprInfo;
  op: TTokenKind;
  prio: Integer;
  r, r1, r2: Integer;
  ptest: Integer;
begin
  if GetEnvironmentVariable('LUA_TRACE') <> '' then
    WriteLn(ErrOutput, 'ExprInfo limit=', limit, ' tok=', Lex.TokenName(Lex.Tok));
  if (Lex.Tok = tkNot) or (Lex.Tok = tkMinus) or (Lex.Tok = tkHash) or (Lex.Tok = tkTilde) then
  begin
    op := Lex.Tok;
    Next;
    e1 := ExprInfo(11);
    r1 := ForceSingle(e1);
    r := FS.AllocReg;
    case op of
      tkNot: Emit(OP_NOT, r, r1, 0);
      tkMinus: Emit(OP_UNM, r, r1, 0);
      tkHash: Emit(OP_LEN, r, r1, 0);
      tkTilde: Emit(OP_BNOT, r, r1, 0);
    end;
    e1.Reg := r;
    e1.IsMulti := False;
    e1.MultiKind := mkNone;
  end
  else
    e1 := SimpleExpr;
  while BinaryPrio(Lex.Tok) > limit do
  begin
    op := Lex.Tok;
    prio := BinaryPrio(op);
    Next;
    // comparison chaining check
    if (prio = 3) and (BinaryPrio(Lex.Tok) = 3) then
      Error('comparison operators must be chained with ''and''');
    r1 := ForceSingle(e1);
    if op = tkAnd then
    begin
      r := FS.AllocReg;
      Emit(OP_MOVE, r, r1, 0);
      ptest := Emit(OP_TEST, r, 0, 0);
      e2 := ExprInfo(prio);
      r2 := ForceSingle(e2);
      Emit(OP_MOVE, r, r2, 0);
      FS.Code[ptest].B := FS.NCode;
      e1.Reg := r;
      e1.IsMulti := False;
      e1.MultiKind := mkNone;
      continue;
    end;
    if op = tkOr then
    begin
      r := FS.AllocReg;
      Emit(OP_MOVE, r, r1, 0);
      ptest := Emit(OP_TEST, r, 0, 1);
      e2 := ExprInfo(prio);
      r2 := ForceSingle(e2);
      Emit(OP_MOVE, r, r2, 0);
      FS.Code[ptest].B := FS.NCode;
      e1.Reg := r;
      e1.IsMulti := False;
      e1.MultiKind := mkNone;
      continue;
    end;
    if (op = tkCaret) or (op = tkConcat) then
      e2 := ExprInfo(prio - 1)
    else
      e2 := ExprInfo(prio);
    r2 := ForceSingle(e2);
    r := FS.AllocReg;
    case op of
      tkPlus: Emit(OP_ADD, r, r1, r2);
      tkMinus: Emit(OP_SUB, r, r1, r2);
      tkStar: Emit(OP_MUL, r, r1, r2);
      tkSlash: Emit(OP_DIV, r, r1, r2);
      tkDblSlash: Emit(OP_IDIV, r, r1, r2);
      tkPercent: Emit(OP_MOD, r, r1, r2);
      tkCaret: Emit(OP_POW, r, r1, r2);
      tkAmp: Emit(OP_BAND, r, r1, r2);
      tkPipe: Emit(OP_BOR, r, r1, r2);
      tkTilde: Emit(OP_BXOR, r, r1, r2);
      tkShl: Emit(OP_SHL, r, r1, r2);
      tkShr: Emit(OP_SHR, r, r1, r2);
      tkConcat: begin
        r := FS.AllocRegs(2);
        Emit(OP_MOVE, r, r1, 0);
        Emit(OP_MOVE, r + 1, r2, 0);
        Emit(OP_CONCAT, r, 2, 0);
      end;
      tkEq: EmitCompare(r, r1, r2, 0, OP_EQ);
      tkNe: EmitCompare(r, r1, r2, 1, OP_EQ);
      tkLt: EmitCompare(r, r1, r2, 0, OP_LT);
      tkLe: EmitCompare(r, r1, r2, 0, OP_LE);
      tkGt: EmitCompare(r, r2, r1, 0, OP_LT);
      tkGe: EmitCompare(r, r2, r1, 0, OP_LE);
    end;
    e1.Reg := r;
    e1.IsMulti := False;
    e1.MultiKind := mkNone;
  end;
  Result := e1;
end;

function TCompiler.SimpleExpr: TExprInfo;
var
  r: Integer;
  k: Integer;
  lv: TLValue;
  e: TExprInfo;
  pc: Integer;
  v: TLuaValue;
begin
  Result.Reg := 0;
  Result.IsMulti := False;
  Result.MultiKind := mkNone;
  Result.MultiPC := -1;
  case Lex.Tok of
    tkNil: begin
      Next;
      r := FS.AllocReg;
      Emit(OP_LOADNIL, r, 0, 0);
      Result.Reg := r;
    end;
    tkTrue, tkFalse: begin
      r := FS.AllocReg;
      Emit(OP_LOADBOOL, r, Ord(Lex.Tok = tkTrue), 0);
      Next;
      Result.Reg := r;
    end;
    tkInt: begin
      r := FS.AllocReg;
      Emit(OP_LOADK, r, FS.AddConst(LuaInt(Lex.IntVal)), 0);
      Next;
      Result.Reg := r;
    end;
    tkFlt: begin
      r := FS.AllocReg;
      v := LuaNum(Lex.FltVal);
      k := FS.AddConst(v);
      Emit(OP_LOADK, r, k, 0);
      Next;
      Result.Reg := r;
    end;
    tkString: begin
      r := FS.AllocReg;
      k := FS.AddConst(LuaStr(Lex.StrVal));
      Emit(OP_LOADK, r, k, 0);
      Next;
      if GetEnvironmentVariable('LUA_TRACE') <> '' then
        WriteLn(ErrOutput, 'after string Next tok=', Lex.TokenName(Lex.Tok));
      Result.Reg := r;
    end;
    tkDots: begin
      if FS.VarArgReg < 0 then
        Error('cannot use ''...'' outside a vararg function');
      Next;
      r := FS.AllocReg;
      pc := Emit(OP_VARARG, r, 0, 0);
      Result.Reg := r;
      Result.IsMulti := True;
      Result.MultiKind := mkVararg;
      Result.MultiPC := pc;
    end;
    tkFunction: begin
      Next;
      r := CompileFunctionValue;
      Result.Reg := r;
    end;
    tkLBrace: begin
      Result := CompileTable;
    end;
  else
    begin
      lv := CompileLValue;
      if lv.IsMulti then
      begin
        Result.Reg := lv.Reg;
        Result.IsMulti := True;
        Result.MultiKind := lv.MultiKind;
        Result.MultiPC := lv.MultiPC;
      end
      else
      begin
        r := CompileVarRead(lv);
        Result.Reg := r;
        Result.IsMulti := False;
        Result.MultiKind := mkNone;
        Result.MultiPC := -1;
      end;
    end;
  end;
end;

function TCompiler.CompileFunctionValue: Integer;
var
  proto: TProto;
  pidx, r: Integer;
begin
  proto := CompileFunctionBody(False);
  pidx := FS.AddProto(proto);
  r := FS.AllocReg;
  Emit(OP_CLOSURE, r, pidx, 0);
  Result := r;
end;

function TCompiler.CompileCall(funcReg, selfReg, want: Integer): TExprInfo;
var
  B: Integer;
  pc: Integer;
begin
  B := CompileArgs(funcReg, selfReg);
  pc := Emit(OP_CALL, funcReg, B, 0);
  if want > 0 then
    FS.Code[pc].C := want + 1
  else
    FS.Code[pc].C := 0;
  Result.Reg := funcReg;
  Result.IsMulti := True;
  Result.MultiKind := mkCall;
  Result.MultiPC := pc;
end;

function TCompiler.CompileArgs(funcReg, selfReg: Integer): Integer;
var
  nargs: Integer;
  firstArg: Integer;
  e: TExprInfo;
  r: Integer;
  k: Integer;
  bval: Integer;
begin
  if selfReg >= 0 then
  begin
    firstArg := funcReg + 1;
    nargs := 1;  // count self (already placed at funcReg+1 by OP_SELF)
  end
  else
  begin
    firstArg := funcReg + 1;
    nargs := 0;
  end;
  FS.EnsureFree(firstArg);
  if (Lex.Tok = tkLParen) then
  begin
    Next;
    if Lex.Tok = tkRParen then
    begin
      Next;
      Result := nargs + 1;
      Exit;
    end;
    while True do
    begin
      FS.FreeTo(firstArg + nargs);
      e := ExprInfo(0);
      if Lex.Tok <> tkComma then
      begin
        // last arg
        if e.IsMulti then
        begin
          if e.Reg <> firstArg + nargs then
          begin
            // rewrite call into MOVE into arg slot, re-emit call there
            bval := FS.Code[e.MultiPC].B;
            FS.Code[e.MultiPC].Op := OP_MOVE;
            FS.Code[e.MultiPC].A := firstArg + nargs;
            FS.Code[e.MultiPC].B := e.Reg;
            FS.Code[e.MultiPC].C := 0;
            // move arguments down too
            for k := 1 to bval - 1 do
              Emit(OP_MOVE, firstArg + nargs + k, e.Reg + k, 0);
            k := Emit(OP_CALL, firstArg + nargs, bval, 0);
            FS.Code[k].C := 0;
          end
          else
            MakeMulti(e, 0);
          Expect(tkRParen);
          Result := 0;  // multret signal
          Exit;
        end
        else
        begin
          Emit(OP_MOVE, firstArg + nargs, e.Reg, 0);
          Inc(nargs);
          FS.FreeTo(firstArg + nargs);
        end;
        Break;
      end
      else
      begin
        ForceSingle(e);
        Emit(OP_MOVE, firstArg + nargs, e.Reg, 0);
        Inc(nargs);
        FS.FreeTo(firstArg + nargs);
        Next; // skip comma
      end;
    end;
    if GetEnvironmentVariable('LUA_TRACE') <> '' then
      WriteLn(ErrOutput, 'CompileArgs before Expect rparen tok=', Lex.TokenName(Lex.Tok));
    Expect(tkRParen);
    if GetEnvironmentVariable('LUA_TRACE') <> '' then
      WriteLn(ErrOutput, 'CompileArgs after Expect rparen tok=', Lex.TokenName(Lex.Tok));
  end
  else if Lex.Tok = tkString then
  begin
    r := FS.AllocReg;
    Emit(OP_LOADK, r, FS.AddConst(LuaStr(Lex.StrVal)), 0);
    Next;
    Emit(OP_MOVE, firstArg + nargs, r, 0);
    Inc(nargs);
  end
  else if Lex.Tok = tkLBrace then
  begin
    e := CompileTable;
    Emit(OP_MOVE, firstArg + nargs, e.Reg, 0);
    Inc(nargs);
  end
  else
    Error('function arguments expected');
  Result := nargs + 1;
end;

function TCompiler.CompileExplist(need: Integer): Integer;
var
  t0: Integer;
  nexps: Integer;
  e: TExprInfo;
  lastMulti: Boolean;
  i: Integer;
begin
  t0 := FS.FreeReg;
  nexps := 0;
  lastMulti := False;
  ExplistMulti := False;
  if (Lex.Tok = tkRParen) or (Lex.Tok = tkRBrace) or (Lex.Tok = tkSemi) or
     (Lex.Tok = tkEof) or (Lex.Tok = tkEnd) or (Lex.Tok = tkElse) or
     (Lex.Tok = tkElseIf) or (Lex.Tok = tkUntil) then
  begin
    // empty list
    if need > 0 then
    begin
      FS.AllocRegs(need);
      Emit(OP_LOADNIL, t0, need - 1, 0);
    end;
    Result := 0;
    Exit;
  end;
  while True do
  begin
    e := ExprInfo(0);
    if GetEnvironmentVariable('LUA_TRACE') <> '' then
      WriteLn(ErrOutput, 'Explist: e.Reg=', e.Reg, ' multi=', e.IsMulti, ' tok=', Lex.TokenName(Lex.Tok), ' t0=', t0, ' nexps=', nexps, ' freereg=', FS.FreeReg);
    if Lex.Tok <> tkComma then
    begin
      // last expression
      LastExplist := e;
      if e.IsMulti then
      begin
        if need > 0 then
        begin
          MakeMulti(e, need);
          for i := need - 1 downto 0 do
            if e.Reg + i <> t0 + nexps + i then
              Emit(OP_MOVE, t0 + nexps + i, e.Reg + i, 0);
          Inc(nexps, need);
          FS.FreeTo(t0 + nexps);
        end
        else
          MakeMulti(e, 0);
        lastMulti := True;
        ExplistMulti := True;
      end
      else
      begin
        if e.Reg <> t0 + nexps then
          Emit(OP_MOVE, t0 + nexps, e.Reg, 0);
        Inc(nexps);
      end;
      Break;
    end
    else
    begin
      ForceSingle(e);
      if e.Reg <> t0 + nexps then
        Emit(OP_MOVE, t0 + nexps, e.Reg, 0);
      Inc(nexps);
      Next;
    end;
  end;
  if need > 0 then
  begin
    if lastMulti then
    begin
      // already placed and FreeTo done
    end
    else
    begin
      if nexps > need then
        FS.FreeTo(t0 + need)
      else if nexps < need then
      begin
        FS.FreeTo(t0 + need);
        Emit(OP_LOADNIL, t0 + nexps, need - nexps - 1, 0);
      end;
    end;
  end;
  Result := nexps;
end;

function TCompiler.CompileTable: TExprInfo;
var
  r: Integer;
  listCount: Integer;
  e: TExprInfo;
  keyReg, valReg: Integer;
  name: string;
  k: Integer;
  bval: Integer;
  lastMulti: Boolean;
begin
  Next; // skip {
  r := FS.AllocReg;
  Emit(OP_NEWTABLE, r, 0, 0);
  listCount := 0;
  FS.EnsureFree(r + 1);
  lastMulti := False;
  while Lex.Tok <> tkRBrace do
  begin
    if Lex.Tok = tkLBracket then
    begin
      Next;
      keyReg := ForceSingle(ExprInfo(0));
      Expect(tkRBracket);
      Expect(tkAssign);
      valReg := ForceSingle(ExprInfo(0));
      Emit(OP_SETTABLE, r, keyReg, valReg);
    end
    else if (Lex.Tok = tkName) and (PeekTok = tkAssign) then
    begin
      name := Lex.NameVal;
      Next;
      Next; // skip =
      valReg := ForceSingle(ExprInfo(0));
      k := FS.AddStr(RawByteString(name));
      Emit(OP_SETFIELD, r, k, valReg);
    end
    else
    begin
      // list item
      e := ExprInfo(0);
      if (Lex.Tok = tkComma) or (Lex.Tok = tkSemi) then
      begin
        Next; // consume separator
        if Lex.Tok = tkRBrace then
        begin
          // last item with trailing separator
          if e.IsMulti then
          begin
            if e.Reg <> r + 1 + listCount then
            begin
              bval := FS.Code[e.MultiPC].B;
              FS.Code[e.MultiPC].Op := OP_MOVE;
              FS.Code[e.MultiPC].A := r + 1 + listCount;
              FS.Code[e.MultiPC].B := e.Reg;
              FS.Code[e.MultiPC].C := 0;
              for k := 1 to bval - 1 do
                Emit(OP_MOVE, r + 1 + listCount + k, e.Reg + k, 0);
              k := Emit(OP_CALL, r + 1 + listCount, bval, 0);
              FS.Code[k].C := 0;
            end
            else
              MakeMulti(e, 0);
            lastMulti := True;
          end
          else
          begin
            ForceSingle(e);
            Emit(OP_MOVE, r + 1 + listCount, e.Reg, 0);
            Inc(listCount);
          end;
          Break;
        end
        else
        begin
          // middle item
          ForceSingle(e);
          Emit(OP_MOVE, r + 1 + listCount, e.Reg, 0);
          Inc(listCount);
          FS.FreeTo(r + 1 + listCount);
          continue;
        end;
      end
      else
      begin
        // last item (no separator)
        if e.IsMulti then
        begin
          if e.Reg <> r + 1 + listCount then
          begin
            bval := FS.Code[e.MultiPC].B;
            FS.Code[e.MultiPC].Op := OP_MOVE;
            FS.Code[e.MultiPC].A := r + 1 + listCount;
            FS.Code[e.MultiPC].B := e.Reg;
            FS.Code[e.MultiPC].C := 0;
            for k := 1 to bval - 1 do
              Emit(OP_MOVE, r + 1 + listCount + k, e.Reg + k, 0);
            k := Emit(OP_CALL, r + 1 + listCount, bval, 0);
            FS.Code[k].C := 0;
          end
          else
            MakeMulti(e, 0);
          lastMulti := True;
        end
        else
        begin
          ForceSingle(e);
          Emit(OP_MOVE, r + 1 + listCount, e.Reg, 0);
          Inc(listCount);
        end;
        Break;
      end;
    end;
    if (Lex.Tok = tkComma) or (Lex.Tok = tkSemi) then
    begin
      Next;
      if Lex.Tok = tkRBrace then Break;
    end
    else
      Break;
  end;
  Expect(tkRBrace);
  if lastMulti then
    Emit(OP_SETLIST, r, 0, 1)
  else if listCount > 0 then
    Emit(OP_SETLIST, r, listCount, 1);
  Result.Reg := r;
  Result.IsMulti := False;
  Result.MultiKind := mkNone;
  Result.MultiPC := -1;
end;

// ================= statements =================

procedure TCompiler.Chunk;
begin
  while Lex.Tok <> tkEof do
  begin
    if Lex.Tok = tkReturn then
      ReturnStat
    else
      Statement;
  end;
end;

procedure TCompiler.Statement;
begin
  case Lex.Tok of
    tkSemi: Next;
    tkIf: IfStat;
    tkWhile: WhileStat;
    tkDo: DoStat;
    tkFor: ForStat;
    tkRepeat: RepeatStat;
    tkFunction: FuncStat(False, False);
    tkGlobal: GlobalStat;
    tkLocal: LocalStat;
    tkReturn: ReturnStat;
    tkBreak: BreakStat;
    tkGoto: GotoStat;
    tkDblColon: LabelStat;
  else
    ExprStat;
  end;
end;

procedure TCompiler.Block;
begin
  FS.OpenBlock(0);
  while (Lex.Tok <> tkEof) and (Lex.Tok <> tkEnd) and (Lex.Tok <> tkElse) and
        (Lex.Tok <> tkElseIf) and (Lex.Tok <> tkUntil) do
    Statement;
  CloseBlockHere;
end;

procedure TCompiler.CloseBlockHere;
var
  b: TBlock;
  i: Integer;
  brk: TStringObj;
begin
  b := FS.Blocks[FS.CurBlock];
  // close to-be-closed variables
  if b.HasTbc and (b.PrevIdx >= 0) then
    Emit(OP_CLOSE, b.FreeReg, 0, 0);
  // pop vars
  FS.ActiveReg := b.ActiveReg;
  FS.FreeTo(b.FreeReg);
  FS.NActVar := b.NActVar;
  // fix locvars endpc
  for i := FS.NLocVars - 1 downto 0 do
  begin
    if FS.LocVars[i].StartPC >= FS.NCode then
      Break;
  end;
  // breaks: create label
  if b.IsLoop = 2 then
  begin
    brk := L.NewString('<break>');
    CreateLabel(brk, False);
  end;
  SolveGotos(FS.CurBlock);
  FS.CurBlock := b.PrevIdx;
end;

procedure TCompiler.IfStat;
var
  endJmps: array of Integer;
  nJmp: Integer;
  r: Integer;
  Lelse: Integer;
  i: Integer;
begin
  nJmp := 0;
  SetLength(endJmps, 16);
  Next; // skip if
  r := ForceSingle(ExprInfo(0));
  Lelse := Emit(OP_JFALSE, r, 0, 0);
  Expect(tkThen);
  Block;
  if nJmp >= Length(endJmps) then SetLength(endJmps, Length(endJmps) * 2);
  endJmps[nJmp] := Emit(OP_JMP, 0, 0, 0);
  Inc(nJmp);
  FS.Code[Lelse].B := FS.NCode;
  while Lex.Tok = tkElseIf do
  begin
    Next;
    r := ForceSingle(ExprInfo(0));
    Lelse := Emit(OP_JFALSE, r, 0, 0);
    Expect(tkThen);
    Block;
    if nJmp >= Length(endJmps) then SetLength(endJmps, Length(endJmps) * 2);
    endJmps[nJmp] := Emit(OP_JMP, 0, 0, 0);
    Inc(nJmp);
    FS.Code[Lelse].B := FS.NCode;
  end;
  if Lex.Tok = tkElse then
  begin
    Next;
    Block;
  end;
  Expect(tkEnd);
  for i := 0 to nJmp - 1 do
    FS.Code[endJmps[i]].A := FS.NCode;
end;

procedure TCompiler.WhileStat;
var
  Lstart, Lend: Integer;
  r: Integer;
begin
  Next; // skip while
  Lstart := FS.NCode;
  r := ForceSingle(ExprInfo(0));
  Lend := Emit(OP_JFALSE, r, 0, 0);
  Expect(tkDo);
  Block;
  Emit(OP_JMP, Lstart, 0, 0);
  FS.Code[Lend].B := FS.NCode;
  Expect(tkEnd);
end;

procedure TCompiler.RepeatStat;
var
  Lstart: Integer;
  r: Integer;
begin
  Next; // skip repeat
  Lstart := FS.NCode;
  FS.OpenBlock(1);
  while (Lex.Tok <> tkUntil) and (Lex.Tok <> tkEof) do
    Statement;
  Expect(tkUntil);
  r := ForceSingle(ExprInfo(0));
  Emit(OP_JFALSE, r, Lstart, 0);
  CloseBlockHere;
end;

procedure TCompiler.DoStat;
begin
  Next;
  Block;
  Expect(tkEnd);
end;

procedure TCompiler.ForStat;
var
  name: TStringObj;
  fn: string;
  r1, r2, r3: Integer;
  baseReg: Integer;
  Lbody, Lforloop, Lforloop2, Lend, Lcall: Integer;
  pjmp, Lloop: Integer;
  i, n: Integer;
  loopNames: array of string;
  attr: TVarKind;
  e: TExprInfo;
  t0: Integer;
  nexps: Integer;
  k: Integer;
begin
  Next; // skip for
  if Lex.Tok <> tkName then Error('<name> expected');
  fn := Lex.NameVal;
  name := L.NewString(RawByteString(fn));
  Next;
  if Lex.Tok = tkAssign then
  begin
    // numeric for
    Next;
    r1 := ForceSingle(ExprInfo(0));
    Expect(tkComma);
    r2 := ForceSingle(ExprInfo(0));
    r3 := -1;
    if TestNext(tkComma) then
      r3 := ForceSingle(ExprInfo(0));
    baseReg := FS.AllocRegs(4);
    Emit(OP_MOVE, baseReg, r1, 0);
    Emit(OP_MOVE, baseReg + 1, r2, 0);
    if r3 >= 0 then
      Emit(OP_MOVE, baseReg + 2, r3, 0)
    else
      Emit(OP_LOADK, baseReg + 2, FS.AddConst(LuaInt(1)), 0);
    FS.AddLocal(name, vkLocal, baseReg + 3);
    FS.AddLocVar(name, FS.NCode, baseReg + 3);
    Expect(tkDo);
    Lforloop := Emit(OP_FORPREP, baseReg, 0, 0);
    Lbody := FS.NCode;
    FS.OpenBlock(1);
    while (Lex.Tok <> tkEnd) and (Lex.Tok <> tkEof) do
      Statement;
    CloseBlockHere;
    Lforloop2 := FS.NCode;
    Emit(OP_FORLOOP, baseReg, Lbody, 0);
    FS.Code[Lforloop].B := Lforloop2;  // FORPREP jumps to FORLOOP
    Lend := FS.NCode;
  end
  else
  begin
    // generic for; first name already parsed
    n := 0;
    SetLength(loopNames, 4);
    if n >= Length(loopNames) then SetLength(loopNames, n * 2);
    loopNames[n] := fn;
    Inc(n);
    while Lex.Tok = tkComma do
    begin
      Next;
      if Lex.Tok <> tkName then Error('<name> expected');
      fn := Lex.NameVal;
      Next;
      if n >= Length(loopNames) then SetLength(loopNames, n * 2);
      loopNames[n] := fn;
      Inc(n);
    end;
    Expect(tkIn);
    // iterator explist: up to 3 values; first expr may be multret
    t0 := FS.FreeReg;
    nexps := 0;
    while True do
    begin
      e := ExprInfo(0);
      if Lex.Tok <> tkComma then
      begin
        if e.IsMulti then
        begin
          if GetEnvironmentVariable('LUA_TRACE') <> '' then
            WriteLn(ErrOutput, 'FORITER pack: e.Reg=', e.Reg, ' t0=', t0, ' nexps=', nexps, ' freereg=', FS.FreeReg);
          MakeMulti(e, 3 - nexps);
          for k := (3 - nexps) - 1 downto 0 do
            if e.Reg + k <> t0 + nexps + k then
              Emit(OP_MOVE, t0 + nexps + k, e.Reg + k, 0);
          nexps := 3;
        end
        else
        begin
          if e.Reg <> t0 + nexps then
            Emit(OP_MOVE, t0 + nexps, e.Reg, 0);
          Inc(nexps);
        end;
        Break;
      end
      else
      begin
        ForceSingle(e);
        if e.Reg <> t0 + nexps then
          Emit(OP_MOVE, t0 + nexps, e.Reg, 0);
        Inc(nexps);
        Next;
        if nexps >= 3 then Break;
      end;
    end;
    if nexps < 3 then
    begin
      FS.FreeTo(t0 + 3);
      Emit(OP_LOADNIL, t0 + nexps, 3 - nexps - 1, 0);
    end;
    baseReg := FS.AllocRegs(4);
    Emit(OP_MOVE, baseReg + 2, t0 + 2, 0);
    Emit(OP_MOVE, baseReg + 1, t0 + 1, 0);
    Emit(OP_MOVE, baseReg, t0, 0);
    for i := 0 to n - 1 do
    begin
      FS.AddLocal(L.NewString(RawByteString(loopNames[i])), vkLocal, baseReg + 3 + i);
      FS.AddLocVar(L.NewString(RawByteString(loopNames[i])), FS.NCode, baseReg + 3 + i);
    end;
    FS.FreeTo(baseReg + 4 + n);
    Expect(tkDo);
    Lcall := FS.NCode;
    Emit(OP_TFORCALL, baseReg, n, n);
    pjmp := Emit(OP_JMP, -1, 0, 0);
    Lbody := FS.NCode;
    FS.OpenBlock(1);
    while (Lex.Tok <> tkEnd) and (Lex.Tok <> tkEof) do
      Statement;
    CloseBlockHere;
    Emit(OP_JMP, Lcall, 0, 0);
    Lloop := FS.NCode;
    Emit(OP_TFORLOOP, baseReg, Lbody, 0);
    FS.Code[pjmp].A := Lloop;
    Lend := FS.NCode;
  end;
  Expect(tkEnd);
end;

// ================= goto machinery =================

function TCompiler.FindLabel(name: TStringObj): Integer;
var
  i: Integer;
  first: Integer;
begin
  first := FS.Blocks[FS.CurBlock].FirstLabel;
  for i := first to FS.NLabels - 1 do
    if FS.Labels[i].Name.Eq(name) then
      Exit(i);
  Result := -1;
end;

procedure TCompiler.CreateLabel(name: TStringObj; last: Boolean);
var
  li: Integer;
begin
  if FS.NLabels >= Length(FS.Labels) then
    SetLength(FS.Labels, Length(FS.Labels) * 2);
  li := FS.NLabels;
  FS.Labels[li].Name := name;
  FS.Labels[li].PC := FS.NCode;
  FS.Labels[li].Line := Lex.Line;
  if last then
  begin
    FS.Labels[li].NActVar := FS.Blocks[FS.CurBlock].NActVar;
    FS.Labels[li].RegLevel := FS.Blocks[FS.CurBlock].FreeReg;
  end
  else
  begin
    FS.Labels[li].NActVar := FS.NActVar;
    FS.Labels[li].RegLevel := FS.FreeReg;
  end;
  Inc(FS.NLabels);
end;

procedure TCompiler.NewGoto(name: TStringObj);
var
  pc: Integer;
  g: Integer;
begin
  pc := Emit(OP_JMP, 0, 0, 0);
  Emit(OP_CLOSE, 0, 1, 0);  // dead placeholder
  if FS.NGotos >= Length(FS.Gotos) then
    SetLength(FS.Gotos, Length(FS.Gotos) * 2);
  g := FS.NGotos;
  FS.Gotos[g].Name := name;
  FS.Gotos[g].PC := pc;
  FS.Gotos[g].NActVar := FS.NActVar;
  FS.Gotos[g].RegLevel := FS.FreeReg;
  FS.Gotos[g].Close := False;
  FS.Gotos[g].Line := Lex.Line;
  Inc(FS.NGotos);
end;

procedure TCompiler.CloseGoto(g, lab: Integer; bup: Boolean);
var
  gt: PGotoDesc;
  lb: PLabelDesc;
  tmp: TInstruction;
  varName: string;
begin
  gt := @FS.Gotos[g];
  lb := @FS.Labels[lab];
  if gt^.NActVar < lb^.NActVar then
  begin
    if (gt^.NActVar < FS.NActVar) and (FS.ActVars[gt^.NActVar].Name <> nil) then
      varName := FS.ActVars[gt^.NActVar].Name.ToStr
    else
      varName := '*';
    Error(Format('<goto %s> at line %d jumps into the scope of ''%s''',
          [gt^.Name.ToStr, gt^.Line, varName]));
  end;
  if gt^.Close or ((lb^.NActVar < gt^.NActVar) and bup) then
  begin
    // swap JMP and CLOSE
    tmp := FS.Code[gt^.PC];
    FS.Code[gt^.PC] := FS.Code[gt^.PC + 1];
    FS.Code[gt^.PC + 1] := tmp;
    FS.Code[gt^.PC].Op := OP_CLOSE;
    FS.Code[gt^.PC].A := lb^.RegLevel;
    FS.Code[gt^.PC].B := 0;
    FS.Code[gt^.PC].C := 0;
    Inc(gt^.PC);
  end;
  FS.Code[gt^.PC].A := lb^.PC;
  // remove goto from list
  while g < FS.NGotos - 1 do
  begin
    FS.Gotos[g] := FS.Gotos[g + 1];
    Inc(g);
  end;
  Dec(FS.NGotos);
end;

procedure TCompiler.SolveGotos(blockIdx: Integer);
var
  b: TBlock;
  igt: Integer;
  lab: Integer;
begin
  b := FS.Blocks[blockIdx];
  igt := b.FirstGoto;
  while igt < FS.NGotos do
  begin
    lab := FindLabel(FS.Gotos[igt].Name);
    if lab >= 0 then
      CloseGoto(igt, lab, b.HasTbc)
    else
    begin
      if b.HasTbc and (FS.Gotos[igt].RegLevel > b.FreeReg) then
        FS.Gotos[igt].Close := True;
      FS.Gotos[igt].NActVar := b.NActVar;
      Inc(igt);
    end;
  end;
  // remove labels of this block
  FS.NLabels := b.FirstLabel;
end;

procedure TCompiler.BreakStat;
var
  b: Integer;
  found: Boolean;
  brk: TStringObj;
begin
  found := False;
  b := FS.CurBlock;
  while b >= 0 do
  begin
    if FS.Blocks[b].IsLoop <> 0 then
    begin
      found := True;
      FS.Blocks[b].IsLoop := 2;
      Break;
    end;
    b := FS.Blocks[b].PrevIdx;
  end;
  if not found then
    Error('break outside loop');
  Next; // skip break
  brk := L.NewString('<break>');
  NewGoto(brk);
end;

procedure TCompiler.GotoStat;
var
  name: TStringObj;
begin
  Next; // skip goto
  if Lex.Tok <> tkName then Error('<name> expected');
  name := L.NewString(RawByteString(Lex.NameVal));
  Next;
  NewGoto(name);
end;

procedure TCompiler.LabelStat;
var
  name: TStringObj;
  last: Boolean;
begin
  Next; // skip ::
  if Lex.Tok <> tkName then Error('<name> expected');
  name := L.NewString(RawByteString(Lex.NameVal));
  Next;
  Expect(tkDblColon);
  // skip other no-op statements
  while (Lex.Tok = tkSemi) or (Lex.Tok = tkDblColon) do
    Statement;
  // check repeated
  if FindLabel(name) >= 0 then
    Error(Format('label ''%s'' already defined', [name.ToStr]));
  last := (Lex.Tok = tkEof) or (Lex.Tok = tkEnd) or (Lex.Tok = tkElse) or
          (Lex.Tok = tkElseIf) or (Lex.Tok = tkUntil);
  CreateLabel(name, last);
end;

// ================= function bodies =================

function TCompiler.GetVarAttribute(def: TVarKind): TVarKind;
var
  s: string;
begin
  Result := def;
  if Lex.Tok <> tkLt then
    Exit;
  Next;
  if Lex.Tok <> tkName then Error('attribute expected');
  s := Lex.NameVal;
  Next;
  if s = 'const' then
  begin
    if def = vkGlobal then Result := vkGlobalConst
    else Result := vkConst;
  end
  else if s = 'close' then
  begin
    if def = vkGlobal then Error('global variables cannot be to-be-closed');
    Result := vkClose;
  end
  else
    Error('unknown attribute');
  Expect(tkGt);
end;

function TCompiler.CompileFunctionBody(isMethod: Boolean): TProto;
var
  proto: TProto;
  child: TFuncState;
  saved: TFuncState;
  fn: string;
  name: TStringObj;
  attr: TVarKind;
  nparams: Integer;
  namedVarArg: TStringObj;
  i: Integer;
begin
  proto := TProto.Create(L);
  proto.Source := MainFS.Proto.Source;
  proto.Linedefined := Lex.Line;
  child := TFuncState.Create(L, FS, proto);
  saved := FS;
  FS := child;
  FS.OpenBlock(0);
  Expect(tkLParen);
  nparams := 0;
  if isMethod then
  begin
    nparams := 1;  // self
    FS.FreeReg := 1;
    proto.MaxStackSize := 1;
  end;
  namedVarArg := nil;
  if Lex.Tok <> tkRParen then
  begin
    while True do
    begin
      if Lex.Tok = tkDots then
      begin
        Next;
        proto.IsVararg := True;
        if Lex.Tok = tkName then
        begin
          namedVarArg := L.NewString(RawByteString(Lex.NameVal));
          Next;
        end;
        Break;
      end;
      if Lex.Tok <> tkName then Error('<name> expected');
      fn := Lex.NameVal;
      name := L.NewString(RawByteString(fn));
      Next;
      attr := vkLocal;
      if Lex.Tok = tkLt then
        attr := GetVarAttribute(vkLocal);
      FS.AddLocal(name, attr, nparams);
      Inc(nparams);
      if not TestNext(tkComma) then
        Break;
    end;
  end;
  Expect(tkRParen);
  // setup vararg register
  if proto.IsVararg then
  begin
    FS.VarArgReg := nparams;
    FS.FreeReg := nparams + 1;
    if nparams + 1 > proto.MaxStackSize then
      proto.MaxStackSize := nparams + 1;
    if namedVarArg <> nil then
    begin
      FS.AddLocal(namedVarArg, vkVararg, nparams);
      FS.AddLocVar(namedVarArg, FS.NCode, nparams);
      Emit(OP_MOVE, nparams, nparams, 0);  // no-op, marks table reg
    end;
  end
  else
    FS.FreeReg := nparams;
  proto.NumParams := nparams;
  // parse body
  while Lex.Tok <> tkEnd do
  begin
    if Lex.Tok = tkReturn then
      ReturnStat
    else
      Statement;
  end;
  Next; // skip end
  // close top block (solves gotos)
  CloseBlockHere;
  if FS.NeedClose then
    Emit(OP_CLOSE, 0, 0, 0);
  Emit(OP_RETURN, 0, 1, 0);
  proto.LastLineDefined := Lex.Line;
  proto.Code := Copy(FS.Code, 0, FS.NCode);
  proto.K := Copy(FS.K, 0, FS.NK);
  proto.Protos := Copy(FS.Protos, 0, FS.NProtos);
  proto.UpvalDescs := Copy(FS.Upvals, 0, FS.NUpvals);
  proto.LocVars := Copy(FS.LocVars, 0, FS.NLocVars);
  FS := saved;
  child.Free;
  Result := proto;
end;

// ================= remaining statements =================

procedure TCompiler.LocalStat;
var
  names: array of TStringObj;
  attrs: array of TVarKind;
  regs: array of Integer;
  nvars: Integer;
  i: Integer;
  t0: Integer;
  proto: TProto;
  pidx, r: Integer;
  fn: string;
begin
  Next; // skip local
  if Lex.Tok = tkFunction then
  begin
    FuncStat(True, False);
    Exit;
  end;
  nvars := 0;
  SetLength(names, 4);
  SetLength(attrs, 4);
  SetLength(regs, 4);
  while True do
  begin
    if Lex.Tok <> tkName then Error('<name> expected');
    fn := Lex.NameVal;
    Next;
    if nvars >= Length(names) then
    begin
      SetLength(names, nvars * 2);
      SetLength(attrs, nvars * 2);
      SetLength(regs, nvars * 2);
    end;
    names[nvars] := L.NewString(RawByteString(fn));
    attrs[nvars] := vkLocal;
    if Lex.Tok = tkLt then
      attrs[nvars] := GetVarAttribute(vkLocal);
    Inc(nvars);
    if not TestNext(tkComma) then
      Break;
  end;
  if TestNext(tkAssign) then
  begin
    t0 := FS.FreeReg;
    CompileExplist(nvars);
    // declare locals
    for i := 0 to nvars - 1 do
    begin
      regs[i] := FS.AllocReg;
      FS.AddLocal(names[i], attrs[i], regs[i]);
      FS.AddLocVar(names[i], FS.NCode, regs[i]);
      if attrs[i] = vkClose then
      begin
        FS.MarkTbc(regs[i]);
        Emit(OP_TBC, regs[i], 0, 0);
      end;
    end;
    if GetEnvironmentVariable('LUA_TRACE') <> '' then
      WriteLn(ErrOutput, 'LocalStat assign: t0=', t0, ' nvars=', nvars, ' freereg=', FS.FreeReg);
    for i := 0 to nvars - 1 do
      Emit(OP_MOVE, regs[i], t0 + i, 0);
  end
  else
  begin
    for i := 0 to nvars - 1 do
    begin
      regs[i] := FS.AllocReg;
      FS.AddLocal(names[i], attrs[i], regs[i]);
      FS.AddLocVar(names[i], FS.NCode, regs[i]);
      if attrs[i] = vkClose then
      begin
        FS.MarkTbc(regs[i]);
        Emit(OP_TBC, regs[i], 0, 0);
      end;
    end;
  end;
end;

procedure TCompiler.GlobalStat;
var
  names: array of TStringObj;
  attrs: array of TVarKind;
  nvars: Integer;
  i: Integer;
  t0: Integer;
  envReg, oldReg: Integer;
  k: Integer;
  fn: string;
  defKind: TVarKind;
  envIsUpv: Boolean;
  envIdx: Integer;
begin
  Next; // skip global
  defKind := vkGlobal;
  if Lex.Tok = tkLt then
  begin
    Next;
    if Lex.Tok <> tkName then Error('attribute expected');
    if Lex.NameVal = 'const' then defKind := vkGlobalConst
    else Error('unknown attribute');
    Next;
    Expect(tkGt);
  end;
  if Lex.Tok = tkFunction then
  begin
    FuncStat(False, True);
    Exit;
  end;
  if Lex.Tok = tkStar then
  begin
    Next;
    FS.AddLocal(nil, defKind, 0);
    Exit;
  end;
  nvars := 0;
  SetLength(names, 4);
  SetLength(attrs, 4);
  while True do
  begin
    if Lex.Tok <> tkName then Error('<name> expected');
    fn := Lex.NameVal;
    Next;
    if nvars >= Length(names) then
    begin
      SetLength(names, nvars * 2);
      SetLength(attrs, nvars * 2);
    end;
    names[nvars] := L.NewString(RawByteString(fn));
    attrs[nvars] := defKind;
    if Lex.Tok = tkLt then
      attrs[nvars] := GetVarAttribute(defKind);
    Inc(nvars);
    if not TestNext(tkComma) then
      Break;
  end;
  // declare globals first
  for i := 0 to nvars - 1 do
    FS.AddLocal(names[i], attrs[i], 0);
  if TestNext(tkAssign) then
  begin
    t0 := FS.FreeReg;
    CompileExplist(nvars);
    for i := 0 to nvars - 1 do
    begin
      k := FS.AddStr(names[i].ToStr);
      oldReg := FS.AllocReg;
      envIsUpv := False;
      envIdx := 0;
      ResolveEnv(envIsUpv, envIdx);
      if envIsUpv then
        Emit(OP_GETTABUP, oldReg, envIdx, k)
      else
        Emit(OP_GETFIELD, oldReg, envIdx, k);
      Emit(OP_ERRNNIL, oldReg, k, 0);
      if envIsUpv then
        Emit(OP_SETTABUP, envIdx, k, t0 + i)
      else
        Emit(OP_SETFIELD, envIdx, k, t0 + i);
    end;
  end;
end;

procedure TCompiler.FuncStat(isLocal, isGlobal: Boolean);
var
  fn: string;
  name: TStringObj;
  lv: TLValue;
  isMethod: Boolean;
  proto: TProto;
  pidx, r, r2: Integer;
  envReg, oldReg, k: Integer;
  kind: TResKind;
  idx: Integer;
  isConst2: Boolean;
  baseReg: Integer;
  envIsUpv: Boolean;
  envIdx: Integer;
begin
  Next; // skip function
  if Lex.Tok <> tkName then Error('<name> expected');
  fn := Lex.NameVal;
  name := L.NewString(RawByteString(fn));
  Next;
  if isLocal or isGlobal then
  begin
    // single name
    isMethod := False;
  end
  else
  begin
    // parse full name chain
    // build lvalue
    lv.Kind := lvLocal;
    lv.Name := fn;
    // resolve first name
    ResolveVar(FS, name, kind, idx, isConst2);
    lv.IsConst := isConst2;
    if kind = rkLocal then begin lv.Kind := lvLocal; lv.Reg := idx; end
    else if kind = rkUpval then begin lv.Kind := lvUpval; lv.UpIdx := idx; end
    else begin
      lv.Kind := lvGlobal;
      ResolveEnv(lv.EnvIsUpval, lv.EnvIdx);
      lv.KeyConst := FS.AddStr(fn);
    end;
    isMethod := False;
    while Lex.Tok = tkDot do
    begin
      Next;
      if Lex.Tok <> tkName then Error('<name> expected');
      fn := Lex.NameVal;
      Next;
      baseReg := CompileVarRead(lv);
      lv.Kind := lvField;
      lv.BaseTemp := True;
      lv.Reg := baseReg;
      lv.KeyConst := FS.AddStr(RawByteString(fn));
      lv.IsConst := False;
    end;
    if Lex.Tok = tkColon then
    begin
      Next;
      if Lex.Tok <> tkName then Error('<name> expected');
      fn := Lex.NameVal;
      Next;
      baseReg := CompileVarRead(lv);
      lv.Kind := lvField;
      lv.BaseTemp := True;
      lv.Reg := baseReg;
      lv.KeyConst := FS.AddStr(RawByteString(fn));
      lv.IsConst := False;
      isMethod := True;
    end;
  end;
  if isLocal then
  begin
    r := FS.AllocReg;
    FS.AddLocal(name, vkLocal, r);
  end;
  proto := CompileFunctionBody(isMethod);
  pidx := FS.AddProto(proto);
  r2 := FS.AllocReg;
  Emit(OP_CLOSURE, r2, pidx, 0);
  if isLocal then
  begin
    Emit(OP_MOVE, r, r2, 0);
    FS.AddLocVar(name, FS.NCode - 2, r);
  end
  else if isGlobal then
  begin
    FS.AddLocal(name, vkGlobal, 0);
    k := FS.AddStr(name.ToStr);
    oldReg := FS.AllocReg;
    envIsUpv := False;
    envIdx := 0;
    ResolveEnv(envIsUpv, envIdx);
    if envIsUpv then
      Emit(OP_GETTABUP, oldReg, envIdx, k)
    else
      Emit(OP_GETFIELD, oldReg, envIdx, k);
    Emit(OP_ERRNNIL, oldReg, k, 0);
    if envIsUpv then
      Emit(OP_SETTABUP, envIdx, k, r2)
    else
      Emit(OP_SETFIELD, envIdx, k, r2);
  end
  else
    AssignTo(lv, r2);
end;

procedure TCompiler.ReturnStat;
var
  t0: Integer;
  nexps: Integer;
  k: Integer;
  bval: Integer;
begin
  Next; // skip return
  if (Lex.Tok = tkEof) or (Lex.Tok = tkEnd) or (Lex.Tok = tkElse) or
     (Lex.Tok = tkElseIf) or (Lex.Tok = tkUntil) or (Lex.Tok = tkSemi) then
  begin
    if FS.NeedClose then
      Emit(OP_CLOSE, 0, 0, 0);
    Emit(OP_RETURN, 0, 1, 0);
    Exit;
  end;
  if FS.NeedClose then
    Emit(OP_CLOSE, 0, 0, 0);
  t0 := FS.FreeReg;
  FS.FreeTo(FS.ActiveReg);
  t0 := FS.FreeReg;
  nexps := CompileExplist(0);
  if ExplistMulti then
  begin
    if LastExplist.Reg <> nexps then
    begin
      bval := FS.Code[LastExplist.MultiPC].B;
      FS.Code[LastExplist.MultiPC].Op := OP_MOVE;
      FS.Code[LastExplist.MultiPC].A := nexps;
      FS.Code[LastExplist.MultiPC].B := LastExplist.Reg;
      FS.Code[LastExplist.MultiPC].C := 0;
      for k := 1 to bval - 1 do
        Emit(OP_MOVE, nexps + k, LastExplist.Reg + k, 0);
      k := Emit(OP_CALL, nexps, bval, 0);
      FS.Code[k].C := 0;
    end
    else
      MakeMulti(LastExplist, 0);
    Emit(OP_RETURN, 0, 0, 0);
  end
  else
  begin
    for k := 0 to nexps - 1 do
      if t0 + k <> k then
        Emit(OP_MOVE, k, t0 + k, 0);
    Emit(OP_RETURN, 0, nexps + 1, 0);
  end;
  FS.FreeReg := t0;
  if Lex.Tok = tkSemi then Next;
end;

procedure TCompiler.ExprStat;
var
  lhss: array of TLValue;
  n: Integer;
  i: Integer;
  t0: Integer;
  lv: TLValue;
begin
  CallWant := 0;
  lv := CompileLValue;
  if lv.IsMulti then
    Exit;  // function call statement; call already emitted
  CallWant := 1;
  n := 0;
  SetLength(lhss, 4);
  lhss[n] := lv;
  Inc(n);
  while Lex.Tok = tkComma do
  begin
    Next;
    if n >= Length(lhss) then SetLength(lhss, n * 2);
    lhss[n] := CompileLValue;
    Inc(n);
  end;
  Expect(tkAssign);
  t0 := FS.FreeReg;
  CompileExplist(n);
  for i := 0 to n - 1 do
    AssignTo(lhss[i], t0 + i);
end;

// ================= compile main =================

function TCompiler.Compile: TFunction;
var
  i: Integer;
begin
  Chunk;
  // close remaining blocks
  if FS.NeedClose then
    Emit(OP_CLOSE, 0, 0, 0);
  Emit(OP_RETURN, 0, 1, 0);
  // solve pending gotos at top block
  SolveGotos(0);
  if FS.NGotos > 0 then
    Error(Format('no visible label ''%s''', [FS.Gotos[0].Name.ToStr]));
  MainFS.Proto.Code := Copy(MainFS.Code, 0, MainFS.NCode);
  MainFS.Proto.K := Copy(MainFS.K, 0, MainFS.NK);
  MainFS.Proto.Protos := Copy(MainFS.Protos, 0, MainFS.NProtos);
  MainFS.Proto.UpvalDescs := Copy(MainFS.Upvals, 0, MainFS.NUpvals);
  MainFS.Proto.LocVars := Copy(MainFS.LocVars, 0, MainFS.NLocVars);
  MainFS.Proto.LastLineDefined := Lex.Line;
  SetLength(MainFS.Proto.LineInfo, MainFS.NCode);
  Result := TFunction.CreateLua(L, MainFS.Proto);
end;

// ================= dump / undump =================

type
  TDumper = class
  public
    Buf: RawByteString;
    procedure Byte1(b: Byte);
    procedure Int4(v: Integer);
    procedure Int8(v: Int64);
    procedure Str(const s: RawByteString);
    procedure DumpValue(const v: TLuaValue);
    procedure DumpProto(p: TProto; strip: Boolean);
  end;

procedure TDumper.Byte1(b: Byte);
begin
  Buf := Buf + Chr(b);
end;

procedure TDumper.Int4(v: Integer);
begin
  Buf := Buf + Chr(v and $FF) + Chr((v shr 8) and $FF) + Chr((v shr 16) and $FF) + Chr((v shr 24) and $FF);
end;

procedure TDumper.Int8(v: Int64);
var
  u: QWord;
  i: Integer;
begin
  u := QWord(v);
  for i := 0 to 7 do
    Buf := Buf + Chr((u shr (i * 8)) and $FF);
end;

procedure TDumper.Str(const s: RawByteString);
var
  len: Integer;
begin
  len := Length(s);
  Int4(len);
  if len > 0 then
    Buf := Buf + s;
end;

procedure TDumper.DumpValue(const v: TLuaValue);
begin
  case v.Vt of
    vtNil: Byte1(0);
    vtBool: if v.B then Byte1(2) else Byte1(1);
    vtInt: begin Byte1(3); Int8(v.I); end;
    vtFlt: begin Byte1(4); Int8(PInt64(@v.N)^); end;
    vtStr: begin Byte1(5); Str(v.S.ToStr); end;
  end;
end;

procedure TDumper.DumpProto(p: TProto; strip: Boolean);
var
  i: Integer;
begin
  Byte1(p.NumParams);
  Byte1(Ord(p.IsVararg));
  Byte1(p.MaxStackSize);
  Int4(p.Linedefined);
  Int4(p.LastLineDefined);
  if strip or (p.Source = nil) then
    Str('')
  else
    Str(p.Source.ToStr);
  Int4(Length(p.Code));
  for i := 0 to Length(p.Code) - 1 do
  begin
    Byte1(p.Code[i].Op);
    Int4(p.Code[i].A);
    Int4(p.Code[i].B);
    Int4(p.Code[i].C);
  end;
  Int4(Length(p.K));
  for i := 0 to Length(p.K) - 1 do
    DumpValue(p.K[i]);
  Int4(Length(p.Protos));
  for i := 0 to Length(p.Protos) - 1 do
    DumpProto(p.Protos[i], strip);
  Int4(Length(p.UpvalDescs));
  for i := 0 to Length(p.UpvalDescs) - 1 do
  begin
    if strip then
      Str('')
    else if p.UpvalDescs[i].Name = nil then
      Str('')
    else
      Str(p.UpvalDescs[i].Name.ToStr);
    Byte1(Ord(p.UpvalDescs[i].InStack));
    Int4(p.UpvalDescs[i].Idx);
  end;
  if strip then
  begin
    Int4(0);  // lineinfo
    Int4(0);  // locvars
  end
  else
  begin
    Int4(Length(p.LineInfo));
    for i := 0 to Length(p.LineInfo) - 1 do
      Int4(p.LineInfo[i]);
    Int4(Length(p.LocVars));
    for i := 0 to Length(p.LocVars) - 1 do
    begin
      if p.LocVars[i].Name = nil then Str('') else Str(p.LocVars[i].Name.ToStr);
      Int4(p.LocVars[i].StartPC);
      Int4(p.LocVars[i].EndPC);
    end;
  end;
end;

function LuaDump(L: TLua; f: TFunction; strip: Boolean): RawByteString;
var
  d: TDumper;
begin
  d := TDumper.Create;
  try
    d.Buf := #27 + 'PLua' + Chr(1);
    d.DumpProto(f.Proto, strip);
    Result := d.Buf;
  finally
    d.Free;
  end;
end;

type
  TUndumper = class
  public
    L: TLua;
    Data: RawByteString;
    Pos: Integer;
    function Byte1: Byte;
    function Int4: Integer;
    function Int8: Int64;
    function Str: RawByteString;
    function ReadValue: TLuaValue;
    function ReadProto: TProto;
  end;

function TUndumper.Byte1: Byte;
begin
  Result := Byte(Data[Pos]);
  Inc(Pos);
end;

function TUndumper.Int4: Integer;
begin
  Result := Byte(Data[Pos]) or (Byte(Data[Pos+1]) shl 8) or
            (Byte(Data[Pos+2]) shl 16) or (Byte(Data[Pos+3]) shl 24);
  Inc(Pos, 4);
end;

function TUndumper.Int8: Int64;
var
  u: QWord;
  i: Integer;
begin
  u := 0;
  for i := 0 to 7 do
    u := u or (QWord(Byte(Data[Pos + i])) shl (i * 8));
  Inc(Pos, 8);
  Result := Int64(u);
end;

function TUndumper.Str: RawByteString;
var
  len: Integer;
begin
  len := Int4;
  if (len < 0) or (len > Length(Data) - Pos + 1) then
    raise ELuaError.CreateMsg(Format('bad string length %d at pos %d (data len %d)', [len, Pos, Length(Data)]));
  SetLength(Result, len);
  if len > 0 then
  begin
    Move(Data[Pos], Result[1], len);
    Inc(Pos, len);
  end;
end;

function TUndumper.ReadValue: TLuaValue;
var
  t: Byte;
  i: Int64;
  n: Double;
begin
  t := Byte1;
  case t of
    0: Result := LuaNil;
    1: Result := LuaBool(False);
    2: Result := LuaBool(True);
    3: begin i := Int8; Result := LuaInt(i); end;
    4: begin i := Int8; n := PDouble(@i)^; Result := LuaNum(n); end;
    5: begin Result := LuaStr(L.NewString(Str)); end;
  else
    Result := LuaNil;
  end;
end;

function TUndumper.ReadProto: TProto;
var
  p: TProto;
  i, n: Integer;
  s: RawByteString;
begin
  p := TProto.Create(L);
  p.NumParams := Byte1;
  p.IsVararg := Byte1 <> 0;
  p.MaxStackSize := Byte1;
  p.Linedefined := Int4;
  p.LastLineDefined := Int4;
  s := Str;
  if s <> '' then
    p.Source := L.NewString(s)
  else
    p.Source := nil;
  n := Int4;
  SetLength(p.Code, n);
  for i := 0 to n - 1 do
  begin
    p.Code[i].Op := Byte1;
    p.Code[i].A := Int4;
    p.Code[i].B := Int4;
    p.Code[i].C := Int4;
  end;
  n := Int4;
  SetLength(p.K, n);
  for i := 0 to n - 1 do
    p.K[i] := ReadValue;
  n := Int4;
  SetLength(p.Protos, n);
  for i := 0 to n - 1 do
  begin
    p.Protos[i] := Self.ReadProto;
  end;
  n := Int4;
  SetLength(p.UpvalDescs, n);
  for i := 0 to n - 1 do
  begin
    s := Str;
    if s <> '' then
      p.UpvalDescs[i].Name := L.NewString(s)
    else
      p.UpvalDescs[i].Name := nil;
    p.UpvalDescs[i].InStack := Byte1 <> 0;
    p.UpvalDescs[i].Idx := Int4;
  end;
  n := Int4;
  SetLength(p.LineInfo, n);
  for i := 0 to n - 1 do
    p.LineInfo[i] := Int4;
  n := Int4;
  SetLength(p.LocVars, n);
  for i := 0 to n - 1 do
  begin
    s := Str;
    if s <> '' then
      p.LocVars[i].Name := L.NewString(s)
    else
      p.LocVars[i].Name := nil;
    p.LocVars[i].StartPC := Int4;
    p.LocVars[i].EndPC := Int4;
  end;
  Result := p;
end;

function LuaUndump(L: TLua; const data: RawByteString; const name: string): TFunction;
var
  u: TUndumper;
  p: TProto;
begin
  u := TUndumper.Create;
  try
    u.L := L;
    u.Data := data;
    u.Pos := 1;
    // skip signature
    u.Pos := 7;
    p := u.ReadProto;
  finally
    u.Free;
  end;
  if p.Source = nil then
    p.Source := L.NewString(RawByteString(name));
  Result := TFunction.CreateLua(L, p);
end;

function LuaCompile(L: TLua; const source: RawByteString; const name: string): TFunction;
var
  c: TCompiler;
begin
  c := TCompiler.Create(L, source, name);
  try
    Result := c.Compile;
  finally
    c.Free;
  end;
end;

end.
