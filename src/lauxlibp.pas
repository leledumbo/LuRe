unit lauxlibp;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// Auxiliary library of the Lua C API: the same interface as the 'lauxlib' unit of the
// Free Pascal Lua bindings, implemented on top of the 'luap' unit (see there for the
// notes and limitations).

interface

uses
  luap;

// functions added for Pascal
procedure lua_pushstring(L: Plua_State; const s: ansistring);

// compatibility macros
function luaL_getn(L: Plua_State; n: Integer): Integer; // calls lua_objlen
procedure luaL_setn(L: Plua_State; t, n: Integer); // does nothing!

type
  luaL_reg = record
    name: PAnsiChar;
    func: lua_CFunction;
  end;
  PluaL_reg = ^luaL_reg;

procedure luaL_openlib(L: Plua_State; const libname: PAnsiChar; const lr: PluaL_reg; nup: Integer); cdecl;
procedure luaL_register(L: Plua_State; const libname: PAnsiChar; const lr: PluaL_reg); cdecl;
function luaL_getmetafield(L: Plua_State; obj: Integer; const e: PAnsiChar): Integer; cdecl;
function luaL_callmeta(L: Plua_State; obj: Integer; const e: PAnsiChar): Integer; cdecl;
function luaL_typerror(L: Plua_State; narg: Integer; const tname: PAnsiChar): Integer; cdecl;
function luaL_argerror(L: Plua_State; numarg: Integer; const extramsg: PAnsiChar): Integer; cdecl;
function luaL_checklstring(L: Plua_State; numArg: Integer; l_: Psize_t): PAnsiChar; cdecl;
function luaL_optlstring(L: Plua_State; numArg: Integer; const def: PAnsiChar; l_: Psize_t): PAnsiChar; cdecl;
function luaL_checknumber(L: Plua_State; numArg: Integer): lua_Number; cdecl;
function luaL_optnumber(L: Plua_State; nArg: Integer; def: lua_Number): lua_Number; cdecl;
function luaL_checkinteger(L: Plua_State; numArg: Integer): lua_Integer; cdecl;
function luaL_optinteger(L: Plua_State; nArg: Integer; def: lua_Integer): lua_Integer; cdecl;

procedure luaL_checkstack(L: Plua_State; sz: Integer; const msg: PAnsiChar); cdecl;
procedure luaL_checktype(L: Plua_State; narg, t: Integer); cdecl;
procedure luaL_checkany(L: Plua_State; narg: Integer); cdecl;

function luaL_newmetatable(L: Plua_State; const tname: PAnsiChar): Integer; cdecl;
function luaL_checkudata(L: Plua_State; ud: Integer; const tname: PAnsiChar): Pointer; cdecl;

procedure luaL_where(L: Plua_State; lvl: Integer); cdecl;
function luaL_error(L: Plua_State; const fmt: PAnsiChar; args: array of const): Integer; cdecl; external name 'luap_error';

function luaL_checkoption(L: Plua_State; narg: Integer; def: PAnsiChar; lst: PPAnsiChar): Integer; cdecl;

function luaL_ref(L: Plua_State; t: Integer): Integer; cdecl;
procedure luaL_unref(L: Plua_State; t, ref: Integer); cdecl;

function luaL_loadfile(L: Plua_State; const filename: PAnsiChar): Integer; cdecl;
function luaL_loadbuffer(L: Plua_State; const buff: PAnsiChar; size: size_t; const name: PAnsiChar): Integer; cdecl;
function luaL_loadstring(L: Plua_State; const s: PAnsiChar): Integer; cdecl;

function luaL_newstate: Plua_State; cdecl;
function lua_open: Plua_State; // compatibility; moved from unit lua to lauxlib because it needs luaL_newstate

function luaL_gsub(L: Plua_State; const s, p, r: PAnsiChar): PAnsiChar; cdecl;
function luaL_findtable(L: Plua_State; idx: Integer; const fname: PAnsiChar; szhint: Integer): PAnsiChar; cdecl;

(*
** ===============================================================
** some useful macros
** ===============================================================
*)

