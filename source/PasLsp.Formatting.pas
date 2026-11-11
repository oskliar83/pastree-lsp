unit PasLsp.Formatting;

{
  The formatter's protocol half: TPasFormatOptions read from JSON, and
  PasTree.Format's edits written as LSP TextEdit[]. The layout itself is
  PasTree's (docs/formatter.md there); nothing here decides a gap.

  OPTIONS BY FIELD NAME, THROUGH RTTI. The JSON member names ARE the
  TPasFormatOptions field names ("IndentStep", "ReservedWordCase"), matched
  without regard to case, and the record is read and written through its
  RTTI - so a field the library adds (wrapping and alignment are being built
  as this is written) is configurable here with no line of this unit
  changed, and pastree/formatOptions lists it with its default. The value
  shapes follow the field's type: an Integer field takes a JSON number, a
  Boolean a JSON true/false, an enumeration a string - its value's name with
  or without the lower-case prefix (`fcUpper` or `Upper`, any case) - or its
  ordinal as a number. A member that names no field, or carries the wrong
  shape, is skipped and reported, never fatal: a client newer than the
  library must not lose the formatting it can have.

  IdentifierCase is the one member that is not a field: identifier case is
  an argument of PasFormatEdits (TPasIdentCaseFunc), answerable only by a
  caller that resolves names - the server does, through the navigator, when
  this is true. The standard LSP FormattingOptions members (tabSize,
  insertSpaces, trimTrailingWhitespace, insertFinalNewline,
  trimFinalNewlines) are skipped silently: the server maps tabSize itself.

  OFFSETS TO POSITIONS. PasFormatEdits answers 0-based offsets into the text
  it parsed - the server guarantees that text IS the document's - and LSP
  wants (line, UTF-16 character). Delphi strings are UTF-16, so a character
  is an index; a line ends at CRLF, LF or a lone CR, as PasLsp.Documents
  reads one. A position between the CR and the LF of one line break has no
  LSP spelling: such an edit grows by that character on both sides, which
  replaces the same text with the same result.
}

interface

uses
  System.SysUtils,
  System.JSON,
  PasTree.Format;

