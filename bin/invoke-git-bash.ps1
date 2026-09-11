# bin/invoke-git-bash.ps1 - locate Git for Windows bash.exe and run a .sh.
# Dot-sourced by the first-class PowerShell entry points in this repo.
# ASCII only: a BOM-less non-ASCII .ps1 is reparsed as CP949 by Windows
# PowerShell 5.1. Valid on both powershell.exe 5.1 and pwsh 7: no chain
# operators, no Kill(bool), no ternary, no null-coalescing.
#
# Locator order (do not resolve bash via PATH; WindowsApps ships a 0-byte WSL stub):
#   1. $env:ASIDE_GIT_BASH
#   2. C:\Program Files\Git\bin\bash.exe
#   3. C:\Program Files (x86)\Git\bin\bash.exe
#   4. HKLM:\SOFTWARE\GitForWindows InstallPath + \bin\bash.exe
#   5. (Get-Command git.exe).Source walked up to ..\bin\bash.exe
# Reject any path whose segments include WindowsApps. Require the file name
# bash.exe and a length greater than zero.
#
# Call:
#   & $bash --noprofile --norc $scriptMixed @args
#   exit $LASTEXITCODE
# Invoke via the call operator so $LASTEXITCODE and stdout are preserved.

function Invoke-GitBash {
  $candidates = @()
  if (-not [string]::IsNullOrEmpty($env:ASIDE_GIT_BASH)) {
    $candidates += $env:ASIDE_GIT_BASH
  }
  $candidates += 'C:\Program Files\Git\bin\bash.exe'
  $candidates += 'C:\Program Files (x86)\Git\bin\bash.exe'

  $regPath = 'HKLM:\SOFTWARE\GitForWindows'
  if (Test-Path -LiteralPath $regPath) {
    $reg = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
    if ($null -ne $reg) {
      $installPath = $reg.InstallPath
      if (-not [string]::IsNullOrEmpty($installPath)) {
        $candidates += (Join-Path $installPath 'bin\bash.exe')
      }
    }
  }

  $gitCmd = @(Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue)[0]
  if ($null -ne $gitCmd) {
    $gitSource = $gitCmd.Source
    if (-not [string]::IsNullOrEmpty($gitSource)) {
      $gitDir = Split-Path -Parent $gitSource
      $gitParent = Split-Path -Parent $gitDir
      if (-not [string]::IsNullOrEmpty($gitParent)) {
        $candidates += (Join-Path $gitParent 'bin\bash.exe')
      }
    }
  }

  $bash = $null
  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrEmpty($candidate)) {
      continue
    }
    $blocked = $false
    $parts = $candidate -split '[\\/]+'
    foreach ($part in $parts) {
      if ($part -eq 'WindowsApps') {
        $blocked = $true
      }
    }
    if ($blocked) {
      continue
    }
    $leaf = Split-Path -Leaf $candidate
    if ($leaf -ne 'bash.exe') {
      continue
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      continue
    }
    $item = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
    if ($null -eq $item) {
      continue
    }
    if ($item.Length -le 0) {
      continue
    }
    $bash = $item.FullName
    break
  }

  if ($null -eq $bash) {
    [Console]::Error.WriteLine('Git for Windows bash.exe was not found. Install Git for Windows. WSL bash is not used.')
    exit 1
  }

  if ($args.Count -lt 1) {
    [Console]::Error.WriteLine('Invoke-GitBash requires a script path.')
    exit 1
  }

  $ScriptPath = [string]$args[0]
  $forward = @()
  if ($args.Count -gt 1) {
    $forward = @($args[1..($args.Count - 1)])
  }

  $resolved = $ScriptPath
  if (-not [System.IO.Path]::IsPathRooted($resolved)) {
    $resolved = Join-Path (Get-Location).ProviderPath $resolved
  }
  $resolved = [System.IO.Path]::GetFullPath($resolved)
  $scriptMixed = $resolved -replace '\\', '/'

  & $bash --noprofile --norc $scriptMixed @forward
  exit $LASTEXITCODE
}
