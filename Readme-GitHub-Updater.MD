# School Quiz Chrome Kiosk for Windows 11

This project configures a Windows computer as a locked-down, single-app school quiz kiosk. Windows automatically signs in to a managed standard account and opens Google Chrome full-screen at:

```text
https://quiz.ysnlc.com/
```

The GitHub source installer is:

```text
setup.ps1
```

During installation, it is copied to the protected Windows working path:

```text
C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1
```

The optional updater is:

```text
Update-SchoolQuizKiosk.ps1
```

The installer supports installation, removal, diagnostics, rollback, and repeatable deployment across multiple school computers. The updater can keep the protected management-script copy synchronized with verified updates published in this repository.

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
- Optionally installs a separate LocalSystem updater task that verifies and updates the protected management script from GitHub.

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

Download the repository file `setup.ps1` to the Administrator desktop and save or rename it as `Setup-SchoolQuizKiosk.ps1`.

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

## Automatic GitHub Updater

Add these files to the repository at the exact paths shown:

```text
Update-SchoolQuizKiosk.ps1
update.json
.github/workflows/update-manifest.yml
```

Keep the existing `setup.ps1` in the repository root. Replace `Readme.MD` with this updated documentation.

The workflow watches both PowerShell scripts. When either script changes, it validates PowerShell syntax, reads the embedded version, calculates SHA-256, and refreshes `update.json`. The published URLs are pinned to one exact Git commit containing both scripts.

`Update-SchoolQuizKiosk.ps1` then checks `update.json`, downloads the published `setup.ps1`, verifies its repository path, source commit, SHA-256, PowerShell syntax, and embedded `$KioskVersion`, creates a rotating backup, and replaces the protected management copy at:

```text
C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1
```

> [!IMPORTANT]
> The updater changes the **protected management script only**. It does not change a copy left on the Administrator desktop, update itself automatically, remove or reinstall the kiosk, reapply Chrome policies, replace the active Assigned Access profile, or restart Windows. This prevents an untested configuration change from being applied automatically to all seven computers.

> [!CAUTION]
> The manifest and scripts are controlled by the same GitHub repository. Hash checking detects corrupted, incomplete, stale, mismatched, and locally modified files, but it is not an independent digital signature. Protect the GitHub account with multi-factor authentication, restrict repository write access, and review commits before deployment.

### Prepare the GitHub repository

1. Upload `Update-SchoolQuizKiosk.ps1` and `update.json` to the repository root.
2. Create `.github/workflows/update-manifest.yml` using that complete path.
3. Replace `Readme.MD` with the updated file.
4. Commit the files to `main`.
5. Open the **Actions** tab and wait for **Update kiosk manifest** to finish successfully.
6. Open the generated `update.json` and confirm that `sourceCommit` contains 40 hexadecimal characters and both download URLs contain that same commit ID.

The workflow needs `contents: write` permission so it can commit the generated manifest. If its final push is rejected, review **Settings → Actions → General → Workflow permissions**, branch protection, and repository rules.

Do not install the automatic updater on the seven desktops until the workflow is green and the complete process has been tested on one computer.

### Install the updater from a desktop copy

Copy `Update-SchoolQuizKiosk.ps1` to the Administrator desktop. Open **Windows Terminal as Administrator**, then run:

```powershell
$u=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Update-SchoolQuizKiosk.ps1'; Unblock-File -LiteralPath $u; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $u -Mode InstallTask
```

This command:

1. Copies the updater to `C:\ProgramData\SchoolQuizKiosk`.
2. Creates a LocalSystem scheduled task named `SchoolQuizKiosk-Updater`.
3. Checks immediately for a published installer update.
4. Checks whenever the computer starts.
5. Checks every day at 03:00 and starts later if that scheduled time was missed.

Run the same command once on each desktop after the first-computer test succeeds.

### Verified installation directly from GitHub

After the workflow has generated a commit-pinned manifest, an administrator can download and verify the updater without first copying it to the desktop:

