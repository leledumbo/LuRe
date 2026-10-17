unit luacore;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math;

type
  TLua = class;
  TThread = class;
  TTable = class;
  TStringObj = class;
  TProto = class;
  TUpval = class;
  TFunction = class;
  TUserdata = class;

  TValueType = (vtNil, vtBool, vtInt, vtFlt, vtStr, vtTab, vtFunc,
                vtUser, vtThread, vtLight);

  TLuaValue = record
    case Vt: TValueType of
      vtNil: ();
      vtBool: (B: Boolean);
      vtInt: (I: Int64);
      vtFlt: (N: Double);
      vtStr: (S: TStringObj);
      vtTab: (T: TTable);
      vtFunc: (F: TFunction);
      vtUser: (U: TUserdata);
      vtThread: (Th: TThread);
      vtLight: (P: Pointer);
  end;
  PLuaValue = ^TLuaValue;

  TGCObject = class
  public
    NextGC: TGCObject;
    Marked: Boolean;
    Finalizing: Boolean;
    ObjType: Byte;
    constructor Create;
  end;

  // ---------------- strings ----------------
  TStringObj = class(TGCObject)
  public
    Len: SizeUInt;
    Hash: Cardinal;
    Data: PByte;
    procedure InitStr(const s: RawByteString; aHash: Cardinal);
    constructor CreateStr(const s: RawByteString; aHash: Cardinal);
    function ToStr: RawByteString;
    function Eq(const s2: TStringObj): Boolean;
    function EqRaw(const s2: RawByteString): Boolean;
    destructor Destroy; override;
  end;

  // ---------------- userdata ----------------
  TUserdata = class(TGCObject)
  public
    Data: Pointer;
    Len: SizeUInt;
    UsrValue: TLuaValue;
    Metatable: TTable;
    constructor Create(AL: TLua; aLen: SizeUInt);
    destructor Destroy; override;
  end;

  // ---------------- tables ----------------
  TTableNode = record
    Key: TLuaValue;
    Val: TLuaValue;
    Next: Integer;
  end;

  TTable = class(TGCObject)
  public
    Arr: array of TLuaValue;
    Asize: Integer;
    Node: array of TTableNode;
    Bucket: array of Integer;
    LastFree: Integer;
    Metatable: TTable;
    WeakKeys: Boolean;
    WeakValues: Boolean;
    LengthCache: Integer;
    constructor Create(AL: TLua; nArr, nRec: Integer);
    procedure SetMetatable(mt: TTable);
  end;

  // ---------------- upvalues ----------------
  TUpval = class(TGCObject)
  public
    V: TLuaValue;
    Open: PLuaValue;
    Next: TUpval;
    NextClosed: TUpval;
    StackIdx: Integer;
    Tbc: Boolean;
    constructor Create;
  end;

  // ---------------- prototypes ----------------
  TLocVar = record
    Name: TStringObj;
    StartPC: Integer;
    EndPC: Integer;
    Reg: Integer;
  end;

  TUpvalDesc = record
    Name: TStringObj;
    InStack: Boolean;
    Idx: Integer;
    IsConst: Boolean;
  end;

  TInstruction = record
    Op: Byte;
    A: Integer;
    B: Integer;
    C: Integer;
  end;

  TProto = class(TGCObject)
  public
    Code: array of TInstruction;
    K: array of TLuaValue;
    Protos: array of TProto;
    UpvalDescs: array of TUpvalDesc;
    NumParams: Integer;
    IsVararg: Boolean;
    MaxStackSize: Integer;
    Source: TStringObj;
    LineInfo: array of Integer;
    LocVars: array of TLocVar;
    LastLineDefined: Integer;
    Linedefined: Integer;
    constructor Create(AL: TLua);
  end;

  // ---------------- functions ----------------
  TCFunc = function(L: TLua): Integer;

  TFunction = class(TGCObject)
  public
    IsC: Boolean;
    Proto: TProto;
    Upvals: array of TUpval;
    CProc: TCFunc;
    VarArgTable: TTable;
    VarArgPreset: Boolean;
    EnvUpval: Integer;
    constructor CreateLua(AL: TLua; p: TProto);
    constructor CreateC(AL: TLua; f: TCFunc);
  end;

  // ---------------- call info / thread ----------------
  TCallInfo = record
    Func: TFunction;
    Base: Integer;
    Top: Integer;
    SavedPC: Integer;
    NResults: Integer;
    CallStatus: Integer;
    PrevCI: Integer;
    IsC: Boolean;
  end;

  TThread = class(TGCObject)
  public
    Main: TLua;
    Stack: array of TLuaValue;
    Top: Integer;
    CI: array of TCallInfo;
    NCI: Integer;
    OpenUpvals: TUpval;
    ClosedUpvals: TUpval;
    ErrorJmp: Boolean;
    Status: Integer;
    YieldVals: array of TLuaValue;
    YieldN: Integer;
    YieldResumeBase: Integer;
    YieldResumeN: Integer;
    constructor Create(AL: TLua; isMain: Boolean);
    procedure EnsureStack(n: Integer);
    function PushValue(const v: TLuaValue): Integer;
    procedure SetTop(idx: Integer);
  end;

  // ---------------- global state ----------------
  TStringEntry = class
    Str: TStringObj;
    Next: TStringEntry;
  end;

  TFinalizerProc = procedure(L: TLua; f: TFunction; obj: TLuaValue);

  TLua = class(TThread)
  public
    Registry: TTable;
    GlobalT: TTable;
    StringTable: array of TStringEntry;
    StringCount: Integer;
    AllGC: TGCObject;
    TotalBytes: SizeUInt;
    GCRunning: Boolean;
    GCMode: string;
    GCPause: Integer;
    GCStepMul: Integer;
    GCStepSize: Integer;
    GCThreshold: SizeUInt;
    LastGCBytes: SizeUInt;
    GCWork: Integer;
    GCInCycle: Boolean;
    MetaStr: TTable;
    MetaTab: TTable;
    MetaNum: TTable;
    MetaFunc: TTable;
    MetaThread: TTable;
    MetaUdata: TTable;
    FinalizerProc: TFinalizerProc;
    CurThread: TThread;
    AssertCount: Integer;
    UseEnv: Boolean;
    constructor CreateMain;
    destructor Destroy; override;
    procedure RegisterObject(o: TGCObject; size: SizeUInt);
    procedure UnregisterObject(o: TGCObject);
    function NewString(const s: RawByteString): TStringObj;
    function NewLongString(const s: RawByteString): TStringObj;
    function NewTable(nArr, nRec: Integer): TTable;
    function NewUserdata(len: SizeUInt): TUserdata;
    function NewThread: TThread;
    procedure CheckGC;
    procedure FullGC;
    function GCStep(size: Integer): Boolean;
    procedure SetGCMode(m: string);
    procedure SetGCParam(const p: string; v: Integer);
    function GetGCParam(const p: string): Integer;
  end;

  ELuaError = class(Exception)
  public
    ErrValue: TLuaValue;
    constructor CreateMsg(const m: string);
  end;

