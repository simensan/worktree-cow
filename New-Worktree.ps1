<#
.SYNOPSIS
    Create a git worktree and block-clone heavy gitignored folders (Unity Library, etc.)
    from the source worktree using ReFS copy-on-write on a Dev Drive.

.DESCRIPTION
    On a Windows 11 24H2+ Dev Drive (ReFS), robocopy uses block cloning automatically:
    the destination references the same on-disk blocks as the source. Files only
    consume extra space when modified. This makes spinning up a fresh Unity worktree
    (with a populated Library/) nearly instant and ~free in disk usage.

    Handles two layouts:
      - Flat: Unity project root IS the git repo root.
      - Nested: Unity project is a subdirectory of a larger repo (e.g. <repo>/UnityProject/).
                The cache clone targets the matching subdir inside the new worktree.

.PARAMETER Branch
    Branch to check out in the new worktree. Created from HEAD if it doesn't exist.

.PARAMETER Source
    Path to the source Unity project (the directory containing ProjectSettings/).
    Defaults to the current directory.

.PARAMETER Dest
    Destination path for the worktree (the repo root inside the worktree, NOT the
    Unity project subdir). Defaults to "<repo-parent>\<repo-leaf>-<branch>".

.PARAMETER Clone
    Directories to block-clone from source into the new worktree (gitignored caches).
    Defaults to a Unity-friendly set. Pass @() to skip cloning entirely.

.PARAMETER Force
    Proceed even if the source is not on a ReFS/Dev Drive volume. The copy still works
    but falls back to full byte-for-byte copy (slow, full disk usage).

.EXAMPLE
    .\New-Worktree.ps1 -Branch feature/inventory
    # Creates ..\<repo>-feature-inventory, clones Library/ etc. into the Unity subdir.

.EXAMPLE
    .\New-Worktree.ps1 -Branch experiment -Source V:\unity\MyGame -Dest V:\unity\MyGame-exp

.EXAMPLE
    .\New-Worktree.ps1 -Branch docs -Clone @()  # plain worktree, no cache clone

.NOTES
    - Source and Dest MUST be on the same ReFS/Dev Drive volume for block cloning.
    - Temp/ is intentionally excluded from the default clone list: it's session state,
      and Temp/UnityLockfile contains the source Editor's live PID — cloning it would
      make Unity refuse to open the new worktree. UnityLockfile is also excluded
      defensively via robocopy /XF if a caller passes Temp explicitly.
    - Uncommitted changes in source can cause Unity to mass-reimport on first open
      (cloned Library was built against the dirty working tree but the new worktree
      is checked out clean). The script warns but does not block.
    - Cleanup later with:  git worktree remove <dest>
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Branch,

    [string]$Source = (Get-Location).Path,

    [string]$Dest,

    [string[]]$Clone = @('Library', 'Logs', 'obj', 'Packages'),

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }
function Write-Ok($msg)   { Write-Host "OK  $msg" -ForegroundColor Green }

# --- Validate source is in a git repo, and locate repo root ---
$Source = (Resolve-Path $Source).Path
$RepoRoot = & git -C $Source rev-parse --show-toplevel 2>$null
if (-not $RepoRoot -or $LASTEXITCODE -ne 0) {
    throw "Source '$Source' is not inside a git repo."
}
$RepoRoot = $RepoRoot -replace '/','\'

