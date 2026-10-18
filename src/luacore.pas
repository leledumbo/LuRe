unit luacore;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$modeswitch advancedrecords}
{$POINTERMATH ON}

// Core data model of the interpreter: values, strings, tables, functions,
// threads (coroutines) and the garbage collector.

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
                vtUser, vtThread, vtLight, vtDead);

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
      vtDead: (D: Pointer);   // key of a collected entry (identity only)
  end;
  PLuaValue = ^TLuaValue;

  TGCObject = class
  public
    NextGC: TGCObject;
    ObjType: Byte;
    Marked: Boolean;
    Fixed: Boolean;      // never collected
    FinState: Byte;      // 0: no finalizer; 1: registered for finalization
  end;

  // ---------------- strings ----------------
  TStringObj = class(TGCObject)
  public
    Str: RawByteString;
    Len: SizeUInt;
    Hash: Cardinal;
    IsShort: Boolean;    // interned
    HashDone: Boolean;
    HNext: TStringObj;   // chain in the string table
    function ToStr: RawByteString; inline;
    function Eq(const s2: TStringObj): Boolean;
    function EqRaw(const s2: RawByteString): Boolean;
    function GetHash: Cardinal; inline;
    function GetData: PByte; inline;
    property Data: PByte read GetData;
  end;

  // ---------------- userdata ----------------
  TUserdata = class(TGCObject)
  public
    Data: Pointer;
    Len: SizeUInt;
    Obj: TObject;        // owned Pascal object (freed with the userdata)
    UsrValue: TLuaValue;
    NUserValues: Integer;   // number of user values (0 or 1)
    Metatable: TTable;
    destructor Destroy; override;
  end;

  // ---------------- tables ----------------
  TTableNode = record
    Key: TLuaValue;
    Val: TLuaValue;
    Next: Integer;       // next node in the collision chain, or -1
  end;

  TTable = class(TGCObject)
  public
    Arr: array of TLuaValue;       // array part: keys 1..Length(Arr)
    Node: array of TTableNode;     // hash part (size is 0 or a power of 2)
    LastFree: Integer;
    Metatable: TTable;
    function ASize: Integer; inline;
  end;

  // ---------------- upvalues ----------------
  TUpval = class(TGCObject)
  public
    V: TLuaValue;        // value when closed
    Th: TThread;         // owner while open
    Idx: Integer;        // stack index while open, -1 when closed
    NextOpen: TUpval;    // list of open upvalues of the thread
    function IsOpen: Boolean; inline;
    function Get: TLuaValue; inline;
    procedure SetVal(const x: TLuaValue); inline;
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
    LineInfo: array of Integer;
    LocVars: array of TLocVar;
    NumParams: Integer;
    IsVararg: Boolean;
    VarTabReg: Integer;     // register of the named vararg table, or -1
    MaxStackSize: Integer;
    Source: TStringObj;
    LineDefined: Integer;
    LastLineDefined: Integer;
  end;

  // ---------------- functions ----------------
  TCFunc = function(L: TLua): Integer;

  TFunction = class(TGCObject)
  public
    IsC: Boolean;
    Proto: TProto;
    Upvals: array of TUpval;        // Lua closures
    CProc: TCFunc;
    CVals: array of TLuaValue;      // C closures
    CName: string;                  // name of a library function (diagnostics)
  end;

  // ---------------- call info / thread ----------------
  TCallInfo = record
    Func: TFunction;
    FuncIdx: Integer;     // stack slot of the function; results go there
    Base: Integer;        // first register / first argument
    Top: Integer;         // frame limit
    SavedPC: Integer;     // index of the next instruction
    NResults: Integer;
    NExtra: Integer;      // number of hidden vararg values (below Base)
    IsC: Boolean;
    IsTail: Boolean;
    Hooked: Boolean;      // a hook function is running on behalf of this frame
    InFinalizer: Boolean; // a __gc finalizer is running on top of this frame
    FTransfer: Integer;   // values transferred by a call/return event (valid inside the hook)
    NTransfer: Integer;
    ExtraArgs: Integer;   // callable objects (__call) prepended to the arguments
  end;

  TThread = class(TGCObject)
  public
    Main: TLua;
    Stack: array of TLuaValue;
    Top: Integer;
    CI: array of TCallInfo;
    NCI: Integer;
    OpenUpvals: TUpval;     // open upvalues, ordered by decreasing Idx
    TbcList: array of Integer;
    NTbc: Integer;
    Status: Integer;
    NCcalls: Integer;       // nested native calls
    NNY: Integer;           // > 0: not yieldable
    Runner: TObject;        // coroutine machinery (owned by luavm)
    Parent: TThread;        // thread that resumed this one
    HookFunc: TLuaValue;
    GCLimit: Integer;       // when > 0, only the stack below it is live (set at some GC safe points)
    HookMask: Integer;
    HookCount: Integer;
    HookCounter: Integer;
    InHook: Boolean;
    OldLine: Integer;
    procedure EnsureStack(n: Integer);
    function PushValue(const v: TLuaValue): Integer;
    procedure SetTop(idx: Integer);
  end;

  // ---------------- global state / main thread ----------------
  TFinalizerProc = procedure(L: TLua; const obj: TLuaValue);
  TFreeThreadProc = procedure(th: TThread);
  TWarnProc = procedure(L: TLua; const msg: RawByteString; tocont: Boolean);

  TLua = class(TThread)
  private
    function GetRegistry: TTable;
    function GetGlobalT: TTable;
    function GetMeta(i: TValueType): TTable;
    procedure SetMeta(i: TValueType; t: TTable);
  public
    // --- state shared by all threads (valid on the main state only)
    FRegistry: TTable;
    FGlobalT: TTable;
    TypeMeta: array[TValueType] of TTable;
    AllGC: TGCObject;
    TotalBytes: Int64;
    GCStopped: Boolean;      // stopped by the user
    GCMode: string;
    GCPause: Integer;
    GCStepMul: Integer;
    GCStepSize: Integer;
    GCThreshold: Int64;
    GCStepDebt: Int64;
    InGC: Boolean;
    FinObjs: array of TGCObject;      // objects with finalizers, by registration
    NFinObjs: Integer;
    ToFinalize: array of TGCObject;   // dead objects awaiting their finalizer
    NToFinalize: Integer;
    FinalizerProc: TFinalizerProc;
    FreeThreadProc: TFreeThreadProc;
    WarnProc: TWarnProc;      // emits a warning (installed by the base library)
    CurThread: TThread;      // running thread
    UseEnv: Boolean;
    Closing: Boolean;
    ExitCode: Integer;
    WarnOn: Boolean;
    constructor CreateMain;
    constructor CreateThread(AMain: TLua);
    procedure RegisterObject(o: TGCObject; size: SizeUInt);
    function NewString(const s: RawByteString): TStringObj;
    function NewTable(nArr, nRec: Integer): TTable;
    function NewUserdata(len: SizeUInt): TUserdata;
    function NewProto: TProto;
    function NewLuaFunction(p: TProto): TFunction;
    function NewCFunction(f: TCFunc; nvals: Integer = 0): TFunction;
    function NewUpval: TUpval;
    function NewThread: TLua;
    procedure Account(delta: Int64);
    procedure CheckGC;
    procedure FullGC;
    function GCStep(size: Integer): Boolean;
    procedure SetGCMode(const m: string);
    procedure SetGCParam(const p: string; v: Integer);
    function GetGCParam(const p: string): Integer;
    procedure SetFinalizer(o: TGCObject);
    property Registry: TTable read GetRegistry;
    property GlobalT: TTable read GetGlobalT;
    property MetaStr: TTable index vtStr read GetMeta write SetMeta;
    property MetaNum: TTable index vtInt read GetMeta write SetMeta;
    property MetaFunc: TTable index vtFunc read GetMeta write SetMeta;
    property MetaThread: TTable index vtThread read GetMeta write SetMeta;
    property MetaBool: TTable index vtBool read GetMeta write SetMeta;
    property MetaNil: TTable index vtNil read GetMeta write SetMeta;
    property MetaLight: TTable index vtLight read GetMeta write SetMeta;
  end;

  ELuaError = class(Exception)
  public
    ErrValue: TLuaValue;
    HasValue: Boolean;
    constructor CreateMsg(const m: string);
    constructor CreateValue(const v: TLuaValue);
  end;

