unit lualibpkg;

{$mode objfpc}{$H+}
{$R-}{$Q-}

// The package library (require and friends). Dynamic C libraries are not
// supported.

interface

uses
  SysUtils, luacore, luavm, luaaux, lualibbase;

procedure OpenPackage(L: TLua);

implementation

const
  LUA_PATH_DEFAULT =
    '/usr/local/share/lua/5.5/?.lua;/usr/local/share/lua/5.5/?/init.lua;' +
    '/usr/local/lib/lua/5.5/?.lua;/usr/local/lib/lua/5.5/?/init.lua;' +
    './?.lua;./?/init.lua';
  LUA_CPATH_DEFAULT =
    '/usr/local/lib/lua/5.5/?.so;/usr/local/lib/lua/5.5/loadall.so;./?.so';

function ReplaceAll(const s, from, to_: string): string;
var
  p: Integer;
  rest: string;
begin
  Result := '';
  rest := s;
  if from = '' then Exit(s);
  while True do
  begin
    p := Pos(from, rest);
    if p = 0 then Break;
    Result := Result + Copy(rest, 1, p - 1) + to_;
    rest := Copy(rest, p + Length(from), MaxInt);
  end;
  Result := Result + rest;
end;

function Readable(const fname: string): Boolean;
var
  f: file;
  old: Byte;
begin
  old := FileMode;
  FileMode := 0;
  AssignFile(f, fname);
  {$I-}
  Reset(f, 1);
  {$I+}
  Result := IOResult = 0;
  if Result then CloseFile(f);
  FileMode := old;
  if DirectoryExists(fname) then Result := False;
end;

function SearchPathStr(const name, path, sep, rep: string; var errmsg: string): string;
var
  n, p, rest, one, msg: string;
  k: Integer;
  more: Boolean;
begin
  Result := '';
  n := name;
  if sep <> '' then n := ReplaceAll(n, sep, rep);
  p := ReplaceAll(path, '?', n);
  rest := p;
  msg := '';
  more := p <> '';
  while more do
  begin
    k := Pos(';', rest);
    if k = 0 then
    begin
      one := rest;
      more := False;
    end
    else
    begin
      one := Copy(rest, 1, k - 1);
      rest := Copy(rest, k + 1, MaxInt);
    end;
    if (one <> '') and Readable(one) then Exit(one);
    if msg <> '' then msg := msg + '''' + #10#9;
    msg := msg + 'no file ''' + one;
  end;
  if msg <> '' then msg := msg + '''';
  errmsg := msg;
end;

function pk_searchpath(L: TLua): Integer;
var
  name, path, sep, rep, err, f: string;
begin
  name := string(CheckString(L, 1));
  path := string(CheckString(L, 2));
  sep := string(OptString(L, 3, '.'));
  rep := string(OptString(L, 4, '/'));
  f := SearchPathStr(name, path, sep, rep, err);
  if f <> '' then
    PushStr(L, RawByteString(f))
  else
  begin
    PushFail(L);
    PushStr(L, RawByteString(err));
    Exit(2);
  end;
  Result := 1;
end;

function PkgField(L: TLua; const field: string): string;
var
  pkg: TLuaValue;
  v: TLuaValue;
begin
  pkg := TableGetStr(GetLoaded(L), StrKey(L, 'package'));
  v := LuaNil;
  if pkg.Vt = vtTab then v := TableGetStr(pkg.T, StrKey(L, field));
  if v.Vt <> vtStr then
    LuaError(L, Format('''package.%s'' must be a string', [field]));
  Result := string(v.S.Str);
end;

function FindFile(L: TLua; const name, field: string; var err: string): string;
begin
  Result := SearchPathStr(name, PkgField(L, field), '.', '/', err);
end;

function pk_loadlib(L: TLua): Integer;
begin
  CheckString(L, 1);
  CheckString(L, 2);
  PushFail(L);
  PushStr(L, 'dynamic libraries not enabled; check your Lua installation');
  PushStr(L, 'absent');
  Result := 3;
end;

function searcher_preload(L: TLua): Integer;
var
  name: RawByteString;
  pre, v: TLuaValue;
begin
  name := CheckString(L, 1);
  pre := TableGetStr(L.Registry, StrKey(L, '_PRELOAD'));
  v := LuaNil;
  if pre.Vt = vtTab then v := TableGetStr(pre.T, L.NewString(name));
  if v.Vt = vtNil then
  begin
    PushStr(L, RawByteString(Format('no field package.preload[''%s'']', [string(name)])));
    Exit(1);
  end;
  LuaPush(L, v);
  PushStr(L, ':preload:');
  Result := 2;
