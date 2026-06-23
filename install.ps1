<#
.SYNOPSIS
    install.ps1 — One-command setup for wiki-mcp (Windows)
.DESCRIPTION
    Usage: powershell -ExecutionPolicy Bypass -File install.ps1

    What it does:
      1. Installs Git and Node.js 22+
      2. Installs opencode
      3. Clones Wiki-NITC/wiki-mcp into the current directory
      4. Creates config.json with wiki.fosscell.org defaults
      5. Checks whether you have a wiki account and opens signup if not
      6. Prompts for bot credentials (opens browser to BotPasswords page)
      7. Adds a `wiki-mcp` PowerShell function to your profile
      8. Creates desktop & Start Menu shortcuts
      9. Validates the setup
.EXAMPLE
    # Run locally:
    .\install.ps1

    # Remote one-liner:
    powershell -c "iwr -useb https://raw.githubusercontent.com/Wiki-NITC/wiki-mcp/main/scripts/install.ps1 | iex"
#>

#Requires -Version 5.1

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Constants ─────────────────────────────────────────────────────────────
$RepoUrl  = "https://github.com/Wiki-NITC/wiki-mcp.git"
$RepoDir  = "wiki-mcp"
$NodeVer  = "22.12.0"
$NodeUrl  = "https://nodejs.org/dist/v$NodeVer/node-v$NodeVer-x64.msi"
$GitUrl   = "https://github.com/git-for-windows/git/releases/latest/download/Git-2.47.0-64-bit.exe"
$OpencodeDir = "$env:USERPROFILE\.opencode\bin"
$OpencodeExe = "$OpencodeDir\opencode.exe"
$ProfilePath = $PROFILE.CurrentUserAllHosts

# ── Helpers ───────────────────────────────────────────────────────────────

# Heuristic: if we're in a console host with RawUI, assume interactive.
# The pause at the end matters most for double-click launches where the
# window would vanish immediately.  In a terminal (or iex) pressing Enter
# once is harmless.
$IsInteractive = $host.Name -eq "ConsoleHost" -and $null -ne $host.UI.RawUI

function Step($Title) {
    Write-Host "`n==> $Title" -ForegroundColor Cyan
}

function Pass($Msg) {
    Write-Host "  [PASS] $Msg" -ForegroundColor Green
}

function Warn($Msg) {
    Write-Host "  [WARN] $Msg" -ForegroundColor Yellow
}

function Die($Msg) {
    Write-Host "  [FAIL] $Msg" -ForegroundColor Red
    if ($IsInteractive) { Read-Host "`nPress Enter to exit" }
    exit 1
}

