#requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap installer for the YSNLC School Quiz Kiosk.

.DESCRIPTION
  Intended to be launched from a Windows PowerShell or Terminal PowerShell window with:

      irm https://raw.githubusercontent.com/technical-ysnlc/kiosk/main/install.ps1 | iex

  The bootstrap downloads update.json, requires commit-pinned payload URLs, downloads and
  verifies setup.ps1 and Update-SchoolQuizKiosk.ps1, requests administrator elevation,
  installs the kiosk, installs the scheduled updater, and schedules a Windows restart.

  Re-running the command on a computer with an active SchoolQuizKiosk installation does not
  reinstall or reconfigure the kiosk. It only installs or repairs the automatic updater.

  The setup and updater payloads are saved to disk before execution because setup.ps1 relies
  on its own file path for elevation and its LocalSystem configuration stage.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BootstrapVersion = '1.0.1'
$ManifestUrl = 'https://raw.githubusercontent.com/technical-ysnlc/kiosk/main/update.json'
$ExpectedProductId = 'school-quiz-kiosk'
$ExpectedRepositoryPath = '/technical-ysnlc/kiosk/'
$PowerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$TempRoot = Join-Path $env:TEMP ('SchoolQuizKiosk-Bootstrap-' + [Guid]::NewGuid().ToString('N'))

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Object.PSObject.Properties.Name -notcontains $Name) {
        throw "The update manifest is missing the required property '$Name'."
    }

    $value = $Object.$Name
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        throw "The update manifest property '$Name' is empty."
    }
    return $value
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [ValidateRange(1, 5)][int]$RetryCount = 3
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $lastError = $null

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            Invoke-WebRequest `
                -Uri $Url `
                -OutFile $OutFile `
                -UseBasicParsing `
                -TimeoutSec 60 `
                -Headers @{
                    'Cache-Control' = 'no-cache'
                    'User-Agent' = "SchoolQuizKiosk-Bootstrap/$BootstrapVersion"
                }
            return
        } catch {
            $lastError = $_
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    }

    throw "Could not download $Url after $RetryCount attempts. $($lastError.Exception.Message)"
}

function Assert-TrustedPayloadUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        throw "$FileName has an invalid URL in update.json."
    }
    if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'raw.githubusercontent.com') {
        throw "$FileName must be downloaded through HTTPS from raw.githubusercontent.com."
    }
    if (-not $uri.IsDefaultPort -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw "$FileName URL contains an unexpected port or user-information component."
    }
    if (-not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw "$FileName URL must not contain a query string or fragment."
    }

    $expectedPath = $ExpectedRepositoryPath + $SourceCommit + '/' + $FileName
    if (-not $uri.AbsolutePath.Equals($expectedPath, [StringComparison]::Ordinal)) {
        throw "$FileName URL is not pinned to manifest commit $SourceCommit."
    }
}

function Assert-PowerShellPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$VersionVariable,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 1024 -or $item.Length -gt 2MB) {
        throw "Downloaded file size is outside the expected range: $Path ($($item.Length) bytes)."
    }

    $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -cne $ExpectedSha256.ToLowerInvariant()) {
        throw "SHA-256 verification failed for $Path. Expected $ExpectedSha256, received $actualSha256."
    }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell syntax validation failed for ${Path}: $details"
    }

    $firstLine = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    if ($firstLine -notmatch '^#requires\s+-Version\s+5\.1') {
        throw "$Path does not declare the expected Windows PowerShell 5.1 requirement."
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $variablePattern = [regex]::Escape($VersionVariable)
    $versionPattern = '(?m)^\s*\${0}\s*=\s*''(?<version>\d+(?:\.\d+){{2,3}})''\s*$' -f $variablePattern
    $versionMatch = [regex]::Match($content, $versionPattern)
    if (-not $versionMatch.Success) {
        throw "$Path does not contain a valid `$$VersionVariable assignment."
    }
    if ($versionMatch.Groups['version'].Value -cne $ExpectedVersion) {
        throw "$Path version $($versionMatch.Groups['version'].Value) does not match manifest version $ExpectedVersion."
    }

    Unblock-File -LiteralPath $Path -ErrorAction SilentlyContinue
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

