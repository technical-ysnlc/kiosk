# School Quiz Chrome Kiosk for Windows 11

This project configures a Windows computer as a locked-down, single-app school quiz kiosk. Windows automatically signs in to a managed standard account and opens Google Chrome full-screen at:

```text
https://quiz.ysnlc.com/
```

The main installer is:

```text
Setup-SchoolQuizKiosk.ps1
```

The script supports installation, removal, diagnostics, rollback, and repeatable deployment across multiple school computers.

> [!IMPORTANT]
> Test the complete quiz workflow on one computer before deploying it to all seven computers. Modified Windows builds such as GhostSpectre may have removed the Windows Assigned Access components required by kiosk mode.

## Features

- Creates a Windows Assigned Access single-app kiosk.
- Automatically creates and signs in to a managed standard kiosk account.
- Launches Chrome in full-screen kiosk and Incognito modes.
- Opens the configured quiz URL automatically.
- Blocks navigation outside the configured quiz site.
- Disables Chrome downloads, printing, file-selection dialogs, extensions, browser sign-in, synchronization, password saving, autofill, Developer Tools, source viewing, and internal browser pages.
- Installs the official 64-bit Chrome Enterprise MSI when Chrome is not already installed.
- Enables User Account Control when required.
- Reversibly disables the existing standard local account named `YSNLC` by default.
- Refuses to install while another enabled standard local account could still provide a normal Windows desktop.
- Backs up existing Chrome machine policies and any existing Assigned Access configuration.
- Restores the previous configuration when kiosk mode is removed.
- Produces installation logs and detailed diagnostic reports.
- Uses a protected LocalSystem scheduled task to apply the Assigned Access configuration.

## Requirements

The computer should meet all of the following requirements:

- Windows PowerShell 5.1.
- A Windows edition identified by the script as Professional, Enterprise, Education, or IoT Enterprise.
- A working Windows Assigned Access MDM Bridge provider.
- An administrator account with a strong, nonblank password.
- Internet access during installation when Chrome is not already installed.
- Permission to restart the computer after installation or removal.

The script is not intended for Windows Home.

## Important Limitations

### Modified Windows builds

GhostSpectre and other stripped or modified Windows images may remove the `MDM_AssignedAccess` provider or related services. The script can bypass the broken Settings kiosk wizard, but it cannot safely recreate missing operating-system components.

Run diagnostic mode first. When the report contains the following message, the Windows image is missing or cannot access the required provider:

```text
MDM_AssignedAccess class: Missing/unavailable
```

In that situation, the most dependable repair is an official, unmodified installation of Windows 11 Pro, Education, Enterprise, or IoT Enterprise.

### Chrome policies are computer-wide

The Chrome restrictions are written under the computer policy registry location and therefore affect Chrome for every Windows user, including administrators. Use Microsoft Edge for unrestricted administrator browsing while the kiosk is installed.

### The URL allowlist is intentionally strict

The script allows only the HTTPS host and optional path derived from the configured kiosk URL. Authentication pages, redirects, embedded content, or required resources on another hostname may be blocked.

Test every part of the quiz, including sign-in, page transitions, submission, images, audio, and result pages.

### File-upload questions are disabled

Chrome file-selection dialogs are disabled. Quiz questions that require students to upload files will not work without modifying the policy section of the script.

### Kiosk removal does not uninstall Chrome

When Chrome is installed by this script, removing kiosk mode leaves Chrome installed. Existing Chrome policies are restored, but the Chrome application itself is not removed.

### UAC remains enabled

When the script enables User Account Control, kiosk removal does not disable it again. Leaving UAC enabled is recommended.

## Before Installation

1. Confirm that the administrator account has a strong password that students do not know.
2. Back up important files on the computer.
3. Confirm that the quiz site works normally in Chrome.
4. Check whether the quiz redirects to another domain or uses file uploads.
5. Remove or disable unnecessary standard local accounts.
6. Run diagnostic mode.
7. Install and test the kiosk on one computer before repeating the process on the remaining computers.

Do not delete the following folder while the kiosk is installed because it contains the backups required for safe removal:

```text
C:\ProgramData\SchoolQuizKiosk
```

## Quick Start

Copy `Setup-SchoolQuizKiosk.ps1` to the Administrator desktop.

Open **Windows Terminal as Administrator**, then run:

```powershell
$script = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Setup-SchoolQuizKiosk.ps1'
Unblock-File -LiteralPath $script
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $script `
    -Mode Install `
    -Restart
```

A compact one-line version is also available:

```powershell
$k=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Setup-SchoolQuizKiosk.ps1'; Unblock-File -LiteralPath $k; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $k -Mode Install -Restart
```

The script self-elevates when necessary, but starting from an Administrator terminal makes errors and prompts easier to understand.

## What Happens After Restart

After installation and restart:

1. Windows automatically signs in to the managed kiosk account.
2. Chrome starts in full-screen kiosk mode.
3. Chrome opens `https://quiz.ysnlc.com/`.
4. Students do not receive the normal Windows desktop, Start menu, taskbar, or File Explorer interface.
5. Closing the kiosk application should cause Windows Assigned Access to restart it.
6. Restarting the computer returns it to the kiosk automatically.