const
  LUA_MAXSHORTLEN = 40;
  MAXSTACK = 1000000;
  LUA_MININTEGER = Low(Int64);
  LUA_MAXINTEGER = High(Int64);

  OBJ_STR = 1; OBJ_TAB = 2; OBJ_PROTO = 3; OBJ_FUNC = 4;
  OBJ_UPVAL = 5; OBJ_USER = 6; OBJ_THREAD = 7;

  ST_OK = 0; ST_YIELD = 1; ST_DEAD = 2; ST_ERR = 3;

  TM_INDEX = 0; TM_NEWINDEX = 1; TM_GC = 2; TM_MODE = 3; TM_LEN = 4;
  TM_EQ = 5; TM_ADD = 6; TM_SUB = 7; TM_MUL = 8; TM_MOD = 9; TM_POW = 10;
  TM_DIV = 11; TM_IDIV = 12; TM_BAND = 13; TM_BOR = 14; TM_BXOR = 15;
  TM_SHL = 16; TM_SHR = 17; TM_UNM = 18; TM_BNOT = 19; TM_LT = 20;
  TM_LE = 21; TM_CONCAT = 22; TM_CALL = 23; TM_CLOSE = 24;
  TM_N = 25;

  // opcodes
  OP_MOVE = 0; OP_LOADNIL = 1; OP_LOADBOOL = 2; OP_LOADI = 3; OP_LOADK = 4;
  OP_GETUPVAL = 5; OP_SETUPVAL = 6;
  OP_GETTABUP = 7; OP_SETTABUP = 8;
  OP_GETTABLE = 9; OP_SETTABLE = 10;
  OP_GETFIELD = 11; OP_SETFIELD = 12;
  OP_NEWTABLE = 13; OP_SELF = 14;
  OP_ADD = 15; OP_SUB = 16; OP_MUL = 17; OP_DIV = 18; OP_IDIV = 19;
  OP_MOD = 20; OP_POW = 21;
  OP_BAND = 22; OP_BOR = 23; OP_BXOR = 24; OP_SHL = 25; OP_SHR = 26;
  OP_UNM = 27; OP_BNOT = 28; OP_NOT = 29; OP_LEN = 30;
  OP_CONCAT = 31; OP_JMP = 32; OP_JFALSE = 33; OP_JTRUE = 34;
  OP_EQ = 35; OP_LT = 36; OP_LE = 37; OP_TEST = 38; OP_TESTSET = 39;
  OP_CALL = 40; OP_TAILCALL = 41; OP_RETURN = 42;
  OP_VARARG = 43; OP_GETVARG = 44; OP_CLOSURE = 45; OP_SETLIST = 46;
  OP_CLOSE = 47; OP_TBC = 48; OP_FORPREP = 49; OP_FORLOOP = 50;
  OP_TFORCALL = 51; OP_TFORLOOP = 52; OP_ERRNNIL = 53; OP_LFALSESKIP = 54;

  MT_NAMES: array[0..TM_N-1] of string = (
    '__index', '__newindex', '__gc', '__mode', '__len', '__eq',
    '__add', '__sub', '__mul', '__mod', '__pow', '__div', '__idiv',
    '__band', '__bor', '__bxor', '__shl', '__shr', '__unm', '__bnot',
    '__lt', '__le', '__concat', '__call', '__close');

// ---------------- value helpers ----------------
function LuaNil: TLuaValue; inline;
function LuaBool(b: Boolean): TLuaValue; inline;
function LuaInt(i: Int64): TLuaValue; inline;
function LuaNum(n: Double): TLuaValue; inline;
function LuaStr(s: TStringObj): TLuaValue; inline;
function LuaTab(t: TTable): TLuaValue; inline;
function LuaFunc(f: TFunction): TLuaValue; inline;
function LuaUser(u: TUserdata): TLuaValue; inline;
function LuaThread(th: TThread): TLuaValue; inline;
function LuaLight(p: Pointer): TLuaValue; inline;

function IsNil(const v: TLuaValue): Boolean; inline;
function IsFalse(const v: TLuaValue): Boolean; inline;
function Truthy(const v: TLuaValue): Boolean; inline;
function VTypeName(const v: TLuaValue): string;
function RawEqual(const a, b: TLuaValue): Boolean;
function NumToStr(const v: TLuaValue): string;
function FltToStrVal(n: Double): string;
function StrToIntVal(const s: RawByteString; var i: Int64): Boolean;
function StrToNumVal(const s: RawByteString; var n: Double): Boolean;
function ToInteger(const v: TLuaValue; var i: Int64): Boolean;
function ToNumberVal(const v: TLuaValue; var n: Double): Boolean;
function FloatToInt(n: Double; var i: Int64; mode: Integer): Boolean;
function HashString(const s: RawByteString): Cardinal;
function SStr(L: TLua; const s: string): TStringObj;
function StaticStr(const s: string): TStringObj;

// ---------------- table operations ----------------
function TableGetStr(t: TTable; key: TStringObj): TLuaValue;
function TableGetInt(t: TTable; key: Int64): TLuaValue;
function TableGet(t: TTable; const key: TLuaValue): TLuaValue;
procedure TableSet(t: TTable; const key, val: TLuaValue);
procedure TableSetInt(t: TTable; key: Int64; const val: TLuaValue);
procedure TableSetStr(t: TTable; key: TStringObj; const val: TLuaValue);
function TableNext(t: TTable; const key: TLuaValue; var nk, nv: TLuaValue): Boolean;
function TableLength(t: TTable): Int64;
function TableCount(t: TTable): Integer;
procedure TableRehash(t: TTable);

implementation

function CFormatE(n: Double; digits: Integer): string; forward;
function CFormatF(n: Double; digits: Integer): string; forward;

var
  StaticStrings: array[0..127] of TStringEntry;

// ================= TGCObject =================
constructor TGCObject.Create;
begin
  inherited Create;
  Marked := False;
  Finalizing := False;
  NextGC := nil;
  ObjType := 0;
end;

// ================= TStringObj =================
procedure TStringObj.InitStr(const s: RawByteString; aHash: Cardinal);
begin
  ObjType := OBJ_STR;
  Len := SizeUInt(Length(s));
  Hash := aHash;
  GetMem(Data, Len + 1);
  if Len > 0 then
    Move(s[1], Data^, Len);
  Data[Len] := 0;
end;

constructor TStringObj.CreateStr(const s: RawByteString; aHash: Cardinal);
begin
  inherited Create;
  InitStr(s, aHash);
end;

destructor TStringObj.Destroy;
begin
  if Data <> nil then
    FreeMem(Data);
  inherited Destroy;
end;

function TStringObj.ToStr: RawByteString;
begin
  SetLength(Result, Len);
  if Len > 0 then
    Move(Data^, Result[1], Len);
end;

function TStringObj.Eq(const s2: TStringObj): Boolean;
begin
  if Self = s2 then
    Exit(True);
  if (Len <> s2.Len) or (Hash <> s2.Hash) then
    Exit(False);
  if Len = 0 then
    Exit(True);
  Result := CompareMem(Data, s2.Data, Len);
