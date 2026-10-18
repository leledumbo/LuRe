program frontbench;

{$mode objfpc}{$H+}

// Times the phases of the front end on one source file: lexing only, lexing and
// parsing (AST), and the complete compilation.
//   frontbench file.lua [repetitions]

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, Classes, Contnrs, luacore, lualex, luaast, luaparser, luagen, luaparse;

var
  L: TLua;
  src: RawByteString;
  fs: TFileStream;
  reps, i: Integer;
  t0: QWord;
  lex: TLexer;
  owner: TAstOwner;
  decl: TFuncDecl;
  ntok: Int64;
begin
  fs := TFileStream.Create(ParamStr(1), fmOpenRead);
  SetLength(src, fs.Size);
  fs.ReadBuffer(src[1], fs.Size);
  fs.Free;
  if ParamCount > 1 then reps := StrToInt(ParamStr(2)) else reps := 25;
  L := TLua.CreateMain;

  ntok := 0;
  t0 := GetTickCount64;
  for i := 1 to reps do
  begin
    lex := TLexer.Create(L, src, '=bench');
    lex.Next;
    while lex.Tok <> tkEof do
    begin
      Inc(ntok);
      lex.Next;
    end;
    lex.Free;
  end;
  WriteLn('lex only      ', (GetTickCount64 - t0) / 1000.0:0:3, 's  (', ntok div reps, ' tokens)');

  t0 := GetTickCount64;
  for i := 1 to reps do
  begin
    decl := ParseChunk(L, src, '=bench', owner);
    owner.Free;
  end;
  WriteLn('lex + parse   ', (GetTickCount64 - t0) / 1000.0:0:3, 's');

  t0 := GetTickCount64;
  for i := 1 to reps do
    LuaCompile(L, src, '=bench');
  WriteLn('full compile  ', (GetTickCount64 - t0) / 1000.0:0:3, 's');
end.
