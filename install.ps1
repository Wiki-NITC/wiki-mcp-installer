<#
.SYNOPSIS
    install.ps1 — One-command setup for wiki-mcp (Windows)
.DESCRIPTION
    Usage: powershell -ExecutionPolicy Bypass -File install.ps1

    What it does:
      1. Installs Git and Node.js 22+
      2. Installs opencode
       3. Clones Wiki-NITC/wiki-mcp into the current directory
       3b. Patches opencode.json for Windows MCP compatibility (cmd/npx.cmd)
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

    # Skip bot password (configure manually later):
    .\install.ps1 -SkipBotPassword
#>

#Requires -Version 5.1

param(
    [switch]$NonInteractive,
    [switch]$SkipBotPassword
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Constants ─────────────────────────────────────────────────────────────
$RepoUrl  = "https://github.com/Wiki-NITC/wiki-mcp.git"
$RepoDir  = "wiki-mcp"
$NodeVer  = "22.12.0"
$Arch     = switch ($env:PROCESSOR_ARCHITECTURE) { "ARM64" { "arm64" } default { "x64" } }
$NodeUrl  = "https://nodejs.org/dist/v$NodeVer/node-v$NodeVer-$Arch.msi"
$GitUrl   = "https://github.com/git-for-windows/git/releases/latest/download/Git-2.47.1-64-bit.exe"
function Get-LatestGitUrl {
    $fallback = $GitUrl
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -UseBasicParsing
        $gitArch = if ($Arch -eq "arm64") { "arm64" } else { "64-bit" }
        $asset = $release.assets | Where-Object { $_.name -like "Git-*-$gitArch.exe" } | Select-Object -First 1
        if ($asset -and $asset.browser_download_url) { return $asset.browser_download_url }
    } catch {
        Warn "Could not fetch latest Git version, using fallback"
    }
    return $fallback
}
$OpencodeDir = "$env:USERPROFILE\.opencode\bin"
$OpencodeExe = "$OpencodeDir\opencode.exe"
$ProfilePath = $PROFILE.CurrentUserAllHosts

# ── Helpers ───────────────────────────────────────────────────────────────

# Heuristic: if we're in a console host with RawUI, assume interactive.
# The pause at the end matters most for double-click launches where the
# window would vanish immediately.  In a terminal (or iex) pressing Enter
# once is harmless.
$IsInteractive = -not $NonInteractive -and $host.Name -eq "ConsoleHost" -and $null -ne $host.UI.RawUI -and -not [Console]::IsInputRedirected

function Step($Title) {
    Write-Host "`n--- $Title ---" -ForegroundColor Cyan
}

function Pass($Msg) {
    Write-Host "  [PASS] $Msg" -ForegroundColor Green
}

function Warn($Msg) {
    Write-Host "  [WARN] $Msg" -ForegroundColor Yellow
}

function Info($Msg) {
    Write-Host "  [INFO] $Msg" -ForegroundColor Blue
}

function Die($Msg) {
    Write-Host "  [FAIL] $Msg" -ForegroundColor Red
    if ($IsInteractive) { Read-Host "`nPress Enter to exit" }
    exit 1
}

function Read-HostSafe($Prompt, $Default = "") {
    if ($IsInteractive) { return Read-Host $Prompt }
    Write-Host "  [SKIP] '$Prompt' (non-interactive, default: '$Default')" -ForegroundColor Yellow
    return $Default
}

function Resolve-RelativePath($RelPath) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RelPath)
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
        $wingetOut = & winget install $WingetId --accept-package-agreements --accept-source-agreements 2>&1
        if ($LASTEXITCODE -eq 0) { $installed = $true }
        else {
            Warn "winget install failed:"
            $wingetOut | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
            Warn "Trying direct download ..."
        }
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

# ── Header ─────────────────────────────────────────────────────────────────
Clear-Host
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  wiki-mcp Installer for Windows" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""

# ── 0. Location guard ────────────────────────────────────────────────────
Step "Step 0: Checking install location"

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
Step "Step 1: Git"
if (-not (Ensure-Program "git" "Git.Git" (Get-LatestGitUrl) "git-install.exe" "/VERYSILENT /NORESTART")) {
    Die "Git could not be installed automatically. Install it from https://git-scm.com and re-run."
}

