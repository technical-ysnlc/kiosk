#requires -Version 5.1
# Runs without changing Windows policy or starting the installer.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
$setupAst = $null
foreach ($file in @('setup.ps1', 'install.ps1', 'Update-SchoolQuizKiosk.ps1')) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    if ($file -eq 'setup.ps1') { $setupAst = $ast }
}

# Load definitions only; never evaluate the setup entry point or machine settings.
foreach ($statement in $setupAst.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    } elseif ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $statement.Left.Extent.Text -in @('$OfflineVideoPath', '$OfflineVideoShortcutName')) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('kiosk-media-test-' + [guid]::NewGuid().ToString('N'))
$savedProgramFiles = $env:ProgramFiles
$savedProgramFilesX86 = ${env:ProgramFiles(x86)}
$savedWindir = $env:WINDIR
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $env:WINDIR = 'C:\Windows'
    $env:ProgramFiles = Join-Path $scratch 'Program Files'
    ${env:ProgramFiles(x86)} = Join-Path $scratch 'Program Files (x86)'
    Assert-True ($null -eq (Get-VlcExecutable)) 'Missing VLC must not produce a candidate.'
    $vlc32 = Join-Path ${env:ProgramFiles(x86)} 'VideoLAN\VLC\vlc.exe'
    $vlc64 = Join-Path $env:ProgramFiles 'VideoLAN\VLC\vlc.exe'
    foreach ($candidate in @($vlc32, $vlc64)) {
        New-Item -ItemType Directory -Path (Split-Path $candidate -Parent) -Force | Out-Null
        New-Item -ItemType File -Path $candidate | Out-Null
        Assert-True ((Get-VlcExecutable) -eq $candidate) 'VLC detection must support x86 and prefer Program Files when both exist.'
    }

    $argsForXml = @{
        ChromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
        KioskUrl = 'https://quiz.ysnlc.com/'
        KioskDisplayName = 'YSNLC-Student'
        ProfileId = '{11111111-1111-1111-1111-111111111111}'
        OfficeApps = @([pscustomobject]@{ Name = 'Microsoft Word'; Path = 'C:\Office\WINWORD.EXE' })
    }
    $vlcEscaped = 'C:\Program Files\Video & LAN\vlc.exe'
    [xml]$withMedia = Build-AssignedAccessXml @argsForXml -VlcPath $vlcEscaped
    [xml]$withoutMedia = Build-AssignedAccessXml @argsForXml
    $allowed = @($withMedia.SelectNodes('//*[local-name()="App"]') | ForEach-Object { $_.DesktopAppPath })
    Assert-True ($allowed -contains $vlcEscaped) 'VLC path must survive XML escaping.'
    Assert-True ($allowed -contains $argsForXml.ChromePath -and $allowed -contains 'C:\Windows\explorer.exe' -and $allowed -contains 'C:\Office\WINWORD.EXE') 'Existing allowed apps must remain.'
    Assert-True ($allowed.Count -eq 4) 'Only VLC should be added to the allowed apps.'
    $pins = ($withMedia.SelectSingleNode('//*[local-name()="StartPins"]').InnerText | ConvertFrom-Json).pinnedList
    Assert-True (@($pins | Where-Object { $_.desktopAppLink -like '*\Uchida-Kraepelin.lnk' }).Count -eq 1) 'Video must have exactly one Start pin.'
    Assert-True ($withoutMedia.OuterXml -notmatch 'Uchida-Kraepelin|vlc.exe') 'No VLC means no broken video pin.'
    Assert-True ($withMedia.SelectSingleNode('//*[local-name()="AllowedNamespace"]').Name -eq 'Downloads') 'Downloads restriction must remain.'
    $noOfficeArgs = $argsForXml.Clone()
    $noOfficeArgs.OfficeApps = @()
    [xml]$noOffice = Build-AssignedAccessXml @noOfficeArgs -VlcPath $vlcEscaped
    Assert-True ($noOffice.SelectNodes('//*[local-name()="App"]').Count -eq 3) 'VLC must work without Office installed.'

    $script:capturedShortcut = $null
    $script:warnings = @()
    function New-KioskShortcut {
        param($Name, $TargetPath, $Arguments, $IconLocation)
        $script:capturedShortcut = $PSBoundParameters
    }
    function Write-Log {
        param($Message, $Level)
        if ($Level -eq 'WARN') { $script:warnings += $Message }
    }
    Set-KioskOfflineVideoShortcut -VlcPath $vlc64
    Assert-True ($capturedShortcut.TargetPath -eq $vlc64) 'Shortcut must launch VLC directly.'
    Assert-True ($capturedShortcut.Arguments -ceq '"C:\Users\KioskUser0\Downloads\uchida-kraepelin.mp4"') 'Shortcut must quote the exact requested video path.'
    Assert-True ($warnings.Count -gt 0) 'A missing video should warn, not prevent configuration.'
    Set-KioskOfflineVideoShortcut -VlcPath $vlc64 -VideoPath 'C:\Users\KioskUser0.YS-LAB-CPU-3\Downloads\uchida-kraepelin.mp4'
    Assert-True ($capturedShortcut.Arguments -ceq '"C:\Users\KioskUser0.YS-LAB-CPU-3\Downloads\uchida-kraepelin.mp4"') 'Shortcut must support the actual SID-resolved Windows profile path.'

    $StatePath = Join-Path $scratch 'State.json'
    $XmlPath = Join-Path $scratch 'AssignedAccess.xml'
    $state = [ordered]@{
        ChromePath = $argsForXml.ChromePath; Url = $argsForXml.KioskUrl
        DisplayName = $argsForXml.KioskDisplayName; ProfileId = $argsForXml.ProfileId
        OfficeApps = $argsForXml.OfficeApps; Version = '2.5.3'
        DisabledLocalUserName = 'YSNLC'
    }
    Write-JsonFile -InputObject $state -Path $StatePath
    $script:applyCount = 0
    $script:failApply = $false
    function Invoke-SystemTask {
        param($SystemMode)
        $script:applyCount++
        if ($script:failApply) { throw 'Simulated policy failure' }
    }
    function Complete-WithOptionalRestart { param($RestartRequired) }
    Update-KioskOfflineMedia
    Assert-True ($applyCount -eq 1) 'An existing kiosk must receive the updated policy.'
    $updated = Read-JsonFile -Path $StatePath
    Assert-True ($updated.VlcPath -eq $vlc64 -and $updated.ProfileId -eq $state.ProfileId -and $updated.DisabledLocalUserName -eq 'YSNLC') 'Media update must persist VLC and preserve kiosk identity/state.'
    Update-KioskOfflineMedia
    Assert-True ($applyCount -eq 1) 'A repeat media update must not reapply unchanged policy.'

    # Simulate an old layout needing its YouTube pin after media has been enabled.
    function Set-KioskQuizShortcutAppMode { param($ChromePath, $KioskUrl) }
    function Set-KioskYouTubeShortcutAppMode { param($ChromePath) }
    function Set-SchoolYouTubeChromePolicies { }
    function Register-SchoolYouTubePolicyTask { }
    New-Item -ItemType File -Path (Join-Path $scratch 'chrome.exe') | Out-Null
    $updated.ChromePath = Join-Path $scratch 'chrome.exe'
    Write-JsonFile -InputObject $updated -Path $StatePath
    Update-SchoolYouTubePolicy
    Assert-True ((Get-Content -LiteralPath $XmlPath -Raw) -match 'Uchida-Kraepelin') 'YouTube layout refresh must retain the offline video.'

    $beforeState = Get-Content -LiteralPath $StatePath -Raw
    Remove-Item -LiteralPath $vlc64, $vlc32
    Update-KioskOfflineMedia
    Assert-True ((Get-Content -LiteralPath $StatePath -Raw) -ceq $beforeState) 'Missing VLC must leave state unchanged.'

    New-Item -ItemType File -Path $vlc32 | Out-Null
    $beforeXml = Get-Content -LiteralPath $XmlPath -Raw
    $script:failApply = $true
    $failed = $false
    try { Update-KioskOfflineMedia } catch { $failed = $true }
    Assert-True $failed 'Policy application failures must be reported.'
    Assert-True ((Get-Content -LiteralPath $XmlPath -Raw).Trim() -ceq $beforeXml.Trim()) 'Failed policy application must restore the local XML.'
    Assert-True ((Get-Content -LiteralPath $StatePath -Raw) -ceq $beforeState) 'Failed policy application must not record successful media state.'
    Write-Host 'PASS: syntax, VLC detection, shortcuts, allowed apps, pins, existing kiosk migration, repeat updates, YouTube preservation, and failure handling.'
} finally {
    $env:ProgramFiles = $savedProgramFiles
    ${env:ProgramFiles(x86)} = $savedProgramFilesX86
    $env:WINDIR = $savedWindir
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