try {
    if ($env:OS -cne 'Windows_NT') {
        throw 'This bootstrap installer must be run on Windows.'
    }
    if (-not (Test-Path -LiteralPath $PowerShellPath)) {
        throw "Windows PowerShell 5.1 was not found at $PowerShellPath."
    }

    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
    $manifestPath = Join-Path $TempRoot 'update.json'
    $setupPath = Join-Path $TempRoot 'Setup-SchoolQuizKiosk.ps1'
    $updaterPath = Join-Path $TempRoot 'Update-SchoolQuizKiosk.ps1'

    Write-Host ''
    Write-Host "YSNLC School Quiz Kiosk bootstrap v$BootstrapVersion" -ForegroundColor Cyan
    Write-Host 'Downloading the update manifest...' -ForegroundColor Cyan
    Invoke-Download -Url $ManifestUrl -OutFile $manifestPath

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "The downloaded update.json file is invalid: $($_.Exception.Message)"
    }

    $schemaVersion = [int](Get-RequiredProperty -Object $manifest -Name 'schemaVersion')
    $productId = [string](Get-RequiredProperty -Object $manifest -Name 'productId')
    $sourceCommit = ([string](Get-RequiredProperty -Object $manifest -Name 'sourceCommit')).ToLowerInvariant()
    $setupVersion = [string](Get-RequiredProperty -Object $manifest -Name 'version')
    $setupUrl = [string](Get-RequiredProperty -Object $manifest -Name 'scriptUrl')
    $setupSha256 = ([string](Get-RequiredProperty -Object $manifest -Name 'sha256')).ToLowerInvariant()
    $minimumUpdaterVersion = [string](Get-RequiredProperty -Object $manifest -Name 'minimumUpdaterVersion')
    $updaterVersion = [string](Get-RequiredProperty -Object $manifest -Name 'updaterVersion')
    $updaterUrl = [string](Get-RequiredProperty -Object $manifest -Name 'updaterUrl')
    $updaterSha256 = ([string](Get-RequiredProperty -Object $manifest -Name 'updaterSha256')).ToLowerInvariant()

    if ($schemaVersion -ne 1) {
        throw "Unsupported update manifest schema version: $schemaVersion"
    }
    if ($productId -cne $ExpectedProductId) {
        throw "Unexpected update manifest product ID: $productId"
    }
    if ($sourceCommit -notmatch '^[a-f0-9]{40}$') {
        throw 'update.json has not yet been published correctly. sourceCommit must be a full 40-character commit SHA.'
    }
    if ($setupVersion -notmatch '^\d+(?:\.\d+){2,3}$' -or
        $updaterVersion -notmatch '^\d+(?:\.\d+){2,3}$' -or
        $minimumUpdaterVersion -notmatch '^\d+(?:\.\d+){2,3}$') {
        throw 'The setup or updater version in update.json is invalid.'
    }
    if ([Version]$updaterVersion -lt [Version]$minimumUpdaterVersion) {
        throw "Updater version $updaterVersion is below the required minimum $minimumUpdaterVersion."
    }
    if ($setupSha256 -notmatch '^[a-f0-9]{64}$' -or $updaterSha256 -notmatch '^[a-f0-9]{64}$') {
        throw 'The setup or updater SHA-256 value in update.json is invalid.'
    }

    Assert-TrustedPayloadUrl -Url $setupUrl -SourceCommit $sourceCommit -FileName 'setup.ps1'
    Assert-TrustedPayloadUrl -Url $updaterUrl -SourceCommit $sourceCommit -FileName 'Update-SchoolQuizKiosk.ps1'

    Write-Host "Downloading kiosk setup $setupVersion from commit $($sourceCommit.Substring(0, 12))..." -ForegroundColor Cyan
    Invoke-Download -Url $setupUrl -OutFile $setupPath
    Assert-PowerShellPayload `
        -Path $setupPath `
        -ExpectedSha256 $setupSha256 `
        -VersionVariable 'KioskVersion' `
        -ExpectedVersion $setupVersion

    Write-Host "Downloading updater $updaterVersion from the same commit..." -ForegroundColor Cyan
    Invoke-Download -Url $updaterUrl -OutFile $updaterPath
    Assert-PowerShellPayload `
        -Path $updaterPath `
        -ExpectedSha256 $updaterSha256 `
        -VersionVariable 'UpdaterVersion' `
        -ExpectedVersion $updaterVersion

    Write-Host 'Both payloads passed URL, SHA-256, syntax, and version verification.' -ForegroundColor Green

    # Re-verify the payload hashes inside the elevated process before executing anything. This
    # closes the ordinary-user-to-administrator time-of-check/time-of-use gap for the temp files.
    $quotedPowerShell = Quote-PowerShellLiteral -Value $PowerShellPath
    $quotedSetup = Quote-PowerShellLiteral -Value $setupPath
    $quotedUpdater = Quote-PowerShellLiteral -Value $updaterPath
    $quotedSetupHash = Quote-PowerShellLiteral -Value $setupSha256
    $quotedUpdaterHash = Quote-PowerShellLiteral -Value $updaterSha256

    $elevatedCode = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'

