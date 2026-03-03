#Requires -Version 5.1
<#
.SYNOPSIS
    Haus of Sutra - Instagram Feed Auto-Update Script

.DESCRIPTION
    Just run .\update-site.ps1 -- the script walks you through everything:
    dependency checks, Instagram login, syncing posts, pushing to GitHub,
    and setting up automatic 12-hour scheduling.
#>

# Hidden param: -Unattended is passed automatically by the scheduled task.
# It suppresses all prompts and exits on any issue that would need user input.
param(
    [switch]$Unattended
)

$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# ---------------------------------------------------------------------------
# Colored output helpers
# ---------------------------------------------------------------------------
function Write-Status  { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Cyan }
function Write-Success { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Green }
function Write-Warn    { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Yellow }
function Write-Err     { param([string]$Msg) Write-Host "  ERROR: $Msg" -ForegroundColor Red }

function Find-Winget {
    # Try PATH first, then the WindowsApps location used by Windows Sandbox / fresh installs
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $found = Resolve-Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe" `
                 -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($found) { return $found.Path }
    return $null
}

function Install-PythonDirect {
    Write-Status "winget unavailable -- downloading Python installer from python.org..."
    try {
        $page = Invoke-WebRequest -Uri "https://www.python.org/downloads/windows/" `
                    -UseBasicParsing -ErrorAction Stop
        $match = [regex]::Match($page.Content,
                     'href="(https://www\.python\.org/ftp/python/[\d.]+/python-[\d.]+-amd64\.exe)"')
        if (-not $match.Success) {
            Write-Err "Could not parse Python installer URL from python.org."
            return $false
        }
        $url = $match.Groups[1].Value
        $installer = "$env:TEMP\python-installer.exe"
        Write-Status "Downloading: $url"
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -ErrorAction Stop
        $sizeMB = [math]::Round((Get-Item $installer).Length / 1MB, 1)
        Write-Status "Downloaded: ${sizeMB} MB"
        if ($sizeMB -lt 1) {
            Write-Err "Download too small (${sizeMB} MB) -- likely a 404 error page, not a real installer."
            Remove-Item $installer -Force -ErrorAction SilentlyContinue
            return $false
        }
        Write-Status "Running installer (silent)..."
        # InstallAllUsers=0 = per-user install (no admin elevation needed).
        # Use Start-Process -Wait so PowerShell waits for the full installer tree,
        # not just the bootstrapper shim that spawns a child MSI and exits immediately.
        $proc = Start-Process -FilePath $installer `
            -ArgumentList "/quiet InstallAllUsers=0 PrependPath=1 Include_test=0" `
            -Wait -PassThru
        $exitCode = $proc.ExitCode
        Remove-Item $installer -Force -ErrorAction SilentlyContinue

        # Poll for up to 60 s -- the MSI may still be running even after -Wait returns.
        Write-Status "Waiting for Python to appear in PATH..."
        for ($i = 0; $i -lt 12; $i++) {
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("Path","User")
            if (Get-Command python -ErrorAction SilentlyContinue) { return $true }
            Start-Sleep -Seconds 5
        }
        Write-Err "Python installer exited (code: $exitCode) but python is not in PATH after 60 s."
        return $false
    } catch {
        Write-Err "Direct Python download failed: $_"
        return $false
    }
}

function Install-GitDirect {
    Write-Status "winget unavailable -- downloading Git installer from GitHub..."
    try {
        $release = Invoke-RestMethod `
                       -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" `
                       -ErrorAction Stop
        $asset = $release.assets |
                     Where-Object { $_.name -match "Git-[\d\.]+-64-bit\.exe" } |
                     Select-Object -First 1
        if (-not $asset) {
            Write-Err "Could not find Git 64-bit installer in latest release."
            return $false
        }
        $installer = "$env:TEMP\git-installer.exe"
        Write-Status "Downloading: $($asset.browser_download_url)"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer `
            -UseBasicParsing -ErrorAction Stop
        Write-Status "Running installer (silent)..."
        & $installer /VERYSILENT /NORESTART /NOCANCEL /SP- `
                     /COMPONENTS="icons,ext\reg\shellhere,assoc,assoc_sh"
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-Err "Direct Git download failed: $_"
        return $false
    }
}

