unit luabinary;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// Binary chunks: string.dump and loading of precompiled functions.
// The header follows the layout of the reference implementation (so that
// tools can recognize it); the body format is private to this interpreter.

interface

uses
  SysUtils, Generics.Collections, luacore;

function DumpFunction(L: TLua; f: TFunction; strip: Boolean): RawByteString;
function UndumpFunction(L: TLua; const data: RawByteString; const chunkName: string): TFunction;

implementation

const
  Signature = #27'Lua';
  LuacVersion = $55;
  LuacFormat = 0;
  LuacData = #$19#$93#13#10#$1a#10;
  LuacInt = -$5678;
  LuacInst = $12345678;
  LuacNum = -370.5;

type
  TStrMap = specialize TDictionary<RawByteString, Integer>;

{ ===================================================================== }

type
  TDumper = class
  public
    Buf: RawByteString;
    Len: Integer;
    Strs: TStrMap;
    Strip: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Block(const p; n: Integer);
    procedure WByte(b: Byte);
    procedure WInt(v: Integer);
    procedure WInt64(v: Int64);
    procedure WDouble(v: Double);
    procedure WString(s: TStringObj);
    procedure WProto(p: TProto);
    procedure Header;
  end;

constructor TDumper.Create;
begin
  SetLength(Buf, 1024);
  Strs := TStrMap.Create;
end;

destructor TDumper.Destroy;
begin
  Strs.Free;
  inherited Destroy;
end;

procedure TDumper.Block(const p; n: Integer);
begin
  if Len + n > Length(Buf) then
    SetLength(Buf, (Len + n) * 2);
  if n > 0 then Move(p, Buf[Len + 1], n);
  Inc(Len, n);
end;

procedure TDumper.WByte(b: Byte);
begin
  Block(b, 1);
end;

procedure TDumper.WInt(v: Integer);
begin
  Block(v, 4);
end;

procedure TDumper.WInt64(v: Int64);
begin
  Block(v, 8);
end;

procedure TDumper.WDouble(v: Double);
begin
  Block(v, 8);
end;

// 0: nil string; 1: new string (length, bytes); k+2: reference to string k
procedure TDumper.WString(s: TStringObj);
var
  idx: Integer;
begin
  if s = nil then
  begin
    WInt(0);
    Exit;
  end;
  if Strs.TryGetValue(s.Str, idx) then
  begin
    WInt(idx + 2);
    Exit;
  end;
  Strs.Add(s.Str, Strs.Count);
  WInt(1);
  WInt(s.Len);
  Block(s.Bytes^, s.Len);
end;

procedure TDumper.Header;
var
  i32: Integer;
  i64: Int64;
  d: Double;
begin
  Block(Signature[1], 4);
  WByte(LuacVersion);
  WByte(LuacFormat);
  Block(LuacData[1], 6);
  WByte(4);
  i32 := LuacInt;
  WInt(i32);
  WByte(4);
  WInt(LuacInst);
  WByte(8);
  i64 := LuacInt;
  WInt64(i64);
  WByte(8);
  d := LuacNum;
  WDouble(d);
end;

procedure TDumper.WProto(p: TProto);
var
  i: Integer;
begin
  if Strip then WString(nil) else WString(p.Source);
  WInt(p.LineDefined);
  WInt(p.LastLineDefined);
  WInt(p.NumParams);
  WByte(Ord(p.IsVararg));
  WInt(p.VarTabReg);
  WInt(p.MaxStackSize);
  WInt(Length(p.Code));
  for i := 0 to High(p.Code) do
  begin
    WByte(p.Code[i].Op);
    WInt(p.Code[i].A);
    WInt(p.Code[i].B);
    WInt(p.Code[i].C);
  end;
  WInt(Length(p.K));
  for i := 0 to High(p.K) do
  begin
    WByte(Ord(p.K[i].Vt));
    case p.K[i].Vt of
      vtBool: WByte(Ord(p.K[i].B));
      vtInt: WInt64(p.K[i].I);
      vtFlt: WDouble(p.K[i].N);
      vtStr: WString(p.K[i].S);
    end;
  end;
  WInt(Length(p.UpvalDescs));
  for i := 0 to High(p.UpvalDescs) do
  begin
    WByte(Ord(p.UpvalDescs[i].InStack));
    WInt(p.UpvalDescs[i].Idx);
    WByte(Ord(p.UpvalDescs[i].IsConst));
  end;
  WInt(Length(p.Protos));
  for i := 0 to High(p.Protos) do
    WProto(p.Protos[i]);
  // debug information
  if Strip then
  begin
    WInt(0);
    WInt(0);
    WInt(0);
  end
  else
  begin
    WInt(Length(p.LineInfo));
    for i := 0 to High(p.LineInfo) do WInt(p.LineInfo[i]);
    WInt(Length(p.LocVars));
    for i := 0 to High(p.LocVars) do
    begin
      WString(p.LocVars[i].Name);
      WInt(p.LocVars[i].StartPC);
      WInt(p.LocVars[i].EndPC);
      WInt(p.LocVars[i].Reg);
    end;
    WInt(Length(p.UpvalDescs));
    for i := 0 to High(p.UpvalDescs) do
      WString(p.UpvalDescs[i].Name);
  end;
