import collections, json, os, pathlib, subprocess

def run(args, env=None):
    return subprocess.run(args, env={**os.environ, **(env or {})}, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def roots(args):
    p = run(['bin/fm-lint.sh', *args, '--list-files'], {'CI':'true'})
    assert p.returncode == 0, p.stderr
    return p.stdout.splitlines()

# Oracle: the documented canonical inventory is every nonhidden .sh file at
# the top level of bin/, bin/backends/, and tests/, independently enumerated.
expected = sorted(str(p) for d in ['bin','bin/backends','tests'] for p in pathlib.Path(d).iterdir() if p.is_file() and p.suffix == '.sh' and not p.name.startswith('.'))
canonical = roots([])
assert sorted(canonical) == expected
print(f'Canonical CLI inventory matches independent filesystem inventory: {len(expected)} roots')
for total in [2,4]:
    union = []
    for index in range(1,total+1):
        selector = f'{index}of{total}'
        selected = roots(['--partition',selector])
        assert selected and selected == roots(['--partition',selector])
        union.extend(selected)
        print(f'CLI --partition {selector} --list-files: {len(selected)} roots, repeatable')
    assert collections.Counter(union) == collections.Counter(expected)
    print(f'{total}-way CLI partition union: every canonical root exactly once')
for args in [['--partition',x] for x in ['0of2','3of2','1of3','0of4','5of4','1of0','01of4','1of04','']]+[['--partition'],['--partition','1of4','--fast'],['--partition','1of4','bin/fm-lint.sh']]:
    p = run(['bin/fm-lint.sh',*args,'--list-files'])
    assert p.returncode == 2, (args,p.returncode,p.stdout,p.stderr)
    print(f'Refused {args!r}: exit=2; {p.stderr.strip()}')

# Parse the actual declarative workflow and execute its shipped verdict shell,
# not a reimplementation. Inputs are synthetic GitHub matrix result strings;
# the independent contract requires success only when every partition passed.
p = run(['ruby','-rjson','-ryaml','-e','puts JSON.generate(YAML.load_file(ARGV[0]))','.github/workflows/ci.yml'])
assert p.returncode == 0, p.stderr
workflow = json.loads(p.stdout)
job = workflow['jobs']['lint']
assert job['needs'] == ['lint-partitions']
assert job['strategy']['matrix']['partition'] == [1,2]
assert workflow['jobs']['lint-partitions']['strategy']['matrix']['partition'] == [1,2,3,4]
step = job['steps'][0]['run']
for context in job['strategy']['matrix']['partition']:
    for result in ['success','failure','cancelled','skipped','']:
        p = run(['/bin/bash','-c',step], {'FM_LINT_RESULT':result})
        assert (p.returncode == 0) == (result == 'success'), (context,result,p.returncode)
        print(f'Local execution of shipped Lint {context} verdict with synthetic matrix result {result!r}: exit={p.returncode}; {p.stdout.strip()}')
print('Local CI executable surfaces validated. No GitHub runner acquisition or remote scheduling exercised.')
