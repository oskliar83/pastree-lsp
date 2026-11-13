unit PasTreeIdePlugin.FormatText;

{
  The IDE-free half of Format (Ctrl+D): the formatter's options as the
  plugin knows them, and the server's TextEdit[] turned into edits of the
  editor buffer's UTF-8 bytes. PasTreeIdePlugin.Format is the IDE half - the
  key, the request, the undoable writer. Pure functions over strings, so
  tests\LspTextSmoke checks them without an IDE and LspClientSmoke applies a
  real server's answer through them.

  THE OPTION TABLE (cFormatOptions) IS ONE LINE PER OPTION. The package
  cannot link PasTree (CLAUDE.md, the one hard invariant), so it cannot read
  TPasFormatOptions; it names the fields instead, and the server maps them
  by name through RTTI (PasLsp.Formatting). A field the library adds needs
  one line here (and the array's upper bound): the options page, the
  registry and the request all walk the table. LspClientSmoke compares the
  table with the server's pastree/formatOptions - a field the library has
  and this table lacks, or a default that differs, fails the build's test
  run rather than reaching a user as a missing option or a wrong default.

  A VALUE IS AN INTEGER for every kind: a Boolean 0 / 1, a choice the index
  of its name in Choices - so the settings store and the page need no case
  per kind beyond the control they draw.

  RIGHTMARGIN 0 IS THE IDE'S RIGHT MARGIN (Editor Options > Display), not
  "no margin" as in TPasFormatOptions: the margin a Delphi author already
  set is the one wrapping should keep, and the library's 0 made Wrap long
  lines a switch that did nothing until a second field was filled in.
  FormatRequestOptions takes the IDE's value from its caller (this unit is
  IDE-free) and sends it in place of a 0; a number in the row overrides it.
  The row's default stays 0, the library's, so the table check holds.

  THE EDITS. The server answers LSP positions - 0-based line, UTF-16
  character - over the text it was sent, which is the buffer without a
  leading BOM. An IOTAEditWriter addresses the buffer's UTF-8 BYTES, BOM
  included (ReadModuleBufferUtf8). FormatByteEdits converts one to the
  other over the buffer's bytes, and refuses the whole answer - nothing
  half-applied - when an edit runs backwards, overlaps the one before, or
  replaces anything but whitespace or a word by the same word in another
  case: the formatter only ever rewrites the whitespace between tokens and
  the case of a word (PasTree's docs/formatter.md sec. 1, 2a), so any other
  replacement means the buffer is not the text the answer was computed
  for. (The harness found the case half the hard way: the first cut of this
  check refused every `ReservedWordCase` edit.)
}

interface

uses
  System.SysUtils,
  System.JSON;

type
  TFormatOptionKind = (fokInteger, fokBoolean, fokChoice);

  TFormatOptionDef = record
    Name: string;      // the TPasFormatOptions field - the server's key
    Group: string;     // the options page's group box
    Caption: string;
    Kind: TFormatOptionKind;
    Default: Integer;  // a Boolean 0 / 1, a choice its index in Choices
    Choices: string;   // fokChoice: the server's value names, comma-separated
    MinValue: Integer; // fokInteger: the page's range
    MaxValue: Integer;
  end;

const
  cFormatIndentation = 'Indentation';
  cFormatLineBreaks = 'Line breaks';
  cFormatSpaces = 'Spaces';
  cFormatCase = 'Capitalization';
  cFormatWrap = 'Wrapping and alignment';
  cFormatDcu = 'Compiled units';
  cFormatCaseChoices = 'Lower,Upper,Keep';

  { TPasFormatOptions, field by field, with TPasFormatOptions.Default -
    PasTree's docs/formatter.md sec. 6. IdentifierCase is the server's own
    option (identifier case through the navigator), off by default, and so
    is FormatDcuText (a compiled unit's generated text in this style), on.
    The style reaches the server in each request, and in the
    initializationOptions for the .dcu text - which the analysis reads
    once, so a change there holds from the next server start. }
  cFormatOptions: array[0..24] of TFormatOptionDef = (
    (Name: 'IndentStep'; Group: cFormatIndentation; Caption: 'Indent step (spaces)'; Kind: fokInteger; Default: 2; MinValue: 1; MaxValue: 16),
    (Name: 'TabWidth'; Group: cFormatIndentation; Caption: 'Tab width when reading a tab-indented line'; Kind: fokInteger; Default: 8; MinValue: 1; MaxValue: 16),
    (Name: 'IndentNestedRoutines'; Group: cFormatIndentation; Caption: 'Indent nested routines'; Kind: fokBoolean; Default: 1),
    (Name: 'KeepDirectivesAtColumn1'; Group: cFormatIndentation; Caption: 'Keep compiler directives written in column 1 there'; Kind: fokBoolean; Default: 1),
    (Name: 'KeepCommentsAtColumn1'; Group: cFormatIndentation; Caption: 'Keep comments written in column 1 there'; Kind: fokBoolean; Default: 1),
    (Name: 'MaxBlankLines'; Group: cFormatLineBreaks; Caption: 'Blank lines kept in a row (-1: all)'; Kind: fokInteger; Default: 2; MinValue: -1; MaxValue: 10),
    (Name: 'BeginOnNewLine'; Group: cFormatLineBreaks; Caption: '"begin" on its own line'; Kind: fokBoolean; Default: 1),
    (Name: 'ElseOnNewLine'; Group: cFormatLineBreaks; Caption: '"else" on its own line, not after "end"'; Kind: fokBoolean; Default: 1),
    (Name: 'StatementAfterThenDo'; Group: cFormatLineBreaks; Caption: 'Statement after "then" / "do" / "else"'; Kind: fokChoice; Default: 0; Choices: 'Always,Keep'),
    (Name: 'OneStatementPerLine'; Group: cFormatLineBreaks; Caption: 'One statement per line'; Kind: fokBoolean; Default: 1),
    (Name: 'OneDeclPerLine'; Group: cFormatLineBreaks; Caption: 'One declaration per line, section words alone'; Kind: fokBoolean; Default: 1),
    (Name: 'NormalizeSpaces'; Group: cFormatSpaces; Caption: 'Normalize spaces inside a line'; Kind: fokBoolean; Default: 1),
    (Name: 'SpaceAroundOperators'; Group: cFormatSpaces; Caption: 'Space around ":=", operators and "="'; Kind: fokBoolean; Default: 1),
    (Name: 'SpaceAfterSeparators'; Group: cFormatSpaces; Caption: 'Space after ",", ";" and ":"'; Kind: fokBoolean; Default: 1),
    (Name: 'RemoveSpaces'; Group: cFormatSpaces; Caption: 'No space inside brackets, before "(" of a call, around "."'; Kind: fokBoolean; Default: 1),
    (Name: 'ReservedWordCase'; Group: cFormatCase; Caption: 'Reserved words'; Kind: fokChoice; Default: 0; Choices: cFormatCaseChoices),
    (Name: 'DirectiveWordCase'; Group: cFormatCase; Caption: 'Directives (override, read, ...)'; Kind: fokChoice; Default: 0; Choices: cFormatCaseChoices),
    (Name: 'CompilerDirectiveCase'; Group: cFormatCase; Caption: 'Compiler directive names ({$IFDEF})'; Kind: fokChoice; Default: 1; Choices: cFormatCaseChoices),
    (Name: 'IdentifierCase'; Group: cFormatCase; Caption: 'Identifiers as declared (waits for the analysis)'; Kind: fokBoolean; Default: 0),
    (Name: 'RightMargin'; Group: cFormatWrap; Caption: 'Right margin (0: the IDE''s Right margin)'; Kind: fokInteger; Default: 0; MinValue: 0; MaxValue: 400),
    (Name: 'WrapLongLines'; Group: cFormatWrap; Caption: 'Wrap a line longer than the right margin'; Kind: fokBoolean; Default: 0),
    (Name: 'AlignAssignments'; Group: cFormatWrap; Caption: 'Align ":=" of consecutive assignments'; Kind: fokBoolean; Default: 0),
    (Name: 'AlignDeclColons'; Group: cFormatWrap; Caption: 'Align ":" / "=" of consecutive declarations'; Kind: fokBoolean; Default: 0),
    (Name: 'AlignTrailingComments'; Group: cFormatWrap; Caption: 'Align comments that end consecutive lines'; Kind: fokBoolean; Default: 0),
    (Name: 'FormatDcuText'; Group: cFormatDcu; Caption: 'A .dcu''s generated source in this style (next server start)'; Kind: fokBoolean; Default: 1)
  );

type
  /// <summary>One value per cFormatOptions row, index for index.</summary>
  TFormatValues = TArray<Integer>;

  /// <summary>One TextEdit of the server's answer, LSP coordinates.</summary>
  TFormatEdit = record
    Line, Character, EndLine, EndCharacter: Integer;
    Text: string;
  end;

  /// <summary>The same edit over the buffer's UTF-8 bytes, 0-based, End
  /// exclusive - what CopyTo / DeleteTo / Insert take.</summary>
  TFormatByteEdit = record
    Start, Stop: Integer;
    Text: UTF8String;
  end;

function DefaultFormatValues: TFormatValues;

/// <summary>The row of AName in cFormatOptions, -1 when absent.</summary>
function FormatOptionIndex(const AName: string): Integer;

/// <summary>The choice names of a fokChoice row.</summary>
function FormatChoices(const ADef: TFormatOptionDef): TArray<string>;

/// <summary>
/// AValues as FormattingOptions members: tabSize (the indent step),
/// insertSpaces, and every row by its name in the server's shape - a number,
/// true / false, a choice's name. A RightMargin of 0 is sent as
/// AIdeRightMargin when that is above 0 (see the header). Caller owns the
/// object.
/// </summary>
function FormatRequestOptions(const AValues: TFormatValues;
  AIdeRightMargin: Integer = 0): TJSONObject;

type
  /// <summary>pastree/inferFormatOptions read for the options page.</summary>
  TFormatInference = record
    Ok: Boolean;
    Error: string;
    /// The page's values with every option the server decided replaced -
    /// one it has no note for (TabWidth, the column-1 rows, the server's own
    /// IdentifierCase and FormatDcuText) keeps the page's value.
    Values: TFormatValues;
    Changed: Integer;   // rows whose value differs from the page's
    /// One line per decided option, for the user: its caption, the value,
    /// what the project showed; a mixed one says it is kept as written.
    Report: string;
    Files, Skipped, Total, Ms: Integer;
  end;

/// <summary>
/// The answer of pastree/inferFormatOptions over ABase (the page's values
/// now). Ok False, ABase unchanged, for anything but that answer's shape.
/// </summary>
function ParseFormatInference(AResult: TJSONValue;
  const ABase: TFormatValues): TFormatInference;

/// <summary>The edits of a TextEdit[] answer; nil for anything else.</summary>
function ParseFormatEdits(AResult: TJSONValue): TArray<TFormatEdit>;

/// <summary>
/// AEdits over ABuffer's bytes (see the header). False, with AError, when
/// the answer cannot be applied as a whole.
/// </summary>
function FormatByteEdits(const ABuffer: UTF8String;
  const AEdits: TArray<TFormatEdit>; out AByteEdits: TArray<TFormatByteEdit>;
  out AError: string): Boolean;

/// <summary>ABuffer with AEdits applied - the writer's walk over a string.</summary>
function ApplyFormatByteEdits(const ABuffer: UTF8String;
  const AEdits: TArray<TFormatByteEdit>): UTF8String;

/// <summary>
/// Where byte AOffset of the old buffer is after AEdits: shifted by the edits
/// before it; strictly inside a replaced span, the end of its replacement - a
/// caret in a re-laid gap lands on the token after it; at a span's start it
/// stays where it is, after the token before.
/// </summary>
function MapOffsetThroughEdits(AOffset: Integer;
  const AEdits: TArray<TFormatByteEdit>): Integer;

implementation

function DefaultFormatValues: TFormatValues;
var
  LIdx: Integer;
begin
  SetLength(Result, Length(cFormatOptions));
  for LIdx := 0 to High(cFormatOptions) do
    Result[LIdx] := cFormatOptions[LIdx].Default;
end;

function FormatOptionIndex(const AName: string): Integer;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(cFormatOptions) do
    if SameText(cFormatOptions[LIdx].Name, AName) then
      Exit(LIdx);
  Result := -1;
end;

function FormatChoices(const ADef: TFormatOptionDef): TArray<string>;
begin
  Result := ADef.Choices.Split([',']);
end;

function FormatRequestOptions(const AValues: TFormatValues;
  AIdeRightMargin: Integer): TJSONObject;
var
  LIdx, LValue: Integer;
  LChoices: TArray<string>;
  LDef: TFormatOptionDef;
begin
  Result := TJSONObject.Create;
  LIdx := FormatOptionIndex('IndentStep');
  if (LIdx >= 0) and (LIdx < Length(AValues)) then
    Result.AddPair('tabSize', TJSONNumber.Create(AValues[LIdx]))
  else
    Result.AddPair('tabSize', TJSONNumber.Create(2));
  Result.AddPair('insertSpaces', TJSONBool.Create(True));
  for LIdx := 0 to High(cFormatOptions) do
  begin
    LDef := cFormatOptions[LIdx];
    if LIdx < Length(AValues) then
      LValue := AValues[LIdx]
    else
      LValue := LDef.Default;
    case LDef.Kind of
      fokInteger:
        begin
          if (LValue = 0) and (AIdeRightMargin > 0) and
             SameText(LDef.Name, 'RightMargin') then
            LValue := AIdeRightMargin;
          Result.AddPair(LDef.Name, TJSONNumber.Create(LValue));
        end;
      fokBoolean:
        Result.AddPair(LDef.Name, TJSONBool.Create(LValue <> 0));
      fokChoice:
        begin
          LChoices := FormatChoices(LDef);
          if (LValue < 0) or (LValue > High(LChoices)) then
            LValue := LDef.Default;
          Result.AddPair(LDef.Name, LChoices[LValue]);
        end;
    end;
  end;
end;

function ParseFormatInference(AResult: TJSONValue;
  const ABase: TFormatValues): TFormatInference;
var
  LOptions, LValue: TJSONValue;
  LNotes: TJSONArray;
  LNote: TJSONValue;
  LName, LText, LLine: string;
  LIdx, LChoice, LNew: Integer;
  LChoices: TArray<string>;
  LDef: TFormatOptionDef;
begin
  Result := Default(TFormatInference);
  Result.Values := Copy(ABase);
  if Length(Result.Values) < Length(cFormatOptions) then
  begin
    LIdx := Length(Result.Values);
    SetLength(Result.Values, Length(cFormatOptions));
    for LIdx := LIdx to High(cFormatOptions) do
      Result.Values[LIdx] := cFormatOptions[LIdx].Default;
  end;
  if not (AResult is TJSONObject) then
  begin
    Result.Error := 'no answer';
    Exit;
  end;
  LOptions := TJSONObject(AResult).GetValue('options');
  LValue := TJSONObject(AResult).GetValue('notes');
  if not (LOptions is TJSONObject) or not (LValue is TJSONArray) then
  begin
    Result.Error := 'not an answer of pastree/inferFormatOptions';
    Exit;
  end;
  LNotes := TJSONArray(LValue);
  Result.Files := AResult.GetValue<Integer>('files', 0);
  Result.Skipped := AResult.GetValue<Integer>('skipped', 0);
  Result.Total := AResult.GetValue<Integer>('total', 0);
  Result.Ms := AResult.GetValue<Integer>('ms', 0);
  for LNote in LNotes do
  begin
    if not (LNote is TJSONObject) then
      Continue;
    LName := LNote.GetValue<string>('option', '');
    LIdx := FormatOptionIndex(LName);
    LText := LNote.GetValue<string>('value', '') + ' - ' +
      LNote.GetValue<string>('evidence', '');
    if LNote.GetValue<Boolean>('mixed', False) then
      LText := LText + ' (mixed: kept as written)';
    if LIdx < 0 then
    begin
      // An option the library has and this table lacks: said, not set.
      Result.Report := Result.Report + LName + ': ' + LText + sLineBreak;
      Continue;
    end;
    LDef := cFormatOptions[LIdx];
    Result.Report := Result.Report + LDef.Caption + ': ' + LText + sLineBreak;
    LValue := TJSONObject(LOptions).GetValue(LDef.Name);
    if LValue = nil then
      Continue;
    LNew := Result.Values[LIdx];
    case LDef.Kind of
      fokInteger:
        if LValue is TJSONNumber then
          LNew := TJSONNumber(LValue).AsInt;
      fokBoolean:
        if LValue is TJSONBool then
          LNew := Ord(TJSONBool(LValue).AsBoolean);
      fokChoice:
        begin
          LChoices := FormatChoices(LDef);
          for LChoice := 0 to High(LChoices) do
            if SameText(LChoices[LChoice], LValue.Value) then
              LNew := LChoice;
        end;
    end;
    if LNew <> Result.Values[LIdx] then
      Inc(Result.Changed);
    Result.Values[LIdx] := LNew;
  end;
  LLine := Format('%d of the project''s %d units read in %.1f s',
    [Result.Files, Result.Total, Result.Ms / 1000]);
  if Result.Skipped > 0 then
    LLine := LLine + Format(', %d skipped (they do not parse clean)',
      [Result.Skipped]);
  Result.Report := LLine + '.' + sLineBreak + sLineBreak + Result.Report;
  Result.Ok := Result.Files > 0;
  if not Result.Ok then
  begin
    // Nothing read: every option came back as its default, which is no
    // finding about the project.
    Result.Error := 'no unit of the project could be read';
    Result.Values := Copy(ABase);
    Result.Changed := 0;
  end;
end;

function ParseFormatEdits(AResult: TJSONValue): TArray<TFormatEdit>;
var
  LValue: TJSONValue;
  LEdit: TFormatEdit;
begin
  Result := nil;
  if not (AResult is TJSONArray) then
    Exit;
  for LValue in TJSONArray(AResult) do
  begin
    if not (LValue is TJSONObject) then
      Continue;
    LEdit.Line := LValue.GetValue<Integer>('range.start.line', -1);
    LEdit.Character := LValue.GetValue<Integer>('range.start.character', -1);
    LEdit.EndLine := LValue.GetValue<Integer>('range.end.line', -1);
    LEdit.EndCharacter := LValue.GetValue<Integer>('range.end.character', -1);
    LEdit.Text := LValue.GetValue<string>('newText', '');
    Result := Result + [LEdit];
  end;
end;

{ The byte offset of each line's start, after a leading BOM - lines split on
  CRLF, LF or a lone CR, as the server splits them. }
function ByteLineStarts(const ABuffer: UTF8String): TArray<Integer>;
var
  LIdx, LLen, LCount: Integer;
begin
  LLen := Length(ABuffer);
  SetLength(Result, 16);
  if (LLen >= 3) and (Ord(ABuffer[1]) = $EF) and (Ord(ABuffer[2]) = $BB) and
     (Ord(ABuffer[3]) = $BF) then
    Result[0] := 3
  else
    Result[0] := 0;
  LCount := 1;
  LIdx := Result[0] + 1;
  while LIdx <= LLen do
  begin
    if (ABuffer[LIdx] = #13) or (ABuffer[LIdx] = #10) then
    begin
      if (ABuffer[LIdx] = #13) and (LIdx < LLen) and (ABuffer[LIdx + 1] = #10) then
        Inc(LIdx);
      if LCount = Length(Result) then
        SetLength(Result, LCount * 2);
      Result[LCount] := LIdx;   // 1-based index of the break's last byte
      Inc(LCount);
    end;
    Inc(LIdx);
  end;
  SetLength(Result, LCount);
end;

{ The byte offset of (ALine, AChar) - AChar in UTF-16 units - or -1 when
  the line does not exist or the character runs past its end. }
function ByteOffsetOf(const ABuffer: UTF8String;
  const AStarts: TArray<Integer>; ALine, AChar: Integer): Integer;
var
  LIdx, LLen, LUnits: Integer;
  LByte: Byte;
begin
  Result := -1;
  if (ALine < 0) or (ALine > High(AStarts)) or (AChar < 0) then
    Exit;
  LLen := Length(ABuffer);
  LIdx := AStarts[ALine] + 1;   // 1-based
  LUnits := 0;
  while LUnits < AChar do
  begin
    if (LIdx > LLen) or (ABuffer[LIdx] = #13) or (ABuffer[LIdx] = #10) then
      Exit;
    LByte := Ord(ABuffer[LIdx]);
    if LByte < $80 then
    begin
      Inc(LIdx);
      Inc(LUnits);
    end
    else if LByte >= $F0 then
    begin
      Inc(LIdx, 4);   // outside the BMP: a surrogate pair, two units
      Inc(LUnits, 2);
    end
    else if LByte >= $E0 then
    begin
      Inc(LIdx, 3);
      Inc(LUnits);
    end
    else
    begin
      Inc(LIdx, 2);
      Inc(LUnits);
    end;
  end;
  if LUnits <> AChar then
    Exit;   // the position falls inside a surrogate pair
  Result := LIdx - 1;
end;

function IsWhitespaceSpan(const ABuffer: UTF8String; AStart, AStop: Integer): Boolean;
var
  LIdx: Integer;
begin
  for LIdx := AStart + 1 to AStop do
    if not CharInSet(ABuffer[LIdx], [' ', #9, #13, #10]) then
      Exit(False);
  Result := True;
end;

function FormatByteEdits(const ABuffer: UTF8String;
  const AEdits: TArray<TFormatEdit>; out AByteEdits: TArray<TFormatByteEdit>;
  out AError: string): Boolean;
var
  LStarts: TArray<Integer>;
  LIdx, LPrevStop: Integer;
  LEdit: TFormatByteEdit;
begin
  Result := False;
  AByteEdits := nil;
  AError := '';
  LStarts := ByteLineStarts(ABuffer);
  LPrevStop := 0;
  SetLength(AByteEdits, Length(AEdits));
  for LIdx := 0 to High(AEdits) do
  begin
    LEdit.Start := ByteOffsetOf(ABuffer, LStarts, AEdits[LIdx].Line,
      AEdits[LIdx].Character);
    LEdit.Stop := ByteOffsetOf(ABuffer, LStarts, AEdits[LIdx].EndLine,
      AEdits[LIdx].EndCharacter);
    LEdit.Text := UTF8Encode(AEdits[LIdx].Text);
    if (LEdit.Start < 0) or (LEdit.Stop < 0) then
    begin
      AError := Format('edit %d is outside the text (line %d)',
        [LIdx + 1, AEdits[LIdx].Line + 1]);
      Exit;
    end;
    if (LEdit.Stop < LEdit.Start) or (LEdit.Start < LPrevStop) then
    begin
      AError := Format('edit %d runs backwards or overlaps the one before',
        [LIdx + 1]);
      Exit;
    end;
    if not IsWhitespaceSpan(ABuffer, LEdit.Start, LEdit.Stop) and
       not SameText(UTF8ToString(Copy(ABuffer, LEdit.Start + 1,
         LEdit.Stop - LEdit.Start)), AEdits[LIdx].Text) then
    begin
      AError := Format('edit %d (line %d) would replace code, not whitespace '
        + 'or a word''s case', [LIdx + 1, AEdits[LIdx].Line + 1]);
      Exit;
    end;
    AByteEdits[LIdx] := LEdit;
    LPrevStop := LEdit.Stop;
  end;
  Result := True;
end;

function ApplyFormatByteEdits(const ABuffer: UTF8String;
  const AEdits: TArray<TFormatByteEdit>): UTF8String;
var
  LIdx, LFrom: Integer;
begin
  Result := '';
  LFrom := 0;
  for LIdx := 0 to High(AEdits) do
  begin
    Result := Result + Copy(ABuffer, LFrom + 1, AEdits[LIdx].Start - LFrom) +
      AEdits[LIdx].Text;
    LFrom := AEdits[LIdx].Stop;
  end;
  Result := Result + Copy(ABuffer, LFrom + 1, MaxInt);
end;

function MapOffsetThroughEdits(AOffset: Integer;
  const AEdits: TArray<TFormatByteEdit>): Integer;
var
  LIdx, LShift: Integer;
begin
  LShift := 0;
  for LIdx := 0 to High(AEdits) do
  begin
    // At or before the edit's start: the caret stays on the token it ends.
    if AEdits[LIdx].Start >= AOffset then
      Break;
    if AOffset < AEdits[LIdx].Stop then
      // Inside the replaced gap: the token after it.
      Exit(AEdits[LIdx].Start + LShift + Length(AEdits[LIdx].Text));
    Inc(LShift, Length(AEdits[LIdx].Text) - (AEdits[LIdx].Stop - AEdits[LIdx].Start));
  end;
  Result := AOffset + LShift;
end;

end.
