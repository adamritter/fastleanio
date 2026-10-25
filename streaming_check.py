#!/usr/bin/env python3
"""Fresh socket tests for the native stream lifecycle and SSE wire format."""
import argparse
import concurrent.futures
import hashlib
import http.client
import json
import os
from pathlib import Path
import random
import re
import signal
import socket
import struct
import subprocess
import time
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent / "bench"))
import check

ROOT = Path(__file__).resolve().parent
BINARY = ROOT / '.lake/build/bin/streaming_checks'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--first-cpu', type=int, default=16)
    parser.add_argument('--backend', choices=['native', 'direct'], default='native')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    BINARY = ROOT / ('.lake/build/bin/streaming_checks')
    args.output.mkdir(parents=True, exist_ok=False)
    seed = int.from_bytes(os.urandom(8), 'big')
    checkpoint = check.snapshot()
    binary_hash = hashlib.sha256(BINARY.read_bytes()).hexdigest()
    (args.output/'metadata.json').write_text(json.dumps({**checkpoint,'seed':seed,'streaming_binary_sha256':binary_hash,'backend':args.backend},indent=2)+'\n')
    rng = random.Random(seed)
    checked = 0
    details = []
    for workers in (1, 4):
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        address = ('127.0.0.1', port)
        logpath = args.output / f'workers-{workers}.log'
        with logpath.open('w') as log:
            proc = subprocess.Popen(['taskset', '-c', ','.join(map(str,[c for c in sorted(os.sched_getaffinity(0)) if c >= args.first_cpu][:workers])), str(BINARY), str(port), str(workers)],
                stdout=log, stderr=subprocess.STDOUT, env={**os.environ, 'LEAN_NUM_THREADS':'1'})
            held = []
            def exchange(path, body=None, headers=None, method='GET'):
                conn = http.client.HTTPConnection(*address, timeout=5)
                try:
                    conn.request(method, path, body=body, headers=headers or {})
                    response = conn.getresponse()
                    return response.status, dict(response.getheaders()), response.read()
                finally:
                    conn.close()
            def stats(id):
                return json.loads(exchange('/stats/'+id)[2])
            def wait_stats(id, **want):
                until = time.monotonic() + .7
                while True:
                    value = stats(id)
                    if all(value[k] == v for k,v in want.items()): return value
                    assert time.monotonic() < until, (id, want, value)
                    time.sleep(.01)
            def connect(id, mode, extra=b''):
                sock = socket.create_connection(address, 5)
                sock.sendall(f'GET /case/{id} HTTP/1.1\r\nHost: localhost\r\nX-Mode: {mode}\r\n'.encode()+extra+b'\r\n')
                return sock
            def reset(sock):
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                sock.close()
            def head(stream):
                status = stream.readline()
                assert status.startswith(b'HTTP/1.'), status
                headers = {}
                while (line := stream.readline()) != b'\r\n':
                    assert line
                    k,v = line.rstrip(b'\r\n').split(b':',1)
                    headers[k.lower()] = v.strip()
                return status, headers
            def chunk(stream):
                line = stream.readline()
                assert line, 'stream ended without final chunk'
                size = int(line.strip(),16)
                body = stream.read(size)
                assert len(body)==size and stream.read(2)==b'\r\n'
                return body
            try:
                for _ in range(500):
                    assert proc.poll() is None, logpath.read_text()
                    try:
                        assert exchange('/')[2] == b'streaming-test'
                        break
                    except OSError: time.sleep(.01)
                else: raise AssertionError('startup timeout')

                # New binary inputs, delayed handler and delayed source opening.
                cases = [(f'{workers}-{i}-{rng.getrandbits(48):x}', rng.randbytes(rng.randrange(1,16384)),
                          rng.randrange(1,7), ['bytes','deferred','deferred-open'][i%3]) for i in range(48)]
                def run(case):
                    id, body, count, mode = case
                    status, headers, result = exchange('/case/'+id, body,
                        {'x-mode':mode, 'x-count':str(count)}, 'POST')
                    assert status==201 and result==body*count
                    assert headers['Transfer-Encoding']=='chunked' and 'Content-Length' not in headers
                    assert headers['x-middleware']=='stream'
                    wait_stats(id, entered=1, opened=1, pulls=count+1, closed=1)
                with concurrent.futures.ThreadPoolExecutor(12) as pool:
                    list(pool.map(run,cases))
                checked += len(cases)

                # HEAD suppresses producer calls; HTTP/1.0 uses close framing.
                id=f'head-{workers}'
                assert exchange('/case/'+id, method='HEAD')[::2] == (201,b'')
                wait_stats(id, opened=1, pulls=0, closed=1)
                id=f'legacy-{workers}'
                with socket.create_connection(address,5) as sock, sock.makefile('rb') as stream:
                    sock.sendall(f'GET /case/{id} HTTP/1.0\r\nX-Count: 3\r\n\r\n'.encode())
                    status, headers=head(stream)
                    assert status.startswith(b'HTTP/1.0 201') and b'transfer-encoding' not in headers
                    assert stream.read()==b's'*3072
                wait_stats(id, opened=1, pulls=4, closed=1)
                checked += 2

                # Middleware changes retain the stream; invalid metadata never opens it.
                for mode in ['bad-header','no-body-status']:
                    id=f'{mode}-{workers}'
                    assert exchange('/case/'+id, headers={'x-mode':mode})[0]==500
                    wait_stats(id, entered=1, opened=0, pulls=0, closed=0)
                    checked += 1
                for mode in ['error','empty','sse-bad']:
                    id=f'{mode}-{workers}'
                    try:
                        exchange('/case/'+id, headers={'x-mode':mode,'x-count':'3'})
                        raise AssertionError('producer failure became successful EOF')
                    except http.client.IncompleteRead: pass
                    wait_stats(id, opened=1, closed=1)
                    checked += 1

                # Streaming bypasses the 4-MiB buffered-response limit.
                id=f'large-{workers}'
                status, _, body=exchange('/case/'+id, headers={'x-size':'65536','x-count':'128'})
                assert status==201 and body==b's'*(8*1024*1024)
                wait_stats(id, opened=1, pulls=129, closed=1)
                checked += 1

                # SSE normalization, Unicode, event IDs and heartbeat without lost pulls.
                for mode in ['sse','sse-delayed']:
                    id=f'{mode}-{workers}'
                    payload=('árvíz\r\nmásodik\rharmadik\n'+str(rng.getrandbits(64))).encode()
                    status, headers, body=exchange('/case/'+id,payload,
                        {'x-mode':mode,'last-event-id':'42'},'POST')
                    assert status==201 and headers['content-type']=='text/event-stream'
                    assert headers['cache-control']=='no-cache'
                    if mode=='sse-delayed': assert body.count(b': keep-alive\n\n')>=1
                    cleaned=body.replace(b': keep-alive\n\n',b'')
                    normalized=payload.replace(b'\r\n',b'\n').replace(b'\r',b'\n')
                    expected=b'event: message\nid: 42\nretry: 1000\n'+b''.join(b'data: '+s+b'\n' for s in normalized.split(b'\n'))+b'\n'
                    expected+='event: message\nid: 1\nretry: 1000\ndata: vége\n\n'.encode()
                    assert cleaned==expected, (cleaned,expected)
                    wait_stats(id, opened=1,pulls=3,closed=1)
                    checked += 1

                # Disconnect during a handler, pending pull, and late resource acquisition.
                for mode in ['wait-handler','wait-stream','late']:
                    id=f'{mode}-{workers}'
                    sock=connect(id,mode)
                    wait_stats(id,entered=1)
                    if mode=='wait-stream': wait_stats(id,opened=1,pulls=1)
                    start=time.monotonic(); reset(sock)
                    want={'cancelled':1}
                    if mode!='wait-handler': want.update(opened=1,closed=1)
                    result=wait_stats(id,**want)
                    details.append({'workers':workers,'case':mode,'cancel_seconds':time.monotonic()-start,'counts':result})
                    checked += 1

                # Producer backpressure: a blocked receiver cannot cause unbounded pulls.
                id=f'pressure-{workers}'
                sock=socket.socket(); sock.settimeout(5)
                sock.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,1024); sock.connect(address)
                sock.sendall(f'GET /case/{id} HTTP/1.1\r\nHost: localhost\r\nX-Size: 65536\r\nX-Count: 100000\r\n\r\n'.encode())
                time.sleep(.15); before=stats(id)['pulls']; time.sleep(.15); after=stats(id)['pulls']
                assert 0 < before <= after < 1000 and after-before <= 2,(before,after)
                reset(sock); wait_stats(id,closed=1)
                details.append({'workers':workers,'case':'backpressure','pulls_before':before,'pulls_after':after})
                checked += 1

                # Heartbeats count as activity even beyond the transport's 1-second idle limit.
                id=f'heartbeat-{workers}'; sock=connect(id,'sse-idle'); stream=sock.makefile('rb')
                assert head(stream)[0].startswith(b'HTTP/1.1 201')
                started=time.monotonic(); beats=0
                while time.monotonic()-started < 2.1:
                    assert chunk(stream)==b': keep-alive\n\n'; beats+=1
                assert stats(id)['pulls']==1
                stream.close(); reset(sock); wait_stats(id,opened=1,pulls=1,closed=1,cancelled=1)
                details.append({'workers':workers,'case':'heartbeat','beats':beats}); checked+=1

                # A genuinely idle stream times out and cancels its pending producer.
                id=f'timeout-{workers}'; sock=connect(id,'wait-stream')
                time.sleep(2.1); wait_stats(id,opened=1,closed=1,cancelled=1); sock.close(); checked+=1

                # Fragmented, pipelined requests survive client write-half closure.
                id=f'pipeline-{workers}'
                with socket.create_connection(address,5) as sock, sock.makefile('rb') as stream:
                    wire=(f'GET /case/{id} HTTP/1.1\r\nHost: localhost\r\nX-Mode: deferred\r\n\r\n'
                          'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n').encode()
                    offset=0
                    while offset<len(wire):
                        size=rng.randrange(1,24); sock.sendall(wire[offset:offset+size]); offset+=size
                    sock.shutdown(socket.SHUT_WR)
                    assert head(stream)[0].startswith(b'HTTP/1.1 201')
                    assert chunk(stream)==b's'*1024 and chunk(stream)==b''
                    status,headers=head(stream); assert status.startswith(b'HTTP/1.1 200')
                    assert stream.read(int(headers[b'content-length']))==b'streaming-test'
                    assert stream.read()==b''
                wait_stats(id,opened=1,closed=1); checked+=2
                # Shutdown must cancel live work, not just already-finished streams.
                held.append(connect('shutdown-stream','wait-stream'))
                held.append(connect('shutdown-handler','wait-handler'))
                wait_stats('shutdown-stream',opened=1,pulls=1)
                wait_stats('shutdown-handler',entered=1)
                checked+=2
            finally:
                proc.send_signal(signal.SIGTERM)
                proc.wait(timeout=10)
                for sock in held: sock.close()
        assert proc.returncode==0, logpath.read_text()
        errors=re.findall(r'errors\s*:=\s*(\d+)',logpath.read_text())
        assert len(errors)==workers and all(int(x)==0 for x in errors),logpath.read_text()
        final=dict((name,json.loads(value)) for name,value in
            re.findall(r'^FINAL (\S+) (.+)$',logpath.read_text(),re.M))
        assert final['shutdown-stream']['closed']==1 and final['shutdown-stream']['cancelled']==1,final
        assert final['shutdown-handler']['cancelled']==1,final
    assert check.snapshot() == checkpoint and hashlib.sha256(BINARY.read_bytes()).hexdigest() == binary_hash
    result={'passed':True,'seed':seed,'workers':[1,4],'checked_cases':checked,'details':details,
            'binary_sha256':hashlib.sha256(BINARY.read_bytes()).hexdigest()}
    (args.output/'validation.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))

if __name__=='__main__': main()
