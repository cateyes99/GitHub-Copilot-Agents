<#
.SYNOPSIS
  READ-ONLY inventory of VS Code workspace-storage folders for a given folder path.

  Finds every storage folder that belongs to the path (one per delete/recreate era),
  marks which era is CURRENT, counts the GitHub Copilot chat sessions in each, and
  prints ready-to-copy commands to restore orphaned sessions.

  Platform: Windows (PowerShell 5.1+, no dependencies). Linux/macOS: use
  scan-storage.py instead.

  Background: VS Code identifies a single-folder workspace as
  MD5(folderPath + creationTimeUnixMs) -- the creation time is salted in BY DESIGN
  (microsoft/vscode src/vs/platform/workspaces/node/workspaces.ts), so deleting and
  recreating a folder at the same path produces a NEW id and the old chat sessions
  vanish from history (but remain on disk, fully recoverable).

.PARAMETER FolderPath
  Full path of the folder to look up, e.g. "e:\Source\My Project". May not exist.

.PARAMETER StorageRoot
  Optional. Defaults to %APPDATA%\Code\User\workspaceStorage (VS Code stable).
  Override for other editions, e.g. "%APPDATA%\Code - Insiders\User\workspaceStorage".

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scan-storage.ps1 "e:\Source\My Project"
#>
param(
  [Parameter(Position = 0)][string]$FolderPath,
  [Parameter(Position = 1)][string]$StorageRoot = ''
)

$ErrorActionPreference = 'Stop'

if (-not $FolderPath) {
  Write-Output 'Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scan-storage.ps1 "<full folder path>" [storage root override]'
  exit 1
}
if (-not $StorageRoot) { $StorageRoot = Join-Path $env:APPDATA 'Code\User\workspaceStorage' }
if (-not (Test-Path -LiteralPath $StorageRoot)) {
  Write-Output "ERROR: storage root not found: $StorageRoot"
  Write-Output 'For another edition pass its root as the 2nd argument, e.g. "%APPDATA%\Code - Insiders\User\workspaceStorage".'
  exit 1
}

# ---- helpers -------------------------------------------------------------

