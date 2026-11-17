unit PasTreeIdePlugin.ImportGraph;

{
  Find All > Import Graph (0.90.0): through which units the program takes a
  unit in - the unit at the caret when it is a `uses` entry or the unit
  header, else the unit in the editor. PasTree 0.208.0's
  PasTree.Sema.ImportGraph, asked as pastree/importGraph; PasTree's demo
  shows the same answer as a tree of its own (docs/editor-features.md
  sec. 16 there).

  THE SERVER ANSWERS WITH THE WHOLE SUBGRAPH OF THE PATHS - every unit on a
  path from the program to the unit and every `uses` edge between them,
  each unit's importers nearest the program first - and the tree is grown
  here, in one tab, "Import Graph":

    - a title row: the steps and the shortest chain, the units on its paths;
    - a note under it naming the other programs that reach the unit, when
      there are any (until 0.92.1 also the units every path goes through
      and the entries whose removal alone drops the unit - the tree shows
      both, so Alex had them dropped);
    - the unit itself, and under every unit the units listing it, up to the
      program. A row is the importer's `uses` entry - "Importer.pas (12):
      implementation uses Unit - level 2" - and double-click opens it.

  THE PATHS ARE TOO MANY TO LIST, and the Messages panel builds every row
  up front - it has no lazy children. So a unit is expanded once, at its
  first place in the tree, depth first; a later row for it says "(see
  above)", a row for a unit already on its own chain "(cycle)". The tree is
  then exactly as large as the subgraph's edges - one row per edge - and is
  never cut (0.92.1): a cut at 3,000 rows left a unit's later importers out
  while the title named them, since depth first spends the rows on the
  first branch's subtree (Alex, 2026-11-17: the title's chain went through
  an importer the cut tree did not show). The panel adds a row in about
  0.4 ms (FindReferences' measurement), so 4,000 edges are under two
  seconds, with the count on the wait dialog.

  THE FIRST BRANCH IS THE TITLE'S CHAIN. The server orders a unit's
  importers nearest the program first, which makes the first branch a
  shortest chain - but not necessarily the one the title names when two
  importers are at the same level. Each edge of the chain is put first
  among its unit's importers, so the title and the tree's first branch
  read the same.

  An entry every path takes - removing that one entry drops the unit - has
  the listed unit's name marked (bold, underlined), the way the demo puts
  such a row in bold; nothing else is marked.
}

interface

uses
  ToolsAPI;

/// <summary>Entry point of the Find All > Import Graph item.</summary>
procedure ExecuteImportGraph(const AView: IOTAEditView);

/// <summary>Removes the tab and closes the callback gate - once, from
/// TIDEWizard.Destroy, before FinalizeLspSession (FindHierarchy's
/// reason).</summary>
procedure FinalizeImportGraph;

/// <summary>Drops the tab: the project it describes is closing.</summary>
procedure CloseImportGraphResults;

implementation

uses
  Winapi.Windows,
  System.SysUtils, System.StrUtils, System.Generics.Collections,
  Vcl.Dialogs, Vcl.Forms,
  PasTreeIdePlugin.IdeUI, PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.ResultRows, PasTreeIdePlugin.WaitDialog,
  PasTreeIdePlugin.RenameToolbar;

const
  cTabName = 'Import Graph';

var
  GGroup: IOTAMessageGroup;
  // The teardown gate - PasTreeIdePlugin.FindReferences.GAlive's reason.
  GAlive: Boolean = True;
  GRunning: Boolean;

procedure RemoveGroup;
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
begin
  // Not at IDE shutdown, and only a tab the IDE still has - FindHierarchy's
  // RemoveGroups gives both reasons.
  if Assigned(GGroup) and not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    try
      LGroup := LMessageServices.GetGroup(cTabName);
      if Assigned(LGroup) then
        LMessageServices.RemoveMessageGroup(LGroup);
    except
      // Cosmetic cleanup; nothing to report to.
    end;
  GGroup := nil;
end;

procedure FinalizeImportGraph;
begin
  GAlive := False;
  RemoveGroup;
end;

procedure CloseImportGraphResults;
begin
  RemoveGroup;
end;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  LspLogToServer(AMessage);
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

