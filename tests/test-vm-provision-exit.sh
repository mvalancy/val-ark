#!/usr/bin/env bash
# Offline regression: the real VM runner must reject partial provisioning.
set -euo pipefail
VALARK_VM_TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)" python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
# The suite runner may invoke this script from a different working directory.
root = Path(os.environ['VALARK_VM_TEST_ROOT']) if 'VALARK_VM_TEST_ROOT' in os.environ else root
with tempfile.TemporaryDirectory(prefix='valark-vm-runner-') as temp:
    sandbox = Path(temp)
    (sandbox / 'tests/vm').mkdir(parents=True)
    (sandbox / 'tests/lib').mkdir()
    (sandbox / 'bin').mkdir()
    for name in ['vm/run.sh', 'lib/results.sh']:
        shutil.copyfile(root / 'tests' / name, sandbox / 'tests' / name)
    (sandbox / 'bin/git').write_text('''#!/bin/bash
# Stub the source archive; no host repository or VM is touched.
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then printf archive > "$2"; exit 0; fi
  shift
done
exit 1
''')
    (sandbox / 'bin/multipass').write_text('''#!/bin/bash
if [ "$1" != exec ] || [ "$4" != bash ]; then exit 0; fi
case "$VM_SCENARIO" in
  no-output) exit 0 ;;
  timeout) printf 'STEP|unpack source|pass|1|\n'; exit 124 ;;
  partial) printf 'STEP|unpack source|pass|1|\n'; exit 0 ;;
  failed-exit) printf 'STEP|unpack source|pass|1|\n### provision done\n'; exit 2 ;;
  failed-step) printf 'STEP|scripts/setup.sh|fail|1|setup failed\n### provision done\n'; exit 0 ;;
  complete) printf 'STEP|unpack source|pass|1|\nSTEP|web smoke|pass|1|\n### provision done\n'; exit 0 ;;
esac
''')
    for script in (sandbox / 'bin').iterdir():
        script.chmod(0o755)
    for scenario in ['no-output', 'timeout', 'partial', 'failed-exit', 'failed-step', 'complete']:
        env = dict(os.environ, PATH=str(sandbox / 'bin') + os.pathsep + os.environ['PATH'],
                   VM_SCENARIO=scenario, VALARK_VM_VERSIONS='24.04', VALARK_VM_KEEP='0',
                   VALARK_RESULTS_DIR=str(sandbox / 'results'))
        proc = subprocess.run(['bash', str(sandbox / 'tests/vm/run.sh')], env=env,
                              cwd=sandbox, text=True, capture_output=True)
        report = json.loads((sandbox / 'results/vm-setup.json').read_text())
        expected_success = scenario == 'complete'
        assert (proc.returncode == 0) == expected_success, (scenario, proc.stdout, proc.stderr)
        assert (report['summary']['failed'] == 0) == expected_success, (scenario, report)
        print(f'PASS: {scenario}')
PY
