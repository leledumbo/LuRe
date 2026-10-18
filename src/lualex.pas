unit lualex;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// Lexer for Lua 5.5 source text.
// Tokens are scanned one at a time; one token of lookahead is supported.

interface

uses
  SysUtils, Generics.Collections, luacore;

type
  TTokenKind = (
    tkEof, tkName, tkInt, tkFlt, tkString,
    tkAnd, tkBreak, tkDo, tkElse, tkElseIf, tkEnd, tkFalse, tkFor,
    tkFunction, tkGlobal, tkGoto, tkIf, tkIn, tkLocal, tkNil, tkNot,
    tkOr, tkRepeat, tkReturn, tkThen, tkTrue, tkUntil, tkWhile,
    tkPlus, tkMinus, tkStar, tkSlash, tkDblSlash, tkPercent, tkCaret,
    tkHash, tkAmp, tkTilde, tkPipe, tkShl, tkShr, tkConcat, tkDots,
    tkEq, tkNe, tkLe, tkGe, tkLt, tkGt, tkAssign,
    tkLParen, tkRParen, tkLBrace, tkRBrace, tkLBracket, tkRBracket,
    tkDblColon, tkSemi, tkColon, tkComma, tkDot,
    tkOther);   // any other single character (always a syntax error)

  TToken = record
    Kind: TTokenKind;
    Str: TStringObj;
    Int: Int64;
    Flt: Double;
    Name: string;
    Ch: Char;              // for tkOther
    First, Last: Integer;  // source range of the token text
  end;

  TLexer = class
  public
    L: TLua;
    ChunkId: string;     // chunk name as shown in messages
    Line: Integer;       // line currently being scanned
    LastLine: Integer;   // line of the last token consumed
    // current token
    Tok: TTokenKind;
    StrVal: TStringObj;
    IntVal: Int64;
    FltVal: Double;
    NameVal: string;
    constructor Create(AL: TLua; const ASource: RawByteString; const AChunkId: string);
    destructor Destroy; override;
    procedure Next;
    function LookAhead: TTokenKind;
    // raises "chunk:line: msg near <current token>"
    procedure SyntaxError(const msg: string);
    // raises "chunk:line: msg near <near>" ('near' already formatted, may be empty)
    procedure ErrorAt(const msg: string; const near: string);
    // token description as in "'x' expected": quoted for symbols and keywords
    function TokenStr(t: TTokenKind): string;
    // description of the current token for "near" parts of messages
    function CurTokenText: string;
    function NewStr(const s: RawByteString): TStringObj;
  private
    Source: RawByteString;
    Len: Integer;
    Pos: Integer;
    CurCh: Char;
    Buf: RawByteString;
    BufLen: Integer;
    Cur: TToken;
    Ahead: TToken;
    HasAhead: Boolean;
    LongStrs: specialize TDictionary<RawByteString, TStringObj>;
    procedure Advance; inline;
    procedure Save(c: Char); inline;
    procedure SaveAndNext; inline;
    function AtEof: Boolean; inline;
    procedure IncLineNumber;
    function BufText: string;
    function TokenText(const t: TToken): string;
    procedure LexError(const msg: string; tk: TTokenKind);
    procedure Scan(var t: TToken);
    function SkipSep: Integer;
    procedure ReadLongString(isString: Boolean; sep: Integer; var t: TToken);
    procedure ReadString(delim: Char; var t: TToken);
    procedure EscCheck(ok: Boolean; const msg: string);
    function GetHexa: Integer;
    function ReadHexaEsc: Integer;
    function ReadDecEsc: Integer;
    procedure ReadUtf8Esc;
    procedure ReadNumeral(var t: TToken);
  end;

implementation

const
  ReservedWords: array[tkAnd..tkWhile] of string = (
    'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for',
    'function', 'global', 'goto', 'if', 'in', 'local', 'nil', 'not',
    'or', 'repeat', 'return', 'then', 'true', 'until', 'while');

  TokenNames: array[tkPlus..tkDot] of string = (
    '+', '-', '*', '/', '//', '%', '^', '#', '&', '~', '|', '<<', '>>',
    '..', '...', '==', '~=', '<=', '>=', '<', '>', '=',
    '(', ')', '{', '}', '[', ']', '::', ';', ':', ',', '.');

