# Runs the pre-commit gate (StyLua, Selene, check-repo, check-globals, load test) on changed + new
# Lua files, or just the last three when something else changed.
# Run it twice after edits: the first pass reformats.
param()

$ErrorActionPreference = "Stop"

function Get-ChangedFiles {
    $staged = git diff --name-only --cached 2>$null
    $unstaged = git diff --name-only 2>$null
    $untracked = git ls-files --others --exclude-standard 2>$null

    $all = @()
    if ($staged) { $all += $staged }
    if ($unstaged) { $all += $unstaged }
    if ($untracked) { $all += $untracked }

    return $all | Sort-Object -Unique
}

Write-Host "== CombatMode lint-changed =="

$changed = Get-ChangedFiles

if (-not $changed -or $changed.Count -eq 0) {
    Write-Host "[PASS] No changed files detected."
    exit 0
}

$luaTargets = $changed | Where-Object {
    $_ -match '^(CombatMode|tests)/.+\.lua$'
}

if (-not $luaTargets -or $luaTargets.Count -eq 0) {
    # The changelog, TOC, Embeds.xml, LICENSE and the name lists matter without any Lua change too.
    Write-Host "[INFO] No changed Lua files; running check-repo, check-globals and the load test."
    pwsh -NoProfile -File (Join-Path $PSScriptRoot "check-repo.ps1")
    $exitCode = $LASTEXITCODE
    pwsh -NoProfile -File (Join-Path $PSScriptRoot "check-globals.ps1")
    if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
    pwsh -NoProfile -File (Join-Path $PSScriptRoot "test.ps1") -SkipIfMissing
    if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
    exit $exitCode
}

Write-Host "[INFO] Running pre-commit on changed Lua files:"
$luaTargets | ForEach-Object { Write-Host "  - $_" }

pre-commit run --files @luaTargets
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Error "pre-commit failed for changed files."
    exit $exitCode
}

Write-Host "[PASS] pre-commit passed for changed Lua files."
exit 0