function Invoke-SchedulerSetup {
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask -or $Unattended) { return }

    Write-Host ""
    $scheduleIt = Read-Host "  Would you like this script to run automatically every 12 hours? (Y/N)"
    if ($scheduleIt -ne "Y" -and $scheduleIt -ne "y") {
        Write-Warn "No problem. You can always re-run this script manually."
        return
    }

    $scriptPath = $PSCommandPath
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Unattended"

    $trigger = New-ScheduledTaskTrigger -Once `
        -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Hours 12) `
        -RepetitionDuration (New-TimeSpan -Days 9999)

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
        -StartWhenAvailable

    $principal = New-ScheduledTaskPrincipal `
        -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive `
        -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description "Auto-syncs Haus of Sutra Instagram feed every 12 hours." | Out-Null

    Write-Success "Scheduled task '$TaskName' registered."
    Write-Status "It will run now and repeat every 12 hours."
}

# ---------------------------------------------------------------------------
# Paths (RepoRoot may be updated after clone detection in step 3)
# ---------------------------------------------------------------------------
$RepoUrl         = "https://github.com/hausofsutra/Haus-of-sutra-website-.git"
$RepoName        = "Haus-of-sutra-website-"
$RepoRoot        = $PSScriptRoot
$TaskName        = "HausOfSutra-InstagramSync"

function Set-RepoPaths {
    # Call this whenever $script:RepoRoot changes
    $script:LastRunFile     = Join-Path $script:RepoRoot ".last_run"
    $script:VenvDir         = Join-Path $script:RepoRoot ".venv"
    $script:VenvActivate    = Join-Path $script:VenvDir "Scripts\Activate.ps1"
    $script:GrabScript      = Join-Path $script:RepoRoot "instagram\grab_posts.py"
    $script:SessionUserFile = Join-Path $script:RepoRoot "instagram\.insta_session_user"
}
Set-RepoPaths

Write-Host ""
Write-Host "  Haus of Sutra - Instagram Feed Sync" -ForegroundColor Magenta
Write-Host "  =====================================" -ForegroundColor Magenta
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Check Python
# ---------------------------------------------------------------------------
Write-Status "Checking Python..."
$pythonCmd = $null
foreach ($cmd in @("python", "python3", "py")) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match "Python 3") {
            $pythonCmd = $cmd
            Write-Success "Found: $ver"
            break
        }
    } catch { }
}

