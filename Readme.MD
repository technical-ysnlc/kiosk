# YSNLC School Quiz Kiosk

This project turns a supported Windows 11 computer into a **Chrome-only quiz kiosk**.

After installation, the computer signs in automatically and opens:

```text
https://quiz.ysnlc.com/
```

Students will not see the normal Windows desktop, Start menu, taskbar, or File Explorer.

## Requirements

- Windows 11 **Pro, Education, Enterprise, or IoT Enterprise**
- An Administrator account with a strong password
- Internet access
- Permission to restart the computer

> Test the complete quiz on one computer before installing it on all seven computers.
>
> GhostSpectre and other modified Windows builds may be missing the Windows Assigned Access components required by kiosk mode. An official Windows installation is recommended.

## Step 1 — Prepare the GitHub Repository

Upload these files using the same structure:

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

Then:

1. Commit the files to the `main` branch.
2. Open the repository **Actions** tab.
3. Wait for **Update kiosk manifest** to finish successfully.
4. Open `update.json` and confirm that `sourceCommit` contains a 40-character commit ID.

The one-line installer will not work until the GitHub Action publishes a valid `update.json` file.

## Step 2 — Install the Kiosk

On the Windows computer:

1. Sign in with the Administrator account.
2. Open **Windows PowerShell** or **Windows Terminal**.
3. Run:

```powershell
irm https://raw.githubusercontent.com/technical-ysnlc/kiosk/main/install.ps1 | iex
```

4. Approve the Windows Administrator/UAC prompt.
5. Wait for installation to finish.
6. The computer will restart automatically after 30 seconds.

The installer downloads and verifies the kiosk setup and updater scripts. It also installs Chrome when Chrome is not already installed.

## Step 3 — Test the Computer

After restart, confirm that:

- Windows signs in to the kiosk automatically.
- Chrome opens full-screen at `https://quiz.ysnlc.com/`.
- Students cannot access the normal Windows desktop.
- A complete quiz can be submitted successfully.
- `Ctrl + Alt + Q` exits the kiosk for Administrator maintenance.

After the first computer passes every test, run the same installer command on the other six computers.

## Administrator Maintenance

To leave kiosk mode, press:

```text
Ctrl + Alt + Q
```

Then sign in with the Administrator account.

Chrome URL restrictions are **not** applied computer-wide. Administrator Chrome remains normal. The kiosk still launches Chrome full-screen, while website blocking should be handled by your existing hosts/network filter.

## Updating the Scripts

When changing `setup.ps1`:

1. Increase the `$KioskVersion` value.
2. Commit and push the change.
3. Wait for **Update kiosk manifest** to finish.
4. Test the update on one computer first.

When changing `Update-SchoolQuizKiosk.ps1`, also increase `$UpdaterVersion`.

The automatic updater updates the protected management script. It does not automatically change an active kiosk configuration.

When an update changes kiosk behavior, remove the kiosk and run the one-line installer again after testing the change on one computer.

## Remove the Kiosk

Press `Ctrl + Alt + Q`, sign in as Administrator, open PowerShell as Administrator, and run:

```powershell
$k='C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1'; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $k -Mode Remove -Restart
```

## Troubleshooting

### `sourceCommit` is missing or invalid

Open the GitHub **Actions** tab and wait for **Update kiosk manifest** to complete successfully.

### `MDM_AssignedAccess class: Missing/unavailable`

The Windows image is missing a required kiosk component. This is common on stripped or modified Windows builds. Install an official Windows 11 Pro, Education, Enterprise, or IoT Enterprise image.

### Logs

```text
C:\ProgramData\SchoolQuizKiosk\Setup.log
C:\ProgramData\SchoolQuizKiosk\Updater.log
C:\ProgramData\SchoolQuizKiosk\Diagnostics-*.txt
```

## Security

- Never give students the Administrator password.
- Protect the GitHub account with two-factor authentication.
- Disable USB booting in BIOS/UEFI when possible.
- Only run the installer from the repository you control.
