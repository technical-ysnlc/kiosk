# YSNLC Student Apps — Windows 11 Restricted Workstation

This project configures a Windows 11 school computer with a restricted student account named **YSNLC App User**.

The student Start menu contains only the school apps that are available on the computer:

- **YSNLC Quiz App** → opens Google Chrome at `https://quiz.ysnlc.com/`
- **Microsoft Word**
- **Microsoft Excel**
- **Microsoft PowerPoint**
- **Student Files** → opens the student's **Downloads** folder

Word, Excel, and PowerPoint are detected automatically. If an Office app is not installed, it is simply not shown.

The Administrator account remains a normal Windows account, but the kiosk applies device-wide filtering: a Windows hosts-file block for common generative-AI websites and a Chrome policy that restricts YouTube to the school channel and its approved video IDs. These restrictions also affect Administrator browsers until the kiosk is removed.

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

On an already-installed 2.x kiosk, run the same one-line installer again as Administrator to apply app mode and refresh the AI/YouTube filters without reinstalling Assigned Access. Close all Chrome windows and reopen **YSNLC Quiz App** after the update.

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

Chrome opens the quiz in an Incognito **app window**, removing the normal address bar and tab strip. This provides a one-page app-style experience, although Chrome does not offer a strict maximum-tab policy.

The installer blocks common AI services—including ChatGPT, Gemini, Claude, Copilot, Perplexity, Grok, DeepSeek, Poe, and others—through a clearly marked section in the Windows hosts file.

General YouTube navigation is blocked by a device-wide Chrome policy. The school channel `UCnO2_eea5GNawtwjJunEXVg` and its known video IDs are allowed. A daily scheduled task reads the channel's public YouTube feed, adds newly published video IDs, and retains previously approved IDs. Because the public feed contains only recent uploads, videos older than the initial approved baseline may need to be added manually if they are not already remembered.

Hosts-file filtering only matches listed hostnames and cannot automatically cover every new AI site, alternate domain, VPN, proxy, or mobile hotspot. For stronger enforcement, combine the kiosk with managed DNS/firewall filtering and test the required school websites before deployment.

## Administrator Maintenance

For the multi-app student experience, use:

```text
Ctrl + Alt + Del
```

Choose **Sign out**, then sign in with the Administrator account.

Administrator File Explorer remains normal. Administrator Chrome is subject to the same AI and YouTube restrictions. Removing the kiosk removes only the marked SchoolQuizKiosk hosts block, removes the YouTube refresh task, and restores the Chrome policy backup.

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
