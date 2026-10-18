unit lualibp;

{$mode objfpc}{$H+}

// Standard libraries of the Lua C API: the same interface as the 'lualib' unit of the
// Free Pascal Lua bindings, implemented on top of the 'luap' unit.

interface

uses
  luap;

const
  LUA_COLIBNAME = 'coroutine';
  LUA_TABLIBNAME = 'table';
  LUA_IOLIBNAME = 'io';
  LUA_OSLIBNAME = 'os';
  LUA_STRLINAME = 'string';
  LUA_MATHLIBNAME = 'math';
  LUA_DBLIBNAME = 'debug';
  LUA_LOADLIBNAME = 'package';

function luaopen_base(L: Plua_State): LongBool; cdecl;
function luaopen_table(L: Plua_State): LongBool; cdecl;
function luaopen_io(L: Plua_State): LongBool; cdecl;
function luaopen_string(L: Plua_State): LongBool; cdecl;
function luaopen_math(L: Plua_State): LongBool; cdecl;
function luaopen_debug(L: Plua_State): LongBool; cdecl;
function luaopen_package(L: Plua_State): LongBool; cdecl;

(* open all previous libraries *)
procedure luaL_openlibs(L: Plua_State); cdecl;

(* compatibility code *)

function lua_baselibopen(L: Plua_State): LongBool;
function lua_tablibopen(L: Plua_State): LongBool;
function lua_iolibopen(L: Plua_State): LongBool;
function lua_strlibopen(L: Plua_State): LongBool;
function lua_mathlibopen(L: Plua_State): LongBool;
function lua_dblibopen(L: Plua_State): LongBool;

implementation

uses
  luacore, lualib, lualibbase, lualibpkg, lualibtab, lualibio, lualibos, lualibstr,
  lualibmath, lualibco, lualibdbg, lualibutf8;

// the libraries register themselves (global and package.loaded); like the real ones these
// functions leave the library table on the stack
function Finish(L: Plua_State; const name: PAnsiChar): LongBool;
begin
  if name = nil then lua_pushvalue(L, LUA_GLOBALSINDEX)
  else lua_getfield(L, LUA_GLOBALSINDEX, name);
  Result := True;
end;

function luaopen_base(L: Plua_State): LongBool; cdecl;
begin
  OpenBase(TLua(L));
  Result := Finish(L, nil);
end;

function luaopen_table(L: Plua_State): LongBool; cdecl;
begin
  OpenTable(TLua(L));
  Result := Finish(L, LUA_TABLIBNAME);
end;

function luaopen_io(L: Plua_State): LongBool; cdecl;
begin
  OpenIO(TLua(L));
  Result := Finish(L, LUA_IOLIBNAME);
end;

function luaopen_string(L: Plua_State): LongBool; cdecl;
begin
  OpenString(TLua(L));
  Result := Finish(L, LUA_STRLINAME);
end;

function luaopen_math(L: Plua_State): LongBool; cdecl;
begin
  OpenMath(TLua(L));
  Result := Finish(L, LUA_MATHLIBNAME);
end;

function luaopen_debug(L: Plua_State): LongBool; cdecl;
begin
  OpenDebug(TLua(L));
  Result := Finish(L, LUA_DBLIBNAME);
end;

function luaopen_package(L: Plua_State): LongBool; cdecl;
begin
  OpenPackage(TLua(L));
  Result := Finish(L, LUA_LOADLIBNAME);
end;

procedure luaL_openlibs(L: Plua_State); cdecl;
begin
  // also opens coroutine and utf8, which the 5.1 list does not know
  OpenLibs(TLua(L));
end;

function lua_baselibopen(L: Plua_State): LongBool;
begin
  Result := luaopen_base(L);
end;

function lua_tablibopen(L: Plua_State): LongBool;
begin
  Result := luaopen_table(L);
end;

function lua_iolibopen(L: Plua_State): LongBool;
begin
  Result := luaopen_io(L);
end;

function lua_strlibopen(L: Plua_State): LongBool;
begin
  Result := luaopen_string(L);
end;

function lua_mathlibopen(L: Plua_State): LongBool;
begin
  Result := luaopen_math(L);
end;

function lua_dblibopen(L: Plua_State): LongBool;
begin
  Result := luaopen_debug(L);
end;

end.
