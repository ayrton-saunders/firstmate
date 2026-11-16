#!/usr/bin/env python3
"""Scratch-only forced failure through the actual extension-binding test cleanup."""
import os, pathlib, shutil, subprocess, tarfile, tempfile

root = pathlib.Path.cwd()
evidence = pathlib.Path('~/.no-mistakes/evidence/01M7JHNMY5H5PXH2WPTYCXFRA2')
with tempfile.TemporaryDirectory(prefix='.diagnostic-proof-', dir=root) as temporary:
    temporary = pathlib.Path(temporary)
    for label in ('before', 'after'):
        scratch = temporary / label
        scratch.mkdir()
        for directory in ('bin', 'tests'):
            shutil.copytree(root / directory, scratch / directory)
        if label == 'before':
            for filename in ('bin/fm-procevent.sh', 'tests/fm-extension-binding.test.sh'):
                data = subprocess.check_output(['git', 'show', 'ace0bb7b:' + filename])
                (scratch / filename).write_bytes(data)
        test = scratch / 'tests/fm-extension-binding.test.sh'
        text = test.read_text()
        old = '"$orphan_source" --config-ref silent-result >/dev/null'
        assert text.count(old) == 1
        text = text.replace(old, '"$orphan_source" --config-ref good >/dev/null')
        anchor = 'TMP_ROOT=$(cd "$TMP_ROOT_RAW" && pwd -P)\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '''printf 'PROOF_FIXTURE_ROOT=%s\\n' "$TMP_ROOT"
python3 - "$TMP_ROOT/oversized-fixture" <<'PROOF_PY'
import sys
with open(sys.argv[1], 'wb') as stream:
    stream.write(b'fixture-prefix-preserved\\n')
    stream.write(b'x' * (16 * 1024 * 1024 - stream.tell()))
PROOF_PY
''')
        test.write_text(text)
        startup = scratch / 'startup.sh'
        startup.write_text('''if [ "${0##*/}" = fm-procevent.sh ] && [ "${1:-}" = _start ]; then
  perl -e 'print STDERR "startup-diagnostic-noise\\n" x 65536 or exit 99' || exit 99
fi
''')
        destination = pathlib.Path(tempfile.mkdtemp(prefix='forced-' + label + '-accepted-', dir=evidence))
        env = os.environ.copy()
        env.update(FM_EXTENSION_BINDING_SEGMENT='lifecycle-orphan-readiness',
                   FM_TEST_EXTENSION_BINDING_DIAGNOSTIC_DIR=str(destination),
                   BASH_ENV=str(startup))
        result = subprocess.run(['bash', 'bin/fm-test-run.sh', 'tests/fm-extension-binding.test.sh'],
                                cwd=scratch, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=150)
        output = result.stdout.decode(errors='replace')
        (evidence / ('forced-' + label + '.log')).write_text(output)
        assert result.returncode != 0, output
        assert 'recovered source orphan-first never handled its private result' in output, output
        fixture_line = next(line for line in output.splitlines() if line.startswith('PROOF_FIXTURE_ROOT='))
        fixture_root = pathlib.Path(fixture_line.split('=', 1)[1])
        assert not fixture_root.exists(), 'fixture cleanup did not finish'
        captures = list(destination.glob('lifecycle-orphan-readiness.*'))
        assert len(captures) == 1, captures
        capture = captures[0]
        assert 'exit=1\n' in (capture / 'outcome.txt').read_text()
        archive_path = capture / 'fixture.tar'
        with tarfile.open(archive_path) as archive:
            members = archive.getmembers()
            for member in members:
                if member.isfile():
                    assert len(archive.extractfile(member).read()) == member.size
            def member(suffix):
                return next(item for item in members if item.name.endswith('/' + suffix))
            stderr = archive.extractfile(member('detached-runners.stderr')).read()
            big = archive.extractfile(member('oversized-fixture')).read()
            assert big.startswith(b'fixture-prefix-preserved\n')
            private = archive.extractfile(member('orphan-first.1.result')).read()
            assert private, 'private source result was lost'
            (evidence / ('forced-' + label + '-private-result.txt')).write_bytes(private)
        if label == 'after':
            assert len(stderr) <= 262144
            assert b'[stderr truncated: shared byte limit=262144]' in stderr
            assert archive_path.stat().st_size <= 8388608
            assert len(big) <= 262144
            manifest = (capture / 'truncation.txt').read_bytes()
            assert len(manifest) <= 8192
            assert b'truncation=1\n' in manifest
            print(manifest.decode(), end='')
        else:
            assert len(stderr) > 262144
            assert archive_path.stat().st_size > 8388608
        print(f'{label}: exit={result.returncode} stderr_bytes={len(stderr)} archive_bytes={archive_path.stat().st_size} oversized_member_bytes={len(big)} fixture_cleaned={not fixture_root.exists()}')
    print('PASS: same forced failure preserved; real detached stderr, private results, bounded readable archive, truncation metadata and cleanup verified; scratch copies removed on exit')