end;

function TStringObj.EqRaw(const s2: RawByteString): Boolean;
begin
  if Len <> SizeUInt(Length(s2)) then
    Exit(False);
  if Len = 0 then
    Exit(True);
  Result := CompareMem(Data, @s2[1], Len);
end;

function HashString(const s: RawByteString): Cardinal;
var
  i: Integer;
begin
  Result := Cardinal(Length(s));
  for i := 1 to Length(s) do
    Result := (Result shl 5) + Result + Cardinal(Byte(s[i]));
  Result := Result xor (Result shr 16);
end;

function StaticStr(const s: string): TStringObj;
var
  h: Cardinal;
  idx: Integer;
  e: TStringEntry;
begin
  h := HashString(RawByteString(s));
  idx := Integer(h and 127);
  e := StaticStrings[idx];
  while e <> nil do
  begin
    if (e.Str.Hash = h) and e.Str.EqRaw(RawByteString(s)) then
      Exit(e.Str);
    e := e.Next;
  end;
  Result := TStringObj.CreateStr(RawByteString(s), h);
  e := TStringEntry.Create;
  e.Str := Result;
  e.Next := StaticStrings[idx];
  StaticStrings[idx] := e;
end;

function SStr(L: TLua; const s: string): TStringObj;
begin
  if L <> nil then
    Result := L.NewString(RawByteString(s))
  else
    Result := StaticStr(s);
end;

// ================= TUserdata =================
constructor TUserdata.Create(AL: TLua; aLen: SizeUInt);
begin
  inherited Create;
  ObjType := OBJ_USER;
  Len := aLen;
  Data := nil;
  UsrValue := LuaNil;
  Metatable := nil;
  if aLen > 0 then
    GetMem(Data, aLen);
end;

destructor TUserdata.Destroy;
begin
  if Data <> nil then
    FreeMem(Data);
  inherited Destroy;
end;

// ================= TTable =================
constructor TTable.Create(AL: TLua; nArr, nRec: Integer);
begin
  inherited Create;
  ObjType := OBJ_TAB;
  Asize := 0;
  LastFree := 0;
  Metatable := nil;
  WeakKeys := False;
  WeakValues := False;
  SetLength(Arr, 0);
  SetLength(Node, 0);
  SetLength(Bucket, 0);
  if AL <> nil then
    AL.RegisterObject(Self, Self.InstanceSize);
end;

procedure TTable.SetMetatable(mt: TTable);
var
  mm: TLuaValue;
  s: string;
  i: Integer;
begin
  Metatable := mt;
  WeakKeys := False;
  WeakValues := False;
  if mt <> nil then
  begin
    mm := TableGetStr(mt, StaticStr('__mode'));
    if mm.Vt = vtStr then
    begin
      s := mm.S.ToStr;
      for i := 1 to Length(s) do
      begin
        if s[i] = 'k' then WeakKeys := True
        else if s[i] = 'v' then WeakValues := True;
      end;
    end;
  end;
end;

// ================= TUpval =================
constructor TUpval.Create;
begin
  inherited Create;
  ObjType := OBJ_UPVAL;
  V := LuaNil;
  Open := nil;
  Next := nil;
  NextClosed := nil;
  StackIdx := -1;
  Tbc := False;
end;

// ================= TProto =================
constructor TProto.Create(AL: TLua);
begin
  inherited Create;
  ObjType := OBJ_PROTO;
  NumParams := 0;
  IsVararg := False;
  MaxStackSize := 2;
  Source := nil;
  Linedefined := 0;
  LastLineDefined := 0;
  if AL <> nil then
    AL.RegisterObject(Self, Self.InstanceSize);
end;

// ================= TFunction =================
constructor TFunction.CreateLua(AL: TLua; p: TProto);
begin
  inherited Create;
  ObjType := OBJ_FUNC;
  IsC := False;
  Proto := p;
  CProc := nil;
  VarArgTable := nil;
  VarArgPreset := False;
  EnvUpval := -1;
  SetLength(Upvals, Length(p.UpvalDescs));
  if AL <> nil then
    AL.RegisterObject(Self, Self.InstanceSize);
end;

constructor TFunction.CreateC(AL: TLua; f: TCFunc);
begin
  inherited Create;
  ObjType := OBJ_FUNC;
  IsC := True;
  Proto := nil;
  CProc := f;
  VarArgTable := nil;
  EnvUpval := -1;
  SetLength(Upvals, 0);
  if AL <> nil then
    AL.RegisterObject(Self, Self.InstanceSize);
end;

// ================= TThread =================
constructor TThread.Create(AL: TLua; isMain: Boolean);
begin
  inherited Create;
  ObjType := OBJ_THREAD;
  Top := 0;
  NCI := 0;
  OpenUpvals := nil;
  ClosedUpvals := nil;
  ErrorJmp := False;
  Status := ST_OK;
  SetLength(Stack, 64);
  SetLength(CI, 16);
  if isMain then
    Main := nil
  else
    Main := AL;
  if (AL <> nil) and not isMain then
    AL.RegisterObject(Self, Self.InstanceSize);
end;

procedure TThread.EnsureStack(n: Integer);
var
  ns: Integer;
  u: TUpval;
begin
  if n <= Length(Stack) then
    Exit;
  ns := Length(Stack) * 2;
  while ns < n do
    ns := ns * 2;
  if ns > MAXSTACK then
    raise ELuaError.CreateMsg('stack overflow');
  SetLength(Stack, ns);
  // re-point open upvalues after reallocation
  u := OpenUpvals;
  while u <> nil do
  begin
    if u.Open <> nil then
      u.Open := @Stack[u.StackIdx];
    u := u.Next;
  end;
end;

function TThread.PushValue(const v: TLuaValue): Integer;
begin
  EnsureStack(Top + 1);
  Stack[Top] := v;
  Result := Top;
  Inc(Top);
end;

procedure TThread.SetTop(idx: Integer);
begin
  if idx > Top then
  begin
    EnsureStack(idx);
    while Top < idx do
    begin
      Stack[Top] := LuaNil;
      Inc(Top);
    end;
  end
  else
    Top := idx;
end;

// ================= ELuaError =================
constructor ELuaError.CreateMsg(const m: string);
begin
  inherited Create(m);
  ErrValue := LuaNil;
end;

// ================= value helpers =================
function LuaNil: TLuaValue; inline;
begin
  Result.Vt := vtNil;
end;

function LuaBool(b: Boolean): TLuaValue; inline;
begin
  Result.Vt := vtBool;
  Result.B := b;
end;

function LuaInt(i: Int64): TLuaValue; inline;
begin
  Result.Vt := vtInt;
  Result.I := i;
end;

function LuaNum(n: Double): TLuaValue; inline;
begin
  Result.Vt := vtFlt;
  Result.N := n;
end;

function LuaStr(s: TStringObj): TLuaValue; inline;
begin
  Result.Vt := vtStr;
  Result.S := s;
end;

