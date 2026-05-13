# Agent guide: working with git worktrees (Windows + Unity + Dev Drive)

This document tells an AI agent how to use git worktrees in this environment
without re-deriving the setup each time. Copy or symlink it into project roots
so agents pick it up.

## TL;DR

- Use worktrees for **any parallel branch work**: experimental refactors, AI
  agent sandboxes, reviewing a PR while keeping main checked out, running long
  builds without blocking other edits.
- All worktrees of a Unity project **must live on the same Dev Drive (ReFS)
  volume** as the source, so ReFS block cloning makes the copy free.
- Create a worktree with `New-Worktree.ps1` (see "Script" below). Do **not**
  hand-roll `git worktree add` for Unity projects — you'll get a worktree with
  no `Library/` and Unity will spend hours reimporting.
- Clean up with `git worktree remove <path>`. Never `rm -rf` a worktree dir
  before unregistering it.

## Why this setup exists

Unity's `Library/`, `Temp/`, `Logs/`, `obj/` are gitignored caches. A fresh
worktree is missing them, so opening it in Unity triggers a full asset
reimport — minutes to hours depending on project size.

On a Dev Drive (Windows 11 ReFS volume), `robocopy` performs **block cloning**:
the destination references the same on-disk extents as the source. Cloning a
30 GB `Library/` takes seconds and adds ~0 disk usage until Unity modifies
files. Each modified file is copy-up'd individually; the source is never
touched.

## Prerequisites (verify before creating worktrees)

```powershell
# 1. Source must be on ReFS Dev Drive
Get-Volume -FilePath (Get-Location).Path | Select FileSystemType, DriveLetter
# Expect: FileSystemType = ReFS

# 2. Dev Drive must be designated as such (gives perf-mode AV + block clone)
fsutil devdrv query <DriveLetter>:
# Expect: "This is a trusted developer volume."

# 3. Windows 11 build 26100 (24H2) or newer — block clone for Dev Drive
[System.Environment]::OSVersion.Version
```

If any check fails:
- Not on Dev Drive → see the main README's "Setting up a Dev Drive" section,
  or fall back to plain `git worktree add` and accept a slow first Unity open.
- Old Windows → upgrade to 24H2 or fall back to slow copy.

## Script

`New-Worktree.ps1` in this repo — usage (adjust path to wherever you put the repo):

```powershell
# From inside the source repo:
& C:\Users\simen\Documents\GitHub\worktree-cow\New-Worktree.ps1 -Branch feature/foo
# Creates <repo>-feature-foo alongside the current repo, with Library/ etc. cloned.

# With explicit dest:
& <repo>\New-Worktree.ps1 -Branch hotfix -Dest V:\unity\MyGame-hotfix

# Plain worktree, no cache clone (e.g. docs-only branches):
& <repo>\New-Worktree.ps1 -Branch docs -Clone @()

# Non-Unity project — override clone list:
& <repo>\New-Worktree.ps1 -Branch x -Clone @('node_modules', '.next', 'dist')
```

Parameters:
- `-Branch` (required) — branch name; created from HEAD if it doesn't exist.
- `-Source` (default: cwd) — source worktree path.
- `-Dest` (default: `<source>-<branch>` sibling dir).
- `-Clone` (default: `Library, Temp, Logs, obj, Packages` — Unity defaults).
- `-Force` — proceed without CoW (falls back to full copy; slow).

## Workflow for an agent

When asked to work on a separate branch / try an experiment / review a PR
without disturbing the user's current state:

1. **Confirm need for a worktree.** If the change is small and the user's
   working tree is clean, a normal branch switch may suffice. Use worktrees
   when: long-running build artifacts shouldn't be invalidated, the user is
   actively editing, multiple agents are working in parallel, or the user
   explicitly asks.

2. **Locate the source repo root** (`git rev-parse --show-toplevel`).

3. **Run the script:**
   ```powershell
   & <path-to>\New-Worktree.ps1 -Branch <branch-name>
   ```

4. **`cd` into the new worktree** and do work there. Commit normally.

5. **Push and/or merge** when done.

6. **Clean up:**
   ```powershell
   git -C <source> worktree remove <dest>
   # If the worktree has uncommitted changes, --force is required;
   # only use it after confirming with the user.
   ```

7. **List worktrees to verify:**
   ```powershell
   git worktree list
   ```

## Caveats and pitfalls

- **One Unity Editor per project at a time.** Even though worktrees are
  independent on disk, opening the same project in two Editors corrupts the
  asset database. `UnityLockfile` blocks it, but don't try to force around it.
- **Cross-volume copies break CoW.** If `-Dest` is on a different volume than
  `-Source`, robocopy falls back to full copy. The script warns about this
  and refuses unless `-Force` is passed.
- **NTFS volumes don't support block clone.** Only ReFS / Dev Drive. The
  script detects this and warns.
- **Don't symlink `Library/` between worktrees.** Both worktrees would share
  state and Unity would mangle them.
- **Don't `rm` a worktree directory before `git worktree remove`.** It leaves
  a stale entry; recover with `git worktree prune`.
- **First Unity open in the new worktree** may copy-up parts of `Library/`
  (validation, version-specific caches). That's expected and one-time.
- **Switching Unity versions or platforms** in a worktree forces a big
  reimport — copy-up will dominate. The CoW savings shine on same-version
  same-platform branch work, not on major platform switches.

## Common operations cheat sheet

```powershell
# List all worktrees
git worktree list

# Remove a worktree (clean — no uncommitted changes)
git worktree remove <path>

# Force-remove (uncommitted changes will be lost)
git worktree remove --force <path>

# Clean up after a manual rm
git worktree prune

# Lock a worktree to prevent automatic prune (e.g. on removable disk)
git worktree lock <path> --reason "long-running experiment"
git worktree unlock <path>

# Move a worktree
git worktree move <from> <to>
```

## When NOT to use this workflow

- Tiny changes that don't need a separate working tree → just commit on a
  branch or stash.
- Projects already on NTFS and you can't move them → block clone won't work,
  full copy of `Library/` is slow. Either move the project to a Dev Drive
  first, or skip the cache clone (`-Clone @()`) and accept a Unity reimport.
- Repos where the cache dirs are tiny (most non-Unity projects) → a plain
  `git worktree add` is fine.
