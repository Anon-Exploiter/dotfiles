#!/usr/bin/env pwsh

function Log-Info {
    param ([string]$Message)
    Write-Host "[INFO] $Message"
}

function Log-Warn {
    param ([string]$Message)
    Write-Host "[WARN] $Message"
}

# Re-run under admin for system tasks
if (-not [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$TargetUser = if ($env:TARGET_USER) { $env:TARGET_USER } else { $env:SUDO_USER -or [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
$UserHome = [System.Environment]::GetFolderPath('UserProfile')

# -----------------------
# Minified helpers
# -----------------------
function Secure-SudoersFile {
    param ([string]$FilePath)

    if (-not $FilePath -or -not (Test-Path $FilePath)) { return 1 }

    $Backup = "$FilePath.bak.$([int](Get-Date -UFormat %s))"
    Copy-Item $FilePath $Backup -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $FilePath -Name Owner -Value "root" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $FilePath -Name Permissions -Value "0440" -ErrorAction SilentlyContinue

    # Note: 'visudo' equivalent operation might need to be handled differently in PowerShell
    # Here we can only check if the file is accessible or readable
    if (-not (Test-Path $FilePath)) {
        Log-Warn "visudo failed for $FilePath; restoring"
        if (Test-Path $Backup) { Move-Item $Backup $FilePath -Force }
        return 1
    }
}