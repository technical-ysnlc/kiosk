#requires -Version 5.1
<#
.SYNOPSIS
  Checks for and installs verified updates to the YSNLC School Quiz Kiosk management script.

.DESCRIPTION
  The updater reads update.json from the technical-ysnlc/kiosk GitHub repository, downloads
  setup.ps1, verifies its SHA-256 hash, validates its PowerShell syntax and embedded version,
  creates a local backup, and replaces the protected working copy at:

      C:\ProgramData\SchoolQuizKiosk\Setup-SchoolQuizKiosk.ps1

  The updater can also install a LocalSystem scheduled task that checks at startup and daily.

  IMPORTANT:
  - This updater updates the management script only. It does not silently remove, reinstall,
    reconfigure, or restart an active kiosk.
  - A new script that changes Chrome policies or Assigned Access settings must be tested on one
    computer and then applied during an administrator maintenance window.
  - Automatic updates from any remote repository are a supply-chain risk. This script pins the
    repository URLs, requires HTTPS, validates a repository-published SHA-256 value, checks the
    embedded version, and refuses automatic major-version upgrades unless -Force is used.

.EXAMPLE
  .\Update-SchoolQuizKiosk.ps1 -Mode Check

.EXAMPLE
  .\Update-SchoolQuizKiosk.ps1 -Mode Update

.EXAMPLE
  .\Update-SchoolQuizKiosk.ps1 -Mode InstallTask

.EXAMPLE
  .\Update-SchoolQuizKiosk.ps1 -Mode RemoveTask
#>

