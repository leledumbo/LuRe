unit luap;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// The Lua C API as seen from Pascal: the same interface as the 'lua' unit of the
// Free Pascal Lua bindings (packages/lua), but implemented on top of this
// interpreter instead of linking a Lua shared library. To switch an application,
// rename the units: lua -> luap, lualib -> lualibp, lauxlib -> lauxlibp.
//
// Notes
//  - the interface is the Lua 5.1 one (as in the bindings), the semantics are those
//    of this implementation (Lua 5.5 values: integers and floats are both LUA_TNUMBER);
//  - there is one Lua state per process; lua_newstate returns nil while one is open;
//  - an error raised outside lua_pcall/lua_cpcall reaches the host as an ELuaError
//    exception (there is no panic function call);
//  - coroutines run on native threads: on Unix put 'cthreads' first in the uses clause
//    of the program.

interface

const
  LUA_NAME = 'luap';
  LUA_LIB_NAME = 'luap';

type
  size_t = Cardinal;
  Psize_t = ^size_t;

const
  LUA_VERSION = 'Lua 5.1';
  LUA_RELEASE = 'Lua 5.1.1';
  LUA_VERSION_NUM = 501;
  LUA_COPYRIGHT = 'Copyright (C) 1994-2006 Lua.org, PUC-Rio';
  LUA_AUTHORS = 'R. Ierusalimschy, L. H. de Figueiredo & W. Celes';

