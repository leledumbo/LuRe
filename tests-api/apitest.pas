program apitest;

{$mode objfpc}{$H+}

// Exercises the Lua C API units luap/lauxlibp/lualibp the way an application using the
// official FPC bindings would do. Prints "ALL OK" when everything behaves.

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, luap, lauxlibp, lualibp;

var
  Fails: Integer = 0;
  HookLines: Integer = 0;
  Freed: Integer = 0;

procedure Check(cond: Boolean; const what: string);
begin
  if not cond then
  begin
    Inc(Fails);
    WriteLn('FAIL: ', what);
  end;
end;

function l_add(L: Plua_State): Integer; cdecl;
begin
  lua_pushnumber(L, luaL_checknumber(L, 1) + luaL_checknumber(L, 2));
  Result := 1;
end;

function l_fail(L: Plua_State): Integer; cdecl;
begin
  Result := luaL_error(L, 'boom %d %s %f', [42, 'str', 1.5]);
end;

function l_counter(L: Plua_State): Integer; cdecl;
var
  n: lua_Integer;
begin
  n := lua_tointeger(L, lua_upvalueindex(1)) + 1;
  lua_pushinteger(L, n);
  lua_pushvalue(L, -1);
  lua_replace(L, lua_upvalueindex(1));
  Result := 1;
end;

function l_yielder(L: Plua_State): Integer; cdecl;
begin
  lua_pushinteger(L, 7);
  Result := lua_yield(L, 1);
end;

function l_point_new(L: Plua_State): Integer; cdecl;
var
  p: PDouble;
begin
  p := lua_newuserdata(L, 2 * SizeOf(Double));
  p[0] := luaL_checknumber(L, 1);
  p[1] := luaL_checknumber(L, 2);
  lua_Lgetmetatable(L, 'Point');
  lua_setmetatable(L, -2);
  Result := 1;
end;

function l_point_x(L: Plua_State): Integer; cdecl;
var
  p: PDouble;
begin
  p := luaL_checkudata(L, 1, 'Point');
  lua_pushnumber(L, p[0]);
  Result := 1;
end;


function l_cpcall(L: Plua_State): Integer; cdecl;
begin
  lua_pushstring(L, 'from cpcall');
  lua_setglobal(L, 'cpmark');
  Result := 0;
end;

function Reader(L: Plua_State; ud: Pointer; sz: Psize_t): PAnsiChar; cdecl;
const
  Parts: array[0..2] of PAnsiChar = ('return ', '1 + ', '2');
begin
  if PInteger(ud)^ > 2 then Exit(nil);
  Result := Parts[PInteger(ud)^];
  sz^ := StrLen(Result);
  Inc(PInteger(ud)^);
end;

var
  DumpedLen: Integer = 0;

function Writer(L: Plua_State; const p: Pointer; sz: size_t; ud: Pointer): Integer; cdecl;
begin
  Inc(DumpedLen, sz);
  Result := 0;
end;

procedure Hook(L: Plua_State; ar: Plua_Debug); cdecl;
begin
  if ar^.event = LUA_HOOKLINE then Inc(HookLines);
end;

var
  L, co: Plua_State;
  reg: array[0..2] of luaL_reg;
  ar: lua_Debug;
  b: luaL_Buffer;
  rd, ref1, ref2, st, i, n: Integer;
  s: PAnsiChar;
  len: size_t;