function Ensure-Program($Name, $WingetId, $Url, $UrlFileName, $SilentArgs = "/S", $ProbePaths = @()) {
    $existing = Get-Command $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Pass "$Name found at $($existing.Source)"
        return $true
    }
    Write-Host "  $Name not found." -ForegroundColor Yellow

    $installed = $false

    # Try winget first
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget -and $WingetId) {
        Write-Host "  Installing $Name via winget ..." -ForegroundColor Yellow
        & winget install $WingetId --accept-package-agreements --accept-source-agreements | Out-Null
        if ($LASTEXITCODE -eq 0) { $installed = $true }
        else { Warn "winget install failed, trying direct download ..." }
    }

    # Fallback: direct download
    if (-not $installed -and $Url) {
        Write-Host "  Downloading $Name from $Url ..." -ForegroundColor Yellow
        $ext = if ($Url -match '\.msi$') { 'msi' } else { 'exe' }
        $tmp = "$env:TEMP\$UrlFileName"
        try {
            Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
        } catch {
            Die "Failed to download $Name from $Url. Install manually and re-run."
        }
        Write-Host "  Running $Name installer ..." -ForegroundColor Yellow
        if ($ext -eq 'msi') {
            Start-Process msiexec.exe -Wait -ArgumentList "/i `"$tmp`" /qn"
        } else {
            Start-Process $tmp -Wait -ArgumentList $SilentArgs
        }
        Remove-Item $tmp -Force
        $installed = $true
    }

    if (-not $installed) { return $false }

    # Refresh PATH from the registry so newly installed programs are visible
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
    $existing = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $existing -and $ProbePaths) {
        # msiexec sometimes doesn't flush PATH changes back to the registry
        # in time. Probe known install locations as a fallback.
        foreach ($p in $ProbePaths) {
            if (Test-Path "$p\$Name.exe") {
                $env:Path = "$p;$env:Path"
                $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
                if ($userPath -notlike "*$p*") {
                    [Environment]::SetEnvironmentVariable("Path", "$userPath;$p", "User")
                }
                $existing = Get-Command $Name -ErrorAction SilentlyContinue
                if ($existing) { break }
            }
        }
    }
    if (-not $existing) {
        Die "$Name was installed but not found in PATH. Restart your terminal and re-run."
    }
    Pass "$Name installed ($($existing.Source))"
    return $true
}

# ── 0. Location guard ────────────────────────────────────────────────────
Step "0/10  Checking install location"

$tempEsc   = [regex]::Escape($env:TEMP.TrimEnd('\'))
$windirEsc = [regex]::Escape($env:WINDIR.TrimEnd('\'))
$BadPaths = @(
    "^[A-Z]:\\$",              # C:\, D:\, etc.
    "^[A-Z]:\\Windows\\",
    "^[A-Z]:\\Program Files",
    "^[A-Z]:\\Program Files \(x86\)",
    "^$tempEsc\\",
    "^$windirEsc\\"
)

$CurrentDir = (Get-Location).Path
$IsBadPath = $false
foreach ($pattern in $BadPaths) {
    if ($CurrentDir -match $pattern) {
        $IsBadPath = $true
        break
    }
}

if ($IsBadPath) {
    $TargetDir = "$env:USERPROFILE\wiki-mcp"
    Warn "Current directory '$CurrentDir' is not suitable for cloning."
    Write-Host "  Relocating to '$TargetDir' ..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    Set-Location $TargetDir
    Pass "Working directory changed to '$TargetDir'"
} else {
    Pass "Location '$CurrentDir' is suitable"
}

# ── 1. Check/Install Git ─────────────────────────────────────────────────
Step "1/10  Git"
if (-not (Ensure-Program "git" "Git.Git" $GitUrl "git-install.exe" "/VERYSILENT /NORESTART")) {
    Die "Git could not be installed automatically. Install it from https://git-scm.com and re-run."
}

# ── 1b. Ensure bash (bundled with Git for Windows) ───────────────────────
$bashProbePaths = @(
    "${env:ProgramFiles}\Git\bin",
    "${env:ProgramFiles(x86)}\Git\bin"
)
if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    foreach ($p in $bashProbePaths) {
        if (Test-Path "$p\bash.exe") {
            $env:Path = "$p;$env:Path"
            break
        }
    }
}
$bashCheck = Get-Command bash -ErrorAction SilentlyContinue
if ($bashCheck) {
    $ver = & $bashCheck.Source --version 2>$null
    Pass "bash found: $($ver.Split("`n")[0])"
} else {
    Warn "bash not found — MCP command in opencode.json may fail"
}

# ── 2. Check/Install Node.js ──────────────────────────────────────────────
Step "2/10  Node.js"

$node = Get-Command node -ErrorAction SilentlyContinue
$nodeOk = $false
if ($node) {
    $ver = & node -p "process.versions.node"
    $major = [int]($ver -split '\.')[0]
    if ($major -ge 22) {
        $nodeOk = $true
        Pass "Node.js found: v$ver"
    } else {
        Warn "Node.js v$ver found, need v$NodeVer or newer"
    }
}

if (-not $nodeOk) {
    $nodeProbePaths = @("$env:ProgramFiles\nodejs", "${env:ProgramFiles(x86)}\nodejs")
    Ensure-Program "node" "OpenJS.NodeJS.LTS" $NodeUrl "node-install.msi" -ProbePaths $nodeProbePaths
    $ver = & node -p "process.versions.node"
    $major = [int]($ver -split '\.')[0]
    if ($major -lt 22) {
        Die "Installed Node.js v$ver is still below v22. Install v$NodeVer+ manually from https://nodejs.org"
    }
    Pass "Node.js installed: v$ver"
}

# ── 3. Clone / update the repo ──────────────────────────────────────────
Step "3/10  wiki-mcp repo"

if (Test-Path "$RepoDir\.git") {
    Push-Location $RepoDir
    Write-Host "  Repo exists, pulling latest ..." -ForegroundColor Yellow
    & git pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        Warn "git pull failed. Continuing with local copy."
    } else {
        Pass "Up-to-date"
    }
} elseif (Test-Path $RepoDir) {
    # Stray directory – back it up and re-clone
    $backup = "$RepoDir.backup-$(Get-Date -Format yyyyMMddHHmmss)"
    Warn "Directory '$RepoDir' exists but is not a git repo. Backing up to '$backup'"
    Rename-Item $RepoDir $backup
    & git clone $RepoUrl
    if ($LASTEXITCODE -ne 0) { Die "Failed to clone repo." }
    Push-Location $RepoDir
    Pass "Cloned into '$RepoDir'"
} else {
    & git clone $RepoUrl
    if ($LASTEXITCODE -ne 0) { Die "Failed to clone repo." }
    Push-Location $RepoDir
    Pass "Cloned into '$RepoDir'"
}

