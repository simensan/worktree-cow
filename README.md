# worktree-cow

Fast git worktrees on Windows using ReFS block cloning — for Unity or anything
else with huge gitignored cache folders (`Library/`, `node_modules/`, `target/`).

A fresh `git worktree add` only checks out tracked files, so Unity reimports
the whole `Library/` on first open. This script `robocopy`s cache dirs into
the new worktree using ReFS block cloning: near-instant, ~0 extra disk until
you modify a file.

## Requirements

- Windows 11 **24H2** (build 26100+).
- A **Dev Drive** (ReFS) hosting both source and destination.
- `git` on PATH.

## Quick start

```powershell
# From inside a repo on a Dev Drive:
& C:\path\to\worktree-cow\New-Worktree.ps1 -Branch feature/foo
# Creates ..\<repo>-feature-foo with Library/ + Logs/ + obj/ + Packages/ cloned.

# Cleanup:
git worktree remove ..\<repo>-feature-foo
```

## Usage

```powershell
New-Worktree.ps1 -Branch <branch> [-Source <path>] [-Dest <path>] [-Clone <dirs>] [-Force]
```

| Parameter | Default | Description |
|---|---|---|
| `-Branch` | (required) | Branch to check out. Created from HEAD if missing. |
| `-Source` | cwd | Source Unity project path (the dir with `ProjectSettings/`). |
| `-Dest` | `<repo-parent>\<repo>-<branch>` | Worktree root (peer of the repo). Must be on the same volume as source. |
| `-Clone` | `Library, Logs, obj, Packages` | Dirs to block-clone. Pass `@()` to skip. |
| `-Force` | off | Proceed without CoW (full byte copy — slow). |

Handles two layouts:
- **Flat**: Unity project IS the git repo root.
- **Nested**: Unity project is a subdir of the repo (e.g. `<repo>/UnityProject/`).
  The cache clone targets the matching subdir inside the new worktree, and the
  final `Open Unity at: ...` line shows where the actual Unity project lives.

Non-Unity example: `-Clone @('node_modules', '.next')` or `-Clone @('target')`.

## Caveats

- `Temp/` is **not** cloned by default — `Temp/UnityLockfile` holds the source
  Editor's PID and would block opening the new worktree.
- **Commit or stash before cloning.** Uncommitted changes (especially to
  `ProjectSettings.asset`) make the cloned Library mismatch the worktree's
  checked-out content, triggering a Unity mass-reimport. The script warns but
  doesn't block.
- One Editor per worktree path (two worktrees can each have their own).
- Cross-volume or NTFS → full copy fallback (the script refuses without `-Force`).
- Always `git worktree remove`; don't `rm` the directory first.

## For AI agents

See [`AGENT-WORKTREE-GUIDE.md`](AGENT-WORKTREE-GUIDE.md).

## License

MIT.
