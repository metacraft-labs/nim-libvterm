#!/usr/bin/env python3
"""Check the native Windows ARM64 runquota policy and its derivation.

The Windows ARM64 leg builds a native runquotad from source. Its inputs are
bound through a chain that starts at the engine revision CI runs, the fleet
Reprobuild pin (`pins/reprobuild.json` in metacraft-labs/metacraft-github-actions)
that setup-dev-env installs and reports as `repro-commit`:

* the workflows pass that output to ci/windows-native-arm-sdk.ps1 as
  -EngineRevision "$env:REPRO_COMMIT";
* the engine's flake.lock at that revision names the runquota revision;
* runquota's flake.lock at that revision names the nim-shm-lease revision;
* source bytes are read from Git at those revisions and checked against
  their blob ids.

So the committed policy must not name any revision or content hash: a pin
move would otherwise leave it stale. This test checks the policy shape, the
SHA-256 pins that chain ci/windows-native-arm-sdk.ps1 to the helper, its
controls and the policy, that every workflow passes setup-dev-env's engine and
names none of its own, and it runs the real PowerShell derivation (the
functions the ARM64 leg calls) against Git checkouts of reprobuild and
runquota. The engine revision is `--revision` (CI passes `repro-commit`), or
else the `rev` of `--pin` (default: the sibling metacraft-github-actions
checkout's pins/reprobuild.json). The nim-shm-lease
export fetches the derived revision from GitHub, as the ARM64 leg does.

Needs pwsh, git and network access; run in the dev shell.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / 'ci'
SDK = CI / 'windows-native-arm-sdk.ps1'
HELPER = CI / 'native-arm-runquota.ps1'
CONTROLS = CI / 'native-arm-runquota-controls.ps1'
OWNED_PATH = CI / 'native-python-owned-path.ps1'
POLICY = CI / 'native-arm-runquota-policy.json'
HEX40 = re.compile(r'\b[0-9a-f]{40}\b')
FULL_SHA = re.compile(r'[0-9a-f]{40}')
# Workflow inputs that would replace the pinned engine or the sibling
# revisions it is built against.
OVERRIDES = ('repro-version', 'repro-build-pin', 'repro-runquota-pin',
             'repro-io-mon-pin', 'repro-stackable-hooks-pin', 'repro-posix-io-mon-pin')
ENGINE_ARGUMENT = '-EngineRevision "$env:REPRO_COMMIT"'
HEX64 = re.compile(r'\b[0-9a-f]{64}\b')


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_policy_shape():
    text = POLICY.read_text()
    policy = json.loads(text)
    assert policy.get('schemaId') == 'nim_libvterm.native-arm-runquota-policy.v2', (
        f"{POLICY.name}: expected the revision-independent v2 schema, got {policy.get('schemaId')!r}")
    pinned = sorted(set(HEX40.findall(text)) | set(HEX64.findall(text)))
    assert not pinned, (
        f'{POLICY.name} names revisions or content hashes {pinned}; derive them from the '
        'engine pin instead, so moving the pin needs no hand-copied values')
    for stale in ('releaseArchiveSHA256', 'releaseImages', 'share/repro'):
        assert stale not in text, f'{POLICY.name} still binds the release install layout ({stale})'
    assert 'runquota.nimble' in policy['runquota']['members'], 'the daemon version source must be exported'
    assert 'apps/runquotad/' in policy['runquota']['members'], 'the daemon entry point must be exported'
    return policy


def check_hash_chain():
    sdk = SDK.read_text()
    helper = HELPER.read_text()
    expected = {
        'Foreign native daemon constructor': sha256(HELPER),
        'Native daemon control source mismatch': sha256(CONTROLS),
        'Unknown native held-path helper image': sha256(OWNED_PATH),
    }
    for refusal, digest in expected.items():
        row = re.search(r"'([0-9a-f]{64})'\)\s*\{\s*throw '" + re.escape(refusal) + "'", sdk)
        assert row, f'{SDK.name}: no SHA-256 pin guards "{refusal}"'
        assert row.group(1) == digest, f'{SDK.name}: "{refusal}" pins {row.group(1)}, file is {digest}'
    policy_pins = set(HEX64.findall(helper))
    assert policy_pins == {sha256(POLICY)}, (
        f'{HELPER.name} pins {sorted(policy_pins)}, {POLICY.name} is {sha256(POLICY)}')


def check_workflows():
    """Every workflow that runs the native ARM64 SDK hands it setup-dev-env's engine."""
    checked = []
    for path in sorted((ROOT / '.github/workflows').glob('*.yml')):
        text = path.read_text()
        if 'windows-native-arm-sdk.ps1' not in text:
            continue
        for setting in OVERRIDES:
            assert not re.search(r'^\s+' + setting + r':', text, re.M), (
                f'{path.name} overrides the pinned engine with {setting}')
        assert re.search(r'^\s+REPRO_COMMIT:\s*\$\{\{\s*steps\.[\w-]+\.outputs\.repro-commit\s*\}\}\s*$',
                         text, re.M), f'{path.name} must pass setup-dev-env\'s repro-commit as REPRO_COMMIT'
        for invocation in re.findall(r'windows-native-arm-sdk\.ps1\b[^\n]*', text):
            assert ENGINE_ARGUMENT in invocation, (
                f'{path.name}: the native ARM64 SDK step must pass {ENGINE_ARGUMENT}')
            assert not HEX40.search(invocation.replace('${{ github.sha }}', '')), (
                f'{path.name}: the native ARM64 SDK step names a literal revision')
        checked.append(path.name)
    assert checked, 'no workflow runs the native ARM64 SDK'
    return checked


