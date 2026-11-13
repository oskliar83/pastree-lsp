unit PasTreeIdePlugin.Format;

{
  Format: the PasTree formatter over the active editor's buffer. Ctrl+D is
  the caret's line, or the selected lines, through the server's
  textDocument/rangeFormatting; Ctrl+Alt+D is the whole unit, through
  textDocument/formatting, after a confirmation.

  WHY NOT THE IDE'S SPLIT (Ctrl+D = the unit without a selection). Decided
  by Alex (0.88.2): Ctrl+D is pressed while writing, on the line just
  typed, and re-laying the whole unit there moves lines the author did not
  touch - in a unit written in another style, every one of them. The unit
  is a deliberate act, so it gets its own key and a question. Its key is
  Ctrl+Alt+D, not Ctrl+Shift+D: that one is the IDE's Declare Field, which
  Alex keeps.

  BOTH KEYS BEHIND ONE SWITCH. They are registered unconditionally (the one
  binding, PasTreeIdePlugin.KeyBindings) and answer krUnhandled when
  Settings > Formatting "Format" is off, so the IDE's own Ctrl+D is back on
  the next keystroke with nothing to unbind. On by default, like every IDE
  key this package takes over. A file that is not Pascal source (a .dfm as
  text, a .dproj) is handed back to the IDE too.

  ONE UNDO STEP: every edit through one IOTAEditWriter
  (CreateUndoableWriter), ascending, offsets resolved before the writer opens
  (ApplySyncEdits' reason - a writer addresses the ORIGINAL bytes). The
  edits only ever replace whitespace (PasTreeIdePlugin.FormatText checks
  that, and refuses the whole answer otherwise).

  THE BUFFER MUST BE THE ONE THE SERVER ANSWERED ABOUT: its bytes are kept
  at the request and compared when the answer lands - a keystroke in
  between and nothing is written (the message says to press it again).

  THE CARET stays on its token (MapOffsetThroughEdits), and its row keeps
  its place on the screen: a format moves lines, and a view that jumped
  would lose the reader.

  WHAT IS SAID. Nothing when it formatted (the change is on screen), a line
  in the Build tab when it could not - a failed request, a buffer that
  moved, an answer that does not fit - since then the key did not do what it
  looked like. "Already formatted" is said too, briefly: a key that visibly
  does nothing reads as a key that is broken.
}

interface

uses
  System.Classes,
  ToolsAPI;

/// <summary>
/// Formats AView's buffer: the whole unit when AWholeUnit (after asking),
/// else the selection's lines when a block is selected, else the caret's
/// line.
/// </summary>
procedure FormatView(const AView: IOTAEditView; AWholeUnit: Boolean);

/// <summary>For the editor menu's OnUpdate: is there a Pascal buffer to
/// format, and is it a selection?</summary>
function CanFormatView(const AView: IOTAEditView; out ASelection: Boolean): Boolean;

procedure InitializeFormat;
procedure FinalizeFormat;

/// <summary>Ctrl+D: the line or the selection; Ctrl+Alt+D: the unit. The
/// menu's labels read these too.</summary>
function FormatLineKey: TShortCut;
function FormatUnitKey: TShortCut;

implementation

uses
  System.SysUtils,
  System.UITypes,
  Vcl.Menus,
  Vcl.Dialogs,
  PasTreeIdePlugin.FormatText,
  PasTreeIdePlugin.KeyBindings,
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.Settings;

var
  GAlive: Boolean = False;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

function ModuleOfView(const AView: IOTAEditView): IOTAModule;
var
  LModules: IOTAModuleServices;
begin
  Result := nil;
  if not Assigned(AView) or not Assigned(AView.Buffer) then
    Exit;
  if Supports(BorlandIDEServices, IOTAModuleServices, LModules) then
    Result := LModules.FindModule(AView.Buffer.FileName);
end;

function CanFormatView(const AView: IOTAEditView; out ASelection: Boolean): Boolean;
var
  LBlock: IOTAEditBlock;
begin
  ASelection := False;
  Result := Assigned(AView) and Assigned(AView.Buffer) and
    not AView.Buffer.IsReadOnly and IsPascalSourceFile(AView.Buffer.FileName);
  if not Result then
    Exit;
  LBlock := AView.Block;
  ASelection := Assigned(LBlock) and LBlock.IsValid and (LBlock.Size > 0);
end;

{ The answer, onto the buffer as one undo step, the caret kept on its token
  and its screen row. }
procedure ApplyFormatEdits(const AView: IOTAEditView;
  const AByteEdits: TArray<TFormatByteEdit>);
var
  LWriter: IOTAEditWriter;
  LIdx, LCaretOfs, LScreenRow: Integer;
  LCharPos: TOTACharPos;
  LEditPos: TOTAEditPos;
begin
  LEditPos := AView.CursorPos;
  LScreenRow := LEditPos.Line - AView.TopRow;
  AView.ConvertPos(True, LEditPos, LCharPos);
  LCaretOfs := AView.CharPosToPos(LCharPos);

  LWriter := AView.Buffer.CreateUndoableWriter;
  if not Assigned(LWriter) then
    Exit;
  try
    for LIdx := 0 to High(AByteEdits) do
    begin
      LWriter.CopyTo(AByteEdits[LIdx].Start);
      LWriter.DeleteTo(AByteEdits[LIdx].Stop);
      if AByteEdits[LIdx].Text <> '' then
        LWriter.Insert(PAnsiChar(AByteEdits[LIdx].Text));  // PAnsiChar: the UTF8String overload is 12+
    end;
  finally
    LWriter := nil;   // the writer commits on release
  end;

  LCharPos := AView.PosToCharPos(MapOffsetThroughEdits(LCaretOfs, AByteEdits));
  AView.ConvertPos(False, LEditPos, LCharPos);
  AView.CursorPos := LEditPos;
  if LEditPos.Line - LScreenRow >= 1 then
    AView.SetTopLeft(LEditPos.Line - LScreenRow, AView.LeftColumn);
  AView.MoveViewToCursor;
  AView.Paint;
end;

procedure FormatView(const AView: IOTAEditView; AWholeUnit: Boolean);
var
  LModule: IOTAModule;
  LFileName: string;
  LSnapshot: UTF8String;
  LSelection: Boolean;
  LBlock: IOTAEditBlock;
  LStartRow, LStartCol, LEndRow, LEndCol: Integer;
  LWhat, LKey: string;
begin
  if not CanFormatView(AView, LSelection) then
    Exit;
  LModule := ModuleOfView(AView);
  if not Assigned(LModule) then
    Exit;
  LFileName := AView.Buffer.FileName;
  if AWholeUnit and (MessageDlg(Format('Format the whole of %s?',
       [ExtractFileName(LFileName)]) + sLineBreak + sLineBreak
       + 'Every line of the unit is laid out in the PasTree style; one '
       + 'Ctrl+Z undoes it.', mtConfirmation, [mbYes, mbNo], 0, mbYes)
       <> mrYes) then
    Exit;
  // Read after the question: the buffer the answer is checked against.
  LSnapshot := ReadModuleBufferUtf8(LModule);
  LStartRow := 0;
  LStartCol := 0;
  LEndRow := 0;
  LEndCol := 0;
  if AWholeUnit then
  begin
    LWhat := ExtractFileName(LFileName);
    LKey := 'Ctrl+Alt+D';
  end
  else if not LSelection then
  begin
    // The caret's line, whole - its indentation included.
    LStartRow := AView.CursorPos.Line;
    LStartCol := 1;
    LEndRow := LStartRow;
    LEndCol := MaxInt div 2;   // the server clamps to the line's end
    LWhat := Format('%s, line %d', [ExtractFileName(LFileName), LStartRow]);
    LKey := 'Ctrl+D';
  end
  else
  begin
    // Whole lines: from the first selected line's start to the end of the
    // last one - a selection ending at column 1 does not select that line.
    LBlock := AView.Block;
    LStartRow := LBlock.StartingRow;
    LStartCol := 1;
    LEndRow := LBlock.EndingRow;
    if (LEndRow > LStartRow) and (LBlock.EndingColumn <= 1) then
      Dec(LEndRow);
    LEndCol := MaxInt div 2;   // the server clamps to the line's end
    LWhat := Format('%s, lines %d-%d',
      [ExtractFileName(LFileName), LStartRow, LEndRow]);
    LKey := 'Ctrl+D';
  end;
  LspFormat(LFileName, not AWholeUnit, LStartRow, LStartCol, LEndRow, LEndCol,
    FormatOptionValues,
    procedure(ASuccess: Boolean; const AEdits: TArray<TFormatEdit>;
      const AError: string)
    var
      LNow: UTF8String;
      LByteEdits: TArray<TFormatByteEdit>;
      LWhy: string;
    begin
      if not GAlive then
        Exit;
      if not ASuccess then
      begin
        LogDiagnostic('Format failed: ' + AError);
        Exit;
      end;
      if Length(AEdits) = 0 then
      begin
        LogDiagnostic(LWhat + ': already formatted');
        Exit;
      end;
      LNow := ReadModuleBufferUtf8(LModule);
      if LNow <> LSnapshot then
      begin
        LogDiagnostic('Format: the buffer changed while the server was '
          + 'answering - nothing was changed. Press ' + LKey + ' again.');
        Exit;
      end;
      if not FormatByteEdits(LNow, AEdits, LByteEdits, LWhy) then
      begin
        LogDiagnostic('Format: the answer does not fit the buffer (' + LWhy
          + ') - nothing was changed.');
        Exit;
      end;
      ApplyFormatEdits(AView, LByteEdits);
      NoteBufferModified(LFileName);
      LspLogDetail(Format('format: %s, %d edit(s) applied',
        [ExtractFileName(LFileName), Length(LByteEdits)]));
    end);
end;

{ Ctrl+D and Ctrl+Alt+D, told apart by AKeyCode. }
procedure FormatKeyProc(const AContext: IOTAKeyContext; AKeyCode: TShortCut;
  var ABindingResult: TKeyBindingResult);
var
  LView: IOTAEditView;
  LSelection: Boolean;
begin
  // Off, or not a Pascal buffer: the IDE's own key.
  ABindingResult := krUnhandled;
  if not GAlive or not FormatEnabled or not Assigned(AContext) or
     not Assigned(AContext.EditBuffer) then
    Exit;
  LView := AContext.EditBuffer.TopView;
  if not CanFormatView(LView, LSelection) then
    Exit;
  ABindingResult := krHandled;
  FormatView(LView, AKeyCode = FormatUnitKey);
end;

procedure InitializeFormat;
begin
  GAlive := True;
  RegisterKey(FormatLineKey, FormatKeyProc);
  RegisterKey(FormatUnitKey, FormatKeyProc);
end;

function FormatLineKey: TShortCut;
begin
  Result := ShortCut(Ord('D'), [ssCtrl]);
end;

function FormatUnitKey: TShortCut;
begin
  Result := ShortCut(Ord('D'), [ssCtrl, ssAlt]);
end;

procedure FinalizeFormat;
begin
  GAlive := False;
end;

end.