end;

function DumpFunction(L: TLua; f: TFunction; strip: Boolean): RawByteString;
var
  d: TDumper;
begin
  d := TDumper.Create;
  try
    d.Strip := strip;
    d.Header;
    d.WByte(Length(f.Proto.UpvalDescs));
    d.WProto(f.Proto);
    SetLength(d.Buf, d.Len);
    Result := d.Buf;
  finally
    d.Free;
  end;
end;

{ ===================================================================== }

type
  TUndumper = class
  public
    L: TLua;
    Data: RawByteString;
    Pos: Integer;
    Name: string;
    Strs: array of TStringObj;
    NStrs: Integer;
    procedure Fail(const why: string);
    procedure Need(n: Integer);
    function RByte: Byte;
    function RInt: Integer;
    function RInt64: Int64;
    function RDouble: Double;
    function RString: TStringObj;
    function RProto: TProto;
    procedure CheckLiteral(const s: string; const why: string);
    procedure Header;
  end;

procedure TUndumper.Fail(const why: string);
begin
  raise ELuaError.CreateMsg(Format('%s: bad binary format (%s)', [Name, why]));
end;

procedure TUndumper.Need(n: Integer);
begin
  if (n < 0) or (Pos + n - 1 > Length(Data)) then Fail('truncated chunk');
end;

function TUndumper.RByte: Byte;
begin
  Need(1);
  Result := Byte(Data[Pos]);
  Inc(Pos);
end;

function TUndumper.RInt: Integer;
begin
  Need(4);
  Move(Data[Pos], Result, 4);
  Inc(Pos, 4);
end;

function TUndumper.RInt64: Int64;
begin
  Need(8);
  Move(Data[Pos], Result, 8);
  Inc(Pos, 8);
end;

function TUndumper.RDouble: Double;
begin
  Need(8);
  Move(Data[Pos], Result, 8);
  Inc(Pos, 8);
end;

function TUndumper.RString: TStringObj;
var
  code, n: Integer;
  s: RawByteString;
begin
  code := RInt;
  if code = 0 then Exit(nil);
  if code = 1 then
  begin
    n := RInt;
    Need(n);
    SetLength(s, n);
    if n > 0 then Move(Data[Pos], s[1], n);
    Inc(Pos, n);
    Result := L.NewString(s);
    if NStrs >= Length(Strs) then SetLength(Strs, NStrs * 2 + 16);
    Strs[NStrs] := Result;
    Inc(NStrs);
    Exit;
  end;
  if (code - 2 < 0) or (code - 2 >= NStrs) then Fail('corrupted chunk');
  Result := Strs[code - 2];
end;

procedure TUndumper.CheckLiteral(const s: string; const why: string);
var
  i: Integer;
begin
  for i := 1 to Length(s) do
    if RByte <> Byte(s[i]) then Fail(why);
end;

procedure TUndumper.Header;
begin
  CheckLiteral(Copy(Signature, 2, 3), 'not a binary chunk');
  if RByte <> LuacVersion then Fail('version mismatch');
  if RByte <> LuacFormat then Fail('format mismatch');
  CheckLiteral(LuacData, 'corrupted chunk');
  if RByte <> 4 then Fail('int size mismatch');
  if RInt <> LuacInt then Fail('int format mismatch');
  if RByte <> 4 then Fail('Instruction size mismatch');
  if RInt <> LuacInst then Fail('Instruction format mismatch');
  if RByte <> 8 then Fail('Lua integer size mismatch');
  if RInt64 <> LuacInt then Fail('Lua integer format mismatch');
  if RByte <> 8 then Fail('Lua number size mismatch');
  if RDouble <> LuacNum then Fail('Lua number format mismatch');
