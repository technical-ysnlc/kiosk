#requires -Version 5.1
# Exercises in-place policy updates with simulated Windows accounts and CIM provider.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'setup.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Write-Log { param($Message, $Level) }
$script:originalSid = 'S-1-5-21-1-2-3-1001'
$script:originalPath = 'D:\Profiles\kioskUser0.YS-LAB-CPU-3'
$script:writes = New-Object 'System.Collections.Generic.List[string]'
$script:failure = ''
function Get-LocalUser {
    [CmdletBinding()] param()
    $sid = if ($script:failure -eq 'Account' -and $script:writes.Count -eq 1) { 'S-1-5-21-1-2-3-1002' } else { $script:originalSid }
    return [pscustomobject]@{ Name = 'kioskUser0'; FullName = 'YSNLC-Student'; SID = $sid }
}
function Get-CimInstance {
    [CmdletBinding()] param($ClassName, $Filter)
    $path = if ($script:failure -eq 'Profile' -and $script:writes.Count -eq 1) { 'D:\Profiles\unexpected' } else { $script:originalPath }
    return [pscustomobject]@{ SID = $script:originalSid; LocalPath = $path }
}
function Set-CimInstance {
    [CmdletBinding()] param($CimInstance)
    $script:writes.Add([string]$CimInstance.Configuration)
    if ($script:failure -eq 'Provider' -and $script:writes.Count -eq 1) { throw 'Simulated provider failure' }
}
$profileId = '{11111111-1111-1111-1111-111111111111}'
$previousXml = @"
<AssignedAccessConfiguration xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config" xmlns:rs5="http://schemas.microsoft.com/AssignedAccess/201810/config">
<Profiles><Profile Id="$profileId" Name="YSNLC Restricted Student Experience" /></Profiles>
<Configs><Config><AutoLogonAccount rs5:DisplayName="YSNLC-Student" /><DefaultProfile Id="$profileId" /></Config></Configs>
</AssignedAccessConfiguration>
"@
$nextXml = $previousXml.Replace('Experience"', 'Experience updated"')
$previousEncoded = [Net.WebUtility]::HtmlEncode($previousXml)
$instance = [pscustomobject]@{ Configuration = $previousEncoded }
Set-AssignedAccessConfigurationInPlace -Instance $instance -Xml $nextXml
Assert-True ($script:writes.Count -eq 1 -and $script:writes[0] -ceq [Net.WebUtility]::HtmlEncode($nextXml)) 'Maintenance must replace the configuration once, without clearing it first.'
foreach ($failure in @('Provider', 'Account', 'Profile')) {
    $script:writes.Clear()
    $script:failure = $failure
    $instance.Configuration = $previousEncoded
    $failed = $false
    try { Set-AssignedAccessConfigurationInPlace -Instance $instance -Xml $nextXml } catch { $failed = $true }
    Assert-True $failed "The $failure failure must be reported."
    Assert-True ($script:writes.Count -eq 2 -and $script:writes[1] -ceq $previousEncoded) 'Failure must restore the original active configuration directly.'
    Assert-True (@($script:writes | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) 'Maintenance and rollback must never clear configuration.'
}
$script:failure = ''
foreach ($invalidXml in @($nextXml.Replace($profileId, '{22222222-2222-2222-2222-222222222222}'), $nextXml.Replace('YSNLC-Student', 'DifferentAccount'))) {
    $script:writes.Clear()
    $instance.Configuration = $previousEncoded
    $failed = $false
    try { Set-AssignedAccessConfigurationInPlace -Instance $instance -Xml $invalidXml } catch { $failed = $true }
    Assert-True ($failed -and $script:writes.Count -eq 0) 'An account/display-name or profile-ID change must be rejected before writing Windows policy.'
}
$script:writes.Clear()
$instance.Configuration = $null
$failed = $false
try { Set-AssignedAccessConfigurationInPlace -Instance $instance -Xml $nextXml } catch { $failed = $true }
Assert-True ($failed -and $script:writes.Count -eq 0) 'Missing active configuration must not silently create a replacement account.'
Write-Host 'PASS: in-place policy replacement, preserved identity/path, provider rollback, identity/path mismatch detection, and missing-configuration refusal.'
