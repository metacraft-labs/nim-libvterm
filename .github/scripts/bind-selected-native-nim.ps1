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
  $expectedVersion = '2.2.10'
  if ($profile.installMethod -eq 'path') {
    $expectedVersion = '2.2.8'
    $nim = [System.IO.Path]::GetFullPath($profile.resolvedExecutablePath)
    if ($profile.packageSelector -ne 'nim' -or $profile.packageId -ne 'nim' -or $profile.executableName -ne 'nim' -or $profile.declaredExecutablePath -ne 'nim' -or $nim -ne 'C:\dev-deps\nim\bin\nim.exe' -or $profile.resolvedExecutableDigest -ne 'blake3:8d42d677439c59b4c4ab37ac62b8f5a707aca621f9e15ada89b81321b28c166a' -or $profile.selectedStorePath -ne '' -or $profile.lockIdentity -ne '' -or @($profile.realizedStorePaths).Count -ne 0 -or $profile.tarballUrl -ne '' -or $profile.tarballSha256 -ne '') { throw 'Unreviewed native PATH Nim profile.' }
    $applications = @(@(Get-Command nim -CommandType Application -All -ErrorAction Stop).Source | ForEach-Object { [System.IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
    if ($applications.Count -ne 1 -or $applications[0] -ne $nim) { throw 'Native PATH lookup is ambiguous or differs from the selected action.' }
    $candidates = @(@($census.executables | Where-Object name -eq 'nim').executableCandidates)
    if ($candidates.Count -ne 1 -or [System.IO.Path]::GetFullPath($candidates[0].path) -ne $nim -or $candidates[0].sha256 -ne '6179EC4B30EE26F6352E55B915603554E2C86F1D38895698156EFB54A5438A84') { throw 'Selected native PATH compiler differs from the source-bound census.' }
    if ((Get-FileHash -LiteralPath $nim -Algorithm SHA256).Hash -ne $candidates[0].sha256) { throw 'Selected native PATH executable bytes changed.' }
    $prefix = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($nim))
    foreach ($path in @($nim, (Join-Path $prefix 'bin'), (Join-Path $prefix 'config'), (Join-Path $prefix 'lib'))) {
      if ((Get-Item -LiteralPath $path).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'Native PATH compiler member is a reparse alias.' }
    }
    $cursor = $prefix
    while ($cursor) {
      if ((Get-Item -LiteralPath $cursor).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'Native PATH prefix traverses a reparse alias.' }
      $cursor = [System.IO.Path]::GetDirectoryName($cursor)
    }
    $files = [ordered]@{ 'bin/nim.exe'=$candidates[0].sha256 }
    foreach ($subdir in @('config','lib')) {
      foreach ($item in Get-ChildItem -LiteralPath (Join-Path $prefix $subdir) -Recurse -Force) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'Native PATH compiler closure includes a reparse alias.' }
        if ($item.PSIsContainer) { continue }
        $relative = $item.FullName.Substring($prefix.Length + 1).Replace('\','/')
        if ($files.Contains($relative)) { throw 'Duplicate native PATH closure member.' }
        $files[$relative] = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
      }
    }
    $configExpected = @{ 'config/nim.cfg'='AE2B00FCF124E9692C497E4520EB24C2B1F871236F4D7DEF5078191548B49DF0'; 'config/config.nims'='4374064E561486E481427F3077F6670354874A69F2CAD04F2663753B8753E8B9'; 'lib/nimbase.h'='28491D05916EAB446DE054370808030B33B63FD5623DCD454212ADEC27EE934D' }
    foreach ($relative in $configExpected.Keys) {
      if (-not $files.Contains($relative) -or $files[$relative] -ne $configExpected[$relative]) { throw "Unreviewed native PATH compiler configuration: $relative" }
    }
    foreach ($required in @('lib/system.nim','lib/pure/times.nim','lib/std/monotimes.nim','lib/pure/asyncdispatch.nim')) {
      if (-not $files.Contains($required)) { throw "Missing native PATH standard library: $required" }
    }
    $proof.nativePathMatchedFiles = $files
    $proof.bindingVariant = 'already-selected-native-path-2.2.8'
  } else {
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
  }
  $bytes = [System.IO.File]::ReadAllBytes($nim)
  if ($bytes.Length -lt 64 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) { throw 'Invalid native Nim PE.' }
  $offset = [BitConverter]::ToInt32($bytes, 60)
  if ($offset -lt 0 -or $offset + 6 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $offset) -ne 17744 -or [BitConverter]::ToUInt16($bytes, $offset + 4) -ne 34404) { throw 'Nim is not native AMD64.' }
  $version = (& $nim --version | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $version -notmatch ('^Nim Compiler Version ' + [regex]::Escape($expectedVersion) + ' \[Windows: amd64\]')) { throw 'Wrong selected native Nim version.' }
  $proof.inspectionSha256 = (Get-FileHash -LiteralPath $inspectionPath -Algorithm SHA256).Hash
  $proof.profile = $profile
  if ($profile.installMethod -eq 'tarball') { $proof.archiveSha256 = $archiveSha }
  $proof.nimPath = $nim
  $proof.peMachine = '0x8664'
  $proof.version = $version
  if ($profile.installMethod -eq 'tarball') { $proof.archiveMatchedFiles = $files }
} catch { $proof.failure = $_.Exception.Message }
finally {
  $proof.finalHead = (& git -C $root rev-parse HEAD).Trim()
  $proof.sourceUnchanged = $proof.finalHead -eq $head
  foreach ($relative in $before.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash -ne $before[$relative]) { $proof.sourceUnchanged = $false }
  }
  if ($proof.Contains('nativePathMatchedFiles')) {
    try {
      $cursor = $prefix
      while ($cursor) {
        if ((Get-Item -LiteralPath $cursor).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'Native PATH ancestry changed to a reparse alias.' }
        $cursor = [System.IO.Path]::GetDirectoryName($cursor)
      }
      $bin = Get-Item -LiteralPath (Join-Path $prefix 'bin')
      if (-not $bin.PSIsContainer -or ($bin.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw 'Final native PATH bin is not a plain directory.' }
      $current = [ordered]@{}
      $members = @((Get-Item -LiteralPath $nim))
      foreach ($subdir in @('config','lib')) {
        $parent = Get-Item -LiteralPath (Join-Path $prefix $subdir)
        if (-not $parent.PSIsContainer -or ($parent.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw 'Native PATH closure directory changed.' }
        $members += @(Get-ChildItem -LiteralPath $parent.FullName -Recurse -Force)
      }
      foreach ($item in $members) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'Native PATH closure now includes a reparse alias.' }
        if ($item.PSIsContainer) { continue }
        $relative = $item.FullName.Substring($prefix.Length + 1).Replace('\','/')
        if ($current.Contains($relative)) { throw 'Duplicate final native PATH closure member.' }
        $current[$relative] = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
      }
      if ($current.Count -ne $proof.nativePathMatchedFiles.Count) { throw 'Native PATH closure member census changed.' }
      foreach ($relative in $proof.nativePathMatchedFiles.Keys) {
        if (-not $current.Contains($relative) -or $current[$relative] -ne $proof.nativePathMatchedFiles[$relative]) { throw 'Native PATH compiler closure changed during binding.' }
      }
      $applications = @(@(Get-Command nim -CommandType Application -All -ErrorAction Stop).Source | ForEach-Object { [System.IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
      if ($applications.Count -ne 1 -or $applications[0] -ne $nim) { throw 'Final native PATH lookup differs from selected compiler.' }
      $proof.finalNativePathMatchedFiles = $current
    } catch { $proof.failure = $_.Exception.Message }
  }
  if (-not $proof.sourceUnchanged) { $proof.failure = 'Source changed during native Nim binding.' }
  $proof | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $directory 'selected-native-nim.json')
}
if ($proof.Contains('failure')) { throw $proof.failure }
Add-Content -LiteralPath $env:GITHUB_PATH -Value (Join-Path $prefix 'bin')
