# YSNLC Student Apps — Windows 11 Restricted Workstation

This project configures a Windows 11 school computer with a restricted student account named **YSNLC App User**.

The student Start menu contains only the school apps that are available on the computer:

- **YSNLC Quiz App** → opens Google Chrome at `https://quiz.ysnlc.com/`
- **YSNLC YouTube Channel** → opens the approved school channel in a Chrome app window
- **Microsoft Word**
- **Microsoft Excel**
- **Microsoft PowerPoint**
- **Student Files** → opens the student's **Downloads** folder
- **Uchida-Kraepelin** → plays `Downloads\uchida-kraepelin.mp4` from the actual Windows-managed kiosk profile in VLC

Word, Excel, and PowerPoint are detected automatically. If an Office app is not installed, it is simply not shown.

The Administrator account remains a normal Windows account, but the kiosk applies device-wide filtering: a Windows hosts-file block for common generative-AI websites and a Chrome policy that restricts YouTube to the school channel and its approved video IDs. These restrictions also affect Administrator browsers until the kiosk is removed.

## Before Installing

1. Use Windows 11 Pro, Education, Enterprise, or IoT Enterprise.
2. Set a strong password on every Administrator account.
3. Install Microsoft Office / Microsoft 365 first if Word, Excel, and PowerPoint are required.
4. Make sure the computer has internet access.
5. If the computer uses Wi-Fi, connect the intended network successfully as Administrator before installing.
6. Test this on **one computer first** before deploying to the other six.

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
5. Confirm `update.json` shows version `2.7.0` and a 40-character `sourceCommit`.

## Fresh Installation

Sign in as Administrator, open PowerShell or Windows Terminal, and run:

```powershell
irm https://raw.githubusercontent.com/technical-ysnlc/kiosk/main/install.ps1 | iex
```

Approve the UAC prompt. The installer verifies the published scripts, installs the restricted student experience, installs the updater task, and schedules a restart.

On an already-installed 2.x kiosk, run the same one-line installer again as Administrator to apply app mode, refresh the AI/YouTube filters, install or verify VLC, download the verified offline video, and update Assigned Access when needed. Sign out and back in as the student, or restart Windows, after the update.

## Offline Uchida-Kraepelin Video

Version 2.7.0 configures the media automatically:

1. If VLC is missing, the installer downloads the official VideoLAN 3.0.23 64-bit MSI, verifies its pinned SHA-256 checksum, and installs it for all users.
2. After Windows creates the managed Assigned Access account, the script looks up that account by SID and asks Windows for its registered profile path.
3. It creates that profile's `Downloads` folder if needed, downloads `uchida-kraepelin.mp4` from the YSNLC Nextcloud public share, and verifies both the exact file size and pinned SHA-256 checksum before replacing any existing copy.
4. It creates the **Uchida-Kraepelin** shortcut using the path Windows actually returned, then allows and pins VLC in Assigned Access.

There is no fixed `C:\Users\KioskUser0` path in this media workflow. If Windows chooses `KioskUser0`, `KioskUser0.YS-LAB-CPU-3`, or another profile directory—even on another drive—the MP4 and shortcut use that exact profile. A computer rename therefore does not require changing the script.

The 131,249,563-byte MP4 is intentionally kept on the YSNLC Nextcloud server rather than committed to this Git repository; it exceeds GitHub's 100 MiB limit for an ordinary Git file. The installer uses the public share's direct WebDAV endpoint, not the browser preview page.

After publishing version 2.7.0 and waiting for the manifest workflow to finish, run the normal one-line installer as Administrator. Sign out and back in as the student, or restart Windows. Open **Uchida-Kraepelin** from Start to play the local file offline.

The shortcut targets VLC directly with the quoted MP4 path as its argument, so changing Windows' default `.mp4` app is unnecessary. VLC is added to the kiosk's allowed apps. This allows the VLC application, not just this one file. The existing Downloads-only File Explorer restriction is retained.

To apply only the media change with a locally downloaded copy of the updated `setup.ps1`, open PowerShell in that file's folder as Administrator and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Mode Media
```

If the automatic updater has already downloaded version 2.7.0 or later, use the installed copy:

```powershell
$k='C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1'; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $k -Mode Media
```

The automatic updater replaces the management script; it does not apply this configuration change by itself. Media mode installs or verifies VLC, downloads and verifies the MP4, and resolves the profile directory from the kiosk account SID. If the account has not materialized yet, restart Windows and rerun the one-line installer.

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

The **YSNLC YouTube Channel** shortcut opens `https://www.youtube.com/@ysnlc_yt/videos` in its own Chrome app window. The channel's **Videos** and **Playlists** sections are allowed, but the shortcut uses **Videos** so students can see every published upload. On an existing kiosk, the maintenance update refreshes the Assigned Access Start pins so this sixth shortcut appears after the student signs out and back in or Windows restarts.

The installer blocks common AI services—including ChatGPT, Gemini, Claude, Copilot, Perplexity, Grok, DeepSeek, Poe, and others—through a clearly marked section in the Windows hosts file.

General YouTube navigation is blocked by a device-wide Chrome policy. The school channel `UCnO2_eea5GNawtwjJunEXVg` and its known video IDs are allowed. A daily scheduled task reads the channel's public YouTube feed, adds newly published video IDs, and retains previously approved IDs. Because the public feed contains only recent uploads, videos older than the initial approved baseline may need to be added manually if they are not already remembered.

Hosts-file filtering only matches listed hostnames and cannot automatically cover every new AI site, alternate domain, VPN, proxy, or mobile hotspot. For stronger enforcement, combine the kiosk with managed DNS/firewall filtering and test the required school websites before deployment.

## Wireless Readiness

For USB Wi-Fi adapters such as the VENTION Wi-Fi 6 dongle, installation sets Windows WLAN AutoConfig to **Automatic** and starts it immediately. When an active Wi-Fi profile is detected, that profile is changed to **all-user** and **automatic connection**, allowing the managed kiosk account to connect without configuring the password again. The password is managed by Windows and is not written to kiosk logs or state files.

Rerunning the one-line installer refreshes this wireless configuration on an existing kiosk. If no wireless profile is detected, connect to Wi-Fi once as Administrator and rerun the installer. Kiosk removal restores the original WLAN AutoConfig startup setting but retains the Windows Wi-Fi profile.

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

Removal retires the managed account and its Windows profile registration so a later reinstall can create a clean managed profile. If the old profile folder contains files, it is preserved under `C:\Users\SchoolQuizKiosk-Recovered` instead of being deleted. The new installation always uses the profile path Windows registers for the new account.

## Troubleshooting

### Failed install, deleted ProgramData, or `KioskUser0.<PC-NAME>`

Do not manually delete `C:\Users\KioskUser0` or the `SchoolQuizKiosk` ProgramData folders. A user-profile folder is not the Windows account: the account SID and profile registration remain, and Windows may create a dotted folder such as `KioskUser0.YS-LAB-CPU-3` on the next attempt.

Version 2.7.0 detects this specific orphaned YSNLC Assigned Access account during the normal one-line installation. It verifies that the account/display name and active Assigned Access configuration belong to this kiosk, preserves any old profile directory under:

```text
C:\Users\SchoolQuizKiosk-Recovered
```

It then clears the stale account/profile registration and asks for a restart. After restarting, run the same one-line installer again. The old profile is preserved for recovery, including a video or student files that may still be inside it.

For a recorded installation, always use `-Mode Remove` rather than deleting folders. If the ProgramData records were already manually deleted and you need to run recovery directly with a downloaded verified `setup.ps1`, use `-Mode Repair`.

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