if (-not $pythonCmd) {
    Write-Err "Python 3 not found."
    if ($Unattended) {
        Write-Err "Cannot install Python unattended. Install manually and re-run."
        exit 1
    }
    $install = Read-Host "  Install Python automatically? (Y/N)"
    if ($install -eq "Y" -or $install -eq "y") {
        $wingetExe = Find-Winget
        $ok = $false
        if ($wingetExe) {
            Write-Status "Installing Python via winget..."
            & $wingetExe install Python.Python.3 --accept-package-agreements --accept-source-agreements
            $ok = ($LASTEXITCODE -eq 0)
            if (-not $ok) { Write-Warn "winget install failed (exit $LASTEXITCODE). Trying direct download..." }
        }
        if (-not $ok) { $ok = Install-PythonDirect }
        if (-not $ok) {
            Write-Err "Could not install Python automatically."
            Write-Warn "Please install manually: https://www.python.org/downloads/"
            exit 1
        }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path","User")
        $pythonCmd = "python"
    } else {
        Write-Warn "Python is required. Download from: https://www.python.org/downloads/"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 2. Check Git
# ---------------------------------------------------------------------------
Write-Status "Checking Git..."
try {
    $gitVer = & git --version 2>&1
    Write-Success "Found: $gitVer"
} catch {
    Write-Err "Git not found."
    if ($Unattended) {
        Write-Err "Cannot install Git unattended. Install manually and re-run."
        exit 1
    }
    $install = Read-Host "  Install Git automatically? (Y/N)"
    if ($install -eq "Y" -or $install -eq "y") {
        $wingetExe = Find-Winget
        $ok = $false
        if ($wingetExe) {
            Write-Status "Installing Git via winget..."
            & $wingetExe install Git.Git --accept-package-agreements --accept-source-agreements
            $ok = ($LASTEXITCODE -eq 0)
            if (-not $ok) { Write-Warn "winget install failed (exit $LASTEXITCODE). Trying direct download..." }
        }
        if (-not $ok) { $ok = Install-GitDirect }
        if (-not $ok) {
            Write-Err "Could not install Git automatically."
            Write-Warn "Please install manually: https://git-scm.com/download/win"
            exit 1
        }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path","User")
    } else {
        Write-Warn "Git is required. Download from: https://git-scm.com/download/win"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 3. Ensure we're in a proper git repo
#    Handles three scenarios:
#      A) Script is already inside a git repo (normal use after first setup)
#      B) User downloaded and extracted the ZIP from GitHub (files exist, no .git)
#      C) Script is sitting somewhere with no repo at all (clone from scratch)
# ---------------------------------------------------------------------------
Write-Status "Looking for repo..."
$insideRepo = & git -C $RepoRoot rev-parse --is-inside-work-tree 2>&1

if ($insideRepo -ne "true") {
    # Check if this looks like an extracted ZIP (key files exist but no .git/)
    $hasRepoFiles = (Test-Path (Join-Path $RepoRoot "index.html")) -and
                    (Test-Path (Join-Path $RepoRoot "instagram\grab_posts.py"))

    if ($hasRepoFiles) {
        # Scenario B: extracted ZIP -- initialize git and connect to remote
        Write-Warn "This looks like an extracted ZIP download (no .git folder)."
        Write-Status "Setting up git so we can push changes..."

        & git -C $RepoRoot init
        if ($LASTEXITCODE -ne 0) { Write-Err "git init failed."; exit 1 }

        & git -C $RepoRoot remote add origin $RepoUrl 2>&1 | Out-Null
        & git -C $RepoRoot fetch origin main
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Could not fetch from remote. Check your internet connection."
            exit 1
        }

        # Reset to track remote main -- keeps local files, sets up proper history
        & git -C $RepoRoot reset origin/main 2>&1 | Out-Null
        & git -C $RepoRoot branch --set-upstream-to=origin/main main 2>&1 | Out-Null

        Write-Success "Git initialized and connected to GitHub."
    } else {
        # Scenario C: no repo files here -- check for or clone a subdirectory
        $subDir = Join-Path $PSScriptRoot $RepoName
        if (Test-Path (Join-Path $subDir ".git")) {
            Write-Status "Found repo at: $subDir"
            $RepoRoot = $subDir
            Set-RepoPaths
        } else {
            Write-Warn "Repo not found. It will be cloned to: $subDir"
            if ($Unattended) {
                Write-Err "Cannot clone unattended on first run. Run the script manually first."
                exit 1
            }
            $doClone = Read-Host "  Clone the repo now? (Y/N)"
            if ($doClone -eq "Y" -or $doClone -eq "y") {
                Write-Status "Cloning $RepoUrl ..."
                & git clone $RepoUrl $subDir
                if ($LASTEXITCODE -ne 0) {
                    Write-Err "git clone failed."
                    exit 1
                }
                Write-Success "Cloned to: $subDir"
                $RepoRoot = $subDir
                Set-RepoPaths
            } else {
                Write-Warn "Cannot continue without the repo."
                exit 1
            }
        }
    }
}
Write-Success "Repo OK: $RepoRoot"

# ---------------------------------------------------------------------------
# 4. Pull latest repo changes (keeps script and grab_posts.py up to date)
# ---------------------------------------------------------------------------
Write-Status "Checking for repo updates..."

$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

$pullSelfOutput = & git -C $RepoRoot pull --rebase --autostash origin main 2>&1
$pullSelfExit = $LASTEXITCODE

$ErrorActionPreference = $oldEap
if ($pullSelfExit -ne 0) {
    # Non-fatal -- warn but continue with current version
    Write-Warn "Could not pull latest updates (continuing with current version)."
} else {
    $pullSelfStr = $pullSelfOutput | Out-String
    if ($pullSelfStr -match "Already up to date") {
        Write-Success "Already up to date."
    } else {
        Write-Success "Updated to latest version. Changes take effect on next run."
    }
}

# ---------------------------------------------------------------------------
# 5. 12-hour elapsed-time check (now that we know where .last_run is)
# ---------------------------------------------------------------------------
if (Test-Path $LastRunFile) {
    $lastRun = [datetime]::Parse(
        (Get-Content $LastRunFile -Raw).Trim(),
        $null,
        [System.Globalization.DateTimeStyles]::RoundtripKind)
    $elapsed = (Get-Date).ToUniversalTime() - $lastRun.ToUniversalTime()
    $hoursLeft = 12 - $elapsed.TotalHours
    if ($hoursLeft -gt 0) {
        $hh = [int][Math]::Floor($hoursLeft)
        $mm = [int][Math]::Floor(($hoursLeft - $hh) * 60)
        Write-Warn "Already ran $([int]$elapsed.TotalHours)h $([int]$elapsed.Minutes)m ago. Next run in ${hh}h ${mm}m."
        if ($Unattended) {
            exit 0
        }
        $runAnyway = Read-Host "  Run anyway? (Y/N)"
        if ($runAnyway -ne "Y" -and $runAnyway -ne "y") {
            Invoke-SchedulerSetup
            exit 0
        }
        Write-Host ""
    }
}

# ---------------------------------------------------------------------------
# 6. Virtual environment
# ---------------------------------------------------------------------------
Write-Status "Setting up Python virtual environment..."
if (-not (Test-Path $VenvDir)) {
    Write-Status "Creating .venv..."
    & $pythonCmd -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to create virtual environment."
        exit 1
    }
}
if (-not (Test-Path $VenvActivate)) {
    Write-Err "Could not find venv activation script: $VenvActivate"
    exit 1
}
& $VenvActivate
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Write-Status "Checking dependencies..."
# TODO: revert to 'instaloader' once PR #2652 is merged (https://github.com/instaloader/instaloader/pull/2652)
# Installing from fork branch that fixes 429 errors by migrating from deprecated web_profile_info to GraphQL
& pip install --quiet requests 2>&1 | Out-Null
& pip install --quiet --force-reinstall --no-deps git+https://github.com/cxyfer/instaloader.git@fix/profile-graphql-v4.16 2>&1 | Out-Null
$ErrorActionPreference = $oldEap
if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to install Python dependencies."
    exit 1
}
# Apply post-install patches (GraphQL-first ordering, 401 rate-limit backoff)
$patchScript = Join-Path $RepoRoot "instagram\patch_instaloader.py"
if (Test-Path $patchScript) {
    & $pythonCmd $patchScript
}
Write-Success "Dependencies ready"

# ---------------------------------------------------------------------------
# 7. Instagram auth -- check for saved login, then let user choose
# ---------------------------------------------------------------------------
Write-Status "Checking Instagram credentials..."

$credentialTarget = "HausOfSutra-Instagram"
$vault = $null
$storedCred = $null

# Load the WinRT PasswordVault type (needed on PS 5.1)
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime 2>$null
    [void][Windows.Security.Credentials.PasswordVault, Windows.Security.Credentials, ContentType = WindowsRuntime]
    $vault = [Windows.Security.Credentials.PasswordVault]::new()
    $allCreds = $vault.FindAllByResource($credentialTarget) 2>$null
    if ($allCreds -and $allCreds.Count -gt 0) {
        $storedCred = $allCreds[0]
        $storedCred.RetrievePassword()
    }
} catch {
    $vault = $null
    $storedCred = $null
}

