unit lualibio;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$POINTERMATH ON}

// The input/output library, implemented over the C stdio streams.

interface

uses
  SysUtils, Math, luacore, luavm, luaaux;

procedure OpenIO(L: TLua);

implementation

type
  TCloseKind = (ckClosed, ckFile, ckPopen, ckNoClose);

  TLStream = class
  public
    F: Pointer;
    Kind: TCloseKind;
  end;

function c_fopen(name, mode: PChar): Pointer; cdecl; external 'c' name 'fopen';
function c_fclose(f: Pointer): Integer; cdecl; external 'c' name 'fclose';
function c_fread(buf: Pointer; size, n: SizeUInt; f: Pointer): SizeUInt; cdecl; external 'c' name 'fread';
function c_fwrite(buf: Pointer; size, n: SizeUInt; f: Pointer): SizeUInt; cdecl; external 'c' name 'fwrite';
function c_fflush(f: Pointer): Integer; cdecl; external 'c' name 'fflush';
function c_fseeko(f: Pointer; off: Int64; whence: Integer): Integer; cdecl; external 'c' name 'fseeko';
function c_ftello(f: Pointer): Int64; cdecl; external 'c' name 'ftello';
function c_setvbuf(f: Pointer; buf: Pointer; mode: Integer; size: SizeUInt): Integer; cdecl; external 'c' name 'setvbuf';
function c_getc(f: Pointer): Integer; cdecl; external 'c' name 'getc';
function c_ungetc(c: Integer; f: Pointer): Integer; cdecl; external 'c' name 'ungetc';
procedure c_clearerr(f: Pointer); cdecl; external 'c' name 'clearerr';
function c_ferror(f: Pointer): Integer; cdecl; external 'c' name 'ferror';
function c_popen(cmd, mode: PChar): Pointer; cdecl; external 'c' name 'popen';
function c_pclose(f: Pointer): Integer; cdecl; external 'c' name 'pclose';
function c_tmpfile: Pointer; cdecl; external 'c' name 'tmpfile';
function c_errno_location: PInteger; cdecl; external 'c' name '__errno_location';

var
  c_stdin: Pointer; external name 'stdin';
  c_stdout: Pointer; external name 'stdout';
  c_stderr: Pointer; external name 'stderr';

const
  FILEHANDLE = 'FILE*';
  REG_INPUT = '_IO_input';
  REG_OUTPUT = '_IO_output';
  MAXARGLINE = 250;
  L_MAXLENNUM = 200;
  EOF_ = -1;

procedure ClearErrno;
begin
  c_errno_location^ := 0;
end;

{ ------------------------------------------------------------------ }
{ file handles                                                        }
{ ------------------------------------------------------------------ }

function TestStream(L: TLua; arg: Integer): TLStream;
var
  v: TLuaValue;
  mt: TTable;
begin
  Result := nil;
  v := LuaArg(L, arg);
  if v.Vt <> vtUser then Exit;
  mt := v.U.Metatable;
  if (mt = nil) or (mt <> GetMetatableByName(L, FILEHANDLE)) then Exit;
  Result := TLStream(v.U.Obj);
end;

function ToLStream(L: TLua; arg: Integer): TLStream;
begin
  Result := TestStream(L, arg);
  if Result = nil then TypeErrorArg(L, arg, FILEHANDLE);
end;

function ToFile(L: TLua; arg: Integer): Pointer;
var
  p: TLStream;
begin
  p := ToLStream(L, arg);
  if p.Kind = ckClosed then LuaError(L, 'attempt to use a closed file');
  Result := p.F;
end;

// creates a file handle in 'closed' state
function NewPreFile(L: TLua): TLStream;
var
  u: TUserdata;
begin
  u := L.NewUserdata(0);
  Result := TLStream.Create;
  Result.Kind := ckClosed;
  u.Obj := Result;
  u.Metatable := GetMetatableByName(L, FILEHANDLE);
  L.SetFinalizer(u);
  LuaPush(L, LuaUser(u));
end;

function NewFile(L: TLua): TLStream;
begin
  Result := NewPreFile(L);
  Result.Kind := ckFile;
end;

function ExecResult(L: TLua; stat: Integer): Integer;
var
  what: string;