# ── 1b. Ensure bash (bundled with Git for Windows) ───────────────────────
$bashDir = $null
$bashProbePaths = @(
    "${env:ProgramFiles}\Git\bin",
    "${env:ProgramFiles(x86)}\Git\bin"
)
if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    foreach ($p in $bashProbePaths) {
        if (Test-Path "$p\bash.exe") {
            $env:Path = "$p;$env:Path"
            $bashDir = $p
            break
        }
    }
}
$bashCheck = Get-Command bash -ErrorAction SilentlyContinue
if ($bashCheck) {
    $ver = & $bashCheck.Source --version 2>$null
    Pass "bash found: $($ver.Split("`n")[0])"
    if ($bashDir) {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$bashDir*") {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$bashDir", "User")
            Pass "Git\bin added to User PATH"
        }
    }
} else {
    Warn "bash not found — MCP command in opencode.json may fail"
}

# ── 2. Check/Install Node.js ──────────────────────────────────────────────
Step "Step 2: Node.js"

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
Step "Step 3: Downloading wiki-mcp from GitHub"

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

# ── 3b. Configure opencode.json for Windows ────────────────────────────
Step "Step 3b: Windows MCP command"

$ocPath = "opencode.json"
if (Test-Path $ocPath) {
    $ocText = Get-Content $ocPath -Raw -Encoding UTF8
    $mcpShPath = "scripts\start-mcp.sh"
    if (Test-Path $mcpShPath) {
        $mcpShContent = Get-Content $mcpShPath -Raw
        $verMatch = [regex]::Match($mcpShContent, 'MCP_VERSION="(.+)"')
        if ($verMatch.Success) {
            $mcpVer = $verMatch.Groups[1].Value
            $oc = $ocText | ConvertFrom-Json
            $oc.mcp."wiki.fosscell.org".command = @("cmd", "/c", "npx.cmd", "@professional-wiki/mediawiki-mcp-server@${mcpVer}")
            $oc | ConvertTo-Json -Depth 10 | Out-File $ocPath -Encoding UTF8
            Pass "Windows-optimized MCP command (cmd /c npx.cmd @ v${mcpVer})"
        } else {
            Warn "Could not extract MCP version from scripts/start-mcp.sh"
        }
    } else {
        Warn "scripts/start-mcp.sh not found, MCP command not patched"
    }
} else {
    Warn "opencode.json not found in repo, creating default..."
    $defaultOc = @{
        mcp = @{
            "wiki.fosscell.org" = @{
                command = @("cmd", "/c", "npx.cmd", "@professional-wiki/mediawiki-mcp-server@latest")
                args = @()
            }
        }
    }
    $defaultOc | ConvertTo-Json -Depth 5 | Out-File $ocPath -Encoding UTF8
    Pass "Default opencode.json created"
}

# ── 4. Install opencode ──────────────────────────────────────────────────
Step "Step 4: opencode"

if (Test-Path $OpencodeExe) {
    $ver = & $OpencodeExe --version 2>$null
    Pass "opencode found: $ver"
} else {
    Write-Host "  opencode not found. Downloading ..." -ForegroundColor Yellow

    # Resolve latest version
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/anomalyco/opencode/releases/latest" -UseBasicParsing
        $version = $release.tag_name -replace '^v'
    } catch {
        Die "Failed to fetch opencode version info from GitHub."
    }
    Write-Host "  Latest version: v$version" -ForegroundColor Yellow

    $zipUrl = "https://github.com/anomalyco/opencode/releases/download/v$version/opencode-windows-$Arch.zip"
    $zipTmp = "$env:TEMP\opencode-windows-$Arch.zip"

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
Step "Step 5: Config"

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
    $json = $config | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText((Resolve-RelativePath "config.json"), $json, [System.Text.UTF8Encoding]::new($false))
    Pass "config.json created (read-only mode)"
} else {
    Pass "config.json already exists"
}

# ── 6. Wiki account check ──────────────────────────────────────────────
Step "Step 6: Wiki account"

Write-Host "  Checking wiki.fosscell.org..."
$wikiUrl = "https://wiki.fosscell.org"
$apiUrl = "$wikiUrl/api.php"
try {
    $siteInfo = Invoke-RestMethod -Uri "$apiUrl`?action=query&meta=siteinfo&format=json" -TimeoutSec 5 -UseBasicParsing
    Pass "Wiki is online"
} catch {
    Warn "Cannot reach wiki.fosscell.org — check your internet"
}
Write-Host ""

