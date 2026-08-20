#requires -Version 5.1
<#
.SYNOPSIS
  Installs, removes, or diagnoses a restricted multi-app school workstation.

.DESCRIPTION
  - Uses Windows Assigned Access restricted user experience (multi-app).
  - Auto-creates and auto-signs-in a managed standard account shown on-screen as YSNLC-Student.
  - Pins YSNLC Quiz App, Student Files, and any detected Word, Excel, and PowerPoint apps.
  - YSNLC Quiz App launches Chrome at https://quiz.ysnlc.com/ in an Incognito window.
  - File Explorer is restricted to the managed user's Downloads folder.
  - Chrome website filtering is left to your existing hosts/network filter.
  - Runs the Assigned Access MDM Bridge portion as LocalSystem by using a temporary scheduled task.
  - Reversibly disables the pre-existing standard account named YSNLC by default, so it
    cannot remain an unrestricted route to the desktop.
  - Repairs required Assigned Access/AppLocker service startup settings when they were disabled,
    and records their previous settings for removal.
  - Includes rollback and diagnostics modes.

  IMPORTANT:
  1. This script is intended for Windows 11 Pro, Enterprise, Education, or IoT Enterprise.
  2. This version does NOT apply computer-wide Chrome URL policies. Administrator Chrome remains unrestricted.
  3. Microsoft Office is not installed by this script. Word, Excel, and PowerPoint are included only when detected.
  4. Modified/stripped Windows images can be missing Assigned Access components. The script
     detects that condition and writes a diagnostic report instead of attempting an unsafe hack.
  5. Website filtering is intentionally not enforced by this script. Use your hosts/network filtering
     if students must be prevented from visiting unrelated sites. Test the complete workflow on one computer first.
  6. Set a strong password on every administrator account before using the workstation.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-SchoolQuizKiosk.ps1 -Mode Install -Restart

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-SchoolQuizKiosk.ps1 -Mode Remove -Restart

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-SchoolQuizKiosk.ps1 -Mode Diagnose

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-SchoolQuizKiosk.ps1 -Mode Preflight
#>

[CmdletBinding()]
param(
    [ValidateSet('Install', 'Remove', 'Diagnose', 'Preflight')]
    [string]$Mode = 'Install',

    [ValidatePattern('^https://')]
    [string]$Url = 'https://quiz.ysnlc.com/',

    [ValidateLength(1, 64)]
    [string]$DisplayName = 'YSNLC-Student',

    [AllowEmptyString()]
    [ValidateLength(0, 64)]
    [string]$DisableLocalUser = 'YSNLC',

    [switch]$Restart,

    [ValidateSet('Admin', 'System')]
    [string]$Stage = 'Admin'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Join-Path $env:ProgramData 'SchoolQuizKiosk'
$InstalledScript = Join-Path $Root 'Setup-SchoolQuizKiosk.ps1'
$LogPath = Join-Path $Root 'Setup.log'
$StatePath = Join-Path $Root 'State.json'
$XmlPath = Join-Path $Root 'AssignedAccess.xml'
$SystemRequestPath = Join-Path $Root 'SystemRequest.json'
$SystemResultPath = Join-Path $Root 'SystemResult.json'
$PreflightJsonPath = Join-Path $Root 'Preflight.json'
$PreflightTextPath = Join-Path $Root 'Preflight.txt'
$ChromePolicyBackupPath = Join-Path $Root 'ChromePolicies-BeforeKiosk.reg'
$ChromePolicyAbsentMarker = Join-Path $Root 'ChromePolicies-WereAbsent.marker'
$AssignedAccessBackupPath = Join-Path $Root 'AssignedAccess-BeforeKiosk.txt'
$AssignedAccessAbsentMarker = Join-Path $Root 'AssignedAccess-WasAbsent.marker'
$ServiceBackupPath = Join-Path $Root 'ServiceState-BeforeKiosk.json'
$ShortcutRoot = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\YSNLC School'
$KioskVersion = '2.1.3'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevated {
    if (-not $PSCommandPath) {
        throw 'This script must be saved as a .ps1 file before it can elevate itself.'
    }

    $escapedPath = $PSCommandPath.Replace("'", "''")
    $escapedMode = $Mode.Replace("'", "''")
    $escapedUrl = $Url.Replace("'", "''")
    $escapedDisplayName = $DisplayName.Replace("'", "''")
    $escapedDisableLocalUser = $DisableLocalUser.Replace("'", "''")

    $command = "& '$escapedPath' -Mode '$escapedMode' -Url '$escapedUrl' -DisplayName '$escapedDisplayName' -DisableLocalUser '$escapedDisableLocalUser'"
    if ($Restart) {
        $command += ' -Restart'
    }

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" | Out-Null
}

function Initialize-WorkingDirectory {
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }

    # This folder contains a script that is launched as LocalSystem. Lock it down so
    # a standard user cannot replace the script or request file and elevate privileges.
    & "$env:SystemRoot\System32\icacls.exe" $Root `
        '/inheritance:r' `
        '/grant:r' `
        '*S-1-5-18:(OI)(CI)F' `
        '*S-1-5-32-544:(OI)(CI)F' *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not secure the kiosk working folder: $Root"
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        # Logging must never hide the original operation result.
    }

    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $InputObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required file not found: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-KioskInstallEvidence {
    foreach ($path in @(
        $StatePath,
        $XmlPath,
        $ChromePolicyBackupPath,
        $ChromePolicyAbsentMarker,
        $AssignedAccessBackupPath,
        $AssignedAccessAbsentMarker,
        $ServiceBackupPath
    )) {
        if (Test-Path -LiteralPath $path) {
            return $true
        }
    }
    return $false
}

function Clear-AssignedAccessBackup {
    Remove-Item -LiteralPath $AssignedAccessBackupPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $AssignedAccessAbsentMarker -Force -ErrorAction SilentlyContinue
}

function Test-AssignedAccessBackupEvidence {
    return ((Test-Path -LiteralPath $AssignedAccessBackupPath) -or
            (Test-Path -LiteralPath $AssignedAccessAbsentMarker))
}

function Get-WindowsInfo {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        ProductName    = [string]$cv.ProductName
        EditionId      = [string]$cv.EditionID
        DisplayVersion = [string]$cv.DisplayVersion
        CurrentBuild   = [string]$cv.CurrentBuild
        UBR            = [string]$cv.UBR
    }
}

function Assert-SupportedEdition {
    param([Parameter(Mandatory = $true)]$WindowsInfo)

    if ($WindowsInfo.EditionId -notmatch 'Professional|Enterprise|Education|IoTEnterprise') {
        throw "Assigned Access is not supported by this Windows edition: $($WindowsInfo.EditionId). Use Windows 11 Pro, Enterprise, Education, or IoT Enterprise."
    }

    $buildNumber = 0
    if (-not [int]::TryParse([string]$WindowsInfo.CurrentBuild, [ref]$buildNumber) -or $buildNumber -lt 22621) {
        throw "This restricted multi-app configuration uses Windows 11 22H2+ StartPins and requires build 22621 or newer. Detected build: $($WindowsInfo.CurrentBuild)."
    }
}

function Get-RegistryDwordValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return [int]$item.$Name
    } catch {
        return $null
    }
}

function Enable-UacIfRequired {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $current = Get-RegistryDwordValue -Path $path -Name 'EnableLUA'

    if ($current -ne 1) {
        New-ItemProperty -LiteralPath $path -Name EnableLUA -PropertyType DWord -Value 1 -Force | Out-Null
        Write-Log 'User Account Control was disabled. It has been enabled; a restart is required before kiosk sign-in can work.' 'WARN'
        return $true
    }

    Write-Log 'User Account Control is enabled.' 'OK'
    return $false
}

