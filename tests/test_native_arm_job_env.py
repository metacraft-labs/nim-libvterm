#!/usr/bin/env python3
"""Check that the Windows ARM64 leg starts its native steps with a clean job
environment.

The native Windows ARM64 steps refuse what they did not set up themselves:
* "Authenticate owning checkout Git runtime configuration" refuses any
  inherited GIT_CONFIG_COUNT, GIT_CONFIG_PARAMETERS, GIT_CONFIG_KEY_n or
  GIT_CONFIG_VALUE_n before the owning checkout;
* ci/native-arm-runquota.ps1's Build-NativeRunquota refuses an inherited
  RunQuota (RUNQUOTAD_BIN, RUNQUOTA_BIN, ...) or toolchain (LIBRARY_PATH,
  CFLAGS, ...).
setup-dev-env, which runs first and builds an x64 Reprobuild CLI under
emulation, exports both by default. So on that leg each workflow asks
setup-dev-env for `git-access: none` and `export-build-env: false`, and
keeps the defaults everywhere else. The guards themselves stay as they are.

Workflow checks always run. With --actions <metacraft-github-actions Git
checkout>, the setup-dev-env revision the workflows use (a commit, or `dev`,
read as that checkout's origin/dev) is also read from Git and must declare
both inputs, so a revision older than them cannot pass. Pure text checks plus
`git show`; no network.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = [ROOT / '.github' / 'workflows' / name for name in ('ci.yml', 'ci-reprobuild.yml')]
ARM64 = "runner.os == 'Windows' && matrix.arch == 'arm64'"
EXPECTED = {
    'git-access': "${{ " + ARM64 + " && 'none' || 'read' }}",
    'export-build-env': "${{ " + ARM64 + " && 'false' || 'true' }}",
}
GUARD = "'^GIT_CONFIG_(COUNT|PARAMETERS|KEY_[0-9]+|VALUE_[0-9]+)$'"
USES = re.compile(r'uses: metacraft-labs/metacraft-github-actions/setup-dev-env@([0-9a-f]{40}|dev)\b')
FAILURES = []


def check(condition, message):
    if not condition:
        FAILURES.append(message)


def setup_dev_env_step(text):
    match = USES.search(text)
    if match is None:
        return None, ''
    start = text.rfind('\n      - name: ', 0, match.start())
    end = text.find('\n      - name: ', match.end())
    return match.group(1), text[start:end if end >= 0 else len(text)]


def with_inputs(step):
    inputs = {}
    lines = step.splitlines()
    if '        with:' not in lines:
        return inputs
    for line in lines[lines.index('        with:') + 1:]:
        if not line.startswith('          '):
            break
        if line.strip().startswith('#'):
            continue
        name, _, value = line.strip().partition(': ')
        inputs[name] = value
    return inputs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--actions', help='metacraft-github-actions Git checkout')
    args = parser.parse_args()

    pins = set()
    for workflow in WORKFLOWS:
        text = workflow.read_text(encoding='utf-8')
        pin, step = setup_dev_env_step(text)
        check(pin is not None, f'{workflow.name}: no setup-dev-env step at a commit or @dev')
        if pin is None:
            continue
        pins.add(pin)
        inputs = with_inputs(step)
        for name, value in EXPECTED.items():
            check(inputs.get(name) == value,
                  f'{workflow.name}: setup-dev-env {name} is {inputs.get(name)!r}, expected {value!r}')
        check(GUARD in text, f'{workflow.name}: the owning-checkout Git guard changed')
    check(len(pins) == 1, f'the workflows use different setup-dev-env revisions: {sorted(pins)}')

    if args.actions and pins:
        for pin in sorted(pins):
            ref = 'origin/dev' if pin == 'dev' else pin
            shown = subprocess.run(['git', '-C', args.actions, 'show', f'{ref}:setup-dev-env/action.yml'],
                                   capture_output=True, text=True)
            check(shown.returncode == 0, f'setup-dev-env@{pin} is not in {args.actions}: {shown.stderr.strip()}')
            action = shown.stdout
            check('\n  export-build-env:\n' in action, f'setup-dev-env@{pin} has no export-build-env input')
            check("read|write|none)" in action, f'setup-dev-env@{pin} does not accept git-access none')

    for failure in FAILURES:
        print('FAIL', failure)
    if FAILURES:
        return 1
    print(f'native ARM64 job environment: {len(WORKFLOWS)} workflows checked')
    return 0


if __name__ == '__main__':
    sys.exit(main())