def flake_input(repository, revision, name):
    lock = json.loads(subprocess.check_output(['git', '-C', str(repository), 'show', f'{revision}:flake.lock']))
    node = lock['nodes'][lock['nodes'][lock['root']]['inputs'][name]]['locked']
    return node['owner'], node['repo'], node['rev']


PROBE = r'''
param([string]$Helper,[string]$Engine,[string]$EngineRevision,[string]$Runquota,[string]$Out)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# The Nix pwsh wrapper exports its own LD_LIBRARY_PATH; it is for pwsh, and
# would make a git built against another glibc fail to load its helpers.
Remove-Item Env:LD_LIBRARY_PATH -ErrorAction SilentlyContinue
$gitImage=(Get-Command git -CommandType Application | Select-Object -First 1).Source
$activeStageChild=$null;$unresolvedStageOwner=$false
. $Helper
$policy=Get-Content -LiteralPath (Join-Path (Split-Path $Helper) 'native-arm-runquota-policy.json') -Raw|ConvertFrom-Json -Depth 30
function Expect-Refusal([string]$pattern,[scriptblock]$body) {
  $failure=$null;try{& $body}catch{$failure=$_.Exception.Message}
  if($null -eq $failure -or $failure -notmatch $pattern){throw ('Wrong or absent refusal: '+$pattern+' got '+$failure)}
  return $failure
}
$refusals=[ordered]@{}
$refusals.foreignEngine=Expect-Refusal 'Foreign engine revision' {Assert-CheckoutHead $Engine ('0'*40) 'Foreign engine revision'}
$foreign=$policy|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30;$foreign.runquota.owner='not-'+$foreign.runquota.owner
$refusals.foreignLockInput=Expect-Refusal 'Foreign locked input' {Resolve-NativeRunquotaPins $foreign $Engine $EngineRevision $Runquota|Out-Null}
$pins=Resolve-NativeRunquotaPins $policy $Engine $EngineRevision $Runquota
$runquotaTree=Join-Path $Out 'runquota'
$runquotaMap=Export-PinnedGitTree $Runquota $pins.runquotaRevision $policy.runquota.members $runquotaTree
$version=Get-RunquotaVersion $runquotaTree
$leaseGit=Join-Path $Out 'lease-git';New-Item -ItemType Directory -Path $leaseGit|Out-Null
Initialize-PinnedFetch $leaseGit $pins.leaseURL $pins.leaseRevision
$leaseTree=Join-Path $Out 'lease'
$leaseMap=Export-PinnedGitTree $leaseGit $pins.leaseRevision $policy.lease.members $leaseTree
$refusals.absentMember=Expect-Refusal 'Pinned source lacks declared member' {Export-PinnedGitTree $Runquota $pins.runquotaRevision @('apps/runquotad/','no-such-member/') (Join-Path $Out 'absent')|Out-Null}
$refusals.notACommit=Expect-Refusal 'Pinned revision is not a commit' {Export-PinnedGitTree $Runquota ('0'*40) $policy.runquota.members (Join-Path $Out 'not-a-commit')|Out-Null}
[ordered]@{pins=$pins;runquota=$runquotaMap;lease=$leaseMap;version=$version;refusals=$refusals}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $Out 'result.json')
'''


