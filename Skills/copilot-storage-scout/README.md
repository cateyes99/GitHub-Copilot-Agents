# copilot-storage-scout

A GitHub Copilot **Skill** for VS Code made by _**GitHub Copilot**_ + _**GLM5.3** on **build.Nividia.com**_ that inventories the GitHub Copilot chat sessions
stored for any folder on your drive — including **lost sessions** — and generates the
exact commands to bring them back.

## The problem it solves: "same folder name, same path, sessions gone"

You have a folder, say `D:\Make\Up\Folder`, with GitHub Copilot chat sessions associated
with it. At some point you **delete** that folder, and later **recreate a new folder with
the SAME name at the SAME full path**. When you open the recreated folder in VS Code, all
your previous Copilot chat sessions are gone from Chat history.

This is not a bug — it is deliberate VS Code behavior. For a single-folder workspace,
VS Code computes the workspace identity as:

$$
\text{workspaceId} = \text{MD5}\big(\underbrace{\text{folder path}}_{\text{same}} + \underbrace{\text{folder creation time}}_{\text{changes on recreate!}}\big)
$$

```
id = MD5( folder path + creation identity of the folder )
```

where the "creation identity" is the folder's **creation time** on Windows/macOS, or its
**inode number** on Linux. Deleting and recreating a folder at the exact same path
changes that salt, so the recreated folder gets a **brand-new workspace id**. VS Code then
opens a fresh, empty per-workspace storage folder — and your old chat sessions, while
still fully intact on disk, are no longer listed.

**This skill retrieves exactly that info**: give it a full folder path (which may have
been deleted and recreated any number of times), and it finds *every* storage "era" that
ever belonged to that path, tells you which era is the current one, how many chat
sessions each era holds, and prints ready-to-copy commands to restore the lost ones.

## What you get

For a path like `e:\Source\Solar-System-Explorer\Cline+DS4.1F`:

```
 Storage eras for this path (oldest first):

  #  storage folder (hash)                       status    created (local)   last write         chat sessions
  1  49ed8977d265bb7b65830f123e6ab0d1  ORPHANED  2026-09-19 13:49  2026-10-13 09:51      35
  2  95f8f9a87c4d45aa57532b5cfe78308f  CURRENT   2026-10-15 22:01  2026-10-17 08:30       3

 RESTORING LOST SESSIONS - you run these yourself (the script never will)
 Close ALL VS Code windows first. Run ONE block at a time; after each swap,
 re-run this script before performing another.

 Era stored at 2026-09-19 13:49 (35 sessions):
   cd /d "C:\Users\<you>\AppData\Roaming\Code\User\workspaceStorage"
   ren 95f8f9a87c4d45aa57532b5cfe78308f 95f8f9a87c4d45aa57532b5cfe78308f-backup
   ren 49ed8977d265bb7b65830f123e6ab0d1 95f8f9a87c4d45aa57532b5cfe78308f
```

After running the swap (with all VS Code windows closed) and reopening the folder, the
35 lost sessions reappear in Chat history.

## Platform support

| Platform          | Salt in the workspace id             | Status                                                       |
| ----------------- | ------------------------------------ | ------------------------------------------------------------ |
| **Windows** | Folder creation time (Unix epoch ms) | ✅ Verified against real storage                             |
| **macOS**   | Folder creation time (Unix epoch ms) | ⚠️ Implemented from VS Code source, not yet field-verified |
| **Linux**   | Folder inode number (`st_ino`)     | ⚠️ Implemented from VS Code source, not yet field-verified |

The delete/recreate → lost-sessions behavior exists on **all three platforms** (all three
salt the id); only the salt value differs.

Scope: VS Code desktop (stable) + GitHub Copilot Chat, local single-folder workspaces.
Multi-root `.code-workspace` files and remote workspaces (WSL/SSH/devcontainers) use
unsalted ids and are immune to this problem — the skill skips them. Other editions
(Insiders, VSCodium) are supported by passing their storage root as the script's second
argument.

## Windows case-insensitive paths — handled

On Windows, paths are **case-insensitive**, and the skill handles this correctly:

