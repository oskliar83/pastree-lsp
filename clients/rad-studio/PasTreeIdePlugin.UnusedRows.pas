unit PasTreeIdePlugin.UnusedRows;

{
  The rows of Find All > Unused... as the server sends them - unused
  declarations (pastree/unusedSymbols), unused `uses` entries
  (pastree/unusedUses), units nobody uses (pastree/unreferencedUnits) - their
  reader, and the GROUP MERGE (0.93.0).

  NO TOOLSAPI, ON PURPOSE: LspClientSmoke links this unit and checks the
  merge over two real servers, which it could not do through LspSession.

  THE GROUP RULE is pastree-mcp's ("kept when every analysis holding the unit
  finds it unused"), made here because the plugin runs one server per
  project and no single process holds every analysis - pastree-mcp holds
  them all in one, so it merges inside; the rule is the same and small.
  Every project of the group is asked with `group: true`, which adds `held`
  (the files it searched) to its answers. Then, per kind:
  - a declaration (its name's place) is a row when every project holding
    its file finds it unused - as a row, or as a member of a type that is a
    row there (`inRow`: unused all the same, left out only because its type
    goes with it; a row of the group where another project uses the type
    and not the member). The row shown is the one with the most to say
    (`how`: "only written" over "used only by unused" over nothing);
  - a `uses` entry (its name's place) the same;
  - a unit nobody uses when no project holding it reaches it.
  A row's doubts are the union over the projects, its `by` too; `skipped`
  takes the largest count of each reason.

  REMOVED TOGETHER. A project weighs its rows as removed together
  (PasTree's loTogether) - but in a group what is removed is only the
  entries every project finds unused, fewer than each project's own rows.
  So the first round asks without that check (`group: true`), and a second
  asks each project again with `removed`: the group's removable entries it
  holds (GroupRemovedPlaces). What it holds back comes as a doubt, joined to
  the merged row (AddTogetherDoubts). One round is enough to be safe: an
  entry one project holds back is removed by nobody, so every other
  project removes less than it was weighed with - it can only lose a
  doubt, never need one.
}

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections;

type
  /// <summary>
  /// An unused `uses` entry: its name at Row/Col (Len chars), the section
  /// it is in, why removing it may be wrong (Doubts - such an entry is
  /// shown, never removed) and why no edit removes it (Refused, '' when an
  /// edit does).
  /// </summary>
  TLspUnusedEntry = record
    FilePath: string;
    Row, Col, Len: Integer;
    UnitName, Section: string;
    Doubts: TArray<string>;
    Refused: string;
    TypeSpans: TArray<Integer>;
    // `afterRows` (0.89.14): the unused declarations the entry is needed
    // only by - it goes with them, never removed alone. nil otherwise.
    By: TArray<string>;
  end;

  /// <summary>A `uses` entry naming a unit nobody uses. IsProgram: the
  /// .dpr/.dpk's, which goes with the unit when it leaves the project.
  /// </summary>
  TLspListedBy = record
    FilePath: string;
    Row, Col, Len: Integer;
    Note: string;
    IsProgram: Boolean;
    TypeSpans: TArray<Integer>;
  end;

  /// <summary>A project unit nobody uses: its name in its own header.</summary>
  TLspUnreferencedEntry = record
    FilePath: string;
    Row, Col, Len: Integer;
    UnitName: string;
    Doubts: TArray<string>;
    TypeSpans: TArray<Integer>;
    ListedBy: TArray<TLspListedBy>;
  end;

  /// <summary>Where an only-assigned row is written: IDE 1-based.</summary>
  TLspWriteSite = record
    FilePath: string;
    Row, Col: Integer;
    Computed: Boolean;
  end;

  /// <summary>A declaration nothing uses (pastree/unusedSymbols): its name
  /// at Row/Col (Len chars), Name qualified by its types, Kind in prose
  /// ("function", "field"), and where the index may be wrong (Doubts).
  /// </summary>
  TLspUnusedSymbol = record
    FilePath: string;
    Row, Col, Len: Integer;
    Name, Kind: string;
    Doubts: TArray<string>;
    // A row made by rows (server 0.89.2): why it is one - "used only by
    // unused X - it goes with them", "only assigned (...), never read"; ''
    // for one nothing uses.
    Why: string;
    // Its kind of row made by rows: 'usedOnlyByUnused', 'onlyAssigned', ''.
    How: string;
    TypeSpans: TArray<Integer>;
    // The rows using it, qualified ('' for itself) - they go with it.
    By: TArray<string>;
    // An only-assigned row's assignments: where the name is written (moved
    // with the edits like the row) and whether code computes the value.
    WriteSites: TArray<TLspWriteSite>;
    // Why Remove cannot take it out (pastree/symbolsRemoval's refusal,
    // kept for the rest of the tab's life); '' while none is known.
    Refused: string;
  end;

  /// <summary>Any of the three answers: Entries for unusedUses, Units for
  /// unreferencedUnits, Symbols and Skipped ("105 published members") for
  /// unusedSymbols. ProjectFile is the .dproj of the server that answered
  /// ('' for a group's merged answer). Held: the files a `group` answer
  /// searched; InRow: the places (UnusedPlaceKey) of the members a `group`
  /// unusedSymbols answer left out as members of a row type.
  /// </summary>
  TLspUnusedAnswer = record
    ProjectFile: string;
    Entries: TArray<TLspUnusedEntry>;
    Units: TArray<TLspUnreferencedEntry>;
    Symbols: TArray<TLspUnusedSymbol>;
    Skipped: TArray<string>;
    Held: TArray<string>;
    InRow: TArray<string>;
  end;

  TLspUnusedProc = reference to procedure(ASuccess: Boolean;
    const AAnswer: TLspUnusedAnswer; const AError: string);

  /// <summary>A row's name in its file, IDE 1-based.</summary>
  TLspUnusedPlace = record
    FilePath: string;
    Row, Col: Integer;
  end;

/// <summary>A Location object's file, start (IDE 1-based) and width - the
/// rows of pastree/unusedUses and unreferencedUnits are names on one
/// line.</summary>
function ReadUnusedLocation(AObj: TJSONObject; out APath: string;
  out ARow, ACol, ALen: Integer): Boolean;

/// <summary>AObj's AName member as strings; nil when absent.</summary>
function ReadStrings(AObj: TJSONObject; const AName: string): TArray<string>;

/// <summary>Any of the three answers' `result`.</summary>
function ParseUnusedAnswer(AResult: TJSONValue): TLspUnusedAnswer;

/// <summary>The key a place is merged by: the path in lower case, row and
/// column.</summary>
function UnusedPlaceKey(const APath: string; ARow, ACol: Integer): string;

/// <summary>
/// One answer per project (its three steps joined, Held set) merged into
/// the group's: a row only where every project holding its file finds it
/// unused. ProjectFile is ''.
/// </summary>
function MergeGroupAnswers(
  const AAnswers: TArray<TLspUnusedAnswer>): TLspUnusedAnswer;

/// <summary>
/// The entries of AMerged the group removes (no doubt, no `by`, nothing
/// refused) whose file AProject holds - what pastree/unusedUses'
/// `removed` weighs together in that project.
/// </summary>
function GroupRemovedPlaces(const AMerged,
  AProject: TLspUnusedAnswer): TArray<TLspUnusedPlace>;

/// <summary>Every doubt of ARound's entries joined to AMerged's entry at
/// the same place - the second round's "removed together".</summary>
procedure AddTogetherDoubts(var AMerged: TLspUnusedAnswer;
  const ARound: TLspUnusedAnswer);

implementation

uses
  System.Generics.Defaults,
  PasTreeIdePlugin.LspClient;

// LSP 0-based to IDE 1-based - as LspDocuments' LspToIde, which this unit
// cannot link (it uses ToolsAPI).
procedure ToIde(ALine, ACharacter: Integer; out ARow, ACol: Integer);
begin
  ARow := ALine + 1;
  ACol := ACharacter + 1;
end;

function ReadInts(AObj: TJSONObject; const AName: string): TArray<Integer>;
var
  LArr: TJSONArray;
begin
  Result := nil;
  if not AObj.TryGetValue<TJSONArray>(AName, LArr) then
    Exit;
  SetLength(Result, LArr.Count);
  for var LIdx := 0 to LArr.Count - 1 do
    if LArr.Items[LIdx] is TJSONNumber then
      Result[LIdx] := TJSONNumber(LArr.Items[LIdx]).AsInt
    else
      Result[LIdx] := 0;
end;

function ReadUnusedLocation(AObj: TJSONObject; out APath: string;
  out ARow, ACol, ALen: Integer): Boolean;
var
  LLine, LChar, LEndChar: Integer;
begin
  APath := LspUriToPath(AObj.GetValue<string>('uri', ''));
  LLine := AObj.GetValue<Integer>('range.start.line', -1);
  LChar := AObj.GetValue<Integer>('range.start.character', -1);
  LEndChar := AObj.GetValue<Integer>('range.end.character', LChar);
  Result := (APath <> '') and (LLine >= 0) and (LChar >= 0);
  if not Result then
    Exit;
  ToIde(LLine, LChar, ARow, ACol);
  ALen := LEndChar - LChar;
end;

function ReadStrings(AObj: TJSONObject; const AName: string): TArray<string>;
var
  LArr: TJSONArray;
begin
  Result := nil;
  if AObj.TryGetValue<TJSONArray>(AName, LArr) then
    for var LItem in LArr do
      Result := Result + [LItem.Value];
end;

// An only-assigned row's `writeSites`.
function ReadWriteSites(AObj: TJSONObject): TArray<TLspWriteSite>;
var
  LArr: TJSONArray;
  LSite: TLspWriteSite;
begin
  Result := nil;
  if not AObj.TryGetValue<TJSONArray>('writeSites', LArr) then
    Exit;
  for var LValue in LArr do
  begin
    if not (LValue is TJSONObject) then
      Continue;
    LSite := Default(TLspWriteSite);
    LSite.FilePath := LspUriToPath(LValue.GetValue<string>('uri', ''));
    ToIde(LValue.GetValue<Integer>('line', 0),
      LValue.GetValue<Integer>('character', 0), LSite.Row, LSite.Col);
    LSite.Computed := LValue.GetValue<Boolean>('computed', False);
    Result := Result + [LSite];
  end;
end;

function UnusedPlaceKey(const APath: string; ARow, ACol: Integer): string;
begin
  Result := Format('%s:%d:%d', [LowerCase(APath), ARow, ACol]);
end;

function ParseUnusedAnswer(AResult: TJSONValue): TLspUnusedAnswer;
var
  LArr, LListed: TJSONArray;
  LObj: TJSONObject;
  LEntry: TLspUnusedEntry;
  LUnit: TLspUnreferencedEntry;
  LBy: TLspListedBy;
  LSymbol: TLspUnusedSymbol;
  LSymbols, LRow, LCol: Integer;
begin
  Result := Default(TLspUnusedAnswer);
  LSymbols := 0;
  if not (AResult is TJSONObject) then
    Exit;
  if AResult.TryGetValue<TJSONArray>('skipped', LArr) then
    for var LValue in LArr do
      if (LValue is TJSONObject) and
         (LValue.GetValue<Integer>('count', 0) > 0) then
        Result.Skipped := Result.Skipped + [Format('%d %s',
          [LValue.GetValue<Integer>('count', 0),
           LValue.GetValue<string>('what', '')])];
  // A group answer (0.93.0): the files searched, and the members of row
  // types by their place.
  if AResult.TryGetValue<TJSONArray>('held', LArr) then
  begin
    SetLength(Result.Held, LArr.Count);
    for var LI := 0 to LArr.Count - 1 do
      Result.Held[LI] := LspUriToPath(LArr.Items[LI].Value);
  end;
  if AResult.TryGetValue<TJSONArray>('inRow', LArr) then
    for var LValue in LArr do
      if LValue is TJSONObject then
      begin
        ToIde(LValue.GetValue<Integer>('line', 0),
          LValue.GetValue<Integer>('character', 0), LRow, LCol);
        Result.InRow := Result.InRow + [UnusedPlaceKey(LspUriToPath(
          LValue.GetValue<string>('uri', '')), LRow, LCol)];
      end;
  if AResult.TryGetValue<TJSONArray>('rows', LArr) then
    for var LValue in LArr do
    begin
      if not (LValue is TJSONObject) then
        Continue;
      LObj := TJSONObject(LValue);
      if LObj.GetValue('kind') <> nil then
      begin
        LSymbol := Default(TLspUnusedSymbol);
        if not ReadUnusedLocation(LObj, LSymbol.FilePath, LSymbol.Row,
          LSymbol.Col, LSymbol.Len) then
          Continue;
        LSymbol.Name := LObj.GetValue<string>('name', '');
        LSymbol.Kind := LObj.GetValue<string>('kind', '');
        LSymbol.Doubts := ReadStrings(LObj, 'doubts');
        LSymbol.Why := LObj.GetValue<string>('why', '');
        LSymbol.How := LObj.GetValue<string>('how', '');
        LSymbol.TypeSpans := ReadInts(LObj, 'typeSpans');
        LSymbol.By := ReadStrings(LObj, 'by');
        LSymbol.WriteSites := ReadWriteSites(LObj);
        // Thousands of rows on a large project: grown by halves, not by one.
        if LSymbols = Length(Result.Symbols) then
          SetLength(Result.Symbols, LSymbols + LSymbols div 2 + 16);
        Result.Symbols[LSymbols] := LSymbol;
        Inc(LSymbols);
      end
      else if LObj.TryGetValue<TJSONArray>('listedBy', LListed) then
      begin
        LUnit := Default(TLspUnreferencedEntry);
        if not ReadUnusedLocation(LObj, LUnit.FilePath, LUnit.Row, LUnit.Col,
          LUnit.Len) then
          Continue;
        LUnit.UnitName := LObj.GetValue<string>('unitName', '');
        LUnit.Doubts := ReadStrings(LObj, 'doubts');
        LUnit.TypeSpans := ReadInts(LObj, 'typeSpans');
        for var LByValue in LListed do
        begin
          LBy := Default(TLspListedBy);
          if not (LByValue is TJSONObject) or
             not ReadUnusedLocation(TJSONObject(LByValue), LBy.FilePath,
             LBy.Row, LBy.Col, LBy.Len) then
            Continue;
          LBy.Note := LByValue.GetValue<string>('note', '');
          LBy.IsProgram := LByValue.GetValue<Boolean>('program', False);
          LBy.TypeSpans := ReadInts(TJSONObject(LByValue), 'typeSpans');
          LUnit.ListedBy := LUnit.ListedBy + [LBy];
        end;
        Result.Units := Result.Units + [LUnit];
      end
      else
      begin
        LEntry := Default(TLspUnusedEntry);
        if not ReadUnusedLocation(LObj, LEntry.FilePath, LEntry.Row,
          LEntry.Col, LEntry.Len) then
          Continue;
        LEntry.UnitName := LObj.GetValue<string>('unitName', '');
        LEntry.Section := LObj.GetValue<string>('section', '');
        LEntry.Doubts := ReadStrings(LObj, 'doubts');
        LEntry.Refused := LObj.GetValue<string>('refused', '');
        LEntry.By := ReadStrings(LObj, 'by');
        LEntry.TypeSpans := ReadInts(LObj, 'typeSpans');
        Result.Entries := Result.Entries + [LEntry];
      end;
    end;
  SetLength(Result.Symbols, LSymbols);
end;

{ -------- the group merge -------- }

// AList with the strings of AMore it lacks (exact text), in order.
function UnionOf(const AList, AMore: TArray<string>): TArray<string>;
var
  LFound: Boolean;
begin
  Result := AList;
  for var LS in AMore do
  begin
    LFound := False;
    for var LT in Result do
      if LT = LS then
      begin
        LFound := True;
        Break;
      end;
    if not LFound then
      Result := Result + [LS];
  end;
end;

// How much a row's `how` says: the analysis that sees uses (the dead ones)
// says more than one that sees none - pastree-mcp's order, PasTree's
// TPasUnusedHow.
function HowRank(const AHow: string): Integer;
begin
  if SameText(AHow, 'onlyAssigned') then
    Result := 2
  else if SameText(AHow, 'usedOnlyByUnused') then
    Result := 1
  else
    Result := 0;
end;

procedure Bump(ACounts: TDictionary<string, Integer>; const AKey: string);
var
  LN: Integer;
begin
  if not ACounts.TryGetValue(AKey, LN) then
    LN := 0;
  ACounts.AddOrSetValue(AKey, LN + 1);
end;

function CountOf(ACounts: TDictionary<string, Integer>;
  const AKey: string): Integer;
begin
  if not ACounts.TryGetValue(AKey, Result) then
    Result := 0;
end;

// The rows sorted as a server sorts its own: by the file's name (a tab
// groups by file), the path breaking a tie, then by place.
function CompareFiles(const APathA, APathB: string): Integer;
begin
  Result := CompareText(ExtractFileName(APathA), ExtractFileName(APathB));
  if Result = 0 then
    Result := CompareText(APathA, APathB);
end;

function MergeGroupAnswers(
  const AAnswers: TArray<TLspUnusedAnswer>): TLspUnusedAnswer;
var
  LHeld, LSymCount, LEntCount, LUnitCount, LSkipMax: TDictionary<string,
    Integer>;
  LSymAt, LEntAt, LUnitAt: TDictionary<string, Integer>;
  LSeen: TDictionary<string, Boolean>;
  LSymbols: TList<TLspUnusedSymbol>;
  LEntries: TList<TLspUnusedEntry>;
  LUnits: TList<TLspUnreferencedEntry>;
  LSymbol: TLspUnusedSymbol;
  LEntry: TLspUnusedEntry;
  LUnit: TLspUnreferencedEntry;
  LKey, LWhat: string;
  LAt, LN, LSpace: Integer;
  LListedAt: TDictionary<string, Boolean>;
  LDoubts: TArray<string>;
begin
  Result := Default(TLspUnusedAnswer);
  LHeld := TDictionary<string, Integer>.Create;
  LSymCount := TDictionary<string, Integer>.Create;
  LEntCount := TDictionary<string, Integer>.Create;
  LUnitCount := TDictionary<string, Integer>.Create;
  LSkipMax := TDictionary<string, Integer>.Create;
  LSymAt := TDictionary<string, Integer>.Create;
  LEntAt := TDictionary<string, Integer>.Create;
  LUnitAt := TDictionary<string, Integer>.Create;
  LSeen := TDictionary<string, Boolean>.Create;
  LSymbols := TList<TLspUnusedSymbol>.Create;
  LEntries := TList<TLspUnusedEntry>.Create;
  LUnits := TList<TLspUnreferencedEntry>.Create;
  try
    for var LA in AAnswers do
    begin
      // Who holds what: each project once per file.
      LSeen.Clear;
      for var LP in LA.Held do
        if LSeen.TryAdd(LowerCase(LP), True) then
          Bump(LHeld, LowerCase(LP));

      // Declarations: a row or a member of a row type, counted once per
      // project; the row kept the first seen, or one saying more.
      LSeen.Clear;
      for var LS in LA.Symbols do
      begin
        LKey := UnusedPlaceKey(LS.FilePath, LS.Row, LS.Col);
        if LSeen.TryAdd(LKey, True) then
          Bump(LSymCount, LKey);
        if not LSymAt.ContainsKey(LKey) then
        begin
          LSymAt.Add(LKey, LSymbols.Count);
          LSymbols.Add(LS);
        end;
      end;
      for var LK in LA.InRow do
        if LSeen.TryAdd(LK, True) then
          Bump(LSymCount, LK);

      // `uses` entries.
      LSeen.Clear;
      for var LE in LA.Entries do
      begin
        LKey := UnusedPlaceKey(LE.FilePath, LE.Row, LE.Col);
        if LSeen.TryAdd(LKey, True) then
          Bump(LEntCount, LKey);
        if not LEntAt.TryGetValue(LKey, LAt) then
        begin
          LEntAt.Add(LKey, LEntries.Count);
          LEntries.Add(LE);
        end
        else
        begin
          LEntry := LEntries[LAt];
          LEntry.Doubts := UnionOf(LEntry.Doubts, LE.Doubts);
          LEntry.By := UnionOf(LEntry.By, LE.By);
          if LEntry.Refused = '' then
            LEntry.Refused := LE.Refused;
          LEntries[LAt] := LEntry;
        end;
      end;

      // Units nobody uses, by file.
      LSeen.Clear;
      for var LU in LA.Units do
      begin
        LKey := LowerCase(LU.FilePath);
        if LSeen.TryAdd(LKey, True) then
          Bump(LUnitCount, LKey);
        if not LUnitAt.TryGetValue(LKey, LAt) then
        begin
          LUnitAt.Add(LKey, LUnits.Count);
          LUnits.Add(LU);
        end
        else
        begin
          LUnit := LUnits[LAt];
          LUnit.Doubts := UnionOf(LUnit.Doubts, LU.Doubts);
          // Every entry naming it, each once.
          LListedAt := TDictionary<string, Boolean>.Create;
          try
            for var LB in LUnit.ListedBy do
              LListedAt.AddOrSetValue(UnusedPlaceKey(LB.FilePath, LB.Row,
                LB.Col), True);
            for var LB in LU.ListedBy do
              if LListedAt.TryAdd(UnusedPlaceKey(LB.FilePath, LB.Row, LB.Col),
                True) then
                LUnit.ListedBy := LUnit.ListedBy + [LB];
          finally
            LListedAt.Free;
          end;
          LUnits[LAt] := LUnit;
        end;
      end;

      // Not weighed: the largest count of each reason.
      for var LSk in LA.Skipped do
      begin
        LSpace := Pos(' ', LSk);
        LN := StrToIntDef(Copy(LSk, 1, LSpace - 1), 0);
        LWhat := Copy(LSk, LSpace + 1, MaxInt);
        if CountOf(LSkipMax, LWhat) < LN then
          LSkipMax.AddOrSetValue(LWhat, LN);
      end;
    end;

    // The doubts and the `how` of a declaration over every project that
    // has it as a row (a second pass: the first kept the first row seen).
    for var LA in AAnswers do
      for var LS in LA.Symbols do
      begin
        LAt := LSymAt[UnusedPlaceKey(LS.FilePath, LS.Row, LS.Col)];
        LSymbol := LSymbols[LAt];
        if HowRank(LS.How) > HowRank(LSymbol.How) then
        begin
          LDoubts := LSymbol.Doubts;
          LSymbol := LS;
          LSymbol.Doubts := UnionOf(LS.Doubts, LDoubts);
        end
        else
          LSymbol.Doubts := UnionOf(LSymbol.Doubts, LS.Doubts);
        LSymbols[LAt] := LSymbol;
      end;

    // Kept: every project holding the file finds it unused. Thousands of
    // rows on a large group: counted into place, not appended one by one.
    SetLength(Result.Symbols, LSymbols.Count);
    LAt := 0;
    for var LS in LSymbols do
    begin
      LN := CountOf(LHeld, LowerCase(LS.FilePath));
      if (LN > 0) and (CountOf(LSymCount, UnusedPlaceKey(LS.FilePath, LS.Row,
        LS.Col)) >= LN) then
      begin
        Result.Symbols[LAt] := LS;
        Inc(LAt);
      end;
    end;
    SetLength(Result.Symbols, LAt);
    SetLength(Result.Entries, LEntries.Count);
    LAt := 0;
    for var LE in LEntries do
    begin
      LN := CountOf(LHeld, LowerCase(LE.FilePath));
      if (LN > 0) and (CountOf(LEntCount, UnusedPlaceKey(LE.FilePath, LE.Row,
        LE.Col)) >= LN) then
      begin
        Result.Entries[LAt] := LE;
        Inc(LAt);
      end;
    end;
    SetLength(Result.Entries, LAt);
    SetLength(Result.Units, LUnits.Count);
    LAt := 0;
    for var LU in LUnits do
    begin
      LN := CountOf(LHeld, LowerCase(LU.FilePath));
      if (LN > 0) and (CountOf(LUnitCount, LowerCase(LU.FilePath)) >= LN) then
      begin
        Result.Units[LAt] := LU;
        Inc(LAt);
      end;
    end;
    SetLength(Result.Units, LAt);
    for var LP in LSkipMax do
      Result.Skipped := Result.Skipped + [Format('%d %s', [LP.Value, LP.Key])];
    TArray.Sort<string>(Result.Skipped);
  finally
    LUnits.Free;
    LEntries.Free;
    LSymbols.Free;
    LSeen.Free;
    LUnitAt.Free;
    LEntAt.Free;
    LSymAt.Free;
    LSkipMax.Free;
    LUnitCount.Free;
    LEntCount.Free;
    LSymCount.Free;
    LHeld.Free;
  end;
  TArray.Sort<TLspUnusedSymbol>(Result.Symbols,
    TComparer<TLspUnusedSymbol>.Construct(
    function(const A, B: TLspUnusedSymbol): Integer
    begin
      Result := CompareFiles(A.FilePath, B.FilePath);
      if Result = 0 then
        Result := A.Row - B.Row;
      if Result = 0 then
        Result := A.Col - B.Col;
    end));
  TArray.Sort<TLspUnusedEntry>(Result.Entries,
    TComparer<TLspUnusedEntry>.Construct(
    function(const A, B: TLspUnusedEntry): Integer
    begin
      Result := CompareFiles(A.FilePath, B.FilePath);
      if Result = 0 then
        Result := A.Row - B.Row;
      if Result = 0 then
        Result := A.Col - B.Col;
    end));
  TArray.Sort<TLspUnreferencedEntry>(Result.Units,
    TComparer<TLspUnreferencedEntry>.Construct(
    function(const A, B: TLspUnreferencedEntry): Integer
    begin
      Result := CompareText(A.UnitName, B.UnitName);
    end));
end;

function GroupRemovedPlaces(const AMerged,
  AProject: TLspUnusedAnswer): TArray<TLspUnusedPlace>;
var
  LHeld: TDictionary<string, Boolean>;
  LPlace: TLspUnusedPlace;
begin
  Result := nil;
  LHeld := TDictionary<string, Boolean>.Create;
  try
    for var LP in AProject.Held do
      LHeld.AddOrSetValue(LowerCase(LP), True);
    for var LE in AMerged.Entries do
      if (LE.Doubts = nil) and (LE.By = nil) and (LE.Refused = '') and
         LHeld.ContainsKey(LowerCase(LE.FilePath)) then
      begin
        LPlace.FilePath := LE.FilePath;
        LPlace.Row := LE.Row;
        LPlace.Col := LE.Col;
        Result := Result + [LPlace];
      end;
  finally
    LHeld.Free;
  end;
end;

procedure AddTogetherDoubts(var AMerged: TLspUnusedAnswer;
  const ARound: TLspUnusedAnswer);
var
  LAt: TDictionary<string, Integer>;
  LIdx: Integer;
begin
  LAt := TDictionary<string, Integer>.Create;
  try
    for var LI := 0 to High(AMerged.Entries) do
      LAt.AddOrSetValue(UnusedPlaceKey(AMerged.Entries[LI].FilePath,
        AMerged.Entries[LI].Row, AMerged.Entries[LI].Col), LI);
    for var LE in ARound.Entries do
      if (LE.Doubts <> nil) and LAt.TryGetValue(UnusedPlaceKey(LE.FilePath,
        LE.Row, LE.Col), LIdx) then
        AMerged.Entries[LIdx].Doubts := UnionOf(AMerged.Entries[LIdx].Doubts,
          LE.Doubts);
  finally
    LAt.Free;
  end;
end;

end.