const
  LUA_MAXSHORTLEN = 40;
  MAXSTACK = 1000000;
  LUA_MININTEGER = Low(Int64);
  LUA_MAXINTEGER = High(Int64);

  OBJ_STR = 1; OBJ_TAB = 2; OBJ_PROTO = 3; OBJ_FUNC = 4;
  OBJ_UPVAL = 5; OBJ_USER = 6; OBJ_THREAD = 7;

  // thread status
  ST_OK = 0; ST_YIELD = 1; ST_DEAD = 2; ST_ERR = 3;

  // metamethod events
  TM_INDEX = 0; TM_NEWINDEX = 1; TM_GC = 2; TM_MODE = 3; TM_LEN = 4;
  TM_EQ = 5; TM_ADD = 6; TM_SUB = 7; TM_MUL = 8; TM_MOD = 9; TM_POW = 10;
  TM_DIV = 11; TM_IDIV = 12; TM_BAND = 13; TM_BOR = 14; TM_BXOR = 15;
  TM_SHL = 16; TM_SHR = 17; TM_UNM = 18; TM_BNOT = 19; TM_LT = 20;
  TM_LE = 21; TM_CONCAT = 22; TM_CALL = 23; TM_CLOSE = 24;
  TM_N = 25;

  MT_NAMES: array[0..TM_N - 1] of string = (
    '__index', '__newindex', '__gc', '__mode', '__len', '__eq',
    '__add', '__sub', '__mul', '__mod', '__pow', '__div', '__idiv',
    '__band', '__bor', '__bxor', '__shl', '__shr', '__unm', '__bnot',
    '__lt', '__le', '__concat', '__call', '__close');

  // float -> integer conversion modes
  F2I_EQ = 0; F2I_FLOOR = 1; F2I_CEIL = 2;

  // hook masks
  HOOK_CALL = 1; HOOK_RET = 2; HOOK_LINE = 4; HOOK_COUNT = 8;
  HOOK_INT = $100;   // pseudo hook: a pending interrupt (SIGINT) must be raised by the VM

  // opcodes. Operands marked RK are registers (>= 0) or constants (< 0,
  // constant index = -1 - value).
  OP_MOVE = 0;        // R[A] := R[B]
  OP_LOADK = 1;       // R[A] := K[B]
  OP_LOADNIL = 2;     // R[A .. A+B] := nil
  OP_LOADBOOL = 3;    // R[A] := (B <> 0)
  OP_GETUPVAL = 4;    // R[A] := Up[B]
  OP_SETUPVAL = 5;    // Up[B] := R[A]
  OP_GETTABUP = 6;    // R[A] := Up[B][RK(C)]
  OP_SETTABUP = 7;    // Up[A][RK(B)] := RK(C)
  OP_GETTABLE = 8;    // R[A] := R[B][RK(C)]
  OP_SETTABLE = 9;    // R[A][RK(B)] := RK(C)
  OP_NEWTABLE = 10;   // R[A] := {} (B array size, C hash size)
  OP_SELF = 11;       // R[A+1] := R[B]; R[A] := R[B][RK(C)]
  OP_ADD = 12;        // R[A] := RK(B) op RK(C)
  OP_SUB = 13;
  OP_MUL = 14;
  OP_MOD = 15;
  OP_POW = 16;
  OP_DIV = 17;
  OP_IDIV = 18;
  OP_BAND = 19;
  OP_BOR = 20;
  OP_BXOR = 21;
  OP_SHL = 22;
  OP_SHR = 23;
  OP_UNM = 24;        // R[A] := -R[B]
  OP_BNOT = 25;
  OP_NOT = 26;
  OP_LEN = 27;
  OP_CONCAT = 28;     // R[A] := R[B] .. ... .. R[B+C-1]
  OP_JMP = 29;        // pc := A
  OP_JT = 30;         // if R[A] then pc := B
  OP_JF = 31;         // if not R[A] then pc := B
  OP_EQ = 32;         // if (RK(B) == RK(C)) == (A <> 0) then pc := Code[pc].A else pc++
  OP_LT = 33;
  OP_LE = 34;
  OP_CALL = 35;       // R[A], ... := R[A](R[A+1], ..., R[A+B-1]); C-1 results
  OP_TAILCALL = 36;   // return R[A](R[A+1], ..., R[A+B-1])
  OP_RETURN = 37;     // return R[A], ..., R[A+B-2]
  OP_VARARG = 38;     // R[A], ... := ...  (C-1 values; B <> 0: B-1 is the vararg table register)
  OP_CLOSURE = 39;    // R[A] := closure(Protos[B])
  OP_SETLIST = 40;    // R[A][C+i] := R[A+i], 1 <= i <= B
  OP_CLOSE = 41;      // close upvalues and to-be-closed variables >= R[A]
  OP_TBC = 42;        // mark R[A] as to-be-closed
  OP_FORPREP = 43;    // prepare numeric loop; if it does not run, pc := B
  OP_FORLOOP = 44;    // update numeric loop; if it continues, pc := B
  OP_TFORPREP = 45;   // generic loop setup
  OP_TFORCALL = 46;   // R[A+3], ... := R[A](R[A+1], R[A+2]) (C results)
  OP_TFORLOOP = 47;   // if R[A+3] ~= nil then pc := B
  OP_ERRNNIL = 48;    // error if R[A] ~= nil (K[B] is the global name)
  OP_NOP = 49;
  OP_GETVARG = 50;    // R[A] := vararg[RK(C)] (virtual vararg table: integer index or 'n')
  NUM_OPCODES = 51;

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
function CFormatDouble(const fmt: string; n: Double): string;
function HexDigitVal(c: Char): Integer;
function ChunkIdStr(const source: string): string;
function StrToIntVal(const s: RawByteString; var i: Int64): Boolean;
function StrToNumVal(const s: RawByteString; var n: Double): Boolean;
function LocaleDecPoint: Char;   // decimal point of the current C locale
function ToInteger(const v: TLuaValue; var i: Int64): Boolean;
function ToNumberVal(const v: TLuaValue; var n: Double): Boolean;
function FloatToInt(n: Double; var i: Int64; mode: Integer): Boolean;
function HashString(const s: RawByteString): Cardinal;
function StaticStr(const s: string): TStringObj;
function TMName(tm: Integer): TStringObj;

// ---------------- tables ----------------
function TableGetStr(t: TTable; ks: TStringObj): TLuaValue;
function TableGetInt(t: TTable; ik: Int64): TLuaValue;
function TableGet(t: TTable; const key: TLuaValue): TLuaValue;
procedure TableSet(t: TTable; const key, val: TLuaValue);
procedure TableSetInt(t: TTable; key: Int64; const val: TLuaValue);
procedure TableSetStr(t: TTable; key: TStringObj; const val: TLuaValue);
function TableNext(t: TTable; const key: TLuaValue; var nk, nv: TLuaValue): Boolean;
function TableLength(t: TTable): Int64;
function TableCount(t: TTable): Integer;
procedure TableResize(t: TTable; nArr, nHash: Integer);
procedure TableClear(t: TTable);

implementation

var
  TheState: TLua = nil;
  StrTab: array of TStringObj;
  StrCount: Integer = 0;
  TMNames: array[0..TM_N - 1] of TStringObj;

{ ===================================================================== }
{ strings                                                                }
{ ===================================================================== }

function TStringObj.ToStr: RawByteString;
begin
  Result := Str;
end;

function TStringObj.GetData: PByte;
begin
  Result := PByte(Pointer(Str));
end;

function ComputeHash(const s: RawByteString): Cardinal;
var
  i: Integer;
  h: Cardinal;
begin
  h := Cardinal($5bd1e995) xor Cardinal(Length(s));
  for i := Length(s) downto 1 do
    h := h xor ((h shl 5) + (h shr 2) + Cardinal(Byte(s[i])));
  Result := h;
end;

function HashString(const s: RawByteString): Cardinal;
begin
  Result := ComputeHash(s);
end;

function TStringObj.GetHash: Cardinal;
begin
  if not HashDone then
  begin
    Hash := ComputeHash(Str);
    HashDone := True;
  end;
  Result := Hash;
end;

function TStringObj.Eq(const s2: TStringObj): Boolean;
begin
  if Self = s2 then Exit(True);
  if IsShort and s2.IsShort then Exit(False);
  if Len <> s2.Len then Exit(False);
  if Len = 0 then Exit(True);
  Result := CompareMem(Pointer(Str), Pointer(s2.Str), Len);
end;

function TStringObj.EqRaw(const s2: RawByteString): Boolean;
begin
  if Len <> SizeUInt(Length(s2)) then Exit(False);
  if Len = 0 then Exit(True);
  Result := CompareMem(Pointer(Str), Pointer(s2), Len);
end;

procedure StrTabResize(newSize: Integer);
var
  nt: array of TStringObj;
  i, idx: Integer;
  s, nxt: TStringObj;
begin
  SetLength(nt, newSize);
  for i := 0 to Length(StrTab) - 1 do
  begin
    s := StrTab[i];
    while s <> nil do
    begin
      nxt := s.HNext;
      idx := Integer(s.Hash and Cardinal(newSize - 1));
      s.HNext := nt[idx];
      nt[idx] := s;
      s := nxt;
    end;
  end;
  StrTab := nt;
end;

// finds or creates the interned short string; 'fresh' tells if it is new
function InternShort(const s: RawByteString; var fresh: Boolean): TStringObj;
var
  h: Cardinal;
  idx: Integer;
begin
  h := ComputeHash(s);
  idx := Integer(h and Cardinal(Length(StrTab) - 1));
  Result := StrTab[idx];
  while Result <> nil do
  begin
    if (Result.Hash = h) and Result.EqRaw(s) then
    begin
      fresh := False;
      Exit;
    end;
    Result := Result.HNext;
  end;
  if StrCount >= Length(StrTab) then
  begin
    StrTabResize(Length(StrTab) * 2);
    idx := Integer(h and Cardinal(Length(StrTab) - 1));
  end;
  Result := TStringObj.Create;
  Result.ObjType := OBJ_STR;
  Result.Str := s;
  Result.Len := Length(s);
  Result.Hash := h;
  Result.HashDone := True;
  Result.IsShort := True;
  Result.HNext := StrTab[idx];
  StrTab[idx] := Result;
  Inc(StrCount);
  fresh := True;
