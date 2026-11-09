param(
    [switch]$SkipIfMissing
)

$ErrorActionPreference = "Stop"

# Compiles and loads every addon file against a stubbed client, once per client in CombatMode.toc,
# then runs the unit specs in tests/. Needs LuaJIT (winget install DEVCOM.LuaJIT). A pass means every
# file loads; what the addon does once the game fires events still needs an in-game check.

$repo = Split-Path $PSScriptRoot -Parent

$lua = (Get-Command luajit -ErrorAction SilentlyContinue).Source
if (-not $lua -and $env:LOCALAPPDATA) {
    # A shell opened before the install has a stale PATH.
    $installed = Join-Path $env:LOCALAPPDATA "Programs/LuaJIT/bin/luajit.exe"
    if (Test-Path -LiteralPath $installed) { $lua = $installed }
}
if (-not $lua) {
    if ($SkipIfMissing) {
        Write-Host "[WARN] LuaJIT not found; skipped the load test (winget install DEVCOM.LuaJIT)."
        exit 0
    }
    Write-Host "[FAIL] LuaJIT not found (winget install DEVCOM.LuaJIT)."
    exit 1
}

Write-Host "== CombatMode load test =="
& $lua (Join-Path $repo "tests/run.lua") ($repo -replace '\\', '/')
exit $LASTEXITCODE
