unit PasTreeIdePlugin.FindDefines;

{
  "Defines at cursor" and "Options at cursor" entry points, wired to the
  editor's Find All submenu (see PasTreeIdePlugin.Wizard) - the IDE side of
  PasTree 0.28.0's DefinesAt and 0.112.0's OptionsAt
  (docs/editor-features.md section 10 in the PasTree repo owns the
  contract).

  "Find All > Defines", the project-wide inventory (`pastree/findDefines`),
  was the third command here until 0.94.4, when Alex dropped it as of little
  use (2026-11-19); the server still answers the method.

  Modeled on PasTreeIdePlugin.FindReferences, which owns the longer story on
  why this runs out of process. Three differences from that unit:

    - NO SNIPPET LOOKUP, and no TSnippetCache: these rows carry their own
      line AND the span to highlight in it, so nothing here re-reads a
      source line (see DisplaySnippet - pairing the server's span with any
      other text is what produced two wrong highlights on 2026-09-14).


    - BOTH commands need NO IDENTITY at the caret - `pastree/definesAt`
      replays the model's define state up to the cursor, and
      `pastree/optionsAt` its option state - so neither can answer "nothing
      here" the way a reference search can. They are always offered (no
      findAllAt gate, unlike the seven Find All commands - see SPEC.md).

    - PROJECT-SCOPED, DELIBERATELY, unlike Find References: LspDefinesAt
      and LspOptionsAt ask only the active file's own server
      (LspSession.SessionForRequest), never LspXxxInGroup. A conditional
      symbol is a project-local fact - PasTree's docs note plainly that a
      $DEFINE is unit-local and a define one project of a group makes is not
      in effect in another project's compile at all - so a group-wide merge
      would answer a question nobody asked, unlike a shared unit's
      references, which really are one fact seen from two closures.

  Two commands, a Messages tab each ("Defines at cursor", "Options at
  cursor"), cleared and rebuilt by the next call of the same command - they
  shared one tab until 0.94.4, where the second answer wiped out the first
  (Alex, 2026-11-19). `Defines at cursor` is a FLAT list, one row per name
  in effect, each showing the $DEFINE that put it there; `Options at cursor`
  is the same question about compiler options - what an $IFOPT written
  there would see - asked and shown the same way.
}

interface

uses
  ToolsAPI;

/// <summary>Defines at cursor: the flat in-effect set.</summary>
procedure ExecuteDefinesAtCursor(const AView: IOTAEditView);

/// <summary>Options at cursor: the compiler options in effect.</summary>
procedure ExecuteOptionsAtCursor(const AView: IOTAEditView);

/// <summary>
/// Removes the two Messages tabs - call once from
/// TIDEWizard.Destroy, before FinalizeLspSession, exactly as
/// FinalizeFindReferencesMessageGroup does and for the same reason (see its
/// own header comment: a callback landing after the group's vtable is
/// unloaded is the dangling-code AV this package has already been bitten by).
/// </summary>
procedure FinalizeFindDefinesMessageGroup;

/// <summary>Drops the results tabs because the project they describe is closing.</summary>
procedure CloseFindDefinesResults;

implementation

uses
  System.SysUtils,
  PasTreeIdePlugin.IdeUI, PasTreeIdePlugin.LspSession, PasTreeIdePlugin.ResultRows,
  PasTreeIdePlugin.WaitDialog, PasTreeIdePlugin.RenameToolbar,
  PasTreeIdePlugin.FindReferences;   // GetOrCreateResultTab, RemoveResultTabs

const
  // The tabs' names: the menu items' captions, as the Find All family's
  // tabs are named after their commands (FindReferences.GetOrCreateResultTab,
  // whose registry these two share).
  cDefinesTabName = 'Defines at cursor';
  cOptionsTabName = 'Options at cursor';

var
  // The teardown gate - see FindReferences.GAlive for the crash it prevents.
  GAlive: Boolean = True;

// Not at IDE shutdown - see FindReferences.FinalizeFindReferencesMessageGroup
// for the AV this guards against; RemoveResultTabs honours it.
procedure FinalizeFindDefinesMessageGroup;
begin
  GAlive := False;
  RemoveResultTabs;
end;

procedure CloseFindDefinesResults;
begin
  RemoveResultTabs;