function LuaTab(t: TTable): TLuaValue; inline;
begin
  Result.Vt := vtTab;
  Result.T := t;
end;

function LuaFunc(f: TFunction): TLuaValue; inline;
begin
  Result.Vt := vtFunc;
  Result.F := f;
end;

function LuaUser(u: TUserdata): TLuaValue; inline;
begin
  Result.Vt := vtUser;
  Result.U := u;
end;

function LuaThread(th: TThread): TLuaValue; inline;
begin
  Result.Vt := vtThread;
  Result.Th := th;
end;

function LuaLight(p: Pointer): TLuaValue; inline;
begin
  Result.Vt := vtLight;
  Result.P := p;
end;

function IsNil(const v: TLuaValue): Boolean; inline;
begin
  Result := v.Vt = vtNil;
end;

function IsFalse(const v: TLuaValue): Boolean; inline;
begin
  Result := (v.Vt = vtNil) or ((v.Vt = vtBool) and not v.B);
end;

function Truthy(const v: TLuaValue): Boolean; inline;
begin
  Result := not IsFalse(v);
end;

function VTypeName(const v: TLuaValue): string;
begin
  case v.Vt of
    vtNil: Result := 'nil';
    vtBool: Result := 'boolean';
    vtInt, vtFlt: Result := 'number';
    vtStr: Result := 'string';
    vtTab: Result := 'table';
    vtFunc: Result := 'function';
    vtUser: Result := 'userdata';
    vtThread: Result := 'thread';
    vtLight: Result := 'userdata';
  end;
end;

function RawEqual(const a, b: TLuaValue): Boolean;
begin
  if a.Vt <> b.Vt then
  begin
    if (a.Vt = vtInt) and (b.Vt = vtFlt) then
      Exit(Double(a.I) = b.N);
    if (a.Vt = vtFlt) and (b.Vt = vtInt) then
      Exit(a.N = Double(b.I));
    Exit(False);
  end;
  case a.Vt of
    vtNil: Result := True;
    vtBool: Result := a.B = b.B;
    vtInt: Result := a.I = b.I;
    vtFlt: Result := a.N = b.N;
    vtStr: Result := a.S.Eq(b.S);
    vtTab: Result := a.T = b.T;
    vtFunc: Result := a.F = b.F;
    vtUser: Result := a.U = b.U;
    vtThread: Result := a.Th = b.Th;
    vtLight: Result := a.P = b.P;
  end;
end;

function FloatToInt(n: Double; var i: Int64; mode: Integer): Boolean;
var
  r: Double;
begin
  if IsNaN(n) or IsInfinite(n) then
    Exit(False);
  if (n < Double(LUA_MININTEGER)) or (n > Double(LUA_MAXINTEGER)) then
    Exit(False);
  case mode of
    0: r := Trunc(n);
    1: r := Floor(n);
    2: r := Ceil(n);
  end;
  i := Trunc(r);
  Result := True;
end;

function StrToIntVal(const s: RawByteString; var i: Int64): Boolean;
var
  code: Integer;
  v: Int64;
begin
  if s = '' then
    Exit(False);
  Val(string(s), v, code);
  if code <> 0 then
    Exit(False);
  i := v;
  Result := True;
end;

function StrToNumVal(const s: RawByteString; var n: Double): Boolean;
var
  code: Integer;
  v: Double;
begin
  if s = '' then
    Exit(False);
  Val(string(s), v, code);
  if code <> 0 then
    Exit(False);
  n := v;
  Result := True;
end;

function ToInteger(const v: TLuaValue; var i: Int64): Boolean;
var
  n: Double;
  s: RawByteString;
begin
  case v.Vt of
    vtInt: begin i := v.I; Exit(True); end;
    vtFlt: begin
      if IsNaN(v.N) or IsInfinite(v.N) then Exit(False);
      Exit(FloatToInt(v.N, i, 0));
    end;
    vtStr: begin
      s := v.S.ToStr;
      if StrToIntVal(s, i) then
        Exit(True);
      if StrToNumVal(s, n) then
        Exit(FloatToInt(n, i, 0));
      Exit(False);
    end;
  end;
  Result := False;
end;

function ToNumberVal(const v: TLuaValue; var n: Double): Boolean;
begin
  case v.Vt of
    vtInt: begin n := Double(v.I); Exit(True); end;
    vtFlt: begin n := v.N; Exit(True); end;
    vtStr: Exit(StrToNumVal(v.S.ToStr, n));
  end;
  Result := False;
end;

// C-like %g with given precision
function CFormatG(n: Double; prec: Integer): string;
var
  exp: Integer;
  a: Double;
  s: string;
  i: Integer;
  useExp: Boolean;
begin
  if IsNaN(n) then Exit('nan');
  if IsInfinite(n) then
  begin
    if n > 0 then Exit('inf') else Exit('-inf');
  end;
  if n = 0 then
    Exit('0');
  a := Abs(n);
  exp := Floor(Log10(a));
  if a < 1 then
    exp := Floor(Log10(a));
  // %g uses exponent form if exp < -4 or exp >= prec
  useExp := (exp < -4) or (exp >= prec);
  if useExp then
  begin
    s := CFormatE(n, prec - 1);
    // strip trailing zeros in mantissa
    if Pos('e', s) > 0 then
    begin
      i := Pos('e', s) - 1;
      while (i > 1) and (s[i] = '0') do
        Delete(s, i, 1);
      while (i > 1) and (s[i] = '0') do
      begin
        Delete(s, i, 1);
        Dec(i);
      end;
      if (i >= 1) and (s[i] = '.') then
        Delete(s, i, 1);
    end;
    Result := s;
  end
  else
  begin
    Result := CFormatF(n, prec - 1 - exp);
    // strip trailing zeros after decimal point
    if Pos('.', Result) > 0 then
    begin
      while Result[Length(Result)] = '0' do
        Delete(Result, Length(Result), 1);
      if Result[Length(Result)] = '.' then
        Delete(Result, Length(Result), 1);
    end;
  end;
end;

// C-like %e with given digits after decimal point
function CFormatE(n: Double; digits: Integer): string;
var
  neg: Boolean;
  a: Double;
  exp: Integer;
  mant: string;
  i: Integer;
  e: string;
begin
  if IsNaN(n) then Exit('nan');
  if IsInfinite(n) then
  begin
    if n > 0 then Exit('inf') else Exit('-inf');
  end;
  neg := n < 0;
  a := Abs(n);
  if a = 0 then
    exp := 0
  else
    exp := Floor(Log10(a));
  mant := FloatToStrF(a / Power(10, exp), ffFixed, 0, digits);
  // normalize mantissa (e.g. 9.999999 -> 10.000000)
  if mant[1] = '1' then
  begin
    // check if mantissa rounds to 10
    if (Length(mant) > 1) and (mant[1] = '1') and (mant[2] = '0') then
    begin
      // count
      i := 2;
      while (i <= Length(mant)) and (mant[i] = '0') do Inc(i);
      if i > Length(mant) then
      begin
        mant := '1.' + StringOfChar('0', digits);
        Inc(exp);
      end;
    end;
  end;
  if neg then
    e := '-'
  else
    e := '';
  if exp >= 0 then
    e := e + 'e+' + Format('%0.2d', [exp])
  else
    e := e + 'e-' + Format('%0.2d', [-exp]);
  Result := e + mant;