## Administrator Maintenance

To leave the kiosk for maintenance, press:

```text
Ctrl + Alt + Q
```

Then sign in with the protected administrator account.

Because Chrome policies are computer-wide, use Microsoft Edge for unrestricted administrator browsing while kiosk mode is installed.

## Diagnostic Mode

Run diagnostics before installation or whenever setup fails:

```powershell
$script = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Setup-SchoolQuizKiosk.ps1'
Unblock-File -LiteralPath $script
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $script `
    -Mode Diagnose
```

Diagnostics record:

- Windows product, edition, version, and build.
- UAC status.
- Chrome installation path.
- Presence of the `MDM_AssignedAccess` class.
- Presence of the `Set-AssignedAccess` command.
- Recent Assigned Access event log entries.

Reports are saved as:

```text
C:\ProgramData\SchoolQuizKiosk\Diagnostics-YYYYMMDD-HHMMSS.txt
```

The main installation log is:

```text
C:\ProgramData\SchoolQuizKiosk\Setup.log
```

To view the most recent log entries:

```powershell
Get-Content 'C:\ProgramData\SchoolQuizKiosk\Setup.log' -Tail 100
```

## Remove the Kiosk

Sign in as Administrator and run:

```powershell
$script = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Setup-SchoolQuizKiosk.ps1'
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $script `
    -Mode Remove `
    -Restart
```

One-line version:

```powershell
$k=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Setup-SchoolQuizKiosk.ps1'; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $k -Mode Remove -Restart
```

Removal attempts to:

- Restore the previous Windows Assigned Access configuration.
- Restore the previous Chrome machine policies.
- Re-enable the original `YSNLC` account when it was enabled before installation.
- Remove the managed kiosk account created by Assigned Access.
- Delete the script's active state and configuration files.

Restart Windows after removal even when the `-Restart` switch was not used.

## Custom Configuration

The default configuration is:

```text
URL:                  https://quiz.ysnlc.com/
Display name:         YSNLC School Quiz
Local user disabled:  YSNLC
Breakout sequence:    Ctrl+Alt+Q
```

Install with explicit values:

```powershell
.\Setup-SchoolQuizKiosk.ps1 `
    -Mode Install `
    -Url 'https://quiz.ysnlc.com/' `
    -DisplayName 'YSNLC School Quiz' `
    -DisableLocalUser 'YSNLC' `
    -Restart
```

Use only an HTTPS URL. The script rejects non-HTTPS kiosk addresses.

## Parameter Reference

| Parameter | Accepted values | Default | Purpose |
|---|---|---|---|
| `-Mode` | `Install`, `Remove`, `Diagnose` | `Install` | Selects the operation. |
| `-Url` | HTTPS URL | `https://quiz.ysnlc.com/` | Sets the Chrome start page and URL allowlist. |
| `-DisplayName` | 1 to 64 characters | `YSNLC School Quiz` | Sets the managed kiosk account display name. |
| `-DisableLocalUser` | Local account name or an empty string | `YSNLC` | Disables one existing standard account and records its original state. |
| `-Restart` | Switch | Not set | Restarts Windows automatically after installation or removal. |
| `-Stage` | `Admin`, `System` | `Admin` | Internal implementation parameter. Do not set this manually. |

Passing an empty string to `-DisableLocalUser` skips the named-account disable step:

```powershell
.\Setup-SchoolQuizKiosk.ps1 -Mode Install -DisableLocalUser ''
```

The installation still fails if any enabled non-administrator local account remains. This protects against students selecting another account and reaching a normal desktop.

## Chrome Restrictions Applied

The script writes machine policies under:

```text
HKLM\SOFTWARE\Policies\Google\Chrome
```

The configured restrictions include:

- Browser sign-in disabled.
- Guest mode disabled.
- Incognito mode forced.
- Chrome Sync disabled.
- Password Manager disabled.
- Address and credit-card autofill disabled.
- Developer Tools disabled.
- Extension developer mode restricted.
- Printing disabled.
- Downloads blocked.
- File-selection dialogs disabled.
- Chrome extensions blocked.
- Translation disabled.
- Search suggestions disabled.
- Promotional tabs disabled.
- Startup forced to the quiz URL.
- All URLs blocked except the configured allowlist entry.
- `chrome://`, `chrome-untrusted://`, `devtools://`, `view-source:`, and `file://` pages blocked.

## Changes Made to the Computer

| Change | During removal |
|---|---|
| Enables UAC when it is disabled | UAC remains enabled. |
| Installs Chrome Enterprise when Chrome is missing | Chrome remains installed. |
| Applies Chrome machine policies | Previous Chrome policies are restored. |
| Applies Assigned Access configuration | Previous Assigned Access configuration is restored when available. |
| Disables the configured standard local account | The account is re-enabled only when it was enabled before installation. |
| Creates a managed kiosk account | Matching managed kiosk accounts are removed. |
| Creates `C:\ProgramData\SchoolQuizKiosk` | Active configuration files are cleaned up; logs and the installed script may remain. |

## Backup and Rollback Files