end;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  LspLogToServer(AMessage);
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ THE SNIPPET IS THE SERVER'S, AND SO IS THE SPAN - they only mean anything
  TOGETHER, which is the whole story of two wrong highlights in a row
  (screenshots, 2026-09-14).

  PasTree frames each row itself: for a $DEFINE site the snippet is the
  source line and hiFrom/hiTo span the name inside it; for a project or
  platform define, which has no source site, the snippet is THE NAME ITSELF
  and the span covers that. Pairing either span with any other text is a
  highlight on the wrong characters - first against a name-prefixed line
  (the underline sat on "{$DEFIN"), then against the main module's own
  `program ClientApp;`, which a 10-character MSWINDOWS span turned into
  "program C".

  So the line is never re-read locally. Find References has to read one -
  an LSP Location carries no text at all - but these rows arrive with
  theirs, from the same snapshot the answer was computed over, which is
  exactly what a re-read was buying there. TrimRight only: hiFrom/hiTo are
  offsets from the START of the snippet, so trimming the left would move
  every one of them.

  AND NOTHING IS PUT IN FRONT OF IT. A row read the name, a colon, and then
  the very same name inside its own directive, until Alex asked for the
  duplicate to go (2026-09-14): the name is already in the directive,
  highlighted, and the file and line ahead of it are the result row's own
  (PasTreeIdePlugin.ResultRows). A project or platform define wanted no
  prefix either - its snippet IS the name. Which leaves the span usable
  exactly as it arrived, with nothing to shift it by - the mistake the
  prefix kept reintroducing. }
function DisplaySnippet(const ARow: TLspDefineRow;
  out AMatchStart, AMatchLen: Integer): string;
begin
  AMatchStart := 0;
  AMatchLen := 0;
  Result := TrimRight(ARow.Snippet);
  if Result = '' then
    Exit(ARow.Name);
  if (ARow.HiTo > ARow.HiFrom) and (ARow.HiFrom >= 0) and
     (ARow.HiTo <= Length(Result)) then
  begin
    AMatchStart := ARow.HiFrom + 1;   // 0-based -> 1-based
    AMatchLen := ARow.HiTo - ARow.HiFrom;
  end;
end;

function OriginTag(const ARow: TLspDefineRow): string;
begin
  if not ARow.Active then
    Result := 'inactive'
  else if ARow.Origin = 'project' then
    Result := 'project'
  else if ARow.Origin = 'platform' then
    Result := 'platform'
  else
    Result := '';
end;

/// <summary>
/// Defines at cursor: a flat list, one row per name in effect, prefixed with
/// the defining file and line - no grouping, since "in effect here" is
/// already the whole answer.
/// </summary>
procedure ReportDefinesAt(const ARows: TArray<TLspDefineRow>);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LRow: TLspDefineRow;
  LDisplay: string;
  LMatchStart, LMatchLen: Integer;
begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;
  LGroup := GetOrCreateResultTab(LMessageServices, cDefinesTabName, '');
  LMessageServices.ClearMessageGroup(LGroup);
  LMessageServices.AddCustomMessagePtr(
    NewTitleRow(Format('PasTree Defines at cursor: %d name(s) in effect',
      [Length(ARows)])), LGroup);

  for LRow in ARows do
  begin
    LDisplay := DisplaySnippet(LRow, LMatchStart, LMatchLen);
    LMessageServices.AddCustomMessagePtr(
      NewSnippetRow(LRow.Hit.FilePath, LRow.Hit.Row, LRow.Hit.Col,
        LDisplay, LMatchStart, LMatchLen, OriginTag(LRow),
        LRow.Hit.TypeSpans),
      LGroup);
  end;
  LMessageServices.ShowMessageView(LGroup);
  ResultScrollToTop;
end;

{ An option row's text and span. A `project` or `default` row arrives as a
  base define's does - its snippet IS the row's text (`$R- RANGECHECKS
  OFF`), highlighted whole - so DisplaySnippet shows it as it is, tagged
  with its origin. A `unit` row's snippet is the directive's line and its
  span the directive, and here the row's text DOES go in front: unlike a
  define's name, the option is not always readable from the directive -
  the group `$R-,Q+` sets two, and after a $POPOPT the row points at the directive
  that set the value before the $PUSHOPT. The span is shifted by exactly
  the prefix put in front of it, the one place it moves. }
function OptionDisplay(const ARow: TLspDefineRow;
  out AMatchStart, AMatchLen: Integer): string;
var
  LPrefix: string;
begin
  Result := DisplaySnippet(ARow, AMatchStart, AMatchLen);
  if (ARow.Origin <> 'unit') or (TrimRight(ARow.Snippet) = '') then
    Exit;
  LPrefix := ARow.Name + ' - ';
  Result := LPrefix + Result;
  if AMatchLen > 0 then
    AMatchStart := AMatchStart + Length(LPrefix);
