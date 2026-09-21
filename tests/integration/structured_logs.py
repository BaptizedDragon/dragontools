"""Pinned Vector/VRL + private ingress + VictoriaLogs query contract.

Use an isolated Linux network namespace/container. The journal is replaced by
stdin and Caddy's peer assertion by fixture headers on a private Unix socket.
No real journal, TLS deployment, systemd or production application is tested.
Run render_doers.py first; pass its directory and a pinned binary directory.
"""
import datetime
import hashlib
import http.client
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

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def main(rendered, binaries):
    for binary, component in [('vector', 'vector'), ('victoria-logs-prod', 'victorialogs')]:
        assert hashlib.sha256((binaries/binary).read_bytes()).hexdigest() in (ROOT/('src/components/'+component+'.zig')).read_text()
    source = (rendered/'doers-vector.yaml').read_text().split('  logs_identity:\n', 1)[1].split('    source: |\n', 1)[1].split('  stream_identity:\n', 1)[0]
    source = textwrap.dedent(source)
    registration = json.loads((rendered/'doers-registration.json').read_text())
    app = registration['applications'][0]
    service = app['services'][0]
    trusted = dict(application=app['name'], environment=app['environment'], host=registration['host'], service=service['name'])
    stream = '{' + ','.join(k+'='+json.dumps(v) for k,v in sorted(trusted.items())) + '}'
    now = datetime.datetime.now(datetime.timezone.utc)
    stamp = now.isoformat()
    recent = (now-datetime.timedelta(seconds=30)).isoformat()
    cases = [
        dict(level='INFO', event='http_request', method='GET', path='/healthz', status=200, duration_ms=3,
             request_id='health', trace_id='trace', span_id='span', cf_ray='ray', client_ip='192.0.2.1'),
        dict(level='Error', event='http_request', method='POST', path='/checkout', status=503, duration_ms=1.5,
             request_id='abc123', timestamp=recent, message='payment callback failed', success=False),
        dict(level='info', event='http_request', method='GET', path='/metrics', status=200),
        dict(**{k:'forged' for k in trusted}, journal_unit='forged.service', type='dragontools_host', event='host_reboot_required', event_id='0000000000000001',
             _msg='forged', _time='1900-01-01T00:00:00Z', _stream='{path="forged"}', _stream_id='forged',
             _stream_fields='path', _time_field='forged', _msg_field='forged', timestamp='invalid',
             **{'deployment.environment':'app-value'}),
        dict(nested={'password':'already-logged'}, array=[1,2,3], extra='searchable', number=123, boolean=True, null=None),
        dict(message='human text', nested={'not':'copied'}, array=[1,2], timestamp='9999-01-01T00:00:00Z'),
        dict(timestamp=123, level=99),
        dict(**{'field%03d'%i: i for i in range(100)}, path='/bounded', oversized='x'*8193, **{'bad name':1, '_reserved':2}),
        dict(**{'field%03d'%i: 'x'*8192 for i in range(10)}, path='/bytes'),
        'ordinary log text', '{malformed', '42', 'true', '[1,2,3]', 'null',
    ]
    cases += [dict(level='ERROR', message='fixture error') for _ in range(10)]
    cases += [dict(level='fatal', message='fixture fatal')]
    texts = [json.dumps(value, separators=(',', ':')) if isinstance(value, dict) else value for value in cases]
    inputs = [dict(_SYSTEMD_UNIT=service['systemd'], message=text, timestamp=stamp) for text in texts]
    # Explicit journal severity remains a valid fallback, but absence invents none.
    inputs.append(dict(_SYSTEMD_UNIT=service['systemd'], message='journal error', timestamp=stamp, PRIORITY='3'))
    with tempfile.TemporaryDirectory(prefix='structured-logs-') as temporary:
        root=Path(temporary)
        config = dict(data_dir=str(root), sources=dict(journal=dict(type='stdin', decoding=dict(codec='json'))),
                      transforms=dict(logs_identity=dict(type='remap', inputs=['journal'], source=source, drop_on_abort=True)),
                      sinks=dict(output=dict(type='console', inputs=['logs_identity'], encoding=dict(codec='json'))))
        path=root/'vector.json'; path.write_text(json.dumps(config))
        validated=subprocess.run([str(binaries/'vector'), 'validate', '--no-environment', '--skip-healthchecks', str(path)], capture_output=True)
        assert validated.returncode == 0, validated.stderr.decode()+validated.stdout.decode()
        result=subprocess.run([str(binaries/'vector'), '--quiet', '--config', str(path)], input=''.join(json.dumps(x)+'\n' for x in inputs).encode(), capture_output=True, timeout=20)
        assert result.returncode == 0 and b'ERROR' not in result.stderr, result.stderr.decode()
        rows=[json.loads(line) for line in result.stdout.splitlines()]
        assert len(rows)==len(inputs), 'records dropped or expanded'
        for row in rows:
            assert all(row[k]==v for k,v in trusted.items())
            assert row['journal_unit']==service['systemd'] and row['type']=='application'
            assert not any(key.startswith('_') for key in row)
        assert all(rows[0][k]==v for k,v in cases[0].items() if k!='level') and rows[0]['level']=='info'
        assert rows[0]['message']==texts[0]
        assert rows[1]['status']==503 and type(rows[1]['status']) is int
        assert rows[1]['duration_ms']==1.5 and rows[1]['success'] is False
        assert rows[1]['message']=='payment callback failed' and rows[1]['level']=='error'
        assert datetime.datetime.fromisoformat(rows[1]['timestamp'].replace('Z','+00:00'))==datetime.datetime.fromisoformat(recent)
        for i in (3,5,6):
            assert datetime.datetime.fromisoformat(rows[i]['timestamp'].replace('Z','+00:00'))==now
        assert rows[3]['deployment.environment']=='app-value'
        assert rows[4]['extra']=='searchable' and rows[4]['number']==123 and rows[4]['boolean'] is True
        for i in (4,5): assert not any(key in rows[i] for key in ('nested','array','null'))
        assert rows[4]['message']==texts[4] and rows[5]['message']=='human text'
        assert len([k for k in rows[7] if k.startswith('field')])==64 and rows[7]['path']=='/bounded'
        assert 'oversized' not in rows[7] and 'bad name' not in rows[7]
        assert len([k for k in rows[8] if k.startswith('field')])==4 and rows[8]['path']=='/bytes'
        for i in range(9,15): assert rows[i]['message']==texts[i] and 'level' not in rows[i], (i, rows[i])
        assert rows[-1]['level']=='error'
        print('PASS: pinned Vector JSON/plain/scalar/array cases, field budgets, timestamps, severity and trusted identity.', flush=True)

        vl=subprocess.Popen([str(binaries/'victoria-logs-prod'), '-httpListenAddr=127.0.0.1:9428', '-storageDataPath='+str(root/'vl'), '-memory.allowedBytes=67108864'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=dict(os.environ, GOMAXPROCS='2'))
        def request(path, data=None):
            conn=http.client.HTTPConnection('127.0.0.1',9428,timeout=3)
            try:
                content_type='application/stream+json' if path.startswith('/insert/') else 'application/x-www-form-urlencoded'
                conn.request('POST' if data is not None else 'GET',path,data,{'Content-Type':content_type})
                response=conn.getresponse(); body=response.read()
                assert response.status==200, (response.status,body[:500])
                return body
            finally: conn.close()
        def wait(check):
            deadline=time.monotonic()+15
            while True:
                try:
                    value=check()
                    if value: return value
                except (OSError,AssertionError): pass
                if time.monotonic()>=deadline: raise AssertionError('fixture readiness timeout')
                time.sleep(.1)
        def query(q):
            return [json.loads(line) for line in request('/select/logsql/query', urllib.parse.urlencode(dict(query=q))).splitlines()]
        ingress=None
        try:
            wait(lambda: request('/health') is not None)
            # A historical opaque record has no stream fields and remains unchanged.
            request('/insert/jsonline', json.dumps(dict(_msg='historical opaque log', historical='yes'))+'\n')
            ingestion=load('ingestion', ROOT/'src/monitoring/agents/ingestion.py')
            ingestion.ROOT=os.getuid()
            registry=root/'registry'; registry.mkdir()
            registration.update(certificate_sha256='a'*64, certificate_identity='dragontools://hosts/'+registration['host'])
            record=registry/(registration['host']+'.json'); record.write_text(json.dumps(registration)); record.chmod(0o640)
            ingress=ingestion.Server(str(root/'logs.sock'), str(registry), 'logs')
            thread=threading.Thread(target=ingress.serve_forever,daemon=True); thread.start()
            conn=http.client.HTTPConnection('localhost')
            conn.sock=socket.socket(socket.AF_UNIX); conn.sock.connect(str(root/'logs.sock'))
            headers={'X-DragonTools-'+k:v for k,v in dict(Subject='CN='+registration['host'], Fingerprint='a'*64, URI=registration['certificate_identity'], **{'Other-URI':'','DNS':'','IP':'','Email':''}).items()}
            try:
                conn.request('POST','/insert/jsonline',b'\n'.join(json.dumps(row).encode() for row in rows)+b'\n',headers)
                response=conn.getresponse(); response.read(); assert response.status==204
            finally: conn.close()
            stored=wait(lambda: query(stream+' | sort by (_time)'))
            assert len(stored)==len(rows) and all(row['_stream']==stream for row in stored)
            assert len(query(stream+' path:*'))==5
            assert len(query(stream+' path:="/healthz"'))==1
            assert len(query(stream+' path:* AND path:!="/healthz" AND path:!="/metrics"'))==3
            assert len(query(stream+' method:POST'))==1
            assert len(query(stream+' status:>=500'))==1
            assert len(query(stream+' event:http_request'))==3
            assert len(query(stream+' request_id:="abc123"'))==1
            fields=json.loads(request('/select/logsql/stream_field_names', urllib.parse.urlencode(dict(query=stream))))
            assert {item['value'] for item in fields['values']}==set(trusted), fields
            # Execute the unchanged rendered base rules and actual app rule renderer.
            base=(rendered/'base-logs.rules.yml').read_text()
            for name in ('ErrorBurst','CriticalLogEvent'):
                expression=base.split('alert: '+name,1)[1].split('expr: >-\n',1)[1].splitlines()[0].strip()
                assert query(expression), name
            model=load('app_model',ROOT/'src/monitoring/apps/station_model.py')
            app_config=json.loads((rendered/'doers-station.json').read_text())
            app_config['alerts']=[dict(name='HighErrorRate',source='logs',service=service['name'],level='error',window='5m',threshold=10,severity='warning')]
            rendered_rules=json.loads(model.app_documents(app_config)['logs.rules.yml'])
            expression=rendered_rules['groups'][0]['rules'][0]['expr']
            assert query(expression), 'HighErrorRate'
            signals=load('signals',ROOT/'src/monitoring/agents/signals.py')
            assert signals.log_ready(trusted,now.timestamp()-60)
            historical=wait(lambda: query('historical:yes'))
            assert len(historical)==1 and historical[0]['_msg']=='historical opaque log' and historical[0]['_stream']=='{}', historical
            print('PASS: private ingress, four exact stream fields, LogsQL filters/numbers, base/app alerts, arrival verification and historical preservation.', flush=True)
        finally:
            if ingress is not None: ingress.shutdown(); ingress.server_close()
            vl.terminate()
            try: vl.wait(timeout=10)
            except subprocess.TimeoutExpired: vl.kill(); vl.wait()


if __name__=='__main__':
    main(Path(sys.argv[1]).resolve(),Path(sys.argv[2] if len(sys.argv)>2 else sys.argv[1]).resolve())