end;

function TUndumper.RProto: TProto;
var
  p: TProto;
  i, n: Integer;
  t: Byte;
begin
  p := L.NewProto;
  Result := p;
  p.Source := RString;
  p.LineDefined := RInt;
  p.LastLineDefined := RInt;
  p.NumParams := RInt;
  p.IsVararg := RByte <> 0;
  p.VarTabReg := RInt;
  p.MaxStackSize := RInt;
  n := RInt;
  if (n < 0) or (n > (Length(Data) - Pos) div 13 + 1) then Fail('truncated chunk');
  SetLength(p.Code, n);
  for i := 0 to n - 1 do
  begin
    p.Code[i].Op := RByte;
    p.Code[i].A := RInt;
    p.Code[i].B := RInt;
    p.Code[i].C := RInt;
    if p.Code[i].Op >= NUM_OPCODES then Fail('corrupted chunk');
  end;
  n := RInt;
  if (n < 0) or (n > Length(Data) - Pos + 1) then Fail('truncated chunk');
  SetLength(p.K, n);
  for i := 0 to n - 1 do
  begin
    t := RByte;
    p.K[i].Vt := TValueType(t);
    case TValueType(t) of
      vtNil: ;
      vtBool: p.K[i].B := RByte <> 0;
      vtInt: p.K[i].I := RInt64;
      vtFlt: p.K[i].N := RDouble;
      vtStr: begin
        p.K[i].S := RString;
        if p.K[i].S = nil then Fail('corrupted chunk');
      end;
    else
      Fail('corrupted chunk');
    end;
  end;
  n := RInt;
  if (n < 0) or (n > Length(Data) - Pos + 1) then Fail('truncated chunk');
  SetLength(p.UpvalDescs, n);
  for i := 0 to n - 1 do
  begin
    p.UpvalDescs[i].InStack := RByte <> 0;
    p.UpvalDescs[i].Idx := RInt;
    p.UpvalDescs[i].IsConst := RByte <> 0;
    p.UpvalDescs[i].Name := nil;
  end;
  n := RInt;
  if (n < 0) or (n > Length(Data) - Pos + 1) then Fail('truncated chunk');
  SetLength(p.Protos, n);
  for i := 0 to n - 1 do
    p.Protos[i] := Self.RProto;
  // debug information
  n := RInt;
  if (n < 0) or (n > (Length(Data) - Pos) div 4 + 1) then Fail('truncated chunk');
  SetLength(p.LineInfo, n);
  for i := 0 to n - 1 do p.LineInfo[i] := RInt;
  n := RInt;
  if (n < 0) or (n > Length(Data) - Pos + 1) then Fail('truncated chunk');
  SetLength(p.LocVars, n);
  for i := 0 to n - 1 do
  begin
    p.LocVars[i].Name := RString;
    p.LocVars[i].StartPC := RInt;
    p.LocVars[i].EndPC := RInt;
    p.LocVars[i].Reg := RInt;
  end;
  n := RInt;
  if (n < 0) or (n > Length(Data) - Pos + 1) then Fail('truncated chunk');
  for i := 0 to n - 1 do
  begin
    if i >= Length(p.UpvalDescs) then Fail('corrupted chunk');
    p.UpvalDescs[i].Name := RString;
  end;
end;

function UndumpFunction(L: TLua; const data: RawByteString; const chunkName: string): TFunction;
var
  u: TUndumper;
  p: TProto;
  nups: Integer;
begin
  u := TUndumper.Create;
  try
    u.L := L;
    u.Data := data;
    u.Pos := 2;       // the first byte was already checked
    if (Length(chunkName) > 0) and (chunkName[1] in ['@', '=']) then
      u.Name := Copy(chunkName, 2, MaxInt)
    else if (Length(chunkName) > 0) and (chunkName[1] = #27) then
      u.Name := 'binary string'
    else
      u.Name := chunkName;
    u.Header;
    nups := u.RByte;
    p := u.RProto;
    if nups <> Length(p.UpvalDescs) then u.Fail('corrupted chunk');
    Result := L.NewLuaFunction(p);
  finally
    u.Free;
  end;
end;

end.
