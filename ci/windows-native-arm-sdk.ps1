param([Parameter(Mandatory=$true)][string]$OwnedPathHelper, [Parameter(Mandatory=$true)][string]$SourceRoot, [Parameter(Mandatory=$true)][string]$SourceRevision)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'Arm64') { throw 'This provider requires an actual native Windows ARM64 host' }
if ($SourceRevision -notmatch '^[0-9a-f]{40}$') { throw 'Invalid exact owning revision' }
$holds=[Collections.Generic.List[IDisposable]]::new()
$activeStageChild=$null
$unresolvedStageOwner=$false
try {
$gitImage=(Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$gitStream=[IO.FileStream]::new($gitImage,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$holds.Add($gitStream)
$gitSHA=(Get-FileHash -LiteralPath $gitImage -Algorithm SHA256).Hash
function Metadata-Git([string[]]$arguments) {
  $info=[Diagnostics.ProcessStartInfo]::new($gitImage);$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$SourceRoot
  foreach ($key in @($info.Environment.Keys)) { if ($key.StartsWith('GIT_', [StringComparison]::OrdinalIgnoreCase)) { $info.Environment.Remove($key)|Out-Null } }
  $info.ArgumentList.Add('-C');$info.ArgumentList.Add($SourceRoot);foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
  $child=$null;$terminal=$false
  try {
    $child=[Diagnostics.Process]::Start($info);$script:activeStageChild=$child
    $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync();$child.WaitForExit();$terminal=$true
    if($child.ExitCode -ne 0){throw 'Owning metadata Git failed'}
    return $stdout.Result
  } finally {
    if($child -and -not $terminal){try{$terminal=$child.HasExited}catch{$terminal=$false}}
    if($child -and $terminal){$child.Dispose();$script:activeStageChild=$null}
    elseif($child){$script:unresolvedStageOwner=$true;[Console]::Error.WriteLine('native_metadata_unresolved pid='+$child.Id)}
  }
}
function Source-State {
  if (-not [IO.Path]::IsPathFullyQualified($SourceRoot)) {throw 'Owning root is not absolute'}
  $canonical=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')
  $top=[IO.Path]::GetFullPath((Metadata-Git @('rev-parse','--show-toplevel')).Trim()).TrimEnd('\','/')
  if (-not [StringComparer]::OrdinalIgnoreCase.Equals($canonical,$top)) {throw 'Owning root differs from actual Git toplevel'}
  $rootItem=Get-Item -LiteralPath $SourceRoot -Force
  if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Foreign owning root'}
  $head=(Metadata-Git @('rev-parse','HEAD')).Trim();if ($head -ne $SourceRevision) {throw 'Foreign owning HEAD'}
  $tree=Metadata-Git @('ls-tree','-r','--full-tree','HEAD');$index=Metadata-Git @('ls-files','--stage');$status=Metadata-Git @('status','--porcelain')
  if ($status.Trim().Length) {throw 'Dirty owning source'}
  $treeRows=@($tree.Trim().Split("`n")|ForEach-Object {$_ -replace ' blob ', ' '});$indexRows=@($index.Trim().Split("`n")|ForEach-Object {$_ -replace ' 0\t', "`t"})
  if (($treeRows -join "`n") -ne ($indexRows -join "`n")) {throw 'Owning index differs from pinned tree'}
  $files=@()
  foreach($row in $index.Trim().Split("`n")) {
    if($row -notmatch '^([0-9]{6}) ([0-9a-f]{40}) 0\t(.*)$'){throw 'Unknown index entry'}
    $mode=$Matches[1];$oid=$Matches[2];$name=$Matches[3]
    if($name.StartsWith('"')){throw 'Quoted source pathname requires explicit qualification'}
    $path=Join-Path $SourceRoot $name;$item=Get-Item -LiteralPath $path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      if($mode -ne '120000' -or $null -eq $item.LinkTarget){throw 'Unexpected source reparse point'}
      $bytes=[Text.Encoding]::UTF8.GetBytes([string]$item.LinkTarget);$kind='link'
    } elseif($item.PSIsContainer){throw 'Tracked file replaced by directory'}
    else {$bytes=[IO.File]::ReadAllBytes($path);$kind='file';if($mode -notin @('100644','100755','120000')){throw 'Unknown source mode'}
      if($mode -eq '120000'){if((Metadata-Git @('config','--bool','--get','core.symlinks')).Trim() -ne 'false'){throw 'Undeclared regular-file symlink representation'};$kind='declared-core-symlinks-false-link-bytes'}
    }
    $header=[Text.Encoding]::UTF8.GetBytes('blob '+$bytes.Length+[char]0)
    $blob=[byte[]]::new($header.Length+$bytes.Length);[Array]::Copy($header,$blob,$header.Length);[Array]::Copy($bytes,0,$blob,$header.Length,$bytes.Length)
    $actualOID=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($blob)).ToLowerInvariant()
    if($actualOID -ne $oid){throw ('Physical source differs from pinned blob: '+$name)}
    $files += [ordered]@{name=$name;mode=$mode;oid=$oid;kind=$kind;attributes=[int]$item.Attributes;length=$bytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))}
  }
  [ordered]@{root=$canonical;rootIdentity=Get-NativeIdentity $SourceRoot;head=$head;tree=$tree;index=$index;files=$files} | ConvertTo-Json -Depth 7 -Compress
}
$helper=[IO.FileStream]::new($OwnedPathHelper,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$holds.Add($helper)
$helperBytes=[byte[]]::new($helper.Length)
$read=0
while ($read -lt $helperBytes.Length) { $n=$helper.Read($helperBytes,$read,$helperBytes.Length-$read); if ($n -eq 0) { throw 'Incomplete held helper' }; $read += $n }
$helperSHA=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($helperBytes)).ToLowerInvariant()
if ($helperSHA -ne '10a232fbec8a9c8a16797aa21bc298b914ad7d3721a3201019347d3e7c1f16db') { throw 'Unknown native held-path helper image' }
. ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString($helperBytes)))
$sourceBefore=Source-State
$root=Join-Path $env:RUNNER_TEMP ('libvterm-arm-sdk-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
$rootHold=[NativePythonOwnedPath]::new($root,$false)
$holds.Add($rootHold)
function Hash-File([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Tree([string]$path) {
  $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($path);$rows=@()
  while ($queue.Count) {
    $d=$queue.Dequeue();$di=Get-Item -LiteralPath $d -Force
    if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse directory in native SDK' }
    foreach ($entry in Get-ChildItem -LiteralPath $d -Force) {
      if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse member in native SDK' }
      $rel=[IO.Path]::GetRelativePath($path,$entry.FullName).Replace('\','/')
      if ($entry.PSIsContainer) { $rows += [ordered]@{name=$rel;kind='directory';identity=Get-NativeIdentity $entry.FullName};$queue.Enqueue($entry.FullName) }
      else { $rows += [ordered]@{name=$rel;kind='file';identity=Get-NativeIdentity $entry.FullName;size=$entry.Length;sha256=Hash-File $entry.FullName} }
    }
  }
  @($rows | Sort-Object name) | ConvertTo-Json -Depth 5 -Compress
}
function Protect-InputTree([string]$path) {
  $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($path)
  while($queue.Count){$d=$queue.Dequeue();$item=Get-Item -LiteralPath $d -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse input directory'}
    $holds.Add([NativePythonOwnedPath]::new($d,$false))
    foreach($entry in Get-ChildItem -LiteralPath $d -Force){if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse input member'}
      if($entry.PSIsContainer){$queue.Enqueue($entry.FullName)}else{$holds.Add([IO.FileStream]::new($entry.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))}
    }
  }
}
function Require-PE([string]$path,[uint16]$machine) {
  $item=Get-Item -LiteralPath $path -Force
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Foreign compiler image' }
  $hold=[NativePythonOwnedPath]::new($path,$false);$holds.Add($hold)
  $imageStream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($imageStream)
  $b=[byte[]]::new($imageStream.Length);$count=0
  while ($count -lt $b.Length) { $n=$imageStream.Read($b,$count,$b.Length-$count);if ($n -eq 0) {throw 'Incomplete held PE image'};$count += $n }
  if ($b.Length -lt 64 -or $b[0] -ne 77 -or $b[1] -ne 90) { throw 'Missing PE signature' }
  $off=[BitConverter]::ToInt32($b,60)
  if ($off -lt 0 -or $off+6 -gt $b.Length -or [BitConverter]::ToUInt32($b,$off) -ne 17744 -or [BitConverter]::ToUInt16($b,$off+4) -ne $machine) { throw 'Wrong native image architecture' }
  [ordered]@{path=$path;machine=$machine;sha256=Hash-File $path;fileId=$hold.Identity()}
}
$canonicalAuthority=@{
  'llvm'=@{count=9298;digest='a14410c4df537b78c2d710ced4fa8485f0dab788e94ab7f6f7336af5b42da05b'}
  'just'=@{count=14;digest='bf9c3ddcd1f41ed4c31f278efedb03a44c4bbd936ac605f98c81b75d534acbd7'}
  'nim-source'=@{count=5832;digest='2304111131e48f84ce81ce5543369a6afa02c6f0da526a812dc34d5e76147673'}
}
function Canonical-Payload([object[]]$rows) {
  $names=[Collections.Generic.List[string]]::new();$byName=@{}
  foreach($row in $rows){$names.Add($row.name);$byName[$row.name]=$row}
  $names.Sort([StringComparer]::Ordinal);$body=[Text.StringBuilder]::new()
  foreach($name in $names){$row=$byName[$name];if($name.Contains("`t") -or $name.Contains("`n") -or $name.Contains("`r")){throw 'Unsupported canonical archive name'}
    if($row.kind -eq 'directory'){$null=$body.Append("D`t$name`n")}else{$null=$body.Append("F`t$name`t$($row.size)`t$($row.sha256)`n")}
  }
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($body.ToString()))).ToLowerInvariant()
}
function Acquire([string]$name,[string]$url,[string]$sha) {
  $archive=Join-Path $root ($name+'.zip')
  Invoke-WebRequest -Uri $url -OutFile $archive -UserAgent 'Metacraft-Everywhere-ARM-Provider/1.0'
  $archiveStream=[IO.FileStream]::new($archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($archiveStream)
  if ((Hash-File $archive) -ne $sha) { throw 'Official archive checksum mismatch' }
  $archiveHold=[NativePythonOwnedPath]::new($archive,$false);$holds.Add($archiveHold)
  $dest=Join-Path $root $name
  $expected=@{};$names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $encoding=[Text.Encoding]::GetEncoding(437)
  $z=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Read,$encoding)
  try {
    foreach ($entry in $z.Entries) {
      $nameParts=$entry.FullName.Replace('\','/').Split('/')
      if ($entry.FullName.Replace('\','/').StartsWith('/') -or $entry.FullName.Contains(':') -or $nameParts.Contains('..') -or $nameParts.Contains('.')) { throw 'Unsafe official archive entry' }
      $relative=$entry.FullName.Replace('\','/').TrimEnd('/')
      if (-not $names.Add($relative)) {throw 'Duplicate or case-colliding archive entry'}
      $directory=$entry.FullName.EndsWith('/')
      $parent=$relative
      while ($parent.Contains('/')) {$parent=$parent.Substring(0,$parent.LastIndexOf('/'));if(-not $expected.ContainsKey($parent)){$expected[$parent]=@{kind='directory'}}}
      if ($directory) {$expected[$relative]=@{kind='directory'}} else {
        $view=$entry.Open();try {$digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($view)).ToLowerInvariant()}finally{$view.Dispose()}
        $expected[$relative]=@{kind='file';size=$entry.Length;sha256=$digest}
      }
      $mode=($entry.ExternalAttributes -shr 16) -band 61440
      if ($mode -notin @(0,16384,32768)) { throw 'Foreign type in official archive' }
    }
  } finally { $z.Dispose() }
  [IO.Compression.ZipFile]::ExtractToDirectory($archive,$dest,$encoding)
  $actual=Tree $dest | ConvertFrom-Json
  if (@($actual).Count -ne $expected.Count) {throw 'Extracted package membership differs from full archive'}
  foreach ($row in $actual) {if(-not $expected.ContainsKey($row.name)){throw 'Unknown extracted member'};$known=$expected[$row.name]
    if($row.kind -ne $known.kind -or ($row.kind -eq 'file' -and ($row.size -ne $known.size -or $row.sha256 -ne $known.sha256))){throw 'Extracted member differs from immutable archive'}
  }
  if(@($actual).Count -ne $canonicalAuthority[$name].count -or (Canonical-Payload @($actual)) -ne $canonicalAuthority[$name].digest){throw 'Extracted source differs from independently canonical official archive authority'}
  $destHold=[NativePythonOwnedPath]::new($dest,$false);$holds.Add($destHold)
  Protect-InputTree $dest
  [ordered]@{archive=$archive;archiveSHA=$sha;root=$dest;fileId=$destHold.Identity();tree=Tree $dest}
}
$sourceHold=[NativePythonOwnedPath]::new($SourceRoot,$false);$holds.Add($sourceHold);$sourceId=$sourceHold.Identity()
if(($sourceBefore|ConvertFrom-Json).rootIdentity -ne $sourceId){throw 'Owning root replaced before hold'}
$scriptHold=[IO.FileStream]::new($PSCommandPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($scriptHold);$scriptSHA=Hash-File $PSCommandPath
$activeStageChild=$null
$unresolvedStageOwner=$false
function Run-Stage([string]$label,[string]$exe,[string[]]$arguments,[string]$workingDirectory=$root,[string]$selectedPath="") {
  $outPath=Join-Path $root ($label+'.stdout');$errPath=Join-Path $root ($label+'.stderr')
  $out=$null;$err=$null;$child=$null
  $row=[ordered]@{name=$label;exe=$exe;argv=$arguments;workingDirectory=$workingDirectory;stdout=$outPath;stderr=$errPath;started=$false;terminal=$false;pid=$null;birthUTC=$null;exit=$null;descendantScope='Not census qualified; direct process naturally waited only'}
  $record=[IO.FileStream]::new((Join-Path $root ($label+'.ownership.json')),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  function Save-Stage {
    $bytes=[Text.Encoding]::UTF8.GetBytes(($row|ConvertTo-Json -Depth 8));$record.Position=0;$record.SetLength(0);$record.Write($bytes,0,$bytes.Length);$record.Flush($true)
  }
  try {
    $row.imageSHA=Hash-File $exe;Save-Stage
    $out=[IO.FileStream]::new($outPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $err=[IO.FileStream]::new($errPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $info=[Diagnostics.ProcessStartInfo]::new($exe);$info.WorkingDirectory=$workingDirectory;$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    if($selectedPath){
      $info.Environment["PATH"]=$selectedPath;$info.Environment["LIBVTERM_NATIVE_ARM_CLANG"]=$clang
      $providerNim=Join-Path $profile.nimBin 'nim.exe'
      if($info.Environment.ContainsKey('REPRO_NIM_COMPILER') -and $info.Environment['REPRO_NIM_COMPILER'] -and -not [IO.Path]::GetFullPath($info.Environment['REPRO_NIM_COMPILER']).Equals($providerNim,[StringComparison]::OrdinalIgnoreCase)){throw 'Foreign provider compiler override'}
      $info.Environment['REPRO_NIM_COMPILER']=$providerNim
      $row.providerCompiler=Require-PE $providerNim 0xAA64
      if($row.providerCompiler.sha256 -ne $profile.nimSHA256){throw 'Provider frontend differs from held native compiler'}
      Save-Stage
    }
    foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::Start($info);$script:activeStageChild=$child
    $row.started=$true;$row.pid=$child.Id;Save-Stage
    $row.birthUTC=$child.StartTime.ToUniversalTime().Ticks;Save-Stage
    $outCopy=$child.StandardOutput.BaseStream.CopyToAsync($out);$errCopy=$child.StandardError.BaseStream.CopyToAsync($err)
    $child.WaitForExit();$row.exit=$child.ExitCode;$row.terminal=$true;Save-Stage
    $outCopy.GetAwaiter().GetResult();$errCopy.GetAwaiter().GetResult();$out.Flush($true);$err.Flush($true)
    $out.Dispose();$out=$null;$err.Dispose();$err=$null
    $row.stdoutSHA=Hash-File $outPath;$row.stderrSHA=Hash-File $errPath;Save-Stage
    $row.imageAfterSHA=Hash-File $exe;Save-Stage
    if($row.imageAfterSHA -ne $row.imageSHA){throw 'Selected stage image changed'}
    if($row.exit -ne 0){throw ('Native stage failed: '+$label)}
    [IO.File]::ReadAllText($outPath)
  } catch {
    $row.failure=$_.Exception.Message
    if($null -ne $child){try {$row.terminal=$child.HasExited;if($row.terminal){$row.exit=$child.ExitCode}}catch{$row.terminal=$false}}
    if($row.started -and -not $row.terminal){$script:unresolvedStageOwner=$true;$row.unresolvedDirectOwner=$true}
    try {Save-Stage} catch {$script:unresolvedStageOwner=$true}
    throw
  } finally {
    $receipt.stages += $row
    if($null -eq $child -or $row.terminal){if($out){$out.Dispose()};if($err){$err.Dispose()};if($child){$child.Dispose()};$script:activeStageChild=$null;$record.Dispose()}
  }
}
function Build-LibvtermZlib {
  param([string]$llvmRoot,[string]$clang)
  $manifestPath=Join-Path $SourceRoot '.github/scripts/native-arm-zlib-members.json'
  $manifestHold=[IO.FileStream]::new($manifestPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($manifestHold)
  $manifestBuffer=[byte[]]::new($manifestHold.Length);$read=0
  while($read -lt $manifestBuffer.Length){$n=$manifestHold.Read($manifestBuffer,$read,$manifestBuffer.Length-$read);if($n -le 0){throw 'Short held Zlib manifest'};$read+=$n}
  $manifestSHA=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBuffer)).ToLowerInvariant()
  if($manifestSHA -ne '4a422797d6701c5f840bc3ca30343749639255eee2a73c8408417ef05e1acc71'){throw 'Foreign canonical Zlib manifest'}
  $manifest=[Text.Encoding]::UTF8.GetString($manifestBuffer)|ConvertFrom-Json
  $archive=Join-Path $root 'zlib-1.3.2.tar.gz'
  if(Test-Path -LiteralPath $archive){throw "Occupied Zlib archive destination"}
  $response=Invoke-WebRequest -Uri 'https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz' -Headers @{'User-Agent'='Metacraft Libvterm native ARM SDK constructor'}
  $download=[IO.FileStream]::new($archive,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$response.RawContentStream.Position=0;$response.RawContentStream.CopyTo($download);$download.Flush($true)}finally{$download.Dispose();$response.RawContentStream.Dispose()}
  $archiveHold=[IO.FileStream]::new($archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($archiveHold)
  if((Hash-File $archive) -ne 'bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16'){throw 'Immutable Zlib archive mismatch'}
  $known=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);foreach($member in $manifest.members.PSObject.Properties){$known[$member.Name]=$member.Value}
  $directories=@($manifest.directories)
  # The independent Python tar receipt omits directory terminal slashes;
  # compare exact raw POSIX directory header names including their one slash.
  $archiveDirectories=@($directories|ForEach-Object {$_+'/'})
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $bodies=[Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
  $seenDirectories=[Collections.Generic.List[string]]::new()
  $gzip=[IO.Compression.GZipStream]::new($archiveHold,[IO.Compression.CompressionMode]::Decompress,$true)
  $tar=[System.Formats.Tar.TarReader]::new($gzip,$true)
  try {
    while($null -ne ($entry=$tar.GetNextEntry($true))){
      $name=$entry.Name
      if($name.Contains('\') -or $name.Contains(':') -or $name.StartsWith('/') -or $name -cnotmatch '^zlib-1\.3\.2(?:/|$)' -or -not $seen.Add($name.TrimEnd('/'))){throw 'Unsafe or duplicate Zlib member'}
      foreach($part in $name.TrimEnd('/').Split('/')){if($part -in @('','.', '..') -or $part.TrimEnd(' ','.') -cne $part){throw 'Unsafe Zlib member segment'}}
      if($entry.EntryType -eq [System.Formats.Tar.TarEntryType]::Directory){
        if($name -cnotin $archiveDirectories){throw 'Foreign Zlib directory'};$seenDirectories.Add($name)
      } elseif($entry.EntryType -in @([System.Formats.Tar.TarEntryType]::RegularFile,[System.Formats.Tar.TarEntryType]::V7RegularFile)){
        if(-not $known.ContainsKey($name)){throw 'Foreign Zlib file'}
        $memory=[IO.MemoryStream]::new();try{$entry.DataStream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$memory.Dispose()}
        $expected=$known[$name]
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if($bytes.Length -ne $expected.size -or $sha -ne $expected.sha256 -or (([int]$entry.Mode) -band 4095) -ne $expected.archive_mode){throw 'Canonical Zlib member body mismatch'}
        $bodies.Add($name,$bytes)
      } else {throw 'Zlib archive link or special member'}
    }
    if($bodies.Count -ne $known.Count -or ($seenDirectories|Sort-Object|ConvertTo-Json -Compress) -ne ($archiveDirectories|Sort-Object|ConvertTo-Json -Compress)){throw 'Incomplete canonical Zlib membership'}
  } finally {$tar.Dispose();$gzip.Dispose()}
  $sourceBase=Join-Path $root 'zlib-input'
  if(Test-Path -LiteralPath $sourceBase){throw 'Occupied Zlib source destination'}
  New-Item -ItemType Directory -Path $sourceBase|Out-Null
  foreach($name in $directories|Sort-Object Length){New-Item -ItemType Directory -Path (Join-Path $sourceBase $name)|Out-Null}
  foreach($pair in $bodies.GetEnumerator()){
    $path=Join-Path $sourceBase $pair.Key
    $stream=[IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($pair.Value,0,$pair.Value.Length);$stream.Flush($true)}finally{$stream.Dispose()}
  }
  $source=Join-Path $sourceBase 'zlib-1.3.2'
  $sourceTree=Tree $source;Protect-InputTree $source
  $makefile=Join-Path $source 'win32/Makefile.gcc'
  if((Hash-File $makefile) -ne '71135ef48a9fcea23c3946b5b7f41ae866e248b1c1e20fd580045a593054c39f'){throw 'Original Zlib object target changed'}
  $objects=@('adler32','compress','crc32','deflate','gzclose','gzlib','gzread','gzwrite','infback','inffast','inflate','inftrees','trees','uncompr','zutil')
  $objectRoot=Join-Path $root 'zlib-objects';New-Item -ItemType Directory -Path $objectRoot|Out-Null
  foreach($name in $objects){
    $object=Join-Path $objectRoot ($name+'.o')
    Run-Stage ('zlib-compile-'+$name) $clang @('--target=aarch64-w64-mingw32','-O3','-Wall','-c','-o',$object,(Join-Path $source ($name+'.c')))|Out-Null
    $bytes=[IO.File]::ReadAllBytes($object)
    if($bytes.Length -lt 20 -or [BitConverter]::ToUInt16($bytes,0) -ne 43620){throw 'Zlib object is not actual ARM64 COFF'}
  }
  $ar=Join-Path $llvmRoot 'llvm-mingw-20261006-ucrt-aarch64/bin/llvm-ar.exe';$arIdentity=Require-PE $ar 43620
  Run-Stage 'zlib-archive-version' $ar @('--version')|Out-Null
  $buildRoot=Join-Path $SourceRoot 'build'
  if(Test-Path -LiteralPath $buildRoot){$buildItem=Get-Item -LiteralPath $buildRoot -Force;if(-not $buildItem.PSIsContainer -or ($buildItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Foreign Zlib build parent'}}else{New-Item -ItemType Directory -Path $buildRoot|Out-Null}
  $buildHold=[NativePythonOwnedPath]::new($buildRoot,$false);$holds.Add($buildHold)
  $sdk=Join-Path $SourceRoot 'build/windows-zlib-sdk'
  if(Test-Path -LiteralPath $sdk){throw 'Occupied Zlib SDK destination'}
  New-Item -ItemType Directory -Path (Join-Path $sdk 'include'),(Join-Path $sdk 'lib')|Out-Null
  foreach($name in @('zlib.h','zconf.h')){Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $sdk ('include/'+$name))}
  $library=Join-Path $sdk 'lib/libz.a'
  $args=@('rcs',$library)+@($objects|ForEach-Object {Join-Path $objectRoot ($_+'.o')})
  Run-Stage 'zlib-static-archive' $ar $args|Out-Null
  $members=(Run-Stage 'zlib-static-members' $ar @('t',$library)).Trim().Split([char]10)|ForEach-Object {$_.TrimEnd([char]13)}
  if(($members|ConvertTo-Json -Compress) -ne (@($objects|ForEach-Object {$_+'.o'})|ConvertTo-Json -Compress)){throw 'Zlib static archive membership differs from original target'}
  $probe=Join-Path $root 'zlib-roundtrip.c'
  [IO.File]::WriteAllText($probe,'#include <zlib.h>
#include <string.h>
int main(void){unsigned char out[128],back[128];uLongf n=128,m=128;const unsigned char text[]="own-zlib-roundtrip";if(strcmp(zlibVersion(),"1.3.2"))return 1;if(compress(out,&n,text,sizeof(text)))return 2;if(uncompress(back,&m,out,n))return 3;return m!=sizeof(text)||memcmp(text,back,m);}')
  $exe=Join-Path $root 'zlib-roundtrip.exe'
  Run-Stage 'zlib-roundtrip-build' $clang @('--target=aarch64-w64-mingw32',('-I'+(Join-Path $sdk 'include')),$probe,$library,'-o',$exe)|Out-Null
  $probeIdentity=Require-PE $exe 43620
  Run-Stage 'zlib-roundtrip-run' $exe @()|Out-Null
  if((Tree $source) -ne $sourceTree -or (Hash-File $archive) -ne $manifest.archive_sha256 -or (Hash-File $manifestPath) -ne $manifestSHA){throw 'Zlib input authority changed'}
  $sdkIdentity=[ordered]@{schemaId='nim_libvterm.native-arm-zlib.v1';version='1.3.2';target='aarch64-w64-mingw32';sourceArchiveSHA256=$manifest.archive_sha256;sourceManifestSHA256=$manifestSHA;compilerSHA256=(Hash-File $clang);archiveTool=$arIdentity;objects=$objects;staticArchiveSHA256=(Hash-File $library);headers=@{zlib=(Hash-File (Join-Path $sdk 'include/zlib.h'));zconf=(Hash-File (Join-Path $sdk 'include/zconf.h'))};nativeRoundtrip=$probeIdentity}
  $identityStream=[IO.FileStream]::new((Join-Path $sdk 'identity.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$identityBytes=[Text.Encoding]::UTF8.GetBytes(($sdkIdentity|ConvertTo-Json -Depth 10));$identityStream.Write($identityBytes,0,$identityBytes.Length);$identityStream.Flush($true)}finally{$identityStream.Dispose()}
  $sdkTree=Tree $sdk;Protect-InputTree $sdk
  [ordered]@{source=$source;sourceTree=$sourceTree;archive=$archive;archiveSHA=$manifest.archive_sha256;manifestSHA=$manifestSHA;sdk=$sdk;sdkTree=$sdkTree;archiveTool=$arIdentity;probe=$probeIdentity;objects=$objects;constructor='Exact upstream static object set and flags with genuine ARM64 Clang/LLVM archive tools';nativeBodyComponentSuccess=$true}
}

$receipt=[ordered]@{sourceBefore=$sourceBefore;scriptSHA=$scriptSHA;helperSHA=$helperSHA;gitSHA=$gitSHA;success=$false;root=$root;rootId=$rootHold.Identity();scope='Actual native provider construction; original monitored/native corpus remains required';stages=@()}
try {
  $llvm=Acquire 'llvm' 'https://github.com/mstorsjo/llvm-mingw/releases/download/20261006/llvm-mingw-20261006-ucrt-aarch64.zip' '9a835d5179c9f3a5a783c11a7f14062a249b4765dd11add64a66786864e82ab2'
  $just=Acquire 'just' 'https://github.com/casey/just/releases/download/1.51.0/just-1.51.0-aarch64-pc-windows-msvc.zip' '12bf56b5b3463e20a1dbb61e3d14748efaefb49231223ef465fbec4d442e2d20'
  $nim=Acquire 'nim-source' 'https://nim-lang.org/download/nim-2.2.10_x64.zip' 'fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f'
  $clang=Join-Path $llvm.root 'llvm-mingw-20261006-ucrt-aarch64/bin/clang.exe'
  $clangIdentity=Require-PE $clang 43620
  if ($clangIdentity.sha256 -ne 'b9d8bae85fff7df611c1ef2f9ad293f42b4b85e1802cc06d39d411ce1582e0cc') { throw 'Unknown ARM compiler wrapper' }
  $target=(Run-Stage 'clang-target' $clang @('-dumpmachine')).Trim();if ( $target -notmatch '^aarch64-.*(mingw32|windows-gnu)$') { throw 'Wrong ARM compiler target' }
  $version=Run-Stage 'clang-version' $clang @('--version');if ( $version -notmatch 'clang version (\d+)' -or [int]$Matches[1] -lt 14) { throw 'ARM compiler floor not met' }
  $justExe=Join-Path $just.root 'just.exe';$justIdentity=Require-PE $justExe 43620
  $justVersion=(Run-Stage 'just-version' $justExe @('--version')).Trim();if ( $justVersion -ne 'just 1.51.0') { throw 'Wrong native just version' }
  $input=Join-Path $nim.root 'nim-2.2.10';$bootstrap=Join-Path $input 'bin/nim.exe';$bootstrapIdentity=Require-PE $bootstrap 34404
  if ($bootstrapIdentity.sha256 -ne 'ab1bcd5a479e81d2f3c58839b0654a97599aa8c2b015f6b021d6943d5f5b55a2') { throw 'Unknown compatibility bootstrap' }
  $native=Join-Path $root 'native-nim';New-Item -ItemType Directory -Path (Join-Path $native 'bin') | Out-Null
  Copy-Item -LiteralPath (Join-Path $input 'lib') -Destination $native -Recurse
  Copy-Item -LiteralPath (Join-Path $input 'config') -Destination $native -Recurse
  foreach($part in @('lib','config')) {
    $original=Tree (Join-Path $input $part)|ConvertFrom-Json;$copied=Tree (Join-Path $native $part)|ConvertFrom-Json
    $originalBodies=@($original|Select-Object name,kind,size,sha256)|ConvertTo-Json -Depth 5 -Compress;$copiedBodies=@($copied|Select-Object name,kind,size,sha256)|ConvertTo-Json -Depth 5 -Compress
    if($originalBodies -ne $copiedBodies){throw 'Native frontend stdlib/config differs from immutable sources'}
  }
  $nativeHold=[NativePythonOwnedPath]::new($native,$false);$holds.Add($nativeHold)
  $nativeNim=Join-Path $native 'bin/nim.exe'
  Run-Stage 'native-frontend-build' $bootstrap @('c','--skipUserCfg','--skipParentCfg','--cpu:arm64','--os:windows','--cc:clang',"--clang.exe:$clang","--clang.linkerexe:$clang","--lib:$(Join-Path $input 'lib')","--nimcache:$(Join-Path $root 'compiler-cache')","--out:$nativeNim",(Join-Path $input 'compiler/nim.nim')) | Out-Null
  $nativeIdentity=Require-PE $nativeNim 43620
  $nativeTreeBefore=Tree $native
  Protect-InputTree $native
  $nativeVersion=Run-Stage 'native-frontend-version' $nativeNim @('--version');if ( $nativeVersion -notmatch 'Version 2\.2\.10.*Windows: arm64') { throw 'Native frontend version/architecture mismatch' }
  $probe=Join-Path $root 'roundtrip.nim';[IO.File]::WriteAllText($probe,'echo "native-arm-roundtrip"')
  $probeExe=Join-Path $root 'roundtrip.exe'
  Run-Stage 'native-roundtrip-build' $nativeNim @('c','--skipUserCfg','--skipParentCfg','--cc:clang',"--clang.exe:$clang","--clang.linkerexe:$clang","--nimcache:$(Join-Path $root 'probe-cache')","--out:$probeExe",$probe) | Out-Null
  $probeIdentity=Require-PE $probeExe 43620
  $output=(Run-Stage 'native-roundtrip-run' $probeExe @()).Trim();if ( $output -ne 'native-arm-roundtrip') { throw 'Native ARM runtime roundtrip failed' }
  if((Tree $native) -ne $nativeTreeBefore){throw 'Native frontend stdlib/config/runtime changed'}
  $zlib=Build-LibvtermZlib $llvm.root $clang
  foreach ($package in @($llvm,$just,$nim)) { if ((Tree $package.root) -ne $package.tree -or (Hash-File $package.archive) -ne $package.archiveSHA) { throw 'Acquired input source/runtime changed' } }
  if ((Get-NativeIdentity $root) -ne $rootHold.Identity()) { throw 'Native SDK root changed' }
  foreach ($role in @($clangIdentity,$justIdentity,$bootstrapIdentity,$nativeIdentity,$probeIdentity)) { if ((Hash-File $role.path) -ne $role.sha256 -or (Get-NativeIdentity $role.path) -ne $role.fileId) {throw 'Native image authority changed'} }
  if ((Source-State) -ne $sourceBefore -or (Get-NativeIdentity $SourceRoot) -ne $sourceId -or (Hash-File $PSCommandPath) -ne $scriptSHA -or (Get-FileHash -LiteralPath $gitImage -Algorithm SHA256).Hash -ne $gitSHA) {throw 'Owning source/tool authority changed'}
  $receipt.sourceAfter=Source-State;$receipt.nativeFrontendPayload=$nativeTreeBefore;$receipt.packages=@($llvm,$just,$nim)
  $receipt.nativeZlib=$zlib;$receipt.nativeCompiler=$clangIdentity;$receipt.nativeFrontend=$nativeIdentity;$receipt.compatibilityBootstrap=$bootstrapIdentity;$receipt.nativeJust=$justIdentity;$receipt.nativeProbe=$probeIdentity;$receipt.target=$target;$receipt.success=$false
  $reproRoot=Join-Path $SourceRoot '.repro'
  if(Test-Path -LiteralPath $reproRoot){$item=Get-Item -LiteralPath $reproRoot -Force;if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Foreign owning profile parent'}}else{New-Item -ItemType Directory -Path $reproRoot|Out-Null}
  $reproHold=[NativePythonOwnedPath]::new($reproRoot,$false);$holds.Add($reproHold)
  $profileRoot=Join-Path $reproRoot 'libvterm-native-arm'
  if(Test-Path -LiteralPath $profileRoot){throw 'Existing or foreign native ARM profile refused'}
  New-Item -ItemType Directory -Path $profileRoot|Out-Null
  $profileRootHold=[NativePythonOwnedPath]::new($profileRoot,$false);$holds.Add($profileRootHold)
  $profile=[ordered]@{schemaId='nim_libvterm.native-arm-sdk.v1';owningHead=$SourceRevision;target='aarch64-w64-mingw32';nativeMachine='AA64';nimVersion='2.2.10';llvmArchiveSHA256=$llvm.archiveSHA;clangSHA256=$clangIdentity.sha256;nimSHA256=$nativeIdentity.sha256;justSHA256=$justIdentity.sha256;clang=$clang;nimBin=(Join-Path $native 'bin');clangBin=(Split-Path $clang);justBin=$just.root;sdkRoot=$zlib.sdk;nativeFrontendPayload=$nativeTreeBefore;zlibPayload=$zlib.sdkTree}
  $profilePath=Join-Path $profileRoot 'profile.json'
  $profileBytes=[Text.Encoding]::UTF8.GetBytes(($profile|ConvertTo-Json -Depth 10))
  $profileStream=[IO.FileStream]::new($profilePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read);$holds.Add($profileStream)
  $profileStream.Write($profileBytes,0,$profileBytes.Length);$profileStream.Flush($true)
  $profileIdentity=Get-NativeIdentity $profilePath
  function Assert-Profile {
    if((Get-NativeIdentity $profileRoot) -ne $profileRootHold.Identity() -or (Get-NativeIdentity $profilePath) -ne $profileIdentity){throw 'Native profile identity changed'}
    $entries=@(Get-ChildItem -LiteralPath $profileRoot -Force)
    if($entries.Count -ne 1 -or $entries[0].Name -cne 'profile.json' -or $entries[0].PSIsContainer -or ($entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unknown native profile membership'}
    $expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($profileBytes)).ToLowerInvariant()
    if((Hash-File $profilePath) -ne $expected){throw 'Native profile bytes changed'}
  }
  function Append-HeldCommand([string]$path,[byte[]]$addition,[string]$label){
    $item=Get-Item -LiteralPath $path -Force
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Foreign command file'}
    $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read);$holds.Add($stream)
    $identity=Get-NativeIdentity $path
    $before=[byte[]]::new($stream.Length);$read=0
    while($read -lt $before.Length){$n=$stream.Read($before,$read,$before.Length-$read);if($n -le 0){throw 'Short held command file'};$read+=$n}
    if($before.Length -gt 0 -and $before[-1] -ne 10){throw 'Existing command file lacks terminal LF'}
    Assert-Profile
    $stream.Seek(0,[IO.SeekOrigin]::End)|Out-Null;$stream.Write($addition,0,$addition.Length);$stream.Flush($true)
    if((Get-NativeIdentity $path) -ne $identity){throw 'Command file identity changed'}
    $actual=[IO.File]::ReadAllBytes($path)
    $expected=[byte[]]::new($before.Length+$addition.Length);[Array]::Copy($before,0,$expected,0,$before.Length);[Array]::Copy($addition,0,$expected,$before.Length,$addition.Length)
    if(-not [System.Linq.Enumerable]::SequenceEqual[byte]($actual,$expected)){throw 'Command file append bytes differ'}
    $receipt.activation += [ordered]@{kind=$label;path=$path;beforeLength=$before.Length;afterLength=$actual.Length;identityPreserved=$true;bytesPreserved=$true}
  }
  $receipt.activation=@()
  Append-HeldCommand $env:GITHUB_ENV ([Text.Encoding]::UTF8.GetBytes('LIBVTERM_NATIVE_ARM_CLANG='+$clang+[char]10+'REPRO_NIM_COMPILER='+(Join-Path $profile.nimBin 'nim.exe')+[char]10)) 'environment'
  $paths=[String]::Join([char]10,@((Join-Path $native 'bin'),$just.root,(Split-Path $clang)))+[char]10
  Append-HeldCommand $env:GITHUB_PATH ([Text.Encoding]::UTF8.GetBytes($paths)) 'path'
  Assert-Profile
  if((Tree $native) -ne $nativeTreeBefore -or (Tree $zlib.sdk) -ne $zlib.sdkTree -or (Source-State) -ne $sourceBefore){throw 'Native source/runtime changed through activation'}
  # Inspect the genuine resolved graph while all native package and profile
  # principals are still held. This is graph qualification, not corpus execution.
  $reproPath=(Get-Command repro -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
  $reproHold=[IO.FileStream]::new($reproPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($reproHold)
  $reproBeforeSHA=Hash-File $reproPath
  $selectedPath=[String]::Join(';',@($profile.nimBin,$profile.clangBin,$profile.justBin,(Split-Path $gitImage)))
  $graphText=Run-Stage 'actual-native-profile-graph' $reproPath @('graph','test','--json','--tool-provisioning=path') $SourceRoot $selectedPath
  $graph=$graphText|ConvertFrom-Json -Depth 100
  if($graph.schemaId -ne 'reprobuild.graph.build.v1' -or $graph.toolProvisioning -ne 'path'){throw 'Foreign native graph provisioning'}
  $providerPath=[IO.Path]::GetFullPath($graph.providerBinaryPath,$SourceRoot)
  if(-not $providerPath.StartsWith($SourceRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Foreign provider output authority'}
  $providerImage=Require-PE $providerPath 0xAA64
  $providerArtifactPath=[IO.Path]::GetFullPath($graph.providerCompileArtifactPath,$SourceRoot)
  if(-not $providerArtifactPath.StartsWith($SourceRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Foreign provider compile artifact'}
  $providerArtifactHold=[IO.FileStream]::new($providerArtifactPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($providerArtifactHold)
  $providerArtifactSHA=Hash-File $providerArtifactPath
  $inspectionPath=[IO.Path]::GetFullPath($graph.toolInspectionPath,$SourceRoot)
  if(-not $inspectionPath.StartsWith($SourceRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Foreign tool inspection authority'}
  $inspectionHold=[IO.FileStream]::new($inspectionPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($inspectionHold)
  $inspectionSHA=Hash-File $inspectionPath
  $inspection=[IO.File]::ReadAllText($inspectionPath)|ConvertFrom-Json -Depth 100
  $selectedImages=@{nim=@{path=(Join-Path $profile.nimBin 'nim.exe');sha=$profile.nimSHA256};clang=@{path=$profile.clang;sha=$profile.clangSHA256}}
  $selectedProfiles=@()
  foreach($role in @('nim','clang')){
    $matches=@($inspection.profiles|Where-Object {$_.packageSelector -eq $role})
    if($matches.Count -ne 1 -or $matches[0].installMethod -ne 'path'){throw 'Native tool role did not resolve the admitted PATH profile'}
    $actual=[IO.Path]::GetFullPath($matches[0].resolvedExecutablePath)
    $expected=[IO.Path]::GetFullPath($selectedImages[$role].path)
    if(-not $actual.Equals($expected,[StringComparison]::OrdinalIgnoreCase)){throw 'Native selected graph image differs from held profile'}
    $image=Require-PE $actual 0xAA64
    if($image.sha256 -ne $selectedImages[$role].sha){throw 'Native graph image body differs from held profile'}
    $selectedProfiles += [ordered]@{role=$role;image=$image;packageId=$matches[0].packageId}
  }
  $selectedJust=Require-PE (Join-Path $profile.justBin 'just.exe') 0xAA64
  if($selectedJust.sha256 -ne $profile.justSHA256){throw 'Native Just image changed'}
  $buildEdges=@($graph.actions|Where-Object {$_.id.StartsWith('nim_libvterm.test_build.')})
  $executeEdges=@($graph.actions|Where-Object {$_.id.StartsWith('nim_libvterm.test_execute.')})
  if($buildEdges.Count -ne 39 -or $executeEdges.Count -ne 39){throw 'Original complete native corpus graph membership changed'}
  foreach($edge in $buildEdges){
    if(@($edge.toolIdentityRefs|Where-Object {$_ -eq 'nim'}).Count -ne 1 -or @($edge.toolIdentityRefs|Where-Object {$_ -eq 'clang'}).Count -ne 1){throw 'Native compile edge omits selected tool identity'}
  }
  $expectedStems=@([regex]::Matches([IO.File]::ReadAllText((Join-Path $SourceRoot 'repro.nim')),'LibvtermTestSpec\(source: "tests/([^"/]+)\.nim"')|ForEach-Object {$_.Groups[1].Value})
  if($expectedStems.Count -ne 39){throw 'Original compile collection membership changed'}
  foreach($stem in $expectedStems){if(@($buildEdges|Where-Object {$_.id -eq ('nim_libvterm.test_build.'+$stem)}).Count -ne 1 -or @($executeEdges|Where-Object {$_.id -eq ('nim_libvterm.test_execute.'+$stem)}).Count -ne 1){throw 'Original native action pair missing'}}
  foreach($edge in @($buildEdges)+@($executeEdges)){
    $pathRows=@($edge.env|Where-Object {$_.StartsWith('PATH=')})
    if($pathRows.Count -ne 1){throw 'Native edge has ambiguous PATH'}
    $allowed=@($profile.nimBin,$profile.clangBin,$profile.justBin)|ForEach-Object {[IO.Path]::GetFullPath($_)}
    foreach($segment in $pathRows[0].Substring(5).Split(';')){if(-not $segment -or [IO.Path]::GetFullPath($segment) -notin $allowed){throw 'Native edge exposes unadmitted PATH member'}}
    if(@($edge.env|Where-Object {$_ -eq ('LIBVTERM_NATIVE_ARM_CLANG='+$clang)}).Count -ne 1){throw 'Native edge compiler projection changed'}
    if(@($edge.inputs|Where-Object {[IO.Path]::GetFullPath($_,$SourceRoot).Equals($profilePath,[StringComparison]::OrdinalIgnoreCase)}).Count -ne 1){throw 'Native edge omits declared profile input'}
  }
  Assert-Profile
  if((Tree $native) -ne $nativeTreeBefore -or (Tree $zlib.sdk) -ne $zlib.sdkTree -or (Source-State) -ne $sourceBefore -or (Hash-File $inspectionPath) -ne $inspectionSHA -or (Hash-File $reproPath) -ne $reproBeforeSHA -or (Hash-File $providerPath) -ne $providerImage.sha256 -or (Hash-File $providerArtifactPath) -ne $providerArtifactSHA){throw 'Native graph authority changed'}
  $receipt.nativeGraph=[ordered]@{inspectionPath=$inspectionPath;inspectionSHA=$inspectionSHA;buildCount=$buildEdges.Count;executeCount=$executeEdges.Count;providerImage=$providerImage;providerCompileArtifactPath=$providerArtifactPath;providerCompileArtifactSHA=$providerArtifactSHA;providerCompiler=$nativeIdentity;providerCompilerSelection='Admitted supported exact766 REPRO_NIM_COMPILER environment plus held native frontend and actual AA64 provider output; durable artifact compilerCommand not decoded';selectedProfiles=$selectedProfiles;selectedJust=$selectedJust;graphMetadataGit=@{path=$gitImage;sha256=$gitSHA};scope='Actual resolved native graph only; original monitored bodies remain required'}
  $receipt.profilePath=$profilePath;$receipt.profileSHA=Hash-File $profilePath;$receipt.activationSuccess=$true
  $receipt.success=$true
  $receiptFile=Join-Path $root 'provider.json';$stream=[IO.FileStream]::new($receiptFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$b=[Text.Encoding]::UTF8.GetBytes(($receipt|ConvertTo-Json -Depth 10));$stream.Write($b,0,$b.Length);$stream.Flush($true)}finally{$stream.Dispose()}

} catch {
  $receipt.failure=$_.Exception.Message
  $receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'provider-failure.json')
  throw
}
} finally { if(-not $unresolvedStageOwner -and $null -eq $activeStageChild){foreach ($h in $holds){$h.Dispose()}} }