function Get-ChromeExecutable {
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'))
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'))
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Install-ChromeEnterprise {
    Write-Log 'Google Chrome was not found. Downloading the official 64-bit Chrome Enterprise MSI.'

    $msiPath = Join-Path $Root 'GoogleChromeStandaloneEnterprise64.msi'
    $msiUrl = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing

    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" `
        -ArgumentList @('/i', ('"{0}"' -f $msiPath), 'ALLUSERS=1', '/qn', '/norestart') `
        -Wait -PassThru

    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Chrome Enterprise MSI installation failed with exit code $($process.ExitCode)."
    }

    $chrome = Get-ChromeExecutable
    if (-not $chrome) {
        throw 'Chrome installation completed, but chrome.exe could not be found.'
    }

    Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
    Write-Log "Chrome installed at: $chrome" 'OK'
    return $chrome
}

function Get-OfficeExecutable {
    param([Parameter(Mandatory = $true)][string]$ExeName)

    $candidates = New-Object System.Collections.Generic.List[string]
    $roots = @()
    if ($env:ProgramFiles) { $roots += $env:ProgramFiles }
    if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }

    foreach ($root in ($roots | Select-Object -Unique)) {
        foreach ($relative in @(
            "Microsoft Office\root\Office16\$ExeName",
            "Microsoft Office\Office16\$ExeName",
            "Microsoft Office\Office15\$ExeName"
        )) {
            $candidates.Add((Join-Path $root $relative))
        }
    }

    foreach ($registryRoot in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths'
    )) {
        $key = Join-Path $registryRoot $ExeName
        if (Test-Path -LiteralPath $key) {
            try {
                $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                $defaultPath = [string]$item.'(default)'
                if (-not [string]::IsNullOrWhiteSpace($defaultPath)) {
                    $candidates.Add($defaultPath.Trim('"'))
                }
            } catch {
                # Candidate registry entry is optional; continue with file-system candidates.
            }
        }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-OfficeApps {
    $definitions = @(
        [pscustomobject]@{ Name = 'Microsoft Word';       Exe = 'WINWORD.EXE';  Path = (Get-OfficeExecutable -ExeName 'WINWORD.EXE') },
        [pscustomobject]@{ Name = 'Microsoft Excel';      Exe = 'EXCEL.EXE';    Path = (Get-OfficeExecutable -ExeName 'EXCEL.EXE') },
        [pscustomobject]@{ Name = 'Microsoft PowerPoint'; Exe = 'POWERPNT.EXE'; Path = (Get-OfficeExecutable -ExeName 'POWERPNT.EXE') }
    )

    return @($definitions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Path) })
}

function New-KioskShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$Arguments = '',
        [string]$IconLocation = ''
    )

    if (-not (Test-Path -LiteralPath $ShortcutRoot)) {
        New-Item -ItemType Directory -Path $ShortcutRoot -Force | Out-Null
    }

    $linkPath = Join-Path $ShortcutRoot ($Name + '.lnk')
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($linkPath)
        $shortcut.TargetPath = $TargetPath
        if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
            $shortcut.Arguments = $Arguments
        }
        if (-not [string]::IsNullOrWhiteSpace($IconLocation)) {
            $shortcut.IconLocation = $IconLocation
        }
        $shortcut.Save()
    } finally {
        if ($shell) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }

    return $linkPath
}

function Install-KioskShortcuts {
    param(
        [Parameter(Mandatory = $true)][string]$ChromePath,
        [Parameter(Mandatory = $true)][string]$KioskUrl,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$OfficeApps
    )

    if (Test-Path -LiteralPath $ShortcutRoot) {
        Remove-Item -LiteralPath $ShortcutRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $ShortcutRoot -Force | Out-Null

    $quizArgs = '--start-maximized --incognito --no-first-run --no-default-browser-check --disable-session-crashed-bubble --overscroll-history-navigation=0 "{0}"' -f $KioskUrl
    New-KioskShortcut -Name 'YSNLC Quiz App' -TargetPath $ChromePath -Arguments $quizArgs -IconLocation ($ChromePath + ',0') | Out-Null
    New-KioskShortcut -Name 'Student Files' -TargetPath "$env:WINDIR\explorer.exe" -Arguments 'shell:Downloads' -IconLocation ("$env:WINDIR\explorer.exe,0") | Out-Null

    foreach ($app in $OfficeApps) {
        New-KioskShortcut -Name ([string]$app.Name) -TargetPath ([string]$app.Path) -IconLocation (([string]$app.Path) + ',0') | Out-Null
    }

    Write-Log "Created restricted-user Start shortcuts under: $ShortcutRoot" 'OK'
}

function Remove-KioskShortcuts {
    if (Test-Path -LiteralPath $ShortcutRoot) {
        Remove-Item -LiteralPath $ShortcutRoot -Recurse -Force -ErrorAction Stop
        Write-Log 'Removed YSNLC restricted-user Start shortcuts.' 'OK'
    }
}

function Get-ServiceSnapshot {
    param([Parameter(Mandatory = $true)][string]$Name)

    $service = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''")) -ErrorAction SilentlyContinue
    if (-not $service) {
        return $null
    }

    return [pscustomobject]@{
        Name      = [string]$service.Name
        StartMode = [string]$service.StartMode
        State     = [string]$service.State
    }
}

function Set-ServiceStartupWithSc {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('auto','demand','disabled')][string]$Startup
    )

    & "$env:SystemRoot\System32\sc.exe" config $Name start= $Startup *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not configure Windows service ${Name}. sc.exe exit code: $LASTEXITCODE"
    }
}

function Ensure-RequiredKioskServices {
    $required = @(
        [pscustomobject]@{ Name = 'AssignedAccessManagerSvc'; Startup = 'demand' },
        [pscustomobject]@{ Name = 'AppIDSvc';                Startup = 'auto' }
    )

    if (-not (Test-Path -LiteralPath $ServiceBackupPath)) {
        $snapshots = @()
        foreach ($item in $required) {
            $snapshot = Get-ServiceSnapshot -Name $item.Name
            if (-not $snapshot) {
                throw "Required Windows kiosk service is missing: $($item.Name). This Windows image may have removed a required component."
            }
            $snapshots += $snapshot
        }
        Write-JsonFile -InputObject $snapshots -Path $ServiceBackupPath
    }

    foreach ($item in $required) {
        $snapshot = Get-ServiceSnapshot -Name $item.Name
        if (-not $snapshot) {
            throw "Required Windows kiosk service is missing: $($item.Name)."
        }

        Set-ServiceStartupWithSc -Name $item.Name -Startup $item.Startup
        try {
            Start-Service -Name $item.Name -ErrorAction Stop
            Write-Log "Required service $($item.Name) is enabled and running." 'OK'
        } catch {
            if ($item.Name -eq 'AssignedAccessManagerSvc') {
                # AssignedAccessManagerSvc is normally Manual/trigger-start. It only needs to be
                # enabled so Windows can start it when Assigned Access configuration is applied.
                Write-Log "AssignedAccessManagerSvc is enabled but did not stay running; Windows may trigger-start it during configuration. $($_.Exception.Message)" 'WARN'
            } else {
                throw
            }
        }
    }
}

function Restore-RequiredKioskServices {
    if (-not (Test-Path -LiteralPath $ServiceBackupPath)) {
        return
    }

    $snapshots = @(Read-JsonFile -Path $ServiceBackupPath)
    foreach ($snapshot in $snapshots) {
        $name = [string]$snapshot.Name
        if ([string]::IsNullOrWhiteSpace($name) -or -not (Get-Service -Name $name -ErrorAction SilentlyContinue)) {
            continue
        }

        if ($name -eq 'AppIDSvc' -and [string]$snapshot.StartMode -eq 'Manual') {
            # Microsoft documents that AppIDSvc can't be changed back to Manual with sc.exe.
            # Leaving it Automatic is safe after kiosk removal and avoids an unsupported registry hack.
            Write-Log 'AppIDSvc was originally Manual. Windows does not support restoring that protected service to Manual with sc.exe, so it is left Automatic.' 'WARN'
            continue
        }

        $startup = switch ([string]$snapshot.StartMode) {
            'Auto'     { 'auto' }
            'Manual'   { 'demand' }
            'Disabled' { 'disabled' }
            default    { 'demand' }
        }

        if ($startup -eq 'disabled') {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        } elseif ([string]$snapshot.State -eq 'Stopped') {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        }

        Set-ServiceStartupWithSc -Name $name -Startup $startup
        Write-Log "Restored service startup setting for $name to $($snapshot.StartMode)." 'OK'
    }

    Remove-Item -LiteralPath $ServiceBackupPath -Force -ErrorAction SilentlyContinue
}

function Backup-ChromePolicies {
    if ((Test-Path -LiteralPath $ChromePolicyBackupPath) -or (Test-Path -LiteralPath $ChromePolicyAbsentMarker)) {
        Write-Log 'An original Chrome policy backup already exists; it will not be overwritten.'
        return
    }

    $rootKey = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
    if (Test-Path -LiteralPath $rootKey) {
        & "$env:SystemRoot\System32\reg.exe" export 'HKLM\SOFTWARE\Policies\Google\Chrome' $ChromePolicyBackupPath /y *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not back up the existing Chrome policy registry key.'
        }
        Write-Log "Existing Chrome policies were backed up to: $ChromePolicyBackupPath" 'OK'
    } else {
        New-Item -ItemType File -Path $ChromePolicyAbsentMarker -Force | Out-Null
        Write-Log 'No pre-existing Chrome machine policy key was found.'
    }
}

function Set-RegistryDword {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Set-RegistryString {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType String -Value $Value -Force | Out-Null
}

function Set-RegistryList {
    param(
        [Parameter(Mandatory = $true)][string]$ParentPath,
        [Parameter(Mandatory = $true)][string]$ListName,
        [Parameter(Mandatory = $true)][string[]]$Values
    )

    $path = Join-Path $ParentPath $ListName
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
    New-Item -Path $path -Force | Out-Null

    for ($i = 0; $i -lt $Values.Count; $i++) {
        New-ItemProperty -LiteralPath $path -Name ([string]($i + 1)) -PropertyType String -Value $Values[$i] -Force | Out-Null
    }
}

function Get-AllowFilterFromUrl {
    param([Parameter(Mandatory = $true)][string]$InputUrl)

    $uri = [Uri]$InputUrl
    if ($uri.Scheme -ne 'https') {
        throw 'The kiosk URL must use HTTPS.'
    }

    $filter = '{0}://{1}' -f $uri.Scheme, $uri.Host
    if (-not $uri.IsDefaultPort) {
        $filter += ':' + $uri.Port
    }

    if ($uri.AbsolutePath -and $uri.AbsolutePath -ne '/') {
        $filter += $uri.AbsolutePath.TrimEnd('/')
    }

    return $filter
}

function Set-ChromeKioskPolicies {
    param([Parameter(Mandatory = $true)][string]$KioskUrl)

    # IMPORTANT: Do not write Chrome restrictions under HKLM here.
    # HKLM Chrome policy applies to every Windows user, including Administrator, which caused
    # "This page is blocked by your organization" outside the kiosk account. Assigned Access
    # already isolates the kiosk Windows session. Website filtering should be handled by the
    # existing hosts/network filter so administrator Chrome profiles remain unaffected.
    Write-Log "Chrome machine-wide URL policies are not modified. Kiosk start page: $KioskUrl" 'OK'
    Write-Log 'Student Windows access is restricted by Assigned Access; website filtering is delegated to the existing hosts/network filter.' 'OK'
}

function Restore-ChromePolicies {
    $hasBackup = Test-Path -LiteralPath $ChromePolicyBackupPath
    $hasAbsentMarker = Test-Path -LiteralPath $ChromePolicyAbsentMarker
    if (-not $hasBackup -and -not $hasAbsentMarker) {
        Write-Log 'No kiosk Chrome policy backup marker was found. Existing Chrome policies were left unchanged.' 'WARN'
        return
    }

    $rootKey = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
    if (Test-Path -LiteralPath $rootKey) {
        Remove-Item -LiteralPath $rootKey -Recurse -Force
    }

    if ($hasBackup) {
        & "$env:SystemRoot\System32\reg.exe" import $ChromePolicyBackupPath *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'The original Chrome policy backup could not be restored.'
        }
        Write-Log 'Original Chrome policies were restored.' 'OK'
    } else {
        Write-Log 'Kiosk Chrome policies were removed.' 'OK'
    }

    # A completed restore becomes the new clean baseline for a future installation.
    Remove-Item -LiteralPath $ChromePolicyBackupPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ChromePolicyAbsentMarker -Force -ErrorAction SilentlyContinue
}

function Build-AssignedAccessXml {
    param(
        [Parameter(Mandatory = $true)][string]$ChromePath,
        [Parameter(Mandatory = $true)][string]$KioskUrl,
        [Parameter(Mandatory = $true)][string]$KioskDisplayName,
        [Parameter(Mandatory = $true)][string]$ProfileId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$OfficeApps
    )

    $escapedChromePath = [System.Security.SecurityElement]::Escape($ChromePath)
    $escapedDisplayName = [System.Security.SecurityElement]::Escape($KioskDisplayName)
    $escapedExplorerPath = [System.Security.SecurityElement]::Escape("$env:WINDIR\explorer.exe")

    $allowedApps = New-Object System.Collections.Generic.List[string]
    $allowedApps.Add(('        <App DesktopAppPath="{0}" />' -f $escapedChromePath))
    $allowedApps.Add(('        <App DesktopAppPath="{0}" />' -f $escapedExplorerPath))

    foreach ($app in $OfficeApps) {
        $escapedPath = [System.Security.SecurityElement]::Escape([string]$app.Path)
        $allowedApps.Add(('        <App DesktopAppPath="{0}" />' -f $escapedPath))
    }

    $pinLinks = New-Object System.Collections.Generic.List[object]
    $baseLink = '%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\YSNLC School\'
    $pinLinks.Add([ordered]@{ desktopAppLink = $baseLink + 'YSNLC Quiz App.lnk' })
    foreach ($app in $OfficeApps) {
        $pinLinks.Add([ordered]@{ desktopAppLink = $baseLink + ([string]$app.Name) + '.lnk' })
    }
    $pinLinks.Add([ordered]@{ desktopAppLink = $baseLink + 'Student Files.lnk' })

    # PowerShell 5.1 can throw 'Argument types do not match' when @() wraps a generic List[object].
    # Convert explicitly to a CLR array for compatibility across Windows 11 PowerShell 5.1 builds.
    $startPinsJson = ([ordered]@{ pinnedList = $pinLinks.ToArray() } | ConvertTo-Json -Depth 5 -Compress)
    $allowedAppsXml = $allowedApps -join "`r`n"

    return @"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config"
    xmlns:rs5="http://schemas.microsoft.com/AssignedAccess/201810/config"
    xmlns:v5="http://schemas.microsoft.com/AssignedAccess/2022/config">
  <Profiles>
    <Profile Id="$ProfileId" Name="YSNLC Restricted Student Experience">
      <AllAppsList>
        <AllowedApps>
$allowedAppsXml
        </AllowedApps>
      </AllAppsList>
      <rs5:FileExplorerNamespaceRestrictions>
        <rs5:AllowedNamespace Name="Downloads" />
      </rs5:FileExplorerNamespaceRestrictions>
      <v5:StartPins><![CDATA[$startPinsJson]]></v5:StartPins>
      <Taskbar ShowTaskbar="true" />
    </Profile>
  </Profiles>
  <Configs>
    <Config>
      <AutoLogonAccount rs5:DisplayName="$escapedDisplayName" />
      <DefaultProfile Id="$ProfileId" />
    </Config>
  </Configs>
</AssignedAccessConfiguration>
"@
}

function Copy-ScriptToProgramData {
    if (-not $PSCommandPath) {
        throw 'The current script path cannot be determined.'
    }

    $source = [IO.Path]::GetFullPath($PSCommandPath)
    $destination = [IO.Path]::GetFullPath($InstalledScript)
    if (-not $source.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

function Invoke-SystemTask {
    param([ValidateSet('Install', 'Remove')][string]$SystemMode)

    Copy-ScriptToProgramData
    Remove-Item -LiteralPath $SystemResultPath -Force -ErrorAction SilentlyContinue

    Write-JsonFile -Path $SystemRequestPath -InputObject ([ordered]@{
        Mode    = $SystemMode
        XmlPath = $XmlPath
    })

    $taskName = 'SchoolQuizKiosk-System-' + [Guid]::NewGuid().ToString('N')
    $powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode {1} -Stage System' -f $InstalledScript, $SystemMode

    $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1)
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName

        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $SystemResultPath)) {
            Start-Sleep -Seconds 1
        }

        if (-not (Test-Path -LiteralPath $SystemResultPath)) {
            $lastResult = $null
            try {
                $lastResult = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
            } catch {
                $lastResult = 'unknown'
            }
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            throw "The LocalSystem configuration task timed out. Scheduled Task result: $lastResult"
        }

        $result = Read-JsonFile -Path $SystemResultPath
        if (-not [bool]$result.Success) {
            throw [string]$result.Message
        }

        Write-Log ([string]$result.Message) 'OK'
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Invoke-AssignedAccessSystemStage {
    Initialize-WorkingDirectory
    $stageStarted = Get-Date

    try {
        $request = Read-JsonFile -Path $SystemRequestPath
        $namespace = 'root\cimv2\mdm\dmmap'
        $className = 'MDM_AssignedAccess'

        try {
            Get-CimClass -Namespace $namespace -ClassName $className -ErrorAction Stop | Out-Null
        } catch {
            throw "The Windows Assigned Access MDM Bridge provider is missing or unavailable. This Windows image may have removed a required component. Original error: $($_.Exception.Message)"
        }

        $instance = Get-CimInstance -Namespace $namespace -ClassName $className -ErrorAction Stop | Select-Object -First 1
        if (-not $instance) {
            throw 'Windows returned no MDM_AssignedAccess instance.'
        }

        if ([string]$request.Mode -eq 'Install') {
            if (-not (Test-Path -LiteralPath ([string]$request.XmlPath))) {
                throw "Assigned Access XML was not found: $($request.XmlPath)"
            }

            # Preserve any pre-existing kiosk configuration so removal can put it back.
            if (-not (Test-Path -LiteralPath $AssignedAccessBackupPath) -and
                -not (Test-Path -LiteralPath $AssignedAccessAbsentMarker)) {
                $previousConfiguration = [string]$instance.Configuration
                if ([string]::IsNullOrWhiteSpace($previousConfiguration)) {
                    New-Item -ItemType File -Path $AssignedAccessAbsentMarker -Force | Out-Null
                } else {
                    Set-Content -LiteralPath $AssignedAccessBackupPath -Value $previousConfiguration -Encoding UTF8 -NoNewline
                }
            }

            # Clear any stale/broken kiosk configuration before applying the new profile.
            $instance.Configuration = $null
            Set-CimInstance -CimInstance $instance -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 2

            $xml = Get-Content -LiteralPath ([string]$request.XmlPath) -Raw -Encoding UTF8
            $instance = Get-CimInstance -Namespace $namespace -ClassName $className -ErrorAction Stop | Select-Object -First 1
            $instance.Configuration = [Net.WebUtility]::HtmlEncode($xml)
            Set-CimInstance -CimInstance $instance -ErrorAction Stop | Out-Null

            Write-JsonFile -Path $SystemResultPath -InputObject ([ordered]@{
                Success = $true
                Message = 'Windows Assigned Access configuration was applied successfully.'
            })
        } else {
            if (Test-Path -LiteralPath $AssignedAccessBackupPath) {
                $previousConfiguration = Get-Content -LiteralPath $AssignedAccessBackupPath -Raw -Encoding UTF8
                $instance.Configuration = $previousConfiguration
                $message = 'The previous Windows Assigned Access configuration was restored successfully.'
            } elseif (Test-Path -LiteralPath $AssignedAccessAbsentMarker) {
                $instance.Configuration = $null
                $message = 'Windows Assigned Access configuration was removed successfully.'
            } else {
                throw 'No SchoolQuizKiosk Assigned Access backup marker was found. Refusing to clear an unknown kiosk configuration.'
            }

            Set-CimInstance -CimInstance $instance -ErrorAction Stop | Out-Null

            Write-JsonFile -Path $SystemResultPath -InputObject ([ordered]@{
                Success = $true
                Message = $message
            })
        }
    } catch {
        $message = Get-DetailedExceptionMessage -ErrorRecord $_
        $eventSummary = Get-RecentAssignedAccessFailure -Since $stageStarted.AddSeconds(-5)
        if (-not [string]::IsNullOrWhiteSpace([string]$eventSummary)) {
            $message = "$message AssignedAccess detail: $eventSummary"
        }
        try {
            Write-JsonFile -Path $SystemResultPath -InputObject ([ordered]@{
                Success = $false
                Message = $message
            })
        } catch {
            # Nothing else can be done from the system stage.
        }
        exit 1
    }

    exit 0
}

function Write-DiagnosticReport {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportPath = Join-Path $Root "Diagnostics-$timestamp.txt"
    $lines = New-Object System.Collections.Generic.List[string]

    $info = Get-WindowsInfo
    $uac = Get-RegistryDwordValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA'
    $chrome = Get-ChromeExecutable
    $officeApps = @(Get-OfficeApps)

    $lines.Add('YSNLC restricted student experience diagnostics')
    $lines.Add(('Generated: {0}' -f (Get-Date)))
    $lines.Add(('Script version: {0}' -f $KioskVersion))
    $lines.Add('')
    $lines.Add(('Windows: {0}' -f $info.ProductName))
    $lines.Add(('EditionID: {0}' -f $info.EditionId))
    $lines.Add(('Version: {0}' -f $info.DisplayVersion))
    $lines.Add(('Build: {0}.{1}' -f $info.CurrentBuild, $info.UBR))
    $lines.Add(('UAC EnableLUA: {0}' -f $uac))
    $lines.Add(('Chrome: {0}' -f $(if ($chrome) { $chrome } else { 'Not found' })))
    foreach ($officeName in @('Microsoft Word','Microsoft Excel','Microsoft PowerPoint')) {
        $office = $officeApps | Where-Object Name -eq $officeName | Select-Object -First 1
        $lines.Add(('{0}: {1}' -f $officeName, $(if ($office) { [string]$office.Path } else { 'Not found' })))
    }
    foreach ($serviceName in @('AssignedAccessManagerSvc','AppIDSvc')) {
        $svc = Get-ServiceSnapshot -Name $serviceName
        if ($svc) {
            $lines.Add(('Service {0}: StartMode={1}; State={2}' -f $serviceName, $svc.StartMode, $svc.State))
        } else {
            $lines.Add(('Service {0}: Missing' -f $serviceName))
        }
    }
    $lines.Add('')

    try {
        Get-CimClass -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_AssignedAccess' -ErrorAction Stop | Out-Null
        $lines.Add('MDM_AssignedAccess class: Present')
    } catch {
        $lines.Add(('MDM_AssignedAccess class: Missing/unavailable - {0}' -f $_.Exception.Message))
    }

    try {
        $cmd = Get-Command Set-AssignedAccess -ErrorAction Stop
        $lines.Add(('Set-AssignedAccess cmdlet: Present at {0}' -f $cmd.Source))
    } catch {
        $lines.Add('Set-AssignedAccess cmdlet: Missing')
    }

    $lines.Add('')
    $lines.Add('Recent Assigned Access events:')
    foreach ($logName in @('Microsoft-Windows-AssignedAccess/Admin', 'Microsoft-Windows-AssignedAccess/Operational')) {
        $lines.Add(('--- {0} ---' -f $logName))
        try {
            $events = Get-WinEvent -LogName $logName -MaxEvents 30 -ErrorAction Stop
            if (-not $events) {
                $lines.Add('No events found.')
            } else {
                foreach ($event in $events) {
                    $oneLine = ($event.Message -replace '[\r\n]+', ' ')
                    $lines.Add(('{0:u} [{1}] ID {2}: {3}' -f $event.TimeCreated, $event.LevelDisplayName, $event.Id, $oneLine))
                }
            }
        } catch {
            $lines.Add(('Could not read log: {0}' -f $_.Exception.Message))
        }
    }

    $lines | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-Log "Diagnostic report created: $reportPath" 'OK'
    return $reportPath
}

function Remove-ManagedKioskUserIfPresent {
    param([string]$ExpectedDisplayName)

    try {
        $users = Get-LocalUser -ErrorAction Stop | Where-Object {
            $_.Name -like 'kioskUser*' -and (
                [string]::IsNullOrWhiteSpace($ExpectedDisplayName) -or
                $_.FullName -eq $ExpectedDisplayName
            )
        }

        foreach ($user in $users) {
            Remove-LocalUser -Name $user.Name -ErrorAction Stop
            Write-Log "Removed managed kiosk account: $($user.Name)" 'OK'
        }
    } catch {
        Write-Log "The managed kiosk account could not be removed automatically: $($_.Exception.Message)" 'WARN'
    }
}

function Get-EnabledStandardLocalUsers {
    param([string[]]$ExcludedUserNames = @())

    $administratorsSid = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    $administrators = Get-LocalGroup -SID $administratorsSid -ErrorAction Stop
    $administratorSidSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($member in (Get-LocalGroupMember -Group $administrators -ErrorAction Stop)) {
        if ($member.SID) {
            [void]$administratorSidSet.Add([string]$member.SID)
        }
    }

    $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $ExcludedUserNames) {
        if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
            [void]$excluded.Add([string]$name)
        }
    }

    $remaining = New-Object System.Collections.Generic.List[object]
    foreach ($user in (Get-LocalUser -ErrorAction Stop)) {
        if (-not [bool]$user.Enabled) {
            continue
        }

        $sidText = [string]$user.SID
        if ($administratorSidSet.Contains($sidText)) {
            continue
        }
        if ($excluded.Contains([string]$user.Name)) {
            continue
        }

        $remaining.Add([pscustomobject]@{
            Name = [string]$user.Name
            SID  = $sidText
        })
    }

    return $remaining.ToArray()
}

function Assert-NoEnabledStandardUsersRemain {
    $remaining = @(Get-EnabledStandardLocalUsers)
    if ($remaining.Count -gt 0) {
        $names = @($remaining | ForEach-Object { $_.Name })
        throw ('Enabled standard local accounts would still provide a normal Windows desktop: {0}. Disable or remove those accounts, then run the installer again.' -f ($names -join ', '))
    }
}

function Disable-ConflictingLocalUser {
    param([string]$UserName)

    if ([string]::IsNullOrWhiteSpace($UserName)) {
        return [pscustomobject]@{
            Name       = $null
            WasEnabled = $false
        }
    }

    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Log "No pre-existing local account named '$UserName' was found."
        return [pscustomobject]@{
            Name       = $null
            WasEnabled = $false
        }
    }

    $sidText = [string]$user.SID
    $administratorsSid = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    $administrators = Get-LocalGroup -SID $administratorsSid -ErrorAction Stop
    $isAdministrator = Get-LocalGroupMember -Group $administrators -ErrorAction Stop | Where-Object {
        [string]$_.SID -eq $sidText
    }

    if ($user.Name -eq $env:USERNAME -or $sidText -match '-500$' -or $isAdministrator) {
        Write-Log "The account '$($user.Name)' matches DisableLocalUser but is an administrator, so it will NOT be disabled. Protect all administrator accounts with strong passwords." 'WARN'
        return [pscustomobject]@{
            Name       = $null
            WasEnabled = $false
        }
    }

    $wasEnabled = [bool]$user.Enabled
    if ($wasEnabled) {
        Disable-LocalUser -Name $user.Name -ErrorAction Stop
        Write-Log "Disabled the pre-existing standard account '$($user.Name)' so it cannot be used to reach a normal desktop." 'OK'
    } else {
        Write-Log "The pre-existing account '$($user.Name)' was already disabled."
    }

    return [pscustomobject]@{
        Name       = [string]$user.Name
        WasEnabled = $wasEnabled
    }
}

function Restore-ConflictingLocalUser {
    param(
        [string]$UserName,
        [bool]$WasEnabled
    )

    if ([string]::IsNullOrWhiteSpace($UserName) -or -not $WasEnabled) {
        return
    }

    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Log "The original local account '$UserName' no longer exists, so it could not be re-enabled." 'WARN'
        return
    }

    if (-not $user.Enabled) {
        Enable-LocalUser -Name $UserName -ErrorAction Stop
        Write-Log "Re-enabled the original local account '$UserName'." 'OK'
    }
}


function Test-HardPendingRestart {
    $reasons = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        if (Test-Path -LiteralPath $path) {
            $reasons.Add($path)
        }
    }
    return $reasons.ToArray()
}

function Test-SoftPendingRestart {
    try {
        $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
        return ($null -ne $session.PendingFileRenameOperations -and @($session.PendingFileRenameOperations).Count -gt 0)
    } catch {
        return $false
    }
}

function Get-KnownAssignedAccessBuildWarning {
    param([Parameter(Mandatory = $true)]$WindowsInfo)

    $build = 0
    $ubr = 0
    if (-not [int]::TryParse([string]$WindowsInfo.CurrentBuild, [ref]$build)) {
        return $null
    }
    [void][int]::TryParse([string]$WindowsInfo.UBR, [ref]$ubr)

    if ($build -in @(26100, 26200) -and $ubr -ge 4484 -and $ubr -lt 7705) {
        return "Windows build $build.$ubr is in a Microsoft-documented Assigned Access regression range. Install Windows updates until this PC is at least $build.7705, restart, and run the installer again."
    }

    return $null
}

function Enable-AssignedAccessOperationalLog {
    try {
        & "$env:SystemRoot\System32\wevtutil.exe" sl 'Microsoft-Windows-AssignedAccess/Operational' /e:true *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'Assigned Access Operational logging is enabled for this installation attempt.' 'OK'
        } else {
            Write-Log "Assigned Access Operational logging could not be enabled. wevtutil exit code: $LASTEXITCODE" 'WARN'
        }
    } catch {
        Write-Log "Assigned Access Operational logging could not be enabled: $($_.Exception.Message)" 'WARN'
    }
}

function Get-RecentAssignedAccessFailure {
    param([datetime]$Since = (Get-Date).AddMinutes(-5))

    try {
        $events = @(Get-WinEvent -LogName 'Microsoft-Windows-AssignedAccess/Admin' -MaxEvents 12 -ErrorAction Stop | Where-Object {
            $_.TimeCreated -ge $Since -and $_.LevelDisplayName -eq 'Error'
        } | Select-Object -First 3)

        if ($events.Count -eq 0) {
            return $null
        }

        $parts = foreach ($event in $events) {
            $message = ([string]$event.Message -replace '[\r\n]+', ' ').Trim()
            if ($message.Length -gt 500) {
                $message = $message.Substring(0, 500) + '...'
            }
            'Event {0}: {1}' -f $event.Id, $message
        }
        return ($parts -join ' | ')
    } catch {
        return $null
    }
}

function Get-DetailedExceptionMessage {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    try {
        $hresult = [int]$ErrorRecord.Exception.HResult
        if ($hresult -ne 0) {
            $hex = ('0x{0:X8}' -f ([uint32]$hresult))
            if ($message -notmatch [regex]::Escape($hex)) {
                $message = "$message (HRESULT $hex)"
            }
        }
    } catch {
        # Keep the original message when an HRESULT cannot be formatted.
    }
    return $message
}

function Invoke-KioskPreflight {
    param([switch]$Quiet)

    Initialize-WorkingDirectory

    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check {
        param(
            [string]$Name,
            [ValidateSet('PASS','WARN','FAIL','INFO')][string]$Status,
            [string]$Details
        )
        $checks.Add([pscustomobject]@{
            Name = $Name
            Status = $Status
            Details = $Details
        })
    }

    $windows = Get-WindowsInfo
    try {
        Assert-SupportedEdition -WindowsInfo $windows
        Add-Check 'Windows edition/build' 'PASS' "$($windows.ProductName); $($windows.EditionId); $($windows.DisplayVersion); build $($windows.CurrentBuild).$($windows.UBR)"
    } catch {
        Add-Check 'Windows edition/build' 'FAIL' $_.Exception.Message
    }

    $knownBuildIssue = Get-KnownAssignedAccessBuildWarning -WindowsInfo $windows
    if ($knownBuildIssue) {
        Add-Check 'Assigned Access Windows update level' 'FAIL' $knownBuildIssue
    } else {
        Add-Check 'Assigned Access Windows update level' 'PASS' 'No known blocked Assigned Access regression range was detected.'
    }

    $uac = Get-RegistryDwordValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA'
    if ($uac -eq 1) {
        Add-Check 'User Account Control' 'PASS' 'UAC is enabled.'
    } else {
        Add-Check 'User Account Control' 'WARN' 'UAC is disabled. The installer will enable it, then stop and require one restart before kiosk configuration.'
    }

    $hardPending = @(Test-HardPendingRestart)
    if ($hardPending.Count -gt 0) {
        Add-Check 'Pending Windows restart' 'FAIL' 'Windows has a pending servicing/update restart. Restart this PC, then run the same installer again.'
    } elseif (Test-SoftPendingRestart) {
        Add-Check 'Pending Windows restart' 'WARN' 'Pending file rename operations were detected. A restart is recommended before deployment.'
    } else {
        Add-Check 'Pending Windows restart' 'PASS' 'No blocking pending restart was detected.'
    }

    try {
        # Assigned Access is a device-scope CSP. Microsoft requires device-setting calls through
        # the MDM Bridge WMI Provider to run as LocalSystem. An elevated administrator can see
        # the class yet receive no MDM_AssignedAccess instance, which is not a valid install-time
        # failure signal. The actual configuration stage already runs as LocalSystem and performs
        # the authoritative Get-CimInstance check before writing any Assigned Access XML.
        Get-CimClass -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_AssignedAccess' -ErrorAction Stop | Out-Null
        Add-Check 'Assigned Access MDM provider' 'PASS' 'MDM_AssignedAccess class is present. The device-level provider instance will be verified during the LocalSystem installation stage.'
    } catch {
        Add-Check 'Assigned Access MDM provider' 'FAIL' $_.Exception.Message
    }

    foreach ($serviceName in @('AssignedAccessManagerSvc','AppIDSvc')) {
        $svc = Get-ServiceSnapshot -Name $serviceName
        if (-not $svc) {
            Add-Check "Service $serviceName" 'FAIL' 'Required Windows kiosk/AppLocker service is missing.'
        } elseif ([string]$svc.StartMode -eq 'Disabled') {
            Add-Check "Service $serviceName" 'WARN' "Service is disabled. The installer will enable it before applying Assigned Access. Current state: $($svc.State)."
        } else {
            Add-Check "Service $serviceName" 'PASS' "StartMode=$($svc.StartMode); State=$($svc.State)."
        }
    }

    $requiredCommands = @(
        'Get-LocalUser','Get-LocalGroup','Get-LocalGroupMember','Disable-LocalUser',
        'New-ScheduledTaskAction','New-ScheduledTaskTrigger','New-ScheduledTaskPrincipal',
        'New-ScheduledTaskSettingsSet','Register-ScheduledTask','Start-ScheduledTask','Unregister-ScheduledTask'
    )
    $missingCommands = @($requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missingCommands.Count -gt 0) {
        Add-Check 'Required Windows PowerShell commands' 'FAIL' ('Missing: ' + ($missingCommands -join ', '))
    } else {
        Add-Check 'Required Windows PowerShell commands' 'PASS' 'LocalAccounts and ScheduledTasks commands are available.'
    }

    if (Test-Path -LiteralPath "$env:WINDIR\explorer.exe") {
        Add-Check 'File Explorer' 'PASS' 'explorer.exe is present.'
    } else {
        Add-Check 'File Explorer' 'FAIL' 'explorer.exe is missing.'
    }

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        if ($shell) {
            Add-Check 'Windows shortcut engine' 'PASS' 'WScript.Shell COM automation is available.'
        } else {
            Add-Check 'Windows shortcut engine' 'FAIL' 'WScript.Shell returned no object.'
        }
    } catch {
        Add-Check 'Windows shortcut engine' 'FAIL' $_.Exception.Message
    } finally {
        if ($shell) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }

    if (Test-KioskInstallEvidence) {
        Add-Check 'Existing kiosk state' 'FAIL' "Existing or incomplete kiosk state exists under $Root. Use the removal command before reinstalling."
    } else {
        Add-Check 'Existing kiosk state' 'PASS' 'No previous kiosk state was detected.'
    }

    try {
        $otherUsers = @(Get-EnabledStandardLocalUsers -ExcludedUserNames @($DisableLocalUser))
        if ($otherUsers.Count -gt 0) {
            $names = @($otherUsers | ForEach-Object { $_.Name })
            Add-Check 'Other standard local users' 'FAIL' ('These enabled standard accounts would keep a normal desktop: ' + ($names -join ', '))
        } else {
            $configured = Get-LocalUser -Name $DisableLocalUser -ErrorAction SilentlyContinue
            if ($configured -and $configured.Enabled) {
                $adminSid = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
                $adminGroup = Get-LocalGroup -SID $adminSid -ErrorAction Stop
                $configuredIsAdmin = Get-LocalGroupMember -Group $adminGroup -ErrorAction Stop | Where-Object {
                    [string]$_.SID -eq [string]$configured.SID
                }
                if ($configuredIsAdmin) {
                    Add-Check 'Other standard local users' 'WARN' "'$DisableLocalUser' is an administrator account, not a student standard account. It will be left enabled; make sure it has a strong password."
                } else {
                    Add-Check 'Other standard local users' 'PASS' "Only the configured '$DisableLocalUser' standard account needs disabling; the installer will do that reversibly."
                }
            } else {
                Add-Check 'Other standard local users' 'PASS' 'No conflicting enabled standard local accounts were detected.'
            }
        }
    } catch {
        Add-Check 'Other standard local users' 'FAIL' $_.Exception.Message
    }

    $chrome = Get-ChromeExecutable
    if ($chrome) {
        Add-Check 'Google Chrome' 'PASS' $chrome
    } else {
        Add-Check 'Google Chrome' 'INFO' 'Chrome is not installed. The installer will download the official Chrome Enterprise MSI.'
    }

    $officeApps = @(Get-OfficeApps)
    foreach ($officeName in @('Microsoft Word','Microsoft Excel','Microsoft PowerPoint')) {
        $found = $officeApps | Where-Object Name -eq $officeName | Select-Object -First 1
        if ($found) {
            Add-Check $officeName 'PASS' ([string]$found.Path)
        } else {
            Add-Check $officeName 'INFO' 'Not installed/detected; this app will be omitted from the student Start menu.'
        }
    }

    try {
        $testChrome = $chrome
        if (-not $testChrome) {
            $testChrome = Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'
        }
        $testProfile = '{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'
        $testXml = Build-AssignedAccessXml -ChromePath $testChrome -KioskUrl $Url -KioskDisplayName $DisplayName -ProfileId $testProfile -OfficeApps $officeApps
        [xml]$parsed = $testXml
        if ($parsed.DocumentElement.LocalName -ne 'AssignedAccessConfiguration') {
            throw 'Generated XML root element is incorrect.'
        }
        Add-Check 'Generated Assigned Access XML' 'PASS' 'The generated restricted multi-app XML is well formed.'
    } catch {
        Add-Check 'Generated Assigned Access XML' 'FAIL' $_.Exception.Message
    }

    $chromePolicyRoot = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
    if (Test-Path -LiteralPath $chromePolicyRoot) {
        Add-Check 'Existing Chrome computer policy' 'WARN' 'A machine-wide Chrome policy key already exists. This script will not overwrite it; existing organization policies may still affect Administrator and student Chrome.'
    } else {
        Add-Check 'Existing Chrome computer policy' 'PASS' 'No existing machine-wide Chrome policy key was detected.'
    }

    $canInstall = (@($checks | Where-Object Status -eq 'FAIL').Count -eq 0)
    $result = [pscustomobject]@{
        Version = $KioskVersion
        Generated = (Get-Date).ToString('o')
        CanInstall = $canInstall
        Checks = $checks.ToArray()
    }

    Write-JsonFile -InputObject $result -Path $PreflightJsonPath

    $text = New-Object System.Collections.Generic.List[string]
    $text.Add('YSNLC Kiosk Compatibility Preflight')
    $text.Add(('Generated: {0}' -f (Get-Date)))
    $text.Add(('Script version: {0}' -f $KioskVersion))
    $text.Add('')
    foreach ($check in $checks) {
        $text.Add(('[{0}] {1}: {2}' -f $check.Status, $check.Name, $check.Details))
    }
    $text.Add('')
    $text.Add(('RESULT: {0}' -f $(if ($canInstall) { 'READY TO INSTALL' } else { 'NOT READY' })))
    $text | Set-Content -LiteralPath $PreflightTextPath -Encoding UTF8

    if (-not $Quiet) {
        Write-Host ''
        Write-Host 'YSNLC Kiosk Compatibility Check' -ForegroundColor Cyan
        foreach ($check in $checks) {
            $color = switch ($check.Status) {
                'PASS' { 'Green' }
                'WARN' { 'Yellow' }
                'FAIL' { 'Red' }
                default { 'Gray' }
            }
            Write-Host ('[{0}] {1}: {2}' -f $check.Status, $check.Name, $check.Details) -ForegroundColor $color
        }
        Write-Host ''
        if ($canInstall) {
            Write-Host 'RESULT: READY TO INSTALL' -ForegroundColor Green
        } else {
            Write-Host 'RESULT: NOT READY - no kiosk configuration was applied.' -ForegroundColor Red
        }
        Write-Host "Preflight report: $PreflightTextPath" -ForegroundColor Cyan
    }

    return $result
}

function Complete-WithOptionalRestart {
    param([bool]$RestartRequired)

    if ($Restart) {
        Write-Log 'Restarting the computer now.' 'WARN'
        Restart-Computer -Force
        return
    }

    if ($RestartRequired) {
        Write-Host ''
        Write-Host 'A restart is required. Run this when ready:' -ForegroundColor Yellow
        Write-Host '  shutdown.exe /r /t 0' -ForegroundColor Yellow
    }
}

function Install-Kiosk {
    $preflight = Invoke-KioskPreflight -Quiet
    if (-not [bool]$preflight.CanInstall) {
        throw "Compatibility preflight failed. Review: $PreflightTextPath"
    }

    $windows = Get-WindowsInfo
    Write-Log "Detected $($windows.ProductName), edition $($windows.EditionId), version $($windows.DisplayVersion), build $($windows.CurrentBuild).$($windows.UBR)."
    Assert-SupportedEdition -WindowsInfo $windows
    Write-Log 'Before student use, confirm that every administrator account has a strong, nonblank password. The script cannot verify password strength.' 'WARN'

    $restartRequired = Enable-UacIfRequired
    if ($restartRequired) {
        Write-Log 'Windows preparation completed: UAC was enabled. Restart Windows and run the same installer again; no Assigned Access profile was applied.' 'WARN'
        Write-Host ''
        Write-Host 'RESTART REQUIRED BEFORE INSTALLATION CAN CONTINUE.' -ForegroundColor Yellow
        Write-Host 'Restart Windows, then run the same GitHub one-line installer again.' -ForegroundColor Yellow
        exit 10
    }

    $chrome = Get-ChromeExecutable
    if (-not $chrome) {
        $chrome = Install-ChromeEnterprise
    } else {
        Write-Log "Chrome found at: $chrome" 'OK'
    }

    $officeApps = @(Get-OfficeApps)
    foreach ($wanted in @('Microsoft Word','Microsoft Excel','Microsoft PowerPoint')) {
        $found = $officeApps | Where-Object Name -eq $wanted | Select-Object -First 1
        if ($found) {
            Write-Log "$wanted found at: $($found.Path)" 'OK'
        } else {
            Write-Log "$wanted was not found and will not appear for the student user. Install Microsoft Office/Microsoft 365 first if this app is required." 'WARN'
        }
    }

    $assignedAccessAttempted = $false
    $shortcutsCreated = $false
    $servicesChanged = $false
    $disabledUserInfo = [pscustomobject]@{
        Name       = $null
        WasEnabled = $false
    }

    try {
        Ensure-RequiredKioskServices
        $servicesChanged = $true
        Enable-AssignedAccessOperationalLog

        Set-ChromeKioskPolicies -KioskUrl $Url
        Install-KioskShortcuts -ChromePath $chrome -KioskUrl $Url -OfficeApps $officeApps
        $shortcutsCreated = $true

        $profileId = '{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'
        $xml = Build-AssignedAccessXml `
            -ChromePath $chrome `
            -KioskUrl $Url `
            -KioskDisplayName $DisplayName `
            -ProfileId $profileId `
            -OfficeApps $officeApps
        $xml | Set-Content -LiteralPath $XmlPath -Encoding UTF8

        # A normal local account named YSNLC would remain a route to an unrestricted desktop,
        # so disable it reversibly by default before creating the managed Assigned Access account.
        $disabledUserInfo = Disable-ConflictingLocalUser -UserName $DisableLocalUser
        Assert-NoEnabledStandardUsersRemain

        $state = [ordered]@{
            Version                     = $KioskVersion
            Experience                  = 'RestrictedMultiApp'
            Url                         = $Url
            DisplayName                 = $DisplayName
            ChromePath                  = $chrome
            OfficeApps                  = @($officeApps | ForEach-Object { [ordered]@{ Name = $_.Name; Path = $_.Path } })
            FileExplorerNamespace       = 'DownloadsOnly'
            ProfileId                   = $profileId
            ChromePolicyScope           = 'None-MachineWide'
            ShortcutRoot                = $ShortcutRoot
            DisabledLocalUserName       = $disabledUserInfo.Name
            DisabledLocalUserWasEnabled = $disabledUserInfo.WasEnabled
            InstalledAt                 = (Get-Date).ToString('o')
        }
        Write-JsonFile -InputObject $state -Path $StatePath

        $assignedAccessAttempted = $true
        Invoke-SystemTask -SystemMode Install
    } catch {
        $applyError = $_.Exception.Message
        Write-Log 'Restricted student experience setup failed. Attempting a safe rollback.' 'WARN'

        $assignedAccessCleared = -not $assignedAccessAttempted
        if ($assignedAccessAttempted) {
            if (Test-AssignedAccessBackupEvidence) {
                try {
                    Invoke-SystemTask -SystemMode Remove
                    $assignedAccessCleared = $true
                } catch {
                    Write-Log "Assigned Access rollback could not be confirmed: $($_.Exception.Message)" 'WARN'
                }
            } else {
                $assignedAccessCleared = $true
                Write-Log 'Assigned Access was not modified before the system-stage failure, so local rollback is safe.' 'WARN'
            }
        }

        if ($assignedAccessCleared) {
            try {
                Restore-ConflictingLocalUser -UserName ([string]$disabledUserInfo.Name) -WasEnabled ([bool]$disabledUserInfo.WasEnabled)
            } catch {
                Write-Log "The original local account could not be restored: $($_.Exception.Message)" 'WARN'
            }

            try {
                Remove-ManagedKioskUserIfPresent -ExpectedDisplayName $DisplayName
            } catch {
                Write-Log "Managed kiosk-user rollback failed: $($_.Exception.Message)" 'WARN'
            }

            if ($shortcutsCreated) {
                try { Remove-KioskShortcuts } catch { Write-Log "Shortcut rollback failed: $($_.Exception.Message)" 'WARN' }
            }
            if ($servicesChanged -or (Test-Path -LiteralPath $ServiceBackupPath)) {
                try { Restore-RequiredKioskServices } catch { Write-Log "Service rollback failed: $($_.Exception.Message)" 'WARN' }
            }

            Clear-AssignedAccessBackup
            foreach ($path in @($XmlPath, $StatePath, $SystemRequestPath, $SystemResultPath)) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Log 'The normal student account remains disabled because Windows could not confirm that Assigned Access was cleared.' 'WARN'
        }

        throw $applyError
    }

    Write-Log 'Restricted multi-app student experience installation is complete.' 'OK'
    Write-Host ''
    Write-Host 'IMPORTANT: Restart Windows to activate the restricted student account.' -ForegroundColor Green
    Write-Host 'Student Start menu: YSNLC Quiz App, Student Files, plus detected Word/Excel/PowerPoint.' -ForegroundColor Green
    Write-Host 'Student File Explorer access is restricted to Downloads.' -ForegroundColor Green
    Write-Host 'Chrome URL policies are not applied machine-wide; Administrator Chrome remains unrestricted.' -ForegroundColor Green
    Write-Host 'For administrator maintenance, press Ctrl+Alt+Del, sign out of the student account, then sign in as Administrator.' -ForegroundColor Yellow

    Complete-WithOptionalRestart -RestartRequired $true
}

