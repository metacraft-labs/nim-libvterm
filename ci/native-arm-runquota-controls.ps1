# Dot-source only inside the real held native SDK constructor, before its
# original Build-NativeRunquota call. No fake compiler/stage/kernel functions.
function Test-NativeRunquotaRefusals([string]$reproPath,[string]$selectedPath) {
  if(-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -cne 'Arm64'){throw 'Real native ARM controls require Windows ARM64'}
  $controlRoot=Join-Path $root 'native-runquota-controls'
  if(Test-Path -LiteralPath $controlRoot){throw 'Occupied daemon control root'}
  New-Item -ItemType Directory -Path $controlRoot|Out-Null
  $controlHold=[NativePythonOwnedPath]::new($controlRoot,$false);$holds.Add($controlHold)
  $rows=[Collections.Generic.List[object]]::new()
  function Expect-Refusal([string]$name,[string]$pattern,[scriptblock]$body) {
    $startHolds=$holds.Count;$stageCount=$receipt.stages.Count;$refused=$false;$failure=''
    try {& $body}catch{$refused=$true;$failure=$_.Exception.Message}
    finally {
      for($i=$holds.Count-1;$i -ge $startHolds;$i--){$holds[$i].Dispose();$holds.RemoveAt($i)}
    }
    if(-not $refused -or $failure -notmatch $pattern){throw ('Wrong or absent actual refusal: '+$name+' '+$failure)}
    if($receipt.stages.Count -ne $stageCount -or $null -ne $script:admittedNativeRunquotad){throw 'Refusal control launched a native stage or admitted a daemon'}
    $rows.Add([ordered]@{name=$name;refused=$true;failure=$failure;newNativeStages=0;scope='Real production precondition/PE refusal, not a fake daemon or admission success'})
  }
  Expect-Refusal 'missing-image' 'Cannot find path|does not exist|Could not find' {Require-PE (Join-Path $controlRoot 'absent-runquotad.exe') 0xAA64|Out-Null}
  # Existing selected release CLI really is x64; do not fabricate PE headers.
  $x64=Require-PE $reproPath 0x8664
  Expect-Refusal 'real-x64-image-rejected-as-native-daemon' 'Wrong native image architecture' {Require-PE $reproPath 0xAA64|Out-Null}
  foreach($pair in @(@('RUNQUOTAD_BIN',(Join-Path $controlRoot 'absent-runquotad.exe')),@('RUNQUOTAD_BIN',$clang),@('RUNQUOTAD_BIN',$reproPath),@('REPROBUILD_BYPASS_RUNQUOTA','1'))) {
    $name=$pair[0];$value=$pair[1]
    if(Test-Path ('Env:'+$name)){throw 'Controls require the original clean admission environment'}
    try {
      Set-Item ('Env:'+$name) $value
      Expect-Refusal ('inherited-'+$name+'-'+$rows.Count) 'Inherited admission selector refused' {Build-NativeRunquota $reproPath $selectedPath|Out-Null}
    } finally {Remove-Item ('Env:'+$name) -ErrorAction SilentlyContinue}
  }
  # Authentic bytes are copied into a counted private mutant tree. Only this
  # deliberately corrupt copy changes; the held production inputs stay intact.
  $policy=Get-Content -LiteralPath (Join-Path $SourceRoot 'ci/native-arm-runquota-policy.json') -Raw|ConvertFrom-Json -Depth 30
  $releaseBin=Split-Path $reproPath;$releaseRoot=Split-Path $releaseBin
  $fixture=Join-Path $controlRoot 'release';$fixtureBin=Join-Path $fixture 'bin';New-Item -ItemType Directory -Path $fixtureBin|Out-Null
  foreach($member in $policy.releaseImages.PSObject.Properties){Copy-Item -LiteralPath (Join-Path $releaseBin $member.Name) -Destination (Join-Path $fixtureBin $member.Name)}
  $source=Join-Path $releaseRoot 'share/repro/src/runquota';$mutantSource=Join-Path $fixture 'share/repro/src/runquota'
  foreach($member in $policy.runquota.PSObject.Properties){$target=Join-Path $mutantSource $member.Name;[IO.Directory]::CreateDirectory((Split-Path $target))|Out-Null;Copy-Item -LiteralPath (Join-Path $source $member.Name) -Destination $target}
  $mutantCli=Join-Path $fixtureBin ([IO.Path]::GetFileName($reproPath))
  $first=@($policy.runquota.PSObject.Properties)[0].Name;$target=Join-Path $mutantSource $first;$original=[IO.File]::ReadAllBytes($target)
  try {
    $changed=[byte[]]::new($original.Length+1);[Array]::Copy($original,$changed,$original.Length);$changed[$changed.Length-1]=10;[IO.File]::WriteAllBytes($target,$changed)
    Expect-Refusal 'changed-released-source' 'Daemon source/image hash mismatch' {Build-NativeRunquota $mutantCli $selectedPath|Out-Null}
  } finally {[IO.File]::WriteAllBytes($target,$original)}
  try {
    Remove-Item -LiteralPath $target
    Expect-Refusal 'missing-released-source' 'Missing daemon source member' {Build-NativeRunquota $mutantCli $selectedPath|Out-Null}
  } finally {[IO.File]::WriteAllBytes($target,$original)}
  # Exercise the actual full helper compiler-hash branch. It authenticates the
  # real source+lease first; no compiler executes because the profile is wrong.
  $originalRoot=$root;$originalNimSHA=$profile.nimSHA256
  try {
    $root=Join-Path $controlRoot 'compiler-hash-refusal';New-Item -ItemType Directory -Path $root|Out-Null
    $profile.nimSHA256=('0'*64)
    Expect-Refusal 'changed-held-compiler-policy' 'Foreign native daemon compiler' {Build-NativeRunquota $reproPath $selectedPath|Out-Null}
  } finally {$profile.nimSHA256=$originalNimSHA;$root=$originalRoot}
  if($rows.Count -ne 9){throw 'Incomplete real refusal inventory'}
  # A genuine syntax failure exercises unchanged Run-Stage primary-error,
  # natural direct wait and retained stderr; it is not a production stage pass.
  $productionReceipt=$receipt;$productionRoot=$root
  $compilerFailureRoot=Join-Path $controlRoot 'real-compiler-failure'
  New-Item -ItemType Directory -Path $compilerFailureRoot|Out-Null
  $badSource=Join-Path $compilerFailureRoot 'deliberately_invalid.nim'
  [IO.File]::WriteAllText($badSource,"proc deliberatelyInvalid( =`n",[Text.UTF8Encoding]::new($false))
  $compileFailure=$null
  try {
    $root=$compilerFailureRoot;$receipt=[ordered]@{stages=@()}
    $nativeNim=Join-Path $profile.nimBin 'nim.exe'
    $arguments=@('c','--skipUserCfg','--skipParentCfg','--skipProjCfg','--lib:'+(Join-Path $native 'lib'),'--cc:clang','--clang.exe:'+$clang,'--clang.linkerexe:'+$clang,'--nimcache:'+(Join-Path $root 'nimcache'),'--out:'+(Join-Path $root 'must-not-exist.exe'),$badSource)
    $failure=$null
    try {Run-Stage 'real-native-compiler-refusal-control' $nativeNim $arguments $root $selectedPath|Out-Null}catch{$failure=$_}
    if($null -eq $failure -or $failure.Exception.Message -cne 'Native stage failed: real-native-compiler-refusal-control'){throw 'Actual compiler primary error was not preserved'}
    if($receipt.stages.Count -ne 1){throw 'Real compiler refusal stage missing'}
    $row=$receipt.stages[0]
    if(-not $row.started -or -not $row.terminal -or $null -eq $row.exit -or $row.exit -eq 0 -or $row.imageSHA -cne $row.imageAfterSHA){throw 'Compiler refusal was not a real waited nonzero child'}
    if(Test-Path -LiteralPath (Join-Path $root 'must-not-exist.exe')){throw 'Invalid source unexpectedly produced executable'}
    $compileFailure=[ordered]@{stage=$row;primaryFailure=$failure.Exception.Message;sourceSHA=Hash-File $badSource;scope='Genuine failing native Nim compile/direct wait, not mocked compiler or production acceptance'}
  } finally {$receipt=$productionReceipt;$root=$productionRoot}
  $receipt.nativeRunquotaControls=[ordered]@{negativeCases=@($rows);actualCompilerFailure=$compileFailure;x64ControlImage=$x64;scope='Actual precondition/source/compiler-policy/PE refusals only; no graph or suite success'}
}
function Confirm-NativeRunquotaPositive([string]$daemon) {
  $image=Require-PE $daemon 0xAA64
  if($image.sha256 -ne $receipt.nativeRunquota.daemon.sha256 -or $receipt.nativeRunquota.version -cne 'runquotad 0.1.3'){throw 'Actual native daemon positive differs'}
  foreach($label in @('native-runquotad-compile','native-runquotad-version')){
    $matches=@($receipt.stages|Where-Object {$_.name -ceq $label})
    if($matches.Count -ne 1 -or $matches[0].exit -ne 0 -or -not $matches[0].started -or -not $matches[0].terminal -or $matches[0].imageSHA -cne $matches[0].imageAfterSHA){throw 'Missing genuine native daemon stage positive'}
  }
  $receipt.nativeRunquotaControls.positive=[ordered]@{daemon=$image;version=$receipt.nativeRunquota.version;scope='Actual production compile/version; actual native graph and original suites remain mandatory downstream'}
}