begin
  if stat = -1 then
  begin
    Result := FileResult(L, False, '');
    Exit;
  end;
  if (stat and $7F) = 0 then
  begin
    what := 'exit';
    stat := (stat shr 8) and $FF;
  end
  else
  begin
    what := 'signal';
    stat := stat and $7F;
  end;
  if (what = 'exit') and (stat = 0) then PushBool(L, True) else PushFail(L);
  PushStr(L, RawByteString(what));
  PushInt(L, stat);
  Result := 3;
end;

// closes the stream at index 1 (already checked to be open)
function AuxClose(L: TLua): Integer;
var
  p: TLStream;
  kind: TCloseKind;
begin
  p := ToLStream(L, 1);
  kind := p.Kind;
  p.Kind := ckClosed;
  case kind of
    ckFile: begin
      ClearErrno;
      Result := FileResult(L, c_fclose(p.F) = 0, '');
    end;
    ckPopen: begin
      ClearErrno;
      Result := ExecResult(L, c_pclose(p.F));
    end;
  else
    begin
      p.Kind := ckNoClose;
      PushFail(L);
      PushStr(L, 'cannot close standard file');
      Result := 2;
    end;
  end;
end;

function f_close(L: TLua): Integer;
begin
  ToFile(L, 1);
  Result := AuxClose(L);
end;

function io_close(L: TLua): Integer;
begin
  if ArgIsNone(L, 1) then
    LuaPush(L, TableGetStr(L.Registry, StrKey(L, REG_OUTPUT)));
  Result := f_close(L);
end;

function f_gc(L: TLua): Integer;
var
  p: TLStream;
begin
  p := ToLStream(L, 1);
  if (p.Kind <> ckClosed) and (p.F <> nil) then
    AuxClose(L);
  Result := 0;
end;

function f_tostring(L: TLua): Integer;
var
  p: TLStream;
begin
  p := ToLStream(L, 1);
  if p.Kind = ckClosed then
    PushStr(L, 'file (closed)')
  else
    PushStr(L, RawByteString('file (0x' + LowerCase(IntToHex(PtrUInt(p.F), 14)) + ')'));
  Result := 1;
end;

function io_type(L: TLua): Integer;
var
  p: TLStream;
begin
  CheckAny(L, 1);
  p := TestStream(L, 1);
  if p = nil then PushFail(L)
  else if p.Kind = ckClosed then PushStr(L, 'closed file')
  else PushStr(L, 'file');
  Result := 1;
end;