```powershell
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows Terminal as Administrator before running this command.'
}

$manifestUrl = 'https://raw.githubusercontent.com/technical-ysnlc/kiosk/main/update.json'
$manifest = ((Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing -TimeoutSec 60).Content | ConvertFrom-Json)

if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.productId -ne 'school-quiz-kiosk') {
    throw 'Unexpected or unsupported update manifest.'
}
if ([string]$manifest.sourceCommit -notmatch '^[A-Fa-f0-9]{40}$') {
    throw 'The manifest does not contain a full source commit.'
}
if ([string]$manifest.updaterVersion -notmatch '^\d+(?:\.\d+){2,3}$') {
    throw 'The updater version is invalid.'
}
if ([string]$manifest.updaterSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
    throw 'The updater SHA-256 value is invalid.'
}

$expectedUrl = "https://raw.githubusercontent.com/technical-ysnlc/kiosk/$($manifest.sourceCommit)/Update-SchoolQuizKiosk.ps1"
if (-not ([string]$manifest.updaterUrl).Equals($expectedUrl, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The updater URL does not match the manifest source commit.'
}

$updater = Join-Path $env:TEMP ("Update-SchoolQuizKiosk-{0}.ps1" -f ([Guid]::NewGuid().ToString('N')))
try {
    Invoke-WebRequest -Uri $expectedUrl -UseBasicParsing -TimeoutSec 60 -OutFile $updater

    $actualHash = (Get-FileHash -LiteralPath $updater -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne ([string]$manifest.updaterSha256).ToLowerInvariant()) {
        throw "Updater verification failed. Expected $($manifest.updaterSha256), received $actualHash."
    }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($updater, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw (($parseErrors | ForEach-Object Message) -join '; ')
    }

    $content = Get-Content -LiteralPath $updater -Raw -Encoding UTF8
    $versionMatch = [regex]::Match(
        $content,
        '(?m)^\s*\$UpdaterVersion\s*=\s*''(?<version>\d+(?:\.\d+){2,3})''\s*$'
    )
    if (-not $versionMatch.Success -or $versionMatch.Groups['version'].Value -ne [string]$manifest.updaterVersion) {
        throw 'The downloaded updater version does not match the manifest.'
    }

    $firstLine = Get-Content -LiteralPath $updater -TotalCount 1 -Encoding UTF8
    if ($firstLine -notmatch '^#requires\s+-Version\s+5\.1') {
        throw 'The downloaded updater does not declare Windows PowerShell 5.1.'
    }

    Unblock-File -LiteralPath $updater
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $updater `
        -Mode InstallTask

    if ($LASTEXITCODE -ne 0) {
        throw "Updater installation returned exit code $LASTEXITCODE."
    }
} finally {
    Remove-Item -LiteralPath $updater -Force -ErrorAction SilentlyContinue
}
```

### Update policy

The scheduled task automatically accepts a newer installer within the same major version, such as `1.3.2` to `1.4.0`. A major-version update, such as `1.x` to `2.x`, is recorded as requiring administrator review and is not installed unless `-Force` is used. A downgrade requires `-AllowDowngrade`; a major-version downgrade requires both `-AllowDowngrade` and `-Force`.

A local protected script whose embedded version cannot be read is not replaced automatically. A same-version SHA-256 mismatch is also treated as suspicious rather than repaired silently. In either case, an administrator must inspect the file and use `-Force` to approve replacement.

### Check without installing an update

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File 'C:\ProgramData\SchoolQuizKiosk\Update-SchoolQuizKiosk.ps1' `
    -Mode Check
```

### Update the protected script immediately

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File 'C:\ProgramData\SchoolQuizKiosk\Update-SchoolQuizKiosk.ps1' `
    -Mode Update
```

For a reviewed major-version update:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File 'C:\ProgramData\SchoolQuizKiosk\Update-SchoolQuizKiosk.ps1' `
    -Mode Update `
    -Force
```

### Show updater status

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File 'C:\ProgramData\SchoolQuizKiosk\Update-SchoolQuizKiosk.ps1' `
    -Mode Status
```

### Remove the updater task

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File 'C:\ProgramData\SchoolQuizKiosk\Update-SchoolQuizKiosk.ps1' `
    -Mode RemoveTask
```

Updater records are stored under:

```text
C:\ProgramData\SchoolQuizKiosk\Updater.log
C:\ProgramData\SchoolQuizKiosk\UpdaterState.json
C:\ProgramData\SchoolQuizKiosk\Updates\
```

The `Updates` folder keeps the newest five backups by default.

### Update the updater itself

The updater intentionally does not replace its own running file automatically. To install a reviewed newer updater:

1. Wait for the workflow to publish the new `updaterVersion`, `updaterUrl`, and `updaterSha256` values.
2. Test the new updater on one computer using the verified GitHub installation command above.
3. Running the new file with `-Mode InstallTask` replaces the installed updater copy and re-registers the scheduled task.
4. Repeat on the remaining computers after the test succeeds.

### Publish a new installer version

1. Edit `setup.ps1`.
2. Increase `$KioskVersion`; never publish different content under an existing version.
3. Commit and push the change to `main`.
4. Wait for **Update kiosk manifest** to finish successfully.
5. Review the generated installer version, source commit, URL, and SHA-256 in `update.json`.
6. Check or update the test desktop first.
7. Allow the remaining computers to receive the tested same-major-version script at their next scheduled check.