function GetOrCreateGroup(
  const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  // Looked up every time: a tab the user closed is a group the IDE dropped.
  GGroup := AMessageServices.GetGroup(cTabName);
  if not Assigned(GGroup) then
    GGroup := AMessageServices.AddMessageGroup(cTabName);
  Result := GGroup;
end;

function NamesOf(const AGraph: TLspImportGraph;
  const AUnits: TArray<Integer>): string;
begin
  Result := '';
  for var LU in AUnits do
    Result := Result + IfThen(Result <> '', ', ') + AGraph.Units[LU].Name;
end;

procedure Report(const AGraph: TLspImportGraph);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LImporters: TArray<TArray<Integer>>;
  LExpanded: TArray<Boolean>;
  LOnChain: TArray<Boolean>;
  LRows: Integer;
  LStart, LTick: UInt64;
  LTarget: TLspImportUnit;
  LHead, LCount, LChain: string;
  LList: TArray<Integer>;
  LTop: Pointer;

  // The row of edge AEdge (importer -> its parent), under AParent.
  function AddEdgeRow(AEdge: Integer; AParent: Pointer;
    const ASuffix: string): Pointer;
  var
    LEdge: TLspImportEdge;
    LFrom: TLspImportUnit;
    LText, LListed: string;
    LMatch, LLen: Integer;
  begin
    LEdge := AGraph.Edges[AEdge];
    LFrom := AGraph.Units[LEdge.FromUnit];
    LListed := AGraph.Units[LEdge.ToUnit].Name;
    if LFrom.IsRoot then
      LText := 'uses '
    else if LEdge.InImpl then
      LText := 'implementation uses '
    else
      LText := 'interface uses ';
    LMatch := 0;
    LLen := 0;
    if LEdge.Sole then
    begin
      LMatch := Length(LText) + 1;
      LLen := Length(LListed);
    end;
    LText := LText + LListed + Format(' - level %d', [LFrom.Level]) +
      ASuffix;
    if LEdge.FilePath <> '' then
      Result := LMessageServices.AddCustomMessage(NewSnippetRow(
        LEdge.FilePath, LEdge.Row, LEdge.Col, LText, LMatch, LLen, ''),
        AParent)
    else
      // No position: the importer itself, at its top.
      Result := LMessageServices.AddCustomMessage(NewSnippetRow(
        LFrom.FilePath, 1, 1, LText, LMatch, LLen, ''), AParent);
    Inc(LRows);
    // How far the list is, on the wait dialog it is filled under - a few
    // times a second, not per row (FindReferences' rule).
    if GetTickCount64 - LTick >= 200 then
    begin
      UpdateWaitDialogWork(Format('Listing results: %d of %d',
        [LRows, Length(AGraph.Edges)]));
      LTick := GetTickCount64;
    end;
  end;

  procedure AddImporters(AUnit: Integer; AParent: Pointer);
  var
    LFrom: Integer;
    LRow: Pointer;
  begin
    LExpanded[AUnit] := True;
    LOnChain[AUnit] := True;
    try
      for var LE in LImporters[AUnit] do
      begin
        LFrom := AGraph.Edges[LE].FromUnit;
        if LOnChain[LFrom] then
          AddEdgeRow(LE, AParent, ' (cycle)')
        else if LExpanded[LFrom] and (LImporters[LFrom] <> nil) then
          AddEdgeRow(LE, AParent, ' (see above)')
        else
        begin
          LRow := AddEdgeRow(LE, AParent, '');
          AddImporters(LFrom, LRow);
        end;
      end;
    finally
      LOnChain[AUnit] := False;
    end;
  end;

begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;
  LGroup := GetOrCreateGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);
  LTarget := AGraph.Units[AGraph.Target];

  LHead := Format('PasTree Import Graph: "%s" - ', [LTarget.Name]);
  if AGraph.Root < 0 then
  begin
    LMessageServices.AddCustomMessagePtr(NewTitleRow(LHead +
      'no program of the project takes it in'), LGroup);
    LMessageServices.ShowMessageView(LGroup);
    Exit;
  end;
  LChain := AGraph.Units[AGraph.Root].Name;
  for var LE in AGraph.Chain do
    LChain := LChain + ' -> ' + AGraph.Units[AGraph.Edges[LE].ToUnit].Name;
  LCount := IntToStr(Length(AGraph.Chain));
  // The other roots are in Units too, off the paths (level -1).
  LRows := 0;
  for var LU in AGraph.Units do
    if LU.Level >= 0 then
      Inc(LRows);
  LTop := LMessageServices.AddCustomMessagePtr(NewTitleRow(LHead + LCount +
    Format(' step(s) from %s: %s; %d unit(s) on its paths',
    [AGraph.Units[AGraph.Root].Name, LChain, LRows]), Length(LHead) + 1,
    Length(LCount)), LGroup);

  // No notes for the bottlenecks and the sole entries (0.92.1, Alex: they
  // repeat the tree) - the first branch is the chain they lie on, and a sole
  // entry has the listed name marked in its row. The other programs reaching
  // the unit are not in the tree, so they keep theirs.
  LList := nil;
  for var LR in AGraph.Roots do
    if LR <> AGraph.Root then
      LList := LList + [LR];
  if LList <> nil then
    LMessageServices.AddCustomMessage(NewNoteRow('also taken in by: ',
      NamesOf(AGraph, LList)), LTop);

  // Each unit's importers, in the server's order (nearest the root first),
  // then the title's chain moved to the front - see the unit header.
  SetLength(LImporters, Length(AGraph.Units));
  for var LE := 0 to High(AGraph.Edges) do
    LImporters[AGraph.Edges[LE].ToUnit] :=
      LImporters[AGraph.Edges[LE].ToUnit] + [LE];
  for var LE in AGraph.Chain do
  begin
    var LTo := AGraph.Edges[LE].ToUnit;
    var LAt := -1;
    for var LI := 0 to High(LImporters[LTo]) do
      if LImporters[LTo][LI] = LE then
        LAt := LI;
    if LAt > 0 then
    begin
      Delete(LImporters[LTo], LAt, 1);
      Insert(LE, LImporters[LTo], 0);
    end;
  end;
  SetLength(LExpanded, Length(AGraph.Units));
  SetLength(LOnChain, Length(AGraph.Units));
  LRows := 0;
  LStart := GetTickCount64;
  LTick := LStart;
  LTop := LMessageServices.AddCustomMessagePtr(NewSnippetRow(
    LTarget.FilePath, 1, 1, LTarget.Name + Format(' - level %d',
    [LTarget.Level]), 1, 0, ''), LGroup);
  AddImporters(AGraph.Target, LTop);
  LspLogDetail(Format('importGraph: report of %d rows for %d edge(s) in %d ms',
    [LRows, Length(AGraph.Edges), GetTickCount64 - LStart]));

  LMessageServices.ShowMessageView(LGroup);
  ResultScrollToTop;
