"""Opt-in saturation check inside the isolated Doers process fixture.

Pause only that fixture's Caddy, fill the production Vector log buffer, observe
backpressure and bounded data files, then resume delivery. No systemd/real disks.
"""
import json
import os
from pathlib import Path
import select
import signal
import time

LIMIT = 268435488


def exercise(vector, caddy, data_dir, request, wait, logs):
    def buffer_size():
        text = request(8686, 'GET', '/metrics').decode()
        rows = [line for line in text.splitlines() if line.startswith('vector_buffer_size_bytes{') and 'component_id="logs"' in line]
        # Prometheus exposition may include a trailing millisecond timestamp.
        # The value is the first token after the label block, never the last.
        return max((float(line.split('}', 1)[1].split()[0]) for line in rows), default=0)
    # Keep each line bounded and ordinary info-level; it is synthetic fixture
    # traffic, never an application error or installer-generated event.
    event = dict(_SYSTEMD_UNIT='doers.service', PRIORITY='6', message=json.dumps(dict(
        message='x' * 16000, level='info', request_id='outage-fixture')))
    payload = (json.dumps(event) + '\n').encode()
    descriptor = vector.stdin.fileno()
    os.set_blocking(descriptor, False)
    os.kill(caddy.pid, signal.SIGSTOP)
    offset = sent = 0
    last_progress = time.monotonic()
    sizes = []
    deadline = time.monotonic() + 120
    try:
        while True:
            assert vector.poll() is None and caddy.poll() is None
            _, writable, _ = select.select([], [descriptor], [], .1)
            if writable:
                try:
                    count = os.write(descriptor, payload[offset:])
                    sent += count
                    offset = (offset + count) % len(payload)
                    if count:
                        last_progress = time.monotonic()
                except BlockingIOError:
                    pass
            now = time.monotonic()
            if not sizes or now - sizes[-1][0] >= 1:
                size = buffer_size()
                assert 0 <= size <= LIMIT + 65536, 'Unexpected buffer gauge value'
                disk = sum(p.stat().st_size for p in Path(data_dir).rglob('*') if p.is_file())
                # Two configured disk buffers plus bounded ledger/segment slack.
                assert disk < 2 * LIMIT + 16 * 1024**2, 'Vector disk exceeded configured budget'
                sizes.append((now, size, disk, sent))
                # Disk segments awaiting acknowledgement can stop writes below
                # max_size. Prove a substantial queued backlog and sustained
                # blocked input, without treating max_size as usable capacity.
                if size >= LIMIT // 4 and now - last_progress >= 10:
                    # Source progress must stall while the full queue blocks.
                    assert sizes[-1][3] == sizes[-3][3], 'Full buffer did not backpressure stdin'
                    print('PASS: Vector outage backlog ' + str(int(size)) +
                          ' bytes; data files ' + str(disk) + ' bytes; source backpressure observed.', flush=True)
                    break
            if now >= deadline:
                raise AssertionError('Vector buffer saturation deadline')
    finally:
        os.kill(caddy.pid, signal.SIGCONT)
    # Finish a partial source line after backpressure releases; stdin stays open.
    def finish_line():
        nonlocal offset
        if offset:
            try:
                offset = (offset + os.write(descriptor, payload[offset:])) % len(payload)
            except BlockingIOError:
                return False
        return offset == 0
    try:
        wait(finish_line, 'Vector source resumes after station recovery', 90)
    finally:
        os.set_blocking(descriptor, True)
    # Prove resumed consumption, not an arbitrary throughput benchmark against
    # shared CI CPUs. Retrying connections and exporter refresh remain bounded.
    wait(lambda: buffer_size() < sizes[-1][1] - 1024 * 1024, 'Vector buffer drains after station recovery', 90)
    wait(lambda: logs('request_id:="outage-fixture" | limit 1'), 'queued logs arrive after outage', 45)
    assert vector.poll() is None and caddy.poll() is None
    print('PASS: station outage saturates bounded Vector buffer, blocks source reads, and resumes delivery without agent restart.', flush=True)
