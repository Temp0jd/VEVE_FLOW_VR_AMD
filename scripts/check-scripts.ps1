<#
.SYNOPSIS
    Checks the other scripts in this repository for two mistakes that PowerShell only reports at
    run time.

.DESCRIPTION
    1. Syntax errors, via the same parser PowerShell itself uses.
    2. A variable whose name collides with one of the script's own parameters - most importantly
       a [switch] parameter: PowerShell variable names are case-insensitive and a declared
       parameter keeps its type constraint for the whole script scope, so `foreach ($check in
       $checks)` inside a script that has `[switch]$Check` fails with

         Cannot convert the "System.Collections.Hashtable" value ... to type
         "System.Management.Automation.SwitchParameter"

       at run time only. That is exactly how setup-pc.ps1 once broke the real run while
       `-Check` itself still worked.

    Run it after editing any script in this repository:

        powershell -ExecutionPolicy Bypass -File scripts\check-scripts.ps1
#>
param([switch]$Quiet)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$files = @()
$files += Get-ChildItem (Join-Path $PSScriptRoot "*.ps1")
$files += Get-ChildItem (Join-Path $Root "*.ps1") -ErrorAction SilentlyContinue
$files += Get-ChildItem (Join-Path $Root "Wave_Native_SDK\samples\wvr_flow_probe\tools\*.ps1") -ErrorAction SilentlyContinue
$files = $files | Where-Object { $_.Name -ne "check-scripts.ps1" } | Sort-Object FullName -Unique

$failed = 0
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $failed++
        Write-Host "FAIL $($file.Name)" -ForegroundColor Red
        $errors | Select-Object -First 5 | ForEach-Object {
            Write-Host "     line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red
        }
        continue
    }

    # Parameters of the script itself, with their type constraints.
    $parameters = @{}
    foreach ($parameter in $ast.ParamBlock.Parameters) {
        $name = $parameter.Name.VariablePath.UserPath
        $type = ""
        if ($parameter.StaticType) { $type = $parameter.StaticType.Name }
        $parameters[$name] = $type
    }

    # Everything after the param block, ignoring function bodies (they get their own scope).
    $functionRanges = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { @{ Start = $_.Extent.StartOffset; End = $_.Extent.EndOffset } })
    $isInFunction = {
        param($offset)
        foreach ($range in $functionRanges) {
            if ($offset -ge $range.Start -and $offset -le $range.End) { return $true }
        }
        return $false
    }

    # Two things go wrong here. A [switch]/[bool] parameter only accepts booleans, so assigning
    # anything else to it fails at run time - that is the setup-pc.ps1 -Check / $check bug. A
    # foreach variable receives whatever the collection holds, so it can break a parameter of any
    # type the same way. A plain assignment to an untyped or string parameter is the normal
    # "override the default" pattern and is only worth a note.
    $assigned = @()
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($node.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $assigned += @{ Name = $node.Left.VariablePath.UserPath; Kind = "assignment"; Offset = $node.Extent.StartOffset; Line = $node.Extent.StartLineNumber }
        }
    }
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        $assigned += @{ Name = $node.Variable.VariablePath.UserPath; Kind = "foreach"; Offset = $node.Extent.StartOffset; Line = $node.Extent.StartLineNumber }
    }

    $collisions = @()
    $notes = @()
    foreach ($entry in $assigned) {
        if (& $isInFunction $entry.Offset) { continue }
        if (-not $parameters.ContainsKey($entry.Name)) { continue }
        $type = $parameters[$entry.Name]
        $booleanOnly = @("SwitchParameter", "Boolean", "Bool", "switch", "bool") -contains $type
        if ($booleanOnly) {
            $collisions += "line $($entry.Line): `$$($entry.Name) is the script parameter [$type] $($entry.Name), which only accepts a boolean"
        } elseif ($entry.Kind -eq "foreach") {
            $collisions += "line $($entry.Line): a foreach variable named `$$($entry.Name) would overwrite the script parameter [$type] $($entry.Name)"
        } else {
            $notes += "line $($entry.Line): `$$($entry.Name) overwrites the script parameter $($entry.Name) (fine if that is meant as a default)"
        }
    }

    if ($collisions.Count -gt 0) {
        $failed++
        Write-Host "FAIL $($file.Name)" -ForegroundColor Red
        $collisions | Select-Object -Unique | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
    } elseif (-not $Quiet) {
        Write-Host "ok   $($file.Name)" -ForegroundColor Green
    }
    if (-not $Quiet) {
        foreach ($note in ($notes | Select-Object -Unique)) { Write-Host "     note: $note" -ForegroundColor DarkGray }
    }
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "$failed script(s) failed; nothing else in this repository is affected." -ForegroundColor Red
    exit 1
}
Write-Host "$($files.Count) scripts checked, no problems found." -ForegroundColor Green