(* option for multiple returns in `lua_pcall' and `lua_call' *)
  LUA_MULTRET = -1;

(*
** pseudo-indices
*)
  LUA_REGISTRYINDEX = -10000;
  LUA_ENVIRONINDEX  = -10001;
  LUA_GLOBALSINDEX  = -10002;

function lua_upvalueindex(I: Integer): Integer;

const
(* thread status; 0 is OK *)
  LUA_YIELD_    = 1;
  LUA_ERRRUN    = 2;
  LUA_ERRSYNTAX = 3;
  LUA_ERRMEM    = 4;
  LUA_ERRERR    = 5;

type
  Plua_State = Pointer;

  lua_CFunction = function(L: Plua_State): Integer; cdecl;

(*
** functions that read/write blocks when loading/dumping Lua chunks
*)
type
  lua_Reader = function(L: Plua_State; ud: Pointer; sz: Psize_t): PAnsiChar; cdecl;
  lua_Writer = function(L: Plua_State; const p: Pointer; sz: size_t; ud: Pointer): Integer; cdecl;

(*
** prototype for memory-allocation functions
*)
  lua_Alloc = function(ud, ptr: Pointer; osize, nsize: size_t): Pointer; cdecl;

(*
** basic types
*)
const
  LUA_TNONE          = -1;

  LUA_TNIL           = 0;
  LUA_TBOOLEAN       = 1;
  LUA_TLIGHTUSERDATA = 2;
  LUA_TNUMBER        = 3;
  LUA_TSTRING        = 4;
  LUA_TTABLE         = 5;
  LUA_TFUNCTION      = 6;
  LUA_TUSERDATA      = 7;
  LUA_TTHREAD        = 8;

(* minimum Lua stack available to a C function *)
  LUA_MINSTACK = 20;

type
(* Type of Numbers in Lua *)
  lua_Number = Double;
  lua_Integer = PtrInt;

(*
** state manipulation
*)
function lua_newstate(f: lua_Alloc; ud: Pointer): Plua_state; cdecl;
procedure lua_close(L: Plua_State); cdecl;
function lua_newthread(L: Plua_State): Plua_State; cdecl;

function lua_atpanic(L: Plua_State; panicf: lua_CFunction): lua_CFunction; cdecl;

(*
** basic stack manipulation
*)
function lua_gettop(L: Plua_State): Integer; cdecl;
procedure lua_settop(L: Plua_State; idx: Integer); cdecl;
procedure lua_pushvalue(L: Plua_State; Idx: Integer); cdecl;
procedure lua_remove(L: Plua_State; idx: Integer); cdecl;
procedure lua_insert(L: Plua_State; idx: Integer); cdecl;
procedure lua_replace(L: Plua_State; idx: Integer); cdecl;
function lua_checkstack(L: Plua_State; sz: Integer): LongBool; cdecl;

procedure lua_xmove(from, to_: Plua_State; n: Integer); cdecl;

(*
** access functions (stack -> C)
*)
function lua_isnumber(L: Plua_State; idx: Integer): LongBool; cdecl;
function lua_isstring(L: Plua_State; idx: Integer): LongBool; cdecl;
function lua_iscfunction(L: Plua_State; idx: Integer): LongBool; cdecl;
function lua_isuserdata(L: Plua_State; idx: Integer): LongBool; cdecl;
function lua_type(L: Plua_State; idx: Integer): Integer; cdecl;
function lua_typename(L: Plua_State; tp: Integer): PAnsiChar; cdecl;

function lua_equal(L: Plua_State; idx1, idx2: Integer): LongBool; cdecl;
function lua_rawequal(L: Plua_State; idx1, idx2: Integer): LongBool; cdecl;
function lua_lessthan(L: Plua_State; idx1, idx2: Integer): LongBool; cdecl;

function lua_tonumber(L: Plua_State; idx: Integer): lua_Number; cdecl;
function lua_tointeger(L: Plua_State; idx: Integer): lua_Integer; cdecl;
function lua_toboolean(L: Plua_State; idx: Integer): LongBool; cdecl;
function lua_tolstring(L: Plua_State; idx: Integer; len: Psize_t): PAnsiChar; cdecl;
function lua_objlen(L: Plua_State; idx: Integer): size_t; cdecl;
function lua_tocfunction(L: Plua_State; idx: Integer): lua_CFunction; cdecl;
function lua_touserdata(L: Plua_State; idx: Integer): Pointer; cdecl;
function lua_tothread(L: Plua_State; idx: Integer): Plua_State; cdecl;
function lua_topointer(L: Plua_State; idx: Integer): Pointer; cdecl;

(*
** push functions (C -> stack)
*)
procedure lua_pushnil(L: Plua_State); cdecl;
procedure lua_pushnumber(L: Plua_State; n: lua_Number); cdecl;
procedure lua_pushinteger(L: Plua_State; n: lua_Integer); cdecl;
procedure lua_pushlstring(L: Plua_State; const s: PAnsiChar; l_: size_t); cdecl;
procedure lua_pushstring(L: Plua_State; const s: PAnsiChar); cdecl;
function lua_pushvfstring(L: Plua_State; const fmt: PAnsiChar; argp: Pointer): PAnsiChar; cdecl;
function lua_pushfstring(L: Plua_State; const fmt: PAnsiChar): PAnsiChar; cdecl; varargs; external name 'luap_pushfstring';
// lua_pushfstring for Pascal callers (used by luaL_error of lauxlibp)
function luap_pushfarray(L: Plua_State; const fmt: PAnsiChar; const args: array of const): PAnsiChar;
procedure lua_pushcclosure(L: Plua_State; fn: lua_CFunction; n: Integer); cdecl;
procedure lua_pushboolean(L: Plua_State; b: LongBool); cdecl;
procedure lua_pushlightuserdata(L: Plua_State; p: Pointer); cdecl;
procedure lua_pushthread(L: Plua_State); cdecl;

(*
** get functions (Lua -> stack)
*)
procedure lua_gettable(L: Plua_State; idx: Integer); cdecl;
procedure lua_getfield(L: Plua_state; idx: Integer; k: PAnsiChar); cdecl;
procedure lua_rawget(L: Plua_State; idx: Integer); cdecl;
procedure lua_rawgeti(L: Plua_State; idx, n: Integer); cdecl;
procedure lua_createtable(L: Plua_State; narr, nrec: Integer); cdecl;
function lua_newuserdata(L: Plua_State; sz: size_t): Pointer; cdecl;
function lua_getmetatable(L: Plua_State; objindex: Integer): Integer; cdecl;
procedure lua_getfenv(L: Plua_State; idx: Integer); cdecl;

(*
** set functions (stack -> Lua)
*)
procedure lua_settable(L: Plua_State; idx: Integer); cdecl;
procedure lua_setfield(L: Plua_State; idx: Integer; k: PAnsiChar); cdecl;
procedure lua_rawset(L: Plua_State; idx: Integer); cdecl;
procedure lua_rawseti(L: Plua_State; idx, n: Integer); cdecl;
function lua_setmetatable(L: Plua_State; objindex: Integer): Integer; cdecl;
function lua_setfenv(L: Plua_State; idx: Integer): Integer; cdecl;

(*
** `load' and `call' functions (load and run Lua code)
*)
procedure lua_call(L: Plua_State; nargs, nresults: Integer); cdecl;
function lua_pcall(L: Plua_State; nargs, nresults, errf: Integer): Integer; cdecl;
function lua_cpcall(L: Plua_State; func: lua_CFunction; ud: Pointer): Integer; cdecl;
function lua_load(L: Plua_State; reader: lua_Reader; dt: Pointer; const chunkname: PAnsiChar): Integer; cdecl;

function lua_dump(L: Plua_State; writer: lua_Writer; data: Pointer): Integer; cdecl;

(*
** coroutine functions
*)
function lua_yield(L: Plua_State; nresults: Integer): Integer; cdecl;
function lua_resume(L: Plua_State; narg: Integer): Integer; cdecl;
function lua_status(L: Plua_State): Integer; cdecl;

(*
** Garbage-collection functions and options
*)
const
  LUA_GCSTOP       = 0;
  LUA_GCRESTART    = 1;
  LUA_GCCOLLECT    = 2;
  LUA_GCCOUNT      = 3;
  LUA_GCCOUNTB     = 4;
  LUA_GCSTEP       = 5;
  LUA_GCSETPAUSE   = 6;
  LUA_GCSETSTEPMUL = 7;

function lua_gc(L: Plua_State; what, data: Integer): Integer; cdecl;

(*
** miscellaneous functions
*)
function lua_error(L: Plua_State): Integer; cdecl;

function lua_next(L: Plua_State; idx: Integer): Integer; cdecl;

procedure lua_concat(L: Plua_State; n: Integer); cdecl;

function lua_getallocf(L: Plua_State; ud: PPointer): lua_Alloc; cdecl;
procedure lua_setallocf(L: Plua_State; f: lua_Alloc; ud: Pointer); cdecl;

(*
** ===============================================================
** some useful macros
** ===============================================================
*)

procedure lua_pop(L: Plua_State; n: Integer);

procedure lua_newtable(L: Plua_state);

procedure lua_register(L: Plua_State; const n: PAnsiChar; f: lua_CFunction);
procedure lua_pushcfunction(L: Plua_State; f: lua_CFunction);

function lua_strlen(L: Plua_state; i: Integer): size_t;

function lua_isfunction(L: Plua_State; n: Integer): Boolean;
function lua_istable(L: Plua_State; n: Integer): Boolean;
function lua_islightuserdata(L: Plua_State; n: Integer): Boolean;
function lua_isnil(L: Plua_State; n: Integer): Boolean;
function lua_isboolean(L: Plua_State; n: Integer): Boolean;
function lua_isthread(L: Plua_State; n: Integer): Boolean;
function lua_isnone(L: Plua_State; n: Integer): Boolean;
function lua_isnoneornil(L: Plua_State; n: Integer): Boolean;

procedure lua_pushliteral(L: Plua_State; s: PAnsiChar);

procedure lua_setglobal(L: Plua_State; const s: PAnsiChar);
procedure lua_getglobal(L: Plua_State; const s: PAnsiChar);

function lua_tostring(L: Plua_State; i: Integer): PAnsiChar;

(*
** compatibility macros and functions
*)

procedure lua_getregistry(L: Plua_State);

function lua_getgccount(L: Plua_State): Integer;

type
  lua_Chunkreader = lua_Reader;
  lua_Chunkwriter = lua_Writer;

(*
** {======================================================================
** Debug API
** =======================================================================
*)

const
  LUA_HOOKCALL    = 0;
  LUA_HOOKRET     = 1;
  LUA_HOOKLINE    = 2;
  LUA_HOOKCOUNT   = 3;
  LUA_HOOKTAILRET = 4;

const
  LUA_MASKCALL  = 1 shl Ord(LUA_HOOKCALL);
  LUA_MASKRET   = 1 shl Ord(LUA_HOOKRET);
  LUA_MASKLINE  = 1 shl Ord(LUA_HOOKLINE);
  LUA_MASKCOUNT = 1 shl Ord(LUA_HOOKCOUNT);

const
  LUA_IDSIZE = 60;

type
  lua_Debug = record           (* activation record *)
    event: Integer;
    name: PAnsiChar;               (* (n) *)
    namewhat: PAnsiChar;           (* (n) `global', `local', `field', `method' *)
    what: PAnsiChar;               (* (S) `Lua', `C', `main', `tail'*)
    source: PAnsiChar;             (* (S) *)
    currentline: Integer;      (* (l) *)
    nups: Integer;             (* (u) number of upvalues *)
    linedefined: Integer;      (* (S) *)
    lastlinedefined: Integer;  (* (S) *)
    short_src: array[0..LUA_IDSIZE - 1] of AnsiChar; (* (S) *)
    (* private part *)
    i_ci: Integer;              (* active function *)
  end;
  Plua_Debug = ^lua_Debug;

  lua_Hook = procedure(L: Plua_State; ar: Plua_Debug); cdecl;

function lua_getstack(L: Plua_State; level: Integer; ar: Plua_Debug): Integer; cdecl;
function lua_getinfo(L: Plua_State; const what: PAnsiChar; ar: Plua_Debug): Integer; cdecl;
function lua_getlocal(L: Plua_State; const ar: Plua_Debug; n: Integer): PAnsiChar; cdecl;
function lua_setlocal(L: Plua_State; const ar: Plua_Debug; n: Integer): PAnsiChar; cdecl;
function lua_getupvalue(L: Plua_State; funcindex: Integer; n: Integer): PAnsiChar; cdecl;
function lua_setupvalue(L: Plua_State; funcindex: Integer; n: Integer): PAnsiChar; cdecl;

function lua_sethook(L: Plua_State; func: lua_Hook; mask: Integer; count: Integer): Integer; cdecl;
function lua_gethookmask(L: Plua_State): Integer; cdecl;
function lua_gethookcount(L: Plua_State): Integer; cdecl;

implementation

uses
  SysUtils, Math, Generics.Collections, luacore, luavm, luaaux, lualibbase, lualibco, luaparse;

const
  FREELIST_REF = 0;

var
  ApiState: TLua = nil;        // the one state
  BaseFunc: TFunction = nil;   // function of the base frame of the state
  AllocF: lua_Alloc = nil;
  AllocUD: Pointer = nil;
  PanicF: lua_CFunction = nil;
  Pseudo: array[0..1] of TLuaValue;   // values of the pseudo-indices
  PseudoFlip: Integer = 0;
  PermStrs: specialize TDictionary<string, AnsiString> = nil;

function TL(L: Plua_State): TLua; inline;
begin
  Result := TLua(L);
end;

{ ===================================================================== }
{ helpers                                                                }
{ ===================================================================== }

function CurBase(T: TLua): Integer; inline;
begin
  if T.NCI = 0 then Result := 0 else Result := T.CI[T.NCI - 1].Base;
end;

// address of the value at an index (nil when the index is not valid)
function IndexPtr(T: TLua; idx: Integer): PLuaValue;
var
  i, n: Integer;
  f: TFunction;
begin
  if idx > 0 then
  begin
    i := CurBase(T) + idx - 1;
    if i >= T.Top then Exit(nil);
    Exit(@T.Stack[i]);
  end;
  if idx > LUA_REGISTRYINDEX then
  begin
    i := T.Top + idx;
    if i < CurBase(T) then Exit(nil);
    Exit(@T.Stack[i]);
  end;
  case idx of
    LUA_REGISTRYINDEX:
      begin
        PseudoFlip := 1 - PseudoFlip;
        Pseudo[PseudoFlip] := LuaTab(T.Registry);
        Result := @Pseudo[PseudoFlip];
      end;
    LUA_ENVIRONINDEX, LUA_GLOBALSINDEX:
      begin
        PseudoFlip := 1 - PseudoFlip;
        Pseudo[PseudoFlip] := LuaTab(T.GlobalT);
        Result := @Pseudo[PseudoFlip];
      end;
  else
    begin
      // upvalue of the running C closure (upvalue 1 lives in CVals[1]: slot 0 holds the function)
      n := LUA_GLOBALSINDEX - idx;
      Result := nil;
      if T.NCI > 0 then
      begin
        f := T.CI[T.NCI - 1].Func;
        if (f <> nil) and f.IsC and (n >= 1) and (n < Length(f.CVals)) then
          Result := @f.CVals[n];
      end;
    end;
  end;
end;

function ValueAt(T: TLua; idx: Integer): TLuaValue;
var
  p: PLuaValue;
begin
  p := IndexPtr(T, idx);
  if p = nil then Result.Vt := vtNil else CopyVal(@Result, p);
end;

procedure PushV(T: TLua; constref v: TLuaValue);
begin
  if T.Top >= T.StackSize - 2 then T.EnsureStack(T.Top + 8);
  CopyVal(@T.Stack[T.Top], @v);
  Inc(T.Top);
end;

// a string that stays valid for the life of the program (names handed out by the debug API)
function PermStr(const s: string): PAnsiChar;
var
  r: AnsiString;
begin
  if PermStrs = nil then PermStrs := specialize TDictionary<string, AnsiString>.Create;
  if not PermStrs.TryGetValue(s, r) then
  begin
    r := AnsiString(s);
    PermStrs.Add(s, r);
  end;
  Result := PAnsiChar(r);
end;

function lua_upvalueindex(I: Integer): Integer;
begin
  Result := LUA_GLOBALSINDEX - I;
end;

{ ===================================================================== }
{ state manipulation                                                     }
{ ===================================================================== }

function DefaultAlloc(ud, ptr: Pointer; osize, nsize: size_t): Pointer; cdecl;
begin
  if nsize = 0 then
  begin
    if ptr <> nil then FreeMem(ptr);
    Exit(nil);
  end;
  if ptr = nil then Result := GetMem(nsize) else Result := ReAllocMem(ptr, nsize);
end;

function BaseFrame(L: TLua): Integer;
begin
  Result := 0;
end;

function lua_newstate(f: lua_Alloc; ud: Pointer): Plua_state; cdecl;
var
  T: TLua;
begin
  if ApiState <> nil then Exit(nil);     // one state per process
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);
  T := TLua.CreateMain;
  LuaInitVM(T);
  ApiState := T;
  AllocF := f;
  AllocUD := ud;
  // the base frame gives the host a stack of its own (index 1 is its first value)
  BaseFunc := T.NewCFunction(@BaseFrame, 0);
  BaseFunc.Fixed := True;
  T.Stack[0] := LuaFunc(BaseFunc);
  T.Top := 1;
  PushCI(T, BaseFunc, 0, 1, 1 + LUA_MINSTACK, 0, True);
  Result := Plua_State(T);
end;

procedure lua_close(L: Plua_State); cdecl;
var
  T: TLua;
begin
  T := TL(L);
  if T <> ApiState then Exit;
  T.NCI := 1;
  T.Top := 1;
  LuaClose(T);
  ApiState := nil;
end;

function lua_newthread(L: Plua_State): Plua_State; cdecl;
var
  co: TLua;
begin
  co := TL(L).NewThread;
  PushV(TL(L), LuaThread(co));
  Result := Plua_State(co);
end;

function lua_atpanic(L: Plua_State; panicf: lua_CFunction): lua_CFunction; cdecl;
begin
  Result := PanicF;
  PanicF := panicf;
end;

{ ===================================================================== }
{ stack manipulation                                                     }
{ ===================================================================== }

function lua_gettop(L: Plua_State): Integer; cdecl;
begin
  Result := TL(L).Top - CurBase(TL(L));
end;

procedure lua_settop(L: Plua_State; idx: Integer); cdecl;
var
  T: TLua;
  nt: Integer;
begin
  T := TL(L);
  if idx >= 0 then nt := CurBase(T) + idx else nt := T.Top + idx + 1;
  if nt > T.StackSize - 2 then T.EnsureStack(nt + 8);
  T.SetTop(nt);
end;

procedure lua_pushvalue(L: Plua_State; Idx: Integer); cdecl;
begin
  PushV(TL(L), ValueAt(TL(L), Idx));
end;

procedure lua_remove(L: Plua_State; idx: Integer); cdecl;
var
  T: TLua;
  i, a: Integer;
begin
  T := TL(L);
  if idx > 0 then a := CurBase(T) + idx - 1 else a := T.Top + idx;
  for i := a to T.Top - 2 do CopyVal(@T.Stack[i], @T.Stack[i + 1]);
  Dec(T.Top);
end;

procedure lua_insert(L: Plua_State; idx: Integer); cdecl;
var
  T: TLua;
  i, a: Integer;
  v: TLuaValue;
begin
  T := TL(L);
  if idx > 0 then a := CurBase(T) + idx - 1 else a := T.Top + idx;
  CopyVal(@v, @T.Stack[T.Top - 1]);
  for i := T.Top - 1 downto a + 1 do CopyVal(@T.Stack[i], @T.Stack[i - 1]);
  CopyVal(@T.Stack[a], @v);
end;

procedure lua_replace(L: Plua_State; idx: Integer); cdecl;
var
  T: TLua;
  p: PLuaValue;
begin
  T := TL(L);
  if (idx = LUA_GLOBALSINDEX) or (idx = LUA_ENVIRONINDEX) then
  begin
    Dec(T.Top);   // replacing the environment of the running function is not supported
    Exit;
  end;
  p := IndexPtr(T, idx);
  if p <> nil then CopyVal(p, @T.Stack[T.Top - 1]);
  Dec(T.Top);
end;

function lua_checkstack(L: Plua_State; sz: Integer): LongBool; cdecl;
var
  T: TLua;
begin
  T := TL(L);
  if T.Top + sz > MAXSTACK then Exit(False);
  T.EnsureStack(T.Top + sz + 8);
  Result := True;
end;

procedure lua_xmove(from, to_: Plua_State; n: Integer); cdecl;
begin
  if from <> to_ then XMove(TL(from), TL(to_), n);
end;

{ ===================================================================== }
{ access functions                                                       }
{ ===================================================================== }

function TypeCode(constref v: TLuaValue): Integer;
begin
  case v.Vt of
    vtNil: Result := LUA_TNIL;
    vtBool: Result := LUA_TBOOLEAN;
    vtLight: Result := LUA_TLIGHTUSERDATA;
    vtInt, vtFlt: Result := LUA_TNUMBER;
    vtStr: Result := LUA_TSTRING;
    vtTab: Result := LUA_TTABLE;
    vtFunc: Result := LUA_TFUNCTION;
    vtUser: Result := LUA_TUSERDATA;
    vtThread: Result := LUA_TTHREAD;
  else
    Result := LUA_TNIL;
  end;
end;

function lua_type(L: Plua_State; idx: Integer): Integer; cdecl;
var
  p: PLuaValue;
begin
  p := IndexPtr(TL(L), idx);
  if p = nil then Exit(LUA_TNONE);
  Result := TypeCode(p^);
end;

function lua_typename(L: Plua_State; tp: Integer): PAnsiChar; cdecl;
const
  Names: array[-1..8] of PAnsiChar = ('no value', 'nil', 'boolean', 'userdata', 'number',
    'string', 'table', 'function', 'userdata', 'thread');
begin
  if (tp < -1) or (tp > 8) then Exit('?');
  Result := Names[tp];
end;

function lua_isnumber(L: Plua_State; idx: Integer): LongBool; cdecl;
var
  p: PLuaValue;
  n: Double;
begin
  p := IndexPtr(TL(L), idx);
  Result := (p <> nil) and ((p^.Vt = vtInt) or (p^.Vt = vtFlt) or
            ((p^.Vt = vtStr) and ToNumberVal(p^, n)));
end;

function lua_isstring(L: Plua_State; idx: Integer): LongBool; cdecl;
var
  p: PLuaValue;
begin
  p := IndexPtr(TL(L), idx);
  Result := (p <> nil) and (p^.Vt in [vtStr, vtInt, vtFlt]);
end;

function lua_iscfunction(L: Plua_State; idx: Integer): LongBool; cdecl;
var
  p: PLuaValue;
begin
  p := IndexPtr(TL(L), idx);
  Result := (p <> nil) and (p^.Vt = vtFunc) and p^.F.IsC;
end;

function lua_isuserdata(L: Plua_State; idx: Integer): LongBool; cdecl;
var
  p: PLuaValue;
begin
  p := IndexPtr(TL(L), idx);
  Result := (p <> nil) and (p^.Vt in [vtUser, vtLight]);
end;

function lua_equal(L: Plua_State; idx1, idx2: Integer): LongBool; cdecl;
var
  a, b: PLuaValue;
begin
  a := IndexPtr(TL(L), idx1);
  b := IndexPtr(TL(L), idx2);
  if (a = nil) or (b = nil) then Exit(False);
  Result := LuaEquals(TL(L), a^, b^);
end;

function lua_rawequal(L: Plua_State; idx1, idx2: Integer): LongBool; cdecl;
var
  a, b: PLuaValue;
begin
  a := IndexPtr(TL(L), idx1);
  b := IndexPtr(TL(L), idx2);
  if (a = nil) or (b = nil) then Exit(False);
  Result := RawEqual(a^, b^);
end;

function lua_lessthan(L: Plua_State; idx1, idx2: Integer): LongBool; cdecl;
var
  a, b: PLuaValue;
begin
  a := IndexPtr(TL(L), idx1);
  b := IndexPtr(TL(L), idx2);
  if (a = nil) or (b = nil) then Exit(False);
  Result := LuaLessThan(TL(L), a^, b^);
end;

function lua_tonumber(L: Plua_State; idx: Integer): lua_Number; cdecl;
var
  p: PLuaValue;
begin
  p := IndexPtr(TL(L), idx);
  if (p = nil) or not ToNumberVal(p^, Result) then Result := 0;
end;

function lua_tointeger(L: Plua_State; idx: Integer): lua_Integer; cdecl;
var
  p: PLuaValue;
  n: Double;
begin
  p := IndexPtr(TL(L), idx);
  if p = nil then Exit(0);
  if p^.Vt = vtInt then Exit(p^.I);
  if not ToNumberVal(p^, n) then Exit(0);
  if IsNaN(n) or IsInfinite(n) then Exit(0);
  Result := Trunc(n);
end;

function lua_toboolean(L: Plua_State; idx: Integer): LongBool; cdecl;
var
  p: PLuaValue;
begin
  p := IndexPtr(TL(L), idx);
  Result := (p <> nil) and Truthy(p^);
end;

function lua_tolstring(L: Plua_State; idx: Integer; len: Psize_t): PAnsiChar; cdecl;
var
  T: TLua;
  p: PLuaValue;
  o: TStringObj;
begin
  T := TL(L);
  p := IndexPtr(T, idx);
  if (p <> nil) and ((p^.Vt = vtInt) or (p^.Vt = vtFlt)) then
  begin
    // numbers are converted in place
    o := T.NewString(RawByteString(NumToStr(p^)));
    p := IndexPtr(T, idx);
    p^.S := o;
    p^.Vt := vtStr;
  end;
  if (p = nil) or (p^.Vt <> vtStr) then
  begin
    if len <> nil then len^ := 0;
    Exit(nil);
  end;
  if len <> nil then len^ := p^.S.Len;
  Result := PAnsiChar(p^.S.Data);
end;

function lua_objlen(L: Plua_State; idx: Integer): size_t; cdecl;
var
  p: PLuaValue;
begin
  p := IndexPtr(TL(L), idx);
  if p = nil then Exit(0);
  case p^.Vt of
    vtStr: Result := p^.S.Len;
    vtTab: Result := TableLength(p^.T);
    vtUser: Result := p^.U.Len;
  else
    Result := 0;
  end;
end;

// C functions of the application are closures over this one; slot 0 of CVals holds the
// pointer to the application's function
function UserTrampoline(T: TLua): Integer;
var
  f: TFunction;
begin
  f := T.CI[T.NCI - 1].Func;
  Result := lua_CFunction(f.CVals[0].P)(Plua_State(T));
end;

function lua_tocfunction(L: Plua_State; idx: Integer): lua_CFunction; cdecl;
var
  p: PLuaValue;
begin
  p := IndexPtr(TL(L), idx);
  if (p <> nil) and (p^.Vt = vtFunc) and p^.F.IsC and
     (Pointer(p^.F.CProc) = Pointer(@UserTrampoline)) then
    Result := lua_CFunction(p^.F.CVals[0].P)
  else
    Result := nil;
end;

function lua_touserdata(L: Plua_State; idx: Integer): Pointer; cdecl;
var
  p: PLuaValue;
begin
  p := IndexPtr(TL(L), idx);
  if p = nil then Exit(nil);
  case p^.Vt of
    vtUser: Result := p^.U.Data;
    vtLight: Result := p^.P;
  else
    Result := nil;
  end;
end;

function lua_tothread(L: Plua_State; idx: Integer): Plua_State; cdecl;
var
  p: PLuaValue;
begin
  p := IndexPtr(TL(L), idx);
  if (p <> nil) and (p^.Vt = vtThread) then Result := Plua_State(p^.Th) else Result := nil;
end;

function lua_topointer(L: Plua_State; idx: Integer): Pointer; cdecl;
var
  p: PLuaValue;
begin
  p := IndexPtr(TL(L), idx);
  if p = nil then Exit(nil);
  case p^.Vt of
    vtTab: Result := Pointer(p^.T);
    vtFunc: Result := Pointer(p^.F);
    vtThread: Result := Pointer(p^.Th);
    vtUser: Result := p^.U.Data;
    vtLight: Result := p^.P;
  else
    Result := nil;
  end;
end;

{ ===================================================================== }
{ push functions                                                         }
{ ===================================================================== }

procedure lua_pushnil(L: Plua_State); cdecl;
begin
  PushV(TL(L), LuaNil);
end;

procedure lua_pushnumber(L: Plua_State; n: lua_Number); cdecl;
begin
  PushV(TL(L), LuaNum(n));
end;

procedure lua_pushinteger(L: Plua_State; n: lua_Integer); cdecl;
begin
  PushV(TL(L), LuaInt(n));
end;

procedure lua_pushlstring(L: Plua_State; const s: PAnsiChar; l_: size_t); cdecl;
begin
  PushV(TL(L), LuaStr(TL(L).NewStringBuf(PByte(s), l_)));
end;

procedure lua_pushstring(L: Plua_State; const s: PAnsiChar); cdecl;
begin
  if s = nil then lua_pushnil(L)
  else PushV(TL(L), LuaStr(TL(L).NewStringBuf(PByte(s), StrLen(s))));
end;

procedure lua_pushcclosure(L: Plua_State; fn: lua_CFunction; n: Integer); cdecl;
var
  T: TLua;
  f: TFunction;
  i: Integer;
begin
  T := TL(L);
  f := T.NewCFunction(@UserTrampoline, n + 1);
  f.CVals[0].Vt := vtLight;
  f.CVals[0].P := Pointer(fn);
  for i := 1 to n do CopyVal(@f.CVals[i], @T.Stack[T.Top - n + i - 1]);
  Dec(T.Top, n);
  PushV(T, LuaFunc(f));
end;

procedure lua_pushboolean(L: Plua_State; b: LongBool); cdecl;
begin
  PushV(TL(L), LuaBool(b));
end;

procedure lua_pushlightuserdata(L: Plua_State; p: Pointer); cdecl;
begin
  PushV(TL(L), LuaLight(p));
end;

procedure lua_pushthread(L: Plua_State); cdecl;
begin
  PushV(TL(L), LuaThread(TL(L)));
end;

{ ---- formatted strings (printf subset of Lua 5.1: %s %d %f %p %c %%) ---- }

type
  // a source of the arguments of a variadic call
  TArgSource = record
    Kind: Integer;            // 0: register/stack image (pushfstring), 1: va_list, 2: open array
    Ints: array[0..3] of PtrInt;
    NInts: Integer;
    Dbls: array[0..7] of Double;
    NDbls: Integer;
    Stack: PPtrInt;           // stack slots following the registers
    IntIdx, DblIdx: Integer;
    VA: Pointer;              // va_list
    VR: array of TVarRec;
    VRIdx: Integer;
  end;

type
  Tva_list = record
    gp_offset, fp_offset: Cardinal;
    overflow_arg_area, reg_save_area: Pointer;
  end;
  Pva_list = ^Tva_list;

function NextInt(var a: TArgSource): PtrInt;
var
  va: Pva_list;
begin
  case a.Kind of
    0: begin
      if a.IntIdx < a.NInts then
      begin
        Result := a.Ints[a.IntIdx];
        Inc(a.IntIdx);
      end
      else
      begin
        Result := a.Stack^;
        Inc(a.Stack);
      end;
    end;
    1: begin
      va := Pva_list(a.VA);
      if va^.gp_offset < 48 then
      begin
        Result := PPtrInt(PByte(va^.reg_save_area) + va^.gp_offset)^;
        Inc(va^.gp_offset, 8);
      end
      else
      begin
        Result := PPtrInt(va^.overflow_arg_area)^;
        va^.overflow_arg_area := PByte(va^.overflow_arg_area) + 8;
      end;
    end;
  else
    begin
      Result := 0;
      if a.VRIdx <= High(a.VR) then
      begin
        case a.VR[a.VRIdx].VType of
          vtInteger: Result := a.VR[a.VRIdx].VInteger;
          vtInt64: Result := PtrInt(a.VR[a.VRIdx].VInt64^);
          vtChar: Result := Ord(a.VR[a.VRIdx].VChar);
          vtBoolean: Result := Ord(a.VR[a.VRIdx].VBoolean);
          vtPChar: Result := PtrInt(a.VR[a.VRIdx].VPChar);
          vtPointer: Result := PtrInt(a.VR[a.VRIdx].VPointer);
          vtAnsiString: Result := PtrInt(PAnsiChar(AnsiString(a.VR[a.VRIdx].VAnsiString)));
          vtString: Result := PtrInt(PAnsiChar(@a.VR[a.VRIdx].VString^[1]));
        end;
        Inc(a.VRIdx);
      end;
    end;
  end;
end;

function NextDbl(var a: TArgSource): Double;
var
  va: Pva_list;
  bits: PtrInt;
begin
  case a.Kind of
    0: begin
      if a.DblIdx < a.NDbls then
      begin
        Result := a.Dbls[a.DblIdx];
        Inc(a.DblIdx);
      end
      else
      begin
        bits := a.Stack^;
        Inc(a.Stack);
        Result := PDouble(@bits)^;
      end;
    end;
    1: begin
      va := Pva_list(a.VA);
      if va^.fp_offset < 176 then
      begin
        Result := PDouble(PByte(va^.reg_save_area) + va^.fp_offset)^;
        Inc(va^.fp_offset, 16);
      end
      else
      begin
        Result := PDouble(va^.overflow_arg_area)^;
        va^.overflow_arg_area := PByte(va^.overflow_arg_area) + 8;
      end;
    end;
  else
    begin
      Result := 0;
      if a.VRIdx <= High(a.VR) then
      begin
        case a.VR[a.VRIdx].VType of
          vtExtended: Result := a.VR[a.VRIdx].VExtended^;
          vtCurrency: Result := a.VR[a.VRIdx].VCurrency^;
          vtInteger: Result := a.VR[a.VRIdx].VInteger;
        end;
        Inc(a.VRIdx);
      end;
    end;
  end;
end;

// formats like lua_pushfstring and pushes the result
function PushFormatted(L: Plua_State; fmt: PAnsiChar; var a: TArgSource): PAnsiChar;
var
  T: TLua;
  r: AnsiString;
  p: PAnsiChar;
  sp: PAnsiChar;
  c: Char;
  n: PtrInt;
begin
  T := TL(L);
  r := '';
  p := fmt;
  while (p <> nil) and (p^ <> #0) do
  begin
    if p^ <> '%' then
    begin
      r := r + p^;
      Inc(p);
      Continue;
    end;
    Inc(p);
    c := p^;
    case c of
      's': begin
        sp := PAnsiChar(NextInt(a));
        if sp = nil then r := r + '(null)' else r := r + AnsiString(sp);
      end;
      'c': r := r + AnsiChar(Chr(Byte(NextInt(a))));
      'd': begin
        n := Integer(NextInt(a));
        r := r + AnsiString(IntToStr(n));
      end;
      'f': r := r + AnsiString(CFormatDouble('%.14g', NextDbl(a)));
      'p': r := r + AnsiString('0x' + LowerCase(IntToHex(NextInt(a), 8)));
      '%': r := r + '%';
    else
      r := r + '%' + c;
    end;
    if p^ <> #0 then Inc(p);
  end;
  PushV(T, LuaStr(T.NewStringBuf(PByte(PAnsiChar(r)), Length(r))));
  Result := PAnsiChar(T.Stack[T.Top - 1].S.Data);
end;

function lua_pushvfstring(L: Plua_State; const fmt: PAnsiChar; argp: Pointer): PAnsiChar; cdecl;
var
  a: TArgSource;
begin
  FillChar(a, SizeOf(a), 0);
  a.Kind := 1;
  a.VA := argp;
  Result := PushFormatted(L, fmt, a);
end;

function luap_pushfarray(L: Plua_State; const fmt: PAnsiChar; const args: array of const): PAnsiChar;
var
  a: TArgSource;
  i: Integer;
begin
  FillChar(a, SizeOf(a), 0);
  a.Kind := 2;
  SetLength(a.VR, Length(args));
  for i := 0 to High(args) do a.VR[i] := args[i];
  Result := PushFormatted(L, fmt, a);
end;

// the variadic lua_pushfstring: the System V x86-64 convention passes the first integer
// arguments in registers, the first floating point ones in xmm registers and the rest on
// the stack, so a function declaring enough parameters sees all of them
const
  // parameters of the register image of a variadic call
  PARAMS_DOC = 0;

function FormatFromRegs(L: Plua_State; fmt: PAnsiChar;
    i1, i2, i3, i4: PtrInt;
    d0, d1, d2, d3, d4, d5, d6, d7: Double;
    s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15: PtrInt): PAnsiChar;
var
  a: TArgSource;
  stk: array[0..15] of PtrInt;
begin
  FillChar(a, SizeOf(a), 0);
  stk[0] := s0; stk[1] := s1; stk[2] := s2; stk[3] := s3; stk[4] := s4; stk[5] := s5;
  stk[6] := s6; stk[7] := s7; stk[8] := s8; stk[9] := s9; stk[10] := s10; stk[11] := s11;
  stk[12] := s12; stk[13] := s13; stk[14] := s14; stk[15] := s15;
  a.Kind := 0;
  a.Ints[0] := i1; a.Ints[1] := i2; a.Ints[2] := i3; a.Ints[3] := i4;
  a.NInts := 4;
  a.Dbls[0] := d0; a.Dbls[1] := d1; a.Dbls[2] := d2; a.Dbls[3] := d3;
  a.Dbls[4] := d4; a.Dbls[5] := d5; a.Dbls[6] := d6; a.Dbls[7] := d7;
  a.NDbls := 8;
  a.Stack := @stk[0];
  Result := PushFormatted(L, fmt, a);
end;

function PushFStringImpl(L: Plua_State; fmt: PAnsiChar;
    i1, i2, i3, i4: PtrInt;
    d0, d1, d2, d3, d4, d5, d6, d7: Double;
    s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15: PtrInt): PAnsiChar; cdecl;
public name 'luap_pushfstring';
begin
  Result := FormatFromRegs(L, fmt, i1, i2, i3, i4, d0, d1, d2, d3, d4, d5, d6, d7,
    s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15);
end;

// luaL_error(L, fmt, ...) of lauxlibp: the message gets the position of the caller
function ErrorImpl(L: Plua_State; fmt: PAnsiChar;
    i1, i2, i3, i4: PtrInt;
    d0, d1, d2, d3, d4, d5, d6, d7: Double;
    s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15: PtrInt): Integer; cdecl;
public name 'luap_error';
var
  ar: lua_Debug;
begin
  FormatFromRegs(L, fmt, i1, i2, i3, i4, d0, d1, d2, d3, d4, d5, d6, d7,
    s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15);
  if lua_getstack(L, 1, @ar) <> 0 then
  begin
    lua_getinfo(L, 'Sl', @ar);
    if ar.currentline > 0 then
    begin
      luap_pushfarray(L, '%s:%d: ', [PAnsiChar(@ar.short_src[0]), ar.currentline]);
      lua_insert(L, -2);
      lua_concat(L, 2);
    end;
  end;
  Result := lua_error(L);
end;

{ ===================================================================== }
{ get functions                                                          }
{ ===================================================================== }

procedure lua_gettable(L: Plua_State; idx: Integer); cdecl;
var
  T: TLua;
  t0, k, r: TLuaValue;
begin
  T := TL(L);
  t0 := ValueAt(T, idx);
  k := ValueAt(T, -1);
  r := LuaIndex(T, t0, k);
  CopyVal(@T.Stack[T.Top - 1], @r);
end;

procedure lua_getfield(L: Plua_State; idx: Integer; k: PAnsiChar); cdecl;
var
  T: TLua;
  t0, key, r: TLuaValue;
begin
  T := TL(L);
  t0 := ValueAt(T, idx);
  key := LuaStr(T.NewStringBuf(PByte(k), StrLen(k)));
  r := LuaIndex(T, t0, key);
  PushV(T, r);
end;

procedure lua_rawget(L: Plua_State; idx: Integer); cdecl;
var
  T: TLua;
  t0: TLuaValue;
  r: TLuaValue;
begin
  T := TL(L);
  t0 := ValueAt(T, idx);
  if t0.Vt <> vtTab then Exit;
  r := TableGet(t0.T, T.Stack[T.Top - 1]);
  CopyVal(@T.Stack[T.Top - 1], @r);
end;

procedure lua_rawgeti(L: Plua_State; idx, n: Integer); cdecl;
var
  T: TLua;
  t0: TLuaValue;
begin
  T := TL(L);
  t0 := ValueAt(T, idx);
  if t0.Vt <> vtTab then begin PushV(T, LuaNil); Exit; end;
  PushV(T, TableGetInt(t0.T, n));
end;

procedure lua_createtable(L: Plua_State; narr, nrec: Integer); cdecl;
begin
  PushV(TL(L), LuaTab(TL(L).NewTable(narr, nrec)));
end;

function lua_newuserdata(L: Plua_State; sz: size_t): Pointer; cdecl;
var
  u: TUserdata;
begin
  u := TL(L).NewUserdata(sz);
  PushV(TL(L), LuaUser(u));
  Result := u.Data;
end;

function lua_getmetatable(L: Plua_State; objindex: Integer): Integer; cdecl;
var
  T: TLua;
  v: TLuaValue;
  mt: TTable;
begin
  T := TL(L);
  v := ValueAt(T, objindex);
  mt := GetMetatable(T, v);
  if mt = nil then Exit(0);
  PushV(T, LuaTab(mt));
  Result := 1;
end;

// the environment of a function: the global table (Lua 5.5 has no per-function environments;
// a Lua closure that has an _ENV upvalue reports its value)
procedure lua_getfenv(L: Plua_State; idx: Integer); cdecl;
var
  T: TLua;
  v: TLuaValue;
  i: Integer;
begin
  T := TL(L);
  v := ValueAt(T, idx);
  if v.Vt <> vtFunc then
  begin
    PushV(T, LuaNil);
    Exit;
  end;
  if not v.F.IsC then
    for i := 0 to Length(v.F.Upvals) - 1 do
      if UpvalName(v.F.Proto, i) = '_ENV' then
      begin
        PushV(T, v.F.Upvals[i].Get);
        Exit;
      end;
  PushV(T, LuaTab(T.GlobalT));
end;

{ ===================================================================== }
{ set functions                                                          }
{ ===================================================================== }

procedure lua_settable(L: Plua_State; idx: Integer); cdecl;
var
  T: TLua;
  t0, k, v: TLuaValue;
begin
  T := TL(L);
  t0 := ValueAt(T, idx);
  k := ValueAt(T, -2);
  v := ValueAt(T, -1);
  LuaSetIndex(T, t0, k, v);
  Dec(T.Top, 2);
end;

procedure lua_setfield(L: Plua_State; idx: Integer; k: PAnsiChar); cdecl;
var
  T: TLua;
  t0, key, v: TLuaValue;
begin
  T := TL(L);
  t0 := ValueAt(T, idx);
  key := LuaStr(T.NewStringBuf(PByte(k), StrLen(k)));
  v := ValueAt(T, -1);
  LuaSetIndex(T, t0, key, v);
  Dec(T.Top);
end;

procedure lua_rawset(L: Plua_State; idx: Integer); cdecl;
var
  T: TLua;
  t0: TLuaValue;
begin
  T := TL(L);
  t0 := ValueAt(T, idx);
  if t0.Vt = vtTab then TableSet(t0.T, T.Stack[T.Top - 2], T.Stack[T.Top - 1]);
  Dec(T.Top, 2);
end;

procedure lua_rawseti(L: Plua_State; idx, n: Integer); cdecl;
var
  T: TLua;
  t0: TLuaValue;
begin
  T := TL(L);
  t0 := ValueAt(T, idx);
  if t0.Vt = vtTab then TableSetInt(t0.T, n, T.Stack[T.Top - 1]);
  Dec(T.Top);
end;

function lua_setmetatable(L: Plua_State; objindex: Integer): Integer; cdecl;
var
  T: TLua;
  v, m: TLuaValue;
  mt: TTable;
begin
  T := TL(L);
  v := ValueAt(T, objindex);
  m := ValueAt(T, -1);
  if m.Vt = vtTab then mt := m.T else mt := nil;
  case v.Vt of
    vtTab: begin
      v.T.Metatable := mt;
      if (mt <> nil) and (TableGetStr(mt, TMName(TM_GC)).Vt <> vtNil) then T.SetFinalizer(v.T);
    end;
    vtUser: begin
      v.U.Metatable := mt;
      if (mt <> nil) and (TableGetStr(mt, TMName(TM_GC)).Vt <> vtNil) then T.SetFinalizer(v.U);
    end;
  else
    begin
      ApiState.TypeMeta[v.Vt] := mt;
      if v.Vt = vtInt then ApiState.TypeMeta[vtFlt] := mt;
    end;
  end;
  Dec(T.Top);
  Result := 1;
end;

function lua_setfenv(L: Plua_State; idx: Integer): Integer; cdecl;
var
  T: TLua;
  v, e: TLuaValue;
  i: Integer;
  u: TUpval;
begin
  T := TL(L);
  v := ValueAt(T, idx);
  e := ValueAt(T, -1);
  Dec(T.Top);
  Result := 0;
  if (v.Vt <> vtFunc) or v.F.IsC or (e.Vt <> vtTab) then Exit;
  for i := 0 to Length(v.F.Upvals) - 1 do
    if UpvalName(v.F.Proto, i) = '_ENV' then
    begin
      // a private upvalue: other closures that shared the old one keep their environment
      u := T.NewUpval;
      u.V := e;
      v.F.Upvals[i] := u;
      Exit(1);
    end;
end;

{ ===================================================================== }
{ load and call                                                          }
{ ===================================================================== }

procedure lua_call(L: Plua_State; nargs, nresults: Integer); cdecl;
begin
  LuaCallK(TL(L), nargs, nresults);
end;

function MapStatus(st: Integer): Integer;
begin
  case st of
    0: Result := 0;
    2: Result := LUA_ERRERR;
  else
    Result := LUA_ERRRUN;
  end;
end;

function lua_pcall(L: Plua_State; nargs, nresults, errf: Integer): Integer; cdecl;
var
  T: TLua;
  eabs: Integer;
begin
  T := TL(L);
  eabs := 0;
  if errf <> 0 then
  begin
    if errf > 0 then eabs := CurBase(T) + errf - 1 else eabs := T.Top + errf;
  end;
  Result := MapStatus(LuaProtectedCall(T, nargs, nresults, eabs));
  if (Result = LUA_ERRRUN) and (T.Top > 0) and (T.Stack[T.Top - 1].Vt = vtStr) and
     (T.Stack[T.Top - 1].S.EqRaw('not enough memory')) then
    Result := LUA_ERRMEM;
end;

function lua_cpcall(L: Plua_State; func: lua_CFunction; ud: Pointer): Integer; cdecl;
begin
  lua_pushcclosure(L, func, 0);
  lua_pushlightuserdata(L, ud);
  Result := lua_pcall(L, 1, 0, 0);
end;

function lua_load(L: Plua_State; reader: lua_Reader; dt: Pointer; const chunkname: PAnsiChar): Integer; cdecl;
var
  T: TLua;
  buf: RawByteString;
  piece: PAnsiChar;
  sz: size_t;
  f: TFunction;
  err, name: string;
begin
  T := TL(L);
  buf := '';
  while True do
  begin
    sz := 0;
    piece := reader(L, dt, @sz);
    if (piece = nil) or (sz = 0) then Break;
    SetLength(buf, Length(buf) + sz);
    Move(piece^, buf[Length(buf) - sz + 1], sz);
  end;
  if chunkname = nil then name := '=?' else name := string(AnsiString(chunkname));
  PrepareFileChunk(buf);
  if not LoadBuffer(T, buf, name, 'bt', f, err) then
  begin
    PushV(T, LuaStr(T.NewString(RawByteString(err))));
    Exit(LUA_ERRSYNTAX);
  end;
  SetEnvUpvalue(T, f, LuaTab(T.GlobalT));
  PushV(T, LuaFunc(f));
  Result := 0;
end;

function lua_dump(L: Plua_State; writer: lua_Writer; data: Pointer): Integer; cdecl;
var
  T: TLua;
  v: TLuaValue;
  s: RawByteString;
begin
  T := TL(L);
  v := ValueAt(T, -1);
  if (v.Vt <> vtFunc) or v.F.IsC then Exit(1);
  s := LuaDump(T, v.F, False);
  Result := writer(L, PByte(Pointer(s)), Length(s), data);
end;

{ ===================================================================== }
{ coroutines                                                             }
{ ===================================================================== }

function lua_yield(L: Plua_State; nresults: Integer): Integer; cdecl;
begin
  Result := CoYield(TL(L), nresults);
end;

function lua_resume(L: Plua_State; narg: Integer): Integer; cdecl;
var
  co, runner: TLua;
  nres, st: Integer;
begin
  co := TL(L);
  runner := TLua(co.Main.CurThread);
  XMove(co, runner, narg);
  st := ResumeCo(runner, co, narg, nres);
  if st <> 0 then
  begin
    XMove(runner, co, 1);      // the error value
    Exit(LUA_ERRRUN);
  end;
  XMove(runner, co, nres);
  if co.Status = ST_DEAD then Result := 0 else Result := LUA_YIELD_;
end;

function lua_status(L: Plua_State): Integer; cdecl;
var
  co: TLua;
begin
  co := TL(L);
  case co.Status of
    ST_YIELD: Result := LUA_YIELD_;
    ST_ERR: Result := LUA_ERRRUN;
  else
    Result := 0;
  end;
end;

{ ===================================================================== }
{ garbage collection, misc                                               }
{ ===================================================================== }

function lua_gc(L: Plua_State; what, data: Integer): Integer; cdecl;
var
  T: TLua;
  m: TLua;
begin
  T := TL(L);
  m := T.Main;
  Result := 0;
  case what of
    LUA_GCSTOP: m.GCStopped := True;
    LUA_GCRESTART: m.GCStopped := False;
    LUA_GCCOLLECT: m.FullGC;
    LUA_GCCOUNT: Result := Integer(m.TotalBytes shr 10);
    LUA_GCCOUNTB: Result := Integer(m.TotalBytes and 1023);
    LUA_GCSTEP: Result := Ord(m.GCStep(data));
    LUA_GCSETPAUSE: begin Result := m.GCPause; m.GCPause := data; end;
    LUA_GCSETSTEPMUL: begin Result := m.GCStepMul; m.GCStepMul := data; end;
  else
    Result := -1;
  end;
end;

function lua_error(L: Plua_State): Integer; cdecl;
var
  T: TLua;
  v: TLuaValue;
begin
  T := TL(L);
  v := ValueAt(T, -1);
  Dec(T.Top);
  LuaThrow(T, v);
  Result := 0;
end;

function lua_next(L: Plua_State; idx: Integer): Integer; cdecl;
var
  T: TLua;
  t0, nk, nv: TLuaValue;
begin
  T := TL(L);
  t0 := ValueAt(T, idx);
  if t0.Vt <> vtTab then Exit(0);
  if TableNext(t0.T, T.Stack[T.Top - 1], nk, nv) then
  begin
    CopyVal(@T.Stack[T.Top - 1], @nk);
    PushV(T, nv);
    Result := 1;
  end
  else
  begin
    Dec(T.Top);
    Result := 0;
  end;
end;

procedure lua_concat(L: Plua_State; n: Integer); cdecl;
var
  T: TLua;
  acc, x: TLuaValue;
  j: Integer;
begin
  T := TL(L);
  if n = 0 then
  begin
    PushV(T, LuaStr(T.NewStringBuf(nil, 0)));
    Exit;
  end;
  acc := ValueAt(T, -1);
  for j := 2 to n do
  begin
    x := ValueAt(T, -j);
    acc := LuaConcat2(T, x, acc);
  end;
  Dec(T.Top, n);
  PushV(T, acc);
end;

function lua_getallocf(L: Plua_State; ud: PPointer): lua_Alloc; cdecl;
begin
  if ud <> nil then ud^ := AllocUD;
  if AllocF = nil then Result := @DefaultAlloc else Result := AllocF;
end;

procedure lua_setallocf(L: Plua_State; f: lua_Alloc; ud: Pointer); cdecl;
begin
  AllocF := f;
  AllocUD := ud;
end;

{ ===================================================================== }
{ macros                                                                 }
{ ===================================================================== }

procedure lua_pop(L: Plua_State; n: Integer);
begin
  lua_settop(L, -n - 1);
end;

procedure lua_newtable(L: Plua_State);
begin
  lua_createtable(L, 0, 0);
end;

procedure lua_register(L: Plua_State; const n: PAnsiChar; f: lua_CFunction);
begin
  lua_pushcfunction(L, f);
  lua_setglobal(L, n);
end;

procedure lua_pushcfunction(L: Plua_State; f: lua_CFunction);
begin
  lua_pushcclosure(L, f, 0);
end;

function lua_strlen(L: Plua_State; i: Integer): size_t;
begin
  Result := lua_objlen(L, i);
end;

function lua_isfunction(L: Plua_State; n: Integer): Boolean;
begin
  Result := lua_type(L, n) = LUA_TFUNCTION;
end;

function lua_istable(L: Plua_State; n: Integer): Boolean;
begin
  Result := lua_type(L, n) = LUA_TTABLE;
end;

function lua_islightuserdata(L: Plua_State; n: Integer): Boolean;
begin
  Result := lua_type(L, n) = LUA_TLIGHTUSERDATA;
end;

function lua_isnil(L: Plua_State; n: Integer): Boolean;
begin
  Result := lua_type(L, n) = LUA_TNIL;
end;

function lua_isboolean(L: Plua_State; n: Integer): Boolean;
begin
  Result := lua_type(L, n) = LUA_TBOOLEAN;
end;

function lua_isthread(L: Plua_State; n: Integer): Boolean;
begin
  Result := lua_type(L, n) = LUA_TTHREAD;
end;

function lua_isnone(L: Plua_State; n: Integer): Boolean;
begin
  Result := lua_type(L, n) = LUA_TNONE;
end;

function lua_isnoneornil(L: Plua_State; n: Integer): Boolean;
begin
  Result := lua_type(L, n) <= 0;
end;

procedure lua_pushliteral(L: Plua_State; s: PAnsiChar);
begin
  lua_pushlstring(L, s, StrLen(s));
end;

procedure lua_setglobal(L: Plua_State; const s: PAnsiChar);
begin
  lua_setfield(L, LUA_GLOBALSINDEX, s);
end;

procedure lua_getglobal(L: Plua_State; const s: PAnsiChar);
begin
  lua_getfield(L, LUA_GLOBALSINDEX, s);
end;

function lua_tostring(L: Plua_State; i: Integer): PAnsiChar;
begin
  Result := lua_tolstring(L, i, nil);
end;

procedure lua_getregistry(L: Plua_State);
begin
  lua_pushvalue(L, LUA_REGISTRYINDEX);
end;

function lua_getgccount(L: Plua_State): Integer;
begin
  Result := lua_gc(L, LUA_GCCOUNT, 0);
end;

{ ===================================================================== }
{ debug API                                                              }
{ ===================================================================== }

// the frame an activation record refers to, nil if it is gone
function FrameOf(T: TLua; ar: Plua_Debug): PCallInfo;
begin
  if (ar^.i_ci < 0) or (ar^.i_ci >= T.NCI) then Exit(nil);
  Result := @T.CI[ar^.i_ci];
end;

function lua_getstack(L: Plua_State; level: Integer; ar: Plua_Debug): Integer; cdecl;
var
  T: TLua;
  idx: Integer;
begin
  T := TL(L);
  idx := T.NCI - 1 - level;
  if (level < 0) or (idx < 0) or (T.CI[idx].Func = BaseFunc) then Exit(0);
  ar^.i_ci := idx;
  Result := 1;
end;

procedure SetShortSrc(ar: Plua_Debug; const src: string);
var
  s: string;
begin
  s := ChunkIdStr(src);
  if Length(s) > LUA_IDSIZE - 1 then SetLength(s, LUA_IDSIZE - 1);
  FillChar(ar^.short_src, SizeOf(ar^.short_src), 0);
  if s <> '' then Move(s[1], ar^.short_src[0], Length(s));
end;

function lua_getinfo(L: Plua_State; const what: PAnsiChar; ar: Plua_Debug): Integer; cdecl;
var
  T: TLua;
  ci: PCallInfo;
  f: TFunction;
  p: TProto;
  opts: string;
  i, line: Integer;
  nm, nw: string;
  src: string;
  fv: TLuaValue;
  tbl: TTable;
  haveCI: Boolean;
begin
  T := TL(L);
  opts := string(AnsiString(what));
  haveCI := True;
  ci := nil;
  if (opts <> '') and (opts[1] = '>') then
  begin
    // the function is on the top of the stack
    fv := ValueAt(T, -1);
    Dec(T.Top);
    Delete(opts, 1, 1);
    if fv.Vt <> vtFunc then Exit(0);
    f := fv.F;
    haveCI := False;
  end
  else
  begin
    ci := FrameOf(T, ar);
    if ci = nil then Exit(0);
    f := ci^.Func;
    fv := LuaFunc(f);
  end;
  Result := 1;
  p := nil;
  if not f.IsC then p := f.Proto;
  for i := 1 to Length(opts) do
    case opts[i] of
      'S': begin
        if f.IsC then
        begin
          ar^.what := 'C';
          ar^.source := '=[C]';
          ar^.linedefined := -1;
          ar^.lastlinedefined := -1;
          SetShortSrc(ar, '=[C]');
        end
        else
        begin
          if p.LineDefined = 0 then ar^.what := 'main' else ar^.what := 'Lua';
          if p.Source <> nil then
          begin
            ar^.source := PAnsiChar(p.Source.Data);
            src := string(p.Source.Str);
          end
          else
          begin
            ar^.source := '=?';
            src := '=?';
          end;
          ar^.linedefined := p.LineDefined;
          ar^.lastlinedefined := p.LastLineDefined;
          SetShortSrc(ar, src);
        end;
      end;
      'l': begin
        line := -1;
        if (ci <> nil) and (p <> nil) then line := ProtoLineAt(p, ci^.SavedPC - 1);
        ar^.currentline := line;
      end;
      'u': begin
        if f.IsC then ar^.nups := Length(f.CVals) - 1 else ar^.nups := Length(p.UpvalDescs);
        if ar^.nups < 0 then ar^.nups := 0;
      end;
      'n': begin
        ar^.name := nil;
        ar^.namewhat := '';
        if haveCI then
        begin
          nm := '';
          nw := FuncNameFromCall(T, ar^.i_ci, nm);
          if nw <> '' then
          begin
            ar^.namewhat := PermStr(nw);
            ar^.name := PermStr(nm);
          end;
        end;
      end;
      'f': PushV(T, fv);
      'L': begin
        tbl := T.NewTable(0, 0);
        if p <> nil then
          for line := 0 to Length(p.LineInfo) - 1 do
            if p.LineInfo[line] >= 0 then TableSetInt(tbl, p.LineInfo[line], LuaBool(True));
        PushV(T, LuaTab(tbl));
      end;
    else
      Result := 0;
    end;
end;

function lua_getlocal(L: Plua_State; const ar: Plua_Debug; n: Integer): PAnsiChar; cdecl;
var
  T: TLua;
  ci: PCallInfo;
  nm: string;
  limit: Integer;
begin
  T := TL(L);
  Result := nil;
  ci := FrameOf(T, ar);
  if (ci = nil) or (n <= 0) then Exit;
  nm := '';
  if not ci^.IsC then nm := LocalNameAt(ci^.Func.Proto, n, ci^.SavedPC - 1);
  if nm <> '' then
  begin
    PushV(T, T.Stack[ci^.Base + n - 1]);
    Exit(PermStr(nm));
  end;
  // temporaries up to the next frame
  if ar^.i_ci = T.NCI - 1 then limit := T.Top else limit := T.CI[ar^.i_ci + 1].FuncIdx;
  if limit - ci^.Base >= n then
  begin
    PushV(T, T.Stack[ci^.Base + n - 1]);
    if ci^.IsC then Result := '(*C temporary)' else Result := '(*temporary)';
  end;
end;

function lua_setlocal(L: Plua_State; const ar: Plua_Debug; n: Integer): PAnsiChar; cdecl;
var
  T: TLua;
  ci: PCallInfo;
  nm: string;
  limit: Integer;
begin
  T := TL(L);
  Result := nil;
  ci := FrameOf(T, ar);
  if (ci <> nil) and (n > 0) then
  begin
    nm := '';
    if not ci^.IsC then nm := LocalNameAt(ci^.Func.Proto, n, ci^.SavedPC - 1);
    if nm <> '' then
      Result := PermStr(nm)
    else
    begin
      if ar^.i_ci = T.NCI - 1 then limit := T.Top else limit := T.CI[ar^.i_ci + 1].FuncIdx;
      if limit - ci^.Base >= n then
        if ci^.IsC then Result := '(*C temporary)' else Result := '(*temporary)';
    end;
    if Result <> nil then CopyVal(@T.Stack[ci^.Base + n - 1], @T.Stack[T.Top - 1]);
  end;
  Dec(T.Top);
end;

function lua_getupvalue(L: Plua_State; funcindex: Integer; n: Integer): PAnsiChar; cdecl;
var
  T: TLua;
  v: TLuaValue;
begin
  T := TL(L);
  Result := nil;
  v := ValueAt(T, funcindex);
  if v.Vt <> vtFunc then Exit;
  if v.F.IsC then
  begin
    if (n < 1) or (n >= Length(v.F.CVals)) then Exit;
    PushV(T, v.F.CVals[n]);
    Result := '';
  end
  else
  begin
    if (n < 1) or (n > Length(v.F.Upvals)) then Exit;
    PushV(T, v.F.Upvals[n - 1].Get);
    Result := PermStr(UpvalName(v.F.Proto, n - 1));
  end;
end;

function lua_setupvalue(L: Plua_State; funcindex: Integer; n: Integer): PAnsiChar; cdecl;
var
  T: TLua;
  v: TLuaValue;
begin
  T := TL(L);
  Result := nil;
  v := ValueAt(T, funcindex);
  if v.Vt = vtFunc then
  begin
    if v.F.IsC then
    begin
      if (n >= 1) and (n < Length(v.F.CVals)) then
      begin
        CopyVal(@v.F.CVals[n], @T.Stack[T.Top - 1]);
        Result := '';
      end;
    end
    else if (n >= 1) and (n <= Length(v.F.Upvals)) then
    begin
      v.F.Upvals[n - 1].SetVal(T.Stack[T.Top - 1]);
      Result := PermStr(UpvalName(v.F.Proto, n - 1));
    end;
  end;
  if Result <> nil then Dec(T.Top);
end;

// ---- hooks: the interpreter calls a closure of ours, which calls the application's hook

function HookTrampoline(T: TLua): Integer;
var
  f: TFunction;
  ar: lua_Debug;
  ev: string;
  v: TLuaValue;
begin
  f := T.CI[T.NCI - 1].Func;
  FillChar(ar, SizeOf(ar), 0);
  v := ValueAt(T, 1);
  if v.Vt = vtStr then ev := string(v.S.Str) else ev := '';
  if ev = 'call' then ar.event := LUA_HOOKCALL
  else if ev = 'tail call' then ar.event := LUA_HOOKCALL
  else if ev = 'return' then ar.event := LUA_HOOKRET
  else if ev = 'line' then ar.event := LUA_HOOKLINE
  else ar.event := LUA_HOOKCOUNT;
  v := ValueAt(T, 2);
  if v.Vt = vtInt then ar.currentline := Integer(v.I) else ar.currentline := -1;
  ar.i_ci := T.NCI - 2;      // the function that triggered the hook
  lua_Hook(f.CVals[0].P)(Plua_State(T), @ar);
  Result := 0;
end;

function lua_sethook(L: Plua_State; func: lua_Hook; mask: Integer; count: Integer): Integer; cdecl;
var
  T: TLua;
  f: TFunction;
  nilv: TLuaValue;
begin
  T := TL(L);
  if (@func = nil) or (mask = 0) then
  begin
    nilv.Vt := vtNil;
    SetHookState(T, nilv, 0, 0);
    Exit(1);
  end;
  f := T.NewCFunction(@HookTrampoline, 1);
  f.CVals[0].Vt := vtLight;
  f.CVals[0].P := Pointer(func);
  // the closure must stay alive while installed: keep it in the registry
  TableSetStr(T.Registry, StrKey(T, '_LUAP_HOOK'), LuaFunc(f));
  SetHookState(T, LuaFunc(f), mask and 15, count);
  Result := 1;
end;

function lua_gethookmask(L: Plua_State): Integer; cdecl;
begin
  Result := TL(L).HookMask and 15;
end;

function lua_gethookcount(L: Plua_State): Integer; cdecl;
begin
  Result := TL(L).HookCount;
end;

end.