procedure luaL_argcheck(L: Plua_State; cond: Boolean; numarg: Integer; extramsg: PAnsiChar);
function luaL_checkstring(L: Plua_State; n: Integer): PAnsiChar;
function luaL_optstring(L: Plua_State; n: Integer; d: PAnsiChar): PAnsiChar;
function luaL_checkint(L: Plua_State; n: Integer): Integer;
function luaL_checklong(L: Plua_State; n: Integer): LongInt;
function luaL_optint(L: Plua_State; n: Integer; d: Double): Integer;
function luaL_optlong(L: Plua_State; n: Integer; d: Double): LongInt;

function luaL_typename(L: Plua_State; i: Integer): PAnsiChar;

function lua_dofile(L: Plua_State; const filename: PAnsiChar): Integer;
function lua_dostring(L: Plua_State; const str: PAnsiChar): Integer;

procedure lua_Lgetmetatable(L: Plua_State; tname: PAnsiChar);

(*
** =======================================================
** Generic Buffer manipulation
** =======================================================
*)

const
  LUAL_BUFFERSIZE = 4096;

type
  luaL_Buffer = record
    p: PAnsiChar;       (* current position in buffer *)
    lvl: Integer;   (* number of strings in the stack (level) *)
    L: Plua_State;
    buffer: array [0..LUAL_BUFFERSIZE - 1] of AnsiChar;
  end;
  PluaL_Buffer = ^luaL_Buffer;

procedure luaL_addchar(B: PluaL_Buffer; c: AnsiChar);

(* compatibility only (alias for luaL_addchar) *)
procedure luaL_putchar(B: PluaL_Buffer; c: AnsiChar);

procedure luaL_addsize(B: PluaL_Buffer; n: Integer);

procedure luaL_buffinit(L: Plua_State; B: PluaL_Buffer); cdecl;
function luaL_prepbuffer(B: PluaL_Buffer): PAnsiChar; cdecl;
procedure luaL_addlstring(B: PluaL_Buffer; const s: PAnsiChar; l: size_t); cdecl;
procedure luaL_addstring(B: PluaL_Buffer; const s: PAnsiChar); cdecl;
procedure luaL_addvalue(B: PluaL_Buffer); cdecl;
procedure luaL_pushresult(B: PluaL_Buffer); cdecl;

(* compatibility with ref system *)

(* pre-defined references *)
const
  LUA_NOREF  = -2;
  LUA_REFNIL = -1;

procedure lua_unref(L: Plua_State; ref: Integer);
procedure lua_getref(L: Plua_State; ref: Integer);

(*
** Compatibility macros and functions
*)

function luaL_check_lstr(L: Plua_State; numArg: Integer; len: Psize_t): PAnsiChar;
function luaL_opt_lstr(L: Plua_State; numArg: Integer; const def: PAnsiChar; len: Psize_t): PAnsiChar;
function luaL_check_number(L: Plua_State; numArg: Integer): lua_Number;
function luaL_opt_number(L: Plua_State; nArg: Integer; def: lua_Number): lua_Number;
procedure luaL_arg_check(L: Plua_State; cond: Boolean; numarg: Integer; extramsg: PAnsiChar);
function luaL_check_string(L: Plua_State; n: Integer): PAnsiChar;
function luaL_opt_string(L: Plua_State; n: Integer; d: PAnsiChar): PAnsiChar;
function luaL_check_int(L: Plua_State; n: Integer): Integer;
function luaL_check_long(L: Plua_State; n: Integer): LongInt;
function luaL_opt_int(L: Plua_State; n: Integer; d: Double): Integer;
function luaL_opt_long(L: Plua_State; n: Integer; d: Double): LongInt;

implementation

uses
  SysUtils, Classes;

const
  FREELIST_REF = 0;
  LUA_ERRFILE = 6;     // LUA_ERRERR + 1 in lauxlib.h

procedure lua_pushstring(L: Plua_State; const s: ansistring);
begin
  lua_pushlstring(L, PAnsiChar(s), Length(s));
end;

function luaL_getn(L: Plua_State; n: Integer): Integer;
begin
  Result := lua_objlen(L, n);
end;

procedure luaL_setn(L: Plua_State; t, n: Integer);
begin
  // does nothing as this operation is deprecated
end;

function AbsIndex(L: Plua_State; i: Integer): Integer; inline;
begin
  if (i > 0) or (i <= LUA_REGISTRYINDEX) then Result := i
  else Result := lua_gettop(L) + i + 1;
