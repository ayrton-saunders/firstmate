#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-live-selection)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

repo, lab = map(Path, sys.argv[1:])
bin_dir = lab / "bin"
bin_dir.mkdir()
for tool in ("bash", "dirname", "basename", "mktemp", "mkdir", "rm", "uname", "cat", "od", "tr", "ps", "sed", "grep", "head", "git"):
    target = shutil.which(tool)
    assert target, f"required test tool missing: {tool}"
    (bin_dir / tool).symlink_to(target)

interceptor = lab / "intercept.py"
interceptor.write_text('''import http.server
import json
import os
from pathlib import Path
import runpy
import socket
import subprocess
import sys
import threading
from unittest.mock import MagicMock, patch

class Intercepted(BaseException):
    pass

real_popen = subprocess.Popen

def capture(argv, **kwargs):
    assert Path(argv[0]).is_absolute(), argv
    assert argv[1:4] == ["serve", "--hostname", "127.0.0.1"], argv
    project = Path(kwargs["cwd"])
    config = json.loads((project / "opencode.json").read_text())
    assert config["model"] == "fixture/native", config
    assert config["agents"]["build"]["model"] == "fixture/native#proof", config
    assert kwargs["env"]["HOME"] != os.environ["HOME"]
    with real_popen(argv, cwd=project, env=kwargs["env"], stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
        output, error = child.communicate(timeout=5)
        assert child.returncode == 0, (output, error)
    with open(os.environ["LIVE_SELECTION_SETUP"], "a") as log:
        log.write(json.dumps({"argv": argv}) + "\\n")
    raise Intercepted()

sock = MagicMock()
sock.__enter__.return_value.getsockname.return_value = ("127.0.0.1", 12345)
sys.argv = sys.argv[1:]
with patch("shutil.copytree"), patch("subprocess.run"), patch.object(http.server, "ThreadingHTTPServer"), patch.object(threading, "Thread"), patch.object(socket, "socket", return_value=sock), patch.object(subprocess, "Popen", side_effect=capture):
    try:
        runpy.run_path(sys.argv[0], run_name="__main__")
    except Intercepted:
        sys.exit(23 if os.environ.get("LIVE_SELECTION_FAIL") == "1" else 0)
raise AssertionError("fixture never attempted process setup")
''')
wrapper = bin_dir / "python3"
wrapper.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(interceptor))} \"$@\"\n")
wrapper.chmod(0o755)


def candidate(path, version):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f'''#!/bin/sh
printf '%s\\t%s\\n' "$0" "$*" >> "$LIVE_SELECTION_CALLS"
if [ "$1" = --version ]; then
  printf '%s\\n' '{version}'
  exit 0
fi
[ "$1" = serve ] || exit 91
exit 0
''')
    path.chmod(0o755)
    return path


selected = candidate(lab / "selected" / "opencode-2-candidate", "2.0.22")
legacy = candidate(lab / "legacy" / "opencode-1-candidate", "1.9.0")
other = candidate(lab / "other" / "opencode", "2.0.11")
calls = lab / "calls"
setups = lab / "setups"
home = lab / "home"
home.mkdir()
env = {
    "PATH": f"{bin_dir}:{selected.parent}",
    "HOME": str(home),
    "TMPDIR": str(lab),
    "LANG": "C",
    "FM_TEST_SKIP_ORPHAN_REAP": "1",
    "FM_OPENCODE_V2_OFFLINE_LIVE": "1",
    "LIVE_SELECTION_CALLS": str(calls),
    "LIVE_SELECTION_SETUP": str(setups),
}
guard = repo / "tests/fm-opencode-primary-live-e2e.test.sh"
fixture = repo / "tests/opencode-v2-live-fixture.py"
bash = str(bin_dir / "bash")


def run_guard(selection=None, **overrides):
    calls.write_text("")
    setups.write_text("")
    current = {**env, **overrides}
    if selection is not None:
        current["FM_OPENCODE_LIVE_BINS"] = selection
    result = subprocess.run([bash, str(guard)], env=current, cwd=lab, capture_output=True, text=True, timeout=30)
    invoked = [line.split("\t", 1) for line in calls.read_text().splitlines()]
    started = [json.loads(line)["argv"][0] for line in setups.read_text().splitlines()]
    return result, invoked, started