The script may create the following files under `C:\ProgramData\SchoolQuizKiosk`:

| File | Purpose |
|---|---|
| `Setup-SchoolQuizKiosk.ps1` | Protected working copy used by the LocalSystem task. |
| `Setup.log` | Installation, removal, and diagnostic log. |
| `State.json` | Records the active kiosk settings and account state. |
| `AssignedAccess.xml` | Generated Windows Assigned Access configuration. |
| `AssignedAccess-BeforeKiosk.txt` | Backup of an earlier Assigned Access configuration. |
| `AssignedAccess-WasAbsent.marker` | Records that no earlier Assigned Access configuration existed. |
| `ChromePolicies-BeforeKiosk.reg` | Backup of an earlier Chrome policy registry key. |
| `ChromePolicies-WereAbsent.marker` | Records that no earlier Chrome policy key existed. |
| `Diagnostics-*.txt` | Timestamped diagnostic reports. |

Do not manually modify or remove these files while the kiosk is active.

## Deploying to Seven Computers

A practical rollout process is:

1. Put `Setup-SchoolQuizKiosk.ps1` and this `README.md` on a USB drive or shared administrator folder.
2. On the first computer, copy the script to the Administrator desktop.
3. Run `-Mode Diagnose`.
4. Review the diagnostic report for the Assigned Access provider.
5. Run `-Mode Install -Restart`.
6. Complete a real student quiz from start to submission.
7. Confirm that `Ctrl + Alt + Q` returns to administrator maintenance.
8. Confirm that removal works on the test computer, then reinstall it.
9. Repeat the same tested procedure on the remaining six computers.
10. Keep one protected copy of the script and document where the administrator credentials are stored.

Use the same script version on every computer so troubleshooting and removal behavior remain consistent.

## Troubleshooting

### Windows Settings says “Couldn't set up a kiosk”

The script does not rely on the Settings wizard. Run diagnostic mode and inspect the `MDM_AssignedAccess` result.

### `MDM_AssignedAccess class: Missing/unavailable`

The required provider is absent, disabled, damaged, or inaccessible. This is common on heavily modified Windows images. Use a complete official Windows installation or restore the removed Windows components before trying again.

### Unsupported Windows edition

The script stops when the Windows `EditionID` does not match Professional, Enterprise, Education, or IoT Enterprise. Install a supported edition rather than bypassing the safety check.

### Enabled standard local accounts remain

The installer reports the account names that would still provide a normal desktop. Disable or remove those accounts and run the installer again.

To list enabled local users:

```powershell
Get-LocalUser | Where-Object Enabled | Select-Object Name, Enabled, Description
```

### Chrome cannot be downloaded

Check the internet connection, date and time, DNS, proxy, and firewall. Alternatively, install the official 64-bit Chrome Enterprise MSI before running the kiosk installer again.

### The quiz page is blank or blocked

The page may depend on another hostname, authentication provider, content-delivery network, or redirect that is not in the allowlist. Review Chrome behavior on a test computer and adjust the script only after identifying every required domain.

### The kiosk does not sign in automatically

Restart Windows, confirm that UAC is enabled, and review:

```text
C:\ProgramData\SchoolQuizKiosk\Setup.log
C:\ProgramData\SchoolQuizKiosk\Diagnostics-*.txt
```

### PowerShell says the script is blocked

Run:

```powershell
Unblock-File -LiteralPath '.\Setup-SchoolQuizKiosk.ps1'
```

Then launch it with Windows PowerShell 5.1 and `-ExecutionPolicy Bypass` as shown in the examples.

### Installation failed and restrictions remain

The script intentionally leaves Chrome restrictions or a disabled standard account in place when Windows cannot confirm that Assigned Access was rolled back. This avoids exposing an unrestricted desktop during a partial failure.

Keep the `C:\ProgramData\SchoolQuizKiosk` folder intact, review the log and diagnostic report, correct the Assigned Access problem, and then run `-Mode Remove`.

## Security Recommendations

Kiosk mode reduces student access but should be combined with basic physical and administrative security:

- Protect every administrator account with a strong password.
- Do not share administrator credentials with students.
- Set a UEFI or BIOS administrator password.
- Disable booting from USB and other external devices when practical.
- Enable BitLocker or equivalent full-disk encryption where available.
- Keep Windows and Chrome updated.
- Physically secure desktop cases, network cables, and reset controls.
- Use network-level filtering when the quiz network must block unrelated internet services.
- Keep a tested recovery procedure and a copy of the kiosk removal script.

This script is a Windows user-interface and browser lockdown tool. It is not a replacement for full-disk encryption, physical security, network controls, backups, or official examination supervision.

## Script Version and Integrity

Documented script version:

```text
1.3.2
```

SHA-256 for the accompanying `Setup-SchoolQuizKiosk.ps1` file:

```text
1b2f2dc9be7f6c1aece4090000076605b44b657e8c2654ea153912de734edace
```

Verify the file with:

```powershell
(Get-FileHash '.\Setup-SchoolQuizKiosk.ps1' -Algorithm SHA256).Hash
```

The returned hash should match the value above before the script is deployed to the computers.