end;

function StaticStr(const s: string): TStringObj;
var
  fresh: Boolean;
begin
  if Length(StrTab) = 0 then
    SetLength(StrTab, 1024);
  if Length(s) <= LUA_MAXSHORTLEN then
  begin
    Result := InternShort(RawByteString(s), fresh);
    Result.Fixed := True;
  end
  else
  begin
    Result := TStringObj.Create;
    Result.ObjType := OBJ_STR;
    Result.Str := RawByteString(s);
    Result.Len := Length(s);
    Result.Fixed := True;
  end;
end;

function TMName(tm: Integer): TStringObj;
begin
  Result := TMNames[tm];
end;

{ ===================================================================== }
{ value helpers                                                          }
{ ===================================================================== }

function LuaNil: TLuaValue;
begin
  Result.Vt := vtNil;
end;

function LuaBool(b: Boolean): TLuaValue;
begin
  Result.Vt := vtBool;
  Result.B := b;
end;

function LuaInt(i: Int64): TLuaValue;
begin
  Result.Vt := vtInt;
  Result.I := i;
end;

function LuaNum(n: Double): TLuaValue;
begin
  Result.Vt := vtFlt;
  Result.N := n;
end;

function LuaStr(s: TStringObj): TLuaValue;
begin
  Result.Vt := vtStr;
  Result.S := s;
end;

function LuaTab(t: TTable): TLuaValue;
begin
  Result.Vt := vtTab;
  Result.T := t;
end;

function LuaFunc(f: TFunction): TLuaValue;
begin
  Result.Vt := vtFunc;
  Result.F := f;
end;

function LuaUser(u: TUserdata): TLuaValue;
begin
  Result.Vt := vtUser;
  Result.U := u;
end;

function LuaThread(th: TThread): TLuaValue;
begin
  Result.Vt := vtThread;
  Result.Th := th;
end;

function LuaLight(p: Pointer): TLuaValue;
begin
  Result.Vt := vtLight;
  Result.P := p;
end;

function IsNil(const v: TLuaValue): Boolean;
begin
  Result := v.Vt = vtNil;
end;

function IsFalse(const v: TLuaValue): Boolean;
begin
  Result := (v.Vt = vtNil) or ((v.Vt = vtBool) and not v.B);
end;

function Truthy(const v: TLuaValue): Boolean;
begin
  Result := not ((v.Vt = vtNil) or ((v.Vt = vtBool) and not v.B));
end;

function VTypeName(const v: TLuaValue): string;
begin
  case v.Vt of
    vtNil, vtDead: Result := 'nil';
    vtBool: Result := 'boolean';
    vtInt, vtFlt: Result := 'number';
    vtStr: Result := 'string';
    vtTab: Result := 'table';
    vtFunc: Result := 'function';
    vtUser, vtLight: Result := 'userdata';
    vtThread: Result := 'thread';
  else
    Result := '?';
  end;
end;

function FloatToInt(n: Double; var i: Int64; mode: Integer): Boolean;
var
  r: Double;
begin
  if IsNaN(n) then Exit(False);
  r := Int(n);                       // truncation toward zero, kept as a float
  if r <> n then
  begin
    case mode of
      F2I_EQ: Exit(False);
      F2I_FLOOR: if n < 0 then r := r - 1;
      F2I_CEIL: if n > 0 then r := r + 1;
    end;
  end;
  // representable range: [-2^63, 2^63)
  if (r < -9223372036854775808.0) or (r >= 9223372036854775808.0) then
    Exit(False);
  i := Trunc(r);
  Result := True;
end;

function RawEqual(const a, b: TLuaValue): Boolean;
var
  i: Int64;
begin
  if a.Vt <> b.Vt then
  begin
    if (a.Vt = vtInt) and (b.Vt = vtFlt) then
      Exit(FloatToInt(b.N, i, F2I_EQ) and (i = a.I));
    if (a.Vt = vtFlt) and (b.Vt = vtInt) then
      Exit(FloatToInt(a.N, i, F2I_EQ) and (i = b.I));
    Exit(False);
  end;
  case a.Vt of
    vtNil: Result := True;
    vtBool: Result := a.B = b.B;
    vtInt: Result := a.I = b.I;
    vtFlt: Result := a.N = b.N;
    vtStr: Result := (a.S = b.S) or ((not a.S.IsShort) and a.S.Eq(b.S));
    vtTab: Result := a.T = b.T;
    vtFunc: Result := a.F = b.F;
    vtUser: Result := a.U = b.U;
    vtThread: Result := a.Th = b.Th;
    vtLight: Result := a.P = b.P;
  else
    Result := a.D = b.D;
  end;
end;

{ ===================================================================== }
{ number <-> string conversions                                          }
{ ===================================================================== }

function c_snprintf(buf: PChar; size: SizeUInt; fmt: PChar): Integer; cdecl; varargs; external 'c' name 'snprintf';
function c_strtod(s: PChar; endp: PPChar): Double; cdecl; external 'c' name 'strtod';
function c_localeconv: PPChar; cdecl; external 'c' name 'localeconv';

// the decimal point of the current C locale (the first field of 'struct lconv')
function LocaleDecPoint: Char;
var
  dp: PChar;
