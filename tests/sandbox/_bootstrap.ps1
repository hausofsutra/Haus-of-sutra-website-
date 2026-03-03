#Requires -Version 5.1
<#
.SYNOPSIS
    Sandbox bootstrap — runs automatically at Windows Sandbox logon.
    Sets up the chosen test scenario, then opens a labelled terminal
    in the right working directory so you can run .\update-site.ps1.

.PARAMETER Scenario
    fresh   - Full repo copy. Python and Git are not installed (sandbox default).
              Tests: winget auto-install of Python + Git, venv, pip, auth, scheduler.

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

$TestDir     = "$env:USERPROFILE\Desktop\haus-test"
$SetupScript = "$env:TEMP\_sandbox_ready.ps1"

switch ($Scenario) {
    "fresh" {
        Write-Host "  Copying full repo to $TestDir ..." -ForegroundColor Cyan
        Copy-Item "C:\host-repo" $TestDir -Recurse -Force
        $label = "SCENARIO: Fresh Install"
        $detail = "Python and Git are NOT installed. winget will be offered for both."
    }
    "zip" {
        Write-Host "  Copying repo (without .git) to $TestDir ..." -ForegroundColor Cyan
        Copy-Item "C:\host-repo" $TestDir -Recurse -Force
        Remove-Item "$TestDir\.git" -Recurse -Force -ErrorAction SilentlyContinue
        $label = "SCENARIO: ZIP Extract"
        $detail = "Repo files exist but no .git folder. Script should run: git init + remote + fetch."
    }
    "clone" {
        Write-Host "  Placing update-site.ps1 in empty folder $TestDir ..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
        Copy-Item "C:\host-repo\update-site.ps1" $TestDir
        $label = "SCENARIO: Fresh Clone"
        $detail = "Only the script exists, no repo files. Script should offer to clone from GitHub."
    }
}

# Write a temp setup script that the new terminal window will run
@"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Set-Location '$TestDir'
`$host.UI.RawUI.WindowTitle = '$label'
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
"@ | Set-Content $SetupScript -Encoding UTF8

# Open an interactive PowerShell window pre-positioned in the test directory
Start-Process powershell.exe -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", $SetupScript
