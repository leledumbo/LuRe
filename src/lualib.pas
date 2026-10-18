unit lualib;

{$mode objfpc}{$H+}

// Opens the standard libraries.

interface

uses
  luacore;

procedure OpenLibs(L: TLua);

implementation

uses
  lualibbase, lualibpkg, lualibco, lualibtab, lualibio, lualibos, lualibstr,
  lualibmath, lualibutf8, lualibdbg;

procedure OpenLibs(L: TLua);
begin
  OpenBase(L);
  OpenPackage(L);
  OpenCoroutine(L);
  OpenTable(L);
  OpenIO(L);
  OpenOS(L);
  OpenString(L);
  OpenMath(L);
  OpenUtf8(L);
  OpenDebug(L);
end;

end.
