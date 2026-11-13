program LspTextSmoke;

{
  The server's TEXT units, tested without a server: PasLsp.Protocol's URI and
  position conversions and PasLsp.XmlDoc's doc-comment rendering.

  WHY A HARNESS OF ITS OWN. Both units are pure functions over strings, and
  neither one had any coverage at all - which is how a doc comment that spells
  `<` correctly ended up wrong in BOTH hint windows, and how a sentence
  containing `0 < Count and Count > Max` silently lost five of its words. A
  bug in this layer reaches a user as "the hint shows the wrong text", with no
  log line and nothing to reproduce from, so it belongs here where a wrong
  string is a failed check.

  Win32 like every harness in this directory (and Win64 as well whenever the
  64-bit IDE's package is built), and that costs nothing: these two units link
  the RTL and nothing else. (PasLsp.XmlDoc is compiled into the Win64 server;
  the code under test is the same code either way.)

  Usage: LspTextSmoke.exe   (no arguments; exits non-zero on failure)
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.JSON,
  PasLsp.Protocol,
  PasLsp.XmlDoc,
  PasTreeIdePlugin.DirectiveText,
  PasTreeIdePlugin.TokenShift,
  PasTreeIdePlugin.ConfigSwitch,
  PasTreeIdePlugin.FormatText;

var
  GFailures: Integer;

procedure Check(ACondition: Boolean; const AName: string);
begin
  if ACondition then
    Writeln('  [ok]   ', AName)
  else
  begin
    Writeln('  [FAIL] ', AName);
    Inc(GFailures);
  end;
end;

procedure CheckEq(const AGot, AWant, AName: string);
begin
  if AGot = AWant then
    Writeln('  [ok]   ', AName)
  else
  begin
    Writeln('  [FAIL] ', AName);
    Writeln('           want: ', AWant);
    Writeln('           got:  ', AGot);
    Inc(GFailures);
  end;
end;

procedure TestUri;
const
  // U+1F600, as a surrogate pair - one character, two UTF-16 code units.
  cEmoji = #$D83D#$DE00;
var
  LPath: string;
begin
  Writeln('URIs');

  // The case of the drive letter is passed through, not normalised - PathToUri
  // is the end that lower-cases it (VS Code's canonical form).
  CheckEq(UriToPath('file:///c%3A/dir/file.pas'), 'c:\dir\file.pas',
    'a percent-encoded drive letter decodes and the slashes turn round');
  CheckEq(UriToPath('file:///c:/dir/file.pas'), 'c:\dir\file.pas',
    'an unencoded colon is accepted too');
  CheckEq(UriToPath('http://example.com/x.pas'), '',
    'a non-file URI is refused rather than guessed at');
  CheckEq(UriToPath('file://server/share/x.pas'), '\\server\share\x.pas',
    'a UNC authority becomes a UNC path');

  // The round trip a client actually exercises: our own PathToUri output must
  // come back as the path we started from, or a definition answer names a
  // document the editor does not recognise.
  LPath := 'C:\Repos\проект\DemoUnit.pas';
  CheckEq(UriToPath(PathToUri(LPath)), LowerCase(LPath[1]) + Copy(LPath, 2,
    MaxInt),
    'a Cyrillic path round-trips through PathToUri (drive letter lowercased)');
  LPath := 'C:\Repos\x' + cEmoji + '\DemoUnit.pas';
  CheckEq(UriToPath(PathToUri(LPath)), LowerCase(LPath[1]) + Copy(LPath, 2,
    MaxInt),
    'and so does a path with a non-BMP character');

  { THE UNESCAPED CASE, which is the one that was broken: the spec tolerates
    raw non-ASCII in a URI and some clients send it, and the decoder walked the
    string one UTF-16 code unit at a time - so each half of a surrogate pair
    was encoded on its own, which is invalid UTF-16, and the RTL turned it into
    U+FFFD bytes. The path then matched no file, silently. }
  CheckEq(UriToPath('file:///c:/x' + cEmoji + '/a.pas'),
    'c:\x' + cEmoji + '\a.pas',
    'an unescaped non-BMP character survives the decode intact');
end;

procedure TestXmlDocEntities;
var
  LParts: TXmlDocParts;
begin
  Writeln;
  Writeln('XMLDoc: entities');

  { `&lt;` is the ONLY correct way to write a literal '<' in a doc comment, so
    every properly written comment containing one goes through here. The parser
    unescapes section text, which is what makes the plain emitter show the
    character and the HTML emitter escape it exactly once. Before that, the
    plain window showed `A &lt; B` verbatim and the HTML one double-escaped to
    `A &amp;lt; B`, which Help Insight rendered as the literal `A &lt; B`:
    wrong in both directions, for the same input. }
  LParts := ParseXmlDoc('<summary>A &lt; B &amp; C</summary>');
  CheckEq(LParts.Summary, 'A < B & C',
    'the parser unescapes entities into real characters');
  CheckEq(XmlDocDisplayText('<summary>A &lt; B &amp; C</summary>'),
    'A < B & C',
    'the plain emitter shows the characters, not the entities');
  Check(XmlDocHtml('<summary>A &lt; B &amp; C</summary>').Contains('A &lt; B')
    and not XmlDocHtml('<summary>A &lt; B</summary>').Contains('&amp;lt;'),
    'the HTML emitter escapes them exactly once');

  CheckEq(ParseXmlDoc('<summary>&#65;&quot;&apos;</summary>').Summary,
    'A"''', 'numeric and quote entities decode too');
  CheckEq(ParseXmlDoc('<summary>a &nosuch; b</summary>').Summary,
    'a &nosuch; b',
    'an unknown entity is left alone rather than eaten');
end;

procedure TestXmlDocProse;
var
  LParts: TXmlDocParts;
begin
  Writeln;
  Writeln('XMLDoc: a raw ''<'' in prose');

  { The unit header promises that a parse error never costs the user the text.
    A raw '<' with any later '>' in the block used to be treated as a tag, and
    everything between them was dropped as an unknown tag's body - so this
    entirely ordinary sentence lost five words and read "True when 0 Max". }
  LParts := ParseXmlDoc(
    '<summary>True when 0 < Count and Count > Max</summary>');
  CheckEq(LParts.Summary, 'True when 0 < Count and Count > Max',
    'a comparison in prose keeps every word');
  CheckEq(ParseXmlDoc('<summary>a < b</summary>').Summary, 'a < b',
    'an unterminated ''<'' is prose (it always was)');
  // A CAPITALISED unknown name is prose, which is what makes a generic in
  // running text survive: Delphi types are capitalised, XMLDoc tags are not.
  CheckEq(ParseXmlDoc('<summary>List<Integer> of things</summary>').Summary,
    'List<Integer> of things',
    'a generic in running text is prose, not a tag called Integer');
  CheckEq(ParseXmlDoc('<summary>a <TFoo> here</summary>').Summary,
    'a <TFoo> here', 'and so is a bare type name in angle brackets');

  // And the liberal side of the deal still holds: real tags, known or not, are
  // still tags, and an unknown one still contributes its content.
  CheckEq(ParseXmlDoc('<summary>a <b>bold</b> c</summary>').Summary,
    'a bold c', 'a known inline tag is still a tag');
  CheckEq(ParseXmlDoc('<summary>a <weird>x</weird> c</summary>').Summary,
    'a x c', 'an unknown BARE tag is still a tag, and its content is kept');
  CheckEq(ParseXmlDoc('<summary>a <weird n="1">x</weird> c</summary>').Summary,
    'a x c', 'so is an unknown tag with an attribute');

  LParts := ParseXmlDoc('<param name="AIndex">0 < AIndex</param>');
  Check((Length(LParts.Params) = 1) and (LParts.Params[0].Name = 'AIndex') and
    (LParts.Params[0].Text = '0 < AIndex'),
    'and the sections themselves still parse around it');
end;

procedure TestPositions;
var
  LLine, LChar, LPasLine, LPasCol: Integer;
begin
  Writeln;
  Writeln('positions');

  LspToPasTree(0, 0, LPasLine, LPasCol);
  Check((LPasLine = 1) and (LPasCol = 1),
    'LSP (0,0) is PasTree (1,1)');
  PasTreeToLsp(1, 1, LLine, LChar);
  Check((LLine = 0) and (LChar = 0), 'and back again');
end;


{ The conditional-symbol locator behind the plugin's Ctrl+hover underline
  (PasTreeIdePlugin.DirectiveText). Covered here because its only other
  observer is a mouse over an IDE editor. }
procedure TestDirectiveSymbol;

  procedure CheckHit(const ALine: string; ACol: Integer;
    const AWant: string; const AName: string);
  var
    LFrom, LTo: Integer;
    LGot: string;
  begin
    if DirectiveNameAt(ALine, ACol, LFrom, LTo) then
      LGot := Copy(ALine, LFrom, LTo - LFrom)
    else
      LGot := '';
    CheckEq(LGot, AWant, AName);
  end;

const
  cIfDef = '  {$IFDEF DEBUG_FOO} // x';
  cIf = '{$IF Defined(MSWINDOWS) and not Declared(TFoo) and Defined( X_1 )}';
begin
  Writeln;
  Writeln('directive symbols');

  CheckHit(cIfDef, 11, 'DEBUG_FOO', '{$IFDEF X}: first char of the symbol');
  CheckHit(cIfDef, 19, 'DEBUG_FOO', '{$IFDEF X}: last char of the symbol');
  CheckHit(cIfDef, 20, '', '{$IFDEF X}: the closing brace is not the symbol');
  CheckHit(cIfDef, 6, '', '{$IFDEF X}: the keyword is not the symbol');
  CheckHit(cIfDef, 24, '', 'outside the directive');
  CheckHit('{$ifndef foo}', 11, 'foo', 'lower-case keyword');
  CheckHit('{$DEFINE A}{$UNDEF B}', 10, 'A', 'two directives on a line: first');
  CheckHit('{$DEFINE A}{$UNDEF B}', 20, 'B', 'two directives on a line: second');
  CheckHit('(*$IFDEF PAREN*) x', 12, 'PAREN', '(*$ ... *) spelling');
  CheckHit('{$I foo.inc}', 5, '', '{$I} is not a conditional');
  CheckHit('{$IFOPT R+}', 8, '', '{$IFOPT} is not a conditional');
  CheckHit('{$ENDIF}', 4, '', '{$ENDIF} is not a conditional');
  CheckHit('{$ELSE}', 4, '', '{$ELSE} is not a conditional');
  CheckHit('{$IFDEF FOO', 10, '', 'unterminated on this line');
  CheckHit('{ $IFDEF FOO }', 9, '', 'a comment that is not a directive');
  CheckHit(cIf, 16, 'MSWINDOWS', '{$IF Defined(X)}');
  CheckHit(cIf, 42, 'TFoo', '{$IF ...} a Declared(T) argument is a name');
  CheckHit(cIf, 61, 'X_1', '{$IF ...} Defined( X ) with spaces');
  CheckHit(cIf, 8, '', '{$IF ...} the callee Defined is not a name');
  CheckHit(cIf, 33, '', '{$IF ...} nor is the callee Declared');
  CheckHit(cIf, 25, '', '{$IF ...} nor an operator word');
  CheckHit('{$ELSEIF Defined(B)}', 18, 'B', '{$ELSEIF Defined(X)}');
  CheckHit('{$IF FOO > 1}', 6, 'FOO', '{$IF} a bare constant is a name');
  CheckHit('  {$IF COMPILERVERSION < 31}function X;', 10, 'COMPILERVERSION',
    '{$IF CompilerVersion < N}');
end;

{ The `inherited` keyword as the plugin's own Ctrl+Click and Ctrl+hover link
  find it (PasTreeIdePlugin.DirectiveText.InheritedKeywordAt) - the IDE never
  asks the Insight Provider about a reserved word. }
procedure TestInheritedKeyword;

  procedure CheckHit(const ALine: string; ACol: Integer;
    const AWant: string; const AName: string);
  var
    LFrom, LTo: Integer;
    LGot: string;
  begin
    if InheritedKeywordAt(ALine, ACol, LFrom, LTo) then
      LGot := Copy(ALine, LFrom, LTo - LFrom)
    else
      LGot := '';
    CheckEq(LGot, AWant, AName);
  end;

const
  cBare = '  inherited;';
  cNamed = '  Result := inherited IsValid(A, ''inherited'') // inherited';
begin
  Writeln;
  Writeln('inherited keyword');

  CheckHit(cBare, 3, 'inherited', 'bare: first char');
  CheckHit(cBare, 11, 'inherited', 'bare: last char');
  CheckHit(cBare, 12, '', 'bare: the semicolon is not the keyword');
  CheckHit(cNamed, 15, 'inherited', 'named: on the keyword');
  CheckHit(cNamed, 26, '', 'named: the method name is not the keyword');
  CheckHit(cNamed, 40, '', 'in a string');
  CheckHit(cNamed, 55, '', 'after //');
  CheckHit('  INHERITED Create;', 5, 'INHERITED', 'upper case');
  CheckHit('{ inherited } inherited;', 4, '', 'in a brace comment');
  CheckHit('{ inherited } inherited;', 16, 'inherited', 'after a brace comment');
  CheckHit('(* inherited *)', 5, '', 'in a (* *) comment');
  CheckHit('  X.&inherited;', 7, '', '&inherited is an identifier');
  CheckHit('  inheritedX;', 4, '', 'a longer identifier');
end;
{ PasTreeIdePlugin.TokenShift: the last tokens answer carried onto the text
  on screen. The base is what the answer describes; each case is a line as
  the editor holds it now, and where the TList token (row 5, [12, 17)) is
  painted - or that it is not, when the edit touched it. }
procedure TestTokenShift;
const
  cField = '    FData: TList;';
var
  LBase: TArray<string>;
  LHint: Integer;

  // Where the TList token lands on ACurrent, painted as row ARow; -1 when
  // it is left out.
  function Lands(ARow: Integer; const ACurrent: string;
    var AHint: Integer): Integer;
  var
    LShift: TLineShift;
    LFrom, LTo: Integer;
  begin
    Result := -1;
    LShift := ShiftForLine(LBase, ARow, ACurrent, AHint);
    if (LShift.BaseRow = 5) and
       ShiftToken(LShift, ACurrent, 12, 17, LFrom, LTo) and
       (LTo - LFrom = 5) then
      Result := LFrom;
  end;

  procedure CheckLands(ARow: Integer; const ACurrent: string; AWant: Integer;
    const AName: string);
  var
    LOwnHint: Integer;
  begin
    LOwnHint := 0;
    Check(Lands(ARow, ACurrent, LOwnHint) = AWant, AName);
  end;

var
  LShift: TLineShift;
  LFrom, LTo: Integer;
begin
  Writeln('--- TokenShift');
  LBase := SplitBaseLines('unit U;'#13#10'interface'#13#10'type'#13#10 +
    '  TFoo = class'#13#10 + cField + #13#10'  end;'#13#10#13#10 +
    'implementation'#13#10'end.');
  Check((Length(LBase) = 9) and (LBase[4] = cField) and (LBase[6] = ''),
    'SplitBaseLines: CRLF lines, the CR dropped, the blank line kept');

  CheckLands(5, cField, 12, 'an unchanged line paints where it was');
  CheckLands(5, '    FXData: TList;', 13,
    'a character typed in front moves the type name right');
  CheckLands(5, '    FData:  TList;', 13, 'so does a space');
  CheckLands(5, '    Data: TList;', 11, 'a deletion in front moves it left');
  CheckLands(5, '    FData: TList; // note', 12,
    'typing after it leaves it where it was');
  CheckLands(5, '    FData: XTList;', -1,
    'a letter typed against its start makes another name: left out');
  CheckLands(5, '    FData: TListX;', -1,
    'a letter typed against its end: left out');
  CheckLands(5, '    FData: TLiist;', -1, 'an edit inside it: left out');
  CheckLands(5, '    Total := Count + 1;', -1,
    'a line with nothing in common paints no token of its base line');

  // A line inserted above: the field is now row 6, and the pass's offset
  // carries the rows below it.
  LHint := 0;
  Check(Lands(6, cField, LHint) = 12,
    'a line moved down by an insertion above is found by its text');
  Check(LHint = -1, 'and the pass remembers the offset');
  LShift := ShiftForLine(LBase, 7, '  end;', LHint);
  Check(LShift.Same and (LShift.BaseRow = 6),
    'the next line is tried at that offset first');
  LHint := -1;
  Check(Lands(6, '    FXData: TList;', LHint) = 13,
    'an edited line below an insertion maps through the pass''s offset');

  LHint := 3;
  LShift := ShiftForLine(LBase, 7, '   ', LHint);
  Check((LShift.BaseRow = 0) and (LHint = 3),
    'a blank line paints nothing and does not move the offset');
  LHint := 0;
  LShift := ShiftForLine(LBase, 40, 'begin', LHint);
  Check(LShift.BaseRow = 0, 'a row past the base text paints nothing');

  // The suffix never reaches into the prefix.
  LHint := 0;
  LShift := ShiftForLine(['aa'], 1, 'aaa', LHint);
  Check((LShift.Prefix = 2) and (LShift.Suffix = 0) and (LShift.Delta = 1),
    'aa -> aaa is one insertion after the common prefix');
  Check(not ShiftToken(LShift, 'aaa', 1, 3, LFrom, LTo),
    'and a token the insertion extends is left out');

  // ShiftSpan: an inactive line's stretch survives an edit inside it.
  LHint := 0;
  LShift := ShiftForLine(['  Log(''dead'');'], 1, '  Log(''dead'');', LHint);
  Check(ShiftSpan(LShift, '  Log(''dead'');', 1, 15, LFrom, LTo) and
    (LFrom = 1) and (LTo = 15), 'ShiftSpan: an unchanged line keeps its span');
  LHint := 0;
  LShift := ShiftForLine(['  Log(''dead'');'], 1, '  Log(''dead!'');', LHint);
  Check(ShiftSpan(LShift, '  Log(''dead!'');', 1, 15, LFrom, LTo) and
    (LFrom = 1) and (LTo = 16),
    'ShiftSpan: typing inside a dead line stretches its span over the edit');
  LHint := 0;
  LShift := ShiftForLine(['  X := 1; {$ENDIF}'], 1,
    '  X := 1; {$ENDIF} // n', LHint);
  Check(ShiftSpan(LShift, '  X := 1; {$ENDIF} // n', 1, 11, LFrom, LTo) and
    (LFrom = 1) and (LTo = 11),
    'ShiftSpan: typing after a span that ends mid-line leaves it in place');
  LHint := 0;
  LShift := ShiftForLine(['{$ELSE} Y := 2;'], 1, '{$ELSE}  Y := 2;', LHint);
  Check(ShiftSpan(LShift, '{$ELSE}  Y := 2;', 9, 16, LFrom, LTo) and
    (LFrom = 9) and (LTo = 17),
    'ShiftSpan: an insertion at a span''s start goes into the span');
  LHint := 0;
  LShift := ShiftForLine(['abcdef'], 1, 'abXYZef', LHint);
  Check(not ShiftSpan(LShift, 'abXYZef', 4, 6, LFrom, LTo),
    'ShiftSpan: a span whose start the edit replaced is left out');
end;

{ The configuration switch watch's debounce (PasTreeIdePlugin.ConfigSwitch):
  a switch restarts only once it has held, a switch back restarts nothing, a
  pass over several restarts once. }
procedure TestConfigSwitch;
var
  LWatch: TConfigSwitchWatch;
  LDebug, LRelease, LProfile, LDebug64: string;
begin
  Writeln('--- ConfigSwitch');
  LDebug := ConfigSwitchKey('Debug', 'Win32');
  LRelease := ConfigSwitchKey('Release', 'Win32');
  LProfile := ConfigSwitchKey('Profile', 'Win32');
  LDebug64 := ConfigSwitchKey('Debug', 'Win64');
  LWatch := Default(TConfigSwitchWatch);

  Check(LWatch.Observe(LDebug, LDebug, 1000) = csSame,
    'the server runs the selection: nothing to do');
  Check(LWatch.Observe(LDebug, ConfigSwitchKey('debug', 'WIN32'), 1000) = csSame,
    'compared without case, as EnsureSession compares');

  Check(LWatch.Observe(LDebug, LRelease, 2000) = csWaiting,
    'a new selection waits');
  Check(LWatch.Observe(LDebug, LRelease, 2000 + cConfigSwitchHoldMs - 1)
    = csWaiting, 'and keeps waiting until it has held');
  Check(LWatch.Observe(LDebug, LRelease, 2000 + cConfigSwitchHoldMs)
    = csRestart, 'held: restart');
  Check(LWatch.Observe(LDebug, LRelease, 2000 + cConfigSwitchHoldMs + 300)
    = csWaiting, 'a restart is answered once - the watch starts over');

  LWatch.Reset;
  Check(LWatch.Observe(LDebug, LRelease, 5000) = csWaiting,
    'Debug -> Release ...');
  Check(LWatch.Observe(LDebug, LDebug, 5000 + cConfigSwitchHoldMs - 1)
    = csSame,
    '... -> Debug inside the hold: no restart');
  Check(LWatch.Observe(LDebug, LDebug, 9000) = csSame,
    'nor later');
  Check(LWatch.Observe(LDebug, LRelease, 9300) = csWaiting,
    'switching again starts a fresh hold');
  Check(LWatch.Observe(LDebug, LRelease, 9300 + cConfigSwitchHoldMs - 1)
    = csWaiting, 'not counted from the first switch');

  LWatch.Reset;
  Check(LWatch.Observe(LDebug, LRelease, 20000) = csWaiting,
    'a pass: Release ...');
  // Profile inside Release's hold, then waited out from Profile's start.
  Check(LWatch.Observe(LDebug, LProfile, 20000 + cConfigSwitchHoldMs - 1)
    = csWaiting, '... then Profile restarts the hold');
  Check(LWatch.Observe(LDebug, LProfile, 20000 + 2 * cConfigSwitchHoldMs - 2)
    = csWaiting, 'held from Profile, not from Release');
  Check(LWatch.Observe(LDebug, LProfile, 20000 + 2 * cConfigSwitchHoldMs - 1)
    = csRestart, 'one restart, for the last selection');

  LWatch.Reset;
  Check(LWatch.Observe(LDebug, LDebug64, 30000) = csWaiting,
    'a platform switch waits like a configuration switch');
  Check(LWatch.Observe(LDebug, LDebug64, 30000 + cConfigSwitchHoldMs)
    = csRestart, 'and restarts once held');

  CheckEq(ConfigSwitchWhat('Debug', 'Win32', 'Release', 'Win32'),
    'active configuration changed (Debug -> Release)', 'the line: configuration');
  CheckEq(ConfigSwitchWhat('Debug', 'Win32', 'Debug', 'Win64'),
    'active platform changed (Win32 -> Win64)', 'the line: platform');
  CheckEq(ConfigSwitchWhat('Debug', 'Win32', 'Release', 'Win64'),
    'active configuration and platform changed (Debug Win32 -> Release Win64)',
    'the line: both');
end;

{ PasTreeIdePlugin.FormatText: the options as the request carries them, and
  the server's LSP edits turned into edits of the buffer's UTF-8 bytes - a
  BOM before line 0, a two-byte character before an edit on its line, the
  refusals that keep a stale answer out of the buffer, and the caret's
  mapping through the edits. LspClientSmoke applies a real server's answer
  through the same functions. }
procedure TestFormatText;
var
  LJson: TJSONObject;
  LText: string;
  LBuf, LOut: UTF8String;
  LEdits: TArray<TFormatEdit>;
  LBytes: TArray<TFormatByteEdit>;
  LError: string;
  LValues: TFormatValues;

  function Edit(ALine, AChar, AEndLine, AEndChar: Integer;
    const AText: string): TFormatEdit;
  begin
    Result.Line := ALine;
    Result.Character := AChar;
    Result.EndLine := AEndLine;
    Result.EndCharacter := AEndChar;
    Result.Text := AText;
  end;

begin
  Writeln;
  Writeln('=== FormatText: request options and byte edits ===');
  LJson := FormatRequestOptions(DefaultFormatValues);
  try
    LText := LJson.ToJSON;
  finally
    LJson.Free;
  end;
  Check(LText.Contains('"tabSize":2') and LText.Contains('"insertSpaces":true'),
    'tabSize is the indent step, spaces');
  Check(LText.Contains('"IndentStep":2') and
    LText.Contains('"BeginOnNewLine":true') and
    LText.Contains('"StatementAfterThenDo":"Always"') and
    LText.Contains('"ReservedWordCase":"Lower"') and
    LText.Contains('"CompilerDirectiveCase":"Upper"') and
    LText.Contains('"IdentifierCase":false'),
    'every row by its field name, in the server''s shapes');
  LValues := DefaultFormatValues;
  LValues[FormatOptionIndex('IndentStep')] := 4;
  LValues[FormatOptionIndex('ReservedWordCase')] := 1;
  LJson := FormatRequestOptions(LValues);
  try
    LText := LJson.ToJSON;
  finally
    LJson.Free;
  end;
  Check(LText.Contains('"tabSize":4') and LText.Contains('"IndentStep":4')
    and LText.Contains('"ReservedWordCase":"Upper"'),
    'a changed step and a changed case are sent');
  // RightMargin 0 is the IDE's margin; a number in the row overrides it.
  LJson := FormatRequestOptions(DefaultFormatValues, 100);
  try
    LText := LJson.ToJSON;
  finally
    LJson.Free;
  end;
  Check(LText.Contains('"RightMargin":100'), 'RightMargin 0 sends the IDE''s margin');
  LValues := DefaultFormatValues;
  LValues[FormatOptionIndex('RightMargin')] := 132;
  LJson := FormatRequestOptions(LValues, 100);
  try
    LText := LJson.ToJSON;
  finally
    LJson.Free;
  end;
  Check(LText.Contains('"RightMargin":132'), 'a RightMargin of its own overrides the IDE''s');
  LJson := FormatRequestOptions(DefaultFormatValues);
  try
    LText := LJson.ToJSON;
  finally
    LJson.Free;
  end;
  Check(LText.Contains('"RightMargin":0'), 'no IDE margin given: 0, the library''s');

  // BOM + `S := 'Zh';  Y := 1;` CRLF `    Z;` - Zh is one UTF-16 unit and
  // two UTF-8 bytes, so the first edit's character 9 is byte 3 + 10.
  LBuf := UTF8String(#$FEFF + 'S := ''' + #$0416 + ''';  Y := 1;'#13#10'    Z;');
  LEdits := [Edit(0, 9, 0, 11, #13#10), Edit(1, 0, 1, 4, '  ')];
  Check(FormatByteEdits(LBuf, LEdits, LBytes, LError), 'the edits fit: ' + LError);
  Check((Length(LBytes) = 2) and (LBytes[0].Start = 13) and (LBytes[0].Stop = 15)
    and (LBytes[1].Start = 24) and (LBytes[1].Stop = 28),
    'byte offsets: after the BOM and the two-byte character');
  LOut := ApplyFormatByteEdits(LBuf, LBytes);
  Check(LOut = UTF8String(#$FEFF + 'S := ''' + #$0416 + ''';'#13#10 +
    'Y := 1;'#13#10'  Z;'), 'applied: the line split, the indent shrunk');
  Check(MapOffsetThroughEdits(14, LBytes) = 15,
    'a caret inside a re-laid gap lands on the token after it');
  Check(MapOffsetThroughEdits(13, LBytes) = 13,
    'a caret at a gap''s start stays after the token before');
  Check(MapOffsetThroughEdits(28, LBytes) = 26,
    'a caret after an edit moves by its difference');

  Check(not FormatByteEdits(LBuf, [Edit(0, 9, 0, 12, ' ')], LBytes, LError)
    and LError.Contains('not whitespace'),
    'an edit over code is refused - the buffer moved');
  Check(FormatByteEdits(LBuf, [Edit(0, 0, 0, 1, 's')], LBytes, LError) and
    (LBytes[0].Start = 3) and (LBytes[0].Stop = 4),
    'a word''s case is the formatter''s too (ReservedWordCase) - accepted');
  Check(not FormatByteEdits(LBuf, [Edit(0, 0, 0, 1, 'T')], LBytes, LError),
    'another word is not a case change - refused');
  Check(not FormatByteEdits(LBuf, [Edit(1, 0, 1, 4, ''), Edit(0, 9, 0, 11, '')],
    LBytes, LError), 'edits out of order are refused');
  Check(not FormatByteEdits(LBuf, [Edit(5, 0, 5, 1, '')], LBytes, LError),
    'an edit past the last line is refused');
  Check(FormatByteEdits(LBuf, nil, LBytes, LError) and (Length(LBytes) = 0),
    'no edits: nothing to apply');
end;

{ Derive from project: an answer of pastree/inferFormatOptions read over the
  page's values - a decided option replaces its row (a number, a Boolean, a
  choice by its server name), one without a note keeps the page's value, and
  an answer that read no unit changes nothing. }
procedure TestFormatInference;
var
  LJson: TJSONValue;
  LBase: TFormatValues;
  LResult: TFormatInference;
begin
  Writeln;
  Writeln('=== FormatText: Derive from project ===');
  LBase := DefaultFormatValues;
  LBase[FormatOptionIndex('TabWidth')] := 4;
  LJson := TJSONObject.ParseJSONValue('{"options":{"IndentStep":4,' +
    '"TabWidth":8,"BeginOnNewLine":false,"ReservedWordCase":"Upper"},' +
    '"notes":[{"option":"IndentStep","value":"4","evidence":"98%",' +
    '"mixed":false},{"option":"BeginOnNewLine","value":"off","evidence":' +
    '"60%","mixed":true},{"option":"ReservedWordCase","value":"upper",' +
    '"evidence":"99%","mixed":false},{"option":"SomeNewOption","value":"on",' +
    '"evidence":"x","mixed":false}],"files":3,"skipped":1,"total":5,' +
    '"lines":100,"ms":1200}');
  try
    LResult := ParseFormatInference(LJson, LBase);
  finally
    LJson.Free;
  end;
  Check(LResult.Ok and (LResult.Files = 3) and (LResult.Total = 5),
    'the answer is read: ' + LResult.Error);
  Check((LResult.Values[FormatOptionIndex('IndentStep')] = 4) and
    (LResult.Values[FormatOptionIndex('BeginOnNewLine')] = 0) and
    (LResult.Values[FormatOptionIndex('ReservedWordCase')] = 1),
    'decided rows take the answer''s values');
  Check(LResult.Values[FormatOptionIndex('TabWidth')] = 4,
    'a row with no note keeps the page''s value');
  Check(LResult.Changed = 3, Format('three rows changed (%d)',
    [LResult.Changed]));
  Check(LResult.Report.Contains('(mixed: kept as written)') and
    LResult.Report.Contains('SomeNewOption: on') and
    LResult.Report.Contains('1 skipped'),
    'the report says mixed, an unknown option and the skipped units');
  LJson := TJSONObject.ParseJSONValue('{"options":{"IndentStep":2},' +
    '"notes":[{"option":"IndentStep","value":"2"}],"files":0,"total":0}');
  try
    LBase[FormatOptionIndex('IndentStep')] := 3;
    LResult := ParseFormatInference(LJson, LBase);
  finally
    LJson.Free;
  end;
  Check(not LResult.Ok and (LResult.Values[FormatOptionIndex('IndentStep')] = 3)
    and (LResult.Changed = 0), 'no unit read: nothing changes');
  LResult := ParseFormatInference(nil, LBase);
  Check(not LResult.Ok and (LResult.Error <> ''), 'no answer: an error');
end;

begin
  GFailures := 0;
  TestUri;
  TestXmlDocEntities;
  TestXmlDocProse;
  TestPositions;
  TestDirectiveSymbol;
  TestInheritedKeyword;
  TestTokenShift;
  TestConfigSwitch;
  TestFormatText;
  TestFormatInference;

  Writeln;
  if GFailures = 0 then
    Writeln('RESULT: PASS')
  else
  begin
    Writeln(Format('RESULT: FAIL (%d checks failed)', [GFailures]));
    ExitCode := 1;
  end;
end.
