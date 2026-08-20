#requires -Version 5.1
<#
.SYNOPSIS
  Installs, removes, or diagnoses a locked-down Google Chrome school quiz kiosk.

.DESCRIPTION
  - Uses Windows Assigned Access with a classic desktop application.
  - Auto-creates and auto-signs-in a standard kiosk account.
  - Starts Chrome full-screen at https://quiz.ysnlc.com/.
  - Launches Chrome only for the kiosk session; website filtering is left to your hosts/network filter.
  - Runs the Assigned Access MDM Bridge portion as LocalSystem by using a temporary scheduled task.
  - Reversibly disables the pre-existing standard account named YSNLC by default, so it
    cannot remain an unrestricted route to the desktop.
  - Includes rollback and diagnostics modes.

  IMPORTANT:
  1. This script is intended for Windows 11 Pro, Enterprise, Education, or IoT Enterprise.
  2. This version does NOT apply computer-wide Chrome URL policies. Administrator Chrome remains unrestricted.
  3. Modified/stripped Windows images can be missing Assigned Access components. The script
     detects that condition and writes a diagnostic report instead of attempting an unsafe hack.
  4. Website filtering is intentionally not enforced by this script. Use your hosts/network filtering
     if students must be prevented from visiting unrelated sites. Test the quiz on one computer first.
  5. Set a strong password on every administrator account before using the kiosk.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-SchoolQuizKiosk.ps1 -Mode Install -Restart

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-SchoolQuizKiosk.ps1 -Mode Remove -Restart

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-SchoolQuizKiosk.ps1 -Mode Diagnose
#>

[CmdletBinding()]
param(
    [ValidateSet('Install', 'Remove', 'Diagnose')]
    [string]$Mode = 'Install',

    [ValidatePattern('^https://')]
    [string]$Url = 'https://quiz.ysnlc.com/',

    [ValidateLength(1, 64)]
    [string]$DisplayName = 'YSNLC School Quiz',

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
$ChromePolicyBackupPath = Join-Path $Root 'ChromePolicies-BeforeKiosk.reg'
$ChromePolicyAbsentMarker = Join-Path $Root 'ChromePolicies-WereAbsent.marker'
$AssignedAccessBackupPath = Join-Path $Root 'AssignedAccess-BeforeKiosk.txt'
$AssignedAccessAbsentMarker = Join-Path $Root 'AssignedAccess-WasAbsent.marker'
$KioskVersion = '1.4.0'
$BreakoutSequence = 'Ctrl+Alt+Q'

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
        $AssignedAccessAbsentMarker
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
        [Parameter(Mandatory = $true)][string]$ProfileId
    )

    $arguments = "--kiosk $KioskUrl --incognito --no-first-run --no-default-browser-check --disable-session-crashed-bubble --disable-extensions --noerrdialogs --disable-pinch --overscroll-history-navigation=0"
    $escapedChromePath = [System.Security.SecurityElement]::Escape($ChromePath)
    $escapedArguments = [System.Security.SecurityElement]::Escape($arguments)
    $escapedDisplayName = [System.Security.SecurityElement]::Escape($KioskDisplayName)

    return @"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config"
    xmlns:rs5="http://schemas.microsoft.com/AssignedAccess/201810/config"
    xmlns:v4="http://schemas.microsoft.com/AssignedAccess/2021/config">
  <Profiles>
    <Profile Id="$ProfileId">
      <KioskModeApp v4:ClassicAppPath="$escapedChromePath" v4:ClassicAppArguments="$escapedArguments" />
      <v4:BreakoutSequence Key="$BreakoutSequence" />
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
        $message = $_.Exception.Message
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

    $lines.Add('School Quiz Kiosk diagnostics')
    $lines.Add(('Generated: {0}' -f (Get-Date)))
    $lines.Add(('Script version: {0}' -f $KioskVersion))
    $lines.Add('')
    $lines.Add(('Windows: {0}' -f $info.ProductName))
    $lines.Add(('EditionID: {0}' -f $info.EditionId))
    $lines.Add(('Version: {0}' -f $info.DisplayVersion))
    $lines.Add(('Build: {0}.{1}' -f $info.CurrentBuild, $info.UBR))
    $lines.Add(('UAC EnableLUA: {0}' -f $uac))
    $lines.Add(('Chrome: {0}' -f $(if ($chrome) { $chrome } else { 'Not found' })))
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

