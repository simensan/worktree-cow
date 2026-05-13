<#
.SYNOPSIS
    Create a git worktree and block-clone heavy gitignored folders (Unity Library, etc.)
    from the source worktree using ReFS copy-on-write on a Dev Drive.

.DESCRIPTION
    On a Windows 11 24H2+ Dev Drive (ReFS), robocopy uses block cloning automatically:
    the destination references the same on-disk blocks as the source. Files only
    consume extra space when modified. This makes spinning up a fresh Unity worktree
    (with a populated Library/) nearly instant and ~free in disk usage.

.PARAMETER Branch
    Branch to check out in the new worktree. Created from HEAD if it doesn't exist.

.PARAMETER Source
    Path to the source worktree. Defaults to the current directory.

.PARAMETER Dest
    Destination path for the new worktree. Defaults to "<Source>-<Branch>" alongside the source.

.PARAMETER Clone
    Directories to block-clone from source into the new worktree (gitignored caches).
    Defaults to a Unity-friendly set. Pass @() to skip cloning entirely.

.PARAMETER Force
    Proceed even if the source is not on a ReFS/Dev Drive volume. The copy still works
    but falls back to full byte-for-byte copy (slow, full disk usage).

.EXAMPLE
    .\New-Worktree.ps1 -Branch feature/inventory
    # Creates ..\<repo>-feature-inventory next to the current repo, clones Library/ etc.

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
    - Cleanup later with:  git worktree remove <dest>   (then delete leftover dirs if any)
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

# --- Validate source ---
$Source = (Resolve-Path $Source).Path
if (-not (Test-Path (Join-Path $Source '.git'))) {
    throw "Source '$Source' is not a git repo (no .git found)."
}

# --- Default dest if not provided ---
if (-not $Dest) {
    $safeBranch = $Branch -replace '[\\/:*?"<>|]', '-'
    $parent = Split-Path $Source -Parent
    $leaf   = Split-Path $Source -Leaf
    $Dest   = Join-Path $parent "$leaf-$safeBranch"
}

# --- Check filesystem (warn if not ReFS/Dev Drive) ---
$srcRoot = (Split-Path $Source -Qualifier) + '\'
$dstRoot = (Split-Path $Dest   -Qualifier) + '\'
$srcVol  = Get-Volume -FilePath $srcRoot -ErrorAction SilentlyContinue
$dstVol  = Get-Volume -FilePath $dstRoot -ErrorAction SilentlyContinue

$isCoW = ($srcVol.FileSystemType -eq 'ReFS') -and ($srcRoot -eq $dstRoot)
if (-not $isCoW) {
    $reason = if ($srcRoot -ne $dstRoot) { "Source and Dest are on different volumes ($srcRoot vs $dstRoot)" }
              else { "Source volume is $($srcVol.FileSystemType), not ReFS" }
    Write-Warn2 "Block cloning unavailable: $reason."
    Write-Warn2 "robocopy will fall back to full byte copy — slow, full disk usage."
    if (-not $Force) {
        throw "Refusing to proceed without CoW. Re-run with -Force to accept the full copy."
    }
} else {
    Write-Ok "Source on ReFS Dev Drive — robocopy will block-clone."
}

# --- Create the worktree ---
Write-Step "git worktree add '$Dest' '$Branch'"
$branchExists = (& git -C $Source branch --list $Branch) -or `
                (& git -C $Source branch --list --remotes "*/$Branch")
if ($branchExists) {
    & git -C $Source worktree add $Dest $Branch
} else {
    Write-Step "Branch '$Branch' doesn't exist — creating from HEAD"
    & git -C $Source worktree add -b $Branch $Dest
}
if ($LASTEXITCODE -ne 0) { throw "git worktree add failed (exit $LASTEXITCODE)" }

# --- Block-clone heavy dirs ---
foreach ($dir in $Clone) {
    $srcDir = Join-Path $Source $dir
    $dstDir = Join-Path $Dest   $dir
    if (-not (Test-Path $srcDir)) {
        Write-Host "    skip: $dir (not in source)" -ForegroundColor DarkGray
        continue
    }
    Write-Step "clone $dir/"
    # /E recursive incl. empty, /MT:16 multithread, /NFL/NDL/NJH/NP quiet, /R:1 /W:1 fast-fail
    # /XF UnityLockfile: never clone Unity's PID-bearing lock — a live source PID would
    # make Unity refuse to open the new worktree.
    & robocopy $srcDir $dstDir /E /MT:16 /NFL /NDL /NJH /NP /R:1 /W:1 /XF UnityLockfile | Out-Null
    # robocopy exit codes 0-7 are success; 8+ are real failures
    if ($LASTEXITCODE -ge 8) {
        Write-Warn2 "robocopy reported errors for $dir (exit $LASTEXITCODE)"
    }
}

Write-Ok "Worktree ready: $Dest"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor DarkGray
Write-Host "  cd '$Dest'" -ForegroundColor DarkGray
Write-Host "  # When done:  git -C '$Source' worktree remove '$Dest'" -ForegroundColor DarkGray