Write-Host "  You need a wiki account to use this tool."
Write-Host "  (It's free — anyone with @nitc.ac.in email can sign up.)"
Write-Host ""
$answer = Read-HostSafe "  Do you already have a wiki account? (Y/n)" "y"
if ($answer -match '^[Nn]') {
    Write-Host "  Opening registration page ..." -ForegroundColor Yellow
    try { Start-Process "https://wiki.fosscell.org/index.php?title=Special:CreateAccount" }
    catch { [System.Diagnostics.Process]::Start("https://wiki.fosscell.org/index.php?title=Special:CreateAccount") | Out-Null }
    if ($IsInteractive) { Read-Host "  Press Enter after you have created your account" }
    else { Write-Host "  [SKIP] Waiting for account creation (non-interactive mode)" -ForegroundColor Yellow }
} else {
    Write-Host "  Tip: Visit https://wiki.fosscell.org/index.php?title=Special:CreateAccount if you need an account later." -ForegroundColor Yellow
}
Pass "Wiki account check done"

# ── 7. Bot password setup ────────────────────────────────────────────────
Step "Step 7: Bot password"

if ($SkipBotPassword) {
    Warn "Skipping bot password setup (-SkipBotPassword flag set)."
    Warn "Configure credentials manually later: notepad config.json"
} else {
    $config = Get-Content "config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    $wiki = $config.wikis."wiki.fosscell.org"

    if ($wiki.username -and $wiki.password) {
        Pass "Credentials already configured for user '$($wiki.username)'"
    } else {
        Write-Host "  Now create a bot password so the AI can log in." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  A browser window will open to:" -ForegroundColor Yellow
        Write-Host "     https://wiki.fosscell.org/Special:BotPasswords" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Steps in the browser:" -ForegroundColor Yellow
        Write-Host "    1. Log in (if not already)" -ForegroundColor Yellow
        Write-Host "    2. Name it:  wiki-mcp" -ForegroundColor Yellow
        Write-Host "    3. Tick: Basic rights + Edit existing pages + Create, edit, and move pages + High-volume editing" -ForegroundColor Yellow
        Write-Host "    4. Click 'Create'" -ForegroundColor Yellow
        Write-Host "    5. Copy the generated password" -ForegroundColor Yellow
        Write-Host ""

        if ($IsInteractive) {
            Read-Host "  Press Enter to open the browser and continue..."
        } else {
            Write-Host "  [SKIP] Opening browser (non-interactive mode)" -ForegroundColor Yellow
        }
        try { Start-Process "https://wiki.fosscell.org/Special:BotPasswords" }
        catch { [System.Diagnostics.Process]::Start("https://wiki.fosscell.org/Special:BotPasswords") | Out-Null }

        $verified = $false
        $attempts = 0

        while (-not $verified -and $attempts -lt 3) {
            $attempts++
            $botUser = Read-HostSafe "  Bot username (e.g. MyName@wiki-mcp, or type 'skip' to bypass)" ""

            if ($botUser -match '^(?i)skip$') {
                Warn "Skipping bot password setup. Configure credentials manually later:"
                Warn "  notepad config.json"
                break
            }

            if (-not $IsInteractive) {
                Write-Host "  [SKIP] Bot password entry (non-interactive mode)" -ForegroundColor Yellow
                break
            }

            $botPass = Read-Host "  Bot password" -AsSecureString
            $botPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($botPass))
            $botPassPlain = $botPassPlain.Trim()

            if (-not $botUser -or -not $botPassPlain) {
                Warn "Username or password was empty. Try again."
                continue
            }

            if ($botPassPlain.Length -ne 32) {
                Warn "Bot password is $($botPassPlain.Length) characters — expected 32. This usually means a paste error."
                Warn "Try typing the password manually instead of pasting it."
            }

            Info "Verifying credentials..."
            try {
                $loginToken = Invoke-RestMethod -Uri "https://wiki.fosscell.org/api.php?action=query&meta=tokens&type=login&format=json" -SessionVariable ws -UseBasicParsing
                $token = $loginToken.query.tokens.logintoken

                $loginBody = @{
                    action     = "login"
                    lgname     = $botUser
                    lgpassword = $botPassPlain
                    lgtoken    = $token
                    format     = "json"
                }

                $loginResult = Invoke-RestMethod -Uri "https://wiki.fosscell.org/api.php" -Method Post -Body $loginBody -WebSession $ws -UseBasicParsing

                if ($loginResult.login.result -eq "Success") {
                    Pass "Wiki credentials verified"
                    $config.wikis."wiki.fosscell.org".username = $botUser
                    $config.wikis."wiki.fosscell.org".password = $botPassPlain
                    $json = $config | ConvertTo-Json -Depth 5
                    [System.IO.File]::WriteAllText((Resolve-RelativePath "config.json"), $json, [System.Text.UTF8Encoding]::new($false))
                    Pass "Credentials saved to config.json"
                    $verified = $true
                } else {
                    Warn "Login failed: $($loginResult.login.result)"
                    if ($loginResult.login.reason) { Warn "Reason: $($loginResult.login.reason)" }
                    Warn "Try typing the password manually instead of pasting, then try again."
                    if ($attempts -ge 3) {
                        Warn "3 attempts failed. Type 'skip' as the username to bypass, or run: .\install.ps1 -SkipBotPassword"
                    }
                }
            } catch {
                Warn "Could not reach the wiki API: $($_.Exception.Message)"
                if ($attempts -ge 3) {
                    Warn "3 attempts failed. Type 'skip' as the username to bypass, or run: .\install.ps1 -SkipBotPassword"
                }
            }
        }
    }
}

