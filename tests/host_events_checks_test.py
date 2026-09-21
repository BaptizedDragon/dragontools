"""Read-only timer/unit/storage checks; mocked systemd, no host state writes."""
import copy
import importlib.util
import json
from pathlib import Path
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('events',ROOT/'src/monitoring/agents/host_events.py')
helper=importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
SPEC={key:(ROOT/('src/monitoring/agents/host-events.'+key)).read_text() for key in ('service','timer')}

class Checks(unittest.TestCase):
    def setUp(self):
        self.props={}
        for kind in ('service','timer'):
            name='dragontools-host-events.'+kind
            props=dict(line.split('=',1) for line in SPEC[kind].splitlines() if '=' in line)
            props.update(FragmentPath='/etc/systemd/system/'+name,DropInPaths='',NeedDaemonReload='no',LoadState='loaded')
            props.update(UMask='0077',LogNamespace='',UnitFileState='enabled',AccuracyUSec='1s',RandomizedDelayUSec='0',ActiveState='active' if kind=='timer' else 'inactive',SubState='waiting' if kind=='timer' else 'dead',RemainAfterExit='no',Result='success',ExecMainCode='1',ExecMainStatus='0',ExecMainStartTimestampMonotonic='900000000',ExecMainExitTimestampMonotonic='901000000')
            if kind=='service': props['UnitFileState']='static'
            self.props[name]=props
        self.calls=[]
    def output(self,*args):
        self.calls.append(args)
        if args[0]=='id': return 'dt-host-events'
        if args[0]=='busctl': return json.dumps(dict(type='a(sasbttttuii)',data=[['/opt/dragontools/agent/current/dragontool-agent',['/opt/dragontools/agent/current/dragontool-agent','maintenance','events'],False,0,0,0,0,0,0,0]]))
        if args[0]=='runuser':
            self.assertEqual(args[-2:],('maintenance','events-verify')); return ''
        raise AssertionError(args)
    def managed(self, node_error=None):
        import io
        with patch.object(helper.pwd,'getpwnam',return_value=types.SimpleNamespace(pw_uid=999,pw_gid=999,pw_dir='/var/lib/dragontools/host-events',pw_shell='/usr/sbin/nologin')), patch.object(helper,'output',self.output), patch.object(helper,'node',side_effect=node_error), patch.object(helper.os.path,'lexists',return_value=True), patch.object(helper,'properties',side_effect=lambda name:self.props[name]), patch('builtins.open',side_effect=lambda name:io.StringIO(SPEC[name.rsplit('.',1)[1]])):
            helper.managed(SPEC)
    def test_exact_units_pass_and_each_invariant_drift_fails(self):
        self.managed(); original=copy.deepcopy(self.props)
        for name,props in original.items():
            keys=('DropInPaths','NeedDaemonReload','FragmentPath','User','NoNewPrivileges','LogNamespace') if name.endswith('.service') else ('Unit','UnitFileState','AccuracyUSec','RandomizedDelayUSec')
            for key in keys:
                self.props=copy.deepcopy(original); self.props[name][key]='wrong'
                with self.subTest(unit=name,property=key),self.assertRaises(helper.CheckFailure): self.managed()
    def test_inactive_successful_oneshot_and_active_timer_are_healthy(self):
        with patch.object(helper,'properties',side_effect=lambda name:self.props[name]),patch.object(helper.time,'monotonic',return_value=1000),patch.object(helper,'state_safe') as safe:
            self.assertTrue(helper.ready()); safe.assert_called_once()
            self.props['dragontools-host-events.timer']['ActiveState']='inactive'
            self.assertFalse(helper.ready())
            self.assertEqual(safe.call_count,1)
    def test_startup_or_stale_last_run_is_retryable_but_failed_helper_is_not(self):
        name='dragontools-host-events.service'; original=copy.deepcopy(self.props[name])
        with patch.object(helper,'properties',side_effect=lambda name:self.props[name]),patch.object(helper.time,'monotonic',return_value=1000):
            for changes in ({'ExecMainStartTimestampMonotonic':'0'}, {'ExecMainStartTimestampMonotonic':'1'}, {'ActiveState':'activating'}):
                self.props[name]=dict(original,**changes)
                self.assertFalse(helper.last_run())
            for changes in ({'ActiveState':'failed','Result':'exit-code','ExecMainStatus':'86'}, {'ExecMainStatus':'1'}, {'ExecMainCode':'2'}, {'ActiveState':'active','SubState':'exited'}, {'ExecMainExitTimestampMonotonic':'1'}):
                self.props[name]=dict(original,**changes)
                with self.subTest(changes=changes),self.assertRaises(AssertionError): helper.last_run()
    def test_directory_permission_failure_has_semantic_check(self):
        with self.assertRaises(helper.CheckFailure) as failed:
            self.managed(node_error=PermissionError('private diagnostic must not be emitted'))
        self.assertEqual(failed.exception.check,'host_events_state_directory')
        self.assertEqual(failed.exception.code,202)
        self.assertNotIn('private',str(failed.exception))
    def test_entrypoint_emits_only_semantic_exit_code_without_error_text(self):
        import contextlib, io, sys
        stdout, stderr=io.StringIO(),io.StringIO()
        with patch.object(helper.pwd,'getpwnam',side_effect=RuntimeError('PRIVATE-SENTINEL')),patch.object(sys,'argv',['host_events.py','managed',json.dumps(SPEC)]),contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as failed:
                exec(compile((ROOT/'src/monitoring/agents/host_events.py').read_text(),'host_events.py','exec'),{'__name__':'__main__'})
        self.assertEqual(failed.exception.code,200)
        self.assertEqual(stdout.getvalue()+stderr.getvalue(),'')
    def test_state_verification_invokes_only_read_only_mode(self):
        user=types.SimpleNamespace(pw_uid=999,pw_gid=999,pw_dir='/var/lib/dragontools/host-events')
        with patch.object(helper,'account',return_value=user),patch.object(helper,'node'),patch.object(helper.os.path,'lexists',return_value=True),patch.object(helper,'output',self.output):
            helper.state_safe()
        self.assertEqual(self.calls,[('runuser','-u','dt-host-events','--','/opt/dragontools/agent/current/dragontool-agent','maintenance','events-verify')])
    def test_node_refuses_symlinks_hardlinks_and_metadata_drift(self):
        import stat
        valid=dict(st_uid=999,st_gid=999,st_mode=stat.S_IFREG|0o600,st_nlink=1)
        for changes in ({},{'st_uid':0},{'st_gid':0},{'st_mode':stat.S_IFLNK|0o600},{'st_mode':stat.S_IFREG|0o644},{'st_nlink':2}):
            with patch.object(helper.os,'lstat',return_value=types.SimpleNamespace(**dict(valid,**changes))):
                if changes:
                    with self.assertRaises(AssertionError): helper.node('fixture',999,999,0o600)
                else: helper.node('fixture',999,999,0o600)

if __name__=='__main__': unittest.main()