function Assert-VerifiedFile {
    param([string]`$Path, [string]`$ExpectedHash)
    if (-not (Test-Path -LiteralPath `$Path)) {
        throw "Verified payload disappeared before elevation: `$Path"
    }
    `$actual = (Get-FileHash -LiteralPath `$Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if (`$actual -cne `$ExpectedHash) {
        throw "Payload changed after verification: `$Path"
    }
    `$tokens = `$null
    `$errors = `$null
    [System.Management.Automation.Language.Parser]::ParseFile(`$Path, [ref]`$tokens, [ref]`$errors) | Out-Null
    if (`$errors -and `$errors.Count -gt 0) {
        throw "Payload syntax validation failed after elevation: `$Path"
    }
}

try {
    Assert-VerifiedFile -Path $quotedSetup -ExpectedHash $quotedSetupHash
    Assert-VerifiedFile -Path $quotedUpdater -ExpectedHash $quotedUpdaterHash

    `$kioskRoot = Join-Path `$env:ProgramData 'SchoolQuizKiosk'
    `$statePath = Join-Path `$kioskRoot 'State.json'

    if (Test-Path -LiteralPath `$statePath) {
        Write-Host ''
        Write-Host 'An active SchoolQuizKiosk installation was detected.' -ForegroundColor Yellow
        Write-Host 'The kiosk will not be reinstalled or reconfigured.' -ForegroundColor Yellow
        Write-Host 'Installing or repairing the automatic updater...' -ForegroundColor Cyan
        & $quotedPowerShell -NoProfile -ExecutionPolicy Bypass -File $quotedUpdater -Mode InstallTask
        if (`$LASTEXITCODE -ne 0) {
            throw "Updater installation returned exit code `$LASTEXITCODE."
        }
        Write-Host 'Automatic updater installation or repair completed. No restart was requested.' -ForegroundColor Green
        exit 0
    }

    Write-Host ''
    Write-Host 'Installing the School Quiz Kiosk...' -ForegroundColor Cyan
    & $quotedPowerShell -NoProfile -ExecutionPolicy Bypass -File $quotedSetup -Mode Install
    if (`$LASTEXITCODE -ne 0) {
        throw "Kiosk setup returned exit code `$LASTEXITCODE."
    }

    try {
        Write-Host ''
        Write-Host 'Installing the verified automatic updater...' -ForegroundColor Cyan
        & $quotedPowerShell -NoProfile -ExecutionPolicy Bypass -File $quotedUpdater -Mode InstallTask
        if (`$LASTEXITCODE -ne 0) {
            throw "Updater installation returned exit code `$LASTEXITCODE."
        }
        Write-Host 'Automatic updater installed successfully.' -ForegroundColor Green
    } catch {
        Write-Warning "The kiosk was installed, but the automatic updater could not be installed: `$(`$_.Exception.Message)"
        Write-Warning 'After restart, sign in as Administrator and run the one-line installer again to repair the updater.'
    }

    Write-Host ''
    Write-Host 'Installation completed. Windows will restart in 30 seconds.' -ForegroundColor Green
    Write-Host 'To cancel the scheduled restart, run: shutdown.exe /a' -ForegroundColor Yellow
    & "`$env:SystemRoot\System32\shutdown.exe" /r /t 30 /f /c "School Quiz Kiosk installation completed"
    if (`$LASTEXITCODE -ne 0) {
        throw 'Windows restart could not be scheduled. Run shutdown.exe /r /t 0 manually.'
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host "One-line kiosk installation failed: `$(`$_.Exception.Message)" -ForegroundColor Red
    Write-Host 'The computer was not scheduled to restart by this installer.' -ForegroundColor Yellow
    exit 1
}
"@

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevatedCode))
    $argumentList = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"

    Write-Host ''
    if (-not (Test-IsAdministrator)) {
        Write-Host 'Administrator approval is required. Accept the Windows UAC prompt.' -ForegroundColor Yellow
        $process = Start-Process `
            -FilePath $PowerShellPath `
            -Verb RunAs `
            -ArgumentList $argumentList `
            -Wait `
            -PassThru
    } else {
        $process = Start-Process `
            -FilePath $PowerShellPath `
            -ArgumentList $argumentList `
            -Wait `
            -PassThru
    }

    if ($process.ExitCode -ne 0) {
        throw "The elevated installer returned exit code $($process.ExitCode)."
    }

    Write-Host 'Bootstrap completed successfully.' -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "Bootstrap failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'No unverified PowerShell payload was executed.' -ForegroundColor Yellow
    throw
} finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
