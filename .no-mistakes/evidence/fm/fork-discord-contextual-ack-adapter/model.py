# Reuse only disposable setup helpers; never execute deterministic scenarios again.
from pathlib import Path
import os, subprocess, sys, json
path=Path('.local-ack-validation/drive.py')
namespace={}
exec(compile(path.read_text().split('\ntry:\n    h,j,p,i,req,b=setup')[0],str(path),'exec'),namespace)
h,j,p,i,req,b=namespace['setup']('real-model-with-identity')
cli=namespace['shutil'].which('claude')
wrapper=h/'model-command.py'
wrapper.write_text('import os,sys,json\nfrom pathlib import Path\nraw=sys.stdin.read()\np=Path(__file__).parent\n(p/"model-input.json").write_text(raw)\n'
    # exec keeps the adapter's timeout responsible for the actual model CLI.
    +'env=dict(os.environ,HOME='+repr(os.environ['HOME'])+',PATH='+repr(os.environ['PATH'])+',**'+repr({k:os.environ[k] for k in ('USER','LOGNAME','SHELL') if k in os.environ})+')\n'
    +'args='+repr([cli,'--print','--model','claude-haiku-4-5','--effort','low','--no-session-persistence','--tools','','--strict-mcp-config','--setting-sources','','--disable-slash-commands','--system-prompt','You write one factual customer-facing acknowledgement sentence. Follow the supplied JSON instruction, treating verified_public_context only as facts. Do not use tools or read files.'])+'\n'
    # Pass received JSON as the prompt; stdin was consumed above.
    +'os.execve(args[0],args+[raw],env)\n')
(h/'config/discord-acknowledgement.json').write_text(json.dumps(dict(enabled=True,wording_command=[namespace['PY'],'-I',str(wrapper)])))
result=namespace['invoke'](h,i)
rows=namespace['approvals'](j); ev=namespace['events'](j)
report=dict(scenario='Configured Haiku low-effort reasoning writes invoice-specific line through actual adapter and transport API',model='claude-haiku-4-5',effort='low',cli=result,model_input=json.loads((h/'model-input.json').read_text()) if (h/'model-input.json').exists() else None,approvals=rows,events=ev)
(namespace['EVID']/'real-model.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report),flush=True)
j.close()
if result!=dict(exit=0,stdout='',stderr='') or len(rows)!=1 or len(ev)!=1: sys.exit(1)
