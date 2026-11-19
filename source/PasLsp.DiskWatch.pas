unit PasLsp.DiskWatch;

{
  THE SERVER'S OWN EYE ON THE DISK (0.95.0): the directories the analysis
  read its sources from, watched with ReadDirectoryChangesW, the changes
  handed to the dispatcher as workspace/didChangeWatchedFiles would hand
  them.

  Why the server and not the client. Until 0.95.0 the watching was the
  client's (HandleDidChangeWatchedFiles), on the premise that the IDE plugin
  gets the same news from ToolsAPI. It does not: ToolsAPI reports a module
  added, removed or renamed, and nothing at all about a unit that is NOT open
  in the IDE being rewritten on disk - by git, another editor, an agent. The
  analysis kept answering about the text it read at startup, silently; a
  rename then refused to write ("line 3914 no longer reads ...", 2026-11-19)
  because the closed unit's call had moved up a line an hour earlier. The VS
  Code client watches only its workspace folder, so a unit reached through a
  search path outside it had the same hole. One watcher here covers both
  clients, sees exactly the directories the closure came from, and runs in
  this process rather than inside the IDE.

  The clients still send didChangeWatchedFiles, and the IDE still reloads an
  open file and sends its new text: the SAME change arrives two or three
  times. The server tells them apart by the file's stamp (size and last
  write time) - see TLspServer.ApplyDiskChanges. This unit only reports.

  Shape: one thread, one I/O completion port, one non-recursive
  ReadDirectoryChangesW per directory (a recursive watch of a repository root
  would report every .dcu a build writes). The dispatcher states the wanted
  set (SetDirectories); the thread opens and closes handles itself, so every
  handle is touched by one thread only. Only Pascal sources are reported
  (.pas .dpr .dpk .inc); a .dproj change is the client's to report
  (pastree/projectChanged). A buffer overflow - thousands of changes at once,
  a large checkout - loses the names, so it is reported per directory and
  answered with a full rebuild.
}

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections;

const
  // The LSP FileChangeType values, so a change from the watcher and one from
  // a client go through the same code.
  DISK_CREATED = 1;
  DISK_CHANGED = 2;
  DISK_DELETED = 3;

