# Called only inside the held Libvterm native ARM constructor. Uses its real
# Run-Stage, Require-PE, Hash-File and NativePythonOwnedPath authority.
#
# The policy names no revision and no content hash. Every identity is derived
# from the engine revision the workflow pins (-EngineRevision):
#   engine checkout HEAD           = that revision
#   runquota revision              = the engine's flake.lock at that revision
#   nim-shm-lease revision         = runquota's flake.lock at its revision
# Source bytes come from Git object databases at those revisions, and each
# exported file must hash to its own blob id, so the exact member set and the
# per-file SHA-256 identities are recomputed for whatever revision is pinned.
# The engine images are those built from the pinned source; their measured
# hashes are held for the whole run and recorded in the receipt.

function Invoke-PinnedGit([string]$repository,[string[]]$arguments,[switch]$Binary) {
  $info=[Diagnostics.ProcessStartInfo]::new($gitImage);$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$repository
  foreach($key in @($info.Environment.Keys)){if($key.StartsWith('GIT_',[StringComparison]::OrdinalIgnoreCase)){$info.Environment.Remove($key)|Out-Null}}
  $info.Environment['GIT_TERMINAL_PROMPT']='0'
  $info.ArgumentList.Add('-C');$info.ArgumentList.Add($repository);foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
  $child=$null;$terminal=$false
  try {
    $child=[Diagnostics.Process]::Start($info);$script:activeStageChild=$child
    $stderr=$child.StandardError.ReadToEndAsync()
    $buffer=[IO.MemoryStream]::new();$child.StandardOutput.BaseStream.CopyTo($buffer)
    $child.WaitForExit();$terminal=$true
    if($child.ExitCode -ne 0){throw ('Pinned Git failed: '+$arguments[0]+' '+$stderr.Result.Trim())}
    if($Binary){return ,$buffer.ToArray()}
    return [Text.Encoding]::UTF8.GetString($buffer.ToArray())
  } finally {
    if($child -and -not $terminal){try{$terminal=$child.HasExited}catch{$terminal=$false}}
    if($child -and $terminal){$child.Dispose();$script:activeStageChild=$null}
    elseif($child){$script:unresolvedStageOwner=$true;[Console]::Error.WriteLine('native_pinned_git_unresolved pid='+$child.Id)}
  }
}
function Get-GitBlobId([byte[]]$bytes) {
  $header=[Text.Encoding]::UTF8.GetBytes('blob '+$bytes.Length+[char]0)
  $blob=[byte[]]::new($header.Length+$bytes.Length);[Array]::Copy($header,$blob,$header.Length);[Array]::Copy($bytes,0,$blob,$header.Length,$bytes.Length)
  [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($blob)).ToLowerInvariant()
}
function Assert-PinnedCommit([string]$repository,[string]$revision) {
  if($revision -cnotmatch '^[0-9a-f]{40}$'){throw 'Pinned revision is not a full commit id'}
  $resolved=$null
  try{$resolved=(Invoke-PinnedGit $repository @('rev-parse','--verify','--quiet','--end-of-options',($revision+'^{commit}'))).Trim()}catch{$resolved=$null}
  if($resolved -cne $revision){throw ('Pinned revision is not a commit: '+$revision)}
}
function Assert-CheckoutHead([string]$repository,[string]$revision,[string]$refusal) {
  $item=Get-Item -LiteralPath $repository -Force
  if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw ($refusal+': foreign checkout node')}
  $top=[IO.Path]::GetFullPath((Invoke-PinnedGit $repository @('rev-parse','--show-toplevel')).Trim()).TrimEnd('\','/')
  if(-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($repository).TrimEnd('\','/'),$top)){throw ($refusal+': not a Git toplevel')}
  $head=(Invoke-PinnedGit $repository @('rev-parse','HEAD')).Trim()
  if($head -cne $revision){throw ($refusal+': HEAD '+$head+' is not '+$revision)}
}
function Read-PinnedBlob([string]$repository,[string]$revision,[string]$path) {
  Assert-PinnedCommit $repository $revision
  $row=(Invoke-PinnedGit $repository @('ls-tree','-z','--full-tree',$revision,'--',$path)).TrimEnd([char]0)
  if($row -cnotmatch '^100644 blob ([0-9a-f]{40})\t(.+)$' -or $Matches[2] -cne $path){throw ('Pinned file is absent or not a regular file: '+$path)}
  $oid=$Matches[1];$bytes=Invoke-PinnedGit $repository @('cat-file','blob',$oid) -Binary
  if((Get-GitBlobId $bytes) -cne $oid){throw ('Pinned blob differs from its id: '+$path)}
  return ,$bytes
}
function Get-LockedInput([string]$repository,[string]$revision,[string]$inputName,[string]$owner,[string]$repo) {
  $lock=[Text.Encoding]::UTF8.GetString((Read-PinnedBlob $repository $revision 'flake.lock'))|ConvertFrom-Json -Depth 30
  $rootNode=$lock.nodes.PSObject.Properties[$lock.root]
  if($null -eq $rootNode){throw 'Pinned lock has no root node'}
  $edge=$rootNode.Value.inputs.PSObject.Properties[$inputName]
  if($null -eq $edge -or $edge.Value -isnot [string]){throw ('Pinned lock does not own input: '+$inputName)}
  $locked=$lock.nodes.PSObject.Properties[$edge.Value].Value.locked
  if($locked.type -cne 'github' -or $locked.owner -cne $owner -or $locked.repo -cne $repo){throw ('Foreign locked input: '+$inputName+' is '+$locked.type+':'+$locked.owner+'/'+$locked.repo)}
  if($locked.rev -cnotmatch '^[0-9a-f]{40}$'){throw ('Locked input is not a full commit id: '+$inputName)}
  return $locked.rev
}
# Derive every revision from the engine revision. Pure Git object reads: no
# working tree is consulted and nothing is fetched.
function Resolve-NativeRunquotaPins($policy,[string]$engineRoot,[string]$engineRevision,[string]$runquotaRepository) {
  Assert-PinnedCommit $engineRoot $engineRevision
  $runquotaRevision=Get-LockedInput $engineRoot $engineRevision $policy.runquota.engineLockInput $policy.runquota.owner $policy.runquota.repo
  $leaseRevision=Get-LockedInput $runquotaRepository $runquotaRevision $policy.lease.runquotaLockInput $policy.lease.owner $policy.lease.repo
  return [pscustomobject][ordered]@{engineRevision=$engineRevision;runquotaRevision=$runquotaRevision;leaseRevision=$leaseRevision;leaseURL=('https://github.com/'+$policy.lease.owner+'/'+$policy.lease.repo+'.git')}
}
function Test-PinnedMember([string]$name,[string[]]$members) {
  foreach($member in $members){if($member -ceq '' -or $member -ceq $name -or ($member.EndsWith('/') -and $name.StartsWith($member,[StringComparison]::Ordinal))){return $true}}
  return $false
}
# Write the selected members of one pinned tree to a new directory and return
# their SHA-256 map. Every byte written is checked against its Git blob id.
function Export-PinnedGitTree([string]$repository,[string]$revision,[string[]]$members,[string]$destination) {
  Assert-PinnedCommit $repository $revision
  if(Test-Path -LiteralPath $destination){throw 'Occupied pinned source export'}
  New-Item -ItemType Directory -Path $destination|Out-Null
  $expected=[ordered]@{};$covered=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($row in (Invoke-PinnedGit $repository @('ls-tree','-r','-z','--full-tree',$revision)).Split([char]0)) {
    if(-not $row){continue}
    if($row -cnotmatch '^([0-7]{6}) (blob|commit) ([0-9a-f]{40})\t(.+)$'){throw 'Unknown pinned tree entry'}
    $mode=$Matches[1];$type=$Matches[2];$oid=$Matches[3];$name=$Matches[4]
    if(-not (Test-PinnedMember $name $members)){continue}
    if($type -cne 'blob' -or $mode -notin @('100644','100755')){throw ('Pinned member is not a regular file: '+$name)}
    foreach($part in $name.Split('/')){if($part -in @('','.','..') -or $part.TrimEnd(' ','.') -cne $part -or $part.Contains('\') -or $part.Contains(':')){throw 'Unsafe pinned source segment'}}
    $bytes=Invoke-PinnedGit $repository @('cat-file','blob',$oid) -Binary
    if((Get-GitBlobId $bytes) -cne $oid){throw ('Pinned blob differs from its id: '+$name)}
    $target=Join-Path $destination $name;[IO.Directory]::CreateDirectory((Split-Path $target))|Out-Null
    $output=[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$output.Write($bytes,0,$bytes.Length);$output.Flush($true)}finally{$output.Dispose()}
    $expected[$name]=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    foreach($member in $members){if(Test-PinnedMember $name @($member)){$covered.Add($member)|Out-Null}}
  }
  foreach($member in $members){if(-not $covered.Contains($member)){throw ('Pinned source lacks declared member: '+$member)}}
  return [pscustomobject]$expected
}
# Fetch exactly one public commit into an empty repository. Git verifies every
# received object against its id.
function Initialize-PinnedFetch([string]$repository,[string]$url,[string]$revision) {
  if($revision -cnotmatch '^[0-9a-f]{40}$'){throw 'Pinned revision is not a full commit id'}
  if(@(Get-ChildItem -LiteralPath $repository -Force).Count -ne 0){throw 'Occupied pinned fetch repository'}
  Invoke-PinnedGit $repository @('init','--quiet')|Out-Null
  Invoke-PinnedGit $repository @('-c','protocol.version=2','fetch','--quiet','--no-tags','--depth=1','--',$url,$revision)|Out-Null
  Assert-PinnedCommit $repository $revision
}
function Get-RunquotaVersion([string]$sourceRoot) {
  $nimble=[IO.File]::ReadAllText((Join-Path $sourceRoot 'runquota.nimble'))
  $rows=[regex]::Matches($nimble,'(?m)^version\s*=\s*"([0-9]+(?:\.[0-9]+)*)"\s*$')
  if($rows.Count -ne 1){throw 'Pinned runquota declares no single version'}
  return 'runquotad '+$rows[0].Groups[1].Value
}
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
function Measure-ImageTree([string]$path) {
  $measured=[ordered]@{}
  foreach($item in Get-ChildItem -LiteralPath $path -Recurse -Force) {
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Engine image tree reparse entry'}
    if($item.PSIsContainer){continue}
    $measured[[IO.Path]::GetRelativePath($path,$item.FullName).Replace('\','/')]=Hash-File $item.FullName
  }
  if($measured.Count -eq 0){throw 'Empty engine image tree'}
  return [pscustomobject]$measured
}
function Build-NativeRunquota([string]$reproPath,[string]$selectedPath,[string]$engineRevision=$EngineRevision) {
  foreach($name in @('RUNQUOTAD_BIN','REPROBUILD_NO_RUNQUOTA','REPROBUILD_BYPASS_RUNQUOTA','RUNQUOTA_SOCKET','RUNQUOTA_BIN','REPROBUILD_AUTO_RUNQUOTA','REPROBUILD_SRC','SHM_LEASE_SRC','NIMFLAGS','CFLAGS','CPPFLAGS','LDFLAGS','GCC_EXEC_PREFIX','COMPILER_PATH','LIBRARY_PATH','CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH')) {
    if(Test-Path ('Env:'+$name)){throw ('Inherited admission selector refused: '+$name)}
  }
  $policyPath=Join-Path $SourceRoot 'ci/native-arm-runquota-policy.json'
  $policyStream=[IO.FileStream]::new($policyPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$holds.Add($policyStream)
  $policyBytes=[byte[]]::new($policyStream.Length);$offset=0
  while($offset -lt $policyBytes.Length){$n=$policyStream.Read($policyBytes,$offset,$policyBytes.Length-$offset);if($n -le 0){throw 'Short held daemon policy'};$offset+=$n}
  $policySHA=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($policyBytes)).ToLowerInvariant()
  if($policySHA -ne '9cb3b6ca84c01662d57e4a24c6515c5617f632bbed33bb1543a9bd8b57995e20'){throw 'Foreign native daemon policy'}
  $policy=[Text.Encoding]::UTF8.GetString($policyBytes)|ConvertFrom-Json -Depth 30
  if($policy.schemaId -cne 'nim_libvterm.native-arm-runquota-policy.v2'){throw 'Foreign native daemon policy schema'}
  # The CLI on PATH must be the one built in the pinned engine checkout.
  $engineBin=Split-Path ([IO.Path]::GetFullPath($reproPath))
  $engineRoot=$engineBin
  foreach($part in $policy.engine.binPath.Split('/')){$engineRoot=Split-Path $engineRoot}
  if(-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath((Join-Path $engineRoot $policy.engine.binPath)).TrimEnd('\','/'),$engineBin.TrimEnd('\','/')) -or -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFileName($reproPath),$policy.engine.cli)){throw 'Foreign engine image location'}
  Assert-CheckoutHead $engineRoot $engineRevision 'Foreign engine revision'
  $runquotaRepository=Join-Path (Split-Path $engineRoot) $policy.runquota.checkout
  $pins=Resolve-NativeRunquotaPins $policy $engineRoot $engineRevision $runquotaRepository
  $runquotaRevision=$pins.runquotaRevision;$leaseRevision=$pins.leaseRevision;$leaseURL=$pins.leaseURL
  Assert-CheckoutHead $runquotaRepository $runquotaRevision 'Foreign runquota checkout'
  $engineImages=Measure-ImageTree $engineBin
  Hold-ExactTree $engineBin $engineImages
  $daemonRoot=Join-Path $root 'native-runquota'
  if(Test-Path -LiteralPath $daemonRoot){throw 'Occupied native daemon root'}
  New-Item -ItemType Directory -Path $daemonRoot|Out-Null
  $daemonHold=[NativePythonOwnedPath]::new($daemonRoot,$false);$holds.Add($daemonHold)
  $privateSource=Join-Path $daemonRoot 'runquota'
  $runquotaSources=Export-PinnedGitTree $runquotaRepository $runquotaRevision $policy.runquota.members $privateSource
  Hold-ExactTree $privateSource $runquotaSources
  $leaseGit=Join-Path $daemonRoot 'lease-git';New-Item -ItemType Directory -Path $leaseGit|Out-Null
  Initialize-PinnedFetch $leaseGit $leaseURL $leaseRevision
  $leaseRoot=Join-Path $daemonRoot 'nim-shm-lease'
  $leaseSources=Export-PinnedGitTree $leaseGit $leaseRevision $policy.lease.members $leaseRoot
  Hold-ExactTree $leaseRoot $leaseSources
  $expectedVersion=Get-RunquotaVersion $privateSource
  $nativeNim=Join-Path $profile.nimBin 'nim.exe';$nimImage=Require-PE $nativeNim 0xAA64
  $backend=Require-PE $clang 0xAA64
  if($nimImage.sha256 -ne $profile.nimSHA256 -or $backend.sha256 -ne $profile.clangSHA256){throw 'Foreign native daemon compiler'}
  $daemon=Join-Path $daemonRoot 'runquotad.exe'
  $compile=@('c','--skipUserCfg','--skipParentCfg','--skipProjCfg','--threads:on','-d:release','--lib:'+(Join-Path $native 'lib'),'--cc:clang','--clang.exe:'+$clang,'--clang.linkerexe:'+$clang,'--nimcache:'+(Join-Path $daemonRoot 'nimcache'),'--out:'+$daemon)
  foreach($lib in @($runquotaSources.PSObject.Properties.Name|Where-Object {$_ -match '^libs/[^/]+/src/'}|ForEach-Object {($_ -split '/')[1]}|Sort-Object -Unique)){$compile+=('--path:'+(Join-Path $privateSource ('libs/'+$lib+'/src')))}
  $compile+=('--path:'+(Join-Path $leaseRoot 'src'))
  $compile+=('apps/runquotad/runquotad.nim')
  Run-Stage 'native-runquotad-compile' $nativeNim $compile $privateSource $selectedPath|Out-Null
  $daemonImage=Require-PE $daemon 0xAA64;Hold-ExactFile $daemon $daemonImage.sha256
  $version=(Run-Stage 'native-runquotad-version' $daemon @('--version') $daemonRoot $selectedPath).Trim()
  if($version -cne $expectedVersion){throw 'Foreign daemon version probe'}
  Hold-ExactTree $engineBin $engineImages;Hold-ExactTree $privateSource $runquotaSources;Hold-ExactTree $leaseRoot $leaseSources
  Assert-CheckoutHead $engineRoot $engineRevision 'Foreign engine revision';Assert-CheckoutHead $runquotaRepository $runquotaRevision 'Foreign runquota checkout'
  if((Require-PE $nativeNim 0xAA64).sha256 -ne $nimImage.sha256 -or (Require-PE $clang 0xAA64).sha256 -ne $backend.sha256){throw 'Daemon compiler changed'}
  $script:admittedNativeRunquotad=$daemon
  $receipt.nativeRunquota=[ordered]@{engineRevision=$engineRevision;engineImages=$engineImages;runquotaRevision=$runquotaRevision;runquotaSources=$runquotaSources;leaseRevision=$leaseRevision;leaseURL=$leaseURL;leaseSources=$leaseSources;sourcePolicySHA256=$policySHA;daemon=$daemonImage;version=$version;expectedVersion=$expectedVersion;compiler=$nimImage;backend=$backend;scope='Real native daemon prerequisite only; no admission/product acceptance; CLI retains daemon lifecycle'}
  return $daemon
}