function CheckMode(const mode: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (mode = '') or not (mode[1] in ['r', 'w', 'a']) then Exit;
  i := 2;
  if (i <= Length(mode)) and (mode[i] = '+') then Inc(i);
  while i <= Length(mode) do
  begin
    if mode[i] <> 'b' then Exit;
    Inc(i);
  end;
  Result := True;
end;

function io_open(L: TLua): Integer;
var
  fname, mode: string;
  p: TLStream;
begin
  fname := string(CheckString(L, 1));
  mode := string(OptString(L, 2, 'r'));
  p := NewFile(L);
  if not CheckMode(mode) then ArgError(L, 2, 'invalid mode');
  ClearErrno;
  p.F := c_fopen(PChar(fname), PChar(mode));
  if p.F = nil then
  begin
    p.Kind := ckClosed;
    Result := FileResult(L, False, fname);
  end
  else
    Result := 1;
end;

function io_popen(L: TLua): Integer;
var
  cmd, mode: string;
  p: TLStream;
begin
  cmd := string(CheckString(L, 1));
  mode := string(OptString(L, 2, 'r'));
  p := NewPreFile(L);
  if not (((mode = 'r') or (mode = 'w'))) then ArgError(L, 2, 'invalid mode');
  ClearErrno;
  c_fflush(nil);
  p.F := c_popen(PChar(cmd), PChar(mode));
  p.Kind := ckPopen;
  if p.F = nil then
  begin
    p.Kind := ckClosed;
    Result := FileResult(L, False, cmd);
  end
  else
    Result := 1;
end;

function io_tmpfile(L: TLua): Integer;
var
  p: TLStream;
begin
  p := NewFile(L);
  ClearErrno;
  p.F := c_tmpfile;
  if p.F = nil then
  begin
    p.Kind := ckClosed;
    Result := FileResult(L, False, '');
  end
  else
    Result := 1;
end;

function GetIOFile(L: TLua; const findex: string): Pointer;
var
  v: TLuaValue;
  p: TLStream;
begin
  v := TableGetStr(L.Registry, StrKey(L, findex));
  p := TLStream(v.U.Obj);
  if p.Kind = ckClosed then
    LuaError(L, Format('default %s file is closed', [Copy(findex, 5, MaxInt)]));
  Result := p.F;
end;

function g_iofile(L: TLua; const f, mode: string): Integer;
var
  v: TLuaValue;
  fname: string;
  p: TLStream;
begin
  if not ArgIsNoneOrNil(L, 1) then
  begin
    v := LuaArg(L, 1);
    if v.Vt = vtStr then
    begin
      fname := string(v.S.Str);
      p := NewFile(L);
      p.F := c_fopen(PChar(fname), PChar(mode));
      if p.F = nil then
        LuaError(L, Format('cannot open file ''%s'' (%s)', [fname, StrError(GetErrno)]));
      TableSetStr(L.Registry, StrKey(L, f), L.Stack[L.Top - 1]);
    end
    else
    begin
      ToFile(L, 1);
      TableSetStr(L.Registry, StrKey(L, f), v);
    end;
  end;
  LuaPush(L, TableGetStr(L.Registry, StrKey(L, f)));
  Result := 1;
end;

function io_input(L: TLua): Integer;
begin
  Result := g_iofile(L, REG_INPUT, 'r');
end;

function io_output(L: TLua): Integer;
begin
  Result := g_iofile(L, REG_OUTPUT, 'w');
end;

{ ------------------------------------------------------------------ }
{ reading                                                             }
{ ------------------------------------------------------------------ }

type
  TRN = record
    F: Pointer;
    C: Integer;
    N: Integer;
    Buff: array[0..L_MAXLENNUM + 1] of Char;
  end;

function IsSpaceC(c: Integer): Boolean; inline;
begin
  Result := (c = 32) or ((c >= 9) and (c <= 13));
end;

function IsDigitC(c: Integer): Boolean; inline;
begin
  Result := (c >= 48) and (c <= 57);
end;

function IsXDigitC(c: Integer): Boolean; inline;
begin
  Result := IsDigitC(c) or ((c >= 65) and (c <= 70)) or ((c >= 97) and (c <= 102));
end;

function NextC(var rn: TRN): Boolean;
begin
  if rn.N >= L_MAXLENNUM then
  begin
    rn.Buff[0] := #0;
    Exit(False);
  end;
  rn.Buff[rn.N] := Chr(rn.C and $FF);
  Inc(rn.N);
  rn.C := c_getc(rn.F);
  Result := True;
end;

function Test2(var rn: TRN; a, b: Char): Boolean;
begin
  if (rn.C = Ord(a)) or (rn.C = Ord(b)) then
    Result := NextC(rn)
  else
    Result := False;
end;

function ReadDigits(var rn: TRN; hex: Boolean): Integer;
begin
  Result := 0;
  while ((hex and IsXDigitC(rn.C)) or ((not hex) and IsDigitC(rn.C))) and NextC(rn) do
    Inc(Result);
end;

function ReadNumber(L: TLua; f: Pointer): Boolean;
var
  rn: TRN;
  count: Integer;
  hex: Boolean;
  s: RawByteString;
  iv: Int64;
  nv: Double;
begin
  rn.F := f;
  rn.N := 0;
  count := 0;
  hex := False;
  repeat
    rn.C := c_getc(f);
  until not IsSpaceC(rn.C);
  Test2(rn, '-', '+');
  if Test2(rn, '0', '0') then
  begin
    if Test2(rn, 'x', 'X') then hex := True else count := 1;
  end;
  Inc(count, ReadDigits(rn, hex));
  if Test2(rn, '.', '.') then
    Inc(count, ReadDigits(rn, hex));
  if (count > 0) and (hex and Test2(rn, 'p', 'P') or (not hex) and Test2(rn, 'e', 'E')) then
  begin
    Test2(rn, '-', '+');
    ReadDigits(rn, False);
  end;
  c_ungetc(rn.C, f);
  rn.Buff[rn.N] := #0;
  s := RawByteString(StrPas(PChar(@rn.Buff[0])));
  if StrToIntVal(s, iv) then
  begin
    PushInt(L, iv);
    Exit(True);
  end;
  if StrToNumVal(s, nv) then
  begin
    PushNum(L, nv);
    Exit(True);
  end;
  PushNil(L);
  Result := False;
end;

function TestEof(L: TLua; f: Pointer): Boolean;
var
  c: Integer;
begin
  c := c_getc(f);
  c_ungetc(c, f);
  PushStr(L, '');
  Result := c <> EOF_;
end;

function ReadLine(L: TLua; f: Pointer; chop: Boolean): Boolean;
var
  b: RawByteString;
  c: Integer;
  n, i: Integer;
  chunk: array[0..1023] of Char;
begin
  b := '';
  repeat
    i := 0;
    c := 0;
    while i < SizeOf(chunk) do
    begin
      c := c_getc(f);
      if (c = EOF_) or (c = 10) then Break;
      chunk[i] := Chr(c);
      Inc(i);
    end;
    if i > 0 then
    begin
      n := Length(b);
      SetLength(b, n + i);
      Move(chunk[0], b[n + 1], i);
    end;
  until (c = EOF_) or (c = 10);
  if (not chop) and (c = 10) then b := b + #10;
  PushStr(L, b);
  Result := (c = 10) or (Length(b) > 0);
end;

procedure ReadAll(L: TLua; f: Pointer);
var
  b: RawByteString;
  nr: SizeUInt;
  chunk: array[0..4095] of Char;
  n: Integer;
begin
  b := '';
  repeat
    nr := c_fread(@chunk[0], 1, SizeOf(chunk), f);
    if nr > 0 then
    begin
      n := Length(b);
      SetLength(b, n + Integer(nr));
      Move(chunk[0], b[n + 1], nr);
    end;
  until nr < SizeOf(chunk);
  PushStr(L, b);
end;

function ReadChars(L: TLua; f: Pointer; n: SizeUInt): Boolean;
var
  b: RawByteString;
  nr: SizeUInt;
begin
  SetLength(b, n);
  nr := 0;
  if n > 0 then nr := c_fread(Pointer(b), 1, n, f);
  SetLength(b, nr);
  PushStr(L, b);
  Result := nr > 0;
end;

function GRead(L: TLua; f: Pointer; first: Integer): Integer;
var
  nargs, n: Integer;
  success: Boolean;
  v: TLuaValue;
  fmt: RawByteString;
  p: Char;
  cnt: Int64;
begin
  nargs := LuaGetTop(L) - first + 1;
  c_clearerr(f);
  ClearErrno;
  if nargs = 0 then
  begin
    success := ReadLine(L, f, True);
    n := first + 1;
  end
  else
  begin
    L.EnsureStack(L.Top + nargs + 25);
    success := True;
    n := first;
    while (nargs > 0) and success do
    begin
      Dec(nargs);
      v := LuaArg(L, n);
      if v.Vt in [vtInt, vtFlt] then
      begin
        cnt := CheckInteger(L, n);
        if cnt = 0 then success := TestEof(L, f) else success := ReadChars(L, f, SizeUInt(cnt));
      end
      else
      begin
        fmt := CheckString(L, n);
        if (Length(fmt) > 0) and (fmt[1] = '*') then Delete(fmt, 1, 1);
        if fmt = '' then p := #0 else p := fmt[1];
        case p of
          'n': success := ReadNumber(L, f);
          'l': success := ReadLine(L, f, True);
          'L': success := ReadLine(L, f, False);
          'a': begin ReadAll(L, f); success := True; end;
        else
          ArgError(L, n, 'invalid format');
        end;
      end;
      Inc(n);
    end;
  end;
  if c_ferror(f) <> 0 then
    Exit(FileResult(L, False, ''));
  if not success then
  begin
    Dec(L.Top);
    PushFail(L);
  end;
  Result := n - first;
end;

function io_read(L: TLua): Integer;
begin
  Result := GRead(L, GetIOFile(L, REG_INPUT), 1);
end;

function f_read(L: TLua): Integer;
begin
  Result := GRead(L, ToFile(L, 1), 2);
end;

// iteration function of 'lines'
function io_readline(L: TLua): Integer;
var
  fn: TFunction;
  p: TLStream;
  n, i: Integer;
  err: TLuaValue;
begin
  fn := L.CI[L.NCI - 1].Func;
  p := TLStream(fn.CVals[0].U.Obj);
  n := Integer(fn.CVals[1].I);
  if p.Kind = ckClosed then LuaError(L, 'file is already closed');
  LuaSetTop(L, 1);
  L.EnsureStack(L.Top + n + 25);
  for i := 1 to n do
    LuaPush(L, fn.CVals[2 + i]);
  n := GRead(L, p.F, 2);
  if Truthy(L.Stack[L.Top - n]) then
    Exit(n);
  if n > 1 then
  begin
    err := L.Stack[L.Top - n + 1];
    LuaError(L, string(err.S.Str));
  end;
  if Truthy(fn.CVals[2]) then
  begin
    LuaSetTop(L, 0);
    LuaPush(L, fn.CVals[0]);
    AuxClose(L);
  end;
  Result := 0;
end;

procedure AuxLines(L: TLua; toclose: Boolean);
var
  n, i: Integer;
  f: TFunction;
begin
  n := LuaGetTop(L) - 1;
  if n > MAXARGLINE then ArgError(L, MAXARGLINE + 2, 'too many arguments');
  f := L.NewCFunction(@io_readline, 3 + n);
  f.CVals[0] := LuaArg(L, 1);
  f.CVals[1] := LuaInt(n);
  f.CVals[2] := LuaBool(toclose);
  for i := 1 to n do f.CVals[2 + i] := LuaArg(L, 1 + i);
  LuaPush(L, LuaFunc(f));
end;

function f_lines(L: TLua): Integer;
begin
  ToFile(L, 1);
  AuxLines(L, False);
  Result := 1;
end;

function io_lines(L: TLua): Integer;
var
  toclose: Boolean;
  fname: string;
  p: TLStream;
  v: TLuaValue;
begin
  if ArgIsNone(L, 1) then PushNil(L);
  if LuaArg(L, 1).Vt = vtNil then
  begin
    L.Stack[LuaAbsIndex(L, 1)] := TableGetStr(L.Registry, StrKey(L, REG_INPUT));
    ToFile(L, 1);
    toclose := False;
  end
  else
  begin
    fname := string(CheckString(L, 1));
    p := NewFile(L);
    p.F := c_fopen(PChar(fname), 'r');
    if p.F = nil then
      LuaError(L, Format('cannot open file ''%s'' (%s)', [fname, StrError(GetErrno)]));
    v := L.Stack[L.Top - 1];
    Dec(L.Top);
    L.Stack[LuaAbsIndex(L, 1)] := v;
    toclose := True;
  end;
  AuxLines(L, toclose);
  if toclose then
  begin
    PushNil(L);
    PushNil(L);
    LuaPush(L, LuaArg(L, 1));
    Result := 4;
  end
  else
    Result := 1;
end;

{ ------------------------------------------------------------------ }
{ writing and positioning                                             }
{ ------------------------------------------------------------------ }

function GWrite(L: TLua; f: Pointer; arg: Integer): Integer;
var
  nargs, total: Integer;
  v: TLuaValue;
  s: RawByteString;
  numbytes: SizeUInt;
begin
  nargs := LuaGetTop(L) - arg;
  total := 0;
  ClearErrno;
  while nargs > 0 do
  begin
    Dec(nargs);
    v := LuaArg(L, arg);
    if v.Vt in [vtInt, vtFlt] then
      s := RawByteString(NumToStr(v))
    else
      s := CheckString(L, arg);
    numbytes := 0;
    if Length(s) > 0 then numbytes := c_fwrite(Pointer(s), 1, Length(s), f)
    else numbytes := 0;
    Inc(total, Integer(numbytes));
    if numbytes < SizeUInt(Length(s)) then
    begin
      Result := FileResult(L, False, '');
      PushInt(L, total);
      Exit(Result + 1);
    end;
    Inc(arg);
  end;
  Result := 1;
end;

function io_write(L: TLua): Integer;
var
  f: Pointer;
begin
  f := GetIOFile(L, REG_OUTPUT);
  LuaPush(L, TableGetStr(L.Registry, StrKey(L, REG_OUTPUT)));
  Result := GWrite(L, f, 1);
end;

function f_write(L: TLua): Integer;
var
  f: Pointer;
begin
  f := ToFile(L, 1);
  LuaPush(L, LuaArg(L, 1));
  // the file handle is returned: write the arguments, then leave the file on top
  Result := GWrite(L, f, 2);
end;

function f_seek(L: TLua): Integer;
const
  Modes: array[0..2] of Integer = (0, 1, 2);
  ModeNames: array[0..2] of string = ('set', 'cur', 'end');
var
  f: Pointer;
  op: Integer;
  off: Int64;
begin
  f := ToFile(L, 1);
  op := CheckOption(L, 2, 'cur', ModeNames);
  off := OptInteger(L, 3, 0);
  ClearErrno;
  if c_fseeko(f, off, Modes[op]) <> 0 then
    Exit(FileResult(L, False, ''));
  PushInt(L, c_ftello(f));
  Result := 1;
end;

function f_setvbuf(L: TLua): Integer;
const
  Modes: array[0..2] of Integer = (2, 0, 1);
  ModeNames: array[0..2] of string = ('no', 'full', 'line');
var
  f: Pointer;
  op: Integer;
  sz: Int64;
  res: Integer;
begin
  f := ToFile(L, 1);
  op := CheckOption(L, 2, '', ModeNames);
  sz := OptInteger(L, 3, 1024);
  ClearErrno;
  res := c_setvbuf(f, nil, Modes[op], SizeUInt(sz));
  Result := FileResult(L, res = 0, '');
end;

function AuxFlush(L: TLua; f: Pointer): Integer;
begin
  ClearErrno;
  Result := FileResult(L, c_fflush(f) = 0, '');
end;

function f_flush(L: TLua): Integer;
begin
  Result := AuxFlush(L, ToFile(L, 1));
end;

function io_flush(L: TLua): Integer;
begin
  Result := AuxFlush(L, GetIOFile(L, REG_OUTPUT));
end;

function io_noclose(L: TLua): Integer;
begin
  Result := 0;
end;

procedure CreateStdFile(L: TLua; t: TTable; f: Pointer; const key, fname: string);
var
  p: TLStream;
  v: TLuaValue;
begin
  p := NewPreFile(L);
  p.F := f;
  p.Kind := ckNoClose;
  v := L.Stack[L.Top - 1];
  Dec(L.Top);
  if key <> '' then TableSetStr(L.Registry, StrKey(L, key), v);
  SetField(L, t, fname, v);
end;

procedure OpenIO(L: TLua);
const
  IoFuncs: array[0..10] of TLibFunc = (
    (Name: 'close'; Func: @io_close),
    (Name: 'flush'; Func: @io_flush),
    (Name: 'input'; Func: @io_input),
    (Name: 'lines'; Func: @io_lines),
    (Name: 'open'; Func: @io_open),
    (Name: 'output'; Func: @io_output),
    (Name: 'popen'; Func: @io_popen),
    (Name: 'read'; Func: @io_read),
    (Name: 'tmpfile'; Func: @io_tmpfile),
    (Name: 'type'; Func: @io_type),
    (Name: 'write'; Func: @io_write));
  Meths: array[0..6] of TLibFunc = (
    (Name: 'read'; Func: @f_read),
    (Name: 'write'; Func: @f_write),
    (Name: 'lines'; Func: @f_lines),
    (Name: 'flush'; Func: @f_flush),
    (Name: 'seek'; Func: @f_seek),
    (Name: 'close'; Func: @f_close),
    (Name: 'setvbuf'; Func: @f_setvbuf));
  MetaMeths: array[0..2] of TLibFunc = (
    (Name: '__gc'; Func: @f_gc),
    (Name: '__close'; Func: @f_gc),
    (Name: '__tostring'; Func: @f_tostring));
var
  t, mt, meth: TTable;
begin
  t := NewLib(L, 'io', IoFuncs);
  mt := NewMetatable(L, FILEHANDLE);
  RegisterFuncs(L, mt, MetaMeths);
  meth := L.NewTable(0, 8);
  RegisterFuncs(L, meth, Meths);
  SetField(L, mt, '__index', LuaTab(meth));
  CreateStdFile(L, t, c_stdin, REG_INPUT, 'stdin');
  CreateStdFile(L, t, c_stdout, REG_OUTPUT, 'stdout');
  CreateStdFile(L, t, c_stderr, '', 'stderr');
end;

end.
