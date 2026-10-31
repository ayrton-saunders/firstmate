#!/usr/bin/env bash
# Read-only Discord identity verification through the installed executable.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-discord-verify-pins)
fm_git_init_commit "$TMP_ROOT/source"
mkdir -p "$TMP_ROOT/source/bin"
cp "$ROOT/bin/fm-discord-verify-pins.py" "$TMP_ROOT/source/bin/"
for name in fm-inbox.sh fm-send.sh fm-spawn.sh fm-discord-hook.py; do
  printf 'inert fixture for %s\n' "$name" > "$TMP_ROOT/source/bin/$name"
done
python3 -I - "$TMP_ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

root = Path(sys.argv[1]).resolve()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


class Pins(unittest.TestCase):
    def setUp(self):
        self.world = root / 'world'
        shutil.rmtree(self.world, ignore_errors=True)
        self.source = self.world / 'source'
        shutil.copytree(root / 'source', self.source)
        self.home = self.world / 'home'
        self.home.mkdir()
        commit = subprocess.check_output(['git', '-C', str(self.source), 'rev-parse', 'HEAD'], text=True).strip()
        files = {f'bin/{name}': hashlib.sha256((self.source / 'bin' / name).read_bytes()).hexdigest()
                 for name in ('fm-inbox.sh', 'fm-send.sh', 'fm-spawn.sh', 'fm-discord-hook.py')}
        self.identity = dict(source_commit=commit, source_digest=digest(files))
        self.config = dict(schema=2, enabled=True, home=str(self.home), source=str(self.source),
                           **self.identity, journal=str(self.world / 'must-not-open-journal'),
                           package_root=str(self.world / 'must-not-import-package'),
                           python_executable=str(self.world / 'must-not-execute-interpreter'))
        self.manifest = dict(schema=2, enabled=True, parent_identity={**self.identity,
                             'home_identity': hashlib.sha256(str(self.home).encode()).hexdigest()},
                             bot_token_file=str(self.world / 'must-not-read-token'))
        self.config_path = self.world / 'parent.json'
        self.manifest_path = self.world / 'transport.json'
        self.write()

    def write(self):
        self.config_path.write_text(json.dumps(self.config))
        self.manifest_path.write_text(json.dumps(self.manifest))

    def snapshot(self):
        return {str(p.relative_to(self.world)): (p.lstat().st_mode, p.lstat().st_mtime_ns,
                    os.readlink(p) if p.is_symlink() else p.read_bytes() if p.is_file() else None)
                for p in self.world.rglob('*')}

    def invoke(self, reason=None, config_path=None, command=None):
        before = self.snapshot()
        result = subprocess.run([sys.executable, '-I', str(command or self.source / 'bin/fm-discord-verify-pins.py'),
                                 '--parent-config', str(config_path or self.config_path),
                                 '--transport-manifest', str(self.manifest_path)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(self.snapshot(), before, 'verification must not modify any file or create sidecars/bytecode')
        if reason is None:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'Discord source/config/manifest pins agree; journal epoch and fences not checked.\n')
            self.assertEqual(result.stderr, '')
        else:
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, '')
            self.assertIn(reason, result.stderr)
            self.assertNotIn(str(self.world), result.stderr)
        return result

    def test_agreement_without_private_runtime_journal_or_credentials(self):
        self.invoke()

    def test_parent_commit_mismatch(self):
        self.config['source_commit'] = '0' * 40
        self.write()
        self.invoke('parent source commit mismatch')

    def test_parent_digest_mismatch(self):
        self.config['source_digest'] = '0' * 64
        self.write()
        self.invoke('parent source digest mismatch')

    def test_dirty_lifecycle_file(self):
        with (self.source / 'bin/fm-send.sh').open('a') as stream:
            stream.write('unapproved fixture change\n')
        self.invoke('parent source digest mismatch')

    def test_each_transport_identity_pin_mismatch(self):
        for key in ('source_commit', 'source_digest', 'home_identity'):
            with self.subTest(pin=key):
                original = self.manifest['parent_identity'][key]
                self.manifest['parent_identity'][key] = '0' * len(original)
                self.write()
                self.invoke('transport parent_identity ' + key + ' mismatch')
                self.manifest['parent_identity'][key] = original

    def test_malformed_transport_identity(self):
        for identity in (None, [], {}, {**self.manifest['parent_identity'], 'unexpected': 'private'}):
            self.manifest['parent_identity'] = identity
            self.write()
            self.invoke('transport parent_identity absent or malformed')

    def test_malformed_json(self):
        for text in ('[]', '{', '{"schema":2,"schema":2}', '{"private":"sensitive-fixture-value"'):
            self.config_path.write_text(text)
            result = self.invoke('Discord pin verification refused')
            self.assertNotIn('sensitive-fixture-value', result.stderr)

    def test_invalid_enablement_or_schema(self):
        for target in (self.config, self.manifest):
            for key, value in (('enabled', False), ('enabled', 'true'), ('schema', 1), ('schema', '2')):
                original = target[key]
                target[key] = value
                self.write()
                self.invoke('enabled schema 2')
                target[key] = original

    def test_invalid_parent_pins(self):
        for key, value in (('source_commit', None), ('source_commit', 'xyz'), ('source_digest', 'A' * 64)):
            original = self.config[key]
            self.config[key] = value
            self.write()
            self.invoke('parent source pins absent or malformed')
            self.config[key] = original

    def test_symlink_config(self):
        link = self.world / 'linked.json'
        link.symlink_to(self.config_path)
        self.invoke('explicit absolute regular JSON files required', config_path=link)

    def test_relative_and_missing_config(self):
        self.invoke('explicit absolute regular JSON files required', config_path=Path('relative.json'))
        self.invoke('explicit absolute regular JSON files required', config_path=self.world / 'missing.json')

    def test_oversized_config(self):
        self.config_path.write_text(' ' * 65537)
        self.invoke('configuration size limit')

    def test_noncanonical_home(self):
        self.config['home'] = str(self.home) + '/.'
        self.write()
        self.invoke('canonical absolute source and home paths required')

    def test_wrong_invoked_source(self):
        other = self.world / 'other/bin'
        other.mkdir(parents=True)
        command = other / 'fm-discord-verify-pins.py'
        shutil.copyfile(self.source / 'bin/fm-discord-verify-pins.py', command)
        self.invoke('invoked command is not from the configured parent source', command=command)

    def test_missing_and_symlinked_lifecycle_files(self):
        path = self.source / 'bin/fm-send.sh'
        saved = self.world / 'saved'
        path.rename(saved)
        self.invoke('parent source lifecycle file absent or symlinked')
        path.symlink_to(saved)
        self.invoke('parent source lifecycle file absent or symlinked')

    def test_git_unavailable(self):
        shutil.rmtree(self.source / '.git')
        self.invoke('parent source Git commit unavailable')


unittest.main(argv=['discord-pin-verification'], verbosity=2)
PY
pass 'Discord pin verifier: identity agreement and refusals leave local fixtures unchanged'