# ── 4. Install opencode ──────────────────────────────────────────────────
Step "4/10  opencode"

if (Test-Path $OpencodeExe) {
    $ver = & $OpencodeExe --version 2>$null
    Pass "opencode found: $ver"
} else {
    Write-Host "  opencode not found. Downloading for Windows-x64 ..." -ForegroundColor Yellow

    # Resolve latest version
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/anomalyco/opencode/releases/latest" -UseBasicParsing
        $version = $release.tag_name -replace '^v'
    } catch {
        Die "Failed to fetch opencode version info from GitHub."
    }
    Write-Host "  Latest version: v$version" -ForegroundColor Yellow

    $zipUrl = "https://github.com/anomalyco/opencode/releases/download/v$version/opencode-windows-x64.zip"
    $zipTmp = "$env:TEMP\opencode-windows-x64.zip"

    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipTmp -UseBasicParsing
    } catch {
        Die "Failed to download opencode from $zipUrl"
    }

    # Create target directory and extract
    New-Item -ItemType Directory -Force -Path $OpencodeDir | Out-Null
    try {
        Expand-Archive -Path $zipTmp -DestinationPath $OpencodeDir -Force
    } catch {
        Die "Failed to extract opencode archive."
    }
    Remove-Item $zipTmp -Force

    if (-not (Test-Path $OpencodeExe)) {
        Die "opencode.exe not found after extraction. Expected at $OpencodeExe"
    }

    # Add to User PATH persistently
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -notlike "*$OpencodeDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$currentPath;$OpencodeDir", "User")
        $env:Path += ";$OpencodeDir"
        Pass "opencode added to User PATH"
    }
    $ver = & $OpencodeExe --version 2>$null
    Pass "opencode installed: v$ver"
}

# ── 5. Create config.json ────────────────────────────────────────────────
Step "5/10  Config"

if (-not (Test-Path "config.json")) {
    $config = @{
        defaultWiki = "wiki.fosscell.org"
        wikis = @{
            "wiki.fosscell.org" = @{
                sitename    = "WIKI FOSSCELL NITC"
                server      = "https://wiki.fosscell.org"
                articlepath = ""
                scriptpath  = ""
                username    = $null
                password    = $null
                private     = $false
            }
        }
    }
    $config | ConvertTo-Json -Depth 3 | Out-File "config.json" -Encoding UTF8
    Pass "config.json created (read-only mode)"
} else {
    Pass "config.json already exists"
}

