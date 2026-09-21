"""Execute the rendered activation shell against a persistent fake systemd.

No production paths or services are changed. Native procfs is covered separately.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('DRAGONTOOLS_PKI_FIXTURE', ROOT/'zig-out/bin/dragontool-pki-fixture'))
spec = importlib.util.spec_from_file_location('host_events', ROOT/'src/monitoring/agents/host_events.py')
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
SYSTEMCTL = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
path = Path(os.environ['HOST_EVENTS_SYSTEMD_STATE'])
s = json.loads(path.read_text())
a = sys.argv[1:]; verb=a[0]; unit=a[-1]; code=0
if verb == 'show':
    print('yes' if a[2]=='NeedDaemonReload' and s['reload'] else '')
elif verb == 'daemon-reload':
    s['reload']=False; s['calls'].append('reload')
elif verb in ('is-active','is-enabled'):
    code=0 if s['active' if verb=='is-active' else 'enabled'] else 1
elif verb in ('start','restart','enable'):
    s['calls'].append(verb+' '+unit)
    if unit.endswith('.service'):
        assert verb=='start', 'oneshot must never be enabled or restarted'
        s['result']='exit-code' if s['fail']=='helper' else 'success'
        s['status']='86' if s['fail']=='helper' else '0'
        s['service_active']='failed' if s['fail']=='helper' else 'inactive'
        s['stamp']=int(time.monotonic()*1000000)
        code=1 if s['fail']=='helper' else 0
    elif verb=='enable':
        code=1 if s['fail']=='enable' else 0
        if not code: s['enabled']=True
    else:
        code=1 if s['fail']=='timer' else 0
        if not code: s['active']=True
else:
    raise AssertionError(a)
path.write_text(json.dumps(s))
sys.exit(code)
'''


class Activation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rendered=json.loads(subprocess.check_output([str(BINARY),'host-events-scripts']))

    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        self.pending=self.root/'host-events-restart-required'; self.pending.touch()
        self.state=self.root/'systemd.json'
        self.state.write_text(json.dumps(dict(reload=True, enabled=False, active=False,
            service_active='failed', result='exit-code', status='86', stamp=0, fail='', calls=[])))
        executable=self.root/'systemctl'; executable.write_text(SYSTEMCTL); executable.chmod(0o755)
        self.env=dict(os.environ, PATH=str(self.root)+os.pathsep+os.environ['PATH'], HOST_EVENTS_SYSTEMD_STATE=str(self.state))
        self.script=self.rendered['activate'].replace('/var/lib/dragontools/host-events-restart-required',str(self.pending))

    def read(self): return json.loads(self.state.read_text())
    def fail(self, value):
        state=self.read(); state['fail']=value; self.state.write_text(json.dumps(state))
    def apply(self, code=0, changed=True):
        result=subprocess.run(['/bin/sh','-c',self.script],env=self.env,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,code)
        self.assertEqual(result.stderr,b'')
        self.assertEqual(result.stdout,(b'changed' if changed else b'unchanged') if code==0 else b'')
        return self.read()
    def properties(self, unit):
        s=self.read()
        if unit.endswith('.timer'): return dict(ActiveState='active' if s['active'] else 'inactive')
        return dict(ActiveState=s['service_active'],SubState='dead' if s['status']=='0' else 'failed',Result=s['result'],
            ExecMainCode='1',ExecMainStatus=s['status'],ExecMainStartTimestampMonotonic=str(s['stamp']),ExecMainExitTimestampMonotonic=str(s['stamp']))
    def verify(self):
        with patch.object(checks,'properties',self.properties),patch.object(checks,'state_safe') as state_safe:
            self.assertTrue(checks.ready()); state_safe.assert_called_once()

    def test_production_failed_first_run_recovers_then_finalized_rerun_is_noop(self):
        self.fail('helper'); failed=self.apply(207)
        self.assertFalse(failed['enabled']); self.assertFalse(failed['active'])
        self.assertTrue(self.pending.exists())
        with patch.object(checks,'properties',self.properties),self.assertRaises(AssertionError): checks.last_run()
        self.fail(''); state=self.apply()
        self.assertTrue(state['enabled'] and state['active'])
        self.assertEqual(state['service_active'],'inactive')
        self.verify()
        self.pending.unlink() # Model finalization only after successful verification.
        before=self.read()['calls']; self.apply(changed=False); self.verify()
        self.assertEqual(before,self.read()['calls'])

    def test_interrupted_timer_enable_recovers_without_losing_intent(self):
        self.fail('enable'); self.apply(205)
        self.assertTrue(self.pending.exists())
        self.fail(''); self.apply(); self.verify()
        self.pending.unlink(); before=self.read()['calls']; self.apply(changed=False)
        self.assertEqual(before,self.read()['calls'])

    def test_timer_start_failure_is_distinct_and_keeps_intent(self):
        self.fail('timer'); self.apply(206); self.assertTrue(self.pending.exists())

    def test_static_oneshot_and_five_minute_timer_policy(self):
        self.assertIn('Type=oneshot\n',self.rendered['service'])
        self.assertNotIn('RemainAfterExit=',self.rendered['service'])
        self.assertNotIn('[Install]',self.rendered['service'])
        self.assertIn('OnUnitActiveSec=5min\n',self.rendered['timer'])
        self.assertIn('Unit=dragontools-host-events.service\n',self.rendered['timer'])
        self.assertIn('ProtectSystem=strict\n',self.rendered['service'])
        self.assertIn('ReadWritePaths=/var/lib/dragontools/host-events\n',self.rendered['service'])


if __name__=='__main__': unittest.main()
