#Requires -Version 5.1
<#
.SYNOPSIS
    Haus of Sutra - Instagram Feed Auto-Update Script

.DESCRIPTION
    Just run .\update-site.ps1 — the script walks you through everything:
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

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$RepoRoot        = $PSScriptRoot
$LastRunFile     = Join-Path $RepoRoot ".last_run"
$VenvDir         = Join-Path $RepoRoot ".venv"
$VenvActivate    = Join-Path $VenvDir "Scripts\Activate.ps1"
$GrabScript      = Join-Path $RepoRoot "instagram\grab_posts.py"
$SessionUserFile = Join-Path $RepoRoot "instagram\.insta_session_user"

Write-Host ""
Write-Host "  Haus of Sutra - Instagram Feed Sync" -ForegroundColor Magenta
Write-Host "  =====================================" -ForegroundColor Magenta
Write-Host ""

# ---------------------------------------------------------------------------
# 1. 12-hour elapsed-time check
#    Unattended: exit silently (Task Scheduler will try again later)
#    Interactive: ask the user if they want to run anyway
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
            exit 0
        }
        Write-Host ""
    }
}

# ---------------------------------------------------------------------------
# 2. Check Python
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
    $install = Read-Host "  Install Python via winget? (Y/N)"
    if ($install -eq "Y" -or $install -eq "y") {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Status "Installing Python..."
            winget install Python.Python.3
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("Path","User")
            $pythonCmd = "python"
        } else {
            Write-Err "winget not available."
            Write-Warn "Download Python from: https://www.python.org/downloads/"
            exit 1
        }
    } else {
        Write-Warn "Python is required. Download from: https://www.python.org/downloads/"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 3. Check Git
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
    $install = Read-Host "  Install Git via winget? (Y/N)"
    if ($install -eq "Y" -or $install -eq "y") {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Status "Installing Git..."
            winget install Git.Git
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("Path","User")
        } else {
            Write-Err "winget not available."
            Write-Warn "Download Git from: https://git-scm.com/download/win"
            exit 1
        }
    } else {
        Write-Warn "Git is required. Download from: https://git-scm.com/download/win"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 4. Verify we're inside the git repo
# ---------------------------------------------------------------------------
Write-Status "Verifying repo..."
$insideRepo = & git -C $RepoRoot rev-parse --is-inside-work-tree 2>&1
if ($insideRepo -ne "true") {
    Write-Err "Not inside a git repository: $RepoRoot"
    exit 1
}
Write-Success "Repo OK"

# ---------------------------------------------------------------------------
# 5. Virtual environment
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
Write-Status "Checking dependencies..."
& pip install --quiet instaloader requests 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to install Python dependencies."
    exit 1
}
Write-Success "Dependencies ready"

# ---------------------------------------------------------------------------
# 6. Instagram auth via Windows Credential Manager
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
        Write-Success "Found saved credentials for @$($storedCred.UserName)"
        Set-Content -Path $SessionUserFile -Value $storedCred.UserName -NoNewline
    }
} catch {
    $vault = $null
    $storedCred = $null
}

if (-not $storedCred) {
    Write-Warn "No saved Instagram credentials found."
    if ($Unattended) {
        Write-Warn "Running unattended - skipping Instagram login."
        $doLogin = "N"
    } else {
        $doLogin = Read-Host "  Log in to Instagram for better reliability? (Y/N)"
    }
    if ($doLogin -eq "Y" -or $doLogin -eq "y") {
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
    } else {
        Write-Warn "Skipping login - using anonymous access (may be rate-limited)."
    }
}

# ---------------------------------------------------------------------------
# 7. Run grab_posts.py
# ---------------------------------------------------------------------------
Write-Host ""
Write-Status "Running grab_posts.py..."
& $pythonCmd $GrabScript
if ($LASTEXITCODE -ne 0) {
    Write-Err "grab_posts.py exited with code $LASTEXITCODE"
    exit 1
}

# ---------------------------------------------------------------------------
# 8. Check for git changes
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
    # 9. Ensure git identity is configured
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
    # 10. Commit, rebase on remote, push
    # -----------------------------------------------------------------------
    & git -C $RepoRoot add "instagram/"
    & git -C $RepoRoot commit -m "chore: sync instagram feed"
    if ($LASTEXITCODE -ne 0) {
        Write-Err "git commit failed."
        exit 1
    }

    Write-Status "Pulling latest from origin main..."
    $pullOutput = & git -C $RepoRoot pull --rebase origin main 2>&1
    $pullExit = $LASTEXITCODE
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
    $pushOutput = & git -C $RepoRoot push origin main 2>&1
    $pushExit = $LASTEXITCODE
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
    # 11. Update last-run timestamp
    # -----------------------------------------------------------------------
    Set-Content -Path $LastRunFile -Value (Get-Date).ToUniversalTime().ToString("o")

    Write-Host ""
    Write-Success "Feed synced, committed, and pushed."
    Write-Host ""
}

# ---------------------------------------------------------------------------
# 12. Scheduler — offer to set up if no scheduled task exists yet
# ---------------------------------------------------------------------------
$taskName = "HausOfSutra-InstagramSync"
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if (-not $existingTask -and -not $Unattended) {
    Write-Host ""
    $scheduleIt = Read-Host "  Would you like this script to run automatically every 12 hours? (Y/N)"
    if ($scheduleIt -eq "Y" -or $scheduleIt -eq "y") {
        $scriptPath = $MyInvocation.MyCommand.Path
        $action = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Unattended"

        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $trigger.RepetitionInterval = [TimeSpan]::FromHours(12)
        $trigger.RepetitionDuration = [TimeSpan]::FromDays(9999)

        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
            -StartWhenAvailable

        $principal = New-ScheduledTaskPrincipal `
            -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
            -LogonType Interactive `
            -RunLevel Limited

        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal `
            -Description "Auto-syncs Haus of Sutra Instagram feed every 12 hours." | Out-Null

        Write-Success "Scheduled task '$taskName' registered."
        Write-Status "It will run at logon and repeat every 12 hours."
    } else {
        Write-Warn "No problem. You can always re-run this script manually."
    }
}

Write-Host ""