begin
  L := luaL_newstate;
  Check(L <> nil, 'newstate');
  luaL_openlibs(L);
  Check(lua_gettop(L) = 0, 'empty stack after openlibs');

  // stack basics
  lua_pushinteger(L, 10); lua_pushstring(L, 'abc'); lua_pushboolean(L, True); lua_pushnil(L);
  Check(lua_gettop(L) = 4, 'gettop');
  Check(lua_type(L, 1) = LUA_TNUMBER, 'type number');
  Check(lua_type(L, 2) = LUA_TSTRING, 'type string');
  Check(lua_type(L, 3) = LUA_TBOOLEAN, 'type boolean');
  Check(lua_isnil(L, 4), 'type nil');
  Check(lua_isnone(L, 5), 'none');
  Check(lua_tointeger(L, 1) = 10, 'tointeger');
  Check(lua_objlen(L, 2) = 3, 'objlen');
  lua_insert(L, 1);
  Check(lua_isnil(L, 1), 'insert');
  lua_remove(L, 1);
  Check((lua_gettop(L) = 3) and lua_toboolean(L, 3), 'remove');
  lua_settop(L, 0);

  // numbers as strings
  lua_pushnumber(L, 3.5);
  s := lua_tolstring(L, 1, @len);
  Check((s <> nil) and (StrComp(s, '3.5') = 0) and (len = 3), 'number to string');
  lua_settop(L, 0);

  // C function, globals, calls
  lua_register(L, 'add', @l_add);
  lua_getglobal(L, 'add');
  lua_pushinteger(L, 2); lua_pushinteger(L, 40);
  lua_call(L, 2, 1);
  Check(lua_tonumber(L, -1) = 42, 'call add');
  lua_settop(L, 0);

  // dostring and results
  Check(lua_dostring(L, 'x = add(1, 2); return x, "s"') = 0, 'dostring');
  Check((lua_gettop(L) = 2) and (lua_tonumber(L, 1) = 3), 'dostring results');
  lua_settop(L, 0);

  // errors
  lua_pushcfunction(L, @l_fail);
  st := lua_pcall(L, 0, 0, 0);
  Check(st = LUA_ERRRUN, 'pcall status');
  s := lua_tostring(L, -1);
  Check((s <> nil) and (Pos('boom 42 str 1.5', s) > 0), 'error message with luaL_error');
  lua_settop(L, 0);
  st := lua_dostring(L, 'error("plain")');
  Check(st = LUA_ERRRUN, 'error status');
  Check(Pos('plain', lua_tostring(L, -1)) > 0, 'error text');
  lua_settop(L, 0);
  st := luaL_loadstring(L, 'x = = 1');
  Check(st = LUA_ERRSYNTAX, 'syntax error status');
  lua_settop(L, 0);
  st := lua_dostring(L, 'add({}, 1)');
  Check(Pos('bad argument #1 to ''add''', lua_tostring(L, -1)) > 0, 'argerror: ' + lua_tostring(L, -1));
  lua_settop(L, 0);

  // upvalues
  lua_pushinteger(L, 0);
  lua_pushcclosure(L, @l_counter, 1);
  lua_pushvalue(L, -1);
  lua_call(L, 0, 1);
  lua_pop(L, 1);
  lua_call(L, 0, 1);
  Check(lua_tointeger(L, -1) = 2, 'closure upvalue');
  lua_settop(L, 0);

  // tables
  lua_newtable(L);
  lua_pushstring(L, 'v'); lua_setfield(L, 1, 'k');
  lua_pushinteger(L, 5); lua_rawseti(L, 1, 1);
  lua_getfield(L, 1, 'k');
  Check(StrComp(lua_tostring(L, -1), 'v') = 0, 'setfield/getfield');
  lua_pop(L, 1);
  lua_rawgeti(L, 1, 1);
  Check(lua_tointeger(L, -1) = 5, 'rawgeti');
  lua_pop(L, 1);
  n := 0;
  lua_pushnil(L);
  while lua_next(L, 1) <> 0 do begin Inc(n); lua_pop(L, 1); end;
  Check(n = 2, 'next');
  Check(lua_objlen(L, 1) = 1, 'table objlen');
  lua_settop(L, 0);

  // userdata with metatable
  luaL_newmetatable(L, 'Point');
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, '__index');
  lua_pushcfunction(L, @l_point_x);
  lua_setfield(L, -2, 'x');
  lua_pop(L, 1);
  lua_register(L, 'point', @l_point_new);
  lua_settop(L, 0);
  Check(lua_dostring(L, 'return point(3, 4):x()') = 0, 'userdata method');
  Check(lua_tonumber(L, -1) = 3, 'userdata result');
  lua_settop(L, 0);
  st := lua_dostring(L, 'return point(1,2).x(42)');
  Check(Pos('Point expected, got number', lua_tostring(L, -1)) > 0, 'checkudata error: ' + lua_tostring(L, -1));
  lua_settop(L, 0);

  // registers
  reg[0].name := 'add'; reg[0].func := @l_add;
  reg[1].name := 'counter'; reg[1].func := @l_counter;
  reg[2].name := nil; reg[2].func := nil;
  luaL_register(L, 'mylib', @reg[0]);
  Check(lua_istable(L, -1), 'register pushes table');
  lua_settop(L, 0);
  Check(lua_dostring(L, 'return mylib.add(3, 4) + (package.loaded.mylib == mylib and 1 or 0)') = 0, 'mylib call');
  Check(lua_tonumber(L, -1) = 8, 'mylib result');
  lua_settop(L, 0);

  // refs
  lua_pushstring(L, 'one'); ref1 := luaL_ref(L, LUA_REGISTRYINDEX);
  lua_pushstring(L, 'two'); ref2 := luaL_ref(L, LUA_REGISTRYINDEX);
  Check(ref1 <> ref2, 'distinct refs');
  lua_getref(L, ref1);
  Check(StrComp(lua_tostring(L, -1), 'one') = 0, 'getref');
  lua_pop(L, 1);
  lua_unref(L, ref1);
  lua_pushstring(L, 'three'); i := luaL_ref(L, LUA_REGISTRYINDEX);
  Check(i = ref1, 'ref reuse');
  lua_settop(L, 0);

  // buffers
  luaL_buffinit(L, @b);
  for i := 1 to 3000 do luaL_addchar(@b, 'a');
  luaL_addstring(@b, 'xyz');
  lua_pushstring(L, 'VALUE');
  luaL_addvalue(@b);
  for i := 1 to 5000 do luaL_addchar(@b, 'b');
  luaL_pushresult(@b);
  Check(lua_objlen(L, -1) = 3000 + 3 + 5 + 5000, 'buffer length');
  Check(lua_gettop(L) = 1, 'buffer leaves one value');
  lua_settop(L, 0);

  // load with reader, dump
  rd := 0;
  Check(lua_load(L, @Reader, @rd, 'reader') = 0, 'lua_load');
  lua_call(L, 0, 1);
  Check(lua_tonumber(L, -1) = 3, 'loaded chunk');
  lua_settop(L, 0);
  luaL_loadstring(L, 'return 1');
  Check(lua_dump(L, @Writer, nil) = 0, 'dump');
  Check(DumpedLen > 0, 'dump wrote');
  lua_settop(L, 0);

  // cpcall
  Check(lua_cpcall(L, @l_cpcall, nil) = 0, 'cpcall');
  lua_getglobal(L, 'cpmark');
  Check(StrComp(lua_tostring(L, -1), 'from cpcall') = 0, 'cpcall effect');
  lua_settop(L, 0);

  // pushfstring
  s := lua_pushfstring(L, 'n=%d s=%s f=%f c=%c %%', 12, PAnsiChar('hi'), 2.5, Ord('Z'));
  Check(StrComp(s, 'n=12 s=hi f=2.5 c=Z %') = 0, 'pushfstring: ' + s);
  lua_settop(L, 0);

  // coroutines
  co := lua_newthread(L);
  Check(lua_gettop(L) = 1, 'newthread pushes');
  luaL_loadstring(co, 'local a = coroutine.yield(1); return a + 1');
  st := lua_resume(co, 0);
  Check(st = LUA_YIELD_, 'resume yields');
  Check(lua_tonumber(co, -1) = 1, 'yielded value');
  lua_settop(co, 0);
  lua_pushinteger(co, 41);
  st := lua_resume(co, 1);
  Check(st = 0, 'resume finishes');
  Check(lua_tonumber(co, -1) = 42, 'final value');
  lua_settop(L, 0);
  lua_settop(L, 0);
  lua_pushcfunction(L, @l_yielder);
  lua_setglobal(L, 'cyield');
  Check(lua_dostring(L, 'local co = coroutine.wrap(function() return cyield() end); return co()') = 0, 'yield from C');
  Check(lua_tonumber(L, -1) = 7, 'C yield value');
  lua_settop(L, 0);

  // debug
  Check(lua_getstack(L, 0, @ar) = 0, 'no frame at level 0 of the host');
  lua_dostring(L, 'function whoami() return debug.traceback("tb") end');
  lua_settop(L, 0);
  lua_sethook(L, @Hook, LUA_MASKLINE, 0);
  lua_dostring(L, 'local x = 1' + #10 + 'x = x + 1' + #10 + 'x = x + 1');
  lua_sethook(L, nil, 0, 0);
  Check(HookLines >= 3, 'line hook ' + IntToStr(HookLines));
  lua_settop(L, 0);
  lua_getglobal(L, 'whoami');
  lua_getinfo(L, '>Sn', @ar);
  Check(StrComp(ar.what, 'Lua') = 0, 'getinfo what');
  lua_settop(L, 0);

  // gc and metatables with __gc
  Check(lua_gc(L, LUA_GCCOLLECT, 0) = 0, 'gc collect');
  Check(lua_getgccount(L) > 0, 'gccount');

  // environment helpers
  lua_getfenv(L, -1);
  lua_settop(L, 0);
  lua_pushvalue(L, LUA_GLOBALSINDEX);
  Check(lua_istable(L, -1), 'globals index');
  lua_settop(L, 0);

  lua_close(L);
  if Fails = 0 then WriteLn('ALL OK') else begin WriteLn(Fails, ' failures'); Halt(1); end;
end.
