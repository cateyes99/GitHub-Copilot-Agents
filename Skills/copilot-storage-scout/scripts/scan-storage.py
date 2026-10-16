#!/usr/bin/env python3
"""READ-ONLY inventory of VS Code workspace-storage folders for a folder path.

Linux + macOS edition (Python 3, stdlib only). On Windows, use scan-storage.ps1
(the verified edition) instead.

VS Code identifies a single-folder workspace as MD5(fsPath + salt), where the salt is
BY DESIGN the folder's creation identity (microsoft/vscode
src/vs/platform/workspaces/node/workspaces.ts):
    macOS : creation time, Unix epoch ms   (Node Stats.birthtime.getTime())
    Linux : the folder's inode number       (Node Stats.ino)
Deleting and recreating a folder at the same path therefore yields a NEW id: VS Code
starts a fresh storage folder and the old chat sessions vanish from history, although
they remain fully recoverable on disk.

Usage:
    python3 scan-storage.py "<full folder path>" [storage root override]
"""

import hashlib
import json
import os
import sys
import time
import urllib.parse


def md5hex(text):
    return hashlib.md5(text.encode('utf-8')).hexdigest()


def fmt(t):
    return time.strftime('%Y-%m-%d %H:%M', time.localtime(t))


def main():
    if sys.platform.startswith('win'):
        print('On Windows, use scan-storage.ps1 instead (it is the verified edition).')
        sys.exit(2)
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print('Usage: python3 scan-storage.py "<full folder path>" [storage root override]')
        sys.exit(1)

    query = sys.argv[1].strip().replace('\\', '/').rstrip('/')
    if len(sys.argv) > 2 and sys.argv[2].strip():
        root = sys.argv[2].strip()
    elif sys.platform == 'darwin':
        root = os.path.expanduser('~/Library/Application Support/Code/User/workspaceStorage')
    else:
        cfg = os.environ.get('XDG_CONFIG_HOME', os.path.expanduser('~/.config'))
        root = os.path.join(cfg, 'Code', 'User', 'workspaceStorage')

    if not os.path.isdir(root):
        print('ERROR: storage root not found: %s' % root)
        print('For another edition pass its root as the 2nd argument,')
        print('e.g. ".../Code - Insiders/User/workspaceStorage".')
        sys.exit(1)

    is_darwin = sys.platform == 'darwin'
    exists = os.path.isdir(query)

    hits, near_leaf, near_parent = [], [], []
    scanned = skip_multi = skip_remote = skip_nojson = 0

    for name in sorted(os.listdir(root)):
        scanned += 1
        wj = os.path.join(root, name, 'workspace.json')
        if not os.path.isfile(wj):
            skip_nojson += 1
            continue
        try:
            with open(wj, encoding='utf-8') as f:
                meta = json.load(f)
        except Exception:
            continue
        if 'workspace' in meta:
            skip_multi += 1          # .code-workspace: different id scheme
            continue
        uri = meta.get('folder')
        if not uri:
            skip_nojson += 1
            continue
        if not uri.startswith('file:///'):
            skip_remote += 1         # vscode-remote:// etc.: id = MD5(uri), immune
            continue
        fspath = urllib.parse.unquote(uri[len('file://'):])
        norm = fspath.rstrip('/')
        cs = os.path.join(root, name, 'chatSessions')
        sessions = 0
        if os.path.isdir(cs):
            sessions = sum(1 for x in os.listdir(cs)
                           if os.path.isfile(os.path.join(cs, x))
                           and (x.endswith('.jsonl') or x.endswith('.json')))
        if norm.lower() == query.lower():
            st = os.stat(os.path.join(root, name))
            hits.append({'hash': name, 'fspath': fspath,
                         'created': getattr(st, 'st_birthtime', st.st_ctime),
                         'last': st.st_mtime, 'sessions': sessions,
                         'status': 'ORPHANED'})
        elif os.path.basename(norm).lower() == os.path.basename(query).lower():
            near_leaf.append('%s  ->  %s' % (name, fspath))
        elif os.path.dirname(norm).lower() == os.path.dirname(query).lower():
            near_parent.append('%s  ->  %s' % (name, fspath))

    # ---- current-id candidates -------------------------------------------
    salts = []
    if exists:
        qst = os.stat(query)
        if is_darwin:
            # Python's st_birthtime float can lose sub-ms precision, so probe a window.
            base = int(getattr(qst, 'st_birthtime', qst.st_mtime) * 1000)
            salts = [str(base + d) for d in (-2, -1, 0, 1, 2)]
        else:
            salts = [str(qst.st_ino)]

    for h in hits:
        if any(h['hash'] == md5hex(h['fspath'] + s) for s in salts):
            h['status'] = 'CURRENT'

    hits.sort(key=lambda h: h['created'])
    has_current = any(h['status'] == 'CURRENT' for h in hits)
    if has_current:
        # exact: the current era's hash IS the restore target
        target = next(h['hash'] for h in hits if h['status'] == 'CURRENT')
    elif salts:
        # folder exists but was never opened in VS Code since recreation: best guess
        base_path = hits[-1]['fspath'] if hits else query
        target = md5hex(base_path + salts[len(salts) // 2])
    else:
        target = None

    # ---- report ----------------------------------------------------------
    print('=====================================================================')
    print(' VS Code workspace-storage scout (READ-ONLY - nothing was modified)')
    print('=====================================================================')
    print(' Storage root : %s' % root)
    print(' Folder path  : %s' % query)
    print(' Scanned %d storage folders (skipped: %d multi-root, %d remote, %d empty-window).'
          % (scanned, skip_multi, skip_remote, skip_nojson))
    if exists:
        print(' Folder on disk : YES')
        print(' Current workspace id (MD5 of path + creation identity): %s' % target)
        if is_darwin:
            print(' (macOS: id derived from a +/-2ms window around the detected birthtime;')
            print('  if no era is marked CURRENT, open the folder in VS Code once and re-run.)')
        else:
            print(' (Linux: the created column shows inode ctime, an approximation.)')
    else:
        print(' Folder on disk : NO (deleted) - the restore target id cannot be computed')
        print(' until the folder is recreated.')
    print('')

    if not hits:
        print(' No storage folders found for this path.')
        if near_leaf:
            print('')
            print(' Near misses - same folder NAME, different parent:')
            for n in near_leaf:
                print('   %s' % n)
        if near_parent:
            print('')
            print(' Near misses - same PARENT, different folder name:')
            for n in near_parent:
                print('   %s' % n)
        if not near_leaf and not near_parent:
            print(' No near matches either - check the path for typos.')
        return

    print(' Storage eras for this path (oldest first):')
    print('')
    print('  #  storage folder (hash)                       status    created (local)   last write         chat sessions')
    for i, h in enumerate(hits, 1):
        print(' %2d  %s  %-8s  %s  %s  %6d'
              % (i, h['hash'], h['status'], fmt(h['created']), fmt(h['last']), h['sessions']))

    if target is None:
        print('')
        print(' The folder is currently deleted. Recreate it, then re-run this script to')
        print(' get the restore target id.')
        return

    restorable = [h for h in hits if h['status'] == 'ORPHANED' and h['sessions'] > 0]
    if not restorable:
        print('')
        print(' Nothing to restore: no orphaned era contains chat sessions.')
        return

    print('')
    print('---------------------------------------------------------------------')
    print(' RESTORING LOST SESSIONS - you run these yourself (the script never will)')
    print(' Close ALL VS Code windows first. Run ONE block at a time; after each swap,')
    print(' re-run this script before performing another.')
    for r in restorable:
        print('')
        print(' Era stored at %s (%d sessions):' % (fmt(r['created']), r['sessions']))
        print('   cd "%s"' % root)
        if has_current:
            print('   mv %s %s-backup' % (target, target))
        print('   mv %s %s' % (r['hash'], target))
    print('')
    print(' After the swap, open the folder in VS Code - the restored sessions appear in')
    print(' Chat history. Trade-offs: sessions created after the folder was recreated live')
    print(' in the -backup folder and disappear from the listing (copying their .jsonl files')
    print(' across does not re-index them). The target id assumes you open the folder via')
    print(' the same path spelling shown above. Consider enabling chat.sessionSync.enabled')
    print(' so future sessions sync to the cloud.')


if __name__ == '__main__':
    main()