$hasSessionFile = Test-Path $SessionUserFile
$savedUser = if ($storedCred) { $storedCred.UserName }
             elseif ($hasSessionFile) { (Get-Content $SessionUserFile -Raw).Trim() }
             else { $null }
$hasSavedLogin = $null -ne $savedUser

$doNewLogin  = $false
$useAnonymous = $false

if ($Unattended) {
    if ($hasSavedLogin) {
        Write-Status "Using saved login for @$savedUser (unattended)."
        if ($storedCred) { Set-Content -Path $SessionUserFile -Value $savedUser -NoNewline }
    } else {
        Write-Warn "No saved credentials - using anonymous access (unattended)."
        $useAnonymous = $true
    }
} elseif ($hasSavedLogin) {
    Write-Success "Found saved login: @$savedUser"
    Write-Host ""
    Write-Host "  [1] Use saved login (@$savedUser)  (recommended)" -ForegroundColor Cyan
    Write-Host "  [2] Log in with different credentials" -ForegroundColor Cyan
    Write-Host "  [3] Run anonymously" -ForegroundColor Cyan
    Write-Host ""
    $authChoice = Read-Host "  Choose (1/2/3)"
    switch ($authChoice) {
        "2" { $doNewLogin = $true }
        "3" { $useAnonymous = $true; Write-Warn "Using anonymous access (may be rate-limited)." }
        default {
            Write-Success "Using saved login for @$savedUser"
            if ($storedCred) { Set-Content -Path $SessionUserFile -Value $savedUser -NoNewline }
        }
    }
} else {
    Write-Warn "No saved Instagram credentials found."
    Write-Host ""
    Write-Host "  [1] Log in to Instagram  (recommended - more reliable)" -ForegroundColor Cyan
    Write-Host "  [2] Run anonymously  (may be rate-limited)" -ForegroundColor Cyan
    Write-Host ""
    $authChoice = Read-Host "  Choose (1/2)"
    switch ($authChoice) {
        "2" { $useAnonymous = $true; Write-Warn "Using anonymous access (may be rate-limited)." }
        default { $doNewLogin = $true }
    }
}

