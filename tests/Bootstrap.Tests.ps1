#requires -Version 5.1
# Exercises the launch verifier without downloading files, elevating, or running setup.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'install.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("kiosk launch ' test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $PowerShellPath = (Get-Process -Id $PID).Path
    $quotedPowerShell = Quote-PowerShellLiteral $PowerShellPath
    $quotedSetup = Quote-PowerShellLiteral (Join-Path $scratch 'Setup-SchoolQuizKiosk.ps1')
    $quotedUpdater = Quote-PowerShellLiteral (Join-Path $scratch 'Update-SchoolQuizKiosk.ps1')
    $quotedTranscript = Quote-PowerShellLiteral (Join-Path $scratch 'elevated-install.log')
    $quotedSetupHash = Quote-PowerShellLiteral ('a' * 64)
    $quotedUpdaterHash = Quote-PowerShellLiteral ('b' * 64)
    $setupVersion = '2.7.1'
    $template = $ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$elevatedCode'
    }, $true) | Select-Object -First 1
    . ([scriptblock]::Create($template.Extent.Text))
    $templateTokens = $null
    $templateErrors = $null
    [Management.Automation.Language.Parser]::ParseInput($elevatedCode, [ref]$templateTokens, [ref]$templateErrors) | Out-Null
    Assert-True ($templateErrors.Count -eq 0) 'The expanded elevated installer must have valid PowerShell syntax.'

    $wrapperPath = Join-Path $scratch 'elevated-install.ps1'
    $markerPath = Join-Path $scratch 'ran.txt'
    $quotedMarker = Quote-PowerShellLiteral $markerPath
    # This wrapper is much larger than the reported failing encoded command.
    $safeWrapper = ('# Long installer body' + [Environment]::NewLine) * 2000
    $safeWrapper += "[IO.File]::WriteAllText($quotedMarker, 'verified'); exit 10"
    [IO.File]::WriteAllText($wrapperPath, $safeWrapper, (New-Object Text.UTF8Encoding $false))
    $hash = Get-Sha256Hex $wrapperPath
    $arguments = New-VerifiedBootstrapArguments -ScriptPath $wrapperPath -ExpectedHash $hash
    Assert-True ($arguments.Length -lt 8000) 'Launch arguments must stay short even when the installer body is large.'
    $childArguments = $arguments -split ' '
    & $PowerShellPath @childArguments | Out-Null
    Assert-True ($LASTEXITCODE -eq 10) 'The verifier must propagate the elevated installer exit code.'
    Assert-True ((Get-Content -LiteralPath $markerPath -Raw) -eq 'verified') 'The verified wrapper must execute, including paths with spaces and apostrophes.'

    Remove-Item -LiteralPath $markerPath
    [IO.File]::WriteAllText($wrapperPath, "[IO.File]::WriteAllText($quotedMarker, 'tampered')")
    # A child failure is expected; Windows PowerShell and PowerShell 7 report its stderr differently.
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $PowerShellPath @childArguments 2>&1 | Out-Null } finally { $ErrorActionPreference = $savedPreference }
    Assert-True ($LASTEXITCODE -eq 1) 'Changing the wrapper after hashing must return the verifier failure code.'
    Assert-True (-not (Test-Path -LiteralPath $markerPath)) 'Tampered wrapper bytes must never execute.'
    # GitHub's PowerShell step exits with LASTEXITCODE. The child failure above
    # is expected and already asserted; report success only after all checks pass.
    $global:LASTEXITCODE = 0
    Write-Host "PASS: expanded bootstrap syntax, large wrapper, short $($arguments.Length)-character launch, quoted paths, exit codes, and tamper rejection."
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