- All path matching against VS Code's `workspace.json` records is case-insensitive, so
  `D:\MAKE\UP\FOLDER`, `d:\make\up\folder` and `D:\Make\Up\Folder` all find the same
  storage eras.
- Disk checks (existence, creation time) go through Windows itself, which is
  case-insensitive.
- The restore target id never depends on how *you* spelled the path: it is taken from
  the current era's hash, or from the exact path spelling recorded inside VS Code's own
  `workspace.json` — never from your typed casing.

(FYI: VS Code's workspace hash itself is case-*sensitive*, so opening the same physical
folder with different casing creates separate eras. The skill's case-insensitive matching
finds all of them regardless.)

## Installation

Copy this folder to your personal skills directory:

```
# Windows
xcopy /E /I "E:\Source\GitHub-Copilot-Agents\Skills\copilot-storage-scout" "%USERPROFILE%\.copilot\skills\copilot-storage-scout"

# Linux / macOS
cp -r ./copilot-storage-scout ~/.copilot/skills/
```

Then start a new Copilot chat in VS Code. Note: personal skills live under
`~/.copilot/skills/` and do **not** roam with VS Code Settings Sync — copy them to each
machine manually.

## Usage

### As a skill (recommended)

In any Copilot chat — the target folder does **not** need to be open:

```
/copilot-storage-scout D:\Make\Up\Folder
```

The skill is `user-invocable` only (`disable-model-invocation: true`), so it never runs
unless you explicitly ask for it.

### Directly in a terminal

```powershell
# Windows (PowerShell 5.1+, no dependencies)
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.copilot\skills\copilot-storage-scout\scripts\scan-storage.ps1" "D:\Make\Up\Folder"

# Optional 2nd argument: storage-root override, e.g. for VS Code Insiders
powershell -NoProfile -ExecutionPolicy Bypass -File scan-storage.ps1 "D:\Make\Up\Folder" "$env:APPDATA\Code - Insiders\User\workspaceStorage"
```

```bash
# Linux / macOS (Python 3, stdlib only)
python3 ~/.copilot/skills/copilot-storage-scout/scripts/scan-storage.py "/home/you/make/up/folder"
```

### Edge cases handled

- **Folder currently deleted:** lists its eras and explains that the restore target id
  cannot be computed until the folder is recreated — recreate it, then re-run.
- **No match:** reports zero matches plus a near-miss list (same folder name under a
  different parent, or same parent with a different folder name) to catch typos and
  encoding mismatches.
- **Multiple delete/recreate cycles:** one era per cycle, oldest first; restore one at a
  time, re-running the skill between swaps.
- **Paths with special characters:** `+`, spaces, CJK characters, and URI-encoded
  `workspace.json` entries (`%3A`, `%2B`, …) are decoded and normalized before matching.

## Safety

**The skill is strictly READ-ONLY.** It never modifies, renames, moves, or deletes
anything — it only reports and prints suggested commands. You perform any restore
yourself, with all VS Code windows closed. Restoring swaps the current era into a
`-backup` folder; sessions created after the folder was recreated live there and
disappear from the listing (copying their `.jsonl` files across does not re-index them).

To avoid the problem going forward: delete a folder's *contents* rather than the folder
itself, or enable the VS Code setting `chat.sessionSync.enabled` so sessions sync to the
cloud and are immune to workspace-identity changes.

## Files

| File                         | Purpose                                                                               |
| ---------------------------- | ------------------------------------------------------------------------------------- |
| `SKILL.md`                 | The skill definition: domain knowledge, procedure, output interpretation, constraints |
| `scripts/scan-storage.ps1` | Windows scanner (PowerShell 5.1+, field-verified)                                     |
| `scripts/scan-storage.py`  | Linux/macOS scanner (Python 3 stdlib, implemented from VS Code source)                |

## Background

The workspace-identity mechanism comes from the VS Code source
(`src/vs/platform/workspaces/node/workspaces.ts`), which notes that the creation-time
salt exists so that "folders getting recreated result in a different identifier".
Orphaned storage folders are never garbage-collected (the storage cleaner only removes
empty-window folders), which is why the lost sessions remain fully recoverable.
