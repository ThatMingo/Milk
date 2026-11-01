"""Real pinned Pi RPC + fake model, sibling worker prototype. Synthetic data only."""
import concurrent.futures
import http.server
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from test_boundaries import HERE, PROJECT, SYNTHETIC, clean_env, profile, run

class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        r=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        last=r['messages'][-1]
        if last['role']=='user':
            raw=last['content'];raw=raw if isinstance(raw,str) else ''.join(c.get('text','') for c in raw)
            tool,args=json.loads(raw)
            delta={'role':'assistant','tool_calls':[{'index':0,'id':'phase1-call','type':'function','function':{'name':tool,'arguments':json.dumps(args)}}]}
            finish='tool_calls'
        else:delta={'role':'assistant','content':'phase1-complete'};finish='stop'
        value={'id':'phase1','object':'chat.completion.chunk','created':1,'model':'fixture','choices':[{'index':0,'delta':delta,'finish_reason':finish}]}
        data=('data: '+json.dumps(value)+'\n\ndata: [DONE]\n\n').encode()
        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)

class Pi:
    def __init__(self,root,port,strict=False,mcp=False):
        self.root=root;self.project=root/'project';self.storage=root/'existing';self.outside=root/'outside'
        for p in (self.project,self.storage,self.outside):p.mkdir()
        (self.project/'input.txt').write_text('input-synthetic')
        (self.storage/'data').write_text('profile-synthetic')
        (self.outside/'data').write_text('outside-synthetic')
        self.marker=root/'mcp-marker'
        (self.storage/'models.json').write_text(json.dumps({'providers':{'phase1':{'api':'openai-completions','baseUrl':f'http://127.0.0.1:{port}/v1','apiKey':'synthetic-availability','models':[{'id':'fixture','contextWindow':32768,'maxTokens':1024}]}}}))
        env={**clean_env(root),'PI_CODING_AGENT_DIR':str(self.storage),'PI_OFFLINE':'1','MILK_PI_LOCAL_KEY':SYNTHETIC,'PHASE1_PROFILE_FILE':str(self.storage/'data')}
        if mcp:env.update(PHASE1_MCP_SCRIPT=str(HERE/'mcp_probe.py'),PHASE1_MCP_MARKER=str(self.marker))
        args=[str(PROJECT/'Runtime/PiRuntime/pi'),'--mode','rpc','--offline','--no-session','--no-extensions','--no-skills','--no-prompt-templates','-e',str(HERE/'pi_bridge.ts')]
        if not mcp:args+=['--no-mcp']
        else:args+=['-e','builtin:mcp']
        args=['/usr/bin/sandbox-exec','-p',profile([self.outside],nofork=strict),*args]
        self.p=subprocess.Popen(args,cwd=self.project,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        self.q=queue.Queue();self.events=[];self.workers={};self.pending={};self.cancelled=set();self.serial=0;self.once_read=None;self.grant_owner=None;self.grant_path=None
        self.pool=concurrent.futures.ThreadPoolExecutor(max_workers=4);self.lock=threading.Lock()
        threading.Thread(target=self.read,daemon=True).start()
        self.wait(lambda e:e.get('statusKey')=='phase1-ready')
        self.rpc('set_model',provider='phase1',modelId='fixture')
    def read(self):
        for line in self.p.stdout:
            try:self.q.put(json.loads(line))
            except ValueError:pass
    def send(self,value):self.p.stdin.write((json.dumps(value)+'\n').encode());self.p.stdin.flush()
    def execute(self,r):
        operation=r['operation']
        # Exact test dispatcher. Requests from Pi are untrusted; unknown op denied.
        if r['op'] not in {'read','access','write','mkdir','bash','ls','find','grep'}:return {'error':'unsupported'}
        # Test host approves one exact typed read, never command execution.
        with self.lock:
            if r['op'] in {'read','access'} and r['args'].get('path')==self.once_read and r.get('invocation'):
                self.grant_owner=r['invocation'];self.grant_path=self.once_read;self.once_read=None
            approved=(r['op'] in {'read','access'} and r.get('invocation')==self.grant_owner and self.grant_owner is not None and r['args'].get('path')==self.grant_path)
        denied=[self.storage] if approved else [self.outside,self.storage]
        args=['/usr/bin/sandbox-exec','-p',profile(denied,nofork=approved),'/usr/bin/python3',str(HERE/'operation.py')]
        p=subprocess.Popen(args,cwd=self.project,env=clean_env(self.root),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        with self.lock:
            self.workers[operation]=p
            if operation in self.cancelled:
                try:os.killpg(p.pid,signal.SIGKILL)
                except ProcessLookupError:pass
        try:
            out,_=p.communicate(json.dumps(r).encode(),timeout=12)
            return json.loads(out) if out else {'error':'cancelled'}
        except (ValueError,subprocess.TimeoutExpired):
            try:os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            p.communicate();return {'error':'worker failed closed'}
        finally:
            with self.lock:self.workers.pop(operation,None)
    def pump(self):
        for key,future in list(self.pending.items()):
            if future.done():
                self.send({'type':'extension_ui_response','id':key,'value':json.dumps(future.result())});del self.pending[key]
        try:e=self.q.get(timeout=.025)
        except queue.Empty:return None
        self.events.append(e)
        if e.get('type')=='tool_execution_end' and e.get('toolCallId')==self.grant_owner:
            self.grant_owner=None;self.grant_path=None
        if e.get('type')=='extension_ui_request' and e.get('method')=='input':
            r=json.loads(e['title'])
            if r.get('phase1')!=1:raise AssertionError('invalid request')
            self.pending[e['id']]=self.pool.submit(self.execute,r)
        if e.get('statusKey')=='phase1-cancel':
            operation=e['statusText'];self.cancelled.add(operation)
            with self.lock:
                p=self.workers.get(operation)
                if p:
                    try:os.killpg(p.pid,signal.SIGKILL)
                    except ProcessLookupError:pass
        return e
    def wait(self,predicate,timeout=12):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            e=self.pump()
            if e is not None and predicate(e):return e
            if self.p.poll() is not None:raise AssertionError('Pi exited: '+self.p.stderr.read().decode()[-1200:])
        raise AssertionError('RPC deadline; recent records: '+json.dumps(self.events[-6:]))
    def rpc(self,kind,**args):
        self.serial+=1;key='request-'+str(self.serial);self.send({'id':key,'type':kind,**args})
        r=self.wait(lambda e:e.get('id')==key and e.get('type')=='response')
        if not r.get('success'):raise AssertionError(r)
        return r
    def tool(self,name,args):
        start=len(self.events);self.rpc('prompt',message=json.dumps([name,args]));self.wait(lambda e:e.get('type')=='agent_end')
        return self.events[start:]
    def close(self):
        with self.lock:
            for p in self.workers.values():
                try:os.killpg(p.pid,signal.SIGKILL)
                except ProcessLookupError:pass
        self.p.terminate()
        try:self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:os.killpg(self.p.pid,signal.SIGKILL);self.p.wait()
        self.pool.shutdown(wait=True)
        self.p.stdin.close();self.p.stdout.close();self.p.stderr.close()

class PiBoundaries(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (PROJECT/'Runtime/PiRuntime/pi').exists():raise RuntimeError('Pinned Pi fixture required; do not claim simulated success')
        with tempfile.TemporaryDirectory(prefix='Milk-Pi-Version-') as version_home:
            version=run([PROJECT/'Runtime/PiRuntime/pi','--version'],env=clean_env(version_home))
        if version.returncode or version.stdout.strip()!='1.4.0':raise RuntimeError('Expected actual pinned Pi 1.4.0')
        cls.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Model)
        threading.Thread(target=cls.server.serve_forever,daemon=True).start()
    @classmethod
    def tearDownClass(cls):cls.server.shutdown();cls.server.server_close()
    def start(self,**kw):
        temp=tempfile.TemporaryDirectory(prefix='Milk-Pi-Phase1-');self.addCleanup(temp.cleanup)
        p=Pi.__new__(Pi);self.addCleanup(lambda:p.close() if hasattr(p,'p') else None)
        p.__init__(Path(temp.name).resolve(),self.server.server_port,**kw);return p
    def test_builtins_nested_results_profile_denial_unknown_fail_closed(self):
        p=self.start()
        for name,args in [('read',{'path':'input.txt'}),('write',{'path':'new.txt','content':'old'}),('edit',{'path':'new.txt','oldText':'old','newText':'edited'}),('bash',{'command':'printf routed'}),('ls',{'path':str(p.project)}),('find',{'path':str(p.project),'pattern':'*.txt'}),('grep',{'path':str(p.project),'pattern':'synthetic'}),('phase1_nested',{})]:
            with self.subTest(tool=name):
                events=p.tool(name,args)
                ends=[e for e in events if e.get('type')=='tool_execution_end']
                self.assertTrue(ends,'No actual Pi execution result')
                self.assertFalse(any(e.get('isError') for e in ends),json.dumps(ends))
        self.assertEqual((p.project/'new.txt').read_text(),'edited')
        events=p.tool('read',{'path':str(p.storage/'data')})
        self.assertTrue(any(e.get('isError') for e in events if e.get('type')=='tool_execution_end'))
        events=p.tool('unsafe_custom',{})
        self.assertIn('unsupported execution path',json.dumps(events))
        self.assertNotIn('profile-synthetic',json.dumps(events))
        self.assertTrue(any(e.get('parentToolCallId') for e in p.events),'Nested tool path not observed')
    def test_fixed_runtime_and_one_typed_sibling_grant(self):
        p=self.start();pid=p.p.pid
        target=str(p.outside/'data')
        p.once_read=target
        events=p.tool('read',{'path':target})
        self.assertTrue(any('outside-synthetic' in json.dumps(e.get('result',{})) for e in events if e.get('type')=='tool_execution_end'),'Typed sibling grant failed')
        self.assertIsNone(p.once_read)
        events=p.tool('read',{'path':target})
        self.assertTrue(any(e.get('isError') for e in events if e.get('type')=='tool_execution_end'))
        self.assertEqual(p.p.pid,pid);self.assertIsNone(p.p.poll())

    def test_model_tool_abort_cancels_worker(self):
        p=self.start()
        p.rpc('prompt',message=json.dumps(['bash',{'command':'sleep 4; printf escaped > model-late.txt'}]))
        end=time.monotonic()+5
        while not p.workers and time.monotonic()<end:p.pump()
        self.assertTrue(p.workers)
        p.rpc('abort')
        self.assertTrue(any(e.get('type')=='agent_end' for e in p.events))
        self.assertTrue(p.cancelled)
        self.assertFalse((p.project/'model-late.txt').exists())

    def test_python_node_npm_descendants_do_not_inherit_key(self):
        p=self.start()
        if not Path('/opt/homebrew/bin/node').exists() or not Path('/opt/homebrew/bin/npm').exists():
            raise RuntimeError('This host proof requires the explicitly selected /opt/homebrew/bin Node/npm')
        (p.project/'package.json').write_text(json.dumps({'name':'phase1-synthetic','version':'1.0.0','scripts':{'check':'node -e \"if(process.env.MILK_PI_LOCAL_KEY)process.exit(7);console.log(\'clean-node\')\"'}}))
        config=p.root/'empty-npmrc';config.write_text('')
        globalconfig=p.root/'global-npmrc';globalconfig.write_text('')
        commands=[
            "/usr/bin/python3 -c 'import os; assert not os.environ.get(\"MILK_PI_LOCAL_KEY\"); print(\"clean-python\")'",
            f'PATH=/opt/homebrew/bin:/usr/bin:/bin /opt/homebrew/bin/npm --offline --userconfig="{config}" --globalconfig="{globalconfig}" --cache="{p.root}/npm-cache" run check',
        ]
        for command in commands:
            result=p.rpc('bash',command=command)
            self.assertEqual(result['data']['exitCode'],0,result['data']['output'])
            self.assertIn('clean-',result['data']['output'])

    def test_user_bash_and_cancellation(self):
        p=self.start()
        result=p.rpc('bash',command='test -z "$MILK_PI_LOCAL_KEY" && printf clean')
        self.assertEqual(result['data']['output'],'clean')
        p.send({'id':'slow','type':'bash','command':'sleep 4; printf escaped > late.txt'})
        end=time.monotonic()+5
        while not p.workers and time.monotonic()<end:p.pump()
        self.assertTrue(p.workers,'No sibling worker began')
        p.rpc('abort_bash');p.wait(lambda e:e.get('id')=='slow' and e.get('type')=='response')
        self.assertTrue(p.cancelled,'AbortSignal did not reach bridge')
        self.assertFalse((p.project/'late.txt').exists())
    def test_historical_no_fork_primitive_not_current_runtime_design(self):
        p=self.start(strict=True)
        p.rpc('prompt',message='/phase1-spawn-probe')
        result=json.loads(next(e for e in p.events if e.get('statusKey')=='phase1-spawn')['statusText'])
        self.assertTrue(result['runtimeHasKey']);self.assertTrue(result['profileReadable'])
        self.assertTrue(result['execBlocked']);self.assertTrue(result['customBlocked'])
        self.assertFalse(result['execInherited']);self.assertFalse(result['customInherited'])
    def test_approved_pi_runtime_domain_spawn_inherits_synthetic_key(self):
        p=self.start(strict=False)
        p.rpc('prompt',message='/phase1-spawn-probe')
        result=json.loads(next(e for e in p.events if e.get('statusKey')=='phase1-spawn')['statusText'])
        self.assertTrue(result['execInherited']);self.assertTrue(result['customInherited'])
    def test_historical_no_fork_denies_mcp_not_current_design(self):
        p=self.start(strict=True,mcp=True)
        end=time.monotonic()+1
        while time.monotonic()<end:p.pump()
        self.assertFalse(p.marker.exists(),'MCP spawned despite runtime fork denial')
    def test_approved_stdio_mcp_inherits_and_executes(self):
        p=self.start(strict=False,mcp=True)
        end=time.monotonic()+5
        while not p.marker.exists() and time.monotonic()<end:p.pump()
        self.assertTrue(p.marker.exists(),'MCP path was not exercised')
        self.assertTrue(json.loads(p.marker.read_text())['inherited'])
        events=p.tool('mcp__phase1__probe',{})
        ends=[e for e in events if e.get('type')=='tool_execution_end']
        self.assertTrue(ends)
        self.assertFalse(any(e.get('isError') for e in ends),json.dumps(ends))
        self.assertIn('synthetic-mcp',json.dumps(ends))

if __name__=='__main__':unittest.main(verbosity=2)
