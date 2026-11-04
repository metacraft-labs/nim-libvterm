$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64') {
  throw 'This immutable WinLibs provider requires native Windows x64; ARM64 requires a separate native provider.'
}
if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
  throw 'The pinned supported installer requires the native PowerShell Get-FileHash cmdlet.'
}
$revision = '76659f5730ecf698b1963c656494d2cb66eb256d'
$files = [ordered]@{
  'toolchain-utils.ps1' = 'd1cb869b8c0652cbd96e362bc88d23b46385e6468be654adf0de8a276772979b'
  'ensure-gcc.ps1' = '96c893eb18253469092960a548858bbaa3da3ea0cc53fa3a47478256f73176eb'
  'toolchain-versions.env' = '9bde26a453e5af29512b44dd04156e90a4a4df886dd15acbc896ff84f22ea5cd'
}
$root = Join-Path $env:RUNNER_TEMP ('libvterm-native-sdk-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
foreach ($entry in $files.GetEnumerator()) {
  $path = Join-Path $root $entry.Key
  $url = "https://raw.githubusercontent.com/metacraft-labs/reprobuild/$revision/windows/$($entry.Key)"
  Invoke-WebRequest -Uri $url -OutFile $path
  if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value) {
    throw "Immutable compiler source hash mismatch: $($entry.Key)"
  }
}
. (Join-Path $root 'toolchain-utils.ps1')
. (Join-Path $root 'ensure-gcc.ps1')
$pin = Read-KeyValueFile -Path (Join-Path $root 'toolchain-versions.env')
if ($pin['GCC_VERSION'] -ne '16.1.0' -or $pin['GCC_WINLIBS_RELEASE'] -ne '16.1.0posix-14.0.0-ucrt-r2' -or $pin['GCC_WINLIBS_SHA256'] -ne '78eff1e2e804b6a6320c713f084b8f820c662104a24cea6a3bfcab82032bdd60') {
  throw 'Immutable compiler pin mismatch'
}
$installRoot = Join-Path $root 'installed'
Ensure-Gcc -Root $installRoot -Arch 'x64' -Toolchain $pin | Out-Null
$bin = Join-Path $installRoot 'gcc\16.1.0\bin'
$records = @()
foreach ($name in @('gcc.exe', 'g++.exe')) {
  $path = Join-Path $bin $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing native compiler: $name" }
  $bytes = [System.IO.File]::ReadAllBytes($path)
  if ($bytes.Length -lt 64 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) { throw "Invalid PE: $name" }
  $offset = [BitConverter]::ToInt32($bytes, 60)
  if ($offset -lt 0 -or $offset + 6 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $offset) -ne 17744 -or [BitConverter]::ToUInt16($bytes, $offset + 4) -ne 34404) { throw "Non-AMD64 compiler: $name" }
  $version = (& $path -dumpfullversion).Trim()
  if ($LASTEXITCODE -ne 0 -or $version -ne '16.1.0') { throw "Wrong native compiler version: $name" }
  $target = (& $path -dumpmachine).Trim()
  if ($LASTEXITCODE -ne 0 -or $target -ne 'x86_64-w64-mingw32') { throw "Wrong compiler target: $name" }
  $include = (& $path -print-file-name=include).Trim()
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $include 'stdarg.h'))) { throw "Missing native compiler headers: $name" }
  $records += [ordered]@{ path=$path; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; peMachine='0x8664'; version=$version; target=$target; include=$include }
}
$env:PATH = "$bin;$env:PATH"
$probe = Join-Path $root 'native_header_link_probe.c'
$binary = Join-Path $root 'native_header_link_probe.exe'
[System.IO.File]::WriteAllText($probe, "#include <stdio.h>`n#include <stdarg.h>`nint main(void) { puts(`"native-sdk-ok`"); return 0; }`n")
& (Join-Path $bin 'gcc.exe') $probe -o $binary
if ($LASTEXITCODE -ne 0) { throw 'Native SDK header/link probe failed' }
$output = (& $binary).Trim()
if ($LASTEXITCODE -ne 0 -or $output -ne 'native-sdk-ok') { throw 'Native SDK runtime probe failed' }
$justArchive = Join-Path $root 'just-1.51.0-windows-x64.zip'
$justArchiveSha256 = '09d1138b6845e73f04bff5e26be3f57663bddca25e36fe6241d28a5aa310b64e'
Invoke-WebRequest -Uri 'https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-x86_64-pc-windows-msvc.zip' -OutFile $justArchive
Assert-FileSha256 -Path $justArchive -Expected $justArchiveSha256
$justRoot = Join-Path $root 'just'
Expand-Archive -LiteralPath $justArchive -DestinationPath $justRoot
$justExe = Join-Path $justRoot 'just.exe'
$justBytes = [System.IO.File]::ReadAllBytes($justExe)
if ($justBytes.Length -lt 64 -or $justBytes[0] -ne 77 -or $justBytes[1] -ne 90) { throw 'Invalid native just PE' }
$justOffset = [BitConverter]::ToInt32($justBytes, 60)
if ($justOffset -lt 0 -or $justOffset + 6 -gt $justBytes.Length -or [BitConverter]::ToUInt32($justBytes, $justOffset) -ne 17744 -or [BitConverter]::ToUInt16($justBytes, $justOffset + 4) -ne 34404) { throw 'Non-AMD64 just executable' }
$justVersion = (& $justExe --version).Trim()
if ($LASTEXITCODE -ne 0 -or $justVersion -ne 'just 1.51.0') { throw 'Wrong native just version' }
$justIdentity = [ordered]@{ path=$justExe; sha256=(Get-FileHash -LiteralPath $justExe -Algorithm SHA256).Hash; peMachine='0x8664'; version=$justVersion; archiveSha256=$justArchiveSha256 }
# Build the owning locked Zlib source with the same verified native compiler.
$zlibArchive = Join-Path $root 'zlib-1.3.2.tar.gz'
Invoke-WebRequest -Uri 'https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz' -OutFile $zlibArchive
Assert-FileSha256 -Path $zlibArchive -Expected 'bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16'
$zlibSourceRoot = Join-Path $root 'zlib-source'
New-Item -ItemType Directory -Path $zlibSourceRoot | Out-Null
$tarExe = Get-WindowsTarExe
& $tarExe -xzf $zlibArchive -C $zlibSourceRoot
if ($LASTEXITCODE -ne 0) { throw 'Owning Zlib source extraction failed' }
$zlibSource = Join-Path $zlibSourceRoot 'zlib-1.3.2'
$makeExe = Join-Path $bin 'mingw32-make.exe'
$arExe = Join-Path $bin 'ar.exe'
$objdumpExe = Join-Path $bin 'objdump.exe'
foreach ($tool in @($makeExe, $arExe, $objdumpExe)) {
  if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Missing native Zlib build tool: $tool" }
  $bytes = [System.IO.File]::ReadAllBytes($tool)
  if ($bytes.Length -lt 64 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) { throw "Invalid Zlib build tool PE: $tool" }
  $offset = [BitConverter]::ToInt32($bytes, 60)
  if ($offset -lt 0 -or $offset + 6 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $offset) -ne 17744 -or [BitConverter]::ToUInt16($bytes, $offset + 4) -ne 34404) { throw "Non-AMD64 Zlib build tool: $tool" }
}
$makeVersion = (& $makeExe '--version' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $makeVersion -notmatch '^GNU Make ') { throw 'Invalid native GNU make version identity' }
$arVersion = (& $arExe '--version' | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $arVersion -notmatch '^GNU ar ') { throw 'Invalid native GNU ar version identity' }
Assert-FileSha256 -Path (Join-Path $zlibSource 'win32/Makefile.gcc') -Expected '71135ef48a9fcea23c3946b5b7f41ae866e248b1c1e20fd580045a593054c39f'
Push-Location $zlibSource
try {
  & $makeExe '-f' 'win32/Makefile.gcc' 'libz.a' ('CC="' + (Join-Path $bin 'gcc.exe').Replace('\', '/') + '"') ('AR="' + $arExe.Replace('\', '/') + '"')
  if ($LASTEXITCODE -ne 0) { throw 'Original upstream Zlib static target failed' }
} finally { Pop-Location }
$zlibSdk = Join-Path $env:GITHUB_WORKSPACE 'build/windows-zlib-sdk'
if (Test-Path -LiteralPath $zlibSdk) { throw 'Refusing to replace an existing Zlib SDK output' }
$zlibInclude = Join-Path $zlibSdk 'include'
$zlibLibrary = Join-Path $zlibSdk 'lib'
New-Item -ItemType Directory -Path $zlibInclude, $zlibLibrary | Out-Null
Copy-Item -LiteralPath (Join-Path $zlibSource 'zlib.h'), (Join-Path $zlibSource 'zconf.h') -Destination $zlibInclude
Copy-Item -LiteralPath (Join-Path $zlibSource 'libz.a') -Destination $zlibLibrary
$objectFormats = (& $objdumpExe '-f' (Join-Path $zlibLibrary 'libz.a') | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Owning Zlib static object inspection failed' }
$formats = [regex]::Matches($objectFormats, 'file format ([^\s]+)')
if ($formats.Count -eq 0) { throw 'Owning Zlib static archive contains no verified objects' }
foreach ($format in $formats) { if ($format.Groups[1].Value -ne 'pe-x86-64') { throw 'Non-AMD64 Zlib static object' } }
$zlibProbe = Join-Path $root 'zlib_probe.c'
$zlibBinary = Join-Path $root 'zlib_probe.exe'
[System.IO.File]::WriteAllText($zlibProbe, "#include <zlib.h>`n#include <string.h>`nint main(void) { unsigned char out[128], back[128]; uLongf n=128, m=128; const unsigned char text[]=`"own-zlib-roundtrip`"; if(strcmp(zlibVersion(),`"1.3.2`")) return 1; if(compress(out,&n,text,sizeof(text))) return 2; if(uncompress(back,&m,out,n)) return 3; return m!=sizeof(text)||memcmp(text,back,m); }`n")
& (Join-Path $bin 'gcc.exe') $zlibProbe "-I$zlibInclude" "-L$zlibLibrary" '-lz' '-o' $zlibBinary
if ($LASTEXITCODE -ne 0) { throw 'Owning Zlib header/link probe failed' }
& $zlibBinary
if ($LASTEXITCODE -ne 0) { throw 'Owning Zlib native roundtrip failed' }
$zlibFiles = [ordered]@{}
foreach ($relative in @('include/zlib.h', 'include/zconf.h', 'lib/libz.a')) {
  $zlibFiles[$relative] = (Get-FileHash -LiteralPath (Join-Path $zlibSdk $relative) -Algorithm SHA256).Hash
}
$zlibIdentity = [ordered]@{ sourceSha256='bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16'; sourceVersion='1.3.2'; files=$zlibFiles; makePath=$makeExe; makeVersion=$makeVersion; arVersion=$arVersion; makeSha256=(Get-FileHash -LiteralPath $makeExe -Algorithm SHA256).Hash; arPath=$arExe; arSha256=(Get-FileHash -LiteralPath $arExe -Algorithm SHA256).Hash; objectFormats=$objectFormats; objdumpPath=$objdumpExe; objdumpSha256=(Get-FileHash -LiteralPath $objdumpExe -Algorithm SHA256).Hash; tarPath=$tarExe; tarSha256=(Get-FileHash -LiteralPath $tarExe -Algorithm SHA256).Hash; probeSha256=(Get-FileHash -LiteralPath $zlibBinary -Algorithm SHA256).Hash }
$zlibIdentity | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $zlibSdk 'identity.json')
Add-Content -LiteralPath $env:GITHUB_ENV -Value "NIM_LIBVTERM_ZLIB_INCLUDE=$zlibInclude"
Add-Content -LiteralPath $env:GITHUB_ENV -Value "NIM_LIBVTERM_ZLIB_LIB=$zlibLibrary"
$proof = [ordered]@{ immutableSource=$revision; sourceHashes=$files; root=$root; archiveSha256=$pin['GCC_WINLIBS_SHA256']; compilers=$records; just=$justIdentity; nativeProbeSha256=(Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash; nativeProbeOutput=$output; scope='Native compiler provisioning; original monitored actions remain required' }
$proof['zlib'] = $zlibIdentity
$directory = Join-Path $env:GITHUB_WORKSPACE '.repro\windows-native-provenance'
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$proof | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $directory 'native-compiler-sdk.json')
Add-Content -LiteralPath $env:GITHUB_PATH -Value $bin
Add-Content -LiteralPath $env:GITHUB_PATH -Value $justRoot
