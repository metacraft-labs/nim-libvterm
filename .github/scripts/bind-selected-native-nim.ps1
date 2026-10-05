$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64') { throw 'Native x64 Nim binding does not qualify ARM64.' }
$root = [System.IO.Path]::GetFullPath($env:GITHUB_WORKSPACE)
$head = (& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $env:GITHUB_SHA) { throw 'Native Nim source HEAD is not the current tested checkout.' }
$before = [ordered]@{}
foreach ($relative in @('repro.nim', 'repro.lock', 'flake.lock', 'config.nims', 'Justfile', '.github/scripts/bind-selected-native-nim.ps1')) {
  $before[$relative] = (Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash
}
$proof = [ordered]@{ sourceHead=$head; sourceFiles=$before; scope='Same action-selected acquired native x64 Nim for original crosschecks; no historical compiler transfer' }
$directory = Join-Path $root '.repro/windows-native-provenance'
try {
  $census = Get-Content -Raw -LiteralPath (Join-Path $directory 'ambient-executables.json') | ConvertFrom-Json
  if ($census.sourceHead -ne $head) { throw 'Prior source-bound census is stale.' }
  foreach ($file in $census.sourceFiles) {
    if (-not $before.Contains($file.path) -or $before[$file.path] -ne $file.sha256) { throw 'Current source differs from pre-typed census.' }
  }
  $inspectionPath = Join-Path $root '.repro/build/repro/path-only-tool-identities.inspect.json'
  $inspection = Get-Content -Raw -LiteralPath $inspectionPath | ConvertFrom-Json
  if ($inspection.projectName -ne 'nim_libvterm') { throw 'Foreign selected tool inspection.' }
  $profiles = @($inspection.profiles | Where-Object { $_.packageSelector -eq 'nim' -or $_.executableName -eq 'nim' })
  if ($profiles.Count -ne 1) { throw 'Missing or ambiguous selected Nim profile.' }
  $profile = $profiles[0]
  $archiveSha = 'fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f'
  if ($profile.packageSelector -ne 'nim' -or $profile.executableName -ne 'nim' -or $profile.packageId -ne 'nim@2.2.10' -or $profile.installMethod -ne 'tarball' -or $profile.archiveType -ne 'zip' -or $profile.stripComponents -ne 1 -or $profile.tarballSha256 -ne $archiveSha -or $profile.tarballUrl -ne 'https://nim-lang.org/download/nim-2.2.10_x64.zip' -or $profile.tarballSelectedUrl -ne $profile.tarballUrl -or $profile.declaredExecutablePath -ne 'bin/nim.exe' -or $profile.resolvedExecutableDigest -ne 'blake3:0aac2d15f0babe0a5ee234acdd3d550e180fe1cf5febc6cc10179482a4481680') { throw 'Selected Nim acquisition identity differs from the reviewed current profile.' }
  $prefix = [System.IO.Path]::GetFullPath($profile.selectedStorePath)
  $prefixParent = [System.IO.Path]::GetFullPath((Join-Path $root '.repro/build/repro/tool-store/prefixes/nim'))
  if ([System.IO.Path]::GetDirectoryName($prefix) -ne $prefixParent -or $profile.lockIdentity -ne "tarball:nim@2.2.10:sha256:$archiveSha" -or $profile.realizationBoundary -ne $profile.selectedStorePath -or @($profile.realizedStorePaths).Count -ne 1 -or $profile.realizedStorePaths[0] -ne $profile.selectedStorePath) { throw 'Foreign or ambiguous Nim prefix.' }
  $cursor = $prefix
  while ($cursor.Length -gt $root.Length) {
    if ((Get-Item -LiteralPath $cursor).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'Selected Nim prefix traverses a reparse-point alias.' }
    $cursor = [System.IO.Path]::GetDirectoryName($cursor)
  }
  if ($cursor -ne $root) { throw 'Selected Nim prefix is not within the owning source root.' }
  $nim = Join-Path $prefix 'bin/nim.exe'
  if ([System.IO.Path]::GetFullPath($profile.resolvedExecutablePath) -ne [System.IO.Path]::GetFullPath($nim)) { throw 'Selected Nim executable does not match its acquired prefix.' }
  $archive = Join-Path $root ".repro/build/repro/tool-store/downloads/$archiveSha.archive"
  if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archiveSha) { throw 'Missing or wrong acquired Nim archive.' }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
  $files = [ordered]@{}
  try {
    $nimEntries = @($zip.Entries | Where-Object { $_.FullName -match '^[^/]+/bin/nim.exe$' })
    if ($nimEntries.Count -ne 1) { throw 'Missing or ambiguous archive Nim executable.' }
    $archiveRoot = $nimEntries[0].FullName.Substring(0, $nimEntries[0].FullName.Length - 'bin/nim.exe'.Length)
    $entries = @($zip.Entries | Where-Object { $_.FullName -eq $nimEntries[0].FullName -or $_.FullName.StartsWith($archiveRoot + 'config/') -or $_.FullName.StartsWith($archiveRoot + 'lib/') })
    foreach ($entry in $entries) {
      if ($entry.FullName.EndsWith('/')) { continue }
      $relative = $entry.FullName.Substring($archiveRoot.Length)
      if ($relative -match '(^|/)\.\.(/|$)' -or $files.Contains($relative)) { throw 'Unsafe or duplicate Nim archive member.' }
      $path = [System.IO.Path]::GetFullPath((Join-Path $prefix $relative))
      if (-not $path.StartsWith($prefix + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Nim archive member escapes prefix.' }
      $item = Get-Item -LiteralPath $path
      if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw 'Nim member is not a regular acquired file.' }
      $stream = $entry.Open()
      $algorithm = [System.Security.Cryptography.SHA256]::Create()
      try { $archiveFileSha = ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '') }
      finally { $stream.Dispose(); $algorithm.Dispose() }
      $fileSha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
      if ($fileSha -ne $archiveFileSha) { throw "Selected Nim differs from acquired archive: $relative" }
      $files[$relative] = $fileSha
    }
  } finally { $zip.Dispose() }
  foreach ($required in @('bin/nim.exe', 'config/nim.cfg', 'lib/system.nim', 'lib/pure/times.nim', 'lib/std/monotimes.nim', 'lib/pure/asyncdispatch.nim')) {
    if (-not $files.Contains($required)) { throw "Missing acquired Nim closure member: $required" }
  }
  $bytes = [System.IO.File]::ReadAllBytes($nim)
  if ($bytes.Length -lt 64 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) { throw 'Invalid native Nim PE.' }
  $offset = [BitConverter]::ToInt32($bytes, 60)
  if ($offset -lt 0 -or $offset + 6 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $offset) -ne 17744 -or [BitConverter]::ToUInt16($bytes, $offset + 4) -ne 34404) { throw 'Nim is not native AMD64.' }
  $version = (& $nim --version | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $version -notmatch '^Nim Compiler Version 2\.2\.10 \[Windows: amd64\]') { throw 'Wrong selected native Nim version.' }
  $proof.inspectionSha256 = (Get-FileHash -LiteralPath $inspectionPath -Algorithm SHA256).Hash
  $proof.profile = $profile
  $proof.archiveSha256 = $archiveSha
  $proof.nimPath = $nim
  $proof.peMachine = '0x8664'
  $proof.version = $version
  $proof.archiveMatchedFiles = $files
} catch { $proof.failure = $_.Exception.Message }
finally {
  $proof.finalHead = (& git -C $root rev-parse HEAD).Trim()
  $proof.sourceUnchanged = $proof.finalHead -eq $head
  foreach ($relative in $before.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash -ne $before[$relative]) { $proof.sourceUnchanged = $false }
  }
  if (-not $proof.sourceUnchanged) { $proof.failure = 'Source changed during native Nim binding.' }
  $proof | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $directory 'selected-native-nim.json')
}
if ($proof.Contains('failure')) { throw $proof.failure }
Add-Content -LiteralPath $env:GITHUB_PATH -Value (Join-Path $prefix 'bin')
