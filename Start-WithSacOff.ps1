param(
    [Parameter(Mandatory)]
    [string[]]$Program
)

$ErrorActionPreference = 'Stop'

# --- Self-elevate, relaunching the SAME PowerShell host, arguments quoted ---
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $hostExe  = (Get-Process -Id $PID).Path
    $progArgs = ($Program | ForEach-Object { "`"$_`"" }) -join ','
    $argList  = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Program', $progArgs
    )
    Start-Process -FilePath $hostExe -ArgumentList $argList -Verb RunAs
    exit
}

$policyKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
$policyVal = 'VerifiedAndReputablePolicyState'   # 0 = Off, 1 = On, 2 = Evaluation

function Get-SacState { (Get-MpComputerStatus).SmartAppControlState }
function Invoke-CiRefresh {
    'Y' | citool.exe --refresh | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "citool --refresh exited with $LASTEXITCODE" }
}

$initialState = Get-SacState
Write-Output "Smart App Control is currently: $initialState"
$changedSac = $false

if ($initialState -in 'On', 'Eval') {
    Write-Output 'Turning Smart App Control off...'
    Set-ItemProperty -Path $policyKey -Name $policyVal -Value 0 -Type DWord
    Invoke-CiRefresh
    $changedSac = $true

    if ((Get-SacState) -ne 'Off') {
        Write-Error "Failed to turn Smart App Control off (state: $(Get-SacState)). A reboot may be required."
        exit 1
    }
    Write-Output 'Smart App Control is off.'
}

# --- Launch each program and wait for it to close before restoring SAC ---
foreach ($p in $Program) {
    $full = (Resolve-Path -LiteralPath $p).Path
    Write-Output "Starting $full ..."
    Start-Process -FilePath $full -WorkingDirectory (Split-Path -Parent $full) -Wait
}

# --- Best-effort restore (note: On->Off is usually one-way on Windows 11) ---
if ($changedSac) {
    Write-Output 'Attempting to turn Smart App Control back on...'
    $restore = if ($initialState -eq 'Eval') { 2 } else { 1 }
    Set-ItemProperty -Path $policyKey -Name $policyVal -Value $restore -Type DWord
    Invoke-CiRefresh

    $finalState = Get-SacState
    if ($finalState -eq $initialState) {
        Write-Output "Smart App Control restored to $finalState."
    } else {
        Write-Warning "Smart App Control is now '$finalState', not '$initialState'. Windows normally does not allow re-enabling it without a reset."
    }
}
