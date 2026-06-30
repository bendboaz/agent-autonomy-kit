# agent-config.ps1 - per-repo config LOADER for the agent-ops engine.
# (Generalized from the original hardcoded-constants file.)
#
# Dot-sourced by common.ps1. Resolves the consuming repo, reads its
# .agent-ops/config.json merged over .agent-ops/config.local.json (machine
# paths, gitignored), validates, and sets the script-scope variables the rest
# of common.ps1 consumes:
#   $RepoRoot $RepoSlug $AppId $InstallationId $BranchPrefix $DefaultCap
#   $Labels $RoleHeaders $WorktreeBase $VenvScripts $GH $StateDir $AgentOpsPath
#
# Repo resolution order:
#   1. $env:AGENT_OPS_REPO  (the run-*.ps1 wrappers set this)
#   2. current directory, walking up, for a folder with .agent-ops/config.json
#   3. otherwise throw (real runs need a config; tests set AGENT_OPS_REPO)
#
# Never hardcode repo identity or machine paths here — that is the whole point.

function Get-AgentProp($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value } else { return $null }
}

function Find-AgentOpsRepoRoot([string]$start) {
    $dir = $start
    for ($i = 0; $i -lt 12 -and $dir; $i++) {
        if (Test-Path (Join-Path (Join-Path $dir '.agent-ops') 'config.json')) { return $dir }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

# --- resolve repo root ---
if ($env:AGENT_OPS_REPO -and (Test-Path $env:AGENT_OPS_REPO)) {
    $RepoRoot = (Resolve-Path $env:AGENT_OPS_REPO).Path
} else {
    $RepoRoot = Find-AgentOpsRepoRoot ((Get-Location).Path)
}
if (-not $RepoRoot) {
    throw "agent-ops: no .agent-ops/config.json found. Set `$env:AGENT_OPS_REPO to the repo root, or run from inside the repo."
}

$configPath = Join-Path (Join-Path $RepoRoot '.agent-ops') 'config.json'
$localPath  = Join-Path (Join-Path $RepoRoot '.agent-ops') 'config.local.json'
if (-not (Test-Path $configPath)) {
    throw "agent-ops: missing config at $configPath (copy templates/config.example.json and fill it in)."
}
# -Encoding UTF8 so emoji role headers survive on Windows PowerShell 5.1.
$cfg   = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$local = if (Test-Path $localPath) { Get-Content $localPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

# config.local.json (machine) wins over config.json for the same key.
function Get-AgentSetting([string]$name) {
    $v = Get-AgentProp $local $name
    if ($null -ne $v) { return $v }
    return Get-AgentProp $cfg $name
}
function Assert-AgentKey($value, [string]$name) {
    if ($null -eq $value -or "$value" -eq '') {
        throw "agent-ops: config.json missing required '$name' ($configPath)."
    }
}

# --- identity / behavior (committed config.json) ---
$RepoSlug       = [string](Get-AgentProp $cfg 'repoSlug');       Assert-AgentKey $RepoSlug 'repoSlug'
$AppId          = [string](Get-AgentProp $cfg 'appId');          Assert-AgentKey $AppId 'appId'
$InstallationId = [string](Get-AgentProp $cfg 'installationId'); Assert-AgentKey $InstallationId 'installationId'
$BranchPrefix   = [string](Get-AgentProp $cfg 'branchPrefix');   Assert-AgentKey $BranchPrefix 'branchPrefix'
$capRaw         = Get-AgentProp $cfg 'defaultCap';               Assert-AgentKey $capRaw 'defaultCap'
$DefaultCap     = [int]$capRaw
$AgentOpsPath   = [string](Get-AgentProp $cfg 'agentOpsPath'); if (-not $AgentOpsPath) { $AgentOpsPath = '.agent-ops' }

# --- labels (explicit build → cross-version hashtable + key validation) ---
$labelsObj = Get-AgentProp $cfg 'labels'
if (-not $labelsObj) { throw "agent-ops: config.json missing 'labels' ($configPath)." }
$labelMap = [ordered]@{ Ready='ready'; InProgress='inProgress'; Blocked='blocked'; NeedsAttention='needsAttention'; HelpWanted='helpWanted'; Meta='meta' }
$Labels = @{}
foreach ($k in $labelMap.Keys) {
    $v = Get-AgentProp $labelsObj $labelMap[$k]
    Assert-AgentKey $v "labels.$($labelMap[$k])"
    $Labels[$k] = [string]$v
}

# --- role headers ---
$rhObj = Get-AgentProp $cfg 'roleHeaders'
if (-not $rhObj) { throw "agent-ops: config.json missing 'roleHeaders' ($configPath)." }
$rhMap = [ordered]@{ Implementing='implementing'; Reviewing='reviewing'; Human='human' }
$RoleHeaders = @{}
foreach ($k in $rhMap.Keys) {
    $v = Get-AgentProp $rhObj $rhMap[$k]
    Assert-AgentKey $v "roleHeaders.$($rhMap[$k])"
    $RoleHeaders[$k] = [string]$v
}

# --- state dir (committed config or default; relative to repo root) ---
$stateRel = [string](Get-AgentProp $cfg 'stateDir'); if (-not $stateRel) { $stateRel = '.claude/agent-state' }
$StateDir = if ([IO.Path]::IsPathRooted($stateRel)) { $stateRel } else { Join-Path $RepoRoot $stateRel }

# --- machine paths (gitignored config.local.json; absent in CI/tests is fine) ---
$WorktreeBase = [string](Get-AgentSetting 'worktreeBase')
$venvRel = [string](Get-AgentSetting 'venvScripts')
if ($venvRel) {
    $VenvScripts = if ([IO.Path]::IsPathRooted($venvRel)) { $venvRel } else { Join-Path $RepoRoot $venvRel }
} else {
    $VenvScripts = $null
}

# --- gh path: config.local override → known Windows location → PATH fallback ---
$ghCfg = [string](Get-AgentSetting 'ghPath')
if ($ghCfg) { $GH = $ghCfg } else { $GH = 'C:\Program Files\GitHub CLI\gh.exe'; if (-not (Test-Path $GH)) { $GH = 'gh' } }