end;

procedure ExecuteImportGraph(const AView: IOTAEditView);
var
  LFile: string;
begin
  try
    if not Assigned(AView) or not Assigned(AView.Buffer) then
      Exit;
    if GRunning then
    begin
      IdeMessageDlg('The import graph is still being built.', mtInformation,
        [mbOK]);
      Exit;
    end;
    LFile := AView.Buffer.FileName;
    GRunning := True;
    ShowWaitDialog('Building the import graph...');
    LspImportGraph(LFile, AView.Buffer.EditPosition.Row,
      AView.Buffer.EditPosition.Column, '',
      procedure(ASuccess: Boolean; const AGraph: TLspImportGraph;
        const AError: string)
      begin
        GRunning := False;
        if not GAlive then
          Exit;   // package unloading - nothing here may touch the IDE
        if not ASuccess then
        begin
          CloseWaitDialog;
          LogDiagnostic('Import Graph: ' + AError);
          Exit;
        end;
        ReportUnderWaitDialog(Length(AGraph.Edges) + 1,
          procedure
          begin
            Report(AGraph);
          end);
      end);
  except
    on E: Exception do
    begin
      GRunning := False;
      CloseWaitDialog;
      LogDiagnostic(Format('Import Graph: unhandled %s: %s',
        [E.ClassName, E.Message]));
    end;
  end;
end;

end.