end;

/// <summary>
/// Options at cursor: a flat list, one row per option, in the server's
/// order - dcc's defaults, the project's switches, then the ones a directive
/// set, by file and line.
/// </summary>
procedure ReportOptionsAt(const ARows: TArray<TLspDefineRow>);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LRow: TLspDefineRow;
  LDisplay, LTag: string;
  LMatchStart, LMatchLen, LUnitRows: Integer;
begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;
  LUnitRows := 0;
  for LRow in ARows do
    if LRow.Origin = 'unit' then
      Inc(LUnitRows);
  LGroup := GetOrCreateResultTab(LMessageServices, cOptionsTabName, '');
  LMessageServices.ClearMessageGroup(LGroup);
  LMessageServices.AddCustomMessagePtr(
    NewTitleRow(Format('PasTree Options at cursor: %d option(s), %d set in units',
      [Length(ARows), LUnitRows])), LGroup);

  for LRow in ARows do
  begin
    LDisplay := OptionDisplay(LRow, LMatchStart, LMatchLen);
    if LRow.Origin = 'unit' then
      LTag := ''
    else
      LTag := LRow.Origin;
    LMessageServices.AddCustomMessagePtr(
      NewSnippetRow(LRow.Hit.FilePath, LRow.Hit.Row, LRow.Hit.Col,
        LDisplay, LMatchStart, LMatchLen, LTag, LRow.Hit.TypeSpans),
      LGroup);
  end;
  LMessageServices.ShowMessageView(LGroup);
  ResultScrollToTop;
end;

procedure ExecuteDefinesAtCursor(const AView: IOTAEditView);
var
  LCursorFile: string;
  LRow, LCol: Integer;
begin
  try
    if not Assigned(AView) then
      Exit;
    LCursorFile := AView.Buffer.FileName;
    LRow := AView.Buffer.EditPosition.Row;
    LCol := AView.Buffer.EditPosition.Column;
    ShowWaitDialog('Finding defines at cursor...');
    LspLogDetail(Format('definesAt: asking %s(%d,%d)',
      [ExtractFileName(LCursorFile), LRow, LCol]));
    LspDefinesAt(LCursorFile, LRow, LCol,
      procedure(ASuccess: Boolean; const ARows: TArray<TLspDefineRow>;
        const AError: string)
      begin
        LspLogDetail(Format('definesAt: answer ok=%s rows=%d err=%s',
          [BoolToStr(ASuccess, True), Length(ARows), AError]));
        if not GAlive then
          Exit;
        if not ASuccess then
        begin
          CloseWaitDialog;   // as above
          LogDiagnostic('Defines at cursor: ' + AError);
          Exit;
        end;
        ReportUnderWaitDialog(Length(ARows),
          procedure
          begin
            ReportDefinesAt(ARows);
          end);
      end);
  except
    on E: Exception do
    begin
      CloseWaitDialog;
      LogDiagnostic(Format('Defines at cursor: unhandled %s: %s',
        [E.ClassName, E.Message]));
    end;
  end;
end;

procedure ExecuteOptionsAtCursor(const AView: IOTAEditView);
var
  LCursorFile: string;
  LRow, LCol: Integer;
begin
  try
    if not Assigned(AView) then
      Exit;
    LCursorFile := AView.Buffer.FileName;
    LRow := AView.Buffer.EditPosition.Row;
    LCol := AView.Buffer.EditPosition.Column;
    ShowWaitDialog('Finding options at cursor...');
    LspLogDetail(Format('optionsAt: asking %s(%d,%d)',
      [ExtractFileName(LCursorFile), LRow, LCol]));
    LspOptionsAt(LCursorFile, LRow, LCol,
      procedure(ASuccess: Boolean; const ARows: TArray<TLspDefineRow>;
        const AError: string)
      begin
        LspLogDetail(Format('optionsAt: answer ok=%s rows=%d err=%s',
          [BoolToStr(ASuccess, True), Length(ARows), AError]));
        if not GAlive then
          Exit;
        if not ASuccess then
        begin
          CloseWaitDialog;   // as above
          LogDiagnostic('Options at cursor: ' + AError);
          Exit;
        end;
        ReportUnderWaitDialog(Length(ARows),
          procedure
          begin
            ReportOptionsAt(ARows);
          end);
      end);
  except
    on E: Exception do
    begin
      CloseWaitDialog;
      LogDiagnostic(Format('Options at cursor: unhandled %s: %s',
        [E.ClassName, E.Message]));
    end;
  end;
end;

end.
