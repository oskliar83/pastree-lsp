object PasTreeUnusedForm: TPasTreeUnusedForm
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  BorderStyle = bsDialog
  Caption = 'Find Unused'
  ClientHeight = 283
  ClientWidth = 360
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poMainFormCenter
  TextHeight = 15
  object grpScope: TGroupBox
    Left = 12
    Top = 8
    Width = 336
    Height = 74
    Caption = 'Search in'
    TabOrder = 0
    object rbUnit: TRadioButton
      Left = 12
      Top = 22
      Width = 312
      Height = 19
      Caption = 'Current unit'
      Checked = True
      TabOrder = 0
      TabStop = True
    end
    object rbProject: TRadioButton
      Left = 12
      Top = 46
      Width = 312
      Height = 19
      Caption = 'Project'
      TabOrder = 1
    end
  end
  object grpLookFor: TGroupBox
    Left = 12
    Top = 90
    Width = 336
    Height = 98
    Caption = 'Look for'
    TabOrder = 1
    object cbDeclarations: TCheckBox
      Left = 12
      Top = 22
      Width = 312
      Height = 19
      Caption = 'Unused declarations'
      Checked = True
      State = cbChecked
      TabOrder = 0
    end
    object cbUsesEntries: TCheckBox
      Left = 12
      Top = 46
      Width = 312
      Height = 19
      Caption = 'Unused units in uses clauses'
      Checked = True
      State = cbChecked
      TabOrder = 1
    end
    object cbNobodyUses: TCheckBox
      Left = 12
      Top = 70
      Width = 312
      Height = 19
      Caption = 'Units nobody uses (project only)'
      Checked = True
      State = cbChecked
      TabOrder = 2
    end
  end
  object cbDoubts: TCheckBox
    Left = 24
    Top = 198
    Width = 324
    Height = 19
    Caption = 'Show rows the analysis is not sure about'
    TabOrder = 2
  end
  object btnOK: TButton
    Left = 172
    Top = 244
    Width = 85
    Height = 27
    Caption = 'OK'
    Default = True
    ModalResult = 1
    TabOrder = 3
  end
  object btnCancel: TButton
    Left = 263
    Top = 244
    Width = 85
    Height = 27
    Cancel = True
    Caption = 'Cancel'
    ModalResult = 2
    TabOrder = 4
  end
end
