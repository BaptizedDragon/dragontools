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
            props.update(UMask='0077',LogNamespace='',UnitFileState='enabled',AccuracyUSec='1s',RandomizedDelayUSec='0',ActiveState='active',Result='success',ExecMainStartTimestampMonotonic='900000000')
            self.props[name]=props
        self.calls=[]
    def output(self,*args):
        self.calls.append(args)
        if args[0]=='id': return 'dt-host-events'
        if args[0]=='busctl': return json.dumps(dict(type='a(sasbttttuii)',data=[['/opt/dragontools/agent/current/dragontool-agent',['/opt/dragontools/agent/current/dragontool-agent','maintenance','events'],False,0,0,0,0,0,0,0]]))
        if args[0]=='runuser':
            self.assertEqual(args[-2:],('maintenance','events-verify')); return ''
        raise AssertionError(args)
    def managed(self):
        import io
        with patch.object(helper.pwd,'getpwnam',return_value=types.SimpleNamespace(pw_uid=999,pw_gid=999,pw_dir='/var/lib/dragontools/host-events',pw_shell='/usr/sbin/nologin')), patch.object(helper,'output',self.output), patch.object(helper,'node'), patch.object(helper.os.path,'lexists',return_value=True), patch.object(helper,'properties',side_effect=lambda name:self.props[name]), patch('builtins.open',side_effect=lambda name:io.StringIO(SPEC[name.rsplit('.',1)[1]])):
            helper.managed(SPEC)
    def test_exact_units_pass_and_each_invariant_drift_fails(self):
        self.managed(); original=copy.deepcopy(self.props)
        for name,props in original.items():
            keys=('DropInPaths','NeedDaemonReload','FragmentPath','User','NoNewPrivileges','LogNamespace') if name.endswith('.service') else ('Unit','UnitFileState','AccuracyUSec','RandomizedDelayUSec')
            for key in keys:
                self.props=copy.deepcopy(original); self.props[name][key]='wrong'
                with self.subTest(unit=name,property=key),self.assertRaises(AssertionError): self.managed()
    def test_ready_recent_observation_uses_only_read_only_helper(self):
        with patch.object(helper,'output',self.output),patch.object(helper,'properties',side_effect=lambda name:self.props[name]),patch.object(helper.time,'monotonic',return_value=1000):
            self.assertTrue(helper.ready())
            self.assertEqual(len(self.calls),1)
            for unit,key,value in [('timer','ActiveState','inactive'),('service','Result','exit-code'),('service','ExecMainStartTimestampMonotonic','1')]:
                original=self.props['dragontools-host-events.'+unit][key]; self.props['dragontools-host-events.'+unit][key]=value
                self.assertFalse(helper.ready()); self.props['dragontools-host-events.'+unit][key]=original
            self.assertEqual(len(self.calls),1)
    def test_node_refuses_symlinks_hardlinks_and_metadata_drift(self):
        import stat
        valid=dict(st_uid=999,st_gid=999,st_mode=stat.S_IFREG|0o600,st_nlink=1)
        for changes in ({},{'st_uid':0},{'st_gid':0},{'st_mode':stat.S_IFLNK|0o600},{'st_mode':stat.S_IFREG|0o644},{'st_nlink':2}):
            with patch.object(helper.os,'lstat',return_value=types.SimpleNamespace(**dict(valid,**changes))):
                if changes:
                    with self.assertRaises(AssertionError): helper.node('fixture',999,999,0o600)
                else: helper.node('fixture',999,999,0o600)

if __name__=='__main__': unittest.main()