if ($doNewLogin) {
    $igUser = Read-Host "  Instagram username"
    $igPassSS = Read-Host "  Instagram password" -AsSecureString
    $igPassBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($igPassSS)
    $igPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($igPassBSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($igPassBSTR)

    Write-Status "Logging in and saving instaloader session..."
    $loginScript = @"
import instaloader, sys
L = instaloader.Instaloader()
try:
    L.login(sys.argv[1], sys.argv[2])
    L.save_session_to_file()
    print('Session saved.')
except Exception as e:
    print(f'Login failed: {e}', file=sys.stderr)
    sys.exit(1)
"@
    $loginResult = & $pythonCmd -c $loginScript $igUser $igPass 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Instagram login failed: $loginResult"
        Write-Warn "Continuing with anonymous access."
        $useAnonymous = $true
    } else {
        Write-Success $loginResult

        if ($vault) {
            try {
                try { $vault.Remove($vault.Retrieve($credentialTarget, $igUser)) } catch { }
                $newCred = [Windows.Security.Credentials.PasswordCredential]::new(
                    $credentialTarget, $igUser, $igPass)
                $vault.Add($newCred)
                Write-Success "Credentials saved to Windows Credential Manager."
            } catch {
                Write-Warn "Could not save to Credential Manager: $_"
            }
        } else {
            Write-Warn "Windows Credential Manager not available. Credentials not persisted."
            Write-Warn "The instaloader session file will still be used for this machine."
        }

        Set-Content -Path $SessionUserFile -Value $igUser -NoNewline
        Write-Success "Session user saved."
    }
    $igPass = $null
    [System.GC]::Collect()
}

# ---------------------------------------------------------------------------
# 8. Run grab_posts.py
# ---------------------------------------------------------------------------
Write-Host ""
Write-Status "Running grab_posts.py..."

# If the user chose anonymous, temporarily hide the session file so grab_posts.py
# doesn't load it. Restore it afterwards regardless of outcome.
$sessionFileHidden = $false
if ($useAnonymous -and (Test-Path $SessionUserFile)) {
    if (Test-Path "$SessionUserFile.bak") { Remove-Item "$SessionUserFile.bak" -Force }
    Move-Item -Path $SessionUserFile -Destination "$SessionUserFile.bak" -Force
    $sessionFileHidden = $true
}

& $pythonCmd $GrabScript
$grabExit = $LASTEXITCODE

if ($sessionFileHidden -and (Test-Path "$SessionUserFile.bak")) {
    if (Test-Path $SessionUserFile) { Remove-Item $SessionUserFile -Force }
    Move-Item -Path "$SessionUserFile.bak" -Destination $SessionUserFile -Force
}

if ($grabExit -ne 0) {
    Write-Err "grab_posts.py exited with code $grabExit"
    exit 1
}