# Unity project may BE the repo root, or live in a subdirectory of it.
$UnityRel = if ($Source -ieq $RepoRoot) { '' }
            else { $Source.Substring($RepoRoot.Length).TrimStart('\') }

# --- Default dest if not provided: peer of the repo root ---
if (-not $Dest) {
    $safeBranch = $Branch -replace '[\\/:*?"<>|]', '-'
    $repoParent = Split-Path $RepoRoot -Parent
    $repoLeaf   = Split-Path $RepoRoot -Leaf
    $Dest       = Join-Path $repoParent "$repoLeaf-$safeBranch"
}
$DestUnity = if ($UnityRel) { Join-Path $Dest $UnityRel } else { $Dest }

Write-Host "    Repo root:     $RepoRoot" -ForegroundColor DarkGray
Write-Host "    Unity project: $Source  (rel: '$UnityRel')" -ForegroundColor DarkGray
Write-Host "    Worktree dest: $Dest" -ForegroundColor DarkGray
Write-Host "    Cache target:  $DestUnity" -ForegroundColor DarkGray

# --- Check filesystem (warn if not ReFS/Dev Drive) ---
$srcRoot = (Split-Path $Source -Qualifier) + '\'
$dstRoot = (Split-Path $Dest   -Qualifier) + '\'
$srcVol  = Get-Volume -FilePath $srcRoot -ErrorAction SilentlyContinue

$isCoW = ($srcVol.FileSystemType -eq 'ReFS') -and ($srcRoot -eq $dstRoot)
if (-not $isCoW) {
    $reason = if ($srcRoot -ne $dstRoot) { "Source and Dest are on different volumes ($srcRoot vs $dstRoot)" }
              else { "Source volume is $($srcVol.FileSystemType), not ReFS" }
    Write-Warn2 "Block cloning unavailable: $reason."
    Write-Warn2 "robocopy will fall back to full byte copy - slow, full disk usage."
    if (-not $Force) {
        throw "Refusing to proceed without CoW. Re-run with -Force to accept the full copy."
    }
} else {
    Write-Ok "Source on ReFS Dev Drive - robocopy will block-clone."
}

# --- Warn if source has uncommitted changes ---
# Cloned Library was built against source's current (dirty) working tree, but
# `git worktree add` checks out the committed tree in dest. Mismatched input
# hashes -> Unity mass-reimports. ProjectSettings.asset is the worst offender.
$dirty = & git -C $Source status --porcelain
if ($dirty) {
    Write-Warn2 "Source has uncommitted changes - Unity will likely mass-reimport in the new worktree:"
    $dirty | ForEach-Object { Write-Warn2 "    $_" }
    Write-Warn2 "Commit or stash first to avoid this. Continuing anyway..."
}

# --- Create the worktree ---
Write-Step "git worktree add '$Dest' '$Branch'"
$branchExists = (& git -C $Source branch --list $Branch) -or `
                (& git -C $Source branch --list --remotes "*/$Branch")
if ($branchExists) {
    & git -C $Source worktree add $Dest $Branch
} else {
    Write-Step "Branch '$Branch' doesn't exist - creating from HEAD"
    & git -C $Source worktree add -b $Branch $Dest
}
if ($LASTEXITCODE -ne 0) { throw "git worktree add failed (exit $LASTEXITCODE)" }

# --- Block-clone heavy dirs INTO the Unity project subdir of the worktree ---
foreach ($dir in $Clone) {
    $srcDir = Join-Path $Source    $dir
    $dstDir = Join-Path $DestUnity $dir
    if (-not (Test-Path $srcDir)) {
        Write-Host "    skip: $dir (not in source)" -ForegroundColor DarkGray
        continue
    }
    Write-Step "clone $dir/ -> $dstDir"
    # /E recursive incl. empty, /MT:16 multithread, /NFL/NDL/NJH/NP quiet, /R:1 /W:1 fast-fail
    # /XF UnityLockfile: never clone Unity's PID-bearing lock - a live source PID would
    # make Unity refuse to open the new worktree.
    & robocopy $srcDir $dstDir /E /MT:16 /NFL /NDL /NJH /NP /R:1 /W:1 /XF UnityLockfile | Out-Null
    # robocopy exit codes 0-7 are success; 8+ are real failures
    if ($LASTEXITCODE -ge 8) {
        Write-Warn2 "robocopy reported errors for $dir (exit $LASTEXITCODE)"
    }
}

Write-Ok "Worktree ready: $Dest"
Write-Host ""
Write-Host "Open Unity at: $DestUnity" -ForegroundColor DarkGray
Write-Host "When done:     git -C '$Source' worktree remove '$Dest'" -ForegroundColor DarkGray