# ── 6. Wiki account check ──────────────────────────────────────────────
Step "6/10  Wiki account"

Write-Host "  You need a wiki account on wiki.fosscell.org to edit pages."
Write-Host "  (It's free - anyone with @nitc.ac.in email can sign up.)"
Write-Host ""
$answer = Read-Host "  Do you already have a wiki account? (Y/n)"
if ($answer -match '^[Nn]') {
    Write-Host "  Opening registration page ..." -ForegroundColor Yellow
    try { Start-Process "https://wiki.fosscell.org/index.php?title=Special:CreateAccount" }
    catch { [System.Diagnostics.Process]::Start("https://wiki.fosscell.org/index.php?title=Special:CreateAccount") | Out-Null }
    Read-Host "  Press Enter after you have created your account"
} else {
    Write-Host "  Tip: Visit https://wiki.fosscell.org/index.php?title=Special:CreateAccount if you need an account later." -ForegroundColor Yellow
}
Pass "Wiki account check done"

# ── 7. Bot-password setup (optional) ─────────────────────────────────────
Step "7/10  Wiki credentials (optional)"

$config = Get-Content "config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$wiki = $config.wikis."wiki.fosscell.org"

if ($wiki.username -and $wiki.password) {
    Pass "Credentials already configured for user '$($wiki.username)'"
} else {
    Write-Host "  No wiki credentials configured yet." -ForegroundColor Yellow
    Write-Host "  Without them you can read the wiki but cannot edit." -ForegroundColor Yellow
    $answer = Read-Host "  Set up a bot password now? (y/N)"
    if ($answer -match '^[Yy]') {
        Write-Host ""
        Write-Host "  1. Go to:  https://wiki.fosscell.org/Special:BotPasswords" -ForegroundColor Cyan
        Write-Host "  2. Log in with your NITC wiki account" -ForegroundColor Cyan
        Write-Host "  3. Create a bot password with minimum scopes" -ForegroundColor Cyan
        Write-Host "  4. Enter the bot username and password below" -ForegroundColor Cyan
        Write-Host "     (Bot username looks like 'YourName@bot-name')" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Opening BotPasswords page ..." -ForegroundColor Yellow
        try { Start-Process "https://wiki.fosscell.org/Special:BotPasswords" }
        catch { [System.Diagnostics.Process]::Start("https://wiki.fosscell.org/Special:BotPasswords") | Out-Null }

        $botUser = Read-Host "  Bot username (e.g. MyName@my-bot)"
        $botPass = Read-Host "  Bot password" -AsSecureString
        $botPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($botPass))

        # Test the credentials against the MediaWiki API (shared session)
        Write-Host "  Verifying credentials ..." -ForegroundColor Yellow
        $loginToken = Invoke-RestMethod -Uri "https://wiki.fosscell.org/api.php?action=query&meta=tokens&type=login&format=json" -SessionVariable ws -UseBasicParsing
        $token = $loginToken.query.tokens.logintoken

        $loginBody = @{
            action    = "login"
            lgname    = $botUser
            lgpassword = $botPassPlain
            lgtoken   = $token
            format    = "json"
        }
        try {
            $loginResult = Invoke-RestMethod -Uri "https://wiki.fosscell.org/api.php" -Method Post -Body $loginBody -WebSession $ws -UseBasicParsing
            if ($loginResult.login.result -eq "Success") {
                Pass "Credentials verified! Logged in as $($loginResult.login.lgusername)"

                # Write credentials into the parsed JSON object, then re-serialize
                $config = Get-Content "config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
                $config.wikis."wiki.fosscell.org".username = $botUser
                $config.wikis."wiki.fosscell.org".password = $botPassPlain
                $config | ConvertTo-Json -Depth 5 | Out-File "config.json" -Encoding UTF8
                Pass "Credentials saved to config.json"
            } else {
                Warn "Login failed: $($loginResult.login.result). Credentials not saved."
                Warn "You can manually add them to config.json later."
            }
        } catch {
            Warn "Could not reach the wiki API. Credentials not saved."
            Warn "You can manually add them to config.json later."
        }
    }
}

