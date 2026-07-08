# block-sensitive-files.ps1
# Blocks Claude from reading, editing, or writing sensitive credential files.
# Fires as a PreToolUse hook on Read | Edit | Write | Grep | Bash | PowerShell | CMD.
# (Shell tools - Bash, PowerShell, CMD - are matched on tool_input.command.
#  Grep is matched on tool_input.path and tool_input.glob - with output_mode
#  "content" it can dump a secret file into context just like Read.)
#
# Rules:
#   1. Exact filename match  -> always block
#   2. Extension match       -> always block
#   3. Name pattern match    -> block ONLY if extension is not in the safe-extensions list
#      (prevents false positives on files like secret_management.md, password_policy.txt, etc.)
#   4. Bash command check    -> block if command string references a sensitive path
#
# Files inside the .claude directory are exempt (Claude needs to manage its own config).

$json = $input | ConvertFrom-Json

$toolName = $json.tool_name
$filePath = ""

if ($toolName -in @("Bash", "PowerShell", "CMD")) {
    $filePath = $json.tool_input.command
} else {
    $filePath = $json.tool_input.file_path
    if (-not $filePath) { $filePath = $json.tool_input.path }
}

# The real path/command, captured before any glob fallback below - the .claude
# exemption must only ever be decided from this, never from a glob pattern (a
# glob like "x/.claude/*.credentials.json" is not itself a location under .claude).
$exemptCandidate = $filePath

# Grep can select target files via its glob filter even when its path is a
# directory (or omitted) - capture the glob for a dedicated check below.
$globPattern = ""
if ($toolName -eq "Grep") {
    $globPattern = [string]$json.tool_input.glob
    if (-not $filePath) { $filePath = $globPattern }
}

if (-not $filePath) { exit 0 }

# .credentials.json (the OAuth token store) is always blocked - even under
# .claude, which is otherwise exempt below for config self-management. Also
# match a Grep glob directly, since a glob has no reliable "start of path"
# anchor for the regex below.
if (($filePath -replace '\\', '/').ToLower() -match '(^|/|\s)\.credentials\.json' -or
    ($globPattern -and $globPattern.ToLower().Contains('.credentials.json'))) {
    @{
        hookSpecificOutput = @{
            hookEventName            = "PreToolUse"
            permissionDecision       = "deny"
            permissionDecisionReason = "SENSITIVE FILE BLOCKED (.credentials.json is the OAuth token store). Claude is never permitted to read or write it."
        }
    } | ConvertTo-Json -Compress
    exit 0
}

# Exempt the .claude config directory so Claude can manage hooks/settings.
# Decided from the real path/command only, never the glob fallback above.
if ($exemptCandidate -and ($exemptCandidate -replace '\\', '/' -match '/\.claude/')) { exit 0 }

$fileName = Split-Path $filePath -Leaf -ErrorAction SilentlyContinue
if (-not $fileName) { $fileName = $filePath }
$lowerName = $fileName.ToLower()
$ext = [System.IO.Path]::GetExtension($lowerName)
if ($ext -eq "" -and $lowerName.StartsWith(".")) { $ext = $lowerName }

# --- Blocklists ---

$blockedExactNames = @(
    '.env',
    'credentials', 'credentials.json',
    'service-account.json', 'google-credentials.json', 'client_secret.json',
    'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa',
    '.netrc', '.pgpass', 'htpasswd', '.htpasswd'
)

$blockedExtensions = @(
    '.pem', '.key', '.p12', '.pfx', '.keystore', '.jks', '.pkcs12', '.cer', '.crt',
    '.credential', '.credentials', '.token', '.tokens', '.secret', '.secrets',
    '.password', '.passwords'
)

# Pattern matching is skipped for these extensions (docs, code, config)
$safeExtensions = @(
    '.md', '.txt', '.rst', '.adoc',
    '.example', '.sample', '.template', '.tpl',   # template files never contain real secrets
    '.ps1', '.psm1', '.psd1', '.sh', '.bash', '.zsh', '.fish',
    '.py', '.rb', '.php', '.java', '.go', '.rs', '.c', '.cpp', '.h', '.cs',
    '.js', '.ts', '.jsx', '.tsx', '.mjs', '.cjs',
    '.html', '.htm', '.css', '.scss', '.less', '.svg',
    '.yaml', '.yml', '.toml', '.ini', '.cfg', '.conf', '.xml',
    '.json', '.jsonc', '.json5',
    '.lock', '.log'
)