# ---------------------------------------------------------------------------
# 9. Check for git changes
# ---------------------------------------------------------------------------
Write-Host ""
Write-Status "Checking for changes..."
$changes = & git -C $RepoRoot status --porcelain "instagram/" 2>&1
if (-not $changes) {
    Write-Success "No new posts - feed is already up to date."
    Set-Content -Path $LastRunFile -Value (Get-Date).ToUniversalTime().ToString("o")
    Write-Host ""
    # Still check scheduler at the end
} else {
    Write-Success "Changes detected - committing..."

    # -----------------------------------------------------------------------
    # 10. Ensure git identity is configured
    # -----------------------------------------------------------------------
    $gitName  = & git -C $RepoRoot config user.name  2>&1
    $gitEmail = & git -C $RepoRoot config user.email 2>&1
    if (-not $gitName -or $gitName -match "error") {
        if ($Unattended) {
            Write-Err "git user.name not configured. Run: git config --global user.name 'Your Name'"
            exit 1
        }
        $gitName = Read-Host "  git user.name not set. Enter your name"
        & git -C $RepoRoot config --global user.name $gitName
    }
    if (-not $gitEmail -or $gitEmail -match "error") {
        if ($Unattended) {
            Write-Err "git user.email not configured. Run: git config --global user.email 'you@example.com'"
            exit 1
        }
        $gitEmail = Read-Host "  git user.email not set. Enter your email"
        & git -C $RepoRoot config --global user.email $gitEmail
    }

    # -----------------------------------------------------------------------
    # 11. Commit, rebase on remote, push
    # -----------------------------------------------------------------------
    & git -C $RepoRoot add "instagram/"
    & git -C $RepoRoot commit -m "chore: sync instagram feed"
    if ($LASTEXITCODE -ne 0) {
        Write-Err "git commit failed."
        exit 1
    }

    Write-Status "Checking for repo updates..."

    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    $pullOutput = & git -C $RepoRoot pull --rebase --autostash origin main 2>&1
    $pullExit = $LASTEXITCODE

    $ErrorActionPreference = $oldEap

    if ($pullExit -ne 0) {
        $pullStr = $pullOutput | Out-String
        if ($pullStr -match "authentication" -or $pullStr -match "credential" -or
            $pullStr -match "Permission denied" -or $pullStr -match "403") {
            Write-Err "Pull failed: authentication error."
            Write-Warn "  - Run: gh auth login"
            Write-Warn "  - Set up SSH keys: https://docs.github.com/en/authentication/connecting-to-github-with-ssh"
            Write-Warn "  - Ensure Git Credential Manager is installed"
        } elseif ($pullStr -match "CONFLICT") {
            Write-Err "Pull failed: merge conflict detected."
            Write-Warn "Resolve conflicts manually in: $RepoRoot"
            Write-Warn "Then run: git rebase --continue && git push origin main"
        } else {
            Write-Err "Pull failed:"
            Write-Host $pullStr -ForegroundColor Red
        }
        exit 1
    }
    Write-Success "Up to date with remote."

    Write-Status "Pushing to origin main..."
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    $pushOutput = & git -C $RepoRoot push origin main 2>&1
    $pushExit = $LASTEXITCODE

    $ErrorActionPreference = $oldEap
    if ($pushExit -ne 0) {
        $pushStr = $pushOutput | Out-String
        if ($pushStr -match "authentication" -or $pushStr -match "credential" -or
            $pushStr -match "Permission denied" -or $pushStr -match "403") {
            Write-Err "Push failed: authentication error."
            Write-Warn "Try one of:"
            Write-Warn "  - Run: gh auth login"
            Write-Warn "  - Set up SSH keys: https://docs.github.com/en/authentication/connecting-to-github-with-ssh"
            Write-Warn "  - Ensure Git Credential Manager is installed"
        } elseif ($pushStr -match "non-fast-forward" -or $pushStr -match "rejected") {
            Write-Err "Push rejected - remote has new commits that arrived during this run."
            Write-Warn "Re-run the script to retry."
        } else {
            Write-Err "Push failed:"
            Write-Host $pushStr -ForegroundColor Red
        }
        exit 1
    }
    Write-Success "Pushed to origin main."

    # -----------------------------------------------------------------------
    # 12. Update last-run timestamp
    # -----------------------------------------------------------------------
    Set-Content -Path $LastRunFile -Value (Get-Date).ToUniversalTime().ToString("o")

    Write-Host ""
    Write-Success "Feed synced, committed, and pushed."
    Write-Host ""
}

# ---------------------------------------------------------------------------
# 13. Scheduler -- offer to set up if no scheduled task exists yet
# ---------------------------------------------------------------------------
Invoke-SchedulerSetup

Write-Host ""