The workflow rejects a changed installer hash unless `$KioskVersion` was increased. It applies the same rule to `$UpdaterVersion` when the updater file changes.

### Applying configuration changes from a new installer

Replacing the protected management script does not change the already-running Assigned Access profile or Chrome policies. When a new installer changes kiosk behavior:

1. Test the new version on one desktop first.
2. Leave kiosk mode with `Ctrl + Alt + Q` and sign in as Administrator.
3. Review the change and the updater backup.
4. Use the tested maintenance process to remove and reinstall the kiosk when the configuration change requires it.
5. Deploy the tested configuration to the other six computers.

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

After installation, run maintenance, diagnostics, and removal from the protected copy below so the updated version is used:

```text
C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1
```

Do not use an older copy left on the Administrator desktop. Running an old installer can overwrite the protected working copy when it starts a LocalSystem operation.

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

Before installation, the desktop copy is appropriate. After installation, use `C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1` so diagnostics run with the latest verified management-script version.

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

Sign in as Administrator and run the protected working copy, which may have been updated automatically:

```powershell
$script = 'C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1'
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $script `
    -Mode Remove `
    -Restart
```

One-line version:

```powershell
$k='C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1'; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $k -Mode Remove -Restart
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
| `Update-SchoolQuizKiosk.ps1` | Installed updater used by the scheduled task. |
| `Updater.log` | Updater checks, downloads, validation, and error log. |
| `UpdaterState.json` | Last installed and available version/hash status. |
| `Updates\*.backup.ps1` | Rotating backups of earlier management-script versions. |

Do not manually modify or remove these files while the kiosk is active.

## Deploying to Seven Computers

A practical rollout process is:

1. Download or rename the repository file `setup.ps1` as `Setup-SchoolQuizKiosk.ps1` for the Administrator desktop.
2. Put the installer, `Update-SchoolQuizKiosk.ps1`, and this `README.md` on a USB drive or protected administrator share.
3. On the first computer, copy the installer to the Administrator desktop.
4. Run `-Mode Diagnose`.
5. Review the diagnostic report for the Assigned Access provider.
6. Run `-Mode Install -Restart`.
7. After a successful installation, archive or delete the desktop installer so an obsolete copy is not used for later maintenance.
8. Complete a real student quiz from start to submission.
9. Confirm that `Ctrl + Alt + Q` returns to administrator maintenance.
10. Confirm that removal works on the test computer, then reinstall it.
11. Install the updater task and verify `-Mode Status`.
12. Repeat the same tested procedure on the remaining six computers.
13. Keep protected recovery copies and document where the administrator credentials are stored.

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

The repository `update.json` file is the machine-readable source of truth for the current installer and updater versions, source URLs, and SHA-256 values. The copy in this upload package is a **bootstrap manifest** whose URLs use the `main` branch and whose `sourceCommit` value is empty. After the first successful workflow run, GitHub Actions replaces it with a manifest whose two script URLs are pinned to one exact 40-character Git commit.

Package versions and hashes:

| File | Embedded version | SHA-256 |
|---|---:|---|
| `setup.ps1` | `1.3.2` | `1b2f2dc9be7f6c1aece4090000076605b44b657e8c2654ea153912de734edace` |
| `Update-SchoolQuizKiosk.ps1` | `1.0.0` | `fae806722bca7ead9eadb71cd2ea9a2f346abd8ec70c691d6ffb664eefdecdf8` |

Verify a local repository checkout against `update.json`:

```powershell
$manifest = Get-Content '.\update.json' -Raw | ConvertFrom-Json
$setupHash = (Get-FileHash '.\setup.ps1' -Algorithm SHA256).Hash.ToLowerInvariant()
$updaterHash = (Get-FileHash '.\Update-SchoolQuizKiosk.ps1' -Algorithm SHA256).Hash.ToLowerInvariant()

if ($setupHash -ne ([string]$manifest.sha256).ToLowerInvariant()) {
    throw "setup.ps1 failed verification. Expected $($manifest.sha256), received $setupHash."
}
if ($updaterHash -ne ([string]$manifest.updaterSha256).ToLowerInvariant()) {
    throw "Update-SchoolQuizKiosk.ps1 failed verification. Expected $($manifest.updaterSha256), received $updaterHash."
}

"Verified setup.ps1 $($manifest.version): $setupHash"
"Verified updater $($manifest.updaterVersion): $updaterHash"
```

Whenever `setup.ps1` changes, increase `$KioskVersion`. Whenever `Update-SchoolQuizKiosk.ps1` changes, increase `$UpdaterVersion`. The workflow rejects changed script content when the corresponding embedded version was not increased.