# ── 8. PowerShell profile alias ──────────────────────────────────────────
Step "Step 8: Adding wiki-mcp terminal command"

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
Step "Step 9: Desktop shortcut"

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
Step "Step 10: Validation"

# Test config JSON
try {
    $cfg = Get-Content "config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    Pass "config.json is valid JSON"
} catch {
    Die "config.json has invalid JSON — $($_.Exception.Message)"
}

# Test connectivity
try {
    $siteInfo = Invoke-RestMethod -Uri "https://wiki.fosscell.org/api.php?action=query&meta=siteinfo&format=json" -TimeoutSec 5 -UseBasicParsing
    Pass "Wiki API reachable"
} catch {
    Warn "Wiki API not reachable (check your internet)"
}

# Check MCP package availability (npm view — no server start, no block)
Info "Checking MCP server package..."
try {
    $mcpVer = & npm.cmd view @professional-wiki/mediawiki-mcp-server version 2>&1 | Select-Object -Last 1
    if ($mcpVer -and $mcpVer -match '^\d') {
        Pass "MCP server package available (v$($mcpVer.Trim()))"
    } else {
        throw "no version returned"
    }
} catch {
    Warn "MCP server check failed — it'll download on first run."
    Info "This is normal — it'll work when you run 'wiki-mcp'."
}

# ── Done ─────────────────────────────────────────────────────────────────
$repoPath = (Get-Location).Path
Pop-Location
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  wiki-mcp setup complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

if ($shortcutsCreated -gt 0) {
    Write-Host "  Double-click the desktop icon or find"
    Write-Host "  'NITC Wiki MCP' in your Start Menu."
    Write-Host ""
}

if ($aliasExists -or (Test-Path $ProfilePath -and (Get-Content $ProfilePath -Raw -ErrorAction SilentlyContinue) -match "wiki-mcp")) {
    Write-Host "  Or run:  wiki-mcp"
    Write-Host "  (Restart PowerShell or '. `$PROFILE' first if using the same session)"
    Write-Host ""
}

Write-Host "  Config files:"
Write-Host "    $repoPath\opencode.json"
Write-Host "    $repoPath\config.json"
Write-Host ""

$cfgCheck = Get-Content (Resolve-RelativePath "$repoPath\config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $cfgCheck.wikis."wiki.fosscell.org".username) {
    Write-Host "  Credentials not configured. Edit config.json to add them:" -ForegroundColor Yellow
    Write-Host "    notepad $repoPath\config.json" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  First run? opencode will download the model (~2GB)."
Write-Host "  This happens once."
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

if ($IsInteractive) {
    Read-Host "Press Enter to close this window..."
}
