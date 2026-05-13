# Agent guide: Unity git worktrees on Windows + Dev Drive

Drop this file into a Unity project to teach an AI agent how to spin up a
worktree correctly here. Self-contained — execute the commands below
directly; no helper script needed.

## When to use a worktree

Create one for parallel branch work where you can't disturb the current
working tree:

- The user is actively editing on another branch in Unity.
- Long-running build artifacts shouldn't be invalidated.
- Multiple agents working in parallel.
- Reviewing a PR while keeping the current branch open in Unity.

For a tiny change on a clean tree, just switch branches or stash.

## Why the cache-clone matters

A fresh `git worktree add` only checks out tracked files. Unity's `Library/`,
`Logs/`, `obj/`, `Packages/` are gitignored caches; without them, Unity does
a full reimport (minutes to hours) on first open.

On a Windows 11 24H2 **Dev Drive (ReFS)**, `robocopy` block-clones: the
destination references the same on-disk extents as the source. Cloning a
30 GB `Library/` is seconds and ~0 extra disk. Modified files copy-up
individually — the source is never touched.

## Prerequisites (verify before creating worktrees)

```powershell
# 1. Source must be on ReFS
Get-Volume -FilePath (Get-Location).Path | Select FileSystemType, DriveLetter
# Expect: FileSystemType = ReFS

# 2. Volume must be a Dev Drive
fsutil devdrv query <DriveLetter>:
# Expect: "This is a trusted developer volume."

# 3. Windows 11 build 26100 (24H2) or newer
[System.Environment]::OSVersion.Version
```

If the project isn't on a ReFS Dev Drive: move it, or skip the cache clone
(`$Clone = @()`) and accept a full Unity reimport on first open.

## Procedure

Run from inside the Unity project root (the dir containing
`ProjectSettings/`). The script auto-detects whether that's the git repo root
or a subdir of one — both layouts are supported.

```powershell
# --- Inputs ---
$Branch  = '<branch-name>'
$Source  = (Get-Location).Path                                     # cwd = Unity project root

# Locate the git repo root. The Unity project may BE the repo root, or live in
# a subdirectory of a larger repo (e.g. <repo>/UnityProject/). Compute the
# relative path so the cache clone lands at the matching location inside the
# worktree, not at the worktree root.
$RepoRoot = (& git -C $Source rev-parse --show-toplevel) -replace '/','\'
if (-not $RepoRoot) { throw "Not in a git repo." }
$UnityRel = if ($Source -ieq $RepoRoot) { '' }
            else { $Source.Substring($RepoRoot.Length).TrimStart('\') }

# Worktree dest is a peer of the repo root (NOT a peer of the Unity subdir).
$RepoParent = Split-Path $RepoRoot -Parent
$RepoLeaf   = Split-Path $RepoRoot -Leaf
$Dest       = Join-Path $RepoParent ($RepoLeaf + '-' + ($Branch -replace '[\\/:*?"<>|]', '-'))
$DestUnity  = if ($UnityRel) { Join-Path $Dest $UnityRel } else { $Dest }
$Clone      = @('Library', 'Logs', 'obj', 'Packages')              # NOTE: never include Temp — see pitfalls

Write-Host "Repo root:     $RepoRoot"
Write-Host "Unity project: $Source  (rel: '$UnityRel')"
Write-Host "Worktree dest: $Dest"
Write-Host "Cache target:  $DestUnity"

# --- Sanity: same ReFS volume ---
$srcRoot = (Split-Path $Source -Qualifier) + '\'
$dstRoot = (Split-Path $Dest   -Qualifier) + '\'
if ($srcRoot -ne $dstRoot) { throw "Source and Dest must be on the same volume." }
if ((Get-Volume -FilePath $srcRoot).FileSystemType -ne 'ReFS') {
    throw "Source not on ReFS — block clone unavailable. Skip cache clone or move to Dev Drive."
}

# --- Warn if source has uncommitted changes ---
# The cloned Library was built against source's *current* working tree (including
# uncommitted edits). `git worktree add` checks out the *committed* tree in dest.
# If source is dirty, Library's input hashes won't match dest's working tree and
# Unity will mass-reimport on first open. ProjectSettings.asset is the worst
# offender — one byte's difference invalidates most of the artifact graph.
$dirty = & git -C $Source status --porcelain
if ($dirty) {
    Write-Warning "Source has uncommitted changes — Unity will likely mass-reimport in the new worktree:"
    $dirty | ForEach-Object { Write-Warning "  $_" }
    Write-Warning "Commit or stash first to avoid this. Continuing anyway..."
}

# --- Create the worktree ---
$exists = (& git -C $Source branch --list $Branch) -or `
          (& git -C $Source branch --list --remotes "*/$Branch")
if ($exists) {
    & git -C $Source worktree add $Dest $Branch
} else {
    & git -C $Source worktree add -b $Branch $Dest
}
if ($LASTEXITCODE -ne 0) { throw "git worktree add failed" }

# --- Block-clone cache dirs INTO the Unity project subdir of the worktree ---
foreach ($dir in $Clone) {
    $srcDir = Join-Path $Source    $dir
    $dstDir = Join-Path $DestUnity $dir
    if (-not (Test-Path $srcDir)) { continue }
    # /XF UnityLockfile: never clone Unity's PID-bearing lock.
    & robocopy $srcDir $dstDir /E /MT:16 /NFL /NDL /NJH /NP /R:1 /W:1 /XF UnityLockfile | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Warning "robocopy errors in $dir (exit $LASTEXITCODE)" }
}

Write-Host "Worktree ready. Open Unity at: $DestUnity"
```

## Cleanup

```powershell
git -C <source> worktree remove <dest>
# Add --force only if there are uncommitted changes you've confirmed are disposable.
git worktree list   # verify
```

If a worktree directory was deleted manually, run `git worktree prune` to
drop the stale entry.

## Critical pitfalls

- **Open Unity at the Unity project subdir, not the worktree root** when the
  project lives in a subdirectory of the repo. The `Write-Host` at the end
  prints the right path.
- **Never clone `Temp/`.** `Temp/UnityLockfile` contains the source Editor's
  live PID. If the source Editor is running, Unity reads that PID in the
  cloned file and refuses to open the new worktree. `Temp/` is session
  state, not cache. The `/XF UnityLockfile` flag above is a defensive guard.
  Recovery: delete `<dest>\Temp\UnityLockfile`.
- **Uncommitted source changes cause mass reimport.** If `ProjectSettings.asset`
  is dirty in source, the cloned Library was built against the dirty version
  but the new worktree's `git checkout` produces the committed version —
  every artifact dependent on project settings (most of them) reimports.
  Commit or stash first. The warning above flags this.
- **One Editor per worktree path.** Two worktrees can each have their own
  Editor open — they're separate paths with separate `Library/`. Just don't
  open the same path twice.
- **Cross-volume or NTFS = full byte copy.** Block clone requires the same
  ReFS volume on both ends. The check above refuses to proceed.
- **Don't symlink `Library/` between worktrees.** They'd share state and
  Unity would mangle it.
- **Don't `rm` a worktree before `git worktree remove`.** Leaves a stale
  entry — recover with `git worktree prune`.
- **Major reimports** (Unity version upgrade, platform switch, Reimport All)
  copy-up most of `Library/`. CoW shines on same-version same-platform
  branch work, not platform switches.

## Cheat sheet

```powershell
git worktree list
git worktree remove <path>
git worktree remove --force <path>     # uncommitted changes will be lost
git worktree prune                     # after a manual rm
git worktree lock <path> --reason "..."
git worktree unlock <path>
git worktree move <from> <to>
```
