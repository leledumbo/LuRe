unit luaparse;

{$mode objfpc}{$H+}

// Facade of the compiler pipeline:
//   source text -> luaparser (syntax tree) -> luagen (prototypes)
// plus binary chunks (luadump).

interface

uses
  luacore;

// Compiles a source chunk. The first upvalue of the result (_ENV) is left
// unset: the caller must assign it.
function LuaCompile(L: TLua; const source: RawByteString; const name: string): TFunction;
function LuaDump(L: TLua; f: TFunction; strip: Boolean): RawByteString;
function LuaUndump(L: TLua; const data: RawByteString; const name: string): TFunction;

implementation

uses
  SysUtils, Contnrs, luaast, luaparser, luagen, luabinary;

function LuaCompile(L: TLua; const source: RawByteString; const name: string): TFunction;
var
  decl: TFuncDecl;
  owner: TAstOwner;
  p: TProto;
begin
  decl := ParseChunk(L, source, name, owner);
  try
    p := GenerateProto(L, decl, ChunkIdStr(name), L.NewString(RawByteString(name)));
  finally
    owner.Free;
  end;
  Result := L.NewLuaFunction(p);
end;

function LuaDump(L: TLua; f: TFunction; strip: Boolean): RawByteString;
begin
  Result := DumpFunction(L, f, strip);
end;

function LuaUndump(L: TLua; const data: RawByteString; const name: string): TFunction;
begin
  Result := UndumpFunction(L, data, name);
end;

end.
