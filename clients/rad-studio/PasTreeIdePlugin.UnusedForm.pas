unit PasTreeIdePlugin.UnusedForm;

(*
  The Unused dialog - Find All > Unused... (0.89.0). One command in place of
  the three the menu had (Unused Units, Unused Units in the Project, Units
  Nobody Uses), with the question set here (Alex, 2026-11-14):

  - where: the unit in the editor, named, or its project, named. The unit
    is offered only for a Pascal source; the project is always there.
  - what: unused declarations (PasTree 0.191.0's FindUnusedSymbols),
    unused `uses` entries, units nobody uses - the last one a project
    question, greyed while the unit is chosen (its tick kept).
  - whether rows with a doubt are shown at all. Off by default: a row the
    index may be wrong about is not shown anywhere, not even as a count.

  Defaults: everything ticked, doubts off, the unit. Every choice is kept in
  the registry (beside the settings) and is what the dialog opens with next
  time. OK is greyed while nothing would be searched.

  THEMED THE IDE'S OWN WAY - RegisterFormClass before construction,
  ApplyTheme after - as PasTreeIdePlugin.GroupScopeForm does.
*)

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls;

type
  TUnusedOptions = record
    Project: Boolean;          // False: the unit in the editor
    Declarations: Boolean;
    UsesEntries: Boolean;
    NobodyUses: Boolean;       // project only
    Doubts: Boolean;           // show rows with a doubt
    // What is actually searched: NobodyUses needs the project.
    function SearchesNobodyUses: Boolean;
    function SearchesAnything: Boolean;
  end;

  TPasTreeUnusedForm = class(TForm)
    grpScope: TGroupBox;
    rbUnit: TRadioButton;
    rbProject: TRadioButton;
    grpLookFor: TGroupBox;
    cbDeclarations: TCheckBox;
    cbUsesEntries: TCheckBox;
    cbNobodyUses: TCheckBox;
    cbDoubts: TCheckBox;
    btnOK: TButton;
    btnCancel: TButton;
  private
    procedure ChoiceChanged(ASender: TObject);
    function Options: TUnusedOptions;
  end;

var
  // For the Form Designer only, never assigned - see SettingsForm's note on
  // the same variable.
  PasTreeUnusedForm: TPasTreeUnusedForm = nil;

/// <summary>
/// Shows the dialog modally. AUnitFile is the file in the editor ('' or a
/// non-Pascal file: the unit cannot be chosen), AProjectFile the .dproj
/// that answers for it. On OK remembers the choice and returns True with it
/// in AOptions; False on Cancel.
/// </summary>
function ExecuteUnusedDialog(const AUnitFile, AProjectFile: string;
  out AOptions: TUnusedOptions): Boolean;

implementation

{$R *.dfm}

uses
  System.SysUtils,
  System.UITypes,
  System.Win.Registry,
  Winapi.Windows,
  ToolsAPI,
  PasTreeIdePlugin.Settings;

const
  cValueProject = 'UnusedScopeProject';
  cValueDeclarations = 'UnusedDeclarations';
  cValueUsesEntries = 'UnusedUsesEntries';
  cValueNobodyUses = 'UnusedNobodyUses';
  cValueDoubts = 'UnusedDoubts';

function TUnusedOptions.SearchesNobodyUses: Boolean;
begin
  Result := Project and NobodyUses;
end;

function TUnusedOptions.SearchesAnything: Boolean;
begin
  Result := Declarations or UsesEntries or SearchesNobodyUses;
end;

function DefaultOptions: TUnusedOptions;
begin
  Result.Project := False;
  Result.Declarations := True;
  Result.UsesEntries := True;
  Result.NobodyUses := True;
  Result.Doubts := False;
end;

function LoadOptions: TUnusedOptions;
var
  LReg: TRegistry;

  function ReadBool(const AName: string; ADefault: Boolean): Boolean;
  begin
    if LReg.ValueExists(AName) then
      Result := LReg.ReadBool(AName)
    else
      Result := ADefault;
  end;

begin
  Result := DefaultOptions;
  if SettingsRegistryKey = '' then
    Exit;
  LReg := TRegistry.Create(KEY_READ);
  try
    try
      LReg.RootKey := HKEY_CURRENT_USER;
      if LReg.OpenKeyReadOnly(SettingsRegistryKey) then
      begin
        Result.Project := ReadBool(cValueProject, Result.Project);
        Result.Declarations := ReadBool(cValueDeclarations, Result.Declarations);
        Result.UsesEntries := ReadBool(cValueUsesEntries, Result.UsesEntries);
        Result.NobodyUses := ReadBool(cValueNobodyUses, Result.NobodyUses);
        Result.Doubts := ReadBool(cValueDoubts, Result.Doubts);
      end;
    except
      Result := DefaultOptions;
    end;
  finally
    LReg.Free;
  end;
end;

procedure SaveOptions(const AOptions: TUnusedOptions);
var
  LReg: TRegistry;
begin
  if SettingsRegistryKey = '' then
    Exit;
  LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    try
      LReg.RootKey := HKEY_CURRENT_USER;
      if LReg.OpenKey(SettingsRegistryKey, True) then
      begin
        LReg.WriteBool(cValueProject, AOptions.Project);
        LReg.WriteBool(cValueDeclarations, AOptions.Declarations);
        LReg.WriteBool(cValueUsesEntries, AOptions.UsesEntries);
        LReg.WriteBool(cValueNobodyUses, AOptions.NobodyUses);
        LReg.WriteBool(cValueDoubts, AOptions.Doubts);
      end;
    except
      // A choice that does not survive a restart is not worth an exception
      // into the IDE - as for the settings themselves.
    end;
  finally
    LReg.Free;
  end;
end;

function TPasTreeUnusedForm.Options: TUnusedOptions;
begin
  Result.Project := rbProject.Checked;
  Result.Declarations := cbDeclarations.Checked;
  Result.UsesEntries := cbUsesEntries.Checked;
  Result.NobodyUses := cbNobodyUses.Checked;
  Result.Doubts := cbDoubts.Checked;
end;

procedure TPasTreeUnusedForm.ChoiceChanged(ASender: TObject);
begin
  // Greyed, not unticked: the tick comes back with the project.
  cbNobodyUses.Enabled := rbProject.Checked;
  btnOK.Enabled := Options.SearchesAnything;
end;

function IsPascalSource(const AFile: string): Boolean;
begin
  Result := (AFile <> '') and (SameText(ExtractFileExt(AFile), '.pas') or
    SameText(ExtractFileExt(AFile), '.dpr') or
    SameText(ExtractFileExt(AFile), '.dpk'));
end;

function ExecuteUnusedDialog(const AUnitFile, AProjectFile: string;
  out AOptions: TUnusedOptions): Boolean;
var
  LForm: TPasTreeUnusedForm;
  LTheming: IOTAIDEThemingServices;
  LThemed, LUnitOk: Boolean;
  LOptions: TUnusedOptions;
begin
  Result := False;
  AOptions := DefaultOptions;
  LOptions := LoadOptions;
  LUnitOk := IsPascalSource(AUnitFile);
  if not LUnitOk then
    LOptions.Project := True;
  LThemed := Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming)
    and LTheming.IDEThemingEnabled;
  if LThemed then
    LTheming.RegisterFormClass(TPasTreeUnusedForm);
  LForm := TPasTreeUnusedForm.Create(Application.MainForm);
  try
    if LThemed then
      LTheming.ApplyTheme(LForm);
    if LUnitOk then
      LForm.rbUnit.Caption := 'Current unit (' + ExtractFileName(AUnitFile) + ')'
    else
      LForm.rbUnit.Caption := 'Current unit (none in the editor)';
    LForm.rbUnit.Enabled := LUnitOk;
    if AProjectFile <> '' then
      LForm.rbProject.Caption := 'Project (' + ExtractFileName(AProjectFile) + ')';
    LForm.rbUnit.Checked := not LOptions.Project;
    LForm.rbProject.Checked := LOptions.Project;
    LForm.cbDeclarations.Checked := LOptions.Declarations;
    LForm.cbUsesEntries.Checked := LOptions.UsesEntries;
    LForm.cbNobodyUses.Checked := LOptions.NobodyUses;
    LForm.cbDoubts.Checked := LOptions.Doubts;
    LForm.rbUnit.OnClick := LForm.ChoiceChanged;
    LForm.rbProject.OnClick := LForm.ChoiceChanged;
    LForm.cbDeclarations.OnClick := LForm.ChoiceChanged;
    LForm.cbUsesEntries.OnClick := LForm.ChoiceChanged;
    LForm.cbNobodyUses.OnClick := LForm.ChoiceChanged;
    LForm.ChoiceChanged(nil);
    if LForm.ShowModal <> mrOk then
      Exit;
    AOptions := LForm.Options;
    // The unit greyed out is not a choice of the project: the scope saved
    // stays the one made last time the unit could be chosen.
    LOptions := AOptions;
    if not LUnitOk then
      LOptions.Project := LoadOptions.Project;
    SaveOptions(LOptions);
    Result := AOptions.SearchesAnything;
  finally
    LForm.Free;
  end;
end;

end.