# ── 8. PowerShell profile alias ──────────────────────────────────────────
Step "8/10  PowerShell alias"

$aliasExists = $false
if (Test-Path $ProfilePath) {
    $profileContent = Get-Content $ProfilePath -Raw -ErrorAction SilentlyContinue
    if ($profileContent -and $profileContent -match "wiki-mcp") {
        $aliasExists = $true
        Pass "Alias 'wiki-mcp' already exists in PowerShell profile"
    }
}

if (-not $aliasExists) {
    Write-Host "  Adding 'wiki-mcp' alias to PowerShell profile ..." -ForegroundColor Yellow
    # Ensure the profile directory exists (OneDrive paths may not be created yet)
    $profileDir = Split-Path $ProfilePath -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    }
    $fullPath = (Get-Location).Path
    $aliasLine = "`n# NITC Wiki MCP`nfunction wiki-mcp { opencode --project `"$fullPath`" }"
    Add-Content -Path $ProfilePath -Value $aliasLine -Encoding UTF8
    Pass "Alias 'wiki-mcp' added to $ProfilePath"
    Write-Host "  (Restart PowerShell or '. $ProfilePath' to use it)" -ForegroundColor Yellow
}

# ── 9. Desktop & Start Menu shortcuts ───────────────────────────────────
Step "9/10  Shortcuts"

$desktop = [Environment]::GetFolderPath("Desktop")
$startMenu = [Environment]::GetFolderPath("Programs")
$projectPath = (Get-Location).Path
$shortcutsCreated = 0

$wshell = $null
try {
    $wshell = New-Object -ComObject WScript.Shell
} catch {
    Warn "Cannot create shortcuts (WScript.Shell COM not available)"
}

if ($wshell) {
    # Desktop shortcut
    $desktopLnk = "$desktop\NITC Wiki MCP.lnk"
    if (-not (Test-Path $desktopLnk)) {
        Write-Host "  Creating desktop shortcut ..." -ForegroundColor Yellow
        try {
            $shortcut = $wshell.CreateShortcut($desktopLnk)
            $shortcut.TargetPath = $OpencodeExe
            $shortcut.Arguments = "--project `"$projectPath`""
            $shortcut.WorkingDirectory = $projectPath
            $shortcut.Description = "NITC Wiki MCP - opencode terminal"
            $shortcut.Save()
            Pass "Desktop shortcut created"
            $shortcutsCreated++
        } catch {
            Warn "Failed to create desktop shortcut: $_"
        }
    } else {
        Pass "Desktop shortcut already exists"
    }

    # Start Menu shortcut
    $startMenuLnk = "$startMenu\NITC Wiki MCP.lnk"
    if (-not (Test-Path $startMenuLnk)) {
        Write-Host "  Adding Start Menu shortcut ..." -ForegroundColor Yellow
        try {
            $shortcut = $wshell.CreateShortcut($startMenuLnk)
            $shortcut.TargetPath = $OpencodeExe
            $shortcut.Arguments = "--project `"$projectPath`""
            $shortcut.WorkingDirectory = $projectPath
            $shortcut.Description = "NITC Wiki MCP - opencode terminal"
            $shortcut.Save()
            Pass "Start Menu shortcut created"
            $shortcutsCreated++
        } catch {
            Warn "Failed to create Start Menu shortcut: $_"
        }
    } else {
        Pass "Start Menu shortcut already exists"
    }
}

if ($shortcutsCreated -eq 0 -and -not $wshell) {
    Write-Host "  No shortcuts created." -ForegroundColor Yellow
}

# ── 10. Validate config ────────────────────────────────────────────────────
Step "10/10  Validation"

$valErr = 0
$configPath = "config.json"

# 1. File exists and is valid JSON
if (-not (Test-Path $configPath)) {
    Warn "config.json not found"
    $valErr++
} else {
    Pass "Config file exists: $configPath"
    try {
        $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Pass "Valid JSON"
    } catch {
        Warn "Invalid JSON: $($_.Exception.Message)"
        $valErr++
        $cfg = $null
    }
}

if ($cfg) {
    # 2. Top-level fields
    if ([string]::IsNullOrEmpty($cfg.defaultWiki)) {
        Warn "Missing 'defaultWiki' field"
        $valErr++
    } else {
        Pass "defaultWiki: $($cfg.defaultWiki)"
    }

    $wikiCount = @($cfg.wikis.PSObject.Properties).Count
    if ($wikiCount -eq 0) {
        Warn "No wikis configured under 'wikis' key"
        $valErr++
    } else {
        Pass "Found $wikiCount wiki(s) configured"
    }

    # 3. Per-wiki validation + 4. Connectivity check
    foreach ($wikiProp in $cfg.wikis.PSObject.Properties) {
        $wikiKey = $wikiProp.Name
        $wiki    = $wikiProp.Value
        Write-Host "  Wiki: $wikiKey" -ForegroundColor Cyan

        if ([string]::IsNullOrEmpty($wiki.sitename)) {
            Warn "[$wikiKey] Missing sitename"; $valErr++
        } else {
            Pass "[$wikiKey] sitename: $($wiki.sitename)"
        }

        if ([string]::IsNullOrEmpty($wiki.server)) {
            Warn "[$wikiKey] Missing server"; $valErr++
        } else {
            Pass "[$wikiKey] server: $($wiki.server)"
            # 4. Connectivity check
            $apiUrl = "$($wiki.server.TrimEnd('/'))$($wiki.scriptpath.TrimEnd('/'))/api.php"
            try {
                $siteInfo = Invoke-RestMethod -Uri "$apiUrl`?action=query&meta=siteinfo&format=json" -TimeoutSec 5 -UseBasicParsing
                Pass "[$wikiKey] API reachable: $apiUrl"
                Write-Host "    [INFO] Remote sitename: $($siteInfo.query.general.sitename)" -ForegroundColor Cyan
            } catch {
                Warn "[$wikiKey] API not reachable at $apiUrl"
            }
        }

        $hasUser = -not [string]::IsNullOrEmpty($wiki.username)
        $hasPass = -not [string]::IsNullOrEmpty($wiki.password)
        if ($wiki.private -eq $true) {
            if (-not ($hasUser -and $hasPass) -and [string]::IsNullOrEmpty($wiki.token)) {
                Warn "[$wikiKey] Private wiki but no auth configured"
                $valErr++
            } else {
                Pass "[$wikiKey] Auth configured for private wiki"
            }
        }
    }
}

if ($valErr -eq 0) {
    Pass "All validations passed"
} else {
    $plural = if ($valErr -eq 1) { "" } else { "s" }
    Warn "$valErr validation warning$plural — config may need manual review"
}

# ── Done ─────────────────────────────────────────────────────────────────
Pop-Location
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:"
Write-Host "    cd $RepoDir"
Write-Host "    opencode ."
if ($aliasExists -or (Get-Content $ProfilePath -ErrorAction SilentlyContinue) -match "wiki-mcp") {
    Write-Host "    wiki-mcp  (alias)"
}
if ($shortcutsCreated -gt 0) {
    Write-Host ""
    Write-Host "  Shortcuts created:"
    if (Test-Path "$desktop\NITC Wiki MCP.lnk") {
        Write-Host "    Desktop: NITC Wiki MCP"
    }
    if (Test-Path "$startMenu\NITC Wiki MCP.lnk") {
        Write-Host "    Start Menu: NITC Wiki MCP"
    }
}
Write-Host ""
Write-Host "  To edit the wiki later, add a bot password to config.json:"
Write-Host "    https://wiki.fosscell.org/Special:BotPasswords"
Write-Host ""

if ($IsInteractive) {
    Read-Host "Press Enter to exit"
}