function Assert-NoEnabledStandardUsersRemain {
    $administratorsSid = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    $administrators = Get-LocalGroup -SID $administratorsSid -ErrorAction Stop
    $administratorSidSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($member in (Get-LocalGroupMember -Group $administrators -ErrorAction Stop)) {
        if ($member.SID) {
            [void]$administratorSidSet.Add([string]$member.SID)
        }
    }

    $remaining = New-Object System.Collections.Generic.List[string]
    foreach ($user in (Get-LocalUser -ErrorAction Stop)) {
        if (-not [bool]$user.Enabled) {
            continue
        }

        $sidText = [string]$user.SID
        if ($administratorSidSet.Contains($sidText)) {
            continue
        }

        $remaining.Add([string]$user.Name)
    }

    if ($remaining.Count -gt 0) {
        throw ('Enabled standard local accounts would still provide a normal Windows desktop: {0}. Disable or remove those accounts, then run the installer again.' -f ($remaining -join ', '))
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

    if ($user.Name -eq $env:USERNAME) {
        throw "Refusing to disable the administrator account currently running this script: $($user.Name)"
    }

    $sidText = [string]$user.SID
    if ($sidText -match '-500$') {
        throw "Refusing to disable the built-in Administrator account: $($user.Name)"
    }

    $administratorsSid = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    $administrators = Get-LocalGroup -SID $administratorsSid -ErrorAction Stop
    $isAdministrator = Get-LocalGroupMember -Group $administrators -ErrorAction Stop | Where-Object {
        [string]$_.SID -eq $sidText
    }
    if ($isAdministrator) {
        throw "Refusing to disable local administrator account: $($user.Name)"
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
    if (Test-KioskInstallEvidence) {
        throw 'A SchoolQuizKiosk installation or incomplete rollback is already recorded. Run this script with -Mode Remove before installing again.'
    }

    $windows = Get-WindowsInfo
    Write-Log "Detected $($windows.ProductName), edition $($windows.EditionId), version $($windows.DisplayVersion), build $($windows.CurrentBuild).$($windows.UBR)."
    Assert-SupportedEdition -WindowsInfo $windows
    Write-Log 'Before student use, confirm that every administrator account has a strong, nonblank password. The script cannot verify password strength.' 'WARN'

    $restartRequired = Enable-UacIfRequired

    $chrome = Get-ChromeExecutable
    if (-not $chrome) {
        $chrome = Install-ChromeEnterprise
    } else {
        Write-Log "Chrome found at: $chrome" 'OK'
    }

    # Kept for backward-compatible rollback logic; v1.4+ does not create machine-wide Chrome policies.
    $policySetupStarted = $false
    $assignedAccessAttempted = $false
    $disabledUserInfo = [pscustomobject]@{
        Name       = $null
        WasEnabled = $false
    }

    try {
        Set-ChromeKioskPolicies -KioskUrl $Url

        $profileId = '{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'
        $xml = Build-AssignedAccessXml -ChromePath $chrome -KioskUrl $Url -KioskDisplayName $DisplayName -ProfileId $profileId
        $xml | Set-Content -LiteralPath $XmlPath -Encoding UTF8

        # The screenshot shows a normal local account named YSNLC. A normal account
        # would remain a route to the desktop, so disable it reversibly by default.
        $disabledUserInfo = Disable-ConflictingLocalUser -UserName $DisableLocalUser
        Assert-NoEnabledStandardUsersRemain

        $state = [ordered]@{
            Version                       = $KioskVersion
            Url                           = $Url
            DisplayName                   = $DisplayName
            ChromePath                    = $chrome
            ProfileId                     = $profileId
            BreakoutSequence              = $BreakoutSequence
            ChromePolicyScope              = 'None-MachineWide'
            DisabledLocalUserName         = $disabledUserInfo.Name
            DisabledLocalUserWasEnabled   = $disabledUserInfo.WasEnabled
            InstalledAt                   = (Get-Date).ToString('o')
        }
        Write-JsonFile -InputObject $state -Path $StatePath

        $assignedAccessAttempted = $true
        Invoke-SystemTask -SystemMode Install
    } catch {
        $applyError = $_.Exception.Message
        Write-Log 'Kiosk setup failed. Attempting a safe rollback.' 'WARN'

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
                # The system stage creates a backup marker before it changes Assigned Access.
                # With no marker, it failed before touching the Windows kiosk configuration.
                $assignedAccessCleared = $true
                Write-Log 'Assigned Access was not modified before the system-stage failure, so local rollback is safe.' 'WARN'
            }
        }

        if ($assignedAccessCleared) {
            if ($policySetupStarted) {
                try {
                    Restore-ChromePolicies
                } catch {
                    Write-Log "Chrome policy rollback also failed: $($_.Exception.Message)" 'WARN'
                }
            }

            try {
                Restore-ConflictingLocalUser -UserName ([string]$disabledUserInfo.Name) -WasEnabled ([bool]$disabledUserInfo.WasEnabled)
            } catch {
                Write-Log "The original local account could not be restored: $($_.Exception.Message)" 'WARN'
            }

            Clear-AssignedAccessBackup
            foreach ($path in @($XmlPath, $StatePath, $SystemRequestPath, $SystemResultPath)) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Log 'Chrome restrictions and the disabled normal account were intentionally left in place because Windows could not confirm that Assigned Access was cleared. This prevents a partially configured kiosk from exposing an unrestricted desktop or browser.' 'WARN'
        }

        throw $applyError
    }

    Write-Log "Kiosk installation is complete. Maintenance breakout sequence: $BreakoutSequence" 'OK'
    Write-Host ''
    Write-Host 'IMPORTANT: The kiosk restrictions activate after restart.' -ForegroundColor Green
    Write-Host "To leave the kiosk for maintenance, press $BreakoutSequence and sign in to the administrator account." -ForegroundColor Green
    Write-Host 'Chrome URL policies are not applied machine-wide; Administrator Chrome remains unrestricted.' -ForegroundColor Green

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
    Restore-ChromePolicies

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
    Clear-AssignedAccessBackup

    foreach ($path in @($XmlPath, $StatePath, $SystemRequestPath, $SystemResultPath)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }

    Write-Log 'Kiosk removal is complete. Restart Windows to return to the normal sign-in experience.' 'OK'
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
    }
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    $report = $null
    try {
        $report = Write-DiagnosticReport
    } catch {
        Write-Log "A diagnostic report could not be created: $($_.Exception.Message)" 'WARN'
    }

    Write-Host ''
    Write-Host 'The kiosk was not fully configured.' -ForegroundColor Red
    if ($report) {
        Write-Host "Review this report: $report" -ForegroundColor Yellow
    }
    Write-Host "Also review the log: $LogPath" -ForegroundColor Yellow
    exit 1
}