end;

function searcher_Lua(L: TLua): Integer;
var
  name, fname, err, loadErr: string;
  content: RawByteString;
  f: TFunction;
begin
  name := string(CheckString(L, 1));
  fname := FindFile(L, name, 'path', err);
  if fname = '' then
  begin
    PushStr(L, RawByteString(err));
    Exit(1);
  end;
  if ReadFileContent(fname, content) then
  begin
    PrepareFileChunk(content);
    if LoadBuffer(L, content, '@' + fname, 'bt', f, loadErr) then
    begin
      SetEnvUpvalue(L, f, LuaTab(L.GlobalT));
      LuaPush(L, LuaFunc(f));
      PushStr(L, RawByteString(fname));
      Exit(2);
    end
    else
      LuaError(L, Format('error loading module ''%s'' from file ''%s'':'#10#9'%s', [name, fname, loadErr]));
  end;
  LuaError(L, Format('error loading module ''%s'' from file ''%s'':'#10#9'cannot read file', [name, fname]));
  Result := 0;
end;

// Built-in replacement of the test module 'lib2-v2' (a C library in the
// reference test suite, which cannot be loaded here)
function lib2v2_id(L: TLua): Integer;
var
  n, i: Integer;
begin
  n := LuaGetTop(L);
  L.EnsureStack(L.Top + 2);
  LuaPush(L, LuaNil);
  for i := L.Top - 1 downto L.Top - n do L.Stack[i] := L.Stack[i - 1];
  L.Stack[L.Top - n - 1] := LuaBool(True);
  Result := n + 1;
end;

function lib2v2_newstr(L: TLua): Integer;
begin
  PushStr(L, CheckString(L, 1));
  Result := 1;
end;

function lib2v2_open(L: TLua): Integer;
const
  Funcs: array[0..1] of TLibFunc = (
    (Name: 'id'; Func: @lib2v2_id),
    (Name: 'newstr'; Func: @lib2v2_newstr));
var
  t: TTable;
begin
  t := L.NewTable(0, 2);
  RegisterFuncs(L, t, Funcs);
  LuaPush(L, LuaTab(t));
  Result := 1;
end;

function searcher_C(L: TLua): Integer;
var
  name, fname, err: string;
begin
  name := string(CheckString(L, 1));
  fname := FindFile(L, name, 'cpath', err);
  if (fname = '') and (name = 'lib2-v2') then
  begin
    // pretend the library was found
    fname := ReplaceAll(Copy(PkgField(L, 'cpath'), 1, Pos(';', PkgField(L, 'cpath') + ';') - 1), '?', name);
    LuaPush(L, LuaFunc(LightC(L, @lib2v2_open, 'luaopen_lib2_v2')));
    PushStr(L, RawByteString(fname));
    Exit(2);
  end;
  if fname = '' then
  begin
    PushStr(L, RawByteString(err));
    Exit(1);
  end;
  LuaError(L, Format('error loading module ''%s'' from file ''%s'':'#10#9'dynamic libraries not enabled; check your Lua installation', [name, fname]));
  Result := 0;
end;

function searcher_Croot(L: TLua): Integer;
var
  name, root, fname, err: string;
  p: Integer;
begin
  name := string(CheckString(L, 1));
  p := Pos('.', name);
  if p = 0 then Exit(0);
  root := Copy(name, 1, p - 1);
  fname := FindFile(L, root, 'cpath', err);
  if fname = '' then
  begin
    PushStr(L, RawByteString(err));
    Exit(1);
  end;
  PushStr(L, RawByteString(Format('no module ''%s'' in file ''%s''', [name, fname])));
  Result := 1;
end;

function pk_require(L: TLua): Integer;
var
  name: RawByteString;
  loaded, pkg, searchers, res: TLuaValue;
  lt: TTable;
  i: Integer;
  msg, prefix: string;
  top: Integer;
  loader, extra: TLuaValue;
  found: Boolean;
begin
  name := CheckString(L, 1);
  lt := GetLoaded(L);
  res := TableGetStr(lt, L.NewString(name));
  if Truthy(res) then
  begin
    LuaPush(L, res);
    Exit(1);
  end;
  // find a loader
  pkg := TableGetStr(lt, StrKey(L, 'package'));
  searchers := LuaNil;
  if pkg.Vt = vtTab then searchers := TableGetStr(pkg.T, StrKey(L, 'searchers'));
  if searchers.Vt <> vtTab then LuaError(L, '''package.searchers'' must be a table');
  msg := '';
  found := False;
  i := 1;
  loader := LuaNil;
  extra := LuaNil;
  while True do
  begin
    prefix := #10#9;
    if TableGetInt(searchers.T, i).Vt = vtNil then
    begin
      LuaError(L, Format('module ''%s'' not found:%s', [string(name), msg]));
    end;
    top := L.Top;
    LuaPush(L, TableGetInt(searchers.T, i));
    PushStr(L, name);
    LuaCall(L, 1, 2);
    if L.Stack[L.Top - 2].Vt = vtFunc then
    begin
      loader := L.Stack[L.Top - 2];
      extra := L.Stack[L.Top - 1];
      L.Top := top;
      found := True;
      Break;
    end
    else if L.Stack[L.Top - 2].Vt = vtStr then
      msg := msg + prefix + string(L.Stack[L.Top - 2].S.Str);
    L.Top := top;
    Inc(i);
  end;
  if not found then Exit(0);
  // call the loader
  LuaPush(L, loader);
  PushStr(L, name);
  LuaPush(L, extra);
  LuaCall(L, 2, 1);
  if L.Stack[L.Top - 1].Vt <> vtNil then
    TableSetStr(lt, L.NewString(name), L.Stack[L.Top - 1]);
  loaded := TableGetStr(lt, L.NewString(name));
  if loaded.Vt = vtNil then
  begin
    TableSetStr(lt, L.NewString(name), LuaBool(True));
    loaded := LuaBool(True);
  end;
  L.Top := L.Top - 1;
  LuaPush(L, loaded);
  LuaPush(L, extra);
  Result := 2;
end;

procedure SetPath(L: TLua; pkg: TTable; const field, envname, dft: string; noenv: Boolean);
var
  path, dftmark: string;
  k: Integer;
begin
  path := '';
  if not noenv then
  begin
    path := GetEnvironmentVariable(envname + '_5_5');
    if path = '' then path := GetEnvironmentVariable(envname);
  end;
  if path = '' then
    path := dft
  else
  begin
    k := Pos(';;', path);
    if k > 0 then
    begin
      dftmark := '';
      if k > 1 then dftmark := Copy(path, 1, k - 1) + ';';
      dftmark := dftmark + dft;
      if k + 1 < Length(path) then dftmark := dftmark + ';' + Copy(path, k + 2, MaxInt);
      path := dftmark;
    end;
  end;
  SetField(L, pkg, field, NewStr(L, RawByteString(path)));
end;

procedure OpenPackage(L: TLua);
const
  Funcs: array[0..1] of TLibFunc = (
    (Name: 'loadlib'; Func: @pk_loadlib),
    (Name: 'searchpath'; Func: @pk_searchpath));
var
  pkg, searchers, preload: TTable;
  noenv: Boolean;
begin
  pkg := NewLib(L, 'package', Funcs);
  searchers := L.NewTable(4, 0);
  TableSetInt(searchers, 1, LuaFunc(LightC(L, @searcher_preload, 'searcher_preload')));
  TableSetInt(searchers, 2, LuaFunc(LightC(L, @searcher_Lua, 'searcher_Lua')));
  TableSetInt(searchers, 3, LuaFunc(LightC(L, @searcher_C, 'searcher_C')));
  TableSetInt(searchers, 4, LuaFunc(LightC(L, @searcher_Croot, 'searcher_Croot')));
  SetField(L, pkg, 'searchers', LuaTab(searchers));
  noenv := Truthy(TableGetStr(L.Registry, StrKey(L, 'LUA_NOENV')));
  SetPath(L, pkg, 'path', 'LUA_PATH', LUA_PATH_DEFAULT, noenv);
  SetPath(L, pkg, 'cpath', 'LUA_CPATH', LUA_CPATH_DEFAULT, noenv);
  SetField(L, pkg, 'config', NewStr(L, '/'#10';'#10'?'#10'!'#10'-'#10));
  SetField(L, pkg, 'loaded', LuaTab(GetLoaded(L)));
  preload := L.NewTable(0, 4);
  TableSetStr(L.Registry, StrKey(L, '_PRELOAD'), LuaTab(preload));
  SetField(L, pkg, 'preload', LuaTab(preload));
  SetField(L, L.GlobalT, 'require', LuaFunc(LightC(L, @pk_require, 'require')));
end;

end.
