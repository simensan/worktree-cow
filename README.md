# worktree-cow

Fast git worktrees on Windows using ReFS block cloning — for Unity, monorepos,
or anything else with huge gitignored cache folders (`Library/`, `node_modules/`,
`.next/`, `target/`, `obj/`...).

A fresh `git worktree add` only checks out tracked files. For Unity projects in
particular, that means the new worktree has no `Library/` and Unity will spend
minutes-to-hours reimporting on first open. **worktree-cow** copies those cache
dirs into the new worktree using ReFS block cloning: near-instant, ~0 extra
disk space until you actually modify a file.

## How it works

On a Windows 11 Dev Drive (ReFS, 24H2+), `robocopy` performs **block cloning**:
the destination references the same on-disk extents as the source. Files only
consume extra disk space when modified — and only the modified extents, not the
whole file. The original worktree is never touched.

The wrapper script:

1. Validates that source and destination are on the same ReFS Dev Drive volume.
2. Runs `git worktree add` for the requested branch.
3. `robocopy`s the configured cache directories into the new worktree.

Same end behavior as a copy-on-write overlay filesystem, without any mount or
daemon — just native ReFS.

## Requirements

- Windows 11 build **26100 (24H2)** or newer — block clone on Dev Drive ships
  in this release.
- A **Dev Drive** (ReFS volume) hosting both the source repo and the new
  worktree. C:\ cannot be a Dev Drive; create one on another volume.
- `git` on PATH.

Verify:

```powershell
[System.Environment]::OSVersion.Version              # build >= 26100
Get-Volume -FilePath (Get-Location).Path             # FileSystemType = ReFS
fsutil devdrv query <DriveLetter>:                   # "trusted developer volume"
```

If the source repo isn't on a Dev Drive, see [Setting up a Dev Drive](#setting-up-a-dev-drive)
below.

## Quick start

```powershell
# From inside a repo:
& C:\path\to\worktree-cow\New-Worktree.ps1 -Branch feature/inventory
# Creates ..\<repo>-feature-inventory with Library/ + Temp/ + Logs/ + obj/ + Packages/ cloned.
```

That's it. `cd` into the new worktree and start working. Open the project in
Unity — first load is fast because `Library/` is already populated.

When done:

```powershell
git worktree remove ..\<repo>-feature-inventory
```

## Usage

```powershell
New-Worktree.ps1 -Branch <branch> [-Source <path>] [-Dest <path>] [-Clone <dirs>] [-Force]
```

| Parameter | Default | Description |
|---|---|---|
| `-Branch` | (required) | Branch to check out. Created from HEAD if it doesn't exist. |
| `-Source` | cwd | Source worktree path. |
| `-Dest` | `<source>-<branch>` sibling | Destination worktree path. **Must be on the same volume as source.** |
| `-Clone` | `Library, Temp, Logs, obj, Packages` | Directories to block-clone. Pass `@()` to skip. |
| `-Force` | off | Proceed without CoW (full byte copy — slow). |

### Examples

```powershell
# Unity project, default behavior
.\New-Worktree.ps1 -Branch feature/foo

# Explicit destination
.\New-Worktree.ps1 -Branch hotfix -Dest V:\unity\MyGame-hotfix

# Docs/text-only branch — no caches needed
.\New-Worktree.ps1 -Branch docs -Clone @()

# Node project
.\New-Worktree.ps1 -Branch refactor -Clone @('node_modules', '.next', 'dist')

# Rust project
.\New-Worktree.ps1 -Branch x -Clone @('target')

# Force full copy on NTFS (slow — only when you have no choice)
.\New-Worktree.ps1 -Branch y -Force
```

## Caveats

- **One Unity Editor per project at a time.** Worktrees are independent on
  disk, but opening the same project in two Editors corrupts the asset
  database. `UnityLockfile` blocks this; don't try to force around it.
- **Cross-volume copies fall back to full copy.** Block clone only works
  within a single ReFS volume. The script detects this and refuses unless
  `-Force` is passed.
- **NTFS doesn't support block clone.** Same fallback applies. Move projects
  to a Dev Drive for the CoW benefit.
- **Don't symlink `Library/` between worktrees** — both would share state and
  Unity would mangle them.
- **Don't `rm` a worktree dir before `git worktree remove`** — leaves a stale
  entry; recover with `git worktree prune`.
- **Major reimports** (Unity version upgrade, platform switch, Reimport All)
  will copy-up most of `Library/`. CoW savings shine on same-version
  same-platform branch work.

## Setting up a Dev Drive

Settings → System → Storage → Advanced storage settings → Disks & volumes
→ **Create dev drive**. Pick **Create new VHD** (portable, resizable), VHDX
format, dynamically expanding, 200–500 GB depending on project size. Assign a
drive letter.

Or from elevated PowerShell:

```powershell
Format-Volume -DriveLetter V -DevDrive
fsutil devdrv query V:
```

Then move your Unity project (whole folder, including `Library/`) to `V:\`.

## For AI agents

If you're an AI agent (Claude Code, Cursor, etc.) reading this repo to learn
how to manage worktrees in this environment, read
[`AGENT-WORKTREE-GUIDE.md`](AGENT-WORKTREE-GUIDE.md). It has decision rules
for when to spin up a worktree, the cleanup contract, and pitfalls to avoid.

## Why not...

- **Symlinks / junctions on `Library/`** → both worktrees share state, Unity
  corrupts them.
- **Hardlinks** → same problem; writes affect the original.
- **OverlayFS / unionfs** → Linux-only; Unity doesn't run in WSL meaningfully.
- **ProjFS** (Windows Projected File System) → requires writing a custom
  provider; no turnkey use.
- **A separate `Library/` cache shared via env var** → Unity doesn't support
  this; the path is hardcoded per project.

ReFS block cloning is the only Windows-native answer that gives true
copy-on-write semantics without a custom filesystem driver.

## License

MIT. See [`LICENSE`](LICENSE).