end;

// C-like %f with given digits after decimal point
function CFormatF(n: Double; digits: Integer): string;
begin
  Result := FloatToStrF(n, ffFixed, 0, digits);
end;

function FltToStrVal(n: Double): string;
var
  s: string;
  i: Integer;
  check: Double;
begin
  if IsNaN(n) then
    Exit('nan');
  if IsInfinite(n) then
  begin
    if n > 0 then Exit('inf') else Exit('-inf');
  end;
  s := CFormatG(n, 15);
  // round-trip check
  if not StrToNumVal(RawByteString(s), check) or (check <> n) then
    s := CFormatG(n, 17);
  // looks like integer?
  i := 1;
  if (Length(s) > 0) and (s[1] = '-') then i := 2;
  while (i <= Length(s)) and (s[i] >= '0') and (s[i] <= '9') do Inc(i);
  if i > Length(s) then
    s := s + '.0';
  Result := s;
end;

function NumToStr(const v: TLuaValue): string;
begin
  case v.Vt of
    vtInt: Result := IntToStr(v.I);
    vtFlt: Result := FltToStrVal(v.N);
  else
    Result := '';
  end;
end;

// ================= table internals =================

function HashKey(const key: TLuaValue; sizenode: Integer): Integer;
var
  h: Cardinal;
  k: Int64;
begin
  case key.Vt of
    vtStr: h := key.S.Hash;
    vtInt: begin
      k := key.I;
      h := Cardinal(k) xor Cardinal(k shr 32);
    end;
    vtFlt: begin
      k := Trunc(key.N);
      h := Cardinal(k) xor Cardinal(k shr 32);
    end;
    vtBool: h := Cardinal(Ord(key.B));
    vtLight: h := Cardinal(PtrUInt(key.P));
  else
    h := Cardinal(PtrUInt(key.T));
  end;
  Result := Integer(h and Cardinal(sizenode - 1));
end;

procedure TableEnsureHash(t: TTable);
var
  i: Integer;
begin
  if Length(t.Bucket) > 0 then
    Exit;
  SetLength(t.Bucket, 4);
  SetLength(t.Node, 4);
  for i := 0 to 3 do
  begin
    t.Bucket[i] := -1;
    t.Node[i].Key := LuaNil;
    t.Node[i].Val := LuaNil;
    t.Node[i].Next := i + 1;
  end;
  t.Node[3].Next := -1;
  t.LastFree := 0;
end;

function FindNode(t: TTable; const key: TLuaValue): Integer;
var
  b, i: Integer;
begin
  if Length(t.Bucket) = 0 then
    Exit(-1);
  b := HashKey(key, Length(t.Bucket));
  i := t.Bucket[b];
  while i >= 0 do
  begin
    if (t.Node[i].Val.Vt <> vtNil) and RawEqual(t.Node[i].Key, key) then
      Exit(i);
    i := t.Node[i].Next;
  end;
  Result := -1;
end;

