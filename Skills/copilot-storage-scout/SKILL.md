---
name: copilot-storage-scout
description: 'Inventory VS Code workspace-storage folders and their GitHub Copilot chat sessions for a given folder path, across all delete/recreate eras, and generate restore commands. Use when chat sessions or history are missing after a folder was deleted and recreated, when sessions disappeared from Chat history, or to find which workspaceStorage folder belongs to a path. Windows (verified), Linux and macOS (implemented from VS Code source).'
argument-hint: '<full folder path>'
user-invocable: true
disable-model-invocation: true
---

# Copilot Storage Scout

Given a full folder path, find every VS Code `workspaceStorage` folder that belongs to
it — one per delete/recreate "era" — report which era is current, how many Copilot chat
sessions each era holds, and produce the exact commands to restore lost sessions.

**This skill is strictly READ-ONLY: never modify, rename, move, or delete anything under
the storage root. The user performs any restore themselves.**

## Platform support (state this clearly in every answer)

| Platform | Status | Runner |
|---|---|---|
| Windows | ✅ Verified against real storage | `scripts/scan-storage.ps1` — PowerShell 5.1+ (built into Windows) |
| Linux | ⚠️ Implemented from VS Code source, not yet field-verified | `scripts/scan-storage.py` — Python 3 (stdlib only) |
| macOS | ⚠️ Implemented from VS Code source, not yet field-verified | `scripts/scan-storage.py` — Python 3 (stdlib only) |

Scope: **VS Code desktop (stable) + GitHub Copilot Chat, local single-folder workspaces.**

- Other editions (Insiders, VSCodium) use different storage roots — pass an override as
  the script's second argument.
- Multi-root `.code-workspace` files: id = MD5(config file path), no creation salt —
  immune to this problem; skipped.
- Remote workspaces (WSL / SSH / devcontainers): id = MD5(URI), no salt — also immune;
  skipped.
- Other editors and other Copilot surfaces (Copilot CLI, coding agent) store their
  sessions elsewhere — out of scope.

## Why sessions disappear (domain knowledge)

- VS Code keeps per-workspace data in `<storage root>\<32-hex-id>\`. Copilot chat sessions
  are `.jsonl` files in its `chatSessions` subfolder; the visible-history index lives in
  that folder's `state.vscdb` (key `chat.ChatSessionStore.index`).
- Each storage folder contains `workspace.json`, e.g.
  `{"folder":"file:///e%3A/Source/My%2BFolder"}`, mapping it to its workspace. Storage
  folders without one (numeric names) are empty windows — ignored.
- Single-folder workspace id = `MD5(fsPath + String(salt))` — VS Code source:
  `src/vs/platform/workspaces/node/workspaces.ts` ("folders getting recreated result in a
  different identifier" — deliberate):
  - Windows: salt = `floor(birthtimeMs)` — creation time in Unix epoch ms
  - macOS: salt = `birthtime.getTime()` — creation time in Unix epoch ms
  - Linux: salt = `st_ino` — the folder's inode number
- Delete + recreate at the same path ⇒ new salt ⇒ new id ⇒ VS Code opens a fresh storage
  folder and the old sessions vanish from history. They are NOT deleted: the storage
  cleaner only removes empty-window folders, so every orphaned era remains on disk.
- Storage roots: Windows `%APPDATA%\Code\User\workspaceStorage`; macOS
  `~/Library/Application Support/Code/User/workspaceStorage`; Linux
  `$XDG_CONFIG_HOME/Code/User/workspaceStorage` (default `~/.config/Code/...`).

## Procedure

1. Take the user's full folder path. It may have been deleted and recreated any number
   of times, and may not currently exist.
2. Run the script for the current OS (paths relative to this skill's folder):
   - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/scan-storage.ps1 "<path>"`
   - Linux/macOS: `python3 scripts/scan-storage.py "<path>"`
   Both accept an optional second argument: storage-root override.
3. Relay the script's output essentially verbatim — it already contains the era table,
   the current-id verdict, near-misses when nothing matches, and restore commands.
4. Interpret for the user: exactly one era can be CURRENT; all others are ORPHANED. If
   the folder is currently deleted, tell the user to recreate it and re-run — the
   restore target id cannot be computed until then.

## The restore trick (explain when relevant)

To bring an orphaned era's sessions back: close ALL VS Code windows, then swap folders
(the script prints the exact commands):

```
cd <storage root>
ren <current-id> <current-id>-backup    # use mv instead of ren on Linux/macOS
ren <orphaned-id> <current-id>
```

State the trade-offs: sessions created after the recreation live in the `-backup`
folder and disappear from the listing (copying their `.jsonl` files across does not
re-index them); perform one swap at a time and re-run the script afterwards; enabling
the VS Code setting `chat.sessionSync.enabled` makes future sessions cloud-synced and
immune to this problem.

## Constraints

- READ-ONLY, no exceptions. Report; never touch.
- Sessions = `.jsonl` + `.json` files inside `chatSessions` (0 if absent). Never open,
  edit, or rely on `state.vscdb`.
- Never compare paths as raw strings: percent-decode the `workspace.json` URI and
  normalize separators first (`%3A` → `:`, `%2B` → `+`, `/` vs `\`, CJK, spaces).
- If nothing matches, present the script's near-miss list; do not guess.
