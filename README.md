# YSNLC Student Apps — Windows 11 Restricted Workstation

This project configures a Windows 11 school computer with a restricted student account named **YSNLC App User**.

The student Start menu contains only the school apps that are available on the computer:

- **YSNLC Quiz App** → opens Google Chrome at `https://quiz.ysnlc.com/`
- **Microsoft Word**
- **Microsoft Excel**
- **Microsoft PowerPoint**
- **Student Files** → opens the student's **Downloads** folder

Word, Excel, and PowerPoint are detected automatically. If an Office app is not installed, it is simply not shown.

The Administrator account remains a normal Windows account. The script does **not** apply machine-wide Chrome URL blocking. Use the existing hosts/network blocker for website filtering.

## Before Installing

1. Use Windows 11 Pro, Education, Enterprise, or IoT Enterprise.
2. Set a strong password on every Administrator account.
3. Install Microsoft Office / Microsoft 365 first if Word, Excel, and PowerPoint are required.
4. Make sure the computer has internet access.
5. Test this on **one computer first** before deploying to the other six.

> GhostSpectre is a modified Windows build. The script repairs disabled kiosk services when possible, but it cannot restore Windows components that were completely removed.

## Files in the GitHub Repository

```text
kiosk/
├── install.ps1
├── setup.ps1
├── Update-SchoolQuizKiosk.ps1
├── update.json
├── README.md
└── .github/
    └── workflows/
        └── update-manifest.yml
```

For the v2 update, replace/upload these files:

```text
setup.ps1
install.ps1
README.md
.github/workflows/update-manifest.yml
```

Keep `Update-SchoolQuizKiosk.ps1` as it is.

Do **not** manually edit `update.json`. GitHub Actions generates it.

## Publish the Update

1. Upload the replacement files to the paths shown above.
2. Commit them to `main`.
3. Open **GitHub → Actions**.
4. Wait for **Update kiosk manifest** to finish successfully.
5. Confirm `update.json` shows version `2.0.0` and a 40-character `sourceCommit`.

## Fresh Installation

Sign in as Administrator, open PowerShell or Windows Terminal, and run:

```powershell
irm https://raw.githubusercontent.com/technical-ysnlc/kiosk/main/install.ps1 | iex
```

Approve the UAC prompt. The installer verifies the published scripts, installs the restricted student experience, installs the updater task, and schedules a restart.

## Upgrading an Existing v1.x Kiosk

Version 2.0 changes from a single-app kiosk to a multi-app restricted student experience, so it is intentionally **not applied automatically** over an active v1.x kiosk.

First leave the old kiosk and sign in as Administrator. Then run:

```powershell
$k='C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1'; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $k -Mode Remove -Restart
```

After Windows restarts, sign in as Administrator and run the normal installer:

```powershell
irm https://raw.githubusercontent.com/technical-ysnlc/kiosk/main/install.ps1 | iex
```

## What Students Will See

After restart, Windows automatically signs in to **YSNLC App User**.

The restricted Start menu provides the allowed apps. Windows Assigned Access/AppLocker prevents the student account from running unapproved apps such as Command Prompt, PowerShell, Registry Editor, or other desktop programs.

**Student Files** opens File Explorer with the Assigned Access namespace restricted to **Downloads**. Students can save Office work there and select those files from Chrome when uploading to Gmail, Google Drive, or another allowed website.

The YSNLC Quiz App shortcut opens Chrome at:

```text
https://quiz.ysnlc.com/
```

Chrome opens in Incognito mode for the student session. Website access is controlled by your hosts/network filtering, not by machine-wide Chrome policies.

## Administrator Maintenance

For the multi-app student experience, use:

```text
Ctrl + Alt + Del
```

Choose **Sign out**, then sign in with the Administrator account.

Administrator Chrome and File Explorer remain normal.

## Remove the Restricted Student Experience

Sign in as Administrator and run:

```powershell
$k='C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1'; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $k -Mode Remove -Restart
```

## Troubleshooting

Run diagnostics:

```powershell
$k='C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1'; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $k -Mode Diagnose
```

Logs are stored in:

```text
C:\ProgramData\SchoolQuizKiosk\Setup.log
C:\ProgramData\SchoolQuizKiosk\Diagnostics-*.txt
C:\ProgramData\SchoolQuizKiosk\Updater.log
```

If `AssignedAccessManagerSvc` or `AppIDSvc` is missing completely, use an official unmodified Windows 11 installation. The script can enable a disabled service but cannot recreate a service removed from the Windows image.

## Deployment

After the first computer passes testing, use the same one-line installer on the remaining six computers:

```powershell
irm https://raw.githubusercontent.com/technical-ysnlc/kiosk/main/install.ps1 | iex
```
