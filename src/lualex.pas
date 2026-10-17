unit lualex;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, luacore;

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
    tkDblColon, tkSemi, tkColon, tkComma, tkDot);

  TLexer = class
  public
    L: TLua;
    Source: RawByteString;
    Pos: Integer;
    Len: Integer;
    Line: Integer;
    Tok: TTokenKind;
    StrVal: TStringObj;
    IntVal: Int64;
    FltVal: Double;
    NameVal: string;
    constructor Create(AL: TLua; const ASource: RawByteString);
    procedure Next;
    function Peek: TTokenKind;
    procedure Error(const msg: string);
    function TokenName(t: TTokenKind): string;
  private
    HasPeek: Boolean;
    PeekTok: TTokenKind;
    PeekStr: TStringObj;
    PeekInt: Int64;
    PeekFlt: Double;
    PeekName: string;
    CurCh: Char;
    procedure Advance;
    function ChAt(off: Integer): Char;
    procedure SkipSpace;
    procedure ReadLongString(nEq: Integer; isComment: Boolean);
    function ReadNumber: TTokenKind;
    function ReadString: TTokenKind;
    function ReadName: TTokenKind;
    function ReadEscapedChar: Char;
  end;

implementation

procedure HexToDouble(const s: string; var n: Double; var code: Integer); forward;