type
  TLspDiskChange = record
    Path: string;
    Kind: Integer;   // DISK_CREATED / DISK_CHANGED / DISK_DELETED
  end;

  TLspDiskWatcher = class
  private type
    TWatchDir = class
      Path: string;
      Handle: THandle;
      Ovl: TOverlapped;
      Buffer: array of Byte;
      Closing: Boolean;
    end;
  private
    FLock: TCriticalSection;
    FPort: THandle;
    FThread: TThread;
    // Shared, under FLock.
    FWanted: TArray<string>;
    FWantedMoved: Boolean;
    FChanges: TDictionary<string, TLspDiskChange>;   // key: lower-cased path
    FOverflow: TList<string>;
    FFailed: TList<string>;
    FLastEvent: UInt64;
    // The thread's own.
    FDirs: TDictionary<string, TWatchDir>;           // key: lower-cased path
    FPendingFree: Integer;
    // FDirs.Count, published by the thread for Count.
    FActive: Integer;
    procedure Execute;
    procedure ApplyWanted;
    function Arm(ADir: TWatchDir): Boolean;
    procedure Close(ADir: TWatchDir);
    procedure Parse(ADir: TWatchDir; ABytes: DWORD);
    procedure Note(const APath: string; AKind: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    { The directories to watch, replacing the last set: the new ones opened,
      the dropped ones closed, by the thread. Paths as given; compared
      case-insensitively. }
    procedure SetDirectories(const ADirs: TArray<string>);
    { The changes since the last Take, once AQuietMs passed since the latest
      one (0 = now): a checkout's hundreds of events come out as one batch.
      AOverflow names the directories whose changes were lost, AFailed those
      that could not be watched (each once). False = nothing to hand over. }
    function Take(AQuietMs: Cardinal; out AChanges: TArray<TLspDiskChange>;
      out AOverflow, AFailed: TArray<string>): Boolean;
    { How many directories are watched now. }
    function Count: Integer;
  end;

{ Size and last write time, as text - '' for a file that is not there. Two
  reports of one write read the same stamp; the next write moves it. }
function LspDiskStamp(const APath: string): string;

implementation

const
  KEY_WAKE = 1;
  KEY_QUIT = 2;
  // Per directory. Large enough that an ordinary save never overflows it;
  // a checkout that does is answered by a full rebuild anyway.
  BUFFER_SIZE = 64 * 1024;
  NOTIFY_FILTER = FILE_NOTIFY_CHANGE_FILE_NAME or
    FILE_NOTIFY_CHANGE_LAST_WRITE or FILE_NOTIFY_CHANGE_SIZE;

type
  // FILE_NOTIFY_INFORMATION, declared here: the Winapi.Windows spelling has
  // moved between Delphi versions.
  PFileNotify = ^TFileNotify;
  TFileNotify = record
    NextEntryOffset: DWORD;
    Action: DWORD;
    FileNameLength: DWORD;   // bytes
    FileName: array[0..0] of WideChar;
  end;

function CancelIoEx(hFile: THandle; lpOverlapped: POverlapped): BOOL; stdcall;
  external kernel32 name 'CancelIoEx';

function LspDiskStamp(const APath: string): string;
var
  LData: TWin32FileAttributeData;
begin
  if not GetFileAttributesEx(PChar(APath), GetFileExInfoStandard, @LData) then
    Exit('');
  Result := Format('%u:%u:%u:%u', [LData.nFileSizeHigh, LData.nFileSizeLow,
    LData.ftLastWriteTime.dwHighDateTime, LData.ftLastWriteTime.dwLowDateTime]);
end;

function IsPascalSource(const AName: string): Boolean;
var
  LExt: string;
begin
  LExt := LowerCase(ExtractFileExt(AName));
  Result := (LExt = '.pas') or (LExt = '.dpr') or (LExt = '.dpk') or
    (LExt = '.inc');
end;

{ TLspDiskWatcher }

constructor TLspDiskWatcher.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FChanges := TDictionary<string, TLspDiskChange>.Create;
  FOverflow := TList<string>.Create;
  FFailed := TList<string>.Create;
  FDirs := TDictionary<string, TWatchDir>.Create;
  FPort := CreateIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, 1);
  if FPort = 0 then
    RaiseLastOSError;
  FThread := TThread.CreateAnonymousThread(Execute);
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

destructor TLspDiskWatcher.Destroy;
begin
  if FThread <> nil then
  begin
    PostQueuedCompletionStatus(FPort, 0, KEY_QUIT, nil);
    FThread.WaitFor;
    FThread.Free;
  end;
  if FPort <> 0 then
    CloseHandle(FPort);
  FDirs.Free;
  FFailed.Free;
  FOverflow.Free;
  FChanges.Free;
  FLock.Free;
  inherited;
end;

procedure TLspDiskWatcher.SetDirectories(const ADirs: TArray<string>);
begin
  FLock.Enter;
  try
    FWanted := Copy(ADirs);
    FWantedMoved := True;
  finally
    FLock.Leave;
  end;
  PostQueuedCompletionStatus(FPort, 0, KEY_WAKE, nil);
end;

function TLspDiskWatcher.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FActive;
  finally
    FLock.Leave;
  end;
end;

function TLspDiskWatcher.Take(AQuietMs: Cardinal;
  out AChanges: TArray<TLspDiskChange>;
  out AOverflow, AFailed: TArray<string>): Boolean;
begin
  AChanges := nil;
  AOverflow := nil;
  AFailed := nil;
  FLock.Enter;
  try
    if (FChanges.Count = 0) and (FOverflow.Count = 0) and
       (FFailed.Count = 0) then
      Exit(False);
    if (AQuietMs > 0) and (GetTickCount64 - FLastEvent < AQuietMs) then
      Exit(False);
    AChanges := FChanges.Values.ToArray;
    AOverflow := FOverflow.ToArray;
    AFailed := FFailed.ToArray;
    FChanges.Clear;
    FOverflow.Clear;
    FFailed.Clear;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TLspDiskWatcher.Note(const APath: string; AKind: Integer);
