# Scripts

Personal PowerShell scripts.

## Start-WithSacOff.ps1

Runs one or more programs with Smart App Control temporarily turned off. It elevates
itself, turns Smart App Control off if it is on, starts each program and waits for it
to close, then tries to turn Smart App Control back on.

> **Warning:** on Windows 11, Smart App Control normally only goes from On to Off.
> Once it is off, it usually can't be turned back on without resetting Windows, so the
> restore step is best-effort. The script asks before making the change unless you pass
> `-Force`.

### Usage

```powershell
.\Start-WithSacOff.ps1 .\dControl.exe
.\Start-WithSacOff.ps1 -Program .\a.exe, 'C:\Tools\b.exe'
.\Start-WithSacOff.ps1 .\dControl.exe -Force    # skip the confirmation prompt
Get-Help .\Start-WithSacOff.ps1 -Full
```

Program paths can be relative to the current folder or absolute. Programs found only
on `PATH` (like plain `notepad.exe`) need a full path.

### Testing

Steps 1 to 3 don't change anything. Step 4 is the one that turns Smart App Control off.

**1. Check the current state** (read-only):

```powershell
(Get-MpComputerStatus).SmartAppControlState
```

**2. Bad path.** Should stop with `Program not found`, with no UAC prompt:

```powershell
.\Start-WithSacOff.ps1 .\nope.exe
```

**3. Elevation and multiple programs.** Click Yes on UAC.

```powershell
.\Start-WithSacOff.ps1 C:\Windows\notepad.exe, C:\Windows\System32\calc.exe
```

- If Smart App Control is **On** or **Eval**: answer `n` at the prompt. You should see
  `Cancelled`, then `Press Enter to close`. Nothing changes.
- If Smart App Control is already **Off**: no prompt. Notepad opens, and Calculator
  opens after you close Notepad.

**4. Real run** (one-way if Smart App Control is on):

```powershell
.\Start-WithSacOff.ps1 .\dControl.exe
```

Answer `y`. Expect `Smart App Control is off.`, then the program starts. After it
closes, the restore step will most likely print a warning that Smart App Control is now
`Off` rather than restored. That's Windows refusing the change, not a script error.