constructor TLexer.Create(AL: TLua; const ASource: RawByteString);
begin
  L := AL;
  Source := ASource;
  Len := Length(ASource);
  Pos := 1;
  Line := 1;
  HasPeek := False;
  CurCh := #0;
  if Len > 0 then
    CurCh := ASource[1];
  // skip UTF-8 BOM
  if (Len >= 3) and (ASource[1] = #$EF) and (ASource[2] = #$BB) and (ASource[3] = #$BF) then
  begin
    Pos := 4;
    if Pos <= Len then CurCh := ASource[Pos] else CurCh := #0;
  end;
  // skip first line if it starts with '#'
  if (Pos <= Len) and (ASource[Pos] = '#') then
  begin
    while (Pos <= Len) and (ASource[Pos] <> #10) do
      Inc(Pos);
    Inc(Pos); // skip newline
    if Pos > Len then Pos := Len + 1;
    Line := 2;
    if Pos <= Len then CurCh := ASource[Pos] else CurCh := #0;
  end;
  StrVal := nil;
  IntVal := 0;
  FltVal := 0;
  NameVal := '';
  Next;
end;

procedure TLexer.Advance;
begin
  Inc(Pos);
  if Pos <= Len then
    CurCh := Source[Pos]
  else
    CurCh := #0;
end;

function TLexer.ChAt(off: Integer): Char;
var
  p: Integer;
begin
  // ChAt(0) is the character after CurCh
  p := Pos + off + 1;
  if (p >= 1) and (p <= Len) then
    Result := Source[p]
  else
    Result := #0;
end;

procedure TLexer.Error(const msg: string);
begin
  raise ELuaError.CreateMsg(Format('%s:%d: %s', ['?', Line, msg]));
end;

function TLexer.TokenName(t: TTokenKind): string;
begin
  Result := '';
  case t of
    tkEof: Result := '<eof>';
    tkName: Result := '<name>';
    tkInt, tkFlt: Result := '<number>';
    tkString: Result := '<string>';
    tkAnd: Result := 'and';
    tkBreak: Result := 'break';
    tkDo: Result := 'do';
    tkElse: Result := 'else';
    tkElseIf: Result := 'elseif';
    tkEnd: Result := 'end';
    tkFalse: Result := 'false';
    tkFor: Result := 'for';
    tkFunction: Result := 'function';
    tkGlobal: Result := 'global';
    tkGoto: Result := 'goto';
    tkIf: Result := 'if';
    tkIn: Result := 'in';
    tkLocal: Result := 'local';
    tkNil: Result := 'nil';
    tkNot: Result := 'not';
    tkOr: Result := 'or';
    tkRepeat: Result := 'repeat';
    tkReturn: Result := 'return';
    tkThen: Result := 'then';
    tkTrue: Result := 'true';
    tkUntil: Result := 'until';
    tkWhile: Result := 'while';
    tkPlus: Result := '+';
    tkMinus: Result := '-';
    tkStar: Result := '*';
    tkSlash: Result := '/';
    tkDblSlash: Result := '//';
    tkPercent: Result := '%';
    tkCaret: Result := '^';
    tkHash: Result := '#';
    tkAmp: Result := '&';
    tkTilde: Result := '~';
    tkPipe: Result := '|';
    tkShl: Result := '<<';
    tkShr: Result := '>>';
    tkConcat: Result := '..';
    tkDots: Result := '...';
    tkEq: Result := '==';
    tkNe: Result := '~=';
    tkLe: Result := '<=';
    tkGe: Result := '>=';
    tkLt: Result := '<';
    tkGt: Result := '>';
    tkAssign: Result := '=';
    tkLParen: Result := '(';
    tkRParen: Result := ')';
    tkLBrace: Result := '{';
    tkRBrace: Result := '}';
    tkLBracket: Result := '[';
    tkRBracket: Result := ']';
    tkDblColon: Result := '::';
    tkSemi: Result := ';';
    tkColon: Result := ':';
    tkComma: Result := ',';
    tkDot: Result := '.';
  end;
end;

procedure TLexer.SkipSpace;
var
  sep: string;
  level: Integer;
  c: Char;
begin
  while True do
  begin
    c := CurCh;
    if (c = ' ') or (c = #9) or (c = #10) or (c = #13) or (c = #12) or (c = #11) then
    begin
      if c = #10 then Inc(Line);
      Advance;
    end
    else if c = '-' then
    begin
      if ChAt(0) = '-' then
      begin
        Advance; Advance;   // skip --
        // check long comment
        if CurCh = '[' then
        begin
          sep := '[';
          Advance;
          while CurCh = '=' do
          begin
            sep := sep + '=';
            Advance;
          end;
          if CurCh = '[' then
          begin
            sep := sep + '[';
            Advance;
            ReadLongString(Length(sep)-2, True);
            continue;
          end;
        end;
        // short comment
        while (CurCh <> #10) and (CurCh <> #13) and (CurCh <> #0) do
          Advance;
      end
      else
        Exit;
    end
    else
      Exit;
  end;
end;

procedure TLexer.ReadLongString(nEq: Integer; isComment: Boolean);
var
  buf: RawByteString;
  i, j: Integer;
  matched: Boolean;
begin
  buf := '';
  while CurCh <> #0 do
  begin
    if CurCh = #10 then Inc(Line);
    if CurCh = ']' then
    begin
      j := 0;
      while ChAt(j) = '=' do Inc(j);
      if (j = nEq) and (ChAt(j) = ']') then
      begin
        Advance;                      // skip ]
        for i := 1 to nEq do Advance; // skip =
        Advance;                      // skip ]
        if not isComment then
          StrVal := L.NewString(buf);
        Exit;
      end;
    end;
    if not isComment then
      buf := buf + CurCh;
    Advance;
  end;
  Error('unfinished long string');
end;

function TLexer.ReadEscapedChar: Char;
var
  c: Char;
  digits: Integer;
  v: Integer;
  hex: Integer;
  s: string;
  uval: Integer;
  cnt: Integer;
begin
  Advance; // skip backslash
  c := CurCh;
  case c of
    'a': begin Result := #7; Advance; end;
    'b': begin Result := #8; Advance; end;
    'f': begin Result := #12; Advance; end;
    'n': begin Result := #10; Advance; end;
    'r': begin Result := #13; Advance; end;
    't': begin Result := #9; Advance; end;
    'v': begin Result := #11; Advance; end;
    '\': begin Result := '\'; Advance; end;
    '"': begin Result := '"'; Advance; end;
    '''': begin Result := ''''; Advance; end;
    #10: begin Result := #10; Inc(Line); Advance; end;
    #13: begin
      Result := #10;
      if ChAt(0) = #10 then Advance;
      Inc(Line);
      Advance;
    end;
    'x': begin
      Advance;
      v := 0;
      digits := 0;
      while digits < 2 do
      begin
        c := CurCh;
        if (c >= '0') and (c <= '9') then hex := Ord(c) - Ord('0')
        else if (c >= 'a') and (c <= 'f') then hex := Ord(c) - Ord('a') + 10
        else if (c >= 'A') and (c <= 'F') then hex := Ord(c) - Ord('A') + 10
        else Break;
        v := v * 16 + hex;
        Inc(digits);
        Advance;
      end;
      if digits = 0 then Error('hexadecimal digit expected');
      Result := Chr(v);
    end;
    'u': begin
      if ChAt(0) <> '{' then
        Error('missing ''{'' in \u{xxxx}');
      Advance; Advance; // skip u{
      s := '';
      while (CurCh <> '}') and (CurCh <> #0) do
      begin
        s := s + CurCh;
        Advance;
      end;
      if CurCh = '}' then
        Advance
      else
        Error('missing ''}'' in \u{xxxx}');
      Val('$' + s, uval, cnt);
      if cnt <> 0 then
        Error('invalid \u{xxxx} sequence');
      Result := Chr(uval and $FF);
    end;
    'z': begin
      Advance;
      while (CurCh = ' ') or (CurCh = #9) or (CurCh = #10) or (CurCh = #13) do
      begin
        if CurCh = #10 then Inc(Line);
        Advance;
      end;
      Result := #0; // caller must skip
      Exit;
    end;
  else
    if (c >= '0') and (c <= '9') then
    begin
      v := 0;
      digits := 0;
      while (digits < 3) and (CurCh >= '0') and (CurCh <= '9') do
      begin
        v := v * 10 + Ord(CurCh) - Ord('0');
        Inc(digits);
        Advance;
      end;
      if v > 255 then
        Error('decimal escape too large');
      Result := Chr(v);
    end
    else
    begin
      Result := CurCh;
      Advance;
    end;
  end;
end;

function TLexer.ReadString: TTokenKind;
var
  quote: Char;
  buf: RawByteString;
  c: Char;
  uval: Integer;
  s: string;
  cnt: Integer;
begin
  quote := CurCh;
  Advance; // skip quote
  buf := '';
  while True do
  begin
    c := CurCh;
    if c = #0 then
      Error('unfinished string');
    if c = quote then
    begin
      Advance;
      Break;
    end;
    if c = #10 then
      Error('unfinished string');
    if c = '\' then
    begin
      // handle \u{...} specially (multi-byte)
      if ChAt(0) = 'u' then
      begin
        Advance; Advance;
        if CurCh <> '{' then Error('missing ''{'' in \u{xxxx}');
        Advance;
        s := '';
        while (CurCh <> '}') and (CurCh <> #0) do
        begin
          s := s + CurCh;
          Advance;
        end;
        if CurCh = '}' then Advance else Error('missing ''}'' in \u{xxxx}');
        Val('$' + s, uval, cnt);
        if cnt <> 0 then Error('invalid \u{xxxx} sequence');
        // encode UTF-8
        if uval < $80 then
          buf := buf + Chr(uval)
        else if uval < $800 then
          buf := buf + Chr($C0 or (uval shr 6)) + Chr($80 or (uval and $3F))
        else if uval < $10000 then
          buf := buf + Chr($E0 or (uval shr 12)) + Chr($80 or ((uval shr 6) and $3F)) +
                Chr($80 or (uval and $3F))
        else
          buf := buf + Chr($F0 or (uval shr 18)) + Chr($80 or ((uval shr 12) and $3F)) +
                Chr($80 or ((uval shr 6) and $3F)) + Chr($80 or (uval and $3F));
      end
      else
      begin
        c := ReadEscapedChar;
        if c <> #0 then
          buf := buf + c;
      end;
    end
    else
    begin
      buf := buf + c;
      Advance;
    end;
  end;
  StrVal := L.NewString(buf);
  Result := tkString;
end;

function TLexer.ReadName: TTokenKind;
var
  buf: string;
  c: Char;
begin
  buf := '';
  while True do
  begin
    c := CurCh;
    if ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
       ((c >= '0') and (c <= '9')) or (c = '_') then
    begin
      buf := buf + c;
      Advance;
    end
    else
      Break;
  end;
  NameVal := buf;
  if buf = 'and' then Result := tkAnd
  else if buf = 'break' then Result := tkBreak
  else if buf = 'do' then Result := tkDo
  else if buf = 'else' then Result := tkElse
  else if buf = 'elseif' then Result := tkElseIf
  else if buf = 'end' then Result := tkEnd
  else if buf = 'false' then Result := tkFalse
  else if buf = 'for' then Result := tkFor
  else if buf = 'function' then Result := tkFunction
  else if buf = 'global' then Result := tkGlobal
  else if buf = 'goto' then Result := tkGoto
  else if buf = 'if' then Result := tkIf
  else if buf = 'in' then Result := tkIn
  else if buf = 'local' then Result := tkLocal
  else if buf = 'nil' then Result := tkNil
  else if buf = 'not' then Result := tkNot
  else if buf = 'or' then Result := tkOr
  else if buf = 'repeat' then Result := tkRepeat
  else if buf = 'return' then Result := tkReturn
  else if buf = 'then' then Result := tkThen
  else if buf = 'true' then Result := tkTrue
  else if buf = 'until' then Result := tkUntil
  else if buf = 'while' then Result := tkWhile
  else
    Result := tkName;
end;

function TLexer.ReadNumber: TTokenKind;
var
  buf: string;
  isHex, isFlt: Boolean;
  c: Char;
  uv: QWord;
  iv: Int64;
  fv: Double;
  code: Integer;
begin
  buf := '';
  isHex := False;
  isFlt := False;
  // hex prefix
  if (CurCh = '0') and ((ChAt(0) = 'x') or (ChAt(0) = 'X')) then
  begin
    isHex := True;
    buf := '0x';
    Advance; Advance;
    while ((CurCh >= '0') and (CurCh <= '9')) or
          ((CurCh >= 'a') and (CurCh <= 'f')) or
          ((CurCh >= 'A') and (CurCh <= 'F')) or (CurCh = '.') do
    begin
      if CurCh = '.' then isFlt := True;
      buf := buf + CurCh;
      Advance;
    end;
    // binary exponent
    if (CurCh = 'p') or (CurCh = 'P') then
    begin
      isFlt := True;
      buf := buf + 'p';
      Advance;
      if (CurCh = '+') or (CurCh = '-') then
      begin
        buf := buf + CurCh;
        Advance;
      end;
      while (CurCh >= '0') and (CurCh <= '9') do
      begin
        buf := buf + CurCh;
        Advance;
      end;
    end;
  end
  else
  begin
    while (CurCh >= '0') and (CurCh <= '9') do
    begin
      buf := buf + CurCh;
      Advance;
    end;
    if CurCh = '.' then
    begin
      isFlt := True;
      buf := buf + '.';
      Advance;
      while (CurCh >= '0') and (CurCh <= '9') do
      begin
        buf := buf + CurCh;
        Advance;
      end;
    end;
    if (CurCh = 'e') or (CurCh = 'E') then
    begin
      isFlt := True;
      buf := buf + 'e';
      Advance;
      if (CurCh = '+') or (CurCh = '-') then
      begin
        buf := buf + CurCh;
        Advance;
      end;
      while (CurCh >= '0') and (CurCh <= '9') do
      begin
        buf := buf + CurCh;
        Advance;
      end;
    end;
  end;
  if isHex and not isFlt then
  begin
    // hex integer, wrap to 64 bits
    uv := 0;
    for c in buf do
    begin
      if c in ['0'..'9'] then uv := uv * 16 + QWord(Ord(c) - Ord('0'))
      else if c in ['a'..'f'] then uv := uv * 16 + QWord(Ord(c) - Ord('a') + 10)
      else if c in ['A'..'F'] then uv := uv * 16 + QWord(Ord(c) - Ord('A') + 10);
    end;
    IntVal := Int64(uv);
    Result := tkInt;
  end
  else if not isFlt then
  begin
    Val(buf, iv, code);
    if code = 0 then
    begin
      IntVal := iv;
      Result := tkInt;
    end
    else
    begin
      // too large for Int64; parse as float
      Val(buf, fv, code);
      FltVal := fv;
      Result := tkFlt;
    end;
  end
  else
  begin
    if isHex then
    begin
      // convert hex float manually
      // format: 0xH.HHHpEE
      fv := 0;
      // simple parser
      HexToDouble(buf, fv, code);
      FltVal := fv;
    end
    else
    begin
      Val(buf, fv, code);
      FltVal := fv;
    end;
    Result := tkFlt;
  end;
end;

procedure TLexer.Next;
var
  c: Char;
  buf: RawByteString;
  i: Integer;
  sep: string;
begin
  if HasPeek then
  begin
    Tok := PeekTok;
    StrVal := PeekStr;
    IntVal := PeekInt;
    FltVal := PeekFlt;
    NameVal := PeekName;
    HasPeek := False;
    Exit;
  end;
  SkipSpace;
  c := CurCh;
  if c = #0 then
  begin
    Tok := tkEof;
    Exit;
  end;
  // long strings
  if c = '[' then
  begin
    sep := '[';
    Advance;
    while CurCh = '=' do
    begin
      sep := sep + '=';
      Advance;
    end;
    if CurCh = '[' then
    begin
      sep := sep + '[';
      Advance;
      ReadLongString(Length(sep)-2, False);
      Tok := tkString;
      Exit;
    end;
    Tok := tkLBracket;
    Exit;
  end;
  if (c >= '0') and (c <= '9') then
  begin
    Tok := ReadNumber;
    Exit;
  end;
  if ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or (c = '_') then
  begin
    Tok := ReadName;
    Exit;
  end;
  if (c = '"') or (c = '''') then
  begin
    Tok := ReadString;
    Exit;
  end;
  case c of
    '+': Tok := tkPlus;
    '-': Tok := tkMinus;
    '*': Tok := tkStar;
    '/': begin
      if ChAt(0) = '/' then
      begin
        Advance;
        Tok := tkDblSlash;
      end
      else
        Tok := tkSlash;
    end;
    '%': Tok := tkPercent;
    '^': Tok := tkCaret;
    '#': Tok := tkHash;
    '(': Tok := tkLParen;
    ')': Tok := tkRParen;
    '{': Tok := tkLBrace;
    '}': Tok := tkRBrace;
    ']': Tok := tkRBracket;
    ';': Tok := tkSemi;
    ',': Tok := tkComma;
    '&': Tok := tkAmp;
    '|': Tok := tkPipe;
    '~': begin
      if ChAt(0) = '=' then
      begin
        Advance;
        Tok := tkNe;
      end
      else
        Tok := tkTilde;
    end;
    '=': begin
      if ChAt(0) = '=' then
      begin
        Advance;
        Tok := tkEq;
      end
      else
        Tok := tkAssign;
    end;
    '<': begin
      if ChAt(0) = '=' then
      begin
        Advance;
        Tok := tkLe;
      end
      else if ChAt(0) = '<' then
      begin
        Advance;
        Tok := tkShl;
      end
      else
        Tok := tkLt;
    end;
    '>': begin
      if ChAt(0) = '=' then
      begin
        Advance;
        Tok := tkGe;
      end
      else if ChAt(0) = '>' then
      begin
        Advance;
        Tok := tkShr;
      end
      else
        Tok := tkGt;
    end;
    '.': begin
      if ChAt(0) = '.' then
      begin
        Advance;
        if ChAt(0) = '.' then
        begin
          Advance;
          Tok := tkDots;
        end
        else
          Tok := tkConcat;
      end
      else
        Tok := tkDot;
    end;
    ':': begin
      if ChAt(0) = ':' then
      begin
        Advance;
        Tok := tkDblColon;
      end
      else
        Tok := tkColon;
    end;
  else
    Error('unexpected symbol near ''' + c + '''');
  end;
  Advance;
end;

function TLexer.Peek: TTokenKind;
begin
  Result := Tok;
end;

// Parse a hexadecimal float string like "0x1.8p1"
procedure HexToDouble(const s: string; var n: Double; var code: Integer);
var
  i, p: Integer;
  negExp: Boolean;
  exp: Integer;
  mant: Double;
  c: Char;
  dig: Integer;
  fracPos: Integer;
  scale: Double;
begin
  code := 0;
  n := 0;
  // skip 0x
  i := 3;
  mant := 0;
  fracPos := -1;
  while i <= Length(s) do
  begin
    c := s[i];
    if c = '.' then
    begin
      fracPos := i;
      Inc(i);
      continue;
    end;
    if (c = 'p') or (c = 'P') then
      Break;
    if (c >= '0') and (c <= '9') then dig := Ord(c) - Ord('0')
    else if (c >= 'a') and (c <= 'f') then dig := Ord(c) - Ord('a') + 10
    else if (c >= 'A') and (c <= 'F') then dig := Ord(c) - Ord('A') + 10
    else
    begin
      code := 1;
      Exit;
    end;
    mant := mant * 16 + dig;
    Inc(i);
  end;
  if fracPos >= 0 then
  begin
    scale := 1.0 / 16.0;
    for p := fracPos + 1 to i - 1 do
    begin
      c := s[p];
      if (c >= '0') and (c <= '9') then dig := Ord(c) - Ord('0')
      else if (c >= 'a') and (c <= 'f') then dig := Ord(c) - Ord('a') + 10
      else dig := Ord(c) - Ord('A') + 10;
      mant := mant + dig * scale;
      scale := scale / 16.0;
    end;
  end;
  exp := 0;
  if i <= Length(s) then
  begin
    Inc(i); // skip p
    negExp := False;
    if (i <= Length(s)) and ((s[i] = '+') or (s[i] = '-')) then
    begin
      negExp := s[i] = '-';
      Inc(i);
    end;
    while i <= Length(s) do
    begin
      exp := exp * 10 + Ord(s[i]) - Ord('0');
      Inc(i);
    end;
    if negExp then exp := -exp;
  end;
  n := mant * Power(2.0, exp);
end;

end.
