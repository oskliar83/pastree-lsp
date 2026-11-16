unit PasTreeIdePlugin.UnusedUnits;

{
  Find All > Unused... (0.89.0) - one command in place of the three it was
  (Unused Units, Unused Units in the Project, Units Nobody Uses; Alex,
  2026-11-14). A dialog (PasTreeIdePlugin.UnusedForm) asks where - the unit
  in the editor or its project - and what: unused declarations (PasTree
  0.191.0's FindUnusedSymbols), unused `uses` entries, units nobody uses
  (project only), and whether rows with a doubt are shown at all. The
  answers go into ONE tab, "Unused", with a toolbar above it: Remove takes
  the selected unit out, Remove All every one, Revert takes the last Remove
  back. Declarations are shown, never removed (Alex, 2026-11-14: Remove for
  them is deferred - a routine's declaration, its body, a forward and the
  $IFDEF branches are one removal, and a row may be a namesake).

  WHAT IS OFFERED IS THE SERVER'S. It answers pastree/unusedSymbols,
  pastree/unusedUses (the unit in the editor, or every unit of the project
  outside the library paths) and pastree/unreferencedUnits, asked one after
  the other - the wait dialog says which step of how many is running, one
  progress for the whole search, never a line per unit. A unit whose
  initialization reaches outside itself is not offered at all - it is in
  `uses` for what it registers (PasTree's loHideGlobalInit, Alex
  2026-10-05). A row with a doubt is dropped here, on arrival, unless the
  dialog asked for them: then it is shown with its doubts under it, and a
  `uses` entry or a unit with a doubt is never removed.

  THE TREE: a title row with the counts, then a row per part searched that
  found anything - "declarations (N)", "units in uses (N)", "units nobody
  uses (N)". Under declarations: what was not weighed at all (published
  members, virtual methods - the server's `skipped`), then the declarations
  - by file for the project, the unit's own directly. Under units in uses:
  for the unit "interface (N)" / "implementation (N)" (Alex, 2026-10-06),
  for the project a row per file (its file name alone, no tags - Alex,
  2026-10-06), the `uses` lines under it with the name marked. Under units
  nobody uses: a row per unit's file and every `uses` entry still naming
  it. A note under a row says why it is kept ("kept: ...") or why no edit
  removes it.

  A NODE is one row Remove can act on, or one declaration: the entries, the
  units nobody uses and the declarations, numbered in that order (NodeCount
  and the Node* functions). A section or file row stands for every node
  under it.

  REMOVE IS PER NODE, so a unit can be taken out and the project compiled
  before the next one (Alex, 2026-10-06): Remove takes the node selected in
  the tree (RenameToolbar.ResultFocusedRow) - a section row stands for every
  node under it - Remove All every node left.
  The edits are asked for at the click (pastree/usesRemoval), on the text
  as it is then - not with the search: a unit nobody uses is listed beside
  its siblings in one clause, and an edit computed before the first of
  them went no longer matches the clause it left. All or nothing per
  Remove: every edit is checked against the text before any is made. Open
  modules are edited through one undoable writer each (one Ctrl+Z per
  file) and saved, as Rename does (Alex, 2026-10-06, after trying it
  unsaved). The save drops the editor's undo history unless the editor's
  "Undo after save" is on - Revert is the way back. Files nobody has open
  are rewritten on disk in their own
  encoding (PasLsp.SourceText). A unit nobody uses is also taken out of the
  project (IOTAProject.RemoveFile - which edits the .dpr's own uses), and
  the project is saved. A removed node leaves the tree; the rows left - the
  declarations too - are moved to the lines the edits left them on
  (MoveRows - on the client group every row under a removed interface clause pointed
  lines too low, 2026-10-06), and Revert puts back the positions it took.
  The tab is rebuilt (the ToolsAPI has no way to drop one row), and the
  selection is put on the node after the removed ones (SelectNode).

  REVERT takes the LAST Remove back, and again the one before - a stack.
  Every rewritten clause must still read what that Remove wrote, at the
  place it wrote it - the offsets are kept from the forward pass, shifted by
  what the earlier edits in the same file added or took away; the later
  Removes are already undone, so the text is the one it left. Anything else
  (the file was edited in between) refuses that Revert and names the file;
  Ctrl+Z in an open file and Revert again is the way out. Units taken out
  of the project are added back.

  Kept per Remove: the nodes, the edits and their offsets, the files taken
  out of the project - never an IDE interface, which the user can close
  under us (the Rename tab's lesson, see its unit).
}

interface

uses
  ToolsAPI;

/// <summary>Asks what to look for (the Unused dialog) about the file in
/// AView or its project, then searches.</summary>
procedure ExecuteUnused(const AView: IOTAEditView);

/// <summary>Drops the results tab because the project it describes is
/// closing.</summary>
procedure CloseUnusedUnitsResults;

/// <summary>Removes the tab and gates late callbacks off - from the
/// wizard's teardown, before FinalizeLspSession.</summary>
procedure FinalizeUnusedUnits;

implementation

uses
  System.SysUtils, System.StrUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults, System.UITypes, Vcl.Forms, Vcl.Dialogs,
  PasLsp.SourceText,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.ResultRows, PasTreeIdePlugin.RenameToolbar,
  PasTreeIdePlugin.WaitDialog, PasTreeIdePlugin.FormModules,
  PasTreeIdePlugin.UnusedForm;

const
  // One tab for every part (Alex, 2026-11-14). Without the "PasTree " the
  // other result tabs carry, as the three tabs before it (Alex, 2026-10-06).
  cMessageGroupName = 'Unused';
  cRemoveButton = 0;
  cRemoveAllButton = 1;
  cRevertButton = 2;

type
  // One edit as applied: the edit and its 0-based character offset in the
  // file's text (no BOM) BEFORE the forward pass.
  TAppliedEdit = record
    Edit: TLspUsesEdit;
    Offset: Integer;
  end;

  // A file's text and how to write it back.
  TEditTarget = record
    Path: string;
    Module: IOTAModule;      // nil: not open, Text is the file's
    Bom: Boolean;            // the buffer starts with a UTF-8 BOM
    Text: string;            // without a BOM
    Encoding: TPasSourceEncoding;
  end;

  // One Remove as made: the nodes it took out, its edits (with the offsets
  // of the forward pass), the units it took out of the project.
  TRemoval = record
    Nodes: TArray<Integer>;
    Edits: TArray<TAppliedEdit>;
    Units: TArray<string>;
    Before: TLspUnusedAnswer;   // the rows' positions before it, for Revert
  end;

  TNodeKind = (nkEntry, nkUnit, nkSymbol);

type
  // The tab and everything its toolbar works on.
  TUnusedTab = class
    Caption: string;                // the message group's name
    Group: IOTAMessageGroup;        // set once the tab was shown
    Options: TUnusedOptions;        // what the search asked for
    Answer: TLspUnusedAnswer;       // the three answers, doubts dropped unless asked
    TitleFile: string;
    Removals: TArray<TRemoval>;     // in order; Revert takes the last back
    // A shown row -> its nodes: one, or every node under a section row.
    RowNode: TDictionary<Pointer, TArray<Integer>>;
    TopNode: TArray<TArray<Integer>>;  // the top-level rows -> nodes, nil title
    // The removable nodes in the order shown, and the row each is selected
    // by (its `uses` line for an entry, its file row for a unit) - for the
    // selection after a Remove.
    ShownNode: TArray<Integer>;
    ShownRow: TArray<Pointer>;
    Busy: Boolean;                  // a Remove waits for its edits
    Generation: Integer;            // a new search or a closed tab
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
  end;

var
  GAlive: Boolean = True;
  { The tab. Every entry point - a search, a toolbar click, a server's
    answer, a queued selection - goes through UseTab, and everything runs
    on the main thread. }
  GTab: TUnusedTab;

constructor TUnusedTab.Create;
begin
  inherited Create;
  Caption := cMessageGroupName;
  RowNode := TDictionary<Pointer, TArray<Integer>>.Create;
end;

destructor TUnusedTab.Destroy;
begin
  RowNode.Free;
  inherited;
end;

procedure TUnusedTab.Clear;
begin
  Inc(Generation);
  Group := nil;
  Answer := Default(TLspUnusedAnswer);
  Removals := nil;
  TopNode := nil;
  ShownNode := nil;
  ShownRow := nil;
  Busy := False;
  RowNode.Clear;
end;

// Makes sure the tab exists; False once the package is going.
function UseTab: Boolean;
begin
  Result := GAlive;
  if not Result then
    Exit;
  if not Assigned(GTab) then
    GTab := TUnusedTab.Create;
end;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  LspLogToServer('unused: ' + AMessage);
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

procedure TellUser(const AText: string; AType: TMsgDlgType);
begin
  MessageDlg(AText, AType, [mbOK], 0);
end;

function GetOrCreateMessageGroup(
  const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  // Looked up every time: a tab the user closed is a group the IDE has
  // dropped, and the reference held here keeps only its object alive -
  // ShowMessageView on it was an access violation in TTabSet.SetTabIndex
  // (Alex, 2026-10-06: close the tab, search again).
  GTab.Group := AMessageServices.GetGroup(GTab.Caption);
  if not Assigned(GTab.Group) then
    GTab.Group := AMessageServices.AddMessageGroup(GTab.Caption);
  Result := GTab.Group;
end;

{ -------- the edits -------- }

// The 0-based offset of line ARow, character column ACol (both 1-based) in
// AText; -1 when there is no such line.
function OffsetOf(const AText: string; ARow, ACol: Integer): Integer;
var
  LLine, LPos: Integer;
begin
  Result := -1;
  LPos := 1;
  LLine := 1;
  while LLine < ARow do
  begin
    while (LPos <= Length(AText)) and (AText[LPos] <> #10) do
      Inc(LPos);
    if LPos > Length(AText) then
      Exit;
    Inc(LPos);
    Inc(LLine);
  end;
  Result := LPos - 1 + ACol - 1;
  if Result > Length(AText) then
    Result := -1;
end;

// The open module of APath, or nil. A module without a source editor (a
// project file's .dproj) counts as not open.
function SourceEditorOf(const AModule: IOTAModule): IOTASourceEditor;
begin
  Result := nil;
  if not Assigned(AModule) then
    Exit;
  for var LIdx := 0 to AModule.GetModuleFileCount - 1 do
    if Supports(AModule.GetModuleFileEditor(LIdx), IOTASourceEditor, Result)
    then
      Exit;
  Result := nil;
end;

function LoadTarget(const APath: string; out ATarget: TEditTarget;
  out AError: string): Boolean;
var
  LBytes: UTF8String;
begin
  ATarget := Default(TEditTarget);
  ATarget.Path := APath;
  AError := '';
  ATarget.Module := ModuleOf(APath);
  if Assigned(SourceEditorOf(ATarget.Module)) then
  begin
    LBytes := ReadModuleBufferUtf8(ATarget.Module);
    ATarget.Bom := (Length(LBytes) >= 3) and (LBytes[1] = #$EF) and
      (LBytes[2] = #$BB) and (LBytes[3] = #$BF);
    if ATarget.Bom then
      Delete(LBytes, 1, 3);
    ATarget.Text := UTF8ToString(LBytes);
    Exit(True);
  end;
  ATarget.Module := nil;
  Result := TryReadSourceForEdit(APath, ATarget.Text, ATarget.Encoding);
  if not Result then
    AError := ExtractFileName(APath) + ' could not be read';
end;

// The edits of one file in order, with the offsets this pass works at:
// forward, where the server saw them; backward, where the forward pass left
// them.
function TargetOffsets(const ATarget: TEditTarget;
  const AEdits: TArray<TAppliedEdit>; AForward: Boolean;
  out AOffsets: TArray<Integer>; out AError: string): Boolean;
var
  LShift: Integer;
  LExpected: string;
begin
  Result := False;
  AError := '';
  SetLength(AOffsets, Length(AEdits));
  LShift := 0;
  for var LIdx := 0 to High(AEdits) do
  begin
    if AForward then
    begin
      AOffsets[LIdx] := OffsetOf(ATarget.Text, AEdits[LIdx].Edit.Row,
        AEdits[LIdx].Edit.Col);
      LExpected := AEdits[LIdx].Edit.OldText;
    end
    else
    begin
      AOffsets[LIdx] := AEdits[LIdx].Offset + LShift;
      LExpected := AEdits[LIdx].Edit.NewText;
    end;
    Inc(LShift, Length(AEdits[LIdx].Edit.NewText) -
      Length(AEdits[LIdx].Edit.OldText));
    if (AOffsets[LIdx] < 0) or
       (Copy(ATarget.Text, AOffsets[LIdx] + 1, Length(LExpected)) <> LExpected)
    then
    begin
      if AForward then
        AError := Format('%s line %d no longer reads what the analysis saw ' +
          '- the file has changed since. Nothing was removed. Run the search ' +
          'again.', [ExtractFileName(ATarget.Path), AEdits[LIdx].Edit.Row])
      else
        AError := Format('%s has been edited since the Remove (line %d). ' +
          'Nothing was reverted. Undo the edit there and press Revert again.',
          [ExtractFileName(ATarget.Path), AEdits[LIdx].Edit.Row]);
      Exit;
    end;
  end;
  Result := True;
end;

// Writes AEdits into ATarget at AOffsets (ascending), forward or back.
procedure WriteTarget(var ATarget: TEditTarget;
  const AEdits: TArray<TAppliedEdit>; const AOffsets: TArray<Integer>;
  AForward: Boolean);
var
  LWriter: IOTAEditWriter;
  LFrom, LTo: string;
  LByte: Integer;
  LText: string;
begin
  if Assigned(ATarget.Module) then
  begin
    LWriter := SourceEditorOf(ATarget.Module).CreateUndoableWriter;
    for var LIdx := 0 to High(AEdits) do
    begin
      if AForward then
      begin
        LFrom := AEdits[LIdx].Edit.OldText;
        LTo := AEdits[LIdx].Edit.NewText;
      end
      else
      begin
        LFrom := AEdits[LIdx].Edit.NewText;
        LTo := AEdits[LIdx].Edit.OldText;
      end;
      // A writer counts UTF-8 bytes of the buffer, BOM included.
      LByte := Length(UTF8Encode(Copy(ATarget.Text, 1, AOffsets[LIdx])));
      if ATarget.Bom then
        Inc(LByte, 3);
      LWriter.CopyTo(LByte);
      LWriter.DeleteTo(LByte + Length(UTF8Encode(LFrom)));
      if LTo <> '' then
        LWriter.Insert(PAnsiChar(UTF8Encode(LTo)));
    end;
    LWriter := nil;
    NoteBufferModified(ATarget.Path);
    Exit;
  end;
  // On disk: spliced from the last edit back, so earlier offsets hold.
  LText := ATarget.Text;
  for var LIdx := High(AEdits) downto 0 do
  begin
    if AForward then
    begin
      LFrom := AEdits[LIdx].Edit.OldText;
      LTo := AEdits[LIdx].Edit.NewText;
    end
    else
    begin
      LFrom := AEdits[LIdx].Edit.NewText;
      LTo := AEdits[LIdx].Edit.OldText;
    end;
    LText := Copy(LText, 1, AOffsets[LIdx]) + LTo +
      Copy(LText, AOffsets[LIdx] + Length(LFrom) + 1, MaxInt);
  end;
  ATarget.Text := LText;
end;

{ Both passes, all or nothing: every file is read and every edit checked
  before the first is written. AEdits sorted by file, then position; on a
  forward pass their offsets are filled in. ADiskPaths: the files written on
  disk, for the server. }
function ApplyAll(var AEdits: TArray<TAppliedEdit>; AForward: Boolean;
  out ADiskPaths: TArray<string>; out AError: string): Boolean;
var
  LTargets: TList<TEditTarget>;
  LRanges: TList<TPair<Integer, Integer>>;   // first edit, count per target
  LOffsets: TList<TArray<Integer>>;
  LTarget: TEditTarget;
  LFirst, LLast: Integer;
  LOff: TArray<Integer>;
  LFileEdits: TArray<TAppliedEdit>;
begin
  Result := False;
  ADiskPaths := nil;
  AError := '';
  LTargets := TList<TEditTarget>.Create;
  LRanges := TList<TPair<Integer, Integer>>.Create;
  LOffsets := TList<TArray<Integer>>.Create;
  try
    // Pass one: read and check.
    LFirst := 0;
    while LFirst <= High(AEdits) do
    begin
      LLast := LFirst;
      while (LLast < High(AEdits)) and SameText(AEdits[LLast + 1].Edit.FilePath,
        AEdits[LFirst].Edit.FilePath) do
        Inc(LLast);
      if not LoadTarget(AEdits[LFirst].Edit.FilePath, LTarget, AError) then
      begin
        AError := AError + '. Nothing was ' + IfThen(AForward, 'removed',
          'reverted') + '.';
        Exit;
      end;
      LFileEdits := Copy(AEdits, LFirst, LLast - LFirst + 1);
      if not TargetOffsets(LTarget, LFileEdits, AForward, LOff, AError) then
        Exit;
      LTargets.Add(LTarget);
      LRanges.Add(TPair<Integer, Integer>.Create(LFirst, LLast - LFirst + 1));
      LOffsets.Add(LOff);
      LFirst := LLast + 1;
    end;
    // Pass two: write and save.
    for var LIdx := 0 to LTargets.Count - 1 do
    begin
      LTarget := LTargets[LIdx];
      LFileEdits := Copy(AEdits, LRanges[LIdx].Key, LRanges[LIdx].Value);
      if AForward then
        for var LE := 0 to High(LFileEdits) do
          AEdits[LRanges[LIdx].Key + LE].Offset := LOffsets[LIdx][LE];
      WriteTarget(LTarget, LFileEdits, LOffsets[LIdx], AForward);
      // An open module is saved, like every file written on disk - one
      // shape for all three checks (Alex, 2026-10-06).
      if Assigned(LTarget.Module) then
        LTarget.Module.Save(False, True)
      else if TryWriteSource(LTarget.Path, LTarget.Text, LTarget.Encoding) then
        ADiskPaths := ADiskPaths + [LTarget.Path]
      else
        LogDiagnostic(ExtractFileName(LTarget.Path) +
          ' could not be written - its edit is lost');
    end;
    Result := True;
  finally
    LOffsets.Free;
    LRanges.Free;
    LTargets.Free;
  end;
end;

{ -------- the project -------- }

function ProjectByFile(const AProjectFile: string): IOTAProject;
var
  LModuleServices: IOTAModuleServices;
  LGroup: IOTAProjectGroup;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  LGroup := LModuleServices.MainProjectGroup;
  if Assigned(LGroup) then
    for var LIdx := 0 to LGroup.ProjectCount - 1 do
      if SameText(LGroup.Projects[LIdx].FileName, AProjectFile) then
        Exit(LGroup.Projects[LIdx]);
end;

{ -------- the nodes -------- }

// The entries, then the units nobody uses, then the declarations.
function NodeCount: Integer;
begin
  Result := Length(GTab.Answer.Entries) + Length(GTab.Answer.Units) +
    Length(GTab.Answer.Symbols);
end;

// What ANode is, and its index in that kind's array.
function NodeKind(ANode: Integer; out AIndex: Integer): TNodeKind;
begin
  AIndex := ANode;
  if AIndex < Length(GTab.Answer.Entries) then
    Exit(nkEntry);
  Dec(AIndex, Length(GTab.Answer.Entries));
  if AIndex < Length(GTab.Answer.Units) then
    Exit(nkUnit);
  Dec(AIndex, Length(GTab.Answer.Units));
  Result := nkSymbol;
end;

function UnitNode(AIndex: Integer): Integer;
begin
  Result := Length(GTab.Answer.Entries) + AIndex;
end;

function SymbolNode(AIndex: Integer): Integer;
begin
  Result := Length(GTab.Answer.Entries) + Length(GTab.Answer.Units) + AIndex;
end;

function NodeRemoved(ANode: Integer): Boolean;
begin
  for var LRemoval in GTab.Removals do
    for var LN in LRemoval.Nodes do
      if LN = ANode then
        Exit(True);
  Result := False;
end;

// An entry Remove takes out: no doubt, and an edit can do it.
function EntryRemovable(const AEntry: TLspUnusedEntry): Boolean;
begin
  Result := (AEntry.Doubts = nil) and (AEntry.Refused = '');
end;

// Whether ANode has anything Remove takes out. A declaration never has.
function NodeRemovable(ANode: Integer): Boolean;
var
  LIdx: Integer;
begin
  case NodeKind(ANode, LIdx) of
    nkEntry: Result := EntryRemovable(GTab.Answer.Entries[LIdx]);
    nkUnit: Result := GTab.Answer.Units[LIdx].Doubts = nil;
  else
    Result := False;
  end;
end;

function NodeFile(ANode: Integer): string;
var
  LIdx: Integer;
begin
  case NodeKind(ANode, LIdx) of
    nkEntry: Result := GTab.Answer.Entries[LIdx].FilePath;
    nkUnit: Result := GTab.Answer.Units[LIdx].FilePath;
  else
    Result := GTab.Answer.Symbols[LIdx].FilePath;
  end;
end;

// What a message about ANode calls it: the unit for an entry, the file for
// a unit nobody uses, the name for a declaration.
function NodeName(ANode: Integer): string;
var
  LIdx: Integer;
begin
  case NodeKind(ANode, LIdx) of
    nkEntry: Result := GTab.Answer.Entries[LIdx].UnitName;
    nkUnit: Result := ExtractFileName(GTab.Answer.Units[LIdx].FilePath);
  else
    Result := GTab.Answer.Symbols[LIdx].Name;
  end;
end;

// The nodes left that Remove All takes.
function RemovableNodes: TArray<Integer>;
begin
  Result := nil;
  for var LNode := 0 to Length(GTab.Answer.Entries) +
    Length(GTab.Answer.Units) - 1 do
    if not NodeRemoved(LNode) and NodeRemovable(LNode) then
      Result := Result + [LNode];
end;

{ -------- the tab -------- }

function SnippetOf(ACache: TDictionary<string, TStringList>;
  const APath: string; ARow: Integer): string;
var
  LLines: TStringList;
begin
  if not ACache.TryGetValue(LowerCase(APath), LLines) then
  begin
    LLines := TStringList.Create;
    LLines.Text := LspSourceTextOf(APath);
    ACache.Add(LowerCase(APath), LLines);
  end;
  if (ARow >= 1) and (ARow <= LLines.Count) then
    Result := LLines[ARow - 1]
  else
    Result := '';
end;

procedure UpdateButtons;
begin
  SetResultToolbarEnabled(GTab.Caption, cRemoveButton,
    not GTab.Busy and (RemovableNodes <> nil));
  SetResultToolbarEnabled(GTab.Caption, cRemoveAllButton,
    not GTab.Busy and (RemovableNodes <> nil));
  SetResultToolbarEnabled(GTab.Caption, cRevertButton,
    not GTab.Busy and (GTab.Removals <> nil));
end;

procedure RemoveClick; forward;
procedure RemoveAllClick; forward;
procedure RevertClick; forward;

// ANodes grouped by NodeFile, in the order the files first come.
function ByFile(const ANodes: TArray<Integer>): TArray<TArray<Integer>>;
var
  LAt: TDictionary<string, Integer>;
  LIdx: Integer;
begin
  Result := nil;
  LAt := TDictionary<string, Integer>.Create;
  try
    for var LNode in ANodes do
    begin
      if not LAt.TryGetValue(LowerCase(NodeFile(LNode)), LIdx) then
      begin
        LIdx := Length(Result);
        SetLength(Result, LIdx + 1);
        LAt.Add(LowerCase(NodeFile(LNode)), LIdx);
      end;
      Result[LIdx] := Result[LIdx] + [LNode];
    end;
  finally
    LAt.Free;
  end;
end;

procedure Report;
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LCache: TObjectDictionary<string, TStringList>;
  LTitle: string;
  LEntries, LUnits, LSymbols: TArray<Integer>;
  LRemoved: Integer;
  LIdx: Integer;

  procedure Note(ANode: Integer; const ALeadIn, AText: string;
    AParent: Pointer);
  begin
    GTab.RowNode.AddOrSetValue(LMessageServices.AddCustomMessage(NewNoteRow(
      ALeadIn, AText), AParent), [ANode]);
  end;

  // A top-level row "ACaption (N)" standing for ANodes.
  function PartRow(const ACaption: string;
    const ANodes: TArray<Integer>): Pointer;
  var
    LCount: string;
  begin
    LCount := IntToStr(Length(ANodes));
    Result := LMessageServices.AddCustomMessagePtr(NewTitleRow(
      ACaption + ' (' + LCount + ')', Length(ACaption) + 3, Length(LCount)),
      LGroup);
    GTab.RowNode.AddOrSetValue(Result, ANodes);
    GTab.TopNode := GTab.TopNode + [ANodes];
  end;

  // A sub-row "ACaption (N)" under AParent standing for ANodes.
  function SectionRow(const ACaption: string; const ANodes: TArray<Integer>;
    AParent: Pointer): Pointer;
  var
    LCount: string;
  begin
    LCount := IntToStr(Length(ANodes));
    Result := LMessageServices.AddCustomMessage(NewTitleRow(
      ACaption + ' (' + LCount + ')', Length(ACaption) + 3, Length(LCount)),
      AParent);
    GTab.RowNode.AddOrSetValue(Result, ANodes);
  end;

  function FileRow(const APath: string; const ANodes: TArray<Integer>;
    AParent: Pointer): Pointer;
  begin
    Result := LMessageServices.AddCustomMessage(NewFileNameRow(APath),
      AParent);
    GTab.RowNode.AddOrSetValue(Result, ANodes);
  end;

  // An unused entry's `uses` line under AParent, and its notes under it.
  procedure EntryRow(ANode: Integer; AParent: Pointer);
  var
    LRowPtr: Pointer;
    LEntry: TLspUnusedEntry;
  begin
    LEntry := GTab.Answer.Entries[ANode];
    LRowPtr := LMessageServices.AddCustomMessage(NewSnippetRow(
      LEntry.FilePath, LEntry.Row, LEntry.Col, SnippetOf(LCache,
      LEntry.FilePath, LEntry.Row), LEntry.Col, LEntry.Len, '',
      LEntry.TypeSpans), AParent);
    GTab.RowNode.AddOrSetValue(LRowPtr, [ANode]);
    GTab.ShownNode := GTab.ShownNode + [ANode];
    GTab.ShownRow := GTab.ShownRow + [LRowPtr];
    for var LDoubt in LEntry.Doubts do
      Note(ANode, 'kept: ', LDoubt, LRowPtr);
    if (LEntry.Doubts = nil) and (LEntry.Refused <> '') then
      Note(ANode, 'not removable: ', LEntry.Refused, LRowPtr);
  end;

  // A declaration's line, its kind as the tag, its doubts under it.
  procedure SymbolRow(ANode: Integer; AParent: Pointer);
  var
    LRowPtr: Pointer;
    LSymbol: TLspUnusedSymbol;
    LIndex: Integer;
  begin
    NodeKind(ANode, LIndex);
    LSymbol := GTab.Answer.Symbols[LIndex];
    LRowPtr := LMessageServices.AddCustomMessage(NewSnippetRow(
      LSymbol.FilePath, LSymbol.Row, LSymbol.Col, SnippetOf(LCache,
      LSymbol.FilePath, LSymbol.Row), LSymbol.Col, LSymbol.Len, LSymbol.Kind,
      LSymbol.TypeSpans), AParent);
    GTab.RowNode.AddOrSetValue(LRowPtr, [ANode]);
    if LSymbol.Why <> '' then
      Note(ANode, '', LSymbol.Why, LRowPtr);
    for var LDoubt in LSymbol.Doubts do
      Note(ANode, 'doubt: ', LDoubt, LRowPtr);
  end;

  procedure DeclarationsPart;
  var
    LTop: Pointer;
  begin
    if LSymbols = nil then
      Exit;
    LTop := PartRow('declarations', LSymbols);
    if GTab.Answer.Skipped <> nil then
      GTab.RowNode.AddOrSetValue(LMessageServices.AddCustomMessage(
        NewNoteRow('not weighed: ', string.Join(', ', GTab.Answer.Skipped)),
        LTop), LSymbols);
    if not GTab.Options.Project then
      for var LNode in LSymbols do
        SymbolRow(LNode, LTop)
    else
      for var LFile in ByFile(LSymbols) do
      begin
        var LFileRow := FileRow(NodeFile(LFile[0]), LFile, LTop);
        for var LNode in LFile do
          SymbolRow(LNode, LFileRow);
      end;
  end;

  // The unit's entries of ASection under AParent; nothing when none is left.
  procedure UsesSection(const ASection: string; AParent: Pointer);
  var
    LNodes: TArray<Integer>;
    LRow: Pointer;
  begin
    LNodes := nil;
    for var LNode in LEntries do
      if SameText(GTab.Answer.Entries[LNode].Section, ASection) then
        LNodes := LNodes + [LNode];
    if LNodes = nil then
      Exit;
    LRow := SectionRow(ASection, LNodes, AParent);
    for var LNode in LNodes do
      EntryRow(LNode, LRow);
  end;

  procedure UsesPart;
  var
    LTop: Pointer;
  begin
    if LEntries = nil then
      Exit;
    LTop := PartRow('units in uses', LEntries);
    if not GTab.Options.Project then
    begin
      UsesSection('interface', LTop);
      UsesSection('implementation', LTop);
    end
    else
      for var LFile in ByFile(LEntries) do
      begin
        var LFileRow := FileRow(NodeFile(LFile[0]), LFile, LTop);
        for var LNode in LFile do
          EntryRow(LNode, LFileRow);
      end;
  end;

  procedure NobodyPart;
  var
    LTop, LFileRow: Pointer;
    LUnit: TLspUnreferencedEntry;
  begin
    if LUnits = nil then
      Exit;
    LTop := PartRow('units nobody uses', LUnits);
    for var LNode in LUnits do
    begin
      NodeKind(LNode, LIdx);
      LUnit := GTab.Answer.Units[LIdx];
      LFileRow := FileRow(LUnit.FilePath, [LNode], LTop);
      GTab.ShownNode := GTab.ShownNode + [LNode];
      GTab.ShownRow := GTab.ShownRow + [LFileRow];
      for var LDoubt in LUnit.Doubts do
        Note(LNode, 'kept: ', LDoubt, LFileRow);
      for var LBy in LUnit.ListedBy do
        GTab.RowNode.AddOrSetValue(LMessageServices.AddCustomMessage(
          NewSnippetRow(LBy.FilePath, LBy.Row, LBy.Col, SnippetOf(LCache,
          LBy.FilePath, LBy.Row), LBy.Col, LBy.Len, '', LBy.TypeSpans),
          LFileRow), [LNode]);
    end;
  end;

begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices)
  then
    Exit;
  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);
  GTab.RowNode.Clear;
  GTab.TopNode := [nil];
  GTab.ShownNode := nil;
  GTab.ShownRow := nil;
  LEntries := nil;
  LUnits := nil;
  LSymbols := nil;
  LRemoved := 0;
  for var LNode := 0 to NodeCount - 1 do
    if NodeRemoved(LNode) then
      Inc(LRemoved)
    else
      case NodeKind(LNode, LIdx) of
        nkEntry: LEntries := LEntries + [LNode];
        nkUnit: LUnits := LUnits + [LNode];
      else
        LSymbols := LSymbols + [LNode];
      end;
  LCache := TObjectDictionary<string, TStringList>.Create([doOwnsValues]);
  try
    // The title names what was searched, no counts: each part's row below
    // carries its own (0.89.6, Alex - the counts here only repeated them).
    if GTab.Options.Project then
      LTitle := 'Unused in ' + ExtractFileName(GTab.Answer.ProjectFile)
    else
      LTitle := 'Unused in ' + ExtractFileName(GTab.TitleFile);
    if LRemoved > 0 then
      LTitle := LTitle + Format(' - %d removed, Revert takes the last ' +
        'Remove back', [LRemoved]);
    LMessageServices.AddCustomMessage(NewTitleRow(LTitle), LGroup);

    DeclarationsPart;
    UsesPart;
    NobodyPart;
  finally
    LCache.Free;
  end;
  LMessageServices.ShowMessageView(LGroup);
  ShowResultToolbar(GTab.Caption, [
    ResultToolButton('Remove', 'EditDeleteCommand',
      procedure begin RemoveClick end),
    ResultToolButton('Remove All', 'EditDeleteCommand',
      procedure begin RemoveAllClick end),
    ResultToolButton('Revert', 'EditUndoCommand',
      procedure begin RevertClick end)]);
  UpdateButtons;
end;

{ -------- Remove / Revert -------- }

function SortedEdits(const AEdits: TArray<TLspUsesEdit>): TArray<TAppliedEdit>;
begin
  SetLength(Result, Length(AEdits));
  for var LIdx := 0 to High(AEdits) do
  begin
    Result[LIdx].Edit := AEdits[LIdx];
    Result[LIdx].Offset := -1;
  end;
  TArray.Sort<TAppliedEdit>(Result, TComparer<TAppliedEdit>.Construct(
    function(const A, B: TAppliedEdit): Integer
    begin
      Result := CompareText(A.Edit.FilePath, B.Edit.FilePath);
      if Result = 0 then
        Result := A.Edit.Row - B.Edit.Row;
      if Result = 0 then
        Result := A.Edit.Col - B.Edit.Col;
    end));
end;

{ -------- the rows' positions -------- }

// Where AText ends when it starts at ARow:ACol (1-based, character columns).
procedure EndOf(const AText: string; ARow, ACol: Integer;
  out AEndRow, AEndCol: Integer);
var
  LLastBreak: Integer;
begin
  AEndRow := ARow;
  LLastBreak := 0;
  for var LIdx := 1 to Length(AText) do
    if AText[LIdx] = #10 then
    begin
      Inc(AEndRow);
      LLastBreak := LIdx;
    end;
  if LLastBreak = 0 then
    AEndCol := ACol + Length(AText)
  else
    AEndCol := Length(AText) - LLastBreak + 1;
end;

function IsNameChar(C: Char): Boolean;
begin
  Result := CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '_', '.']) or
    (Ord(C) > 127);
end;

{ A row's ARow:ACol (its name ALen characters long) after AFrom, starting at
  AEditRow:AEditCol, became ATo. Before it: unchanged. After it: moved by
  what the edit added or took away. Inside it (an entry of the rewritten
  clause): wherever its name stands in ATo; left alone when it is not there
  - that row was removed and is not shown. }
procedure MapPosition(var ARow, ACol: Integer; ALen, AEditRow,
  AEditCol: Integer; const AFrom, ATo: string);
var
  LEndRow, LEndCol, LToRow, LToCol, LAt, LFound, LBreaks, LLastBreak: Integer;
  LName, LUpperTo: string;
begin
  if (ARow < AEditRow) or ((ARow = AEditRow) and (ACol < AEditCol)) then
    Exit;
  EndOf(AFrom, AEditRow, AEditCol, LEndRow, LEndCol);
  if (ARow > LEndRow) or ((ARow = LEndRow) and (ACol >= LEndCol)) then
  begin
    EndOf(ATo, AEditRow, AEditCol, LToRow, LToCol);
    if ARow = LEndRow then
      ACol := ACol - LEndCol + LToCol;
    Inc(ARow, LToRow - LEndRow);
    Exit;
  end;
  if ARow = AEditRow then
    LAt := OffsetOf(AFrom, 1, ACol - AEditCol + 1)
  else
    LAt := OffsetOf(AFrom, ARow - AEditRow + 1, ACol);
  if LAt < 0 then
    Exit;
  LName := UpperCase(Copy(AFrom, LAt + 1, ALen));
  LUpperTo := UpperCase(ATo);
  LFound := 0;
  LAt := Pos(LName, LUpperTo);
  while (LName <> '') and (LAt > 0) do
  begin
    if ((LAt = 1) or not IsNameChar(ATo[LAt - 1])) and
       ((LAt + Length(LName) > Length(ATo)) or
        not IsNameChar(ATo[LAt + Length(LName)])) then
    begin
      LFound := LAt;
      Break;
    end;
    LAt := PosEx(LName, LUpperTo, LAt + 1);
  end;
  if LFound = 0 then
    Exit;
  LBreaks := 0;
  LLastBreak := 0;
  for var LIdx := 1 to LFound - 1 do
    if ATo[LIdx] = #10 then
    begin
      Inc(LBreaks);
      LLastBreak := LIdx;
    end;
  ARow := AEditRow + LBreaks;
  if LBreaks = 0 then
    ACol := AEditCol + LFound - 1
  else
    ACol := LFound - LLastBreak;
end;

// GTab.Answer with arrays of its own, so moving GTab.Answer's rows leaves it alone.
function SnapshotAnswer: TLspUnusedAnswer;
begin
  Result := GTab.Answer;
  Result.Entries := Copy(GTab.Answer.Entries);
  Result.Units := Copy(GTab.Answer.Units);
  for var LIdx := 0 to High(Result.Units) do
    Result.Units[LIdx].ListedBy := Copy(GTab.Answer.Units[LIdx].ListedBy);
  Result.Symbols := Copy(GTab.Answer.Symbols);
end;

{ The rows of GTab.Answer moved to where AEdits (one Remove, sorted, in the
  coordinates of the text before it) left them - so a row clicked after a
  Remove still lands on its line. From the last edit back: each edit's
  coordinates still hold while only the ones after it have been made. }
procedure MoveRows(const AEdits: TArray<TAppliedEdit>);
begin
  for var LIdx := High(AEdits) downto 0 do
  begin
    var LEdit := AEdits[LIdx].Edit;
    for var LE := 0 to High(GTab.Answer.Entries) do
      if SameText(GTab.Answer.Entries[LE].FilePath, LEdit.FilePath) then
        MapPosition(GTab.Answer.Entries[LE].Row, GTab.Answer.Entries[LE].Col,
          GTab.Answer.Entries[LE].Len, LEdit.Row, LEdit.Col, LEdit.OldText,
          LEdit.NewText);
    for var LU := 0 to High(GTab.Answer.Units) do
      for var LB := 0 to High(GTab.Answer.Units[LU].ListedBy) do
        if SameText(GTab.Answer.Units[LU].ListedBy[LB].FilePath, LEdit.FilePath)
        then
          MapPosition(GTab.Answer.Units[LU].ListedBy[LB].Row,
            GTab.Answer.Units[LU].ListedBy[LB].Col,
            GTab.Answer.Units[LU].ListedBy[LB].Len, LEdit.Row, LEdit.Col,
            LEdit.OldText, LEdit.NewText);
    // A declaration is never inside a uses clause: only shifted.
    for var LS := 0 to High(GTab.Answer.Symbols) do
      if SameText(GTab.Answer.Symbols[LS].FilePath, LEdit.FilePath) then
        MapPosition(GTab.Answer.Symbols[LS].Row, GTab.Answer.Symbols[LS].Col,
          GTab.Answer.Symbols[LS].Len, LEdit.Row, LEdit.Col, LEdit.OldText,
          LEdit.NewText);
  end;
end;

procedure TellServer(const ADiskPaths: TArray<string>);
begin
  LspSyncDocuments;
  if ADiskPaths <> nil then
    LspFilesChangedOnDisk(ADiskPaths);
end;

{ What ANodes' Remove asks pastree/usesRemoval for, and the units it takes
  out of the project. An entry: itself, when removable. A unit nobody uses:
  every entry naming it, except in the program (RemoveFile edits that) and
  in a unit leaving the project too - now or with an earlier Remove. An
  entry in a unit leaving the project is left: the file goes. A name asked
  twice in one file (an unused entry naming a unit nobody uses) is asked
  once. A declaration has nothing to remove. }
function RemovalFiles(const ANodes: TArray<Integer>;
  out AUnits: TArray<string>): TArray<TLspRemovalFile>;
var
  LByFile: TDictionary<string, Integer>;   // lower-cased path -> index
  LGoing: TDictionary<string, Boolean>;
  LAt, LIdx: Integer;

  procedure Add(const APath, AName: string);
  begin
    if LGoing.ContainsKey(LowerCase(APath)) then
      Exit;
    if not LByFile.TryGetValue(LowerCase(APath), LAt) then
    begin
      LAt := Length(Result);
      SetLength(Result, LAt + 1);
      Result[LAt].FilePath := APath;
      LByFile.Add(LowerCase(APath), LAt);
    end;
    for var LName in Result[LAt].Names do
      if SameText(LName, AName) then
        Exit;
    Result[LAt].Names := Result[LAt].Names + [AName];
  end;

begin
  Result := nil;
  AUnits := nil;
  LByFile := TDictionary<string, Integer>.Create;
  LGoing := TDictionary<string, Boolean>.Create;
  try
    for var LNode in ANodes do
      if NodeKind(LNode, LIdx) = nkUnit then
      begin
        AUnits := AUnits + [GTab.Answer.Units[LIdx].FilePath];
        LGoing.AddOrSetValue(LowerCase(GTab.Answer.Units[LIdx].FilePath), True);
      end;
    for var LRemoval in GTab.Removals do
      for var LPath in LRemoval.Units do
        LGoing.AddOrSetValue(LowerCase(LPath), True);
    for var LNode in ANodes do
      case NodeKind(LNode, LIdx) of
        nkEntry:
          if EntryRemovable(GTab.Answer.Entries[LIdx]) then
            Add(GTab.Answer.Entries[LIdx].FilePath,
              GTab.Answer.Entries[LIdx].UnitName);
        nkUnit:
          for var LBy in GTab.Answer.Units[LIdx].ListedBy do
            if not LBy.IsProgram then
              Add(LBy.FilePath, GTab.Answer.Units[LIdx].UnitName);
      end;
  finally
    LGoing.Free;
    LByFile.Free;
  end;
end;

{ -------- the selection after a rebuild -------- }

// The node to select once AGone has left the tree: the first one shown
// after the last of them, else the last one shown before them; -1 when
// none is left.
// TArray.IndexOf<T> is Delphi 12+.
function IndexOfInt(const AItems: TArray<Integer>; AValue: Integer): Integer;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(AItems) do
    if AItems[LIdx] = AValue then
      Exit(LIdx);
  Result := -1;
end;

function NodeAfter(const AGone: TArray<Integer>): Integer;
var
  LLast, LFirst: Integer;
  LGone: Boolean;
begin
  Result := -1;
  LLast := -1;
  LFirst := -1;
  for var LIdx := 0 to High(GTab.ShownNode) do
    if IndexOfInt(AGone, GTab.ShownNode[LIdx]) >= 0 then
    begin
      if LFirst < 0 then
        LFirst := LIdx;
      LLast := LIdx;
    end;
  if LLast < 0 then
    Exit;
  for var LIdx := LLast + 1 to High(GTab.ShownNode) do
  begin
    LGone := IndexOfInt(AGone, GTab.ShownNode[LIdx]) >= 0;
    if not LGone then
      Exit(GTab.ShownNode[LIdx]);
  end;
  for var LIdx := LFirst - 1 downto 0 do
    if IndexOfInt(AGone, GTab.ShownNode[LIdx]) < 0 then
      Exit(GTab.ShownNode[LIdx]);
end;

// The row ANode is selected by, nil when it is not shown.
function ShownRowOf(ANode: Integer): Pointer;
begin
  Result := nil;
  for var LIdx := 0 to High(GTab.ShownNode) do
    if GTab.ShownNode[LIdx] = ANode then
      Exit(GTab.ShownRow[LIdx]);
end;

{ Selects ANode's row in the rebuilt tab (Alex, 2026-10-06: the selection
  stays on the next unit, so Remove can be pressed again). The ToolsAPI can
  only clear a group and fill it again, so the rows are new; the tree is
  told which one through RenameToolbar.ResultSelectRow. Tried at once and,
  if the tree has not taken the rows in yet, once more when the message
  queue is next empty. }
procedure SelectNode(ANode: Integer);
var
  LGeneration: Integer;
begin
  if (ANode < 0) or ResultSelectRow(ShownRowOf(ANode)) then
    Exit;
  LGeneration := GTab.Generation;
  TThread.ForceQueue(nil,
    procedure
    begin
      if UseTab and (LGeneration = GTab.Generation) and not
        ResultSelectRow(ShownRowOf(ANode)) then
        LspLogToServer('unused units: the row after the Remove could not be ' +
          'selected');
    end);
end;

// Makes one Remove of ANodes with AEdits (the server's, on the text as it
// is now).
procedure ApplyRemoval(const ANodes: TArray<Integer>;
  const AEdits: TArray<TLspUsesEdit>; const AUnits: TArray<string>);
var
  LNext: Integer;
  LRemoval: TRemoval;
  LDisk: TArray<string>;
  LError: string;
  LProject: IOTAProject;
begin
  LRemoval.Nodes := ANodes;
  LRemoval.Edits := SortedEdits(AEdits);
  LRemoval.Units := nil;
  if not ApplyAll(LRemoval.Edits, True, LDisk, LError) then
  begin
    TellUser(LError, mtError);
    Exit;
  end;
  LRemoval.Before := SnapshotAnswer;
  MoveRows(LRemoval.Edits);
  if AUnits <> nil then
  begin
    LProject := ProjectByFile(GTab.Answer.ProjectFile);
    if not Assigned(LProject) then
      LogDiagnostic(ExtractFileName(GTab.Answer.ProjectFile) + ' is not open - ' +
        'the units stay in it')
    else
    begin
      for var LPath in AUnits do
        try
          LProject.RemoveFile(LPath);
          LRemoval.Units := LRemoval.Units + [LPath];
        except
          on E: Exception do
            LogDiagnostic(Format('%s could not be taken out of the ' +
              'project: %s', [ExtractFileName(LPath), E.Message]));
        end;
      if LRemoval.Units <> nil then
        LProject.Save(False, True);
    end;
  end;
  GTab.Removals := GTab.Removals + [LRemoval];
  LspLogToServer(Format('unused units: Remove %d - %d node(s), %d clause ' +
    'edit(s), %d unit(s) out of the project', [Length(GTab.Removals),
    Length(ANodes), Length(LRemoval.Edits), Length(LRemoval.Units)]));
  // The server first: the rows read their snippets from the text it was
  // sent, which must be the edited one.
  TellServer(LDisk);
  LNext := NodeAfter(ANodes);
  Report;
  SelectNode(LNext);
end;

procedure StartRemoval(const ANodes: TArray<Integer>);
var
  LFiles: TArray<TLspRemovalFile>;
  LUnits: TArray<string>;
  LGeneration: Integer;
  LHasUnits: Boolean;
  LIdx: Integer;
begin
  LFiles := RemovalFiles(ANodes, LUnits);
  LHasUnits := False;
  for var LNode in ANodes do
    if NodeKind(LNode, LIdx) = nkUnit then
      LHasUnits := True;
  if LFiles = nil then
  begin
    // A unit only the program names: RemoveFile is all there is to do.
    ApplyRemoval(ANodes, nil, LUnits);
    Exit;
  end;
  GTab.Busy := True;
  UpdateButtons;
  LGeneration := GTab.Generation;
  LspUsesRemoval(GTab.TitleFile, LFiles,
    procedure(ASuccess: Boolean; const AAnswer: TLspUsesRemovalAnswer;
      const AError: string)
    begin
      if not UseTab or (LGeneration <> GTab.Generation) then
        Exit;
      GTab.Busy := False;
      try
        if not ASuccess then
        begin
          UpdateButtons;
          TellUser('Nothing was removed: ' + AError, mtError);
          Exit;
        end;
        for var LS in AAnswer.Missing do
          LogDiagnostic('no longer in the uses: ' + LS);
        if AAnswer.Refused <> nil then
        begin
          if not LHasUnits then
          begin
            // The clause changed since the search (a directive, a typo).
            UpdateButtons;
            TellUser('Nothing was removed - an entry cannot be taken out by ' +
              'an edit any more:'#13#10 + string.Join(#13#10,
              AAnswer.Refused) + #13#10'Run the search again.', mtError);
            Exit;
          end;
          // A unit leaving the project while a clause still names it builds
          // only while its file is found: said, and the unit still goes.
          for var LS in AAnswer.Refused do
            LogDiagnostic('an entry stays, remove it by hand: ' + LS);
        end;
        ApplyRemoval(ANodes, AAnswer.Edits, LUnits);
      except
        on E: Exception do
        begin
          UpdateButtons;
          LogDiagnostic(Format('Remove failed: %s: %s', [E.ClassName,
            E.Message]));
        end;
      end;
    end);
end;

{ The nodes of the row selected in the tree - one, or every node under a
  section row: by the row itself (one of the pointers ResultFocusedRow
  offers for it is the one AddCustomMessage handed back), the focused row
  before its parents. By its top-level position only when the top-level row
  itself is focused, or stands for one node: a row under a section must
  never stand for the section - that removed a whole interface clause on
  13.1 (Alex, 2026-10-06). nil when it cannot be told. }
function SelectedNodes: TArray<Integer>;
var
  LChain: TArray<TArray<Pointer>>;
  LTop: Integer;
begin
  Result := nil;
  if not ResultFocusedRow(LChain, LTop) or not Assigned(GTab.RowNode) then
    Exit;
  for var LDepth := 0 to High(LChain) do
    for var LSlot := 0 to High(LChain[LDepth]) do
      if GTab.RowNode.TryGetValue(LChain[LDepth][LSlot], Result) then
      begin
        LspLogDetail(Format('unused units: the selected row told by ' +
          'pointer %d at depth %d - %d node(s)', [LSlot, LDepth,
          Length(Result)]));
        Exit;
      end;
  if (LTop >= 0) and (LTop < Length(GTab.TopNode)) and
     ((Length(LChain) = 1) or (Length(GTab.TopNode[LTop]) = 1)) then
    Result := GTab.TopNode[LTop];
  LspLogDetail(Format('unused units: the selected row is not one of ours ' +
    'by pointer - depth %d, top index %d, %d node(s)', [High(LChain), LTop,
    Length(Result)]));
end;

procedure RemoveClick;
var
  LSelected, LNodes: TArray<Integer>;
  LIdx: Integer;
begin
  if not UseTab or GTab.Busy then
    Exit;
  try
    LSelected := nil;
    for var LNode in SelectedNodes do
      if (LNode >= 0) and (LNode < NodeCount) and not NodeRemoved(LNode) then
        LSelected := LSelected + [LNode];
    LNodes := nil;
    for var LNode in LSelected do
      if NodeRemovable(LNode) then
        LNodes := LNodes + [LNode];
    if LSelected = nil then
      TellUser('Select a unit in the ' + GTab.Caption + ' tab first: ' +
        'Remove takes out the selected one, Remove All every one.',
        mtInformation)
    else if LNodes = nil then
    begin
      if Length(LSelected) = 1 then
        TellUser(NodeName(LSelected[0]) + IfThen(NodeKind(LSelected[0],
          LIdx) = nkSymbol, ' is a declaration - declarations are only ' +
          'shown here, nothing removes them.', ' has a note - it stays.'),
          mtInformation)
      else
        TellUser('Nothing there can be removed: declarations are only ' +
          'shown, and every unit has a note.', mtInformation);
    end
    else
      StartRemoval(LNodes);
  except
    on E: Exception do
      LogDiagnostic(Format('Remove failed: %s: %s', [E.ClassName, E.Message]));
  end;
end;

procedure RemoveAllClick;
begin
  if not UseTab or GTab.Busy then
    Exit;
  try
    if RemovableNodes <> nil then
      StartRemoval(RemovableNodes);
  except
    on E: Exception do
      LogDiagnostic(Format('Remove All failed: %s: %s', [E.ClassName,
        E.Message]));
  end;
end;

procedure RevertClick;
var
  LDisk: TArray<string>;
  LError: string;
  LProject: IOTAProject;
  LRemoval: TRemoval;
begin
  if not UseTab or GTab.Busy or (GTab.Removals = nil) then
    Exit;
  try
    LRemoval := GTab.Removals[High(GTab.Removals)];
    if LRemoval.Units <> nil then
    begin
      LProject := ProjectByFile(GTab.Answer.ProjectFile);
      if not Assigned(LProject) then
      begin
        TellUser(ExtractFileName(GTab.Answer.ProjectFile) + ' is not open. ' +
          'Nothing was reverted.', mtError);
        Exit;
      end;
    end;
    if not ApplyAll(LRemoval.Edits, False, LDisk, LError) then
    begin
      TellUser(LError, mtError);
      Exit;
    end;
    if LRemoval.Units <> nil then
    begin
      for var LPath in LRemoval.Units do
        try
          LProject.AddFile(LPath, True);
        except
          on E: Exception do
            LogDiagnostic(Format('%s could not be added back: %s',
              [ExtractFileName(LPath), E.Message]));
        end;
      LProject.Save(False, True);
    end;
    // The rows back where they were before that Remove.
    GTab.Answer := LRemoval.Before;
    SetLength(GTab.Removals, Length(GTab.Removals) - 1);
    LspLogToServer(Format('unused units: reverted - %d clause edit(s), %d ' +
      'unit(s) back in the project', [Length(LRemoval.Edits),
      Length(LRemoval.Units)]));
    TellServer(LDisk);
    Report;
    if LRemoval.Nodes <> nil then
      SelectNode(LRemoval.Nodes[0]);
  except
    on E: Exception do
      LogDiagnostic(Format('Revert failed: %s: %s', [E.ClassName, E.Message]));
  end;
end;

{ -------- entry points -------- }

type
  TUnusedStep = (usSymbols, usUses, usNobody);

var
  // A search under way: a second one waits for it (the menu stays enabled).
  GSearching: Boolean;

// AAnswer without the rows that have a doubt.
function WithoutDoubts(const AAnswer: TLspUnusedAnswer): TLspUnusedAnswer;
begin
  Result := AAnswer;
  Result.Entries := nil;
  Result.Units := nil;
  Result.Symbols := nil;
  for var LEntry in AAnswer.Entries do
    if LEntry.Doubts = nil then
      Result.Entries := Result.Entries + [LEntry];
  for var LUnit in AAnswer.Units do
    if LUnit.Doubts = nil then
      Result.Units := Result.Units + [LUnit];
  SetLength(Result.Symbols, Length(AAnswer.Symbols));
  var LCount := 0;
  for var LSymbol in AAnswer.Symbols do
    if LSymbol.Doubts = nil then
    begin
      Result.Symbols[LCount] := LSymbol;
      Inc(LCount);
    end;
  SetLength(Result.Symbols, LCount);
end;

{ The search: the steps the options ask for, one request after the other,
  the wait dialog saying which of how many runs (one progress for the whole
  search - Alex, 2026-11-14). The answers are merged into one, and the tab
  is built once the last is in. A failed step ends the search: a partial
  tab would read as "nothing unused" where it was not looked for. Its state
  is GSearch, not captured: a step's callback starts the next step. }
const
  cStepText: array[TUnusedStep] of string = ('unused declarations',
    'unused units in uses clauses', 'units nobody uses');

var
  GSearch: record
    FileName: string;
    Options: TUnusedOptions;
    Steps: TArray<TUnusedStep>;
    Merged: TLspUnusedAnswer;
    Start: UInt64;
  end;

procedure EndSearch(const AError: string);
begin
  GSearching := False;
  GSearch.Merged := Default(TLspUnusedAnswer);
  CloseWaitDialog;
  LogDiagnostic(AError);
end;

procedure SearchStep(AStep: Integer); forward;

procedure StepDone(AStep: Integer; ASuccess: Boolean;
  const AAnswer: TLspUnusedAnswer; const AError: string);
begin
  if not GAlive then
  begin
    GSearching := False;
    Exit;
  end;
  if not ASuccess then
  begin
    EndSearch(cStepText[GSearch.Steps[AStep]] + ': ' + AError);
    Exit;
  end;
  try
    GSearch.Merged.ProjectFile := AAnswer.ProjectFile;
    case GSearch.Steps[AStep] of
      usSymbols:
        begin
          GSearch.Merged.Symbols := AAnswer.Symbols;
          GSearch.Merged.Skipped := AAnswer.Skipped;
        end;
      usUses: GSearch.Merged.Entries := AAnswer.Entries;
      usNobody: GSearch.Merged.Units := AAnswer.Units;
    end;
    SearchStep(AStep + 1);
  except
    on E: Exception do
      EndSearch(Format('unhandled %s: %s', [E.ClassName, E.Message]));
  end;
end;

procedure ShowResults;
var
  LAnswer: TLspUnusedAnswer;
  LOptions: TUnusedOptions;
  LFile: string;
begin
  LAnswer := GSearch.Merged;
  LOptions := GSearch.Options;
  LFile := GSearch.FileName;
  GSearch.Merged := Default(TLspUnusedAnswer);
  GSearching := False;
  LspLogToServer(Format('unused: %s search, %d step(s) - %d ' +
    'declarations, %d entries, %d units nobody uses, in %d ms',
    [IfThen(LOptions.Project, 'project', 'unit'), Length(GSearch.Steps),
    Length(LAnswer.Symbols), Length(LAnswer.Entries), Length(LAnswer.Units),
    TThread.GetTickCount64 - GSearch.Start]));
  if not LOptions.Doubts then
    LAnswer := WithoutDoubts(LAnswer);
  ReportUnderWaitDialog(Length(LAnswer.Entries) + Length(LAnswer.Units) +
    Length(LAnswer.Symbols),
    procedure
    begin
      if not UseTab then
        Exit;
      GTab.Clear;
      GTab.Options := LOptions;
      GTab.Answer := LAnswer;
      GTab.TitleFile := LFile;
      Report;
      // A new search only: after a Remove or a Revert the selection
      // (SelectNode) decides what is in view.
      ResultScrollToTop;
    end);
end;

procedure SearchStep(AStep: Integer);
var
  LScope: string;
  LDone: TLspUnusedProc;
begin
  if AStep > High(GSearch.Steps) then
  begin
    ShowResults;
    Exit;
  end;
  // No "Step i of n" line (0.89.3, Alex): the requests after the first
  // take a fraction of its time, so the line sat on step 1 for the whole
  // wait and told nothing. One message for the whole search.
  LDone :=
    procedure(ASuccess: Boolean; const AAnswer: TLspUnusedAnswer;
      const AError: string)
    begin
      StepDone(AStep, ASuccess, AAnswer, AError);
    end;
  LScope := IfThen(GSearch.Options.Project, 'project', 'unit');
  case GSearch.Steps[AStep] of
    usSymbols: LspUnusedSymbols(LScope, GSearch.FileName, LDone);
    usUses: LspUnusedUses(LScope, GSearch.FileName, LDone);
    usNobody: LspUnreferencedUnits(GSearch.FileName, LDone);
  end;
end;

procedure RunSearch(const AFile: string; const AOptions: TUnusedOptions);
begin
  GSearch.FileName := AFile;
  GSearch.Options := AOptions;
  GSearch.Steps := nil;
  if AOptions.Declarations then
    GSearch.Steps := GSearch.Steps + [usSymbols];
  if AOptions.UsesEntries then
    GSearch.Steps := GSearch.Steps + [usUses];
  if AOptions.SearchesNobodyUses then
    GSearch.Steps := GSearch.Steps + [usNobody];
  if GSearch.Steps = nil then
    Exit;
  GSearch.Merged := Default(TLspUnusedAnswer);
  GSearch.Start := TThread.GetTickCount64;
  GSearching := True;
  if AOptions.Project then
    ShowWaitDialog('Looking for unused code in ' +
      ExtractFileName(LspOwningProjectFile(AFile)) + '...')
  else
    ShowWaitDialog('Looking for unused code in ' + ExtractFileName(AFile) +
      '...');
  SearchStep(0);
end;

procedure ExecuteUnused(const AView: IOTAEditView);
var
  LFile: string;
  LOptions: TUnusedOptions;
begin
  try
    if not Assigned(AView) or not Assigned(AView.Buffer) or not UseTab then
      Exit;
    if GSearching then
    begin
      TellUser('A search for unused code is still running.', mtInformation);
      Exit;
    end;
    LFile := AView.Buffer.FileName;
    if not ExecuteUnusedDialog(LFile, LspOwningProjectFile(LFile), LOptions)
    then
      Exit;
    if GTab.Removals <> nil then
      if MessageDlg('The Removes made from the ' + GTab.Caption + ' tab ' +
        'can still be reverted there. A new search drops that. Search anyway?',
        mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
        Exit;
    RunSearch(LFile, LOptions);
  except
    on E: Exception do
    begin
      GSearching := False;
      CloseWaitDialog;
      LogDiagnostic(Format('unhandled %s: %s', [E.ClassName, E.Message]));
    end;
  end;
end;

// The tab, its toolbar and its state - also once GAlive is cleared, when
// UseTab no longer hands the tab out.
procedure DropGroups;
var
  LMessageServices: IOTAMessageServices;
begin
  if not Assigned(GTab) then
    Exit;
  HideResultToolbar(GTab.Caption);
  if Assigned(GTab.Group) and not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    try
      // Only while the tab is still there - see GetOrCreateMessageGroup.
      if Assigned(LMessageServices.GetGroup(GTab.Caption)) then
        LMessageServices.RemoveMessageGroup(
          LMessageServices.GetGroup(GTab.Caption));
    except
      // Cosmetic cleanup; there is no panel left to report a failure to.
    end;
  GTab.Clear;
end;

procedure CloseUnusedUnitsResults;
begin
  DropGroups;
end;

procedure FinalizeUnusedUnits;
begin
  GAlive := False;
  DropGroups;
  FreeAndNil(GTab);
end;

end.
