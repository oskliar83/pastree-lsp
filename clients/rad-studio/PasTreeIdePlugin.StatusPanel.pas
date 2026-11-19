unit PasTreeIdePlugin.StatusPanel;

{
  THE ANALYSIS STATUS IN THE EDITOR'S STATUS BAR - "PasTree: Ready",
  "PasTree: analyzing (inc)...", "PasTree: analyzing...", in a panel of our own
  appended to every edit window's status bar (INTAEditWindow.StatusBar).

  DATA: the server's `$/progress` stream. The server opens one per analysis
  run, titled by its kind (PasLsp.Server, cProgressTitleFull /
  cProgressTitleIncremental), and one for a request that makes library
  bodies full before it answers (cProgressTitleLibrary - "library bodies...",
  whose report line also goes under the running command's wait dialog),
  and TLspClient keeps the run in progress
  (Activity, ActivitySince); LspServerStatusFor routes a file to the server
  that answers it - its owning project's in a group - without creating a
  session.

  A RUN SHORTER THAN cBusyAfterMs IS NOT SHOWN. Most incremental runs end in
  tens of milliseconds, one per typing pause, and a panel switching to
  "analyzing (inc)" and back on each would be a flicker, not information (Alex,
  2026-10-01: 250 ms). Past that the dots move every tick, so a long run
  visibly is one.

  POLLED, every cTickMs, rather than driven by the notification: the dots
  need a timer anyway, the status of a window follows the file in front of
  it (a tab switch in a group changes servers), and the panel text is only
  assigned when it differs, so an idle tick costs a few lookups.

  WHICH FILE A WINDOW SHOWS: the one EditorViewActivated last reported for
  it, falling back to the IDE's top view for the top window - the ToolsAPI
  has no "active view of this edit window" question.

  THE PANEL BELONGS TO A STATUS BAR THE IDE OWNS. It is found again by its
  collection ID every tick and re-added if it is gone (should the IDE rebuild
  its panels, Panels.Clear frees ours with them - hence the ID, never a held
  reference), the bar's destruction is watched with FreeNotification, and
  FinalizeStatusPanel takes every panel back out: a panel left behind would
  outlive the package that knows what it says.

  THE ERROR COUNT: "PasTree: Ready [3]" when the PROJECT answering the file
  in front has errors - every unit its analysis compiles, open or not: the
  server's pastree/diagnosticCounts (LspProjectDiagnosticCounts), not the
  publishDiagnostics of the open files - and plain "PasTree: Ready" when it
  has none; warnings and hints are not in the bracket (Alex, 2026-11-19).
  Only beside Ready: while a run is shown the count is the previous run's.

  THE HINT: "PasTree: Ready, 3 errors, 0 warnings, 12 hints" over our panel,
  the same project's totals. A TStatusPanel has no hint of its own, only its bar
  has one, so the bar's WindowProc is hooked (TBarHint) and answers
  CM_HINTSHOW for our panel's rectangle alone; everywhere else the IDE's
  answer stands, cut off at our panel so that crossing into it asks again.
  The bar is made to show hints if it did not (and declines them outside our
  panel in that case, as before); both are put back when the package goes.
}

interface

procedure InitializeStatusPanel;
procedure FinalizeStatusPanel;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  Winapi.Messages,
  Winapi.CommCtrl,
  Vcl.Controls,
  Vcl.ComCtrls,
  Vcl.ExtCtrls,
  Vcl.Forms,
  ToolsAPI,
  DockForm,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.WaitDialog,
  PasTreeIdePlugin.Timing;

const
  cTickMs = 300;
  // The 250 ms above: shorter runs leave the panel as it was.
  cBusyAfterMs = 250;
  // The leading space is the gap from the IDE's panel before ours - a space's
  // width, 3-4 px at the usual scalings, which a psText panel has no other
  // setting for (Alex, 2026-10-01: flush against it looked cramped).
  cPrefix = ' PasTree: ';

type
  /// The hint of our panel in one status bar - see THE HINT in the header.
  TBarHint = class
  private
    FBar: TStatusBar;
    FOldProc: TWndMethod;
    // What the bar's ShowHint / ParentShowHint were before we turned
    // ShowHint on.
    FShowedHints: Boolean;
    FParentShowHint: Boolean;
    function PanelRect(out ARect: TRect): Boolean;
    procedure WndProc(var AMessage: TMessage);
  public
    PanelId: Integer;
    Text: string;
    constructor Create(ABar: TStatusBar);
    destructor Destroy; override;
    /// The bar is being freed: nothing to restore.
    procedure Forget;
  end;

  TStatusPanels = class(TComponent)
  private
    FTimer: TTimer;
    // Status bar -> the collection ID of our panel in it.
    FPanels: TDictionary<TStatusBar, Integer>;
    // Edit window form -> the file EditorViewActivated last reported there.
    FFiles: TDictionary<TCustomForm, string>;
    // Status bar -> the hook that answers our panel's hint. Owned.
    FHints: TObjectDictionary<TStatusBar, TBarHint>;
    FDots: Integer;
    FLogged: Boolean;
    procedure OnTimer(Sender: TObject);
    function PanelOf(ABar: TStatusBar): TStatusPanel;
    procedure Describe(const AFileName: string; out AText, AHint: string);
    procedure LogLayout(ABar: TStatusBar);
  protected
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ViewActivated(const AWindow: INTAEditWindow;
      const AView: IOTAEditView);
  end;

  TStatusPanelNotifier = class(TNotifierObject, INTAEditServicesNotifier)
  public
    procedure WindowShow(const EditWindow: INTAEditWindow;
      Show, LoadedFromDesktop: Boolean);
    procedure WindowNotification(const EditWindow: INTAEditWindow;
      Operation: TOperation);
    procedure WindowActivated(const EditWindow: INTAEditWindow);
    procedure WindowCommand(const EditWindow: INTAEditWindow;
      Command, Param: Integer; var Handled: Boolean);
    procedure EditorViewActivated(const EditWindow: INTAEditWindow;
      const EditView: IOTAEditView);
    procedure EditorViewModified(const EditWindow: INTAEditWindow;
      const EditView: IOTAEditView);
    procedure DockFormVisibleChanged(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
    procedure DockFormUpdated(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
    procedure DockFormRefresh(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
  end;

var
  GPanels: TStatusPanels;
  GNotifierIndex: Integer = -1;

{ TBarHint }

constructor TBarHint.Create(ABar: TStatusBar);
begin
  inherited Create;
  FBar := ABar;
  FShowedHints := ABar.ShowHint;
  FParentShowHint := ABar.ParentShowHint;
  FOldProc := ABar.WindowProc;
  ABar.WindowProc := WndProc;
  if not FShowedHints then
    ABar.ShowHint := True;
end;

destructor TBarHint.Destroy;
var
  LMine: TWndMethod;
begin
  if FBar <> nil then
  begin
    LMine := WndProc;
    // Restored only while the chain still ends in us - someone who hooked
    // after us holds our method as their old one (same rule as
    // PasTreeIdePlugin.EditorWindowHook).
    if (TMethod(FBar.WindowProc).Code = TMethod(LMine).Code) and
       (TMethod(FBar.WindowProc).Data = TMethod(LMine).Data) then
      FBar.WindowProc := FOldProc
    else
      TimingLog('status panel: the status bar''s WindowProc was hooked ' +
        'after ours - left as it is');
    if not FShowedHints then
      if FParentShowHint then
        FBar.ParentShowHint := True
      else
        FBar.ShowHint := False;
  end;
  inherited;
end;

procedure TBarHint.Forget;
begin
  FBar := nil;
end;

function TBarHint.PanelRect(out ARect: TRect): Boolean;
var
  LItem: TCollectionItem;
begin
  Result := False;
  if (FBar = nil) or FBar.SimplePanel or not FBar.HandleAllocated then
    Exit;
  LItem := FBar.Panels.FindItemID(PanelId);
  if LItem = nil then
    Exit;
  Result := SendMessage(FBar.Handle, SB_GETRECT, LItem.Index,
    LPARAM(@ARect)) <> 0;
end;

procedure TBarHint.WndProc(var AMessage: TMessage);
var
  // Qualified: Vcl.Forms, later in the uses clause, has a deprecated alias.
  LInfo: Vcl.Controls.PHintInfo;
  LRect: TRect;
  LHas: Boolean;
begin
  if (AMessage.Msg <> CM_HINTSHOW) or (AMessage.LParam = 0) then
  begin
    FOldProc(AMessage);
    Exit;
  end;
  LInfo := Vcl.Controls.PHintInfo(AMessage.LParam);
  LHas := PanelRect(LRect);
  if LHas and (Text <> '') and LRect.Contains(LInfo.CursorPos) then
  begin
    LInfo.HintStr := Text;
    // The hint lives while the mouse stays in the panel; leaving it asks
    // the bar again.
    LInfo.CursorRect := LRect;
    AMessage.Result := 0;
    Exit;
  end;
  FOldProc(AMessage);
  // A bar that showed no hints before us still shows none outside our panel.
  if not FShowedHints then
    AMessage.Result := 1
  else if LHas then
  begin
    // The IDE's hint covers the whole bar by default: cut it off at our
    // panel, or moving into the panel would not ask again.
    if LInfo.CursorPos.X < LRect.Left then
    begin
      if LInfo.CursorRect.Right > LRect.Left then
        LInfo.CursorRect.Right := LRect.Left;
    end
    else if LInfo.CursorPos.X >= LRect.Right then
    begin
      if LInfo.CursorRect.Left < LRect.Right then
        LInfo.CursorRect.Left := LRect.Right;
    end;
  end;
end;

{ TStatusPanels }

constructor TStatusPanels.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPanels := TDictionary<TStatusBar, Integer>.Create;
  FFiles := TDictionary<TCustomForm, string>.Create;
  FHints := TObjectDictionary<TStatusBar, TBarHint>.Create([doOwnsValues]);
  FTimer := TTimer.Create(Self);
  FTimer.Interval := cTickMs;
  FTimer.OnTimer := OnTimer;
end;

destructor TStatusPanels.Destroy;
var
  LBar: TStatusBar;
  LItem: TCollectionItem;
  LForm: TCustomForm;
begin
  FTimer.Enabled := False;
  // First: each hook puts its bar's WindowProc and ShowHint back.
  FreeAndNil(FHints);
  for LBar in FPanels.Keys do
  begin
    LItem := LBar.Panels.FindItemID(FPanels[LBar]);
    if LItem <> nil then
      LItem.Free;   // a TCollectionItem removes itself from its collection
    LBar.RemoveFreeNotification(Self);
  end;
  for LForm in FFiles.Keys do
    LForm.RemoveFreeNotification(Self);
  // FreeAndNil, not Free: inherited Destroy still calls Notification (for
  // the timer it owns), which tests both for nil.
  FreeAndNil(FPanels);
  FreeAndNil(FFiles);
  inherited;
end;

procedure TStatusPanels.Notification(AComponent: TComponent;
  Operation: TOperation);
var
  LHint: TBarHint;
begin
  inherited;
  if Operation <> opRemove then
    Exit;
  if (FHints <> nil) and (AComponent is TStatusBar) and
     FHints.TryGetValue(TStatusBar(AComponent), LHint) then
  begin
    LHint.Forget;
    FHints.Remove(TStatusBar(AComponent));
  end;
  if (FPanels <> nil) and (AComponent is TStatusBar) then
    FPanels.Remove(TStatusBar(AComponent));
  if (FFiles <> nil) and (AComponent is TCustomForm) then
    FFiles.Remove(TCustomForm(AComponent));
end;

procedure TStatusPanels.ViewActivated(const AWindow: INTAEditWindow;
  const AView: IOTAEditView);
var
  LForm: TCustomForm;
begin
  if not Assigned(AWindow) or not Assigned(AView) or
     not Assigned(AView.Buffer) then
    Exit;
  LForm := AWindow.Form;
  if LForm = nil then
    Exit;
  if not FFiles.ContainsKey(LForm) then
    LForm.FreeNotification(Self);
  FFiles.AddOrSetValue(LForm, AView.Buffer.FileName);
end;

function TStatusPanels.PanelOf(ABar: TStatusBar): TStatusPanel;
var
  LId: Integer;
  LItem: TCollectionItem;
begin
  if FPanels.TryGetValue(ABar, LId) then
  begin
    LItem := ABar.Panels.FindItemID(LId);
    if LItem is TStatusPanel then
      Exit(TStatusPanel(LItem));
  end
  else
    ABar.FreeNotification(Self);
  if not FLogged then
  begin
    FLogged := True;
    LogLayout(ABar);
  end;
  Result := ABar.Panels.Add;
  Result.Style := psText;
  // The widest text it shows, with room for the panel's own margins. The
  // last panel of a status bar stretches to the right edge anyway, so this
  // only matters when the IDE adds panels after ours.
  ABar.Canvas.Font := ABar.Font;
  Result.Width := ABar.Canvas.TextWidth(cPrefix + 'analyzing (inc)...') + 16;
  FPanels.AddOrSetValue(ABar, Result.ID);
end;

{ One line, once per IDE session and only under Advanced Logging: what the
  IDE's status bar holds when we first add to it - its panels and the
  controls laid over them. If the panel lands somewhere odd on another IDE
  version, this is the line that says why. }
procedure TStatusPanels.LogLayout(ABar: TStatusBar);
var
  LText: string;
  LIdx: Integer;
begin
  LText := Format('status bar %s: %d panels', [ABar.Name, ABar.Panels.Count]);
  for LIdx := 0 to ABar.Panels.Count - 1 do
    LText := LText + Format(' [%d w=%d s=%d]',
      [LIdx, ABar.Panels[LIdx].Width, Ord(ABar.Panels[LIdx].Style)]);
  LText := LText + Format(', %d controls', [ABar.ControlCount]);
  for LIdx := 0 to ABar.ControlCount - 1 do
    LText := LText + Format(' %s(%d..%d)', [ABar.Controls[LIdx].ClassName,
      ABar.Controls[LIdx].Left,
      ABar.Controls[LIdx].Left + ABar.Controls[LIdx].Width]);
  TimingLog(LText);
end;

{ AText is the panel's text, AHint the hint over it; both '' when no server
  answers the file. }
procedure TStatusPanels.Describe(const AFileName: string;
  out AText, AHint: string);
var
  LRunningMs: UInt64;
  LMessage, LState: string;
  LErrors, LWarnings, LHints: Integer;
  LBusy, LCounted: Boolean;

  function Counted(ACount: Integer; const AWhat: string): string;
  begin
    Result := Format('%d %s', [ACount, AWhat]);
    if ACount <> 1 then
      Result := Result + 's';
  end;

begin
  AText := '';
  AHint := '';
  LBusy := False;
  LCounted := True;
  case LspServerStatusFor(AFileName, LRunningMs, LMessage) of
    lssStarting:
      begin
        LState := 'Starting';
        LBusy := True;
        LCounted := False;
      end;
    lssReady:
      LState := 'Ready';
    lssIncremental:
      begin
        LState := 'analyzing (inc)';
        LBusy := True;
      end;
    lssFull:
      begin
        LState := 'analyzing';
        LBusy := True;
      end;
    lssLibrary:
      begin
        // A Find, a rename or the uses lint waiting while the server makes
        // the library bodies it needs full (light mode). Its wait dialog -
        // the command's own progress surface - gets the server's line under
        // the description; a no-op when no dialog of ours is up.
        LState := 'library bodies';
        LBusy := True;
        if LMessage <> '' then
          UpdateWaitDialogWork('PasTree: ' + LMessage);
      end;
    lssFailed:
      begin
        LState := 'Stopped';
        LCounted := False;
      end;
  else
    Exit;   // no server for this file: say nothing
  end;
  // A run shorter than cBusyAfterMs is not shown - see the header.
  if LBusy and LCounted and (LRunningMs < cBusyAfterMs) then
  begin
    LState := 'Ready';
    LBusy := False;
  end;
  AText := cPrefix + LState;
  AHint := 'PasTree: ' + LState;
  if LBusy then
    AText := AText + StringOfChar('.', FDots + 1);
  if not LCounted then
    Exit;
  // Nothing reported yet reads as none: the hint says 0.
  LspProjectDiagnosticCounts(AFileName, LErrors, LWarnings, LHints);
  if (LErrors > 0) and not LBusy then
    AText := AText + Format(' [%d]', [LErrors]);
  AHint := AHint + ', ' + Counted(LErrors, 'error') + ', ' +
    Counted(LWarnings, 'warning') + ', ' + Counted(LHints, 'hint');
end;

procedure TStatusPanels.OnTimer(Sender: TObject);
var
  LServices: INTAEditorServices;
  LEditor: IOTAEditorServices;
  LTop, LWindow: INTAEditWindow;
  LBar: TStatusBar;
  LPanel: TStatusPanel;
  LIdx: Integer;
  LFile, LText, LHintText: string;
  LHint: TBarHint;
begin
  FDots := (FDots + 1) mod 3;
  if not Supports(BorlandIDEServices, INTAEditorServices, LServices) then
    Exit;
  LTop := LServices.TopEditWindow;
  // A failure here repeats every 300 ms for as long as its cause lasts; the
  // panel is cosmetic, and an exception out of a timer is an IDE error box.
  try
    for LIdx := 0 to LServices.EditWindowCount - 1 do
    begin
      LWindow := LServices.EditWindow[LIdx];
      if not Assigned(LWindow) or (LWindow.Form = nil) then
        Continue;
      LBar := LWindow.StatusBar;
      if LBar = nil then
        Continue;
      if not FFiles.TryGetValue(LWindow.Form, LFile) then
      begin
        LFile := '';
        // By form, not by interface: two references to one window need not
        // be the same pointer.
        if Assigned(LTop) and (LWindow.Form = LTop.Form) and
           Supports(BorlandIDEServices, IOTAEditorServices, LEditor) and
           Assigned(LEditor.TopView) and Assigned(LEditor.TopView.Buffer) then
          LFile := LEditor.TopView.Buffer.FileName;
      end;
      LText := '';
      LHintText := '';
      if LFile <> '' then
        Describe(LFile, LText, LHintText);
      LPanel := PanelOf(LBar);
      if LPanel.Text <> LText then
        LPanel.Text := LText;
      if not FHints.TryGetValue(LBar, LHint) then
      begin
        LHint := TBarHint.Create(LBar);
        FHints.Add(LBar, LHint);
      end;
      LHint.PanelId := LPanel.ID;
      LHint.Text := LHintText;
    end;
  except
    on E: Exception do
    begin
      FTimer.Enabled := False;
      TimingLog('status panel stopped: ' + E.ClassName + ': ' + E.Message);
    end;
  end;
end;

{ TStatusPanelNotifier }

procedure TStatusPanelNotifier.EditorViewActivated(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
  if Assigned(GPanels) then
    GPanels.ViewActivated(EditWindow, EditView);
end;

procedure TStatusPanelNotifier.EditorViewModified(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
end;

procedure TStatusPanelNotifier.WindowShow(const EditWindow: INTAEditWindow;
  Show, LoadedFromDesktop: Boolean);
begin
end;

procedure TStatusPanelNotifier.WindowNotification(
  const EditWindow: INTAEditWindow; Operation: TOperation);
begin
end;

procedure TStatusPanelNotifier.WindowActivated(
  const EditWindow: INTAEditWindow);
begin
end;

procedure TStatusPanelNotifier.WindowCommand(const EditWindow: INTAEditWindow;
  Command, Param: Integer; var Handled: Boolean);
begin
end;

procedure TStatusPanelNotifier.DockFormVisibleChanged(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure TStatusPanelNotifier.DockFormUpdated(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure TStatusPanelNotifier.DockFormRefresh(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure InitializeStatusPanel;
var
  LServices: IOTAEditorServices80;
begin
  if GPanels <> nil then
    Exit;
  GPanels := TStatusPanels.Create(nil);
  if Supports(BorlandIDEServices, IOTAEditorServices80, LServices) then
    GNotifierIndex := LServices.AddNotifier(TStatusPanelNotifier.Create);
end;

procedure FinalizeStatusPanel;
var
  LServices: IOTAEditorServices80;
begin
  if GNotifierIndex >= 0 then
  begin
    if Supports(BorlandIDEServices, IOTAEditorServices80, LServices) then
      LServices.RemoveNotifier(GNotifierIndex);
    GNotifierIndex := -1;
  end;
  FreeAndNil(GPanels);
end;

initialization

finalization
  // An unload without the wizard's teardown (see the wizard's destructor)
  // must still take the panels back out and stop the timer.
  FinalizeStatusPanel;

end.
