"""Native observer injected filesystem lifecycle; never reads real reboot state."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
BINARY=Path(os.environ.get('DRAGONTOOLS_PKI_FIXTURE',ROOT/'zig-out/bin/dragontool-pki-fixture'))


class Events(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        for name in ('run','etc','proc/sys/kernel','var/lib/dragontools/host-events'): (self.root/name).mkdir(parents=True,exist_ok=True)
        self.directory=self.root/'var/lib/dragontools/host-events'; self.directory.chmod(0o700)
        (self.root/'proc/sys/kernel/osrelease').write_text('7.0.0-test\n')
        (self.root/'proc/uptime').write_text('123456.42 234567.11\n')
        (self.root/'etc/machine-id').write_text('a'*32+'\n')
        self.marker=self.root/'run/reboot-required'
        self.packages=self.root/'run/reboot-required.pkgs'
        self.state=self.directory/'reboot-required.state'

    def check(self,verify=False,fail=False):
        before={p: (p.read_bytes(),p.stat().st_mtime_ns) for p in self.directory.iterdir() if p.is_file() and not p.is_symlink()}
        result=subprocess.run([str(BINARY),'host-events',str(self.root),'verify' if verify else 'check'],capture_output=True,timeout=10)
        self.assertEqual(result.stderr,b'')
        self.assertEqual(result.returncode==0,not fail)
        if fail: self.assertEqual(result.stdout,b'')
        if verify:
            self.assertEqual(result.stdout,b'')
            self.assertEqual(before,{p:(p.read_bytes(),p.stat().st_mtime_ns) for p in self.directory.iterdir() if p.is_file() and not p.is_symlink()})
        return json.loads(result.stdout) if result.stdout else None

    def test_all_transitions_across_independent_processes_and_initial_true(self):
        self.assertIsNone(self.check())
        stamp=self.state.stat().st_mtime_ns
        self.assertIsNone(self.check()); self.assertEqual(stamp,self.state.stat().st_mtime_ns)
        self.marker.touch()
        event=self.check()
        self.assertEqual(event['event'],'host_reboot_required'); self.assertEqual(event['level'],'warning')
        self.assertEqual(event['packages'],[]); self.assertEqual(event['packages_count'],0)
        self.assertEqual(event['host'],'dt-'+'a'*32); self.assertEqual(event['kernel'],'7.0.0-test')
        self.assertEqual(event['uptime_seconds'],123456); self.assertEqual(event['uptime_human'],'1d 10h')
        stamp=self.state.stat().st_mtime_ns
        self.assertIsNone(self.check()); self.assertEqual(stamp,self.state.stat().st_mtime_ns)
        self.check(verify=True)
        self.marker.unlink(); event=self.check()
        self.assertEqual(event['event'],'host_reboot_requirement_cleared'); self.assertEqual(event['level'],'info')
        self.assertEqual(event['event_id'],'0000000000000002')
        self.assertIsNone(self.check())
        self.state.unlink(); self.marker.touch(); self.assertEqual(self.check()['event'],'host_reboot_required')

    @unittest.skipUnless(Path('/proc/uptime').is_file(), 'requires real Linux procfs')
    def test_fresh_state_with_zero_stat_size_procfs_inputs(self):
        # Production: no reboot marker, no state, readable procfs reports size 0.
        # Regular-file fixtures conceal Zig's size-based EOF optimization.
        shutil.rmtree(self.root/'proc')
        (self.root/'proc').symlink_to('/proc', target_is_directory=True)
        self.assertEqual(Path('/proc/uptime').stat().st_size, 0)
        self.assertTrue(Path('/proc/uptime').read_bytes())
        self.assertIsNone(self.check())
        self.assertEqual(json.loads(self.state.read_text()), dict(version=1, required=False, sequence=0))
        stamp=self.state.stat().st_mtime_ns
        self.check(verify=True)
        self.assertIsNone(self.check())
        self.assertEqual(self.state.stat().st_mtime_ns, stamp)

    def test_packages_bounded_deduplicated_missing_and_non_names_ignored(self):
        self.marker.touch()
        self.packages.write_text('\n libc6 \nlibc6\n not a package \n'+ '\n'.join('package-%d'%i for i in range(26)))
        event=self.check()
        self.assertEqual(event['packages_count'],27); self.assertEqual(len(event['packages']),20)
        self.assertEqual(event['packages'][0],'libc6'); self.assertIn('+ 7 more',event['packages_text'])
        self.assertLess(len(json.dumps(event)),8192)

    def test_unsafe_state_and_input_paths_refused_without_changes(self):
        self.check(); original=self.state.read_bytes()
        outside=self.root/'outside'; outside.write_bytes(original)
        self.state.unlink(); self.state.symlink_to(outside)
        self.check(fail=True); self.assertEqual(outside.read_bytes(),original)
        self.state.unlink(); self.state.write_bytes(original); self.state.chmod(0o644)
        self.check(fail=True); self.state.chmod(0o600)
        self.marker.symlink_to(outside); self.check(fail=True); self.marker.unlink()
        self.marker.touch(); self.packages.symlink_to(outside); self.check(fail=True)
        self.assertEqual(self.state.read_bytes(),original)
        self.directory.chmod(0o755); self.check(fail=True)

    def test_unsafe_staging_refused_before_output_or_state_write(self):
        self.check(); before=self.state.read_bytes()
        staging=self.directory/'reboot-required.next'
        staging.symlink_to(self.state)
        self.marker.touch(); self.check(fail=True); self.check(verify=True,fail=True)
        self.assertEqual(before,self.state.read_bytes())
        staging.unlink(); staging.write_text('partial'); staging.chmod(0o644)
        self.check(fail=True)
        staging.unlink(); os.link(self.state,staging); self.check(fail=True)

    def test_interrupted_staging_and_invalid_state_do_not_rotate_identity(self):
        self.check(); (self.directory/'reboot-required.next').write_text('partial')
        (self.directory/'reboot-required.next').chmod(0o600)
        self.marker.touch(); event=self.check()
        self.assertEqual(event['event_id'],'0000000000000001')
        self.assertFalse((self.directory/'reboot-required.next').exists())
        self.state.write_text('invalid'); self.check(fail=True)
        self.assertEqual(self.state.read_text(),'invalid')


if __name__=='__main__': unittest.main()
