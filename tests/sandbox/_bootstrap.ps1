#Requires -Version 5.1
<#
.SYNOPSIS
    Sandbox bootstrap -- runs automatically at Windows Sandbox logon.
    Sets up the chosen test scenario and stays open as the interactive terminal.

.PARAMETER Scenario
    fresh   - Full repo copy. Python and Git are not installed (sandbox default).
              winget is not available in sandbox, so this exercises the direct
              download fallback (python.org + git-for-windows GitHub releases).

    zip     - Full repo copy minus .git. Simulates a GitHub ZIP download.
              Tests: git init + remote + fetch path (Scenario B in the script).

    clone   - Only update-site.ps1, no repo files.
              Tests: the fresh-clone offer (Scenario C in the script).
#>
param(
    [ValidateSet("fresh", "zip", "clone")]
    [string]$Scenario = "fresh"
)

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Note: winget (App Installer) is not available in Windows Sandbox -- its
# dependency chain (WindowsAppRuntime 1.8+) cannot be satisfied without Store
# access. The fresh-install scenario therefore tests the direct download
# fallback in update-site.ps1 (python.org + git-for-windows GitHub releases).

# ---------------------------------------------------------------------------
# Set up test directory for the chosen scenario
# ---------------------------------------------------------------------------
$TestDir = "$env:USERPROFILE\Desktop\haus-test"

switch ($Scenario) {
    "fresh" {
        Write-Host "  Copying full repo to $TestDir ..." -ForegroundColor Cyan
        Copy-Item "C:\host-repo" $TestDir -Recurse -Force
        $label  = "SCENARIO: Fresh Install"
        $detail = "Python and Git are NOT installed. No winget in sandbox -- direct download fallback will run."
    }
    "zip" {
        Write-Host "  Copying repo (without .git) to $TestDir ..." -ForegroundColor Cyan
        Copy-Item "C:\host-repo" $TestDir -Recurse -Force
        Remove-Item "$TestDir\.git" -Recurse -Force -ErrorAction SilentlyContinue
        $label  = "SCENARIO: ZIP Extract"
        $detail = "Repo files exist but no .git folder. Script should run: git init + remote + fetch."
    }
    "clone" {
        Write-Host "  Placing update-site.ps1 in empty folder $TestDir ..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
        Copy-Item "C:\host-repo\update-site.ps1" $TestDir
        $label  = "SCENARIO: Fresh Clone"
        $detail = "Only the script exists, no repo files. Script should offer to clone from GitHub."
    }
}

# ---------------------------------------------------------------------------
# Stay in this window as the interactive terminal
# ---------------------------------------------------------------------------
Set-Location $TestDir
$host.UI.RawUI.WindowTitle = $label

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host "  $label" -ForegroundColor Yellow
Write-Host "  $detail" -ForegroundColor Gray
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Working dir : $TestDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Run when ready:" -ForegroundColor Gray
Write-Host "    .\update-site.ps1" -ForegroundColor White
Write-Host ""
