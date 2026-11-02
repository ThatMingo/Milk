"""Opt-in macOS executable proofs, not a production policy or default-ON rollout."""
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time
import unittest

HERE=Path(__file__).resolve().parent
PROJECT=HERE.parents[1]
SYNTHETIC='phase1-synthetic-not-a-real-key'

def clean_env(home):
    return {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),'TMPDIR':str(home),'LANG':'en_US.UTF-8','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null','GIT_TERMINAL_PROMPT':'0'}

def run(args, **kw):
    return subprocess.run(list(map(str,args)), capture_output=True, text=True, timeout=15, **kw)

def quote(path):
    return json.dumps(str(Path(path).resolve()))

def profile(denied=(), readonly=(), nofork=False):
    # Deliberately allow-default: proves named kernel boundaries, NOT production closure.
    return '(version 1)\n(allow default)\n'+''.join('(deny file-read* file-write* (subpath '+quote(p)+'))\n' for p in denied)+''.join('(deny file-write* (subpath '+quote(p)+'))\n' for p in readonly)+('(deny process-fork)\n' if nofork else '')

class Boundaries(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if platform.system()!='Darwin' or int(platform.mac_ver()[0].split('.')[0])<26:
            raise RuntimeError('Requires actual macOS 26+; no simulated success')
        cls.temporary=tempfile.TemporaryDirectory(prefix='Milk-Seatbelt-Phase1-')
        cls.root=Path(cls.temporary.name).resolve()
        cls.probe=cls.root/'probe'; cls.plugin=cls.root/'worker.dylib'
        for args in [ ['/usr/bin/clang',HERE/'probe.c','-o',cls.probe], ['/usr/bin/clang','-dynamiclib',HERE/'worker_effect.c','-o',cls.plugin] ]:
            result=run(args)
            if result.returncode:raise RuntimeError(result.stderr)
        smoke=run(['/usr/bin/sandbox-exec','-p',profile(),cls.probe,'env'],env=clean_env(cls.root))
        if smoke.returncode:raise RuntimeError('Seatbelt unavailable (including nested tool sandbox): '+smoke.stderr)
    @classmethod
    def tearDownClass(cls): cls.temporary.cleanup()
    def setUp(self):
        self.work=Path(tempfile.mkdtemp(dir=self.root)).resolve()
        self.project=self.work/'project';self.outside=self.work/'outside'
        self.project.mkdir();self.outside.mkdir();(self.outside/'secret').write_text('synthetic')
    def sandbox(self,args,policy=None,env=None):
        return run(['/usr/bin/sandbox-exec','-p',policy or profile([self.outside]),*args],env=env or clean_env(self.work),cwd=self.project)
    def test_seatbelt_files_symlink_and_descendant(self):
        self.assertEqual(self.sandbox([self.probe,'write',self.project/'ok']).returncode,0)
        self.assertNotEqual(self.sandbox([self.probe,'read',self.outside/'secret']).returncode,0)
        self.assertNotEqual(self.sandbox([self.probe,'write',self.outside/'no']).returncode,0)
        (self.project/'alias').symlink_to(self.outside,target_is_directory=True)
        self.assertNotEqual(self.sandbox([self.probe,'write',self.project/'alias/no']).returncode,0)
        self.assertNotEqual(self.sandbox(['/bin/sh','-c','exec "$1" write "$2"','sh',self.probe,self.outside/'child']).returncode,0)
        self.assertFalse((self.outside/'child').exists())
    def test_nested_sandbox_cannot_widen_but_sibling_can(self):
        request=['/usr/bin/sandbox-exec','-p',profile(),self.probe,'write',self.outside/'once']
        self.assertNotEqual(self.sandbox(request).returncode,0)
        sibling=run(request,env=clean_env(self.work))
        self.assertEqual(sibling.returncode,0,sibling.stderr)
        self.assertNotEqual(self.sandbox([self.probe,'write',self.outside/'later']).returncode,0)
    def test_profile_split_and_synthetic_environment(self):
        managed=self.work/'managed';existing=self.work/'existing';inactive=self.work/'inactive'
        for p in (managed,existing,inactive):p.mkdir();(p/'data').write_text('synthetic')
        runtime=profile([managed,inactive])
        self.assertEqual(self.sandbox([self.probe,'write',existing/'runtime'],runtime).returncode,0)
        self.assertNotEqual(self.sandbox([self.probe,'read',inactive/'data'],runtime).returncode,0)
        tools=profile([managed,existing,inactive])
        self.assertNotEqual(self.sandbox([self.probe,'read',existing/'data'],tools).returncode,0)
        managed_tools=profile([existing,inactive])
        self.assertEqual(self.sandbox([self.probe,'write',managed/'tool'],managed_tools).returncode,0)
        env={**clean_env(self.work),'MILK_PI_LOCAL_KEY':SYNTHETIC}
        self.assertEqual(self.sandbox([self.probe,'env'],env=env).stdout.strip(),'present')
        self.assertEqual(self.sandbox(['/bin/sh','-c','exec "$1" env','sh',self.probe],env=clean_env(self.work)).stdout.strip(),'absent')
    def test_native_worker_isolated_host_remains_trusted(self):
        self.assertNotEqual(self.sandbox([self.probe,'plugin',self.plugin,self.outside/'effect']).returncode,0)
        self.assertEqual(self.sandbox([self.probe,'plugin',self.plugin,self.project/'effect']).returncode,0)
        self.assertEqual(run([self.probe,'plugin',self.plugin,self.outside/'host-effect'],env=clean_env(self.work)).returncode,0)
    def test_fork_denial_and_invalid_profile_fail_closed(self):
        result=self.sandbox([self.probe,'fork'],profile(nofork=True))
        self.assertNotEqual(result.returncode,0)
        result=self.sandbox([self.probe,'write',self.project/'must-not-run'],'(not-a-valid-policy)')
        self.assertNotEqual(result.returncode,0);self.assertFalse((self.project/'must-not-run').exists())
    def test_group_lifetime_counterexample(self):
        marker=self.outside/'detached-effect'
        self.assertNotEqual(self.sandbox([self.probe,'write',marker]).returncode,0)
        p=subprocess.Popen(['/usr/bin/sandbox-exec','-p',profile(),str(self.probe),'detach',str(marker)],start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.assertEqual(p.communicate(timeout=5)[0].strip(),b'detached');self.assertEqual(p.returncode,0)
        try:os.killpg(p.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        time.sleep(.8)
        self.assertTrue(marker.exists(),'Detached child retained the operation-only outside grant')
        self.assertNotEqual(self.sandbox([self.probe,'write',self.outside/'runtime-still-denied']).returncode,0)
        # The synthetic detached child exits immediately after the marker; no persistent daemon.
    def git(self,*args):
        result=run(['/usr/bin/git',*args],cwd=self.project,env=clean_env(self.work))
        self.assertEqual(result.returncode,0,result.stderr);return result
    def escalate_git(self,executable,args):
        # Prototype recognizes exact argv requests only, never shell fragments.
        if executable!='/usr/bin/git' or not args or args[0] not in {'add','commit','checkout','merge','reset','status'}:
            raise ValueError('unrecognized escalation')
        return self.git(*args)
    def test_git_escalation_hooks_helpers_and_no_shell_grant(self):
        self.git('init');self.git('config','user.name','Phase1');self.git('config','user.email','phase1@example.invalid')
        hook=self.project/'.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\nprintf hook > .git/hook-proof\n');hook.chmod(0o700)
        (self.project/'file').write_text('fixture')
        restricted=profile(readonly=[self.project/'.git'])
        self.assertNotEqual(self.sandbox([self.probe,'write',self.project/'.git/arbitrary'],restricted).returncode,0)
        self.assertNotEqual(self.sandbox(['/usr/bin/git','add','file'],restricted).returncode,0)
        self.escalate_git('/usr/bin/git',['add','file'])
        self.escalate_git('/usr/bin/git',['commit','-m','fixture'])
        self.assertTrue((self.project/'.git/hook-proof').exists())
        # A real Git editor helper retains compatibility on metadata-writing escalation.
        helper=self.work/'editor-helper';helper.write_text('#!/bin/sh\nprintf helper > "$PWD/.git/helper-proof"\n');helper.chmod(0o700)
        self.git('config','core.editor',str(helper))
        self.escalate_git('/usr/bin/git',['commit','--amend']);self.assertTrue((self.project/'.git/helper-proof').exists())
        for exe,args in [('/bin/sh',['-c','git add file; touch .git/escape']),('/usr/bin/git',['!sh']),('/usr/bin/git',['-c','alias.x=!sh','x'])]:
            with self.assertRaises(ValueError):self.escalate_git(exe,args)
        self.assertNotEqual(self.sandbox([self.probe,'write',self.project/'.git/later'],restricted).returncode,0)
        self.assertFalse((self.project/'.git/escape').exists())

    def test_linked_worktree_resolved_metadata(self):
        self.git('init');self.git('config','user.name','Phase1');self.git('config','user.email','phase1@example.invalid')
        (self.project/'file').write_text('fixture');self.git('add','file');self.git('commit','-m','fixture')
        linked=self.work/'linked';self.git('worktree','add','-b','phase1',str(linked))
        metadata=run(['/usr/bin/git','rev-parse','--absolute-git-dir'],cwd=linked,env=clean_env(self.work))
        self.assertEqual(metadata.returncode,0)
        gitdir=Path(metadata.stdout.strip()).resolve()
        self.assertTrue(str(gitdir).startswith(str(self.project/'.git/worktrees')))
        policy=profile(readonly=[self.project/'.git',linked/'.git'])
        for target in [gitdir/'arbitrary',linked/'.git']:
            self.assertNotEqual(self.sandbox([self.probe,'write',target],policy).returncode,0)
        (linked/'file').write_text('changed')
        self.assertNotEqual(self.sandbox(['/usr/bin/git','-C',linked,'add','file'],policy).returncode,0)
        result=run(['/usr/bin/git','-C',linked,'add','file'],env=clean_env(self.work))
        self.assertEqual(result.returncode,0,result.stderr)

if __name__=='__main__':unittest.main(verbosity=2)