constructor TLexer.Create(AL: TLua; const ASource: RawByteString; const AChunkId: string);
begin
  L := AL;
  Source := ASource;
  Len := Length(ASource);
  ChunkId := AChunkId;
  Pos := 1;
  Line := 1;
  LastLine := 1;
  HasAhead := False;
  SetLength(Buf, 64);
  BufLen := 0;
  LongStrs := specialize TDictionary<RawByteString, TStringObj>.Create;
  if Len > 0 then CurCh := Source[1] else CurCh := #0;
  Next;
end;

destructor TLexer.Destroy;
begin
  LongStrs.Free;
  inherited Destroy;
end;

// long strings with the same content share one object within a chunk
function TLexer.NewStr(const s: RawByteString): TStringObj;
begin
  Result := L.NewString(s);
  if Length(s) > LUA_MAXSHORTLEN then
  begin
    if not LongStrs.TryGetValue(s, Result) then
    begin
      Result := L.NewString(s);
      LongStrs.Add(s, Result);
    end;
  end;
end;

procedure TLexer.Advance;
begin
  Inc(Pos);
  if Pos <= Len then CurCh := Source[Pos] else CurCh := #0;
end;

function TLexer.AtEof: Boolean;
begin
  Result := Pos > Len;
end;

procedure TLexer.Save(c: Char);
begin
  if BufLen >= Length(Buf) then
    SetLength(Buf, Length(Buf) * 2);
  Inc(BufLen);
  Buf[BufLen] := c;
end;

procedure TLexer.SaveAndNext;
begin
  Save(CurCh);
  Advance;
end;

function TLexer.BufText: string;
begin
  Result := string(Copy(Buf, 1, BufLen));
end;

procedure TLexer.IncLineNumber;
var
  old: Char;