[CmdletBinding()]
param(
    [ValidateSet('Check', 'Update', 'InstallTask', 'RemoveTask', 'Status')]
    [string]$Mode = 'Check',

    [ValidatePattern('^https://')]
    [string]$ManifestUrl = 'https://raw.githubusercontent.com/technical-ysnlc/kiosk/main/update.json',

    [string]$TargetPath = '',

    [switch]$Force,

    [switch]$AllowDowngrade,

    [switch]$Quiet,

    [ValidateRange(1, 20)]
    [int]$KeepBackups = 5,

    [ValidateRange(1, 10)]
    [int]$RetryCount = 3,

    [ValidateRange(1, 300)]
    [int]$RetryDelaySeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$UpdaterVersion = '1.0.0'
$ExpectedProductId = 'school-quiz-kiosk'
$ExpectedRepositoryPrefix = '/technical-ysnlc/kiosk/'
$Root = Join-Path $env:ProgramData 'SchoolQuizKiosk'
$UpdatesRoot = Join-Path $Root 'Updates'
$InstalledUpdater = Join-Path $Root 'Update-SchoolQuizKiosk.ps1'
$UpdaterLogPath = Join-Path $Root 'Updater.log'
$UpdaterStatePath = Join-Path $Root 'UpdaterState.json'
$TaskName = 'SchoolQuizKiosk-Updater'
$script:CurrentScriptUrl = $null

if ([string]::IsNullOrWhiteSpace($TargetPath)) {
    $TargetPath = Join-Path $Root 'Setup-SchoolQuizKiosk.ps1'
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-PowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-SelfElevated {
    if (-not $PSCommandPath) {
        throw 'Save this updater as a .ps1 file before running it.'
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('& ' + (Quote-PowerShellLiteral -Value $PSCommandPath))
    $parts.Add('-Mode ' + (Quote-PowerShellLiteral -Value $Mode))
    $parts.Add('-ManifestUrl ' + (Quote-PowerShellLiteral -Value $ManifestUrl))
    $parts.Add('-TargetPath ' + (Quote-PowerShellLiteral -Value $TargetPath))
    $parts.Add('-KeepBackups ' + [string]$KeepBackups)
    $parts.Add('-RetryCount ' + [string]$RetryCount)
    $parts.Add('-RetryDelaySeconds ' + [string]$RetryDelaySeconds)

    if ($Force) {
        $parts.Add('-Force')
    }
    if ($AllowDowngrade) {
        $parts.Add('-AllowDowngrade')
    }
    if ($Quiet) {
        $parts.Add('-Quiet')
    }

    $command = $parts -join ' '
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" | Out-Null
}

function Initialize-WorkingDirectory {
    foreach ($path in @($Root, $UpdatesRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    # The folder contains scripts that can run as LocalSystem. Standard users must not be able
    # to replace them. This intentionally matches the permissions used by the kiosk installer.
    & "$env:SystemRoot\System32\icacls.exe" $Root `
        '/inheritance:r' `
        '/grant:r' `
        '*S-1-5-18:(OI)(CI)F' `
        '*S-1-5-32-544:(OI)(CI)F' *> $null

    if ($LASTEXITCODE -ne 0) {
        throw "Could not secure the kiosk working folder: $Root"
    }
}

function Write-UpdaterLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        Add-Content -LiteralPath $UpdaterLogPath -Value $line -Encoding UTF8
    } catch {
        # Logging must not hide the original updater result.
    }

    if (-not $Quiet) {
        switch ($Level) {
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'OK'    { Write-Host $line -ForegroundColor Green }
            default { Write-Host $line }
        }
    }
}

function Write-UpdaterState {
    param(
        [Parameter(Mandatory = $true)][string]$Result,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()][string]$InstalledVersion,
        [AllowNull()][string]$AvailableVersion,
        [AllowNull()][string]$InstalledSha256,
        [AllowNull()][string]$AvailableSha256,
        [AllowNull()][string]$SourceCommit
    )

    $state = [ordered]@{
        UpdaterVersion    = $UpdaterVersion
        LastCheckUtc      = [DateTime]::UtcNow.ToString('o')
        Result            = $Result
        Message           = $Message
        InstalledVersion  = $InstalledVersion
        AvailableVersion  = $AvailableVersion
        InstalledSha256   = $InstalledSha256
        AvailableSha256   = $AvailableSha256
        SourceCommit      = $SourceCommit
        TargetPath        = $TargetPath
        ManifestUrl       = $ManifestUrl
        ScriptUrl         = $script:CurrentScriptUrl
    }

    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $UpdaterStatePath -Encoding UTF8
}

function Assert-TrustedRepositoryUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $uri = [Uri]$Url
    if ($uri.Scheme -ne 'https') {
        throw "$Description must use HTTPS."
    }

    if ($uri.Host -ne 'raw.githubusercontent.com') {
        throw "$Description must use raw.githubusercontent.com. Received host: $($uri.Host)"
    }
    if (-not $uri.IsDefaultPort -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw "$Description contains an unexpected port or user-information component."
    }
    if (-not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw "$Description must not contain a query string or fragment."
    }

    if (-not $uri.AbsolutePath.StartsWith($ExpectedRepositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must remain inside the technical-ysnlc/kiosk repository."
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            return & $Operation
        } catch {
            $lastError = $_
            if ($attempt -lt $RetryCount) {
                Write-UpdaterLog "$Description failed on attempt $attempt of $RetryCount. Retrying in $RetryDelaySeconds seconds. Error: $($_.Exception.Message)" 'WARN'
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }

    throw "$Description failed after $RetryCount attempts. Last error: $($lastError.Exception.Message)"
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Object.PSObject.Properties.Name -notcontains $Name) {
        throw "The update manifest is missing the required property '$Name'."
    }

    return $Object.$Name
}

function Get-UpdateManifest {
    Assert-TrustedRepositoryUrl -Url $ManifestUrl -Description 'Manifest URL'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $manifestResponse = Invoke-WithRetry -Description 'Downloading the update manifest' -Operation {
        Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing -TimeoutSec 60 -Headers @{ 'Cache-Control' = 'no-cache' }
    }

    try {
        $manifest = [string]$manifestResponse.Content | ConvertFrom-Json
    } catch {
        throw "The downloaded update manifest is not valid JSON: $($_.Exception.Message)"
    }

    $schemaVersion = [int](Get-RequiredProperty -Object $manifest -Name 'schemaVersion')
    $productId = [string](Get-RequiredProperty -Object $manifest -Name 'productId')
    $versionText = [string](Get-RequiredProperty -Object $manifest -Name 'version')
    $hashText = [string](Get-RequiredProperty -Object $manifest -Name 'sha256')
    $manifestScriptUrl = [string](Get-RequiredProperty -Object $manifest -Name 'scriptUrl')

    if ($schemaVersion -ne 1) {
        throw "Unsupported update manifest schema version: $schemaVersion"
    }
    if ($productId -ne $ExpectedProductId) {
        throw "Unexpected update product ID: $productId"
    }

    $remoteVersion = $null
    try {
        $remoteVersion = [version]$versionText
    } catch {
        throw "The update manifest contains an invalid version: $versionText"
    }

    if ($hashText -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The update manifest SHA-256 value is invalid.'
    }

    Assert-TrustedRepositoryUrl -Url $manifestScriptUrl -Description 'Manifest script URL'

    $minimumUpdaterVersion = $null
    if ($manifest.PSObject.Properties.Name -contains 'minimumUpdaterVersion') {
        $minimumUpdaterVersion = [string]$manifest.minimumUpdaterVersion
        if (-not [string]::IsNullOrWhiteSpace($minimumUpdaterVersion)) {
            $minimumVersion = $null
            try {
                $minimumVersion = [version]$minimumUpdaterVersion
            } catch {
                throw "The manifest contains an invalid minimumUpdaterVersion: $minimumUpdaterVersion"
            }

            if ([version]$UpdaterVersion -lt $minimumVersion) {
                throw "Updater $UpdaterVersion is too old for this release. Install updater $minimumUpdaterVersion or later manually."
            }
        }
    }

    $sourceCommit = $null
    if ($manifest.PSObject.Properties.Name -contains 'sourceCommit') {
        $sourceCommit = [string]$manifest.sourceCommit
    }

    $scriptUri = [Uri]$manifestScriptUrl
    if (-not $scriptUri.AbsolutePath.EndsWith('/setup.ps1', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The manifest script URL must point to setup.ps1 in the trusted repository.'
    }

    if (-not [string]::IsNullOrWhiteSpace($sourceCommit)) {
        if ($sourceCommit -notmatch '^[A-Fa-f0-9]{40}$') {
            throw 'The manifest sourceCommit value must be a full 40-character Git commit SHA.'
        }

        $expectedPath = '/technical-ysnlc/kiosk/' + $sourceCommit + '/setup.ps1'
        if (-not $scriptUri.AbsolutePath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The manifest script URL does not match its sourceCommit value.'
        }
    } else {
        $bootstrapPath = '/technical-ysnlc/kiosk/main/setup.ps1'
        if (-not $scriptUri.AbsolutePath.Equals($bootstrapPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A manifest without sourceCommit must point to setup.ps1 on the main branch.'
        }
    }
    $script:CurrentScriptUrl = $manifestScriptUrl

    return [pscustomobject]@{
        Version       = $remoteVersion
        VersionText   = $versionText
        Sha256        = $hashText.ToLowerInvariant()
        ScriptUrl     = $manifestScriptUrl
        SourceCommit  = $sourceCommit
        RawManifest   = $manifest
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-KioskScriptVersion {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $match = [regex]::Match(
        $content,
        '(?m)^\s*\$KioskVersion\s*=\s*''(?<version>\d+(?:\.\d+){2,3})''\s*$'
    )

    if (-not $match.Success) {
        return $null
    }

    try {
        return [version]$match.Groups['version'].Value
    } catch {
        return $null
    }
}

function Assert-ValidDownloadedScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $downloadedFile = Get-Item -LiteralPath $Path
    if ($downloadedFile.Length -lt 1024 -or $downloadedFile.Length -gt 2MB) {
        throw "Downloaded script size is outside the expected range: $($downloadedFile.Length) bytes."
    }

    $actualHash = Get-Sha256 -Path $Path
    if ($actualHash -ne $Manifest.Sha256) {
        throw "Downloaded script hash mismatch. Expected $($Manifest.Sha256), received $actualHash."
    }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "Downloaded script failed PowerShell syntax validation: $details"
    }

    $downloadedVersion = Get-KioskScriptVersion -Path $Path
    if ($null -eq $downloadedVersion) {
        throw 'Downloaded script does not contain a valid $KioskVersion value.'
    }
    if ($downloadedVersion -ne $Manifest.Version) {
        throw "Downloaded script version $downloadedVersion does not match manifest version $($Manifest.Version)."
    }

    $firstLine = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    if ($firstLine -notmatch '^#requires\s+-Version\s+5\.1') {
        throw 'Downloaded script does not declare the expected Windows PowerShell 5.1 requirement.'
    }

    return [pscustomobject]@{
        Version = $downloadedVersion
        Sha256  = $actualHash
    }
}

function Get-LocalScriptInfo {
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        return [pscustomobject]@{
            Exists      = $false
            Version     = $null
            VersionText = $null
            Sha256      = $null
        }
    }

    $localVersion = Get-KioskScriptVersion -Path $TargetPath
    return [pscustomobject]@{
        Exists      = $true
        Version     = $localVersion
        VersionText = $(if ($null -eq $localVersion) { $null } else { $localVersion.ToString() })
        Sha256      = (Get-Sha256 -Path $TargetPath)
    }
}

function Get-UpdateDecision {
    param(
        [Parameter(Mandatory = $true)]$Local,
        [Parameter(Mandatory = $true)]$Manifest
    )

    if (-not $Local.Exists) {
        return [pscustomobject]@{ Action = 'Update'; Reason = 'The installed management script is missing.' }
    }

    if ($null -eq $Local.Version) {
        if ($Force) {
            return [pscustomobject]@{ Action = 'Update'; Reason = 'The unreadable local script was explicitly approved for replacement with -Force.' }
        }
        return [pscustomobject]@{ Action = 'Manual'; Reason = 'The installed management script version could not be read; administrator review and -Force are required.' }
    }

    if ($Manifest.Version -lt $Local.Version) {
        if (-not $AllowDowngrade) {
            return [pscustomobject]@{ Action = 'Skip'; Reason = "Installed version $($Local.Version) is newer than repository version $($Manifest.Version); downgrade refused." }
        }
        if ($Manifest.Version.Major -ne $Local.Version.Major -and -not $Force) {
            return [pscustomobject]@{ Action = 'Manual'; Reason = "Major-version downgrade $($Local.Version) to $($Manifest.Version) requires both -AllowDowngrade and -Force." }
        }
        return [pscustomobject]@{ Action = 'Update'; Reason = "Downgrade from $($Local.Version) to $($Manifest.Version) was explicitly approved." }
    }

    if ($Manifest.Version -gt $Local.Version) {
        if ($Manifest.Version.Major -ne $Local.Version.Major -and -not $Force) {
            return [pscustomobject]@{ Action = 'Manual'; Reason = "Major-version update $($Local.Version) to $($Manifest.Version) requires administrator review and -Force." }
        }
        return [pscustomobject]@{ Action = 'Update'; Reason = "Version $($Manifest.Version) is newer than installed version $($Local.Version)." }
    }

    if ($Local.Sha256 -ne $Manifest.Sha256) {
        if ($Force) {
            return [pscustomobject]@{ Action = 'Update'; Reason = 'A same-version SHA-256 mismatch was reviewed and replacement was explicitly approved with -Force.' }
        }
        return [pscustomobject]@{ Action = 'Manual'; Reason = 'Version numbers match, but the installed SHA-256 differs; administrator review and -Force are required.' }
    }

    if ($Force) {
        return [pscustomobject]@{ Action = 'Update'; Reason = 'A forced reinstall of the current verified version was requested.' }
    }

    return [pscustomobject]@{ Action = 'Current'; Reason = "Version $($Local.Version) and SHA-256 are current." }
}

function Download-VerifiedUpdate {
    param([Parameter(Mandatory = $true)]$Manifest)

    $tempName = 'setup-{0}-{1}.download' -f $Manifest.VersionText, [Guid]::NewGuid().ToString('N')
    $tempPath = Join-Path $UpdatesRoot $tempName

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WithRetry -Description 'Downloading the kiosk setup script' -Operation {
            Invoke-WebRequest -Uri $Manifest.ScriptUrl -OutFile $tempPath -UseBasicParsing -TimeoutSec 60 -Headers @{ 'Cache-Control' = 'no-cache' }
        } | Out-Null

        Assert-ValidDownloadedScript -Path $tempPath -Manifest $Manifest | Out-Null
        return $tempPath
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Remove-OldBackups {
    $backups = @(Get-ChildItem -LiteralPath $UpdatesRoot -Filter 'Setup-SchoolQuizKiosk-*.backup.ps1' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)

    if ($backups.Count -gt $KeepBackups) {
        $backups | Select-Object -Skip $KeepBackups | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Install-VerifiedUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$DownloadedPath,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Local
    )

    $targetDirectory = Split-Path -Parent $TargetPath
    if (-not (Test-Path -LiteralPath $targetDirectory)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }

    $stagedPath = $TargetPath + '.new'
    $backupPath = $null
    $targetExistedBeforeUpdate = [bool]$Local.Exists

    try {
        Copy-Item -LiteralPath $DownloadedPath -Destination $stagedPath -Force
        Assert-ValidDownloadedScript -Path $stagedPath -Manifest $Manifest | Out-Null

        if ($Local.Exists) {
            $oldVersion = if ([string]::IsNullOrWhiteSpace($Local.VersionText)) { 'unknown' } else { $Local.VersionText }
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupName = 'Setup-SchoolQuizKiosk-{0}-{1}.backup.ps1' -f $oldVersion, $timestamp
            $backupPath = Join-Path $UpdatesRoot $backupName
            Copy-Item -LiteralPath $TargetPath -Destination $backupPath -Force
        }

        if (Test-Path -LiteralPath $TargetPath) {
            [IO.File]::Replace($stagedPath, $TargetPath, $null)
        } else {
            Move-Item -LiteralPath $stagedPath -Destination $TargetPath
        }
        Unblock-File -LiteralPath $TargetPath -ErrorAction SilentlyContinue

        $installedHash = Get-Sha256 -Path $TargetPath
        $installedVersion = Get-KioskScriptVersion -Path $TargetPath
        if ($installedHash -ne $Manifest.Sha256 -or $installedVersion -ne $Manifest.Version) {
            throw 'Post-install verification of the updated management script failed.'
        }

        Remove-OldBackups
        Write-UpdaterLog "Updated the kiosk management script to version $($Manifest.Version). Backup: $backupPath" 'OK'
    } catch {
        if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
            try {
                Copy-Item -LiteralPath $backupPath -Destination $TargetPath -Force
                Write-UpdaterLog "The previous management script was restored from $backupPath after an update failure." 'WARN'
            } catch {
                Write-UpdaterLog "Automatic restoration of the previous management script failed: $($_.Exception.Message)" 'ERROR'
            }
        } elseif (-not $targetExistedBeforeUpdate) {
            Remove-Item -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $DownloadedPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CheckForUpdate {
    $manifest = Get-UpdateManifest
    $local = Get-LocalScriptInfo
    $decision = Get-UpdateDecision -Local $local -Manifest $manifest

    $installedVersion = if ($null -eq $local.Version) { $null } else { $local.Version.ToString() }
    Write-UpdaterState `
        -Result $decision.Action `
        -Message $decision.Reason `
        -InstalledVersion $installedVersion `
        -AvailableVersion $manifest.Version.ToString() `
        -InstalledSha256 $local.Sha256 `
        -AvailableSha256 $manifest.Sha256 `
        -SourceCommit $manifest.SourceCommit

    switch ($decision.Action) {
        'Current' { Write-UpdaterLog $decision.Reason 'OK' }
        'Update'  { Write-UpdaterLog $decision.Reason 'WARN' }
        'Manual'  { Write-UpdaterLog $decision.Reason 'WARN' }
        default   { Write-UpdaterLog $decision.Reason 'INFO' }
    }

    return [pscustomobject]@{
        Manifest = $manifest
        Local    = $local
        Decision = $decision
    }
}

function Invoke-UpdateNow {
    $check = Invoke-CheckForUpdate

    if ($check.Decision.Action -ne 'Update') {
        return
    }

    $downloadedPath = Download-VerifiedUpdate -Manifest $check.Manifest
    Install-VerifiedUpdate -DownloadedPath $downloadedPath -Manifest $check.Manifest -Local $check.Local

    $updatedLocal = Get-LocalScriptInfo
    Write-UpdaterState `
        -Result 'Updated' `
        -Message "The kiosk management script was updated to version $($check.Manifest.Version)." `
        -InstalledVersion $updatedLocal.Version.ToString() `
        -AvailableVersion $check.Manifest.Version.ToString() `
        -InstalledSha256 $updatedLocal.Sha256 `
        -AvailableSha256 $check.Manifest.Sha256 `
        -SourceCommit $check.Manifest.SourceCommit
}

function Install-UpdaterScheduledTask {
    if (-not $PSCommandPath) {
        throw 'The current updater path cannot be determined.'
    }

    $source = [IO.Path]::GetFullPath($PSCommandPath)
    $destination = [IO.Path]::GetFullPath($InstalledUpdater)
    if (-not $source.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    Unblock-File -LiteralPath $InstalledUpdater -ErrorAction SilentlyContinue

    $powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Update -ManifestUrl "{1}" -TargetPath "{2}" -KeepBackups {3} -RetryCount {4} -RetryDelaySeconds {5} -Quiet' -f `
        $InstalledUpdater.Replace('"', '\"'), `
        $ManifestUrl.Replace('"', '\"'), `
        $TargetPath.Replace('"', '\"'), `
        $KeepBackups, `
        $RetryCount, `
        $RetryDelaySeconds
    $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments

    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At ([DateTime]::Today.AddHours(3))
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger @($startupTrigger, $dailyTrigger) `
        -Principal $principal `
        -Settings $settings `
        -Description 'Checks GitHub for a verified School Quiz Kiosk management-script update.' `
        -Force | Out-Null

    Write-UpdaterLog "Installed scheduled task '$TaskName'. It checks at startup and daily at 03:00." 'OK'
    Invoke-UpdateNow
}

function Remove-UpdaterScheduledTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-UpdaterLog "Removed scheduled task '$TaskName'." 'OK'

    $currentPath = $null
    if ($PSCommandPath) {
        $currentPath = [IO.Path]::GetFullPath($PSCommandPath)
    }
    $installedPath = [IO.Path]::GetFullPath($InstalledUpdater)

    if ($currentPath -and $currentPath.Equals($installedPath, [StringComparison]::OrdinalIgnoreCase)) {
        Write-UpdaterLog "The updater file was left at $InstalledUpdater because it is the script currently running. It can be deleted after this window closes." 'WARN'
    } else {
        Remove-Item -LiteralPath $InstalledUpdater -Force -ErrorAction SilentlyContinue
    }
}

function Show-UpdaterStatus {
    $local = Get-LocalScriptInfo
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host 'School Quiz Kiosk Updater Status' -ForegroundColor Cyan
    Write-Host "Updater version:        $UpdaterVersion"
    Write-Host "Target script:          $TargetPath"
    Write-Host "Target exists:          $($local.Exists)"
    Write-Host "Installed version:      $(if ($local.Version) { $local.Version } else { 'Unknown/not installed' })"
    Write-Host "Installed SHA-256:      $(if ($local.Sha256) { $local.Sha256 } else { 'N/A' })"
    Write-Host "Scheduled task:         $(if ($task) { $task.State } else { 'Not installed' })"
    Write-Host "Updater log:            $UpdaterLogPath"
    Write-Host "Updater state:          $UpdaterStatePath"
    Write-Host "Backup folder:          $UpdatesRoot"

    if (Test-Path -LiteralPath $UpdaterStatePath) {
        Write-Host ''
        Write-Host 'Last recorded check:' -ForegroundColor Cyan
        Get-Content -LiteralPath $UpdaterStatePath -Raw -Encoding UTF8 | Write-Host
    }
}

# ---------------- Main entry point ----------------

if (-not (Test-IsAdministrator)) {
    Invoke-SelfElevated
    exit 0
}

try {
    Initialize-WorkingDirectory
    Write-UpdaterLog "Starting mode=$Mode, updaterVersion=$UpdaterVersion"

    switch ($Mode) {
        'Check' {
            Invoke-CheckForUpdate | Out-Null
        }
        'Update' {
            Invoke-UpdateNow
        }
        'InstallTask' {
            Install-UpdaterScheduledTask
        }
        'RemoveTask' {
            Remove-UpdaterScheduledTask
        }
        'Status' {
            Show-UpdaterStatus
        }
    }
} catch {
    Write-UpdaterLog $_.Exception.Message 'ERROR'
    if (-not $Quiet) {
        Write-Host ''
        Write-Host "Updater failed. Review: $UpdaterLogPath" -ForegroundColor Yellow
    }
    exit 1
}