var
  LKey: string;
  LOld, LNew: TLspDiskChange;
begin
  LKey := LowerCase(APath);
  LNew.Path := APath;
  LNew.Kind := AKind;
  FLock.Enter;
  try
    // A file created and then written in one batch is still a creation: the
    // server rebuilds for a creation wherever it lies, for a change only
    // inside the closure.
    if FChanges.TryGetValue(LKey, LOld) and (LOld.Kind = DISK_CREATED) and
       (AKind = DISK_CHANGED) then
      LNew.Kind := DISK_CREATED;
    FChanges.AddOrSetValue(LKey, LNew);
    FLastEvent := GetTickCount64;
  finally
    FLock.Leave;
  end;
end;

function TLspDiskWatcher.Arm(ADir: TWatchDir): Boolean;
begin
  FillChar(ADir.Ovl, SizeOf(ADir.Ovl), 0);
  Result := ReadDirectoryChangesW(ADir.Handle, @ADir.Buffer[0],
    Length(ADir.Buffer), False, NOTIFY_FILTER, nil, @ADir.Ovl, nil);
end;

{ The handle closed; the read it had pending completes as aborted, and that
  completion frees the object (Execute). Until then the object stays alive -
  the kernel still holds its OVERLAPPED. }
procedure TLspDiskWatcher.Close(ADir: TWatchDir);
begin
  ADir.Closing := True;
  CancelIoEx(ADir.Handle, @ADir.Ovl);
  CloseHandle(ADir.Handle);
  ADir.Handle := INVALID_HANDLE_VALUE;
  Inc(FPendingFree);
end;

procedure TLspDiskWatcher.ApplyWanted;
var
  LWanted: TArray<string>;
  LKeep: TDictionary<string, string>;
  LPath, LKey: string;
  LDir: TWatchDir;
  LDrop: TList<string>;
  LFailed: TList<string>;
begin
  FLock.Enter;
  try
    if not FWantedMoved then
      Exit;
    LWanted := FWanted;
    FWantedMoved := False;
  finally
    FLock.Leave;
  end;
  LKeep := TDictionary<string, string>.Create;
  LDrop := TList<string>.Create;
  LFailed := TList<string>.Create;
  try
    for LPath in LWanted do
      LKeep.AddOrSetValue(LowerCase(ExcludeTrailingPathDelimiter(LPath)),
        ExcludeTrailingPathDelimiter(LPath));
    for LKey in FDirs.Keys do
      if not LKeep.ContainsKey(LKey) then
        LDrop.Add(LKey);
    for LKey in LDrop do
    begin
      Close(FDirs[LKey]);
      FDirs.Remove(LKey);
    end;
    for LKey in LKeep.Keys do
    begin
      if FDirs.ContainsKey(LKey) then
        Continue;
      LDir := TWatchDir.Create;
      LDir.Path := LKeep[LKey];
      SetLength(LDir.Buffer, BUFFER_SIZE);
      LDir.Handle := CreateFile(PChar(LDir.Path), FILE_LIST_DIRECTORY,
        FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OVERLAPPED, 0);
      if (LDir.Handle = INVALID_HANDLE_VALUE) or
         (CreateIoCompletionPort(LDir.Handle, FPort, ULONG_PTR(LDir), 0) = 0) or
         not Arm(LDir) then
      begin
        if LDir.Handle <> INVALID_HANDLE_VALUE then
          CloseHandle(LDir.Handle);
        LDir.Free;
        LFailed.Add(LKeep[LKey]);
        Continue;
      end;
      FDirs.Add(LKey, LDir);
    end;
    FActive := FDirs.Count;
    if LFailed.Count > 0 then
    begin
      FLock.Enter;
      try
        FFailed.AddRange(LFailed);
        FLastEvent := GetTickCount64;
      finally
        FLock.Leave;
      end;
    end;
  finally
    LFailed.Free;
    LDrop.Free;
    LKeep.Free;
  end;