begin
  old := CurCh;
  Advance;  // skip '\n' or '\r'
  if (CurCh in [#10, #13]) and (CurCh <> old) and not AtEof then
    Advance;  // skip '\n\r' or '\r\n'
  Inc(Line);
end;

function TLexer.TokenStr(t: TTokenKind): string;
begin
  case t of
    tkEof: Result := '<eof>';
    tkName: Result := '<name>';
    tkInt: Result := '<integer>';
    tkFlt: Result := '<number>';
    tkString: Result := '<string>';
    tkAnd..tkWhile: Result := '''' + ReservedWords[t] + '''';
    tkPlus..tkDot: Result := '''' + TokenNames[t] + '''';
  else
    Result := '<other>';
  end;
end;

function TLexer.TokenText(const t: TToken): string;
begin
  case t.Kind of
    tkName, tkString, tkInt, tkFlt:
      Result := '''' + string(Copy(Source, t.First, t.Last - t.First + 1)) + '''';
    tkOther:
      if t.Ch in [#32..#126] then Result := '''' + t.Ch + ''''
      else Result := '''<\' + IntToStr(Ord(t.Ch)) + '>''';
  else
    Result := TokenStr(t.Kind);
  end;
end;

function TLexer.CurTokenText: string;
begin
  Result := TokenText(Cur);
end;

procedure TLexer.ErrorAt(const msg: string; const near: string);
begin
  if near <> '' then
    raise ELuaError.CreateMsg(Format('%s:%d: %s near %s', [ChunkId, Line, msg, near]))
  else
    raise ELuaError.CreateMsg(Format('%s:%d: %s', [ChunkId, Line, msg]));
end;

procedure TLexer.SyntaxError(const msg: string);
begin
  ErrorAt(msg, TokenText(Cur));
end;

// error raised while scanning: 'near' shows the partial token in the buffer
procedure TLexer.LexError(const msg: string; tk: TTokenKind);
begin
  case tk of
    tkName, tkString, tkInt, tkFlt:
      ErrorAt(msg, '''' + BufText + '''');
  else
    ErrorAt(msg, TokenStr(tk));
  end;
end;

// ---------------------------------------------------------------- scanning

// reads a sequence '[=*[' or ']=*]'; returns count+2 if well formed,
// 1 for a single bracket, 0 for a malformed delimiter
function TLexer.SkipSep: Integer;
var
  count: Integer;
  s: Char;
begin
  count := 0;
  s := CurCh;
  SaveAndNext;
  while CurCh = '=' do
  begin
    SaveAndNext;
    Inc(count);
  end;
  if CurCh = s then
    Result := count + 2
  else if count = 0 then
    Result := 1
  else
    Result := 0;
end;

procedure TLexer.ReadLongString(isString: Boolean; sep: Integer; var t: TToken);
var
  startLine: Integer;
  what: string;
begin
  startLine := Line;
  SaveAndNext;  // skip second '['
  if CurCh in [#10, #13] then
    IncLineNumber;  // first newline is not part of the string
  while True do
  begin
    if AtEof then
    begin
      if isString then what := 'string' else what := 'comment';
      ErrorAt(Format('unfinished long %s (starting at line %d)', [what, startLine]), '<eof>');
    end;
    case CurCh of
      ']':
        if SkipSep = sep then
        begin
          SaveAndNext;  // skip second ']'
          Break;
        end;
      #10, #13:
        begin
          Save(#10);
          IncLineNumber;
          if not isString then BufLen := 0;
        end;
    else
      if isString then SaveAndNext else Advance;
    end;
  end;
  if isString then
    t.Str := NewStr(Copy(Buf, 1 + sep, BufLen - 2 * sep));
end;

procedure TLexer.EscCheck(ok: Boolean; const msg: string);
begin
  if not ok then
  begin
    if not AtEof then SaveAndNext;  // add current char to the message
    LexError(msg, tkString);
  end;
end;

function TLexer.GetHexa: Integer;
begin
  SaveAndNext;
  EscCheck(CurCh in ['0'..'9', 'a'..'f', 'A'..'F'], 'hexadecimal digit expected');
  Result := HexDigitVal(CurCh);
end;

function TLexer.ReadHexaEsc: Integer;
begin
  Result := GetHexa;
  Result := (Result shl 4) + GetHexa;
  Dec(BufLen, 2);  // remove saved chars from the buffer
end;

function TLexer.ReadDecEsc: Integer;
var
  i: Integer;
begin
  Result := 0;
  i := 0;
  while (i < 3) and (CurCh in ['0'..'9']) do
  begin
    Result := 10 * Result + Ord(CurCh) - Ord('0');
    SaveAndNext;
    Inc(i);
  end;
  EscCheck(Result <= 255, 'decimal escape too large');
  Dec(BufLen, i);
end;

procedure TLexer.ReadUtf8Esc;
var
  i, n: Integer;
  r, x, mfb: QWord;
  tmp: array[0..7] of Char;
begin
  i := 4;  // chars to be removed: '\', 'u', '{', and first digit
  SaveAndNext;  // skip 'u'
  EscCheck(CurCh = '{', 'missing ''{''');
  r := GetHexa;  // must have at least one digit
  SaveAndNext;
  while CurCh in ['0'..'9', 'a'..'f', 'A'..'F'] do
  begin
    Inc(i);
    EscCheck(r <= ($7FFFFFFF shr 4), 'UTF-8 value too large');
    r := (r shl 4) + QWord(HexDigitVal(CurCh));
    SaveAndNext;
  end;
  EscCheck(CurCh = '}', 'missing ''}''');
  Advance;  // skip '}'
  Dec(BufLen, i);  // remove saved chars from the buffer
  // encode r as UTF-8 (up to 6 bytes)
  if r < $80 then
  begin
    Save(Chr(r));
    Exit;
  end;
  n := 1;
  x := r;
  mfb := $3f;  // maximum that fits in the first byte
  repeat
    tmp[8 - n] := Chr($80 or (x and $3f));
    Inc(n);
    x := x shr 6;
    mfb := mfb shr 1;
  until x <= mfb;
  tmp[8 - n] := Chr((((not mfb) shl 1) and $FF) or x);
  for i := 8 - n to 7 do
    Save(tmp[i]);
end;

procedure TLexer.ReadString(delim: Char; var t: TToken);
type
  TAfter = (afReadSave, afOnlySave, afNoSave);
var
  c: Integer;
  after: TAfter;
begin
  SaveAndNext;  // keep delimiter (for error messages)
  while CurCh <> delim do
  begin
    if AtEof then
      LexError('unfinished string', tkEof);
    case CurCh of
      #10, #13:
        LexError('unfinished string', tkString);
      '\':
        begin
          SaveAndNext;  // keep '\' for error messages
          c := 0;
          after := afReadSave;
          case CurCh of
            'a': c := 7;
            'b': c := 8;
            'f': c := 12;
            'n': c := 10;
            'r': c := 13;
            't': c := 9;
            'v': c := 11;
            'x': c := ReadHexaEsc;
            'u': begin ReadUtf8Esc; after := afNoSave; end;
            #10, #13:
              begin
                IncLineNumber;
                c := 10;
                after := afOnlySave;
              end;
            '\', '"', '''': c := Ord(CurCh);
          else
            if AtEof then
              after := afNoSave  // will raise an error in the next iteration
            else if CurCh = 'z' then
            begin
              Dec(BufLen);  // remove '\'
              Advance;      // skip the 'z'
              while (CurCh in [' ', #9, #10, #11, #12, #13]) and not AtEof do
                if CurCh in [#10, #13] then IncLineNumber else Advance;
              after := afNoSave;
            end
            else
            begin
              EscCheck(CurCh in ['0'..'9'], 'invalid escape sequence');
              c := ReadDecEsc;
              after := afOnlySave;
            end;
          end;
          if after = afReadSave then
            Advance;
          if after <> afNoSave then
          begin
            Dec(BufLen);  // remove '\'
            Save(Chr(c));
          end;
        end;
    else
      SaveAndNext;
    end;
  end;
  SaveAndNext;  // skip closing delimiter
  t.Str := NewStr(Copy(Buf, 2, BufLen - 2));
end;

procedure TLexer.ReadNumeral(var t: TToken);
var
  expo: string;
  iv: Int64;
  fv: Double;
  txt: RawByteString;
begin
  expo := 'Ee';
  if CurCh = '0' then
  begin
    SaveAndNext;
    if CurCh in ['x', 'X'] then
    begin
      expo := 'Pp';
      SaveAndNext;
    end;
  end;
  while True do
  begin
    if (CurCh <> #0) and (System.Pos(CurCh, expo) > 0) then
    begin
      SaveAndNext;
      if CurCh in ['+', '-'] then SaveAndNext;
    end
    else if CurCh in ['0'..'9', 'a'..'f', 'A'..'F', '.'] then
      SaveAndNext
    else
      Break;
  end;
  if CurCh in ['a'..'z', 'A'..'Z', '_'] then
    SaveAndNext;  // force an error
  txt := Copy(Buf, 1, BufLen);
  if StrToIntVal(txt, iv) then
  begin
    t.Kind := tkInt;
    t.Int := iv;
  end
  else if StrToNumVal(txt, fv) then
  begin
    t.Kind := tkFlt;
    t.Flt := fv;
  end
  else
    LexError('malformed number', tkFlt);
end;

procedure TLexer.Scan(var t: TToken);
var
  sep: Integer;
  c: Char;
  k: TTokenKind;
begin
  t.Str := nil;
  t.Name := '';
  BufLen := 0;
  while True do
  begin
    t.First := Pos;
    if AtEof then
    begin
      t.Kind := tkEof;
      Break;
    end;
    c := CurCh;
    case c of
      #10, #13:
        begin
          IncLineNumber;
          Continue;
        end;
      ' ', #12, #9, #11:
        begin
          Advance;
          Continue;
        end;
      '-':
        begin
          Advance;
          if CurCh <> '-' then
          begin
            t.Kind := tkMinus;
            Break;
          end;
          Advance;
          if CurCh = '[' then
          begin
            sep := SkipSep;
            BufLen := 0;
            if sep >= 2 then
            begin
              ReadLongString(False, sep, t);
              BufLen := 0;
              Continue;
            end;
          end;
          while not (CurCh in [#10, #13]) and not AtEof do
            Advance;
          Continue;
        end;
      '[':
        begin
          sep := SkipSep;
          if sep >= 2 then
          begin
            ReadLongString(True, sep, t);
            t.Kind := tkString;
          end
          else if sep = 0 then
            LexError('invalid long string delimiter', tkString)
          else
            t.Kind := tkLBracket;
          Break;
        end;
      '=':
        begin
          Advance;
          if CurCh = '=' then begin Advance; t.Kind := tkEq; end else t.Kind := tkAssign;
          Break;
        end;
      '<':
        begin
          Advance;
          if CurCh = '=' then begin Advance; t.Kind := tkLe; end
          else if CurCh = '<' then begin Advance; t.Kind := tkShl; end
          else t.Kind := tkLt;
          Break;
        end;
      '>':
        begin
          Advance;
          if CurCh = '=' then begin Advance; t.Kind := tkGe; end
          else if CurCh = '>' then begin Advance; t.Kind := tkShr; end
          else t.Kind := tkGt;
          Break;
        end;
      '/':
        begin
          Advance;
          if CurCh = '/' then begin Advance; t.Kind := tkDblSlash; end else t.Kind := tkSlash;
          Break;
        end;
      '~':
        begin
          Advance;
          if CurCh = '=' then begin Advance; t.Kind := tkNe; end else t.Kind := tkTilde;
          Break;
        end;
      ':':
        begin
          Advance;
          if CurCh = ':' then begin Advance; t.Kind := tkDblColon; end else t.Kind := tkColon;
          Break;
        end;
      '"', '''':
        begin
          ReadString(c, t);
          t.Kind := tkString;
          Break;
        end;
      '.':
        begin
          SaveAndNext;
          if CurCh = '.' then
          begin
            Advance;
            if CurCh = '.' then begin Advance; t.Kind := tkDots; end
            else t.Kind := tkConcat;
          end
          else if not (CurCh in ['0'..'9']) then
            t.Kind := tkDot
          else
            ReadNumeral(t);
          Break;
        end;
      '0'..'9':
        begin
          ReadNumeral(t);
          Break;
        end;
      'a'..'z', 'A'..'Z', '_':
        begin
          repeat
            SaveAndNext;
          until not (CurCh in ['a'..'z', 'A'..'Z', '_', '0'..'9']);
          t.Name := BufText;
          t.Kind := tkName;
          for k := tkAnd to tkWhile do
            if (ReservedWords[k] = t.Name) and (k <> tkGlobal) then  // 'global' is contextual
            begin
              t.Kind := k;
              Break;
            end;
          Break;
        end;
      '+': begin Advance; t.Kind := tkPlus; Break; end;
      '*': begin Advance; t.Kind := tkStar; Break; end;
      '%': begin Advance; t.Kind := tkPercent; Break; end;
      '^': begin Advance; t.Kind := tkCaret; Break; end;
      '#': begin Advance; t.Kind := tkHash; Break; end;
      '&': begin Advance; t.Kind := tkAmp; Break; end;
      '|': begin Advance; t.Kind := tkPipe; Break; end;
      '(': begin Advance; t.Kind := tkLParen; Break; end;
      ')': begin Advance; t.Kind := tkRParen; Break; end;
      '{': begin Advance; t.Kind := tkLBrace; Break; end;
      '}': begin Advance; t.Kind := tkRBrace; Break; end;
      ']': begin Advance; t.Kind := tkRBracket; Break; end;
      ';': begin Advance; t.Kind := tkSemi; Break; end;
      ',': begin Advance; t.Kind := tkComma; Break; end;
    else
      begin
        t.Kind := tkOther;
        t.Ch := c;
        Advance;
        Break;
      end;
    end;
  end;
  t.Last := Pos - 1;
end;

procedure TLexer.Next;
begin
  LastLine := Line;
  if HasAhead then
  begin
    Cur := Ahead;
    HasAhead := False;
  end
  else
    Scan(Cur);
  Tok := Cur.Kind;
  StrVal := Cur.Str;
  IntVal := Cur.Int;
  FltVal := Cur.Flt;
  NameVal := Cur.Name;
end;

function TLexer.LookAhead: TTokenKind;
begin
  if not HasAhead then
  begin
    Scan(Ahead);
    HasAhead := True;
  end;
  Result := Ahead.Kind;
end;

end.
