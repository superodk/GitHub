<#
.SYNOPSIS
    Runs one or more programs with Smart App Control temporarily turned off.

.DESCRIPTION
    Self-elevates, turns Smart App Control (SAC) off if it is on, starts each program
    and waits for it to exit, then tries to restore SAC.

    WARNING: on Windows 11, SAC normally only goes On -> Off. Once it is off, it usually
    cannot be turned back on without resetting Windows, so the restore step is best-effort.

.PARAMETER Program
    One or more paths to executables. Relative paths are resolved from the current folder.

.PARAMETER Force
    Skip the confirmation prompt before turning Smart App Control off.

.EXAMPLE
    .\Start-WithSacOff.ps1 .\dControl.exe

.EXAMPLE
    .\Start-WithSacOff.ps1 -Program .\a.exe, 'C:\Tools\b.exe' -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Program,

    [switch]$Force,

    # Set internally when the script relaunches itself elevated.
    [Parameter(DontShow)]
    [switch]$Relaunched
)

$ErrorActionPreference = 'Stop'

# Resolve and validate every path before elevating or touching SAC. The elevated
# session starts in System32, so relative paths have to be made absolute here.
$Program = foreach ($p in $Program) {
    $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer) { throw "Program not found: $p" }
    $item.FullName
}

function ConvertTo-QuotedLiteral([string]$Text) {
    "'" + ($Text -replace "'", "''") + "'"
}

# --- Self-elevate in the same PowerShell host -------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # -File can't pass a string[] and mangles quotes, so send an encoded command instead.
    $programList = ($Program | ForEach-Object { ConvertTo-QuotedLiteral $_ }) -join ','
    $command = "& $(ConvertTo-QuotedLiteral $PSCommandPath) -Program $programList -Relaunched"
    if ($Force) { $command += ' -Force' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

    Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
    )
    exit
}

# --- Smart App Control helpers ----------------------------------------------------
$policyKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
$policyName = 'VerifiedAndReputablePolicyState'   # 0 = Off, 1 = On, 2 = Evaluation
$stateNames = @{ 0 = 'Off'; 1 = 'On'; 2 = 'Eval' }

function Get-SacState {
    # Prefer Defender's view; fall back to the registry if Defender isn't available.
    try {
        (Get-MpComputerStatus).SmartAppControlState
    } catch {
        $value = (Get-ItemProperty -Path $policyKey -Name $policyName -ErrorAction SilentlyContinue).$policyName
        if ($null -eq $value) { 'Unknown' } else { $stateNames[[int]$value] }
    }
}

function Set-SacState([int]$Value) {
    Set-ItemProperty -Path $policyKey -Name $policyName -Value $Value -Type DWord
    'Y' | citool.exe --refresh | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "citool --refresh exited with code $LASTEXITCODE" }
}

# --- Main -------------------------------------------------------------------------
$initialState = Get-SacState
$turnedOff = $false
$exitCode = 0
Write-Host "Smart App Control: $initialState"

try {
    if ($initialState -in 'On', 'Eval') {
        if (-not $Force) {
            Write-Warning 'Turning Smart App Control off is usually permanent. Windows may not let you turn it back on without a reset.'
            if ((Read-Host 'Continue? [y/N]') -notmatch '^(y|yes)$') {
                Write-Host 'Cancelled.'
                return
            }
        }

        Write-Host 'Turning Smart App Control off...'
        $turnedOff = $true
        Set-SacState 0

        $state = Get-SacState
        if ($state -ne 'Off') { throw "Smart App Control is still '$state'. A reboot may be required." }
        Write-Host 'Smart App Control is off.'
    }

    foreach ($path in $Program) {
        Write-Host "Starting $path"
        Start-Process -FilePath $path -WorkingDirectory (Split-Path -Parent $path) -Wait
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    # Runs even if a launch failed, so SAC is never left changed without an attempt to restore it.
    if ($turnedOff) {
        Write-Host 'Trying to turn Smart App Control back on...'
        try {
            Set-SacState (@{ On = 1; Eval = 2 }[$initialState])
            $finalState = Get-SacState
            if ($finalState -eq $initialState) {
                Write-Host "Smart App Control restored to $finalState."
            } else {
                Write-Warning "Smart App Control is now '$finalState', not '$initialState'. Windows normally doesn't allow turning it back on without a reset."
            }
        } catch {
            Write-Host "ERROR restoring Smart App Control: $($_.Exception.Message)" -ForegroundColor Red
            $exitCode = 1
        }
    }

    # The elevated window closes on exit, so give a chance to read the output.
    if ($Relaunched) { Read-Host 'Press Enter to close' | Out-Null }
}

exit $exitCode
