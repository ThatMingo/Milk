"""Owned cleanup and the explicitly accepted inherited-grant survivor limitation."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time
import unittest
from test_boundaries import HERE, clean_env, profile, run

class Lifetime(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='Milk-Lifetime-')
        cls.root=Path(cls.temp.name).resolve();cls.probe=cls.root/'lifetime-probe'
        r=run(['/usr/bin/clang',HERE/'lifetime_probe.c','-o',cls.probe])
        if r.returncode:raise RuntimeError(r.stderr)
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()
    def setUp(self):self.work=Path(tempfile.mkdtemp(dir=self.root)).resolve()
    def operation_profile(self):
        self.denied=self.work/"denied";self.denied.mkdir(exist_ok=True)
        return profile([self.denied])
    def await_file(self,path,timeout=4):
        # Fixture readiness only, not process discovery/polling as a containment mechanism.
        end=time.monotonic()+timeout
        while time.monotonic()<end and not path.exists():time.sleep(.01)
        self.assertTrue(path.exists(),'Fixture did not reach its detached stage')
    def start_probe(self,mode):
        marker=self.work/(mode+'-effect');ready=self.work/(mode+'-ready')
        args=['/usr/bin/sandbox-exec','-p',self.operation_profile(),str(self.probe),'spawn',mode,str(marker),str(ready),str(self.denied/'forbidden')]
        p=subprocess.Popen(args,env=clean_env(self.work),start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.addCleanup(self.stop,p)
        self.assertTrue(select.select([p.stdout],[],[],3)[0],'No fixture acknowledgement')
        line=p.stdout.readline()
        self.assertEqual(line,b'ready\n',p.stderr.read().decode() if p.poll() is not None else repr(line))
        self.await_file(ready);return p,marker
    def stop(self,p):
        if p.poll() is None:
            try:os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            p.wait(timeout=3)
        p.stdout.close();p.stderr.close()
    def cleanup_group(self,p):
        # Never reap/reuse the owned leader identity before the final group signal.
        for sig in [signal.SIGTERM,signal.SIGKILL]:
            try:os.killpg(p.pid,sig)
            except ProcessLookupError:pass
            except PermissionError:
                # Darwin killpg filters zombies and can return EPERM when no
                # live signalable member remains. Confirm the owned leader has
                # exited WITHOUT reaping/releasing its identity. This fixture
                # has no UID changes; delayed-effect assertions check its work.
                # Do not turn generic EPERM into a production cleanup success.
                status=os.waitid(os.P_PID,p.pid,os.WEXITED|os.WNOHANG|os.WNOWAIT)
                if sig!=signal.SIGKILL or status is None:raise
            if sig==signal.SIGTERM:time.sleep(.05)
        p.wait(timeout=3)
    def test_ordinary_and_term_resistant_children_cleaned_without_unrelated_kill(self):
        unrelated=subprocess.Popen(['/bin/sleep','5'],start_new_session=True)
        try:
            for mode in ['background','resistant']:
                with self.subTest(mode=mode):
                    p,marker=self.start_probe(mode);self.cleanup_group(p)
                    time.sleep(.8)
                    self.assertFalse(marker.exists())
                    self.assertEqual(p.returncode,-(signal.SIGKILL if mode=='resistant' else signal.SIGTERM))
                    self.assertIsNone(unrelated.poll(),'Cleanup touched an unrelated process')
        finally:
            unrelated.terminate();unrelated.wait(timeout=3)
    def test_detached_survivors_keep_sandbox_but_grant_is_not_reused(self):
        for mode in ['setsid','pgroup','double']:
            with self.subTest(mode=mode):
                p,marker=self.start_probe(mode);self.cleanup_group(p)
                self.assertFalse(marker.exists(),'Delayed effect must follow cleanup')
                # A later operation gets a fresh baseline profile, even while
                # the old grant-holder is still waiting to use the same path.
                later=run(['/usr/bin/sandbox-exec','-p',profile([self.denied,marker]),'/bin/sh','-c',': > "$1"','sh',marker],env=clean_env(self.work))
                self.assertNotEqual(later.returncode,0,later.stderr)
                self.assertFalse(marker.exists(),'Later operation reused expired authority')
                time.sleep(.8)
                self.assertTrue(marker.exists(),'Accepted survivor can still use its operation permissions')
                self.assertFalse((self.denied/'forbidden').exists(),'Survivor escaped inherited Seatbelt denial')
    def test_python_node_npm_and_nested_shell_detach(self):
        payload=self.work/'node-child.js'
        payload.write_text("const fs=require('fs');fs.writeFileSync(process.argv[2], 'ready');setTimeout(()=>fs.writeFileSync(process.argv[3], 'survived'),600);")
        launcher=self.work/'node-launcher.js'
        launcher.write_text("const cp=require('child_process');const child=cp.spawn('/opt/homebrew/bin/node',[process.argv[2],process.argv[3],process.argv[4]],{detached:true,stdio:'ignore'});child.unref();setInterval(()=>{},10000);")
        py=self.work/'double.py'
        py.write_text("import os,sys,time,pathlib\npid=os.fork()\nif pid==0:\n os.setsid()\n if os.fork():os._exit(0)\n for fd in range(256):\n  try:os.close(fd)\n  except OSError:pass\n pathlib.Path(sys.argv[1]).write_text('ready')\n time.sleep(.6)\n pathlib.Path(sys.argv[2]).write_text('survived')\n os._exit(0)\nwhile True:time.sleep(1)\n")
        (self.work/'user.npmrc').write_text('');(self.work/'global.npmrc').write_text('')
        (self.work/'package.json').write_text(json.dumps({'name':'phase1-lifetime','version':'1.0.0','scripts':{'detach':'node node-launcher.js node-child.js npm-ready npm-effect'}}))
        cases=[
            ('python',['/usr/bin/python3',str(py),str(self.work/'python-ready'),str(self.work/'python-effect')]),
            ('node',['/opt/homebrew/bin/node',str(launcher),str(payload),str(self.work/'node-ready'),str(self.work/'node-effect')]),
            ('nested',['/bin/sh','-c','/bin/sh -c \'"$1" spawn double "$2" "$3"\' sh "$1" "$2" "$3"','sh',str(self.probe),str(self.work/'nested-effect'),str(self.work/'nested-ready')]),
            ('npm',['/opt/homebrew/bin/node','/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js','--offline','--userconfig='+str(self.work/'user.npmrc'),'--globalconfig='+str(self.work/'global.npmrc'),'--cache='+str(self.work/'npm-cache'),'run','detach']),
        ]
        for name,args in cases:
            with self.subTest(command=name):
                env={**clean_env(self.work),'PATH':'/opt/homebrew/bin:/usr/bin:/bin'}
                p=subprocess.Popen(['/usr/bin/sandbox-exec','-p',self.operation_profile(),*args],cwd=self.work,env=env,start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                self.addCleanup(self.stop,p)
                self.await_file(self.work/(name+'-ready'))
                self.cleanup_group(p)
                self.assertFalse((self.work/(name+'-effect')).exists(),'Effect must follow cleanup')
                time.sleep(.8)
                self.assertTrue((self.work/(name+'-effect')).exists())

    def test_ordinary_shell_python_node_npm_background_children_cleaned(self):
        py=self.work/'ordinary.py'
        py.write_text("import pathlib,sys,time;pathlib.Path(sys.argv[1]).write_text('ready');time.sleep(.6);pathlib.Path(sys.argv[2]).write_text('effect')")
        js=self.work/'ordinary.js'
        js.write_text("const fs=require('fs');fs.writeFileSync(process.argv[2],'ready');setTimeout(()=>fs.writeFileSync(process.argv[3],'effect'),600)")
        (self.work/'user.npmrc').write_text('');(self.work/'global.npmrc').write_text('')
        (self.work/'package.json').write_text(json.dumps({'name':'phase1-cleanup','version':'1.0.0','scripts':{'ordinary':'node ordinary.js npm-ready npm-effect'}}))
        cases=[
            ('shell',['/bin/sh','-c','/bin/sh -c \'"$1" spawn background "$2" "$3"\' sh "$1" "$2" "$3"','sh',str(self.probe),str(self.work/'shell-effect'),str(self.work/'shell-ready')]),
            ('python',['/usr/bin/python3',str(py),str(self.work/'python-ready'),str(self.work/'python-effect')]),
            ('node',['/opt/homebrew/bin/node',str(js),str(self.work/'node-ready'),str(self.work/'node-effect')]),
            ('npm',['/opt/homebrew/bin/node','/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js','--offline','--userconfig='+str(self.work/'user.npmrc'),'--globalconfig='+str(self.work/'global.npmrc'),'--cache='+str(self.work/'npm-cache'),'run','ordinary']),
        ]
        for name,command in cases:
            with self.subTest(command=name):
                # Shell wrapper intentionally leaves a background child in the owned group.
                env={**clean_env(self.work),'PATH':'/opt/homebrew/bin:/usr/bin:/bin'}
                args=['/usr/bin/sandbox-exec','-p',self.operation_profile(),'/bin/sh','-c','"$@" & wait','sh',*command]
                p=subprocess.Popen(args,cwd=self.work,env=env,start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                self.addCleanup(self.stop,p);self.await_file(self.work/(name+'-ready'))
                self.cleanup_group(p);time.sleep(.8)
                self.assertFalse((self.work/(name+'-effect')).exists())

    def test_swift_and_xcodebuild_work_under_seatbelt(self):
        env={**clean_env(self.work),'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer','CLANG_MODULE_CACHE_PATH':str(self.work/'clang-cache')}
        source=self.work/'hello.swift';source.write_text('print("synthetic-swift")')
        for command in [['/usr/bin/xcodebuild','-version'],['/usr/bin/xcrun','swiftc',str(source),'-o',str(self.work/'hello')]]:
            r=run(['/usr/bin/sandbox-exec','-p',self.operation_profile(),*command],env=env)
            self.assertEqual(r.returncode,0,r.stderr)
        r=run([self.work/'hello'],env=env);self.assertEqual(r.stdout.strip(),'synthetic-swift')

if __name__=='__main__':unittest.main(verbosity=2)