# Glob-style patterns checked only against non-safe extensions
$blockedPatterns = @(
    '*secret*',
    '*password*',
    '*passwd*',
    '*credential*',
    '*.env.*',
    '.env.*'
)

# Shell: non-env sensitive path substrings (keys/certs). `.env` files are handled
# separately by regex below so template variants (.env.example/.sample/.template) are
# allowed - they are the documented-safe pattern and never contain real secrets.
$bashDangerSubstrings = @(
    'id_rsa', 'id_ed25519', 'id_ecdsa',
    '.pem', '.p12', '.pfx'
)
# Suffixes on a .env-style filename that mark it a non-secret TEMPLATE (allow these).
$envSafeSuffixes = @('example', 'sample', 'template', 'tpl', 'dist')

# --- Matching logic ---

$isBlocked = $false
$matchedReason = ""

if ($toolName -in @("Bash", "PowerShell", "CMD")) {
    # (a) .env references: block real ones (.env, .env.local, .env.production);
    #     allow template variants (.env.example / .sample / .template / .tpl / .dist).
    foreach ($m in [regex]::Matches($filePath, '(?i)(?<![\w.])\.env(\.[a-z0-9_]+)*')) {
        $suffix = ($m.Value.ToLower() -split '\.')[-1]
        if ($envSafeSuffixes -contains $suffix) { continue }
        $isBlocked = $true
        $matchedReason = "command references a sensitive env file: '$($m.Value)'"
        break
    }
    # (b) other sensitive path substrings (keys / certs)
    if (-not $isBlocked) {
        foreach ($sub in $bashDangerSubstrings) {
            if ($filePath -like "*$sub*") {
                $isBlocked = $true
                $matchedReason = "command references a sensitive path: '$sub'"
                break
            }
        }
    }
} else {
    # 1. Exact name
    foreach ($name in $blockedExactNames) {
        if ($lowerName -eq $name) {
            $isBlocked = $true
            $matchedReason = "exact filename '$fileName'"
            break
        }
    }

    # 2. Extension
    if (-not $isBlocked) {
        if ($blockedExtensions -contains $ext) {
            $isBlocked = $true
            $matchedReason = "extension '$ext'"
        }
    }

    # 3. Pattern (skipped for safe extensions)
    if (-not $isBlocked -and ($safeExtensions -notcontains $ext)) {
        foreach ($pattern in $blockedPatterns) {
            if ($lowerName -like $pattern) {
                $isBlocked = $true
                $matchedReason = "pattern '$pattern' (non-doc file)"
                break
            }
        }
    }

        # 4. Grep glob filter (e.g. glob "*.env*" or "*.pem" over a directory path)
    if (-not $isBlocked -and $globPattern) {
        $g = $globPattern.ToLower()
        foreach ($name in $blockedExactNames) {
            if ($g -like "*$name*") {
                $isBlocked = $true
                $matchedReason = "Grep glob targets '$name'"
                break
            }
        }
        if (-not $isBlocked) {
            foreach ($e in $blockedExtensions) {
                if ($g -like "*$e*") {
                    $isBlocked = $true
                    $matchedReason = "Grep glob targets '$e' files"
                    break
                }
            }
        }
        if (-not $isBlocked) {
            foreach ($pattern in $blockedPatterns) {
                $bare = $pattern.Trim('*')
                if ($bare -and $g -like "*$bare*") {
                    $isBlocked = $true
                    $matchedReason = "Grep glob targets pattern '$pattern'"
                    break
                }
            }
        }
    }
}

if ($isBlocked) {
    @{
        hookSpecificOutput = @{
            hookEventName            = "PreToolUse"
            permissionDecision       = "deny"
            permissionDecisionReason = "SENSITIVE FILE BLOCKED ($matchedReason). Edit this file manually - Claude is not permitted to read or write it."
        }
    } | ConvertTo-Json -Compress
}

exit 0