# workspace.json URI -> the Windows fsPath VS Code hashed:
# "file:///e%3A/Source/My%2BFolder" -> "e:\Source\My+Folder"
function Convert-UriToFspath([string]$uri) {
  $p = $uri -replace '^file:///', ''
  $p = [uri]::UnescapeDataString($p)
  return ($p -replace '/', '\')
}

function Normalize-Query([string]$p) {
  $p = $p.Trim()
  $p = $p -replace '/', '\'
  # VS Code hashes the fsPath exactly as spelled in workspace.json, which uses a
  # lowercase drive letter on Windows ("e:\Source\..."). Match that spelling so the
  # computed id is correct even when the user typed "E:\...".
  if ($p -match '^([A-Za-z]):\\') { $p = $p.Substring(0, 1).ToLower() + $p.Substring(1) }
  return $p.TrimEnd('\')
}

# floor(folder creation time, Unix epoch ms) -- matches VS Code's Math.floor(birthtimeMs)
function Get-UnixMs([string]$path) {
  $item = Get-Item -LiteralPath $path
  $epochTicks = 621355968000000000   # 1970-01-01T00:00:00Z in .NET ticks
  return [long][math]::Floor(($item.CreationTimeUtc.Ticks - $epochTicks) / 10000)
}

function Get-Md5([string]$text) {
  $md5 = [System.Security.Cryptography.MD5]::Create()
  try {
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
    return (@($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $md5.Dispose() }
}

# ---- scan ----------------------------------------------------------------

$query = Normalize-Query $FolderPath
$hits = @()
$nearLeaf = @()
$nearParent = @()
$scanned = 0; $skipMulti = 0; $skipRemote = 0; $skipNoJson = 0

foreach ($dir in (Get-ChildItem -LiteralPath $StorageRoot -Directory)) {
  $scanned++
  $wjPath = Join-Path $dir.FullName 'workspace.json'
  if (-not (Test-Path -LiteralPath $wjPath)) { $skipNoJson++; continue }
  $meta = $null
  try { $meta = Get-Content -LiteralPath $wjPath -Raw | ConvertFrom-Json } catch { continue }
  if ($meta.PSObject.Properties['workspace']) { $skipMulti++; continue }   # .code-workspace: different id scheme
  $folderProp = $meta.PSObject.Properties['folder']
  if (-not $folderProp) { $skipNoJson++; continue }
  $uri = [string]$folderProp.Value
  if (-not $uri.StartsWith('file:///')) { $skipRemote++; continue }         # vscode-remote:// etc.: id = MD5(uri), immune

  $fspath = Convert-UriToFspath $uri
  $norm = Normalize-Query $fspath
  $csPath = Join-Path $dir.FullName 'chatSessions'
  $sessions = 0
  if (Test-Path -LiteralPath $csPath) {
    $sessions = @(Get-ChildItem -LiteralPath $csPath -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Extension -eq '.jsonl' -or $_.Extension -eq '.json' }).Count
  }

  if ($norm -ieq $query) {
    $hits += [pscustomobject]@{
      Hash = $dir.Name; FsPath = $fspath
      Created = $dir.CreationTime; LastWrite = $dir.LastWriteTime
      Sessions = $sessions; Status = 'ORPHANED'
    }
  }
  elseif ((Split-Path -Leaf $norm) -ieq (Split-Path -Leaf $query)) { $nearLeaf += "$($dir.Name)  ->  $fspath" }
  elseif ((Split-Path -Parent $norm) -ieq (Split-Path -Parent $query)) { $nearParent += "$($dir.Name)  ->  $fspath" }
}

# ---- classify ------------------------------------------------------------

$exists = Test-Path -LiteralPath $query
$isDir = $exists -and ((Get-Item -LiteralPath $query).PSIsContainer)
$ctimeMs = $null
if ($isDir) { $ctimeMs = Get-UnixMs $query }

foreach ($h in $hits) {
  if ($ctimeMs -and (Get-Md5 ($h.FsPath + $ctimeMs)) -eq $h.Hash) { $h.Status = 'CURRENT' }
}

$sorted = @($hits | Sort-Object Created)
$hasCurrent = @($hits | Where-Object { $_.Status -eq 'CURRENT' }).Count -gt 0
$targetId = $null
if ($hasCurrent) {
  # exact: the current era's hash IS the restore target
  $targetId = @($hits | Where-Object { $_.Status -eq 'CURRENT' })[0].Hash
}
elseif ($ctimeMs) {
  # folder exists but was never opened in VS Code since recreation: best guess
  $base = if ($sorted.Count -gt 0) { $sorted[-1].FsPath } else { $query }
  $targetId = Get-Md5 ($base + $ctimeMs)
}

# ---- report --------------------------------------------------------------

Write-Output '====================================================================='
Write-Output ' VS Code workspace-storage scout (READ-ONLY - nothing was modified)'
Write-Output '====================================================================='
Write-Output " Storage root : $StorageRoot"
Write-Output " Folder path  : $query"
Write-Output " Scanned $scanned storage folders (skipped: $skipMulti multi-root, $skipRemote remote, $skipNoJson empty-window)."
if ($exists -and -not $isDir) {
  Write-Output ' WARNING: the path exists but is a FILE, not a folder - results are meaningless.'
}
elseif ($isDir) {
  Write-Output " Folder on disk : YES   creation time (Unix ms): $ctimeMs"
  Write-Output " Current workspace id (MD5 of path + creation time): $targetId"
}
else {
  Write-Output ' Folder on disk : NO (deleted) - the restore target id cannot be computed'
  Write-Output ' until the folder is recreated.'
}
Write-Output ''

if ($sorted.Count -eq 0) {
  Write-Output ' No storage folders found for this path.'
  if ($nearLeaf.Count -gt 0) {
    Write-Output ''
    Write-Output ' Near misses - same folder NAME, different parent:'
    $nearLeaf | ForEach-Object { Write-Output "   $_" }
  }
  if ($nearParent.Count -gt 0) {
    Write-Output ''
    Write-Output ' Near misses - same PARENT, different folder name:'
    $nearParent | ForEach-Object { Write-Output "   $_" }
  }
  if ($nearLeaf.Count -eq 0 -and $nearParent.Count -eq 0) {
    Write-Output ' No near matches either - check the path for typos.'
  }
  exit 0
}

Write-Output ' Storage eras for this path (oldest first):'
Write-Output ''
Write-Output '  #  storage folder (hash)                       status    created (local)   last write         chat sessions'
$i = 0
foreach ($h in $sorted) {
  $i++
  Write-Output (' {0,2}  {1}  {2}  {3}  {4}  {5,6}' -f $i, $h.Hash, $h.Status.PadRight(8), $h.Created.ToString('yyyy-MM-dd HH:mm'), $h.LastWrite.ToString('yyyy-MM-dd HH:mm'), $h.Sessions)
}

if (-not $targetId) {
  Write-Output ''
  Write-Output ' The folder is currently deleted. Recreate it, then re-run this script to get'
  Write-Output ' the restore target id.'
  exit 0
}

$restorable = @($sorted | Where-Object { $_.Status -eq 'ORPHANED' -and $_.Sessions -gt 0 })
if ($restorable.Count -eq 0) {
  Write-Output ''
  Write-Output ' Nothing to restore: no orphaned era contains chat sessions.'
  exit 0
}

Write-Output ''
Write-Output '---------------------------------------------------------------------'
Write-Output ' RESTORING LOST SESSIONS - you run these yourself (the script never will)'
Write-Output ' Close ALL VS Code windows first. Run ONE block at a time; after each swap,'
Write-Output ' re-run this script before performing another.'
Write-Output ' (cmd syntax; in PowerShell replace the cd line with: cd "<root>")'
foreach ($r in $restorable) {
  Write-Output ''
  Write-Output (" Era stored at {0} ({1} sessions):" -f $r.Created.ToString('yyyy-MM-dd HH:mm'), $r.Sessions)
  Write-Output "   cd /d `"$StorageRoot`""
  if ($hasCurrent) { Write-Output "   ren $targetId $targetId-backup" }
  Write-Output "   ren $($r.Hash) $targetId"
}
Write-Output ''
Write-Output ' After the swap, open the folder in VS Code - the restored sessions appear in'
Write-Output ' Chat history. Trade-offs: sessions created after the folder was recreated live'
Write-Output ' in the -backup folder and disappear from the listing (copying their .jsonl files'
Write-Output ' across does not re-index them). The target id assumes you open the folder via'
Write-Output ' the same path spelling shown above. Consider enabling chat.sessionSync.enabled'
Write-Output ' so future sessions sync to the cloud.'