{ AJson's members applied to AOptions by field name (see the header);
  AIdentCase takes the IdentifierCase member. Each member applied is added
  to ASet (as the field's own spelling), each one skipped to AProblems with
  the reason. AJson nil or not an object changes nothing. }
procedure ApplyFormatJson(var AOptions: TPasFormatOptions;
  var AIdentCase: Boolean; AJson: TJSONValue; var ASet: TArray<string>;
  var AProblems: TArray<string>);

{ Every field of AOptions as one JSON object text, in declaration order, in
  the shapes ApplyFormatJson reads - an enumeration by its name without the
  prefix. }
function FormatOptionsJson(const AOptions: TPasFormatOptions): string;

{ AEdits - 0-based offsets into AText, ascending - as an LSP TextEdit[]
  array text. }
function FormatEditsJson(const AText: string;
  const AEdits: TPasTextEdits): string;

{ An LSP range over AText as 0-based offsets, AEnd exclusive; a position
  past its line's end clamps to it (PositionToIndex). }
procedure LspRangeToOffsets(const AText: string; AStartLine, AStartChar,
  AEndLine, AEndChar: Integer; out AStart, AEnd: Integer);

{ True when ANames holds AName, ignoring case. }
function NameListed(const ANames: TArray<string>; const AName: string): Boolean;

implementation

uses
  System.Rtti,
  System.TypInfo,
  System.Generics.Collections,
  PasLsp.Protocol,
  PasLsp.Documents;

const
  cIdentifierCase = 'IdentifierCase';
  // FormattingOptions' own members (LSP 3.17): read by the handler or not
  // at all, never an error.
  cLspStandard: TArray<string> = ['tabSize', 'insertSpaces',
    'trimTrailingWhitespace', 'insertFinalNewline', 'trimFinalNewlines'];

function NameListed(const ANames: TArray<string>; const AName: string): Boolean;
var
  LName: string;
begin
  for LName in ANames do
    if SameText(LName, AName) then
      Exit(True);
  Result := False;
end;

{ fcUpper -> Upper: the value's name without its lower-case prefix. A name
  with no such prefix is returned whole. }
function EnumWord(AInfo: PTypeInfo; AOrd: Integer): string;
var
  LIdx: Integer;
begin
  Result := GetEnumName(AInfo, AOrd);
  LIdx := 1;
  while (LIdx <= Length(Result)) and CharInSet(Result[LIdx], ['a'..'z']) do
    Inc(LIdx);
  if LIdx <= Length(Result) then
    Result := Copy(Result, LIdx, MaxInt);
end;

function EnumOrdinalOf(AInfo: PTypeInfo; const AText: string;
  out AOrd: Integer): Boolean;
var
  LData: PTypeData;
  LIdx: Integer;
begin
  LData := GetTypeData(AInfo);
  for LIdx := LData.MinValue to LData.MaxValue do
    if SameText(AText, GetEnumName(AInfo, LIdx)) or
       SameText(AText, EnumWord(AInfo, LIdx)) then
    begin
      AOrd := LIdx;
      Exit(True);
    end;
  Result := False;
end;

function EnumWords(AInfo: PTypeInfo): string;
var
  LData: PTypeData;
  LIdx: Integer;
begin
  LData := GetTypeData(AInfo);
  Result := '';
  for LIdx := LData.MinValue to LData.MaxValue do
  begin
    if Result <> '' then
      Result := Result + ' / ';
    Result := Result + EnumWord(AInfo, LIdx);
  end;
end;

procedure ApplyFormatJson(var AOptions: TPasFormatOptions;
  var AIdentCase: Boolean; AJson: TJSONValue; var ASet: TArray<string>;
  var AProblems: TArray<string>);
var
  LCtx: TRttiContext;
  LType: TRttiType;
  LField, LCand: TRttiField;
  LPair: TJSONPair;
  LName: string;
  LValue: TJSONValue;
  LInfo: PTypeInfo;
  LOrd: Integer;
  LData: PTypeData;
begin
  if not (AJson is TJSONObject) then
    Exit;
  LCtx := TRttiContext.Create;
  LType := LCtx.GetType(TypeInfo(TPasFormatOptions));
  for LPair in TJSONObject(AJson) do
  begin
    LName := LPair.JsonString.Value;
    LValue := LPair.JsonValue;
    if SameText(LName, cIdentifierCase) then
    begin
      if LValue is TJSONBool then
      begin
        AIdentCase := TJSONBool(LValue).AsBoolean;
        ASet := ASet + [cIdentifierCase];
      end
      else
        AProblems := AProblems + [LName + ': true or false expected'];
      Continue;
    end;
    if NameListed(cLspStandard, LName) then
      Continue;
    LField := nil;
    for LCand in LType.GetFields do
      if SameText(LCand.Name, LName) then
      begin
        LField := LCand;
        Break;
      end;
    if LField = nil then
    begin
      AProblems := AProblems + [LName + ': no such option'];
      Continue;
    end;
    LInfo := LField.FieldType.Handle;
    case LField.FieldType.TypeKind of
      tkInteger:
        if LValue is TJSONNumber then
          LField.SetValue(@AOptions, TJSONNumber(LValue).AsInt)
        else
        begin
          AProblems := AProblems + [LField.Name + ': a number expected'];
          Continue;
        end;
      tkEnumeration:
        if LInfo = TypeInfo(Boolean) then
        begin
          if LValue is TJSONBool then
            LField.SetValue(@AOptions, TJSONBool(LValue).AsBoolean)
          else
          begin
            AProblems := AProblems + [LField.Name + ': true or false expected'];
            Continue;
          end;
        end
        else
        begin
          LData := GetTypeData(LInfo);
          if (LValue is TJSONString) and not (LValue is TJSONNumber) and
             EnumOrdinalOf(LInfo, LValue.Value, LOrd) then
            LField.SetValue(@AOptions, TValue.FromOrdinal(LInfo, LOrd))
          else if (LValue is TJSONNumber) and
             (TJSONNumber(LValue).AsInt >= LData.MinValue) and
             (TJSONNumber(LValue).AsInt <= LData.MaxValue) then
            LField.SetValue(@AOptions,
              TValue.FromOrdinal(LInfo, TJSONNumber(LValue).AsInt))
          else
          begin
            AProblems := AProblems + [LField.Name + ': one of ' +
              EnumWords(LInfo) + ' expected'];
            Continue;
          end;
        end;
    else
      AProblems := AProblems + [LField.Name + ': not settable from JSON'];
      Continue;
    end;
    ASet := ASet + [LField.Name];
  end;
end;

function FormatOptionsJson(const AOptions: TPasFormatOptions): string;
var
  LCtx: TRttiContext;
  LField: TRttiField;
  LInfo: PTypeInfo;
  LValue: TValue;
  LItem: string;
begin
  LCtx := TRttiContext.Create;
  Result := '';
  for LField in LCtx.GetType(TypeInfo(TPasFormatOptions)).GetFields do
  begin
    LInfo := LField.FieldType.Handle;
    LValue := LField.GetValue(@AOptions);
    case LField.FieldType.TypeKind of
      tkInteger:
        LItem := IntToStr(LValue.AsOrdinal);
      tkEnumeration:
        if LInfo = TypeInfo(Boolean) then
          LItem := BoolToStr(LValue.AsBoolean, True).ToLower
        else
          LItem := JsonQuote(EnumWord(LInfo, LValue.AsOrdinal));
    else
      Continue;
    end;
    if Result <> '' then
      Result := Result + ',';
    Result := Result + JsonQuote(LField.Name) + ':' + LItem;
  end;
  Result := '{' + Result + '}';
end;

{ 0-based offsets at which each line starts. }
function LineStarts(const AText: string): TArray<Integer>;
var
  LList: TList<Integer>;
  LIdx, LLen: Integer;
begin
  LList := TList<Integer>.Create;
  try
    LList.Add(0);
    LLen := Length(AText);
    LIdx := 1;
    while LIdx <= LLen do
    begin
      if AText[LIdx] = #13 then
      begin
        if (LIdx < LLen) and (AText[LIdx + 1] = #10) then
          Inc(LIdx);
        LList.Add(LIdx);   // 1-based index of the last break char = offset after it
      end
      else if AText[LIdx] = #10 then
        LList.Add(LIdx);
      Inc(LIdx);
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

procedure OffsetToPosition(const AStarts: TArray<Integer>; AOffset: Integer;
  out ALine, AChar: Integer);
var
  LLo, LHi, LMid: Integer;
begin
  LLo := 0;
  LHi := High(AStarts);
  while LLo < LHi do
  begin
    LMid := (LLo + LHi + 1) div 2;
    if AStarts[LMid] <= AOffset then
      LLo := LMid
    else
      LHi := LMid - 1;
  end;
  ALine := LLo;
  AChar := AOffset - AStarts[LLo];
end;

{ Is AOffset between the CR and the LF of one line break? }
function InsideCrLf(const AText: string; AOffset: Integer): Boolean;
begin
  Result := (AOffset > 0) and (AOffset < Length(AText)) and
    (AText[AOffset] = #13) and (AText[AOffset + 1] = #10);
end;

function FormatEditsJson(const AText: string;
  const AEdits: TPasTextEdits): string;
var
  LStarts: TArray<Integer>;
  LSB: TStringBuilder;
  LIdx, LFrom, LTo, LSL, LSC, LEL, LEC: Integer;
  LNew: string;
begin
  LStarts := LineStarts(AText);
  LSB := TStringBuilder.Create;
  try
    LSB.Append('[');
    for LIdx := 0 to High(AEdits) do
    begin
      LFrom := AEdits[LIdx].Start;
      LTo := AEdits[LIdx].Start + AEdits[LIdx].Len;
      LNew := AEdits[LIdx].Text;
      if InsideCrLf(AText, LFrom) then
      begin
        Dec(LFrom);
        LNew := #13 + LNew;
      end;
      if InsideCrLf(AText, LTo) then
      begin
        Inc(LTo);
        LNew := LNew + #10;
      end;
      OffsetToPosition(LStarts, LFrom, LSL, LSC);
      OffsetToPosition(LStarts, LTo, LEL, LEC);
      if LIdx > 0 then
        LSB.Append(',');
      LSB.Append(Format('{"range":{"start":{"line":%d,"character":%d},' +
        '"end":{"line":%d,"character":%d}},"newText":%s}',
        [LSL, LSC, LEL, LEC, JsonQuote(LNew)]));
    end;
    LSB.Append(']');
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

procedure LspRangeToOffsets(const AText: string; AStartLine, AStartChar,
  AEndLine, AEndChar: Integer; out AStart, AEnd: Integer);
begin
  AStart := PositionToIndex(AText, AStartLine, AStartChar) - 1;
  AEnd := PositionToIndex(AText, AEndLine, AEndChar) - 1;
  if AEnd < AStart then
    AEnd := AStart;
end;

end.