def check_derivation(engine, runquota, revisions):
    engine_revision, runquota_pin = revisions
    policy = json.loads(POLICY.read_text())
    owner, repo, locked_runquota = flake_input(engine, engine_revision, policy['runquota']['engineLockInput'])
    assert (owner, repo) == (policy['runquota']['owner'], policy['runquota']['repo'])
    assert locked_runquota == runquota_pin, (
        f'workflow runquota pin {runquota_pin} differs from the engine lock {locked_runquota}')
    lease_owner, lease_repo, lease_revision = flake_input(runquota, locked_runquota, policy['lease']['runquotaLockInput'])
    with tempfile.TemporaryDirectory(prefix='nim-libvterm-native-arm-policy-') as scratch:
        work = Path(scratch)
        probe = work / 'probe.ps1'
        probe.write_text(PROBE)
        out = work / 'out'
        out.mkdir()
        subprocess.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', str(probe),
                        '-Helper', str(HELPER), '-Engine', str(engine), '-EngineRevision', engine_revision,
                        '-Runquota', str(runquota), '-Out', str(out)], check=True)
        result = json.loads((out / 'result.json').read_text())
        pins = result['pins']
        assert pins['engineRevision'] == engine_revision, pins
        assert pins['runquotaRevision'] == locked_runquota, pins
        assert pins['leaseRevision'] == lease_revision, pins
        assert pins['leaseURL'] == f'https://github.com/{lease_owner}/{lease_repo}.git', pins
        for name, repository, revision, members in (
                ('runquota', runquota, locked_runquota, policy['runquota']['members']),
                ('lease', None, lease_revision, policy['lease']['members'])):
            exported = result[name]
            assert exported, f'{name}: nothing exported'
            if repository is None:
                repository = out / 'lease-git'
            listing = subprocess.check_output(['git', '-C', str(repository), 'ls-tree', '-r', '-z',
                                               '--name-only', '--full-tree', revision]).decode().split('\0')
            selected = {path for path in listing if path and any(
                path == member or (member.endswith('/') and path.startswith(member)) or member == ''
                for member in members)}
            assert set(exported) == selected, (name, sorted(set(exported) ^ selected)[:10])
            for path, digest in exported.items():
                blob = subprocess.check_output(['git', '-C', str(repository), 'show', f'{revision}:{path}'])
                assert hashlib.sha256(blob).hexdigest() == digest, (name, path)
                assert (out / name / path).read_bytes() == blob, (name, path)
        nimble = subprocess.check_output(['git', '-C', str(runquota), 'show', f'{locked_runquota}:runquota.nimble']).decode()
        version = re.search(r'^version\s*=\s*"([0-9.]+)"', nimble, re.M).group(1)
        assert result['version'] == f'runquotad {version}', result['version']
        assert any(re.match(r'libs/[^/]+/src/', path) for path in result['runquota']), 'no library sources exported'
        print(f'PASS engine {engine_revision}: runquota {locked_runquota}, lease {lease_revision}, '
              f'{len(result["runquota"])}+{len(result["lease"])} sources, {result["version"]}; '
              f'refusals: {", ".join(result["refusals"])}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--reprobuild', type=Path, default=ROOT.parent / 'reprobuild')
    parser.add_argument('--runquota', type=Path, default=ROOT.parent / 'runquota')
    parser.add_argument('--revision', help="the engine's Reprobuild commit (default: the pin's rev)")
    parser.add_argument('--pin', type=Path,
                        default=ROOT.parent / 'metacraft-github-actions/pins/reprobuild.json')
    # Another engine revision, for example the next pin, can be checked with
    # the runquota pin its own lock names.
    parser.add_argument('--engine-revision', action='append', default=[])
    args = parser.parse_args()
    check_policy_shape()
    check_hash_chain()
    check_workflows()
    if args.revision:
        revision = args.revision
    elif args.pin.is_file():
        revision = json.loads(args.pin.read_text())['rev']
    else:
        raise AssertionError(f'no --revision and no pin file at {args.pin}')
    assert FULL_SHA.fullmatch(revision), f'the engine must be a full commit SHA: {revision!r}'
    policy = json.loads(POLICY.read_text())
    targets = [(revision, flake_input(args.reprobuild, revision, policy['runquota']['engineLockInput'])[2])]
    for extra in args.engine_revision:
        targets.append((extra, flake_input(args.reprobuild, extra, policy['runquota']['engineLockInput'])[2]))
    for target in targets:
        check_derivation(args.reprobuild.resolve(), args.runquota.resolve(), target)


if __name__ == '__main__':
    main()