function Remove-Kiosk {
    if (-not (Test-KioskInstallEvidence)) {
        throw 'No SchoolQuizKiosk installation record was found. No kiosk or Chrome policy changes were made.'
    }

    $display = $DisplayName
    $state = $null
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $state = Read-JsonFile -Path $StatePath
            if ($state.DisplayName) {
                $display = [string]$state.DisplayName
            }
        } catch {
            Write-Log "The state file could not be read: $($_.Exception.Message)" 'WARN'
        }
    }

    # Remove Assigned Access first. Do not unlock Chrome or a normal desktop account
    # if Windows cannot confirm that a profile applied by this script has been removed.
    if (Test-AssignedAccessBackupEvidence) {
        Invoke-SystemTask -SystemMode Remove
    } else {
        # The system stage writes a backup marker before changing Assigned Access. No marker
        # means a prior attempt stopped before Windows kiosk configuration was touched.
        Write-Log 'No SchoolQuizKiosk Assigned Access change marker was found; Windows kiosk configuration was left unchanged.' 'WARN'
    }
    if ((Test-Path -LiteralPath $ChromePolicyBackupPath) -or (Test-Path -LiteralPath $ChromePolicyAbsentMarker)) {
        Restore-ChromePolicies
    }

    try {
        Remove-KioskShortcuts
    } catch {
        Write-Log "The YSNLC Start shortcuts could not be removed: $($_.Exception.Message)" 'WARN'
    }

    if ($state) {
        try {
            Restore-ConflictingLocalUser `
                -UserName ([string]$state.DisabledLocalUserName) `
                -WasEnabled ([bool]$state.DisabledLocalUserWasEnabled)
        } catch {
            Write-Log "The original local account could not be restored: $($_.Exception.Message)" 'WARN'
        }
    }

    Remove-ManagedKioskUserIfPresent -ExpectedDisplayName $display
    try {
        Restore-RequiredKioskServices
    } catch {
        Write-Log "Required-service settings could not be fully restored: $($_.Exception.Message)" 'WARN'
    }
    Clear-AssignedAccessBackup

    foreach ($path in @($XmlPath, $StatePath, $SystemRequestPath, $SystemResultPath)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }

    Write-Log 'Restricted student experience removal is complete. Restart Windows to return to the normal sign-in experience.' 'OK'
    Complete-WithOptionalRestart -RestartRequired $true
}

