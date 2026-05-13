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

Run from inside the source worktree. Replace `<branch>`.

```powershell
# --- Inputs ---
$Branch = '<branch-name>'
$Source = (Get-Location).Path
$Dest   = Join-Path (Split-Path $Source -Parent) `
                    ((Split-Path $Source -Leaf) + '-' + ($Branch -replace '[\\/:*?"<>|]', '-'))
$Clone  = @('Library', 'Logs', 'obj', 'Packages')   # NOTE: never include Temp — see pitfalls

# --- Sanity: same ReFS volume ---
$srcRoot = (Split-Path $Source -Qualifier) + '\'
$dstRoot = (Split-Path $Dest   -Qualifier) + '\'
if ($srcRoot -ne $dstRoot) { throw "Source and Dest must be on the same volume." }
if ((Get-Volume -FilePath $srcRoot).FileSystemType -ne 'ReFS') {
    throw "Source not on ReFS — block clone unavailable. Skip cache clone or move to Dev Drive."
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

# --- Block-clone cache dirs ---
foreach ($dir in $Clone) {
    $srcDir = Join-Path $Source $dir
    $dstDir = Join-Path $Dest   $dir
    if (-not (Test-Path $srcDir)) { continue }
    # /XF UnityLockfile: never clone Unity's PID-bearing lock.
    & robocopy $srcDir $dstDir /E /MT:16 /NFL /NDL /NJH /NP /R:1 /W:1 /XF UnityLockfile | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Warning "robocopy errors in $dir (exit $LASTEXITCODE)" }
}

Write-Host "Worktree ready: $Dest"
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

- **Never clone `Temp/`.** `Temp/UnityLockfile` contains the source Editor's
  live PID. If the source Editor is running, Unity reads that PID in the
  cloned file and refuses to open the new worktree. `Temp/` is session
  state, not cache. The `/XF UnityLockfile` flag above is a defensive guard.
  Recovery: delete `<dest>\Temp\UnityLockfile`.
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