begin
  dp := c_localeconv^;
  if (dp <> nil) and (dp^ <> #0) then Result := dp^ else Result := '.';
end;

// formats one double with a C printf format (e.g. '%.14g'), exactly like C does
function CFormatDouble(const fmt: string; n: Double): string;
var
  buf: array[0..511] of Char;
  len: Integer;
begin
  len := c_snprintf(@buf[0], SizeOf(buf), PChar(fmt), n);
  if len >= SizeOf(buf) then
    len := SizeOf(buf) - 1;
  SetString(Result, PChar(@buf[0]), len);
end;

function FltToStrVal(n: Double): string;
var
  s: string;
  i: Integer;
  check: Double;
begin
  if IsNaN(n) then
  begin
    if PInt64(@n)^ < 0 then Exit('-nan') else Exit('nan');
  end;
  if IsInfinite(n) then
  begin
    if n > 0 then Exit('inf') else Exit('-inf');
  end;
  s := CFormatDouble('%.15g', n);
  if not StrToNumVal(RawByteString(s), check) or (check <> n) then
    s := CFormatDouble('%.17g', n);
  // looks like an integer?
  i := 1;
  while (i <= Length(s)) and (s[i] in ['-', '0'..'9']) do Inc(i);
  if i > Length(s) then
    s := s + '.0';
  Result := s;
end;

function NumToStr(const v: TLuaValue): string;
begin
  if v.Vt = vtInt then
    Result := IntToStr(v.I)
  else
    Result := FltToStrVal(v.N);
end;

// display name of a chunk, as in error messages (LUA_IDSIZE = 60)
function ChunkIdStr(const source: string): string;
const
  MaxId = 59;
var
  nl, n: Integer;
begin
  if (source <> '') and (source[1] = '=') then
    Result := Copy(source, 2, MaxId)
  else if (source <> '') and (source[1] = '@') then
  begin
    if Length(source) - 1 <= MaxId then
      Result := Copy(source, 2, MaxId)
    else
      Result := '...' + Copy(source, Length(source) - (MaxId - 3) + 1, MaxId - 3);
  end
  else
  begin
    n := Length(source);
    nl := Pos(#10, source);
    if (n < 45) and (nl = 0) then
      Result := '[string "' + source + '"]'
    else
    begin
      if nl > 0 then n := nl - 1;
      if n > 45 then n := 45;
      Result := '[string "' + Copy(source, 1, n) + '..."]';
    end;
  end;
end;

function IsLuaSpace(c: Char): Boolean; inline;
begin
  Result := c in [' ', #9, #10, #11, #12, #13];
end;

function HexDigitVal(c: Char): Integer;
begin
  case c of
    '0'..'9': Result := Ord(c) - Ord('0');
    'a'..'f': Result := Ord(c) - Ord('a') + 10;
    'A'..'F': Result := Ord(c) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

// trims Lua whitespace; returns the [first, last] range of the remaining text
procedure TrimRange(const s: RawByteString; var first, last: Integer);
begin
  first := 1;
  last := Length(s);
  while (first <= last) and IsLuaSpace(s[first]) do Inc(first);
  while (last >= first) and IsLuaSpace(s[last]) do Dec(last);
end;

function StrToIntVal(const s: RawByteString; var i: Int64): Boolean;
var
  p, last, d: Integer;
  neg: Boolean;
  a: QWord;
begin
  TrimRange(s, p, last);
  if p > last then Exit(False);
  neg := False;
  if s[p] = '-' then begin neg := True; Inc(p); end
  else if s[p] = '+' then Inc(p);
  if p > last then Exit(False);
  a := 0;
  if (s[p] = '0') and (p < last) and (s[p + 1] in ['x', 'X']) then
  begin
    Inc(p, 2);
    if p > last then Exit(False);
    while p <= last do
    begin
      d := HexDigitVal(s[p]);
      if d < 0 then Exit(False);
      a := a * 16 + QWord(d);   // hexadecimal integers wrap around
      Inc(p);
    end;
  end
  else
  begin
    while p <= last do
    begin
      if not (s[p] in ['0'..'9']) then Exit(False);
      d := Ord(s[p]) - Ord('0');
      // decimal overflow: not an integer (caller falls back to float)
      if (a > QWord(High(Int64)) div 10) or
         ((a = QWord(High(Int64)) div 10) and (QWord(d) > QWord(High(Int64)) mod 10 + QWord(Ord(neg)))) then
        Exit(False);
      a := a * 10 + QWord(d);
      Inc(p);
    end;
  end;
  if neg then a := QWord(0) - a;
  i := Int64(a);
  Result := True;
end;

function HexStrToDouble(const s: RawByteString; p, last: Integer; var n: Double): Boolean;
var
  mant: Double;
  exp, e: Integer;
  anyDigit, neg: Boolean;
  sig: Integer;
begin
  // s[p..last] is the text after '0x'
  mant := 0;
  exp := 0;
  anyDigit := False;
  sig := 0;
  while (p <= last) and (HexDigitVal(s[p]) >= 0) do
  begin
    if (sig = 0) and (HexDigitVal(s[p]) = 0) then
      // leading zero: not significant
    else if sig < 30 then
    begin
      mant := mant * 16 + HexDigitVal(s[p]);
      Inc(sig);
    end
    else
      Inc(exp, 4);   // dropped digit in the integer part
    anyDigit := True;
    Inc(p);
  end;
  if (p <= last) and ((s[p] = '.') or (s[p] = LocaleDecPoint)) then
  begin
    Inc(p);
    while (p <= last) and (HexDigitVal(s[p]) >= 0) do
    begin
      if (sig = 0) and (HexDigitVal(s[p]) = 0) then
        Dec(exp, 4)
      else if sig < 30 then
      begin
        mant := mant * 16 + HexDigitVal(s[p]);
        Inc(sig);
        Dec(exp, 4);
      end;
      anyDigit := True;
      Inc(p);
    end;
  end;
  if not anyDigit then Exit(False);
  if (p <= last) and (s[p] in ['p', 'P']) then
  begin
    Inc(p);
    neg := False;
    if (p <= last) and (s[p] in ['+', '-']) then
    begin
      neg := s[p] = '-';
      Inc(p);
    end;
    if (p > last) or not (s[p] in ['0'..'9']) then Exit(False);
    e := 0;
    while (p <= last) and (s[p] in ['0'..'9']) do
    begin
      if e < 100000 then e := e * 10 + Ord(s[p]) - Ord('0');
      Inc(p);
    end;
    if neg then e := -e;
    Inc(exp, e);
  end;
  if p <= last then Exit(False);
  n := mant;
  if exp <> 0 then n := Math.Ldexp(mant, exp);
  Result := True;
end;

function StrToNumVal(const s: RawByteString; var n: Double): Boolean;
var
  p, last, q: Integer;
  neg, digits: Boolean;
  buf: string;
  v: Double;
  endp: PChar;
  dp: Char;
begin
  TrimRange(s, p, last);
  if p > last then Exit(False);
  neg := False;
  if s[p] = '-' then begin neg := True; Inc(p); end
  else if s[p] = '+' then Inc(p);
  if p > last then Exit(False);
  if (s[p] = '0') and (p < last) and (s[p + 1] in ['x', 'X']) then
  begin
    if not HexStrToDouble(s, p + 2, last, v) then Exit(False);
  end
  else
  begin
    // validate decimal syntax: digits [. digits] [e [+-] digits]
    dp := LocaleDecPoint;
    q := p;
    digits := False;
    while (q <= last) and (s[q] in ['0'..'9']) do begin Inc(q); digits := True; end;
    if (q <= last) and ((s[q] = '.') or (s[q] = dp)) then
    begin
      Inc(q);
      while (q <= last) and (s[q] in ['0'..'9']) do begin Inc(q); digits := True; end;
    end;
    if not digits then Exit(False);
    if (q <= last) and (s[q] in ['e', 'E']) then
    begin
      Inc(q);
      if (q <= last) and (s[q] in ['+', '-']) then Inc(q);
      if (q > last) or not (s[q] in ['0'..'9']) then Exit(False);
      while (q <= last) and (s[q] in ['0'..'9']) do Inc(q);
    end;
    if q <= last then Exit(False);
    buf := string(Copy(s, p, last - p + 1));
    for q := 1 to Length(buf) do
      if buf[q] in ['.', dp] then buf[q] := dp;   // strtod expects the locale's point
    if buf[1] = dp then buf := '0' + buf;
    q := Pos(dp, buf);
    if (q > 0) and ((q = Length(buf)) or not (buf[q + 1] in ['0'..'9'])) then
      Insert('0', buf, q + 1);
    v := c_strtod(PChar(buf), @endp);
    if (endp = nil) or (endp^ <> #0) then Exit(False);
  end;
  if neg then v := -v;
  n := v;
  Result := True;
end;

function ToInteger(const v: TLuaValue; var i: Int64): Boolean;
var
  n: Double;
begin
  case v.Vt of
    vtInt: begin i := v.I; Exit(True); end;
    vtFlt: Exit(FloatToInt(v.N, i, F2I_EQ));
    vtStr: begin
      if StrToIntVal(v.S.Str, i) then Exit(True);
      if StrToNumVal(v.S.Str, n) then Exit(FloatToInt(n, i, F2I_EQ));
    end;
  end;
  Result := False;
end;

function ToNumberVal(const v: TLuaValue; var n: Double): Boolean;
var
  i: Int64;
begin
  case v.Vt of
    vtInt: begin n := Double(v.I); Exit(True); end;
    vtFlt: begin n := v.N; Exit(True); end;
    vtStr: begin
      if StrToIntVal(v.S.Str, i) then begin n := Double(i); Exit(True); end;
      Exit(StrToNumVal(v.S.Str, n));
    end;
  end;
  Result := False;
end;

{ ===================================================================== }
{ userdata, upvalues, threads                                            }
{ ===================================================================== }

destructor TUserdata.Destroy;
begin
  if Obj <> nil then
    Obj.Free;
  if Data <> nil then
    FreeMem(Data);
  inherited Destroy;
end;

function TTable.ASize: Integer;
begin
  Result := Length(Arr);
end;

function TUpval.IsOpen: Boolean;
begin
  Result := Idx >= 0;
end;

function TUpval.Get: TLuaValue;
begin
  if Idx >= 0 then Result := Th.Stack[Idx] else Result := V;
end;

procedure TUpval.SetVal(const x: TLuaValue);
begin
  if Idx >= 0 then Th.Stack[Idx] := x else V := x;
end;

procedure TThread.EnsureStack(n: Integer);
var
  ns: Integer;
begin
  if n <= Length(Stack) then
    Exit;
  if n > MAXSTACK + 1000 then
    raise ELuaError.CreateMsg('stack overflow');
  ns := Length(Stack) * 2;
  while ns < n do
    ns := ns * 2;
  if ns > MAXSTACK + 1000 then
    ns := MAXSTACK + 1000;
  if Main <> nil then
    Main.Account(Int64(ns - Length(Stack)) * SizeOf(TLuaValue));
  SetLength(Stack, ns);
end;

function TThread.PushValue(const v: TLuaValue): Integer;
begin
  EnsureStack(Top + 1);
  Stack[Top] := v;
  Result := Top;
  Inc(Top);
end;

procedure TThread.SetTop(idx: Integer);
var
  i: Integer;
begin
  if idx > Top then
  begin
    EnsureStack(idx + 1);
    for i := Top to idx - 1 do
      Stack[i].Vt := vtNil;
  end;
  Top := idx;
end;

constructor ELuaError.CreateMsg(const m: string);
begin
  inherited Create(m);
  ErrValue.Vt := vtNil;
  HasValue := False;
end;

constructor ELuaError.CreateValue(const v: TLuaValue);
begin
  if v.Vt = vtStr then
    inherited Create(string(v.S.Str))
  else
    inherited Create('(error object is a ' + VTypeName(v) + ' value)');
  ErrValue := v;
  HasValue := True;
end;

{ ===================================================================== }
{ tables                                                                 }
{ ===================================================================== }

const
  MAXABITS = 30;

function HashInt(i: Int64): Cardinal; inline;
var
  h: QWord;
begin
  h := QWord(i) * QWord($9E3779B97F4A7C15);
  Result := Cardinal(h shr 32);
end;

function KeyHash(const key: TLuaValue): Cardinal;
var
  bits: Int64;
begin
  case key.Vt of
    vtStr: Result := key.S.GetHash;
    vtInt: Result := HashInt(key.I);
    vtFlt: begin
      bits := PInt64(@key.N)^;
      Result := HashInt(bits);
    end;
    vtBool: Result := Cardinal(Ord(key.B)) + 1;
    vtLight: Result := HashInt(Int64(PtrUInt(key.P)));
    vtDead: Result := HashInt(Int64(PtrUInt(key.D)));
  else
    // collectable objects: all share the same pointer slot in the variant
    Result := HashInt(Int64(PtrUInt(key.T)));
  end;
end;

function MainPos(t: TTable; const key: TLuaValue): Integer; inline;
begin
  Result := Integer(KeyHash(key) and Cardinal(Length(t.Node) - 1));
end;

function KeyEquals(const nk, key: TLuaValue): Boolean; inline;
begin
  if nk.Vt <> key.Vt then Exit(False);
  case key.Vt of
    vtInt: Result := nk.I = key.I;
    vtFlt: Result := nk.N = key.N;
    vtStr: Result := (nk.S = key.S) or ((not key.S.IsShort) and (not nk.S.IsShort) and nk.S.Eq(key.S));
    vtBool: Result := nk.B = key.B;
    vtLight: Result := nk.P = key.P;
  else
    Result := nk.T = key.T;
  end;
end;

// index of the node holding 'key', or -1
function FindNode(t: TTable; const key: TLuaValue): Integer;
var
  i: Integer;
begin
  if Length(t.Node) = 0 then Exit(-1);
  i := MainPos(t, key);
  while i >= 0 do
  begin
    if KeyEquals(t.Node[i].Key, key) then Exit(i);
    i := t.Node[i].Next;
  end;
  Result := -1;
end;

// like FindNode, but also finds entries whose key was cleared by the
// collector (the key of a traversal may have been removed meanwhile)
function FindNodeForNext(t: TTable; const key: TLuaValue): Integer;
var
  i: Integer;
  dk: TLuaValue;
begin
  Result := FindNode(t, key);
  if (Result >= 0) or (Length(t.Node) = 0) then Exit;
  if key.Vt in [vtStr, vtTab, vtFunc, vtUser, vtThread] then
  begin
    i := MainPos(t, key);
    while i >= 0 do
    begin
      dk := t.Node[i].Key;
      if (dk.Vt = vtDead) and (dk.D = Pointer(key.T)) then Exit(i);
      i := t.Node[i].Next;
    end;
  end;
end;

function TableGetStr(t: TTable; ks: TStringObj): TLuaValue;
var
  i: Integer;
begin
  if Length(t.Node) > 0 then
  begin
    i := Integer(ks.GetHash and Cardinal(Length(t.Node) - 1));
    while i >= 0 do
    begin
      with t.Node[i] do
        if (Key.Vt = vtStr) and ((Key.S = ks) or ((not ks.IsShort) and Key.S.Eq(ks))) then
          Exit(Val);
      i := t.Node[i].Next;
    end;
  end;
  Result.Vt := vtNil;
end;

function TableGetInt(t: TTable; ik: Int64): TLuaValue;
var
  i: Integer;
begin
  if QWord(ik - 1) < QWord(Length(t.Arr)) then
    Exit(t.Arr[ik - 1]);
  if Length(t.Node) > 0 then
  begin
    i := Integer(HashInt(ik) and Cardinal(Length(t.Node) - 1));
    while i >= 0 do
    begin
      with t.Node[i] do
        if (Key.Vt = vtInt) and (Key.I = ik) then
          Exit(Val);
      i := t.Node[i].Next;
    end;
  end;
  Result.Vt := vtNil;
end;

function TableGet(t: TTable; const key: TLuaValue): TLuaValue;
var
  i: Integer;
  k: Int64;
begin
  case key.Vt of
    vtNil: Result.Vt := vtNil;
    vtInt: Result := TableGetInt(t, key.I);
    vtStr: Result := TableGetStr(t, key.S);
    vtFlt: begin
      if FloatToInt(key.N, k, F2I_EQ) then
        Result := TableGetInt(t, k)
      else
      begin
        i := FindNode(t, key);
        if i < 0 then Result.Vt := vtNil else Result := t.Node[i].Val;
      end;
    end;
  else
    i := FindNode(t, key);
    if i < 0 then Result.Vt := vtNil else Result := t.Node[i].Val;
  end;
end;

procedure NodeInit(var n: TTableNode); inline;
begin
  n.Key.Vt := vtNil;
  n.Val.Vt := vtNil;
  n.Next := -1;
end;

function TableAccountSize(t: TTable): Int64; inline;
begin
  Result := Int64(Length(t.Arr)) * SizeOf(TLuaValue) + Int64(Length(t.Node)) * SizeOf(TTableNode);
end;

// counts the integer keys of the array part, per power-of-2 slice
function NumUseArray(t: TTable; var nums: array of Integer): Integer;
var
  lg, ttlg, i, lim, lc: Integer;
  ause: Integer;
begin
  ause := 0;
  i := 1;
  ttlg := 1;
  for lg := 0 to MAXABITS do
  begin
    lc := 0;
    lim := ttlg;
    if lim > Length(t.Arr) then
    begin
      lim := Length(t.Arr);
      if i > lim then Break;
    end;
    while i <= lim do
    begin
      if t.Arr[i - 1].Vt <> vtNil then Inc(lc);
      Inc(i);
    end;
    Inc(nums[lg], lc);
    Inc(ause, lc);
    ttlg := ttlg * 2;
  end;
  Result := ause;
end;

function CeilLog2(x: Cardinal): Integer;
begin
  Result := 0;
  while (Cardinal(1) shl Result) < x do Inc(Result);
end;

function CountInt(key: Int64; var nums: array of Integer): Integer;
begin
  if (key >= 1) and (key <= (Int64(1) shl MAXABITS)) then
  begin
    Inc(nums[CeilLog2(Cardinal(key))]);
    Result := 1;
  end
  else
    Result := 0;
end;

function ComputeSizes(var nums: array of Integer; var pna: Integer): Integer;
var
  i, a, na, optimal, twotoi: Integer;
begin
  a := 0;
  na := 0;
  optimal := 0;
  i := 0;
  twotoi := 1;
  while (twotoi > 0) and (pna > twotoi div 2) do
  begin
    Inc(a, nums[i]);
    if a > twotoi div 2 then
    begin
      optimal := twotoi;
      na := a;
    end;
    Inc(i);
    twotoi := twotoi * 2;
    if i > MAXABITS then Break;
  end;
  pna := na;
  Result := optimal;
end;

procedure InsertRaw(t: TTable; const key, val: TLuaValue); forward;

procedure TableResize(t: TTable; nArr, nHash: Integer);
var
  oldArr: array of TLuaValue;
  oldNode: array of TTableNode;
  i, lsize, sz: Integer;
  before: Int64;
begin
  before := TableAccountSize(t);
  oldArr := t.Arr;
  oldNode := t.Node;
  // new hash part
  t.Node := nil;
  if nHash > 0 then
  begin
    lsize := CeilLog2(Cardinal(nHash));
    sz := 1 shl lsize;
    SetLength(t.Node, sz);
    for i := 0 to sz - 1 do NodeInit(t.Node[i]);
  end;
  t.LastFree := Length(t.Node);
  // new array part
  t.Arr := nil;
  SetLength(t.Arr, nArr);
  for i := 0 to nArr - 1 do t.Arr[i].Vt := vtNil;
  // re-insert elements from the old array part
  for i := 0 to Length(oldArr) - 1 do
    if oldArr[i].Vt <> vtNil then
      InsertRaw(t, LuaInt(i + 1), oldArr[i]);
  // re-insert elements from the old hash part
  for i := Length(oldNode) - 1 downto 0 do
    if oldNode[i].Val.Vt <> vtNil then
      InsertRaw(t, oldNode[i].Key, oldNode[i].Val);
  if TheState <> nil then
    TheState.Account(TableAccountSize(t) - before);
end;

procedure TableRehash(t: TTable; const extraKey: TLuaValue);
var
  nums: array[0..MAXABITS + 1] of Integer;
  i, na, totaluse, asize: Integer;
begin
  for i := 0 to MAXABITS + 1 do nums[i] := 0;
  na := NumUseArray(t, nums);
  totaluse := na;
  for i := 0 to Length(t.Node) - 1 do
    if t.Node[i].Val.Vt <> vtNil then
    begin
      if t.Node[i].Key.Vt = vtInt then
        Inc(na, CountInt(t.Node[i].Key.I, nums));
      Inc(totaluse);
    end;
  if extraKey.Vt = vtInt then
    Inc(na, CountInt(extraKey.I, nums));
  Inc(totaluse);
  asize := ComputeSizes(nums, na);
  TableResize(t, asize, totaluse - na);
end;

function GetFreePos(t: TTable): Integer;
begin
  while t.LastFree > 0 do
  begin
    Dec(t.LastFree);
    if t.Node[t.LastFree].Key.Vt = vtNil then
      Exit(t.LastFree);
  end;
  Result := -1;
end;

// inserts a key known to be absent; may rehash
procedure NewKey(t: TTable; const key, val: TLuaValue);
var
  mp, f, othern: Integer;
begin
  if Length(t.Node) = 0 then
  begin
    TableRehash(t, key);
    InsertRaw(t, key, val);
    Exit;
  end;
  mp := MainPos(t, key);
  if t.Node[mp].Val.Vt <> vtNil then
  begin
    f := GetFreePos(t);
    if f < 0 then
    begin
      TableRehash(t, key);
      InsertRaw(t, key, val);
      Exit;
    end;
    othern := MainPos(t, t.Node[mp].Key);
    if othern <> mp then
    begin
      // colliding node is out of its main position: move it to the free slot
      while t.Node[othern].Next <> mp do
        othern := t.Node[othern].Next;
      t.Node[othern].Next := f;
      t.Node[f] := t.Node[mp];
      t.Node[mp].Next := -1;
      t.Node[mp].Val.Vt := vtNil;
    end
    else
    begin
      // colliding node is in its own main position: new key goes to the free slot
      t.Node[f].Next := t.Node[mp].Next;
      t.Node[mp].Next := f;
      mp := f;
    end;
  end;
  t.Node[mp].Key := key;
  t.Node[mp].Val := val;
end;

// sets a key of the table (key normalized and not nil/NaN)
procedure InsertRaw(t: TTable; const key, val: TLuaValue);
var
  i: Integer;
begin
  if key.Vt = vtInt then
  begin
    if QWord(key.I - 1) < QWord(Length(t.Arr)) then
    begin
      t.Arr[key.I - 1] := val;
      Exit;
    end;
  end;
  i := FindNode(t, key);
  if i >= 0 then
    t.Node[i].Val := val
  else if val.Vt <> vtNil then
    NewKey(t, key, val);
end;

procedure TableSet(t: TTable; const key, val: TLuaValue);
var
  k: Int64;
  nk: TLuaValue;
begin
  case key.Vt of
    vtNil: Exit;
    vtFlt: begin
      if FloatToInt(key.N, k, F2I_EQ) then
        nk := LuaInt(k)
      else if IsNaN(key.N) then
        Exit
      else
        nk := key;
    end;
  else
    nk := key;
  end;
  InsertRaw(t, nk, val);
end;

procedure TableSetInt(t: TTable; key: Int64; const val: TLuaValue);
begin
  if QWord(key - 1) < QWord(Length(t.Arr)) then
    t.Arr[key - 1] := val
  else
    InsertRaw(t, LuaInt(key), val);
end;

procedure TableSetStr(t: TTable; key: TStringObj; const val: TLuaValue);
begin
  InsertRaw(t, LuaStr(key), val);
end;

procedure TableClear(t: TTable);
begin
  TableResize(t, 0, 0);
end;

// iteration order: array part, then hash nodes by index
function TableNext(t: TTable; const key: TLuaValue; var nk, nv: TLuaValue): Boolean;
var
  i, n: Integer;
  k: Int64;
  fk: TLuaValue;
begin
  if key.Vt = vtNil then
    i := 0
  else
  begin
    fk := key;
    if (fk.Vt = vtFlt) and FloatToInt(fk.N, k, F2I_EQ) then
      fk := LuaInt(k);
    if (fk.Vt = vtInt) and (QWord(fk.I - 1) < QWord(Length(t.Arr))) then
      i := Integer(fk.I)
    else
    begin
      n := FindNodeForNext(t, fk);
      if n < 0 then
        raise ELuaError.CreateMsg('invalid key to ''next''');
      i := Length(t.Arr) + n + 1;
    end;
  end;
  while i < Length(t.Arr) do
  begin
    if t.Arr[i].Vt <> vtNil then
    begin
      nk := LuaInt(i + 1);
      nv := t.Arr[i];
      Exit(True);
    end;
    Inc(i);
  end;
  Dec(i, Length(t.Arr));
  while i < Length(t.Node) do
  begin
    if t.Node[i].Val.Vt <> vtNil then
    begin
      nk := t.Node[i].Key;
      nv := t.Node[i].Val;
      Exit(True);
    end;
    Inc(i);
  end;
  Result := False;
end;

// a border of the table
function TableLength(t: TTable): Int64;
var
  i, j, m: Int64;
begin
  j := Length(t.Arr);
  if (j > 0) and (t.Arr[j - 1].Vt = vtNil) then
  begin
    // there is a border in the array part: binary search
    i := 0;
    while j - i > 1 do
    begin
      m := (i + j) div 2;
      if t.Arr[m - 1].Vt = vtNil then j := m else i := m;
    end;
    Exit(i);
  end;
  if (Length(t.Node) = 0) or (TableGetInt(t, j + 1).Vt = vtNil) then
    Exit(j);
  // unbound search in the hash part
  i := j + 1;
  j := i * 2;
  while TableGetInt(t, j).Vt <> vtNil do
  begin
    i := j;
    if j > High(Int64) div 2 then
    begin
      // overflow: linear search
      i := 1;
      while TableGetInt(t, i).Vt <> vtNil do Inc(i);
      Exit(i - 1);
    end;
    j := j * 2;
  end;
  while j - i > 1 do
  begin
    m := i + (j - i) div 2;
    if TableGetInt(t, m).Vt = vtNil then j := m else i := m;
  end;
  Result := i;
end;

function TableCount(t: TTable): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to Length(t.Arr) - 1 do
    if t.Arr[i].Vt <> vtNil then Inc(Result);
  for i := 0 to Length(t.Node) - 1 do
    if t.Node[i].Val.Vt <> vtNil then Inc(Result);
end;

{ ===================================================================== }
{ TLua: state, allocation                                                }
{ ===================================================================== }

function TLua.GetRegistry: TTable;
begin
  Result := Main.FRegistry;
end;

function TLua.GetGlobalT: TTable;
begin
  Result := Main.FGlobalT;
end;

function TLua.GetMeta(i: TValueType): TTable;
begin
  Result := Main.TypeMeta[i];
end;

procedure TLua.SetMeta(i: TValueType; t: TTable);
begin
  Main.TypeMeta[i] := t;
  if i = vtInt then Main.TypeMeta[vtFlt] := t;
end;

constructor TLua.CreateMain;
var
  i: Integer;
begin
  inherited Create;
  ObjType := OBJ_THREAD;
  Fixed := True;
  Main := Self;
  TheState := Self;
  CurThread := Self;
  SetLength(Stack, 256);
  SetLength(CI, 32);
  GCMode := 'incremental';
  GCPause := 200;
  GCStepMul := 100;
  GCStepSize := 13;
  GCThreshold := 1024 * 1024;
  TotalBytes := Length(Stack) * SizeOf(TLuaValue);
  if Length(StrTab) = 0 then
    SetLength(StrTab, 1024);
  for i := 0 to TM_N - 1 do
    TMNames[i] := StaticStr(MT_NAMES[i]);
  FRegistry := NewTable(0, 0);
  FRegistry.Fixed := True;
  FGlobalT := NewTable(0, 0);
  FGlobalT.Fixed := True;
end;

constructor TLua.CreateThread(AMain: TLua);
begin
  inherited Create;
  ObjType := OBJ_THREAD;
  Main := AMain;
  SetLength(Stack, 64);
  SetLength(CI, 8);
  AMain.RegisterObject(Self, 400 + 64 * SizeOf(TLuaValue));
end;

procedure TLua.Account(delta: Int64);
begin
  Main.TotalBytes := Main.TotalBytes + delta;
end;

procedure TLua.RegisterObject(o: TGCObject; size: SizeUInt);
begin
  with Main do
  begin
    o.NextGC := AllGC;
    AllGC := o;
    TotalBytes := TotalBytes + Int64(size);
  end;
end;

function TLua.NewString(const s: RawByteString): TStringObj;
var
  fresh: Boolean;
begin
  if Length(s) <= LUA_MAXSHORTLEN then
  begin
    Result := InternShort(s, fresh);
    if fresh then Main.TotalBytes := Main.TotalBytes + 48 + Length(s);
  end
  else
  begin
    Result := TStringObj.Create;
    Result.ObjType := OBJ_STR;
    Result.Str := s;
    Result.Len := Length(s);
    RegisterObject(Result, 48 + SizeUInt(Length(s)));
  end;
end;

function TLua.NewTable(nArr, nRec: Integer): TTable;
begin
  Result := TTable.Create;
  Result.ObjType := OBJ_TAB;
  RegisterObject(Result, 80);
  if (nArr > 0) or (nRec > 0) then
    TableResize(Result, nArr, nRec);
end;

function TLua.NewUserdata(len: SizeUInt): TUserdata;
begin
  Result := TUserdata.Create;
  Result.ObjType := OBJ_USER;
  Result.UsrValue.Vt := vtNil;
  if len > 0 then
  begin
    GetMem(Result.Data, len);
    FillChar(Result.Data^, len, 0);
  end;
  Result.Len := len;
  RegisterObject(Result, 64 + len);
end;

function TLua.NewProto: TProto;
begin
  Result := TProto.Create;
  Result.ObjType := OBJ_PROTO;
  Result.MaxStackSize := 2;
  Result.VarTabReg := -1;
  RegisterObject(Result, 160);
end;

function TLua.NewLuaFunction(p: TProto): TFunction;
begin
  Result := TFunction.Create;
  Result.ObjType := OBJ_FUNC;
  Result.Proto := p;
  SetLength(Result.Upvals, Length(p.UpvalDescs));
  RegisterObject(Result, 64 + SizeUInt(Length(p.UpvalDescs)) * 8);
end;

function TLua.NewCFunction(f: TCFunc; nvals: Integer): TFunction;
var
  i: Integer;
begin
  Result := TFunction.Create;
  Result.ObjType := OBJ_FUNC;
  Result.IsC := True;
  Result.CProc := f;
  SetLength(Result.CVals, nvals);
  for i := 0 to nvals - 1 do Result.CVals[i].Vt := vtNil;
  RegisterObject(Result, 64 + SizeUInt(nvals) * SizeOf(TLuaValue));
end;

function TLua.NewUpval: TUpval;
begin
  Result := TUpval.Create;
  Result.ObjType := OBJ_UPVAL;
  Result.Idx := -1;
  Result.V.Vt := vtNil;
  RegisterObject(Result, 48);
end;

function TLua.NewThread: TLua;
begin
  Result := TLua.CreateThread(Main);
end;

procedure TLua.SetFinalizer(o: TGCObject);
begin
  with Main do
  begin
    if (o.FinState <> 0) or Closing then Exit;
    o.FinState := 1;
    if NFinObjs >= Length(FinObjs) then
      SetLength(FinObjs, Length(FinObjs) * 2 + 16);
    FinObjs[NFinObjs] := o;
    Inc(NFinObjs);
  end;
end;

{ ===================================================================== }
{ garbage collector                                                      }
{ ===================================================================== }

type
  TGCWork = record
    Gray: array of TGCObject;
    NGray: Integer;
    Eph: array of TTable;
    NEph: Integer;
    WeakVals: array of TTable;
    NWV: Integer;
    AllWeak: array of TTable;
    NAW: Integer;
  end;

var
  GW: TGCWork;

procedure GrayPush(o: TGCObject); inline;
begin
  if GW.NGray >= Length(GW.Gray) then
    SetLength(GW.Gray, Length(GW.Gray) * 2 + 256);
  GW.Gray[GW.NGray] := o;
  Inc(GW.NGray);
end;

procedure MarkObj(o: TGCObject); inline;
begin
  if (o <> nil) and not o.Marked then
  begin
    o.Marked := True;
    if o.ObjType <> OBJ_STR then
      GrayPush(o);
  end;
end;

procedure MarkVal(const v: TLuaValue); inline;
begin
  case v.Vt of
    vtStr, vtTab, vtFunc, vtUser, vtThread: MarkObj(TGCObject(v.T));
  end;
end;

// has the collectable value been collected? (strings are values: they are
// marked and never cleared)
function IsCleared(const v: TLuaValue): Boolean;
var
  o: TGCObject;
begin
  case v.Vt of
    vtStr: begin
      v.S.Marked := True;
      Result := False;
    end;
    vtTab, vtFunc, vtUser, vtThread: begin
      o := TGCObject(v.T);
      Result := not (o.Marked or o.Fixed);
    end;
  else
    Result := False;
  end;
end;

function WeakMode(t: TTable; var wk, wv: Boolean): Boolean;
var
  mm: TLuaValue;
  s: RawByteString;
begin
  wk := False;
  wv := False;
  Result := False;
  if t.Metatable = nil then Exit;
  mm := TableGetStr(t.Metatable, TMNames[TM_MODE]);
  if mm.Vt <> vtStr then Exit;
  s := mm.S.Str;
  wk := Pos('k', s) > 0;
  wv := Pos('v', s) > 0;
  Result := wk or wv;
end;

procedure KillDeadKey(var n: TTableNode); inline;
begin
  if n.Key.Vt in [vtStr, vtTab, vtFunc, vtUser, vtThread] then
    n.Key.Vt := vtDead;
end;

procedure TraverseTable(t: TTable);
var
  wk, wv: Boolean;
  i: Integer;
begin
  MarkObj(t.Metatable);
  if not WeakMode(t, wk, wv) then
  begin
    for i := 0 to Length(t.Arr) - 1 do
      MarkVal(t.Arr[i]);
    for i := 0 to Length(t.Node) - 1 do
      with t.Node[i] do
        if Val.Vt = vtNil then
          KillDeadKey(t.Node[i])
        else
        begin
          MarkVal(Key);
          MarkVal(Val);
        end;
    Exit;
  end;
  if wk and wv then
  begin
    // all weak: nothing is marked through this table
    if GW.NAW >= Length(GW.AllWeak) then SetLength(GW.AllWeak, GW.NAW * 2 + 16);
    GW.AllWeak[GW.NAW] := t;
    Inc(GW.NAW);
    for i := 0 to Length(t.Arr) - 1 do
      if t.Arr[i].Vt = vtStr then t.Arr[i].S.Marked := True;
    for i := 0 to Length(t.Node) - 1 do
      with t.Node[i] do
        if Val.Vt <> vtNil then
        begin
          if Key.Vt = vtStr then Key.S.Marked := True;
          if Val.Vt = vtStr then Val.S.Marked := True;
        end;
  end
  else if wv then
  begin
    // weak values: mark keys only
    if GW.NWV >= Length(GW.WeakVals) then SetLength(GW.WeakVals, GW.NWV * 2 + 16);
    GW.WeakVals[GW.NWV] := t;
    Inc(GW.NWV);
    for i := 0 to Length(t.Arr) - 1 do
      if t.Arr[i].Vt = vtStr then t.Arr[i].S.Marked := True;
    for i := 0 to Length(t.Node) - 1 do
      with t.Node[i] do
        if Val.Vt = vtNil then
          KillDeadKey(t.Node[i])
        else
        begin
          MarkVal(Key);
          if Val.Vt = vtStr then Val.S.Marked := True;
        end;
  end
  else
  begin
    // weak keys (ephemeron): a value is marked only if its key is
    for i := 0 to Length(t.Arr) - 1 do
      MarkVal(t.Arr[i]);
    for i := 0 to Length(t.Node) - 1 do
      with t.Node[i] do
        if Val.Vt = vtNil then
          KillDeadKey(t.Node[i])
        else if not IsCleared(Key) then
          MarkVal(Val);
    if GW.NEph >= Length(GW.Eph) then SetLength(GW.Eph, GW.NEph * 2 + 16);
    GW.Eph[GW.NEph] := t;
    Inc(GW.NEph);
  end;
end;

procedure TraverseThread(th: TThread);
var
  i, lim: Integer;
  u: TUpval;
begin
  lim := th.Top;
  for i := 0 to th.NCI - 1 do
  begin
    if th.CI[i].Top > lim then lim := th.CI[i].Top;
    MarkObj(th.CI[i].Func);
  end;
  if th.GCLimit > 0 then lim := th.GCLimit
  else if (th.NCI > 0) and th.CI[th.NCI - 1].IsC and (th.Top >= th.CI[th.NCI - 1].Base) then
    lim := th.Top;   // inside a C function only its arguments and pushed values are live
  if lim > Length(th.Stack) then lim := Length(th.Stack);
  for i := 0 to lim - 1 do
    MarkVal(th.Stack[i]);
  // the part of the stack above the frame is dead: clear it
  for i := lim to Length(th.Stack) - 1 do
    th.Stack[i].Vt := vtNil;
  // open upvalues keep their value in the stack, but the objects must live
  u := th.OpenUpvals;
  while u <> nil do
  begin
    u.Marked := True;
    u := u.NextOpen;
  end;
  MarkVal(th.HookFunc);
  MarkObj(th.Parent);
end;

procedure PropagateOne(o: TGCObject);
var
  i: Integer;
  p: TProto;
  f: TFunction;
  u: TUserdata;
  uv: TUpval;
begin
  case o.ObjType of
    OBJ_TAB: TraverseTable(TTable(o));
    OBJ_FUNC: begin
      f := TFunction(o);
      if f.IsC then
      begin
        for i := 0 to Length(f.CVals) - 1 do MarkVal(f.CVals[i]);
      end
      else
      begin
        MarkObj(f.Proto);
        for i := 0 to Length(f.Upvals) - 1 do MarkObj(f.Upvals[i]);
      end;
    end;
    OBJ_PROTO: begin
      p := TProto(o);
      MarkObj(p.Source);
      for i := 0 to Length(p.K) - 1 do MarkVal(p.K[i]);
      for i := 0 to Length(p.Protos) - 1 do MarkObj(p.Protos[i]);
      for i := 0 to Length(p.UpvalDescs) - 1 do MarkObj(p.UpvalDescs[i].Name);
      for i := 0 to Length(p.LocVars) - 1 do MarkObj(p.LocVars[i].Name);
    end;
    OBJ_UPVAL: begin
      uv := TUpval(o);
      if uv.Idx < 0 then
        MarkVal(uv.V)
      else
        MarkObj(uv.Th);   // value lives in the owner's stack
    end;
    OBJ_USER: begin
      u := TUserdata(o);
      MarkObj(u.Metatable);
      MarkVal(u.UsrValue);
    end;
    OBJ_THREAD: TraverseThread(TThread(o));
  end;
end;

procedure PropagateAll;
begin
  while GW.NGray > 0 do
  begin
    Dec(GW.NGray);
    PropagateOne(GW.Gray[GW.NGray]);
  end;
end;

// marks values of ephemeron tables whose keys are marked, until no change
procedure ConvergeEphemerons;
var
  changed: Boolean;
  k, i: Integer;
  t: TTable;
begin
  repeat
    changed := False;
    for k := 0 to GW.NEph - 1 do
    begin
      t := GW.Eph[k];
      for i := 0 to Length(t.Node) - 1 do
        with t.Node[i] do
          if (Val.Vt <> vtNil) and (not IsCleared(Key)) then
            case Val.Vt of
              vtTab, vtFunc, vtUser, vtThread:
                if not TGCObject(Val.T).Marked then
                begin
                  MarkVal(Val);
                  changed := True;
                end;
            end;
    end;
    PropagateAll;
  until not changed;
end;

procedure ClearByValues(const lst: array of TTable; n, first: Integer);
var
  k, i: Integer;
  t: TTable;
begin
  for k := first to n - 1 do
  begin
    t := lst[k];
    for i := 0 to Length(t.Arr) - 1 do
      if IsCleared(t.Arr[i]) then t.Arr[i].Vt := vtNil;
    for i := 0 to Length(t.Node) - 1 do
      with t.Node[i] do
        if Val.Vt <> vtNil then
        begin
          if IsCleared(Val) then Val.Vt := vtNil;
          if Val.Vt = vtNil then KillDeadKey(t.Node[i]);
        end;
  end;
end;

procedure ClearByKeys(const lst: array of TTable; n: Integer);
var
  k, i: Integer;
  t: TTable;
begin
  for k := 0 to n - 1 do
  begin
    t := lst[k];
    for i := 0 to Length(t.Node) - 1 do
      with t.Node[i] do
        if Val.Vt <> vtNil then
        begin
          if IsCleared(Key) then Val.Vt := vtNil;
          if Val.Vt = vtNil then KillDeadKey(t.Node[i]);
        end;
  end;
end;

procedure UnlinkOpenUpval(uv: TUpval);
var
  p, prev: TUpval;
begin
  if uv.Th = nil then Exit;
  prev := nil;
  p := uv.Th.OpenUpvals;
  while p <> nil do
  begin
    if p = uv then
    begin
      if prev = nil then uv.Th.OpenUpvals := p.NextOpen else prev.NextOpen := p.NextOpen;
      Break;
    end;
    prev := p;
    p := p.NextOpen;
  end;
  uv.Th := nil;
  uv.Idx := -1;
end;

procedure CloseThreadUpvals(th: TThread);
var
  u, nxt: TUpval;
begin
  u := th.OpenUpvals;
  while u <> nil do
  begin
    nxt := u.NextOpen;
    u.V := th.Stack[u.Idx];
    u.Idx := -1;
    u.Th := nil;
    u.NextOpen := nil;
    u := nxt;
  end;
  th.OpenUpvals := nil;
end;

// releases one dead object (it has been unlinked from the object list)
procedure FreeObject(L: TLua; o: TGCObject);
var
  th: TThread;
  sz: Int64;
begin
  case o.ObjType of
    OBJ_STR: sz := 48 + Int64(TStringObj(o).Len);
    OBJ_TAB: sz := 80 + TableAccountSize(TTable(o));
    OBJ_USER: sz := 64 + Int64(TUserdata(o).Len);
    OBJ_UPVAL: begin
      if TUpval(o).Idx >= 0 then UnlinkOpenUpval(TUpval(o));
      sz := 48;
    end;
    OBJ_THREAD: begin
      th := TThread(o);
      if L.FreeThreadProc <> nil then L.FreeThreadProc(th);
      CloseThreadUpvals(th);
      sz := 400 + Int64(Length(th.Stack)) * SizeOf(TLuaValue);
    end;
    OBJ_PROTO: sz := 160;
    OBJ_FUNC: sz := 64 + Int64(Length(TFunction(o).Upvals)) * 8
                   + Int64(Length(TFunction(o).CVals)) * SizeOf(TLuaValue);
  else
    sz := 0;
  end;
  L.TotalBytes := L.TotalBytes - sz;
  o.Free;
end;

procedure SweepAll(L: TLua);
var
  o, nxt, prev: TGCObject;
  i: Integer;
  s, sn, sp: TStringObj;
begin
  prev := nil;
  o := L.AllGC;
  while o <> nil do
  begin
    nxt := o.NextGC;
    if o.Marked or o.Fixed then
    begin
      o.Marked := False;
      prev := o;
    end
    else
    begin
      if prev = nil then L.AllGC := nxt else prev.NextGC := nxt;
      FreeObject(L, o);
    end;
    o := nxt;
  end;
  // interned strings
  for i := 0 to Length(StrTab) - 1 do
  begin
    sp := nil;
    s := StrTab[i];
    while s <> nil do
    begin
      sn := s.HNext;
      if s.Marked or s.Fixed then
      begin
        s.Marked := False;
        sp := s;
      end
      else
      begin
        if sp = nil then StrTab[i] := sn else sp.HNext := sn;
        Dec(StrCount);
        L.TotalBytes := L.TotalBytes - (48 + Int64(s.Len));
        s.Free;
      end;
      s := sn;
    end;
  end;
  L.Marked := False;
end;

procedure TLua.FullGC;
var
  i, origWV, origAW, firstNew: Integer;
  o: TGCObject;
  live: array of TGCObject;
  nLive: Integer;
begin
  if Main <> Self then
  begin
    Main.FullGC;
    Exit;
  end;
  if InGC then Exit;
  InGC := True;
  try
    GW.NGray := 0;
    GW.NEph := 0;
    GW.NWV := 0;
    GW.NAW := 0;
    // roots
    MarkObj(Self);
    MarkObj(CurThread);
    MarkObj(FRegistry);
    MarkObj(FGlobalT);
    for i := Ord(Low(TValueType)) to Ord(High(TValueType)) do
      MarkObj(TypeMeta[TValueType(i)]);
    for i := 0 to NToFinalize - 1 do
      MarkObj(ToFinalize[i]);
    PropagateAll;
    ConvergeEphemerons;
    // values of weak tables that died before resurrection are cleared now
    ClearByValues(GW.WeakVals, GW.NWV, 0);
    ClearByValues(GW.AllWeak, GW.NAW, 0);
    origWV := GW.NWV;
    origAW := GW.NAW;
    // separate unreachable objects that have finalizers
    firstNew := NToFinalize;
    nLive := 0;
    SetLength(live, NFinObjs);
    for i := 0 to NFinObjs - 1 do
    begin
      o := FinObjs[i];
      if o.Marked or o.Fixed then
      begin
        live[nLive] := o;
        Inc(nLive);
      end
    end;
    // dead ones: most recently registered first
    for i := NFinObjs - 1 downto 0 do
    begin
      o := FinObjs[i];
      if not (o.Marked or o.Fixed) then
      begin
        if NToFinalize >= Length(ToFinalize) then
          SetLength(ToFinalize, Length(ToFinalize) * 2 + 16);
        ToFinalize[NToFinalize] := o;
        Inc(NToFinalize);
        o.FinState := 0;
      end;
    end;
    for i := 0 to nLive - 1 do FinObjs[i] := live[i];
    NFinObjs := nLive;
    // resurrect them
    for i := firstNew to NToFinalize - 1 do
      MarkObj(ToFinalize[i]);
    PropagateAll;
    ConvergeEphemerons;
    ClearByKeys(GW.Eph, GW.NEph);
    ClearByKeys(GW.AllWeak, GW.NAW);
    ClearByValues(GW.WeakVals, GW.NWV, origWV);
    ClearByValues(GW.AllWeak, GW.NAW, origAW);
    SweepAll(Self);
    // next collection when memory grows by the pause factor
    GCThreshold := (TotalBytes div 100) * GCPause;
    if GCThreshold < TotalBytes + 256 * 1024 then
      GCThreshold := TotalBytes + 256 * 1024;
  finally
    InGC := False;
  end;
  // call the finalizers (the collector is paused meanwhile)
  if (NToFinalize > 0) and (FinalizerProc <> nil) then
  begin
    InGC := True;
    try
      while NToFinalize > 0 do
      begin
        o := ToFinalize[0];
        Move(ToFinalize[1], ToFinalize[0], (NToFinalize - 1) * SizeOf(TGCObject));
        Dec(NToFinalize);
        case o.ObjType of
          OBJ_TAB: FinalizerProc(TLua(CurThread), LuaTab(TTable(o)));
          OBJ_USER: FinalizerProc(TLua(CurThread), LuaUser(TUserdata(o)));
        end;
      end;
    finally
      InGC := False;
    end;
  end;
end;

// Simulates an incremental collector: each step pays some 'work'; a cycle
// (a full collection here) completes after enough work for the heap size.
function TLua.GCStep(size: Integer): Boolean;
var
  need: Int64;
begin
  with Main do
  begin
    if size <= 0 then size := 2;
    Inc(GCStepDebt, Int64(size) * 4096);
    need := TotalBytes;
    if need < 65536 then need := 65536;
    if GCStepDebt >= need then
    begin
      GCStepDebt := 0;
      FullGC;
      Result := True;
    end
    else
      Result := False;
  end;
end;

procedure TLua.CheckGC;
begin
  with Main do
    if (TotalBytes >= GCThreshold) and not GCStopped and not InGC then
      FullGC;
end;

procedure TLua.SetGCMode(const m: string);
begin
  Main.GCMode := m;
end;

procedure TLua.SetGCParam(const p: string; v: Integer);
begin
  with Main do
    if p = 'pause' then GCPause := v
    else if p = 'stepmul' then GCStepMul := v
    else if p = 'stepsize' then GCStepSize := v;
end;

function TLua.GetGCParam(const p: string): Integer;
begin
  with Main do
    if p = 'pause' then Result := GCPause
    else if p = 'stepmul' then Result := GCStepMul
    else if p = 'stepsize' then Result := GCStepSize
    else Result := 0;
end;

end.