end;

procedure TLspDiskWatcher.Parse(ADir: TWatchDir; ABytes: DWORD);
var
  LOffset: DWORD;
  LInfo: PFileNotify;
  LName: string;
  LKind: Integer;
begin
  LOffset := 0;
  repeat
    LInfo := PFileNotify(@ADir.Buffer[LOffset]);
    SetString(LName, PWideChar(@LInfo.FileName[0]),
      LInfo.FileNameLength div SizeOf(WideChar));
    if IsPascalSource(LName) then
    begin
      case LInfo.Action of
        FILE_ACTION_ADDED, FILE_ACTION_RENAMED_NEW_NAME:
          LKind := DISK_CREATED;
        FILE_ACTION_REMOVED, FILE_ACTION_RENAMED_OLD_NAME:
          LKind := DISK_DELETED;
      else
        LKind := DISK_CHANGED;
      end;
      Note(IncludeTrailingPathDelimiter(ADir.Path) + LName, LKind);
    end;
    if LInfo.NextEntryOffset = 0 then
      Break;
    Inc(LOffset, LInfo.NextEntryOffset);
  until LOffset >= ABytes;
end;

procedure TLspDiskWatcher.Execute;
var
  LBytes: DWORD;
  LKey: ULONG_PTR;
  LOvl: POverlapped;
  LOk: Boolean;
  LDir: TWatchDir;
  LQuit: Boolean;
  LDeadline: UInt64;
begin
  LQuit := False;
  while not LQuit do
  begin
    LOvl := nil;
    LOk := GetQueuedCompletionStatus(FPort, LBytes, LKey, LOvl, INFINITE);
    if LOvl = nil then
    begin
      if not LOk then
        Break;   // the port itself failed
      if LKey = KEY_QUIT then
        LQuit := True
      else
        ApplyWanted;
      Continue;
    end;
    LDir := TWatchDir(LKey);
    if LDir.Closing then
    begin
      LDir.Free;
      Dec(FPendingFree);
      Continue;
    end;
    if LOk and (LBytes > 0) then
      Parse(LDir, LBytes)
    else if LOk then
    begin
      // Zero bytes on success: the buffer overflowed, the names are lost.
      FLock.Enter;
      try
        if FOverflow.IndexOf(LDir.Path) < 0 then
          FOverflow.Add(LDir.Path);
        FLastEvent := GetTickCount64;
      finally
        FLock.Leave;
      end;
    end;
    // Re-armed even after a failure: a transient error must not end the
    // watch. A directory that is gone fails here and is reported.
    if not Arm(LDir) then
    begin
      FLock.Enter;
      try
        if FFailed.IndexOf(LDir.Path) < 0 then
          FFailed.Add(LDir.Path);
        FLastEvent := GetTickCount64;
      finally
        FLock.Leave;
      end;
      FDirs.Remove(LowerCase(LDir.Path));
      FActive := FDirs.Count;
      CloseHandle(LDir.Handle);
      LDir.Free;
    end;
  end;
  // Quit: close everything, collect the aborted reads for a moment, and
  // leave the rest to process exit - a read the kernel never returns must
  // not hold the shutdown.
  for LDir in FDirs.Values do
    Close(LDir);
  FDirs.Clear;
  LDeadline := GetTickCount64 + 500;
  while (FPendingFree > 0) and (GetTickCount64 < LDeadline) do
  begin
    LOvl := nil;
    GetQueuedCompletionStatus(FPort, LBytes, LKey, LOvl, 100);
    if (LOvl <> nil) and TWatchDir(LKey).Closing then
    begin
      TWatchDir(LKey).Free;
      Dec(FPendingFree);
    end;
  end;
end;

end.
