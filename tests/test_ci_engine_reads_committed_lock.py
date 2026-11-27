#!/usr/bin/env python3
"""Compile the lock reader of the engine CI runs and read the shipping lock.

CI runs the fleet Reprobuild pin, `pins/reprobuild.json` in
metacraft-labs/metacraft-github-actions, which setup-dev-env installs when a
workflow names no engine of its own. The workflows must not name one (no
repro-version, repro-build-pin, bootstrap sibling pin or literal
`github:metacraft-labs/reprobuild/<sha>`), so every leg runs that one engine
and builds it against the siblings its own flake.lock pins.

The revision is `--revision` (CI passes setup-dev-env's `repro-commit`
output), or else the `rev` of `--pin` (default: the sibling
metacraft-github-actions checkout's pins/reprobuild.json).

No engine, parser, filesystem or compiler is mocked. The sibling Reprobuild
Git object database supplies exact immutable source revisions; no checkout is
moved. Run in the dev shell with the sibling repository available. This
checks reader compatibility on this host; it does not claim native bootstrap
qualification for other operating systems.
"""
import argparse
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
PROBE = '''import std/os
import repro_lock
let text = readFile(paramStr(1))
let solved = parseSolvedGraphLock(text)
let locked = parseLockedDependencies(text)
doAssert solved.packages.len == locked.packages.len
# Both readers are on the build/publication path; neither may accept a
# partial lock silently after a schema migration.
echo "packages=", solved.packages.len, " deps=", locked.deps.len
'''
V2_CONTROL = '''schema = "reprobuild.solved-graph-lock.v2"
[lock]
platform = "amd64-linux"
optimal = false
inputs_digest = "fnv1a64:0123456789abcdef"
variants = []
packages = []
deps = []
'''


# Workflow inputs that would replace the pinned engine or the sibling
# revisions it is built against.
OVERRIDES = ('repro-version', 'repro-build-pin', 'repro-runquota-pin',
             'repro-io-mon-pin', 'repro-stackable-hooks-pin', 'repro-posix-io-mon-pin')
FULL_SHA = re.compile(r'[0-9a-f]{40}')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reprobuild', type=Path, default=ROOT.parent / 'reprobuild')
    parser.add_argument('--revision', help="the engine's Reprobuild commit (default: the pin's rev)")
    parser.add_argument('--pin', type=Path,
                        default=ROOT.parent / 'metacraft-github-actions/pins/reprobuild.json')
    # Every workflow that installs the engine must install the same one, so a
    # second workflow cannot keep an engine that rejects the v3 lock. With no
    # override in any of them, all run the pin.
    parser.add_argument('--workflow', type=Path, action='append',
                        help='default: every workflow under .github/workflows')
    parser.add_argument('--nim', default='nim')
    args = parser.parse_args()
    paths = args.workflow or sorted((ROOT / '.github/workflows').glob('*.yml'))
    for path in paths:
        text = path.read_text()
        for setting in OVERRIDES:
            if re.search(r'^\s+' + setting + r':', text, re.M):
                raise AssertionError(f'{path.name} overrides the pinned engine with {setting}')
        bound = sorted(set(re.findall(r'github:metacraft-labs/reprobuild/([0-9a-f]{40})', text)))
        if bound:
            raise AssertionError(f'{path.name} names a literal Reprobuild revision: {bound}')
    if args.revision:
        revision = args.revision
    elif args.pin.is_file():
        revision = json.loads(args.pin.read_text())['rev']
    else:
        raise AssertionError(f'no --revision and no pin file at {args.pin}')
    if not FULL_SHA.fullmatch(revision):
        raise AssertionError(f'the engine must be a full commit SHA: {revision!r}')
    revisions = [revision]
    committed = (ROOT / 'repro.lock').read_bytes()
    lock = tomllib.loads(committed.decode())['lock']
    expected = f"packages={len(lock['packages'])} deps={len(lock['deps'])}"
    failures = []
    for revision in revisions:
        with tempfile.TemporaryDirectory(prefix='nim-libvterm-ci-lock-reader-') as scratch:
            work = Path(scratch)
            archive = subprocess.check_output(['git', '-C', str(args.reprobuild),
                                                'archive', revision, 'libs', 'flake.lock'])
            with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
                # The archive is `git archive` output of a pinned, immutable
                # Reprobuild revision (not untrusted input). Interpreters whose
                # tarfile predates extraction filters (no `data_filter`) reject
                # the `filter` keyword, so pass it only where it exists.
                if hasattr(tarfile, 'data_filter'):
                    tar.extractall(work, filter='data')
                else:
                    tar.extractall(work)
            (work / 'probe.nim').write_text(PROBE)
            (work / 'v2.lock').write_text(V2_CONTROL)
            (work / 'committed.lock').write_bytes(committed)
            paths = sorted((work / 'libs').glob('*/src'))
            command = [args.nim, 'c', '--hints:off', '--parallelBuild:2',
                        '-d:reproVendoredHash',
                        '--passC:-I' + str(work / 'libs/blake3/src/blake3/vendor'),
                        *('--path:' + str(p) for p in paths),
                        '--out:' + str(work / 'probe'), str(work / 'probe.nim')]
            print(f'Compiling exact CI reader {revision}', flush=True)
            run(*command, cwd=work)
            # A v2 positive control proves the probe and dependencies actually
            # work before attributing the shipping lock failure to its schema.
            control = subprocess.check_output([str(work / 'probe'), str(work / 'v2.lock')], text=True)
            assert control.strip() == 'packages=0 deps=0', control
            current = subprocess.run([str(work / 'probe'), str(work / 'committed.lock')],
                                      capture_output=True, text=True)
            if current.returncode or current.stdout.strip() != expected:
                failures.append(revision)
                print(f'FAIL {revision}: {current.stdout}{current.stderr}', flush=True)
            else:
                print(f'PASS {revision}: {expected}', flush=True)
    assert not failures, f'CI engines cannot read committed lock: {failures}'


if __name__ == '__main__':
    main()
