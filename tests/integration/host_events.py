"""Offline pinned Vector/VictoriaLogs/vmalert/Alertmanager host event contract.

Injected native filesystem and stdin replace the real host and journal. Caddy
peer assertions are fixture headers; notification delivery ends at a local webhook.
No real systemd, reboot state, SSH or Telegram is touched.
"""
import datetime
import hashlib
import http.client
import http.server
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import urllib.parse

ROOT=Path(__file__).resolve().parents[2]

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module

def request(port,path,data=None):
    connection=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
    try:
        content_type='application/json' if isinstance(data,(list,dict)) else 'application/x-www-form-urlencoded'
        if isinstance(data,(list,dict)): data=json.dumps(data)
        connection.request('POST' if data is not None else 'GET',path,data,{'Content-Type':content_type})
        response=connection.getresponse(); body=response.read()
        assert 200<=response.status<300,(response.status,body[:500])
        return body
    finally: connection.close()

def wait(check,seconds=100):
    deadline=time.monotonic()+seconds
    while True:
        try:
            value=check()
            if value: return value
        except (OSError,AssertionError): pass
        if time.monotonic()>=deadline: raise AssertionError('bounded host event fixture timeout')
        time.sleep(.25)

def main(rendered,binaries,alerting,native):
    for path,component in [(binaries/'vector','vector'),(binaries/'victoria-logs-prod','victorialogs'),(binaries/'vmalert','vmalert'),(alerting/'alertmanager','alertmanager')]:
        assert hashlib.sha256(path.read_bytes()).hexdigest() in (ROOT/f'src/components/{component}.zig').read_text()
    with tempfile.TemporaryDirectory(prefix='host-events-fixture-') as temporary:
        root=Path(temporary); processes=[]; process_logs=[]; ingress=None; notifications=[]
        class Receiver(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                notifications.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                self.send_response(200); self.end_headers()
            def log_message(self,*_): pass
        receiver=http.server.ThreadingHTTPServer(('127.0.0.1',19093),Receiver)
        threading.Thread(target=receiver.serve_forever,daemon=True).start()
        def start(argv):
            log=(root/('process-%d.log'%len(processes))).open('w+')
            process_logs.append(log)
            proc=subprocess.Popen(list(map(str,argv)),stdout=log,stderr=log,env=dict(os.environ,GOMAXPROCS='2'))
            processes.append(proc); return proc
        def logs(query): return [json.loads(row) for row in request(9428,'/select/logsql/query',urllib.parse.urlencode(dict(query=query))).splitlines()]
        try:
            # The actual native observer, with test-only root injection.
            host_root=root/'host'
            for name in ('run','etc','proc/sys/kernel','var/lib/dragontools/host-events'): (host_root/name).mkdir(parents=True,exist_ok=True)
            (host_root/'var/lib/dragontools/host-events').chmod(0o700)
            (host_root/'etc/machine-id').write_text('a'*32+'\n')
            (host_root/'proc/sys/kernel/osrelease').write_text('7.0.0-30-generic\n')
            (host_root/'proc/uptime').write_text('123456.42 0.00\n')
            marker=host_root/'run/reboot-required'; marker.touch()
            (host_root/'run/reboot-required.pkgs').write_text('libc6\nlibc6\n'+ '\n'.join('linux-image-%d'%i for i in range(26)))
            def observe():
                result=subprocess.run([str(native),'host-events',str(host_root),'check'],capture_output=True,timeout=15)
                assert result.returncode==0 and not result.stderr,(result.returncode,result.stderr)
                return result.stdout.decode().strip()
            required=observe(); assert not observe()
            marker.unlink(); (host_root/'proc/uptime').write_text('120.00 0.00\n')
            (host_root/'proc/sys/kernel/osrelease').write_text('7.0.0-31-generic\n')
            cleared=observe(); assert not observe()
            stamp=datetime.datetime.now(datetime.timezone.utc).isoformat()
            source=(rendered/'doers-vector.yaml').read_text().split('  host_events_identity:\n',1)[1].split('    source: |\n',1)[1].split('sinks:\n',1)[0]
            source=textwrap.dedent(source)
            config=dict(data_dir=str(root/'vector'),sources=dict(journal=dict(type='stdin',decoding=dict(codec='json'))),transforms=dict(events=dict(type='remap',inputs=['journal'],source=source,drop_on_abort=True)),sinks=dict(out=dict(type='console',inputs=['events'],encoding=dict(codec='json'))))
            config_file=root/'vector.json'; config_file.write_text(json.dumps(config))
            payload=''.join(json.dumps(dict(message=line,timestamp=stamp))+'\n' for line in (required,cleared,json.dumps(dict(event='host_stream_ready'))))
            result=subprocess.run([str(binaries/'vector'),'--quiet','--config',str(config_file)],input=payload.encode(),capture_output=True,timeout=20)
            assert result.returncode==0 and b'ERROR' not in result.stderr,result.stderr
            rows=[json.loads(line) for line in result.stdout.splitlines()]; assert len(rows)==3
            assert json.loads(rows[0]['packages'])[:2]==['libc6','linux-image-0'] and rows[0]['packages_count']==27
            assert rows[0]['uptime_seconds']==123456 and rows[1]['uptime_human']=='2m'
            trusted=dict(application='host',environment='host',host='dt-'+'a'*32,service='dragontools-host')
            for row in rows: assert all(row[k]==v for k,v in trusted.items())
            start([binaries/'victoria-logs-prod','-httpListenAddr=127.0.0.1:9428','-storageDataPath='+str(root/'logs'),'-memory.allowedBytes=67108864'])
            wait(lambda: request(9428,'/health') is not None)
            ingestion=load('ingestion',ROOT/'src/monitoring/agents/ingestion.py'); ingestion.ROOT=os.getuid()
            registry=root/'registry'; registry.mkdir()
            registration=json.loads((rendered/'doers-registration.json').read_text())
            registration.update(certificate_sha256='a'*64,certificate_identity='dragontools://hosts/'+registration['host'])
            record=registry/(registration['host']+'.json'); record.write_text(json.dumps(registration)); record.chmod(0o640)
            ingress=ingestion.Server(str(root/'logs.sock'),str(registry),'logs')
            threading.Thread(target=ingress.serve_forever,daemon=True).start()
            connection=http.client.HTTPConnection('localhost'); connection.sock=socket.socket(socket.AF_UNIX); connection.sock.connect(str(root/'logs.sock'))
            headers={'X-DragonTools-'+k:v for k,v in dict(Subject='CN='+registration['host'],Fingerprint='a'*64,URI=registration['certificate_identity'],**{'Other-URI':'','DNS':'','IP':'','Email':''}).items()}
            connection.request('POST','/insert/jsonline',b'\n'.join(json.dumps(row).encode() for row in rows)+b'\n',headers)
            response=connection.getresponse(); response.read(); assert response.status==204; connection.close()
            stream='{'+','.join(k+'='+json.dumps(v) for k,v in sorted(trusted.items()))+'}'
            stored=wait(lambda: logs(stream))
            assert len(stored)==3 and all(row['_stream']==stream for row in stored)
            assert len(logs(stream+' event:="host_reboot_required" packages:libc6'))==1
            signals=load('signals',ROOT/'src/monitoring/agents/signals.py')
            assert signals.log_ready(trusted,time.time()-60)
            print('PASS: native persistent transitions, bounded packages, generated VRL, private ingress and trusted host stream.',flush=True)
            # Preserve the actual production route policy; replace Telegram only
            # with a local webhook. No tokens, internet or human messages.
            text=(ROOT/'src/monitoring/alertmanager.zig').read_text().split('pub const enabled_config =',1)[1].split('\n;',1)[0]
            text='\n'.join(line.split('\\\\',1)[1] for line in text.splitlines() if '\\\\' in line)
            text=text.split('receivers:',1)[0].replace('/etc/dragontools/alertmanager/templates/telegram.tmpl',str(ROOT/'src/monitoring/telegram.tmpl'))
            text+='receivers:\n  - name: discard\n'
            for name,resolved in [('telegram','true'),('telegram-host-events','false')]: text+='  - name: '+name+'\n    webhook_configs:\n      - url: http://127.0.0.1:19093/notify\n        send_resolved: '+resolved+'\n'
            am_config=root/'alertmanager.yml'; am_config.write_text(text)
            start([alerting/'alertmanager','--config.file='+str(am_config),'--storage.path='+str(root/'am'),'--web.listen-address=127.0.0.1:9093','--cluster.listen-address='])
            wait(lambda: request(9093,'/-/ready') is not None)
            evaluator=start([binaries/'vmalert','-rule='+str(rendered/'base-logs.rules.yml'),'-datasource.url=http://127.0.0.1:9428','-notifier.url=http://127.0.0.1:9093','-httpListenAddr=127.0.0.1:8880','-group.maxStartDelay=1s'])
            # v1.152.0 subtracts its 30s eval delay, then aligns query time to
            # the 1m group interval. Starting early in a minute can leave both
            # initial evaluations before these fresh events; allow two full
            # cycles plus notification margin, without changing native policy.
            wait(lambda: len(notifications)==2,seconds=180)
            names={item['alerts'][0]['labels']['alertname'] for item in notifications}
            assert names=={'HostRebootRequired','HostRebootRequirementCleared'}
            for item in notifications:
                assert len(item['alerts'])==1 and item['status']=='firing'
                alert=item['alerts'][0]; assert not set(alert['labels']) & {'kernel','packages','packages_text','packages_count','uptime_seconds','uptime_human'}
                assert alert['annotations']['kernel'].startswith('7.0.0-') and alert['annotations']['uptime_human'], alert['annotations']
                if alert['labels']['alertname']=='HostRebootRequired': assert 'libc6' in alert['annotations']['packages_text'] and '+ 7 more' in alert['annotations']['packages_text']
            # Query the exact rule at a future evaluation time: old history cannot
            # keep the event alert active. No changes to the rule's two-minute window.
            for rule in json.loads((ROOT/'src/monitoring/host_event_rules.json').read_text())['groups'][0]['rules']:
                result=json.loads(request(9428,'/select/logsql/stats_query',urllib.parse.urlencode(dict(query=rule['expr'],time=time.time()+300))))
                assert not result['data']['result'],result
            evaluator.terminate(); evaluator.wait(timeout=10)
            alerts=[{key:item['alerts'][0][key] for key in ('labels','annotations','startsAt','endsAt')} for item in notifications]
            for _ in range(3): request(9093,'/api/v2/alerts',alerts)
            for alert in alerts: alert['endsAt']=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=1)).isoformat()
            request(9093,'/api/v2/alerts',alerts)
            # Observe one complete production group interval for unwanted repeats
            # or automatic resolved notifications, while checking every response.
            deadline=time.monotonic()+65
            while time.monotonic()<deadline:
                assert len(notifications)==2
                time.sleep(.25)
            print('PASS: native event annotations contain context, ALERTS labels stay small, old history expires, and Alertmanager sends one notification per event with no automatic resolved/repeat.',flush=True)
        except Exception:
            for log in process_logs:
                log.flush(); log.seek(0); print(log.read()[-8000:],file=sys.stderr)
            raise
        finally:
            if ingress: ingress.shutdown(); ingress.server_close()
            receiver.shutdown(); receiver.server_close()
            for proc in reversed(processes):
                if proc.poll() is None: proc.terminate()
                try: proc.wait(timeout=10)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait()

if __name__=='__main__': main(*map(lambda x:Path(x).resolve(),sys.argv[1:]))
