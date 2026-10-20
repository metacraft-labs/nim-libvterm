# Called only inside the held Libvterm native ARM constructor. Uses its real
# Run-Stage, Require-PE, Hash-File and NativePythonOwnedPath authority.
function Build-NativeRunquota([string]$reproPath,[string]$selectedPath) {
  foreach($name in @('RUNQUOTAD_BIN','REPROBUILD_NO_RUNQUOTA','REPROBUILD_BYPASS_RUNQUOTA','RUNQUOTA_SOCKET','RUNQUOTA_BIN','REPROBUILD_AUTO_RUNQUOTA','REPROBUILD_SRC','SHM_LEASE_SRC','NIMFLAGS','CFLAGS','CPPFLAGS','LDFLAGS','GCC_EXEC_PREFIX','COMPILER_PATH','LIBRARY_PATH','CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH')) {
    if(Test-Path ('Env:'+$name)){throw ('Inherited admission selector refused: '+$name)}
  }
  $policyPath=Join-Path $SourceRoot 'ci/native-arm-runquota-policy.json'
  $policyStream=[IO.FileStream]::new($policyPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($policyStream)
  $policyBytes=[byte[]]::new($policyStream.Length);$offset=0
  while($offset -lt $policyBytes.Length){$n=$policyStream.Read($policyBytes,$offset,$policyBytes.Length-$offset);if($n -le 0){throw 'Short held daemon policy'};$offset+=$n}
  if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($policyBytes)).ToLowerInvariant() -ne '18ba0559375b9f13b3cd43f5de2bdd82ae635043d915099d18cafd211c950691'){throw 'Foreign native daemon policy'}
  $policy=[Text.Encoding]::UTF8.GetString($policyBytes)|ConvertFrom-Json -Depth 30
  function Hold-ExactFile([string]$path,[string]$expected) {
    $item=Get-Item -LiteralPath $path -Force
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Foreign daemon source/image node'}
    $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($stream)
    if((Hash-File $path) -ne $expected){throw ('Daemon source/image hash mismatch: '+$path)}
  }
  function Hold-ExactTree([string]$path,$expected) {
    $hold=[NativePythonOwnedPath]::new($path,$false);$holds.Add($hold)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($item in Get-ChildItem -LiteralPath $path -Recurse -Force) {
      if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Daemon tree reparse entry'}
      if($item.PSIsContainer){continue}
      $relative=[IO.Path]::GetRelativePath($path,$item.FullName).Replace('\','/')
      $property=$expected.PSObject.Properties[$relative]
      if($null -eq $property -or -not $seen.Add($relative)){throw 'Unknown daemon source member'}
      Hold-ExactFile $item.FullName $property.Value
    }
    if($seen.Count -ne @($expected.PSObject.Properties).Count){throw 'Missing daemon source member'}
  }
  $releaseBin=Split-Path $reproPath
  Hold-ExactTree $releaseBin $policy.releaseImages
  $source=Join-Path (Split-Path $releaseBin) 'share/repro/src/runquota'
  Hold-ExactTree $source $policy.runquota
  $daemonRoot=Join-Path $root 'native-runquota'
  if(Test-Path -LiteralPath $daemonRoot){throw 'Occupied native daemon root'}
  New-Item -ItemType Directory -Path $daemonRoot|Out-Null
  $daemonHold=[NativePythonOwnedPath]::new($daemonRoot,$false);$holds.Add($daemonHold)
  $privateSource=Join-Path $daemonRoot 'runquota';New-Item -ItemType Directory -Path $privateSource|Out-Null
  foreach($member in $policy.runquota.PSObject.Properties){
    $target=Join-Path $privateSource $member.Name
    [IO.Directory]::CreateDirectory((Split-Path $target))|Out-Null
    $input=[IO.FileStream]::new((Join-Path $source $member.Name),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $output=[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$input.CopyTo($output);$output.Flush($true)}finally{$input.Dispose();$output.Dispose()}
  }
  Hold-ExactTree $privateSource $policy.runquota
  $archive=Join-Path $daemonRoot 'lease.zip'
  $response=Invoke-WebRequest -Uri $policy.leaseURL -Headers @{'User-Agent'='Metacraft Libvterm native ARM daemon prerequisite'}
  $download=[IO.FileStream]::new($archive,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$response.RawContentStream.Position=0;$response.RawContentStream.CopyTo($download);$download.Flush($true)}finally{$download.Dispose();$response.RawContentStream.Dispose()}
  Hold-ExactFile $archive $policy.leaseArchiveSHA256
  $leaseRoot=Join-Path $daemonRoot 'nim-shm-lease';New-Item -ItemType Directory -Path $leaseRoot|Out-Null
  $zip=[IO.Compression.ZipFile]::OpenRead($archive)
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  try {
    foreach($entry in $zip.Entries) {
      $name=$entry.FullName
      if(-not $name.StartsWith($policy.leaseArchiveRoot,[StringComparison]::Ordinal)){throw 'Foreign lease archive root'}
      $relative=$name.Substring($policy.leaseArchiveRoot.Length)
      if(-not $relative){continue}
      if($relative.Contains('\') -or $relative.Contains(':') -or $relative.StartsWith('/') -or (($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000){throw 'Foreign lease archive node'}
      foreach($part in $relative.TrimEnd('/').Split('/')){if($part -in @('','.', '..') -or $part.TrimEnd(' ','.') -cne $part){throw 'Unsafe lease source segment'}}
      if($relative.EndsWith('/')){continue}
      $property=$policy.lease.PSObject.Properties[$relative]
      if($null -eq $property -or -not $seen.Add($relative)){throw 'Unknown or duplicate lease member'}
      $target=Join-Path $leaseRoot $relative;[IO.Directory]::CreateDirectory((Split-Path $target))|Out-Null
      $input=$entry.Open();$output=[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
      try{$input.CopyTo($output);$output.Flush($true)}finally{$input.Dispose();$output.Dispose()}
      if((Hash-File $target) -ne $property.Value){throw 'Lease source hash mismatch'}
    }
  } finally {$zip.Dispose()}
  if($seen.Count -ne @($policy.lease.PSObject.Properties).Count){throw 'Missing lease archive member'}
  Hold-ExactTree $leaseRoot $policy.lease
  $nativeNim=Join-Path $profile.nimBin 'nim.exe';$nimImage=Require-PE $nativeNim 0xAA64
  $backend=Require-PE $clang 0xAA64
  if($nimImage.sha256 -ne $profile.nimSHA256 -or $backend.sha256 -ne $profile.clangSHA256){throw 'Foreign native daemon compiler'}
  $daemon=Join-Path $daemonRoot 'runquotad.exe'
  $compile=@('c','--skipUserCfg','--skipParentCfg','--skipProjCfg','--threads:on','-d:release','--lib:'+(Join-Path $native 'lib'),'--cc:clang','--clang.exe:'+$clang,'--clang.linkerexe:'+$clang,'--nimcache:'+(Join-Path $daemonRoot 'nimcache'),'--out:'+$daemon)
  foreach($lib in @($policy.runquota.PSObject.Properties.Name|Where-Object {$_ -match '^libs/[^/]+/src/'}|ForEach-Object {($_ -split '/')[1]}|Sort-Object -Unique)){$compile+=('--path:'+(Join-Path $privateSource ('libs/'+$lib+'/src')))}
  $compile+=('--path:'+(Join-Path $leaseRoot 'src'))
  $compile+=('apps/runquotad/runquotad.nim')
  Run-Stage 'native-runquotad-compile' $nativeNim $compile $privateSource $selectedPath|Out-Null
  $daemonImage=Require-PE $daemon 0xAA64;Hold-ExactFile $daemon $daemonImage.sha256
  $version=(Run-Stage 'native-runquotad-version' $daemon @('--version') $daemonRoot $selectedPath).Trim()
  if($version -cne 'runquotad 0.1.3'){throw 'Foreign daemon version probe'}
  Hold-ExactTree $source $policy.runquota;Hold-ExactTree $privateSource $policy.runquota;Hold-ExactTree $leaseRoot $policy.lease
  if((Require-PE $nativeNim 0xAA64).sha256 -ne $nimImage.sha256 -or (Require-PE $clang 0xAA64).sha256 -ne $backend.sha256){throw 'Daemon compiler changed'}
  $script:admittedNativeRunquotad=$daemon
  $receipt.nativeRunquota=[ordered]@{releaseArchiveSHA256=$policy.releaseArchiveSHA256;leaseRevision=$policy.leaseRevision;leaseArchiveSHA256=$policy.leaseArchiveSHA256;sourcePolicySHA256='18ba0559375b9f13b3cd43f5de2bdd82ae635043d915099d18cafd211c950691';daemon=$daemonImage;version=$version;compiler=$nimImage;backend=$backend;scope='Real native daemon prerequisite only; no admission/product acceptance; CLI retains daemon lifecycle'}
  return $daemon
}