function CountInRange(const keys: array of TLuaValue; cnt, limit: Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to cnt - 1 do
  begin
    if (keys[i].Vt = vtInt) and (keys[i].I >= 1) and (keys[i].I <= limit) then
      Inc(Result);
  end;
end;

procedure TableRehash(t: TTable);
var
  keys, vals: array of TLuaValue;
  cnt, total, i, nasize, next, c: Integer;
  nhsize: Integer;
  b: Integer;
  f: Integer;
begin
  cnt := 0;
  SetLength(keys, 16);
  SetLength(vals, 16);
  for i := 0 to Length(t.Arr) - 1 do
  begin
    if not IsNil(t.Arr[i]) then
    begin
      if cnt >= Length(keys) then
      begin
        SetLength(keys, cnt * 2);
        SetLength(vals, cnt * 2);
      end;
      keys[cnt] := LuaInt(i + 1);
      vals[cnt] := t.Arr[i];
      Inc(cnt);
    end;
  end;
  for i := 0 to Length(t.Node) - 1 do
  begin
    if not IsNil(t.Node[i].Val) then
    begin
      if cnt >= Length(keys) then
      begin
        SetLength(keys, cnt * 2);
        SetLength(vals, cnt * 2);
      end;
      keys[cnt] := t.Node[i].Key;
      vals[cnt] := t.Node[i].Val;
      Inc(cnt);
    end;
  end;
  total := cnt;
  nasize := 0;
  if total > 0 then
  begin
    next := 1;
    while next <= total do
    begin
      c := CountInRange(keys, cnt, next);
      if c >= next div 2 then
        nasize := next
      else
        Break;
      if next >= 1 shl 28 then Break;
      if next >= total then Break;
      next := next * 2;
    end;
  end;
  c := total - CountInRange(keys, cnt, nasize);
  nhsize := 1;
  while nhsize < c * 2 do
    nhsize := nhsize * 2;
  if nhsize < 4 then nhsize := 4;
  t.Asize := nasize;
  // compute longest sequential prefix
  t.LengthCache := 0;
  for i := 0 to cnt - 1 do
  begin
    if (keys[i].Vt = vtInt) and (keys[i].I = t.LengthCache + 1) then
      Inc(t.LengthCache);
  end;
  while True do
  begin
    c := t.LengthCache + 1;
    if c > nasize then
    begin
      if not IsNil(TableGet(t, LuaInt(c))) then Inc(t.LengthCache) else Break;
    end
    else
      Break;
  end;
  SetLength(t.Arr, nasize);
  for i := 0 to nasize - 1 do
    t.Arr[i] := LuaNil;
  SetLength(t.Bucket, nhsize);
  SetLength(t.Node, nhsize);
  for i := 0 to nhsize - 1 do
  begin
    t.Bucket[i] := -1;
    t.Node[i].Key := LuaNil;
    t.Node[i].Val := LuaNil;
    t.Node[i].Next := i + 1;
  end;
  t.Node[nhsize - 1].Next := -1;
  t.LastFree := 0;
  for i := 0 to cnt - 1 do
  begin
    if (keys[i].Vt = vtInt) and (keys[i].I >= 1) and (keys[i].I <= nasize) then
      t.Arr[keys[i].I - 1] := vals[i]
    else
    begin
      b := HashKey(keys[i], nhsize);
      f := t.LastFree;
      t.LastFree := t.Node[f].Next;
      t.Node[f].Key := keys[i];
      t.Node[f].Val := vals[i];
      t.Node[f].Next := t.Bucket[b];
      t.Bucket[b] := f;
    end;
  end;
end;

function TableGet(t: TTable; const key: TLuaValue): TLuaValue;
var
  idx: Integer;
  k: Int64;
begin
  case key.Vt of
    vtNil: Exit(LuaNil);
    vtInt: begin
      k := key.I;
      if (k >= 1) and (k <= t.Asize) then
      begin
        Result := t.Arr[k - 1];
        if not IsNil(Result) then Exit;
      end;
    end;
    vtFlt: begin
      if FloatToInt(key.N, k, 0) and (k >= 1) and (k <= t.Asize) then
      begin
        Result := t.Arr[k - 1];
        if not IsNil(Result) then Exit;
      end;
    end;
  end;
  idx := FindNode(t, key);
  if idx < 0 then
    Result := LuaNil
  else
    Result := t.Node[idx].Val;
end;

function TableGetStr(t: TTable; key: TStringObj): TLuaValue;
var
  idx: Integer;
begin
  if Length(t.Bucket) = 0 then
    Exit(LuaNil);
  idx := t.Bucket[HashKey(LuaStr(key), Length(t.Bucket))];
  while idx >= 0 do
  begin
    if (t.Node[idx].Val.Vt <> vtNil) and (t.Node[idx].Key.Vt = vtStr) and
       t.Node[idx].Key.S.Eq(key) then
      Exit(t.Node[idx].Val);
    idx := t.Node[idx].Next;
  end;
  Result := LuaNil;
end;

function TableGetInt(t: TTable; key: Int64): TLuaValue;
var
  idx: Integer;
begin
  if (key >= 1) and (key <= t.Asize) then
  begin
    Result := t.Arr[key - 1];
    if not IsNil(Result) then Exit;
  end;
  if Length(t.Bucket) = 0 then
    Exit(LuaNil);
  idx := t.Bucket[HashKey(LuaInt(key), Length(t.Bucket))];
  while idx >= 0 do
  begin
    if (t.Node[idx].Val.Vt <> vtNil) and (t.Node[idx].Key.Vt = vtInt) and
       (t.Node[idx].Key.I = key) then
      Exit(t.Node[idx].Val);
    idx := t.Node[idx].Next;
  end;
  Result := LuaNil;
end;

procedure TableSet(t: TTable; const key, val: TLuaValue);
var
  idx, b: Integer;
  k: Int64;
  nk: TLuaValue;
  prev: Integer;
  f: Integer;
begin
  if key.Vt = vtNil then
    Exit;
  nk := key;
  if nk.Vt = vtFlt then
  begin
    if FloatToInt(nk.N, k, 0) then
      nk := LuaInt(k);
  end;
  if nk.Vt = vtInt then
  begin
    k := nk.I;
    if (k >= 1) and (k <= t.Asize) then
    begin
      t.Arr[k - 1] := val;
      if not IsNil(val) then
      begin
        if k = t.LengthCache + 1 then
        begin
          t.LengthCache := k;
          while not IsNil(TableGetInt(t, t.LengthCache + 1)) do
            Inc(t.LengthCache);
        end;
      end;
      Exit;
    end;
  end;
  TableEnsureHash(t);
  b := HashKey(nk, Length(t.Bucket));
  prev := -1;
  idx := t.Bucket[b];
  while idx >= 0 do
  begin
    if RawEqual(t.Node[idx].Key, nk) then
      Break;
    prev := idx;
    idx := t.Node[idx].Next;
  end;
  if idx >= 0 then
  begin
    if IsNil(val) then
    begin
      if prev < 0 then
        t.Bucket[b] := t.Node[idx].Next
      else
        t.Node[prev].Next := t.Node[idx].Next;
      t.Node[idx].Val := LuaNil;
      t.Node[idx].Next := t.LastFree;
      t.LastFree := idx;
    end
    else
      t.Node[idx].Val := val;
  end
  else if not IsNil(val) then
  begin
    if t.LastFree < 0 then
    begin
      TableRehash(t);
      b := HashKey(nk, Length(t.Bucket));
    end;
    f := t.LastFree;
    t.LastFree := t.Node[f].Next;
    t.Node[f].Key := nk;
    t.Node[f].Val := val;
    t.Node[f].Next := t.Bucket[b];
    t.Bucket[b] := f;
    if (nk.Vt = vtInt) and (nk.I = t.LengthCache + 1) then
    begin
      t.LengthCache := nk.I;
      while not IsNil(TableGetInt(t, t.LengthCache + 1)) do
        Inc(t.LengthCache);
    end;
  end;
end;

procedure TableSetInt(t: TTable; key: Int64; const val: TLuaValue);
begin
  if (key >= 1) and (key <= t.Asize) then
    t.Arr[key - 1] := val
  else
    TableSet(t, LuaInt(key), val);
end;

procedure TableSetStr(t: TTable; key: TStringObj; const val: TLuaValue);
begin
  TableSet(t, LuaStr(key), val);
end;

function TableNext(t: TTable; const key: TLuaValue; var nk, nv: TLuaValue): Boolean;
var
  i, idx: Integer;
  k: Int64;
begin
  if key.Vt = vtNil then
    i := 0
  else if (key.Vt = vtInt) and (key.I >= 1) and (key.I <= t.Asize) then
    i := key.I
  else if (key.Vt = vtFlt) and FloatToInt(key.N, k, 0) and (k >= 1) and (k <= t.Asize) then
    i := k
  else
    i := t.Asize;
  while i < t.Asize do
  begin
    if not IsNil(t.Arr[i]) then
    begin
      nk := LuaInt(i + 1);
      nv := t.Arr[i];
      Exit(True);
    end;
    Inc(i);
  end;
  if Length(t.Node) = 0 then
    Exit(False);
  if key.Vt <> vtNil then
  begin
    if (key.Vt = vtInt) and (key.I >= 1) and (key.I <= t.Asize) then
      idx := Length(t.Node) - 1
    else
    begin
      idx := FindNode(t, key);
      if idx >= 0 then
        idx := idx - 1
      else
        idx := Length(t.Node) - 1;
    end;
  end
  else
    idx := Length(t.Node) - 1;
  while idx >= 0 do
  begin
    if not IsNil(t.Node[idx].Val) then
    begin
      nk := t.Node[idx].Key;
      nv := t.Node[idx].Val;
      Exit(True);
    end;
    Dec(idx);
  end;
  Result := False;
end;

function TableLength(t: TTable): Int64;
var
  lo, hi, mid: Int64;
begin
  lo := 0;
  hi := t.Asize + 1;
  while hi - lo > 1 do
  begin
    mid := (lo + hi) div 2;
    if not IsNil(TableGetInt(t, mid)) then
      lo := mid
    else
      hi := mid;
  end;
  if t.LengthCache > lo then
    lo := t.LengthCache;
  Result := lo;
end;

function TableCount(t: TTable): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to Length(t.Arr) - 1 do
    if not IsNil(t.Arr[i]) then Inc(Result);
  for i := 0 to Length(t.Node) - 1 do
    if not IsNil(t.Node[i].Val) then Inc(Result);
end;

// ================= TLua =================
constructor TLua.CreateMain;
begin
  inherited Create(nil, True);
  Main := Self;
  TotalBytes := 0;
  GCRunning := True;
  GCMode := 'incremental';
  GCPause := 200;
  GCStepMul := 100;
  GCStepSize := 13;
  GCThreshold := 512 * 1024;
  LastGCBytes := 0;
  GCWork := 0;
  GCInCycle := False;
  FinalizerProc := nil;
  SetLength(StringTable, 128);
  StringCount := 0;
  AllGC := nil;
  Registry := TTable.Create(Self, 0, 0);
  GlobalT := TTable.Create(Self, 0, 0);
  MetaStr := TTable.Create(Self, 0, 0);
  MetaTab := TTable.Create(Self, 0, 0);
  MetaNum := TTable.Create(Self, 0, 0);
  MetaFunc := TTable.Create(Self, 0, 0);
  MetaThread := TTable.Create(Self, 0, 0);
  MetaUdata := TTable.Create(Self, 0, 0);
end;

destructor TLua.Destroy;
begin
  inherited Destroy;
end;

procedure TLua.RegisterObject(o: TGCObject; size: SizeUInt);
begin
  o.NextGC := AllGC;
  AllGC := o;
  TotalBytes := TotalBytes + size;
end;

procedure TLua.UnregisterObject(o: TGCObject);
var
  prev, cur: TGCObject;
begin
  prev := nil;
  cur := AllGC;
  while cur <> nil do
  begin
    if cur = o then
    begin
      if prev = nil then
        AllGC := cur.NextGC
      else
        prev.NextGC := cur.NextGC;
      Exit;
    end;
    prev := cur;
    cur := cur.NextGC;
  end;
end;

function TLua.NewString(const s: RawByteString): TStringObj;
var
  h: Cardinal;
  idx: Integer;
  e: TStringEntry;
  len: SizeUInt;
begin
  len := SizeUInt(Length(s));
  if len <= LUA_MAXSHORTLEN then
  begin
    h := HashString(s);
    idx := Integer(h and Cardinal(Length(StringTable) - 1));
    e := StringTable[idx];
    while e <> nil do
    begin
      if (e.Str.Hash = h) and e.Str.EqRaw(s) then
        Exit(e.Str);
      e := e.Next;
    end;
    Result := TStringObj.CreateStr(s, h);
    e := TStringEntry.Create;
    e.Str := Result;
    e.Next := StringTable[idx];
    StringTable[idx] := e;
    Inc(StringCount);
    Result.Marked := True;
  end
  else
  begin
    Result := TStringObj.CreateStr(s, HashString(s));
    RegisterObject(Result, Result.InstanceSize + len + 1);
  end;
end;

function TLua.NewLongString(const s: RawByteString): TStringObj;
begin
  Result := TStringObj.CreateStr(s, HashString(s));
  RegisterObject(Result, Result.InstanceSize + SizeUInt(Length(s)) + 1);
end;

function TLua.NewTable(nArr, nRec: Integer): TTable;
begin
  Result := TTable.Create(Self, nArr, nRec);
end;

function TLua.NewUserdata(len: SizeUInt): TUserdata;
begin
  Result := TUserdata.Create(Self, len);
  RegisterObject(Result, Result.InstanceSize + len);
end;

function TLua.NewThread: TThread;
begin
  Result := TThread.Create(Self, False);
end;

// ================= GC =================

procedure MarkValue(L: TLua; const v: TLuaValue); forward;
procedure MarkTable(L: TLua; t: TTable); forward;
procedure MarkThread(L: TLua; th: TThread); forward;

procedure MarkObject(L: TLua; o: TGCObject);
var
  i: Integer;
  u: TUserdata;
begin
  if (o = nil) or o.Marked then
    Exit;
  o.Marked := True;
  case o.ObjType of
    OBJ_TAB: MarkTable(L, TTable(o));
    OBJ_FUNC: begin
      with TFunction(o) do
      begin
        if not IsC then
        begin
          MarkObject(L, Proto);
          for i := 0 to Length(Upvals) - 1 do
            MarkObject(L, Upvals[i]);
        end
        else
          for i := 0 to Length(Upvals) - 1 do
            MarkObject(L, Upvals[i]);
        MarkObject(L, VarArgTable);
      end;
    end;
    OBJ_PROTO: begin
      with TProto(o) do
      begin
        MarkObject(L, Source);
        for i := 0 to Length(K) - 1 do
          MarkValue(L, K[i]);
        for i := 0 to Length(Protos) - 1 do
          MarkObject(L, Protos[i]);
        for i := 0 to Length(UpvalDescs) - 1 do
          MarkObject(L, UpvalDescs[i].Name);
        for i := 0 to Length(LocVars) - 1 do
          MarkObject(L, LocVars[i].Name);
      end;
    end;
    OBJ_UPVAL: begin
      if TUpval(o).Open <> nil then
        MarkValue(L, TUpval(o).Open^)
      else
        MarkValue(L, TUpval(o).V);
    end;
    OBJ_USER: begin
      u := TUserdata(o);
      MarkObject(L, u.Metatable);
      MarkValue(L, u.UsrValue);
    end;
    OBJ_THREAD: MarkThread(L, TThread(o));
  end;
end;

procedure MarkThread(L: TLua; th: TThread);
var
  i: Integer;
  u: TUpval;
begin
  if (th = nil) or th.Marked then
    Exit;
  th.Marked := True;
  for i := 0 to th.Top - 1 do
    MarkValue(L, th.Stack[i]);
  for i := 0 to th.NCI - 1 do
    MarkObject(L, th.CI[i].Func);
  u := th.ClosedUpvals;
  while u <> nil do
  begin
    MarkObject(L, u);
    u := u.NextClosed;
  end;
end;

procedure MarkValue(L: TLua; const v: TLuaValue);
begin
  case v.Vt of
    vtStr: MarkObject(L, v.S);
    vtTab: MarkObject(L, v.T);
    vtFunc: MarkObject(L, v.F);
    vtUser: MarkObject(L, v.U);
    vtThread: MarkObject(L, v.Th);
  end;
end;

procedure MarkTable(L: TLua; t: TTable);
var
  i: Integer;
begin
  if (t = nil) or t.Marked then
    Exit;
  t.Marked := True;
  MarkObject(L, t.Metatable);
  for i := 0 to Length(t.Arr) - 1 do
    if not IsNil(t.Arr[i]) then
      MarkValue(L, t.Arr[i]);
  for i := 0 to Length(t.Node) - 1 do
  begin
    if not IsNil(t.Node[i].Val) then
    begin
      if not t.WeakKeys then
        MarkValue(L, t.Node[i].Key);
      if not t.WeakValues then
        MarkValue(L, t.Node[i].Val);
    end;
  end;
end;

function HasFinalizer(t: TTable): Boolean;
var
  mm: TLuaValue;
begin
  if (t = nil) or (t.Metatable = nil) then
    Exit(False);
  mm := TableGetStr(t.Metatable, StaticStr('__gc'));
  Result := mm.Vt = vtFunc;
end;

function ValueMarked(L: TLua; const v: TLuaValue): Boolean;
begin
  case v.Vt of
    vtStr: Result := v.S.Marked;
    vtTab: Result := v.T.Marked;
    vtFunc: Result := v.F.Marked;
    vtUser: Result := v.U.Marked;
    vtThread: Result := v.Th.Marked;
  else
    Result := True;
  end;
end;

procedure ClearWeakTables(L: TLua);
var
  o: TGCObject;
  t: TTable;
  i: Integer;
begin
  o := L.AllGC;
  while o <> nil do
  begin
    if (o.ObjType = OBJ_TAB) and o.Marked then
    begin
      t := TTable(o);
      if t.WeakKeys or t.WeakValues then
      begin
        for i := 0 to Length(t.Arr) - 1 do
        begin
          if (not IsNil(t.Arr[i])) and t.WeakValues and not ValueMarked(L, t.Arr[i]) then
            t.Arr[i] := LuaNil;
        end;
        for i := 0 to Length(t.Node) - 1 do
        begin
          if not IsNil(t.Node[i].Val) then
          begin
            if t.WeakKeys and not ValueMarked(L, t.Node[i].Key) then
            begin
              t.Node[i].Val := LuaNil;
              t.Node[i].Next := t.LastFree;
              t.LastFree := i;
            end
            else if t.WeakValues and not ValueMarked(L, t.Node[i].Val) then
            begin
              t.Node[i].Val := LuaNil;
              t.Node[i].Next := t.LastFree;
              t.LastFree := i;
            end;
          end;
        end;
      end;
    end;
    o := o.NextGC;
  end;
end;

function UserdataHasFinalizer(u: TUserdata): Boolean;
var
  mm: TLuaValue;
begin
  if (u = nil) or (u.Metatable = nil) then
    Exit(False);
  mm := TableGetStr(u.Metatable, StaticStr('__gc'));
  Result := mm.Vt = vtFunc;
end;

procedure TLua.FullGC;
var
  o, next, finz: TGCObject;
  f: TTable;
  u: TUserdata;
  mm: TLuaValue;
begin
  if GCInCycle then
    Exit;
  GCInCycle := True;
  try
    // 1. clear marks
    o := AllGC;
    while o <> nil do
    begin
      o.Marked := False;
      o := o.NextGC;
    end;
    // 2. mark roots
    MarkThread(Self, Self);
    MarkObject(Self, Registry);
    MarkObject(Self, GlobalT);
    MarkObject(Self, MetaStr);
    MarkObject(Self, MetaTab);
    MarkObject(Self, MetaNum);
    MarkObject(Self, MetaFunc);
    MarkObject(Self, MetaThread);
    MarkObject(Self, MetaUdata);
    // mark metatables of finalizable objects so __gc survives
    o := AllGC;
    while o <> nil do
    begin
      if not o.Marked then
      begin
        if o.ObjType = OBJ_TAB then
        begin
          if HasFinalizer(TTable(o)) then
            MarkObject(Self, TTable(o).Metatable);
        end
        else if o.ObjType = OBJ_USER then
        begin
          if UserdataHasFinalizer(TUserdata(o)) then
            MarkObject(Self, TUserdata(o).Metatable);
        end;
      end;
      o := o.NextGC;
    end;
    // 3. clear weak tables
    ClearWeakTables(Self);
    // 4. separate finalizable objects
    finz := nil;
    o := AllGC;
    while o <> nil do
    begin
      if not o.Marked then
      begin
        if ((o.ObjType = OBJ_TAB) and HasFinalizer(TTable(o))) or
           ((o.ObjType = OBJ_USER) and UserdataHasFinalizer(TUserdata(o))) then
        begin
          o.Finalizing := True;
          o.Marked := True;
          o.NextGC := finz;
          finz := o;
        end;
      end;
      o := o.NextGC;
    end;
    // 5. sweep
    o := AllGC;
    while o <> nil do
    begin
      next := o.NextGC;
      if not o.Marked and not o.Finalizing then
      begin
        UnregisterObject(o);
        o.Free;
      end;
      o := next;
    end;
    // 6. run finalizers
    o := finz;
    while o <> nil do
    begin
      next := o.NextGC;
      o.Marked := False;
      o := next;
    end;
    o := finz;
    while o <> nil do
    begin
      next := o.NextGC;
      if not o.Marked then
      begin
        o.Marked := True;
        if (o.ObjType = OBJ_TAB) then
        begin
          f := TTable(o);
          if f.Metatable <> nil then
          begin
            mm := TableGetStr(f.Metatable, StaticStr('__gc'));
            if (mm.Vt = vtFunc) and (FinalizerProc <> nil) then
              FinalizerProc(Self, mm.F, LuaTab(f));
          end;
        end
        else if (o.ObjType = OBJ_USER) then
        begin
          u := TUserdata(o);
          if u.Metatable <> nil then
          begin
            mm := TableGetStr(u.Metatable, StaticStr('__gc'));
            if (mm.Vt = vtFunc) and (FinalizerProc <> nil) then
              FinalizerProc(Self, mm.F, LuaUser(u));
          end;
        end;
      end;
      o := next;
    end;
    // 7. re-mark after finalization; free still-dead finalizables
    o := AllGC;
    while o <> nil do
    begin
      o.Marked := False;
      o := o.NextGC;
    end;
    MarkThread(Self, Self);
    MarkObject(Self, Registry);
    MarkObject(Self, GlobalT);
    MarkObject(Self, MetaStr);
    MarkObject(Self, MetaTab);
    MarkObject(Self, MetaNum);
    MarkObject(Self, MetaFunc);
    MarkObject(Self, MetaThread);
    MarkObject(Self, MetaUdata);
    o := finz;
    while o <> nil do
    begin
      next := o.NextGC;
      if not o.Marked then
      begin
        UnregisterObject(o);
        o.Free;
      end
      else
        o.Finalizing := False;
      o := next;
    end;
    LastGCBytes := TotalBytes;
    GCWork := 0;
  finally
    GCInCycle := False;
  end;
end;

function TLua.GCStep(size: Integer): Boolean;
var
  eff: Integer;
begin
  eff := size;
  if eff < 0 then
    eff := GCStepSize;
  if eff <= 0 then
  begin
    FullGC;
    Exit(True);
  end;
  Inc(GCWork, eff * GCStepMul);
  if GCWork >= 10000 then
  begin
    FullGC;
    Result := True;
  end
  else
    Result := False;
end;

procedure TLua.SetGCMode(m: string);
begin
  GCMode := m;
end;

procedure TLua.SetGCParam(const p: string; v: Integer);
begin
  if p = 'pause' then GCPause := v
  else if p = 'stepmul' then GCStepMul := v
  else if p = 'stepsize' then GCStepSize := v;
end;

function TLua.GetGCParam(const p: string): Integer;
begin
  if p = 'pause' then Result := GCPause
  else if p = 'stepmul' then Result := GCStepMul
  else if p = 'stepsize' then Result := GCStepSize
  else Result := 0;
end;

procedure TLua.CheckGC;
begin
  if not GCRunning then
    Exit;
  if TotalBytes > LastGCBytes + GCThreshold then
    FullGC;
end;

end.
