program runtests;

{$mode objfpc}{$H+}

// Runs the Lua test suite files with one or two interpreters and prints an ASCII
// comparison table: test file | ref lua | lure lua, each cell "pass (1.23s)".
//
//   runtests [-t seconds] [-d testdir] [-r ref-lua] [-l lure-lua] file.lua...
//
// A missing -r or -l column is shown as "n/a". Every test runs from the test
// directory, with stdin connected to a pipe and with a 'lua' that names the
// interpreter under test first in PATH (main.lua and files.lua start 'lua'
// subprocesses through the shell).

uses
  {$ifdef unix}BaseUnix,{$endif}
  SysUtils, Classes, Process;

type
  TOutcome = (oSkipped, oPass, oFail, oTimeout);

  TResult = record
    Outcome: TOutcome;
    Seconds: Double;
  end;

  TInterpreter = record
    Name: string;
    Path: string;       // absolute path, '' when not available
    BinDir: string;     // directory with a 'lua' link to Path
    Passed, Failed: Integer;
    Total: Double;
  end;

var
  TestDir: string = '.';
  Timeout: Integer = 300;
  Interp: array[0..1] of TInterpreter;
  Files: TStringList;
  TempRoot: string;

procedure Usage;
begin
  WriteLn(StdErr, 'usage: runtests [-t seconds] [-d testdir] [-r ref-lua] [-l lure-lua] file.lua...');
  Halt(2);
end;

function Quote(const s: string): string;
begin
  Result := '''' + StringReplace(s, '''', '''\''''', [rfReplaceAll]) + '''';
end;

procedure SetupInterpreter(var it: TInterpreter; const name, path: string);
begin
  it.Name := name;
  it.Path := '';
  if (path <> '') and FileExists(path) then
  begin
    it.Path := ExpandFileName(path);
    it.BinDir := TempRoot + PathDelim + name;
    ForceDirectories(it.BinDir);
    fpSymlink(PChar(it.Path), PChar(it.BinDir + PathDelim + 'lua'));
  end;
end;

function RunTest(const it: TInterpreter; const testFile: string): TResult;
var
  p: TProcess;
  t0: QWord;
  cmd: string;
begin
  Result.Outcome := oSkipped;
  Result.Seconds := 0;
  if it.Path = '' then Exit;
  // 'BASHOPTS=xpg_echo' gives bash's echo the dash behaviour the tests assume
  cmd := 'echo x | env PATH=' + Quote(it.BinDir) + ':"$PATH" BASHOPTS=xpg_echo timeout ' +
         IntToStr(Timeout) + ' ' + Quote(it.Path) + ' ' + Quote(testFile) + ' >/dev/null 2>&1';
  p := TProcess.Create(nil);
  try
    p.Executable := '/bin/sh';
    p.Parameters.Add('-c');
    p.Parameters.Add(cmd);
    p.CurrentDirectory := TestDir;
    p.Options := [poWaitOnExit];
    t0 := GetTickCount64;
    p.Execute;
    Result.Seconds := (GetTickCount64 - t0) / 1000.0;
    case p.ExitStatus of
      0: Result.Outcome := oPass;
      124: Result.Outcome := oTimeout;
    else
      Result.Outcome := oFail;
    end;
  finally
    p.Free;
  end;
end;

function Cell(const r: TResult): string;
begin
  case r.Outcome of
    oSkipped: Result := 'n/a';
    oPass: Result := Format('pass (%.2fs)', [r.Seconds]);
    oFail: Result := Format('FAIL (%.2fs)', [r.Seconds]);
  else
    Result := Format('TIMEOUT (%.0fs)', [r.Seconds]);
  end;
end;

procedure PrintRow(const widths: array of Integer; const cols: array of string);
var
  i: Integer;
begin
  Write('|');
  for i := 0 to High(cols) do
    Write(' ', cols[i], StringOfChar(' ', widths[i] - Length(cols[i])), ' |');
  WriteLn;
end;

procedure PrintRule(const widths: array of Integer);
var
  i: Integer;
begin
  Write('+');
  for i := 0 to High(widths) do
    Write(StringOfChar('-', widths[i] + 2), '+');
  WriteLn;
end;

var
  i, k: Integer;
  arg: string;
  rows: array of array[0..2] of string;
  res: TResult;
  widths: array[0..2] of Integer;
  titles: array[0..2] of string = ('test file', 'ref lua', 'lure lua');
  refPath, lurePath: string;

begin
  Files := TStringList.Create;
  refPath := '';
  lurePath := '';
  i := 1;
  while i <= ParamCount do
  begin
    arg := ParamStr(i);
    if arg = '-t' then begin Inc(i); Timeout := StrToIntDef(ParamStr(i), 300); end
    else if arg = '-d' then begin Inc(i); TestDir := ParamStr(i); end
    else if arg = '-r' then begin Inc(i); refPath := ParamStr(i); end
    else if arg = '-l' then begin Inc(i); lurePath := ParamStr(i); end
    else if (arg <> '') and (arg[1] = '-') then Usage
    else Files.Add(arg);
    Inc(i);
  end;
  if Files.Count = 0 then Usage;

  // paths are resolved before the tests change the working directory
  TempRoot := GetTempDir(False) + 'runtests-' + IntToStr(GetProcessID);
  ForceDirectories(TempRoot);
  SetupInterpreter(Interp[0], 'ref', refPath);
  SetupInterpreter(Interp[1], 'lure', lurePath);

  SetLength(rows, Files.Count);
  for i := 0 to Files.Count - 1 do
  begin
    rows[i][0] := Files[i];
    for k := 0 to 1 do
    begin
      res := RunTest(Interp[k], Files[i]);
      rows[i][k + 1] := Cell(res);
      case res.Outcome of
        oPass: Inc(Interp[k].Passed);
        oFail, oTimeout: Inc(Interp[k].Failed);
      end;
      Interp[k].Total := Interp[k].Total + res.Seconds;
    end;
    WriteLn(StdErr, Format('%-16s ref: %-18s lure: %s', [Files[i], rows[i][1], rows[i][2]]));
  end;

  for k := 0 to 2 do
  begin
    widths[k] := Length(titles[k]);
    for i := 0 to High(rows) do
      if Length(rows[i][k]) > widths[k] then widths[k] := Length(rows[i][k]);
  end;
  SetLength(rows, Length(rows) + 1);
  rows[High(rows)][0] := 'passed / total';
  for k := 0 to 1 do
    if Interp[k].Path = '' then rows[High(rows)][k + 1] := 'n/a'
    else rows[High(rows)][k + 1] := Format('%d / %d (%.2fs)',
           [Interp[k].Passed, Interp[k].Passed + Interp[k].Failed, Interp[k].Total]);
  for k := 0 to 2 do
    if Length(rows[High(rows)][k]) > widths[k] then widths[k] := Length(rows[High(rows)][k]);

  PrintRule(widths);
  PrintRow(widths, titles);
  PrintRule(widths);
  for i := 0 to High(rows) - 1 do
    PrintRow(widths, rows[i]);
  PrintRule(widths);
  PrintRow(widths, rows[High(rows)]);
  PrintRule(widths);

  // clean up the temporary links
  for k := 0 to 1 do
    if Interp[k].Path <> '' then
    begin
      DeleteFile(Interp[k].BinDir + PathDelim + 'lua');
      RemoveDir(Interp[k].BinDir);
    end;
  RemoveDir(TempRoot);
  if Interp[1].Failed > 0 then Halt(1);
end.
