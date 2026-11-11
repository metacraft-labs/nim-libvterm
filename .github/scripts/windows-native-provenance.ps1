$ErrorActionPreference = 'Stop'
function Get-NativeFileSha256([string]$Path) {
  $algorithm = [System.Security.Cryptography.SHA256]::Create()
  $stream = $null
  try {
    $stream = [System.IO.File]::OpenRead($Path)
    return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
  }
  finally {
    if ($null -ne $stream) { $stream.Dispose() }
    $algorithm.Dispose()
  }
}
$records = @()
foreach ($name in @('repro','nim','gcc','g++')) {
  $commands = @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)
  $entries = @()
  foreach ($command in $commands) {
    $path = $command.Source
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $machine = $null
    if ($bytes.Length -ge 64 -and $bytes[0] -eq 77 -and $bytes[1] -eq 90) {
      $offset = [BitConverter]::ToInt32($bytes,60)
      if ($offset -ge 0 -and $offset + 6 -le $bytes.Length -and [BitConverter]::ToUInt32($bytes,$offset) -eq 17744) {
        $machine = ('0x{0:x4}' -f [BitConverter]::ToUInt16($bytes,$offset+4))
      }
    }
    $versionOutput = @(& $path --version 2>&1 | ForEach-Object { $_.ToString() })
    $versionExit = $LASTEXITCODE
    $nimFiles = @()
    if ($name -eq 'nim') {
      $candidateRoot = Split-Path (Split-Path $path -Parent) -Parent
      foreach ($relative in @('config\nim.cfg','config\config.nims','lib\nimbase.h')) {
        $candidate = Join-Path $candidateRoot $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          $nimFiles += [ordered]@{ path=$candidate; sha256=(Get-NativeFileSha256 $candidate) }
        }
      }
    }
    $entries += [ordered]@{ path=$path; sha256=(Get-NativeFileSha256 $path); peMachine=$machine; versionExit=$versionExit; versionOutput=$versionOutput; candidateNimFiles=$nimFiles }
  }
  $records += [ordered]@{ name=$name; available=($entries.Count -gt 0); executableCandidates=$entries }
}
$source = @()
foreach ($name in @('repro.nim','repro.lock','flake.lock','config.nims','nim.cfg')) {
  if (Test-Path -LiteralPath $name -PathType Leaf) {
    $source += [ordered]@{ path=$name; sha256=(Get-NativeFileSha256 $name) }
  }
}
$proof = [ordered]@{ sourceHead=(& git rev-parse HEAD); scope='Ambient dev-exec executable census; action-scoped provisioned identities must be read separately'; executables=$records; sourceFiles=$source }
$directory = Join-Path $env:GITHUB_WORKSPACE '.repro\windows-native-provenance'
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$proof | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $directory 'ambient-executables.json')
