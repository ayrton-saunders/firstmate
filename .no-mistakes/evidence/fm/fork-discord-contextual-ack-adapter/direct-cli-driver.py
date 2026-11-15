import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
home = root / '.ack-validation/home'
subprocess.run(['bash', 'bin/fm-lab-home.sh', 'create', str(home)], check=True, capture_output=True)
env = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') or k in ('HOME',))}
env.update(FM_HOME=str(home), HOME=str(home), PYTHONDONTWRITEBYTECODE='1')
ack = [sys.executable, '-I', str(root/'bin/fm-discord-acknowledge.py')]
config = home/'config'
switch = config/'discord-acknowledgement.json'
parent = config/'discord-integration.json'
marker = home/'wording-called'
wording = home/'deterministic-wording.py'
wording.write_text('from pathlib import Path\n' + f'Path({str(marker)!r}).touch()\n' + 'print("I am checking the invoice totals.")\n')

def snapshot():
    return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(home.rglob('*')) if p.is_file()}

def invoke(name, delay='well-over-30s', context='Checking invoice totals against receipts.',
           expected=0, error='', environment=None):
    before = snapshot()
    command = ack + ['captured-request', 'domain', delay, context]
    result = subprocess.run(command, capture_output=True, text=True, timeout=8,
                            env=environment or env)
    after = snapshot()
    entry = {'scenario': name, 'command': command, 'exit': result.returncode,
             'stdout': result.stdout, 'stderr': result.stderr,
             'home_files_unchanged': before == after,
             'wording_called': marker.exists(), 'files': sorted(after)}
    print(json.dumps(entry, ensure_ascii=True), flush=True)
    assert result.returncode == expected, entry
    assert result.stdout == '', entry
    assert (error in result.stderr if error else result.stderr == ''), entry
    assert before == after and not marker.exists(), entry

settings = {'enabled': True, 'wording_command': [sys.executable, '-I', str(wording)]}
switch.write_text(json.dumps(settings))
parent.write_text('INTENTIONALLY INVALID: an imminent answer must not open this')
invoke('Imminent answer ignores enabled wording and broken parent configuration', delay='imminent')
switch.unlink()
invoke('Absent switch skips slow-request acknowledgement before broken parent configuration')
settings['enabled'] = False
switch.write_text(json.dumps(settings))
invoke('Explicitly disabled switch skips slow-request acknowledgement')
settings['enabled'] = True
switch.write_text(json.dumps(settings))
# A gate caller must be refused before the deliberately invalid parent configuration.
unmarked = root/'.ack-validation/unmarked'
unmarked.mkdir()
gate_env = {**env, 'FM_HOME': str(unmarked), 'NO_MISTAKES_GATE': 'test'}
invoke('Unauthorized home refuses before parent configuration or wording', expected=1,
       error='parent lifecycle authority required', environment=gate_env)
for label, text in [('C1 control', 'Checking\x85totals'), ('bidi override', 'Checking\u202etotals'),
                    ('invisible-only text', '\u200b \u200b'), ('multiline', 'Checking\ntotals'),
                    ('oversize UTF-8', '\u00e9'*201)]:
    invoke('Unsafe verified public context refuses before wording: ' + label,
           context=text, expected=1, error='one nonempty line within 400 UTF-8 bytes')
invoke('Ambiguous delay judgement refuses rather than authorizing a line', delay='maybe',
       expected=1, error='explicit parent delay judgement required')
print('All direct CLI calls exited; no wording command, journal, transport, model or Discord call was made.', flush=True)
