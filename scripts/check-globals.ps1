param(
    [switch]$Update,
    [string]$SourceDir = (Join-Path ([IO.Path]::GetTempPath()) "acm-wow-ui-source")
)

$ErrorActionPreference = "Stop"

# Catches WoW API typos and removed names, which Selene cannot see: it only knows plain Lua, and
# the addon reaches the game through _G.Name and C_Namespace.Member.
#
# Default mode reads only this repo and fails on any such name that is on neither list:
#   scripts/data/wow-globals.txt         generated: names found in Blizzard's UI source
#   scripts/data/wow-globals-manual.txt  by hand: our own globals, other addons, engine-only names
#
# -Update fetches the live, forever, classic and classic_era branches of Gethe/wow-ui-source into
# -SourceDir (lua and xml only) and rewrites wow-globals.txt with every name in use that the source
# confirms. A name it can't confirm stays failing: fix the typo, or add it to the manual list with
# the reason.
#
# A name counts as confirmed when it exists on any of those clients, so this does not prove a name
# exists on all of them; guard client-specific calls as usual. Methods on frames are not checked.

$repo = Split-Path $PSScriptRoot -Parent
$addon = Join-Path $repo "CombatMode"
$dataDir = Join-Path $PSScriptRoot "data"
$confirmedPath = Join-Path $dataDir "wow-globals.txt"
$manualPath = Join-Path $dataDir "wow-globals-manual.txt"
$sourceUrl = "https://github.com/Gethe/wow-ui-source.git"
$branches = "live", "forever", "classic", "classic_era"

function Read-NameList([string]$path) {
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if (Test-Path -LiteralPath $path) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            $name = ($line -replace '#.*$', '').Trim()
            if ($name) { [void]$names.Add($name) }
        }
    }
    return , $names
}

# name -> first "file:line" that uses it
function Get-UsedNames {
    $used = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $globalPattern = [regex]'(?<![\w.:])_G\.([A-Za-z_]\w*)'
    $memberPattern = [regex]'(?<![\w.:])(?:_G\.)?(C_[A-Za-z]\w*\.[A-Za-z_]\w*)'
    foreach ($file in Get-ChildItem -LiteralPath $addon -Recurse -File -Filter *.lua) {
        # Generated text and translations, not code.
        if ($file.Name -eq "ChangelogData.lua" -or $file.DirectoryName -like "*Locales") { continue }
        $rel = $file.FullName.Substring($repo.Length + 1) -replace '\\', '/'
        $number = 0
        foreach ($raw in [IO.File]::ReadLines($file.FullName)) {
            $number++
            $line = $raw -replace '--.*$', ''
            foreach ($pattern in $globalPattern, $memberPattern) {
                foreach ($m in $pattern.Matches($line)) {
                    $name = $m.Groups[1].Value
                    if (-not $used.ContainsKey($name)) { $used[$name] = "${rel}:$number" }
                }
            }
        }
    }
    return , $used
}

function Update-Source([string]$branch) {
    $dir = Join-Path $SourceDir $branch
    if (Test-Path -LiteralPath (Join-Path $dir ".git")) {
        git -C $dir fetch --quiet --depth 1 origin $branch
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed for $branch" }
        git -C $dir reset --quiet --hard FETCH_HEAD
    }
    else {
        New-Item -ItemType Directory -Force -Path $SourceDir | Out-Null
        git clone --quiet --depth 1 --filter=blob:none --sparse --branch $branch $sourceUrl $dir
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $branch" }
        git -C $dir sparse-checkout set --no-cone '*.lua' '*.xml'
    }
    if ($LASTEXITCODE -ne 0) { throw "could not update the $branch checkout" }
    return $dir
}

function Get-KnownNames {
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
public static class AcmTokenScan {
    static bool Start(char c) { return char.IsLetter(c) || c == '_'; }
    static bool Part(char c) { return char.IsLetterOrDigit(c) || c == '_'; }
    // Adds every identifier, plus "C_Namespace.Member" for each namespaced call.
    public static void Add(string text, HashSet<string> set) {
        int i = 0, n = text.Length;
        while (i < n) {
            if (!Start(text[i])) { i++; continue; }
            int s = i;
            while (i < n && Part(text[i])) i++;
            string token = text.Substring(s, i - s);
            set.Add(token);
            if (token.StartsWith("C_") && i + 1 < n && text[i] == '.' && Start(text[i + 1])) {
                int m = i + 1, e = m;
                while (e < n && Part(text[e])) e++;
                set.Add(token + "." + text.Substring(m, e - m));
            }
        }
    }
}
'@
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $namePattern = [regex]'\bName\s*=\s*"(\w+)"'
    $namespacePattern = [regex]'\bNamespace\s*=\s*"(C_\w+)"'
    foreach ($branch in $branches) {
        Write-Host "[INFO] Reading Blizzard's UI source ($branch)..."
        $dir = Update-Source $branch
        $files = Get-ChildItem -LiteralPath $dir -Recurse -File |
            Where-Object { $_.Extension -in ".lua", ".xml" -and $_.FullName -notmatch '[\\/]\.git[\\/]' }
        foreach ($file in $files) {
            $text = [IO.File]::ReadAllText($file.FullName)
            [AcmTokenScan]::Add($text, $known)
            # The generated API docs list engine functions no Blizzard Lua happens to call.
            if ($file.FullName -match 'APIDocumentation') {
                $namespace = $namespacePattern.Match($text).Groups[1].Value
                foreach ($m in $namePattern.Matches($text)) {
                    $name = $m.Groups[1].Value
                    [void]$known.Add($name)
                    if ($namespace) { [void]$known.Add("$namespace.$name") }
                }
            }
        }
    }
    return , $known
}

Write-Host "== CombatMode check-globals =="

$used = Get-UsedNames
$manual = Read-NameList $manualPath

if ($Update) {
    $known = Get-KnownNames
    $confirmed = @($used.Keys | Where-Object { $known.Contains($_) -and -not $manual.Contains($_) } |
            Sort-Object { $_ } -CaseSensitive)
    $header = @(
        "# Generated by scripts/check-globals.ps1 -Update; do not edit by hand.",
        "# WoW globals and C_ API members this addon uses that exist in Blizzard's UI source."
    )
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    [IO.File]::WriteAllText($confirmedPath, ((@($header) + $confirmed) -join "`n") + "`n")
    Write-Host "[INFO] Wrote $($confirmed.Count) confirmed names."
}

$confirmedNames = Read-NameList $confirmedPath
$unknown = @($used.Keys | Where-Object { -not $confirmedNames.Contains($_) -and -not $manual.Contains($_) } | Sort-Object)

if ($unknown.Count -gt 0) {
    foreach ($name in $unknown) { Write-Host "[FAIL] $name ($($used[$name])) is not a known WoW name" }
    Write-Host "$($unknown.Count) unknown name(s). Fix the typo, or if the name is real run:"
    Write-Host "  pwsh ./scripts/check-globals.ps1 -Update"
    Write-Host "A name that isn't Blizzard's goes in scripts/data/wow-globals-manual.txt with the reason."
    exit 1
}

Write-Host "[PASS] $($used.Count) WoW names are known."
exit 0