def succeeded(result):
    assert result.returncode == 0, (result.stdout, result.stderr)


result, invoked, started = run_guard(str(selected))
succeeded(result)
assert started == [str(selected)], (result.stdout, result.stderr, started)
assert invoked == [[str(selected), "--version"], [str(selected), "serve --hostname 127.0.0.1 --port 12345"]], invoked
print("ok - explicit alternate-basename path runs without PATH opencode")

with_other = f"{env['PATH']}:{other.parent}"
relative = os.path.relpath(selected, lab)
result, invoked, started = run_guard(relative, PATH=with_other)
succeeded(result)
assert started == [str(selected)], started
assert all(path == str(selected) for path, _ in invoked), invoked
print("ok - relative explicit path cannot select a sibling PATH installation")

result, invoked, started = run_guard(f"{legacy} {selected} {other}", PATH=with_other)
succeeded(result)
assert started == [str(selected), str(other)], started
assert [path for path, args in invoked if args.startswith("serve ")] == started, invoked
assert "not OpenCode 2" in result.stdout, result.stdout
print("ok - each V2 candidate is exercised and legacy candidates remain skipped")

result, invoked, started = run_guard(str(legacy))
succeeded(result)
assert started == [] and "no OpenCode 2 executable" in result.stdout, (started, result.stdout)
assert invoked and all(path == str(legacy) and args == "--version" for path, args in invoked), invoked
print("ok - a legacy-only selection never starts the V2 fixture")

result, invoked, started = run_guard(str(selected), PATH=with_other, LIVE_SELECTION_FAIL="1")
assert result.returncode != 0, result.stdout
assert "OpenCode 2.0.22 native fixture failed" in result.stderr, result.stderr
assert started == [str(selected)], started
assert invoked[-1] == [str(selected), "--version"], invoked
assert all(path == str(selected) for path, _ in invoked), invoked
print("ok - fixture failure diagnostics probe only the selected executable")

result, invoked, started = run_guard(str(lab / "missing"))
assert result.returncode != 0 and "is missing" in result.stderr, (result.stdout, result.stderr)
assert invoked == [] and started == [], (invoked, started)
result, invoked, started = run_guard(str(selected), FM_OPENCODE_V2_OFFLINE_LIVE="0")
succeeded(result)
assert "disabled by FM_OPENCODE_V2_OFFLINE_LIVE=0" in result.stdout, result.stdout
assert invoked == [] and started == [], (invoked, started)
print("ok - missing candidates fail and disabled guards never probe or start anything")

result, invoked, started = run_guard(PATH=with_other)
succeeded(result)
assert started == [str(other)], started
assert all(path == str(other) for path, _ in invoked), invoked
result, invoked, started = run_guard()
assert result.returncode != 0 and "opencode is not installed" in result.stderr, result.stderr
assert invoked == [] and started == [], (invoked, started)
print("ok - default selection still requires and uses PATH opencode")

result, invoked, started = run_guard(str(selected), FM_OPENCODE_LIVE_E2E="1")
assert result.returncode != 0 and "opencode is not installed" in result.stderr, result.stderr
assert invoked == [] and started == [], (invoked, started)
result, invoked, started = run_guard(str(lab / "missing"), PATH=with_other, FM_OPENCODE_LIVE_E2E="1")
assert result.returncode != 0 and "tmux is not installed" in result.stderr, result.stderr
assert invoked == [] and started == [], (invoked, started)
print("ok - credentialed TUI selection still requires PATH opencode and ignores explicit candidates")

calls.write_text("")
setups.write_text("")
result = subprocess.run([str(wrapper), str(fixture)], env={**env, "PATH": with_other}, cwd=lab, capture_output=True, text=True, timeout=15)
succeeded(result)
assert [json.loads(line)["argv"][0] for line in setups.read_text().splitlines()] == [str(other)]
assert calls.read_text().split("\t", 1)[0] == str(other)
print("ok - standalone fixture default still resolves PATH opencode")
PY