# ---------------- Main entry point ----------------

if ($Stage -eq 'System') {
    Invoke-AssignedAccessSystemStage
}

if (-not (Test-IsAdministrator)) {
    Invoke-SelfElevated
    exit 0
}

try {
    Initialize-WorkingDirectory
    Write-Log "Starting mode=$Mode, stage=$Stage, scriptVersion=$KioskVersion"

    switch ($Mode) {
        'Install' {
            Install-Kiosk
        }
        'Remove' {
            Remove-Kiosk
        }
        'Diagnose' {
            $report = Write-DiagnosticReport
            Write-Host ''
            Write-Host "Diagnostics saved to: $report" -ForegroundColor Green
        }
        'Preflight' {
            $preflight = Invoke-KioskPreflight
            if (-not [bool]$preflight.CanInstall) {
                exit 2
            }
        }
    }
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    if ($_.ScriptStackTrace) {
        Write-Log ('PowerShell stack: ' + (($_.ScriptStackTrace -replace '[\r\n]+', ' | '))) 'ERROR'
    }
    $report = $null
    try {
        $report = Write-DiagnosticReport
    } catch {
        Write-Log "A diagnostic report could not be created: $($_.Exception.Message)" 'WARN'
    }

    Write-Host ''
    Write-Host 'The restricted student experience was not fully configured.' -ForegroundColor Red
    if ($report) {
        Write-Host "Review this report: $report" -ForegroundColor Yellow
    }
    Write-Host "Also review the log: $LogPath" -ForegroundColor Yellow
    exit 1
}