end;

{ ---- errors ---- }

procedure luaL_where(L: Plua_State; lvl: Integer); cdecl;
var
  ar: lua_Debug;
begin
  if lua_getstack(L, lvl, @ar) <> 0 then
  begin
    lua_getinfo(L, 'Sl', @ar);
    if ar.currentline > 0 then
    begin
      luap_pushfarray(L, '%s:%d: ', [PAnsiChar(@ar.short_src[0]), ar.currentline]);
      Exit;
    end;
  end;
  lua_pushliteral(L, '');
end;

function ErrorArr(L: Plua_State; const fmt: PAnsiChar; const args: array of const): Integer;
begin
  luaL_where(L, 1);
  luap_pushfarray(L, fmt, args);
  lua_concat(L, 2);
  Result := lua_error(L);
end;

function luaL_argerror(L: Plua_State; numarg: Integer; const extramsg: PAnsiChar): Integer; cdecl;
var
  ar: lua_Debug;
begin
  if lua_getstack(L, 0, @ar) = 0 then
    Exit(ErrorArr(L, 'bad argument #%d (%s)', [numarg, extramsg]));
  lua_getinfo(L, 'n', @ar);
  if (ar.namewhat <> nil) and (StrComp(ar.namewhat, 'method') = 0) then
  begin
    Dec(numarg);
    if numarg = 0 then
      Exit(ErrorArr(L, 'calling ' + #39 + '%s' + #39 + ' on bad self (%s)', [ar.name, extramsg]));
  end;
  if ar.name = nil then ar.name := '?';
  Result := ErrorArr(L, 'bad argument #%d to ' + #39 + '%s' + #39 + ' (%s)', [numarg, ar.name, extramsg]);
end;

function luaL_typerror(L: Plua_State; narg: Integer; const tname: PAnsiChar): Integer; cdecl;
var
  msg: PAnsiChar;
begin
  msg := luap_pushfarray(L, '%s expected, got %s', [tname, luaL_typename(L, narg)]);
  Result := luaL_argerror(L, narg, msg);
end;

procedure tag_error(L: Plua_State; narg, tag: Integer);
begin
  luaL_typerror(L, narg, lua_typename(L, tag));
end;

{ ---- argument checks ---- }

function luaL_checklstring(L: Plua_State; numArg: Integer; l_: Psize_t): PAnsiChar; cdecl;
begin
  Result := lua_tolstring(L, numArg, l_);
  if Result = nil then tag_error(L, numArg, LUA_TSTRING);
end;

function luaL_optlstring(L: Plua_State; numArg: Integer; const def: PAnsiChar; l_: Psize_t): PAnsiChar; cdecl;
begin
  if lua_isnoneornil(L, numArg) then
  begin
    if l_ <> nil then
    begin
      if def = nil then l_^ := 0 else l_^ := StrLen(def);
    end;
    Result := def;
  end
  else
    Result := luaL_checklstring(L, numArg, l_);
end;

function luaL_checknumber(L: Plua_State; numArg: Integer): lua_Number; cdecl;
begin
  Result := lua_tonumber(L, numArg);
  if (Result = 0) and not lua_isnumber(L, numArg) then tag_error(L, numArg, LUA_TNUMBER);
end;

function luaL_optnumber(L: Plua_State; nArg: Integer; def: lua_Number): lua_Number; cdecl;
begin
  if lua_isnoneornil(L, nArg) then Result := def else Result := luaL_checknumber(L, nArg);
end;

function luaL_checkinteger(L: Plua_State; numArg: Integer): lua_Integer; cdecl;
begin
  Result := lua_tointeger(L, numArg);
  if (Result = 0) and not lua_isnumber(L, numArg) then tag_error(L, numArg, LUA_TNUMBER);
end;

function luaL_optinteger(L: Plua_State; nArg: Integer; def: lua_Integer): lua_Integer; cdecl;
begin
  if lua_isnoneornil(L, nArg) then Result := def else Result := luaL_checkinteger(L, nArg);
end;

procedure luaL_checkstack(L: Plua_State; sz: Integer; const msg: PAnsiChar); cdecl;
begin
  if not lua_checkstack(L, sz) then ErrorArr(L, 'stack overflow (%s)', [msg]);
end;

procedure luaL_checktype(L: Plua_State; narg, t: Integer); cdecl;
begin
  if lua_type(L, narg) <> t then tag_error(L, narg, t);
end;

procedure luaL_checkany(L: Plua_State; narg: Integer); cdecl;
begin
  if lua_type(L, narg) = LUA_TNONE then luaL_argerror(L, narg, 'value expected');
end;

function luaL_checkoption(L: Plua_State; narg: Integer; def: PAnsiChar; lst: PPAnsiChar): Integer; cdecl;
var
  name: PAnsiChar;
  i: Integer;
begin
  name := luaL_optlstring(L, narg, def, nil);
  if name = nil then name := luaL_checklstring(L, narg, nil);
  i := 0;
  while lst[i] <> nil do
  begin
    if StrComp(lst[i], name) = 0 then Exit(i);
    Inc(i);
  end;
  Result := luaL_argerror(L, narg, luap_pushfarray(L, 'invalid option ' + #39 + '%s' + #39, [name]));
end;

{ ---- metatables and userdata ---- }

function luaL_newmetatable(L: Plua_State; const tname: PAnsiChar): Integer; cdecl;
begin
  lua_getfield(L, LUA_REGISTRYINDEX, tname);
  if not lua_isnil(L, -1) then Exit(0);
  lua_pop(L, 1);
  lua_newtable(L);
  lua_pushvalue(L, -1);
  lua_setfield(L, LUA_REGISTRYINDEX, tname);
  Result := 1;
end;

function luaL_checkudata(L: Plua_State; ud: Integer; const tname: PAnsiChar): Pointer; cdecl;
begin
  Result := lua_touserdata(L, ud);
  if Result <> nil then
    if lua_getmetatable(L, ud) <> 0 then
    begin
      lua_getfield(L, LUA_REGISTRYINDEX, tname);
      if lua_rawequal(L, -1, -2) then
      begin
        lua_pop(L, 2);
        Exit;
      end;
    end;
  luaL_typerror(L, ud, tname);
  Result := nil;
end;

function luaL_getmetafield(L: Plua_State; obj: Integer; const e: PAnsiChar): Integer; cdecl;
begin
  if lua_getmetatable(L, obj) = 0 then Exit(0);
  lua_pushstring(L, e);
  lua_rawget(L, -2);
  if lua_isnil(L, -1) then
  begin
    lua_pop(L, 2);
    Result := 0;
  end
  else
  begin
    lua_remove(L, -2);
    Result := 1;
  end;
end;

function luaL_callmeta(L: Plua_State; obj: Integer; const e: PAnsiChar): Integer; cdecl;
begin
  obj := AbsIndex(L, obj);
  if luaL_getmetafield(L, obj, e) = 0 then Exit(0);
  lua_pushvalue(L, obj);
  lua_call(L, 1, 1);
  Result := 1;
end;

{ ---- libraries ---- }

function luaL_findtable(L: Plua_State; idx: Integer; const fname: PAnsiChar; szhint: Integer): PAnsiChar; cdecl;
var
  e, fn: PAnsiChar;
  name: AnsiString;
  n: Integer;
begin
  fn := fname;
  if idx <> 0 then lua_pushvalue(L, idx);
  Result := nil;
  repeat
    e := StrScan(fn, '.');
    n := 0;
    if e = nil then n := StrLen(fn) else n := e - fn;
    SetLength(name, n);
    Move(fn^, name[1], n);
    lua_pushlstring(L, PAnsiChar(name), n);
    lua_rawget(L, -2);
    if lua_isnil(L, -1) then
    begin
      lua_pop(L, 1);
      lua_createtable(L, 0, ord(e = nil) * szhint);
      lua_pushlstring(L, PAnsiChar(name), n);
      lua_pushvalue(L, -2);
      lua_settable(L, -4);
    end
    else if not lua_istable(L, -1) then
    begin
      lua_pop(L, 2);
      Exit(fname);
    end;
    lua_remove(L, -2);
    if e <> nil then fn := e + 1;
  until e = nil;
end;

procedure luaL_openlib(L: Plua_State; const libname: PAnsiChar; const lr: PluaL_reg; nup: Integer); cdecl;
var
  r: PluaL_reg;
  size, i: Integer;
begin
  if libname <> nil then
  begin
    size := 0;
    r := lr;
    while (r <> nil) and (r^.name <> nil) do begin Inc(size); Inc(r); end;
    // the table is looked up in package.loaded first, then in the globals
    luaL_findtable(L, LUA_REGISTRYINDEX, '_LOADED', 1);
    lua_getfield(L, -1, libname);
    if not lua_istable(L, -1) then
    begin
      lua_pop(L, 1);
      if luaL_findtable(L, LUA_GLOBALSINDEX, libname, size) <> nil then
        ErrorArr(L, 'name conflict for module ' + #39 + '%s' + #39, [libname]);
      lua_pushvalue(L, -1);
      lua_setfield(L, -3, libname);
    end;
    lua_remove(L, -2);
    lua_insert(L, -(nup + 1));
  end;
  r := lr;
  while (r <> nil) and (r^.name <> nil) do
  begin
    for i := 1 to nup do lua_pushvalue(L, -nup);
    lua_pushcclosure(L, r^.func, nup);
    lua_setfield(L, -(nup + 2), r^.name);
    Inc(r);
  end;
  lua_pop(L, nup);
end;

procedure luaL_register(L: Plua_State; const libname: PAnsiChar; const lr: PluaL_reg); cdecl;
begin
  luaL_openlib(L, libname, lr, 0);
end;

{ ---- references ---- }

function luaL_ref(L: Plua_State; t: Integer): Integer; cdecl;
begin
  t := AbsIndex(L, t);
  if lua_isnil(L, -1) then
  begin
    lua_pop(L, 1);
    Exit(LUA_REFNIL);
  end;
  lua_rawgeti(L, t, FREELIST_REF);
  Result := lua_tointeger(L, -1);
  lua_pop(L, 1);
  if Result <> 0 then
  begin
    lua_rawgeti(L, t, Result);
    lua_rawseti(L, t, FREELIST_REF);
  end
  else
    Result := lua_objlen(L, t) + 1;
  lua_rawseti(L, t, Result);
end;

procedure luaL_unref(L: Plua_State; t, ref: Integer); cdecl;
begin
  if ref >= 0 then
  begin
    t := AbsIndex(L, t);
    lua_rawgeti(L, t, FREELIST_REF);
    lua_rawseti(L, t, ref);
    lua_pushinteger(L, ref);
    lua_rawseti(L, t, FREELIST_REF);
  end;
end;

procedure lua_unref(L: Plua_State; ref: Integer);
begin
  luaL_unref(L, LUA_REGISTRYINDEX, ref);
end;

procedure lua_getref(L: Plua_State; ref: Integer);
begin
  lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
end;

{ ---- loading ---- }

type
  TOneShot = record
    P: PAnsiChar;
    N: size_t;
  end;
  POneShot = ^TOneShot;

function OneShotReader(L: Plua_State; ud: Pointer; sz: Psize_t): PAnsiChar; cdecl;
var
  o: POneShot;
begin
  o := POneShot(ud);
  if o^.N = 0 then Exit(nil);
  sz^ := o^.N;
  o^.N := 0;
  Result := o^.P;
end;

function luaL_loadbuffer(L: Plua_State; const buff: PAnsiChar; size: size_t; const name: PAnsiChar): Integer; cdecl;
var
  o: TOneShot;
begin
  o.P := buff;
  o.N := size;
  Result := lua_load(L, @OneShotReader, @o, name);
end;

function luaL_loadstring(L: Plua_State; const s: PAnsiChar): Integer; cdecl;
begin
  Result := luaL_loadbuffer(L, s, StrLen(s), s);
end;

function luaL_loadfile(L: Plua_State; const filename: PAnsiChar): Integer; cdecl;
var
  fs: TFileStream;
  ms: TMemoryStream;
  buf: AnsiString;
  fn, chunk: AnsiString;
  start: Integer;
begin
  if filename = nil then
  begin
    fn := 'stdin';
    chunk := '=stdin';
    ms := TMemoryStream.Create;
    try
      ms.LoadFromStream(THandleStream.Create(0));
      SetLength(buf, ms.Size);
      if ms.Size > 0 then Move(ms.Memory^, buf[1], ms.Size);
    finally
      ms.Free;
    end;
  end
  else
  begin
    fn := filename;
    chunk := '@' + fn;
    try
      fs := TFileStream.Create(fn, fmOpenRead or fmShareDenyNone);
      try
        SetLength(buf, fs.Size);
        if fs.Size > 0 then fs.ReadBuffer(buf[1], fs.Size);
      finally
        fs.Free;
      end;
    except
      luap_pushfarray(L, 'cannot open %s', [PAnsiChar(fn)]);
      Exit(LUA_ERRFILE);
    end;
  end;
  start := 1;
  if (Length(buf) >= 3) and (buf[1] = #$EF) and (buf[2] = #$BB) and (buf[3] = #$BF) then start := 4;
  if (start <= Length(buf)) and (buf[start] = '#') then
  begin
    // skip the first line, keeping its line break so line numbers stay right
    while (start <= Length(buf)) and (buf[start] <> #10) do Inc(start);
  end;
  Result := luaL_loadbuffer(L, PAnsiChar(@buf[start]), Length(buf) - start + 1, PAnsiChar(chunk));
end;

function luaL_newstate: Plua_State; cdecl;
begin
  Result := lua_newstate(nil, nil);
end;

function lua_open: Plua_State;
begin
  Result := luaL_newstate;
end;

function luaL_gsub(L: Plua_State; const s, p, r: PAnsiChar): PAnsiChar; cdecl;
var
  res, src, pat, rep: AnsiString;
begin
  src := s;
  pat := p;
  rep := r;
  if pat = '' then res := src else res := StringReplace(src, pat, rep, [rfReplaceAll]);
  lua_pushlstring(L, PAnsiChar(res), Length(res));
  Result := lua_tostring(L, -1);
end;

{ ---- macros ---- }

function luaL_typename(L: Plua_State; i: Integer): PAnsiChar;
begin
  Result := lua_typename(L, lua_type(L, i));
end;

function lua_dofile(L: Plua_State; const filename: PAnsiChar): Integer;
begin
  Result := luaL_loadfile(L, filename);
  if Result = 0 then
    Result := lua_pcall(L, 0, LUA_MULTRET, 0);
end;

function lua_dostring(L: Plua_State; const str: PAnsiChar): Integer;
begin
  Result := luaL_loadstring(L, str);
  if Result = 0 then
    Result := lua_pcall(L, 0, LUA_MULTRET, 0);
end;

procedure lua_Lgetmetatable(L: Plua_State; tname: PAnsiChar);
begin
  lua_getfield(L, LUA_REGISTRYINDEX, tname);
end;

procedure luaL_argcheck(L: Plua_State; cond: Boolean; numarg: Integer; extramsg: PAnsiChar);
begin
  if not cond then
    luaL_argerror(L, numarg, extramsg)
end;

function luaL_checkstring(L: Plua_State; n: Integer): PAnsiChar;
begin
  Result := luaL_checklstring(L, n, nil)
end;

function luaL_optstring(L: Plua_State; n: Integer; d: PAnsiChar): PAnsiChar;
begin
  Result := luaL_optlstring(L, n, d, nil)
end;

function luaL_checkint(L: Plua_State; n: Integer): Integer;
begin
  Result := Integer(luaL_checkinteger(L, n))
end;

function luaL_checklong(L: Plua_State; n: Integer): LongInt;
begin
  Result := LongInt(luaL_checkinteger(L, n))
end;

function luaL_optint(L: Plua_State; n: Integer; d: Double): Integer;
begin
  Result := Integer(luaL_optinteger(L, n, Trunc(d)))
end;

function luaL_optlong(L: Plua_State; n: Integer; d: Double): LongInt;
begin
  Result := LongInt(luaL_optinteger(L, n, Trunc(d)))
end;

{ ---- buffers: the pieces that do not fit the inline buffer are pushed as strings, and
  merged so that at most one of them is on the stack ---- }

procedure Flush(B: PluaL_Buffer; force: Boolean);
var
  len: size_t;
begin
  len := B^.p - PAnsiChar(@B^.buffer[0]);
  if (len = 0) and not force then Exit;
  lua_pushlstring(B^.L, PAnsiChar(@B^.buffer[0]), len);
  B^.p := PAnsiChar(@B^.buffer[0]);
  if B^.lvl > 0 then lua_concat(B^.L, 2) else B^.lvl := 1;
end;

procedure luaL_addchar(B: PluaL_Buffer; c: AnsiChar);
begin
  if B^.p >= PAnsiChar(@B^.buffer[0]) + LUAL_BUFFERSIZE then Flush(B, False);
  B^.p^ := c;
  Inc(B^.p);
end;

procedure luaL_putchar(B: PluaL_Buffer; c: AnsiChar);
begin
  luaL_addchar(B, c);
end;

procedure luaL_addsize(B: PluaL_Buffer; n: Integer);
begin
  Inc(B^.p, n);
end;

procedure luaL_buffinit(L: Plua_State; B: PluaL_Buffer); cdecl;
begin
  B^.L := L;
  B^.p := PAnsiChar(@B^.buffer[0]);
  B^.lvl := 0;
end;

function luaL_prepbuffer(B: PluaL_Buffer): PAnsiChar; cdecl;
begin
  Flush(B, False);
  Result := B^.p;
end;

procedure luaL_addlstring(B: PluaL_Buffer; const s: PAnsiChar; l: size_t); cdecl;
var
  n: size_t;
  src: PAnsiChar;
begin
  src := s;
  while l > 0 do
  begin
    n := PAnsiChar(@B^.buffer[0]) + LUAL_BUFFERSIZE - B^.p;
    if n = 0 then
    begin
      Flush(B, False);
      Continue;
    end;
    if n > l then n := l;
    Move(src^, B^.p^, n);
    Inc(B^.p, n);
    Inc(src, n);
    Dec(l, n);
  end;
end;

procedure luaL_addstring(B: PluaL_Buffer; const s: PAnsiChar); cdecl;
begin
  luaL_addlstring(B, s, StrLen(s));
end;

procedure luaL_addvalue(B: PluaL_Buffer); cdecl;
var
  len: size_t;
  s: PAnsiChar;
  copy: AnsiString;
begin
  s := lua_tolstring(B^.L, -1, @len);
  SetLength(copy, len);
  if len > 0 then Move(s^, copy[1], len);
  lua_pop(B^.L, 1);
  luaL_addlstring(B, PAnsiChar(copy), len);
end;

procedure luaL_pushresult(B: PluaL_Buffer); cdecl;
begin
  Flush(B, B^.lvl = 0);
  B^.lvl := 0;
end;

{ ---- compatibility ---- }

function luaL_check_lstr(L: Plua_State; numArg: Integer; len: Psize_t): PAnsiChar;
begin
  Result := luaL_checklstring(L, numArg, len);
end;

function luaL_opt_lstr(L: Plua_State; numArg: Integer; const def: PAnsiChar; len: Psize_t): PAnsiChar;
begin
  Result := luaL_optlstring(L, numArg, def, len);
end;

function luaL_check_number(L: Plua_State; numArg: Integer): lua_Number;
begin
  Result := luaL_checknumber(L, numArg);
end;

function luaL_opt_number(L: Plua_State; nArg: Integer; def: lua_Number): lua_Number;
begin
  Result := luaL_optnumber(L, nArg, def);
end;

procedure luaL_arg_check(L: Plua_State; cond: Boolean; numarg: Integer; extramsg: PAnsiChar);
begin
  luaL_argcheck(L, cond, numarg, extramsg);
end;

function luaL_check_string(L: Plua_State; n: Integer): PAnsiChar;
begin
  Result := luaL_checkstring(L, n);
end;

function luaL_opt_string(L: Plua_State; n: Integer; d: PAnsiChar): PAnsiChar;
begin
  Result := luaL_optstring(L, n, d);
end;

function luaL_check_int(L: Plua_State; n: Integer): Integer;
begin
  Result := luaL_checkint(L, n);
end;

function luaL_check_long(L: Plua_State; n: Integer): LongInt;
begin
  Result := luaL_checklong(L, n);
end;

function luaL_opt_int(L: Plua_State; n: Integer; d: Double): Integer;
begin
  Result := luaL_optint(L, n, d);
end;

function luaL_opt_long(L: Plua_State; n: Integer; d: Double): LongInt;
begin
  Result := luaL_optlong(L, n, d);
end;

end.
