#!/usr/bin/env python3
"""Fresh socket correctness and matched one-core end-to-end benchmarks.
Only the Python standard library and wrk are needed. Never caches app responses.
"""
import argparse, base64, hashlib, http.client, json, os, pathlib, random, re, secrets, socket, subprocess, time, urllib.parse, statistics
ROOT=pathlib.Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def snapshot():
    roots=[ROOT,ROOT/'.lake/packages/fast_http']
    files={}
    for root in roots:
        for p in root.rglob('*'):
            rel=p.relative_to(root)
            if any(x in {'.git','.lake','target','node_modules','results','__pycache__','data'} for x in rel.parts):continue
            if p.is_file() and (p.suffix in {'.lean','.c','.py','.rs','.mjs','.toml','.json','.lock'} or p.name=='lean-toolchain'):
                files[str(p.relative_to(ROOT))]=sha(p)
    for p in [ROOT/'.lake/build/bin/feature_server',ROOT/'bench/axum/target/release/fastleanio-axum-baseline',pathlib.Path('/usr/bin/node')]:files[str(p)]=sha(p)
    return files

def request(port, method, path, body=b'',headers=None):
    c=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
    c.request(method,path,body,headers or {})
    r=c.getresponse();answer=(r.status,{k.lower():v for k,v in r.getheaders()},r.read());c.close();return answer

def multipart(label,data,boundary):
    return (f'--{boundary}\r\nContent-Disposition: form-data; name="label"\r\n\r\n{label}\r\n--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="sample.bin"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode()+data+f'\r\n--{boundary}--\r\n'.encode())

def cases(rng,filedata):
    name='name-'+str(rng.randrange(10**9));n=rng.randrange(100000)
    data=rng.randbytes(1024);boundary='Bench'+str(rng.randrange(10**12));label='upload-'+str(rng.randrange(100000))
    return {
      'plain':('GET','/plain',b'',{},b'x'*1024,200),
      'routing':('GET','/api/hello/'+name,b'',{},('hello '+name).encode(),200),
      'query':('GET','/query?q='+name,b'',{},name.encode(),200),
      'json':('POST','/json',json.dumps({'name':name,'count':n}).encode(),{'Content-Type':'application/json'},f'{name}:{n+1}'.encode(),200),
      'form':('POST','/form',urllib.parse.urlencode({'name':name,'count':n}).encode(),{'Content-Type':'application/x-www-form-urlencoded'},f'{name}:{n+1}'.encode(),200),
      'multipart':('POST','/multipart',multipart(label,data,boundary),{'Content-Type':f'multipart/form-data; boundary={boundary}'},f'{label}:1024:{sum(data)}'.encode(),200),
      'bearer':('GET','/bearer',b'',{'Authorization':'Bearer benchmark-secret'},b'authenticated',200),
      'basic':('GET','/basic',b'',{'Authorization':'Basic '+base64.b64encode(b'bench:secret').decode()},b'authenticated',200),
      'logging':('GET','/log',b'',{},b'logged',200),
      'file_64k':('GET','/files/asset.bin',b'',{},filedata,200),
      'range_1k':('GET','/files/asset.bin',b'',{'Range':'bytes=256-1279'},filedata[256:1280],206),
      'sse_4_events':('GET','/sse',b'',{},None,200),
      'async_2ms':('GET','/later',b'',{},b'later',200),
    }

def parse_sse(body):
    return [{k:v.lstrip(' ') for k,v in (line.split(':',1) for line in block.splitlines() if ':' in line)} for block in body.decode().strip().split('\n\n')]

def verify(port,case):
    method,path,body,headers,expected,status=case
    actual,h,b=request(port,method,path,body,headers)
    assert actual==status,(path,actual,b[:200])
    assert h.get('x-middleware')=='ran',(path,h)
    if expected is None:
        assert parse_sse(b)==[{'id':str(i),'data':f'event-{i}'} for i in range(4)],b
    else:assert b==expected,(path,len(b),b[:120],expected[:120])
    return h,b

class Server:
    def __init__(self,name,port,cpu,data,out):self.name,self.port,self.cpu,self.data,self.out=name,port,cpu,data,out
    def __enter__(self):
        commands={'fastleanio':[str(ROOT/'.lake/build/bin/feature_server')], 'express':['node',str(ROOT/'bench/express/server.mjs')], 'axum':[str(ROOT/'bench/axum/target/release/fastleanio-axum-baseline')]}
        self.log=open(self.out/(self.name+'-server.log'),'ab');env=dict(os.environ,NODE_ENV='production',UV_THREADPOOL_SIZE='1',LEAN_NUM_THREADS='1')
        self.process=subprocess.Popen(['taskset','-c',str(self.cpu)]+commands[self.name]+[str(self.port),str(self.data)],cwd=ROOT,env=env,stdout=self.log,stderr=self.log)
        for _ in range(200):
            if self.process.poll() is not None:raise RuntimeError(f'{self.name} exited: see {self.log.name}')
            try:
                with socket.create_connection(('127.0.0.1',self.port),.05):return self
            except OSError:time.sleep(.025)
        raise RuntimeError(f'{self.name} failed to start')
    def __exit__(self,*args):
        self.process.terminate()
        try:self.process.wait(10)
        except subprocess.TimeoutExpired:self.process.kill();self.process.wait()
        self.log.close()

def correctness(name,port,rng,filedata):
    total=0
    for _ in range(12):
        for c in cases(rng,filedata).values():verify(port,c);total+=1
    # UTF-8, typed path/query and encoded form roundtrips.
    for _ in range(24):
        value='árvíz + &=😀-'+str(rng.randrange(10**9))
        for path in ['/hello/','/api/hello/']:
            verify(port,('GET',path+urllib.parse.quote(value,safe=''),b'',{},('hello '+value).encode(),200));total+=1
        n=rng.randrange(100000)
        verify(port,('POST','/form',urllib.parse.urlencode({'name':value,'count':n}).encode(),{'Content-Type':'application/x-www-form-urlencoded'},f'{value}:{n+1}'.encode(),200));total+=1
    # HEAD, ETag, byte ranges, missing files and auth rejection.
    h,_=verify(port,cases(rng,filedata)['file_64k']);etag=h['etag']
    for method,path,headers,status,expected in [
      ('HEAD','/plain',{},200,b''),('HEAD','/files/asset.bin',{},200,b''),
      ('GET','/files/asset.bin',{'If-None-Match':etag},304,b''),
      ('GET','/files/asset.bin',{'Range':'bytes=-97'},206,filedata[-97:]),
      ('GET','/files/asset.bin',{'Range':'bytes=65530-'},206,filedata[65530:]),
      ('GET','/files/asset.bin',{'Range':'bytes=999999-'},416,None),
      ('GET','/files/asset.bin',{'Range':'bytes=0-2','If-Range':'"stale"'},200,filedata),
      ('GET','/files/missing.bin',{},404,None),('GET','/files/%2e%2e/secret.bin',{},404,None),
      ('GET','/basic',{},401,None),('GET','/bearer',{'Authorization':'Bearer wrong'},401,None),
      ('GET','/fail',{},500,b'Internal Server Error')]:
        code,hh,body=request(port,method,path,headers=headers)
        # Frameworks differ in traversal rejection (403 vs 404), both must withhold bytes.
        assert code==status or ('%2e' in path and code==403),(name,path,code,body[:100])
        if expected is not None:assert body==expected,(name,path,body[:100])
        if status==401:assert 'www-authenticate' in hh
        total+=1
    for method,path,body,headers in [('POST','/json',b'{bad',{'Content-Type':'application/json'}),('POST','/multipart',b'broken',{'Content-Type':'multipart/form-data; boundary=X'})]:
        code,_,_=request(port,method,path,body,headers);assert 400<=code<500,(name,path,code);total+=1
    assert int(request(port,'GET','/log-count')[2])>=12
    if name=='fastleanio':
        for headers in [{'Range':'bytes=0-2'}, {'Range':'bytes=-2'}]:
            code,hh,body=request(port,'HEAD','/files/asset.bin',headers=headers)
            assert code==200 and body==b'' and 'content-range' not in hh
            total+=1
        for auth in ['bAsIc    '+base64.b64encode(b'bench:secret').decode(), 'Basic '+base64.b64encode(b'bench:secret').decode()]:
            assert request(port,'GET','/basic',headers={'Authorization':auth})[0]==200
            total+=1
        for auth in ['Bearer bad@token','Bearer =','Basic '+base64.b64encode(b'bench:sec\x00ret').decode()]:
            assert request(port,'GET','/basic' if auth.startswith('Basic') else '/bearer',headers={'Authorization':auth})[0]==401
            total+=1
        for boundary in ['"bad "','"bad@boundary"']:
            code,_,_=request(port,'POST','/multipart',multipart('x',b'y','bad'),{'Content-Type':'multipart/form-data; boundary='+boundary})
            assert code==400
            total+=1
        # Strict parser policy is intentionally stronger than the baseline libraries.
        for body in [b'name=%FF&count=1',b'name=%GG&count=1',b'name=a&name=b&count=1',b'name=x&count=-1']:
            code,_,_=request(port,'POST','/form',body,{'Content-Type':'application/x-www-form-urlencoded'});assert code in (400,422),(body,code);total+=1
        for suffix in [b'\r\n--Xoops',b'\r\n--X--oops',b'\x00\xff\r\n--X-']:
            data=rng.randbytes(57)+suffix+rng.randbytes(23)
            c=('POST','/multipart',multipart('binary',data,'X'),{'Content-Type':'multipart/form-data; boundary="X"'},f'binary:{len(data)}:{sum(data)}'.encode(),200)
            verify(port,c);total+=1
    return total

def lua_bytes(b):return '"'+''.join('\\%03d'%x for x in b)+'"'
def wrk_run(args,port,case,expected,out,seconds):
    method,path,body,headers,_,status=case
    script=out.with_suffix('.lua')
    lines=['threads = {}','function setup(thread) table.insert(threads, thread) end','valid=0; errors=0',f'wrk.method={json.dumps(method)}',f'wrk.path={json.dumps(path)}',f'wrk.body={lua_bytes(body)}']
    lines += [f'wrk.headers[{json.dumps(k)}]={json.dumps(v)}' for k,v in headers.items()]
    lines += [f'expected={lua_bytes(expected)}',f'''function response(status, headers, body)
 if status == {status} and body == expected and headers["x-middleware"] == "ran" then valid=valid+1 else errors=errors+1 end
end
function done(summary, latency, requests)
 local n,e=0,0
 for _,t in ipairs(threads) do n=n+t:get("valid");e=e+t:get("errors") end
 io.write(string.format("VALIDATED %d ERRORS %d REQUESTS %d\\n",n,e,summary.requests))
end''']
    script.write_text('\n'.join(lines))
    cmd=['taskset','-c',args.client_cpus,args.wrk,'-t2','-c64',f'-d{seconds}s','--latency','-s',str(script),f'http://127.0.0.1:{port}']
    run=subprocess.run(cmd,capture_output=True,text=True,timeout=seconds+20)
    text=run.stdout+run.stderr;out.write_text(text)
    assert run.returncode==0,text
    m=re.search(r'VALIDATED (\d+) ERRORS (\d+) REQUESTS (\d+)',text);assert m,text
    good,bad,count=map(int,m.groups());assert bad==0 and good==count and count>0,text
    assert 'Socket errors:' not in text,text
    rps=float(re.search(r'Requests/sec:\s+([\d.]+)',text).group(1))
    return {'requests_per_second':rps,'validated':good,'errors':bad,'raw':str(out.relative_to(ROOT))}

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--benchmark',action='store_true');p.add_argument('--seconds',type=int,default=5);p.add_argument('--warmup-seconds',type=int,default=2);p.add_argument('--repeats',type=int,default=3);p.add_argument('--server-cpu',type=int,default=16);p.add_argument('--client-cpus',default='24-31');p.add_argument('--wrk',default='/tmp/lean-uv-wrk/wrk');p.add_argument('--servers',default='fastleanio,express,axum');a=p.parse_args()
    out=ROOT/a.output;out.mkdir(parents=True,exist_ok=True);data=out/'data';data.mkdir(exist_ok=True)
    seed=secrets.randbits(64);rng=random.Random(seed);filedata=rng.randbytes(65536);(data/'asset.bin').write_bytes(filedata);(out/'secret.bin').write_bytes(b'never serve this');(data/'.hidden').write_bytes(b'never serve this')
    before=snapshot();result={'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'versions':{cmd:subprocess.check_output(cmd.split(),text=True).strip() for cmd in ['node --version','cargo --version','rustc --version','lake env lean --version']},'seed':seed,'timestamp_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'machine':subprocess.check_output(['uname','-a'],text=True).strip(),'affinity':sorted(os.sched_getaffinity(0)),'server_cpu':a.server_cpu,'client_cpus':a.client_cpus,'connections':64,'client_threads':2,'warmup_seconds':a.warmup_seconds,'wrk_sha256':sha(pathlib.Path(a.wrk)) if a.benchmark else None,'seconds':a.seconds,'repeats':a.repeats,'source_and_binary_sha256':before,'correctness':{},'runs':[]}
    (out/'metadata.json').write_text(json.dumps(result,indent=2))
    names=a.servers.split(',')
    for i,name in enumerate(names):
        with Server(name,18300+i,a.server_cpu,data,out) as server:
            n=correctness(name,server.port,rng,filedata);result['correctness'][name]=n;print(f'{name}: {n} fresh correctness cases passed',flush=True)
    if a.benchmark:
        # Interleave frameworks between repetitions to reduce order/thermal bias.
        for rep in range(a.repeats):
            workloads=cases(rng,filedata)
            for name in names[rep%len(names):]+names[:rep%len(names)]:
                with Server(name,18300+names.index(name),a.server_cpu,data,out) as server:
                    for workload,case in workloads.items():
                        h,expected=verify(server.port,case)
                        warm=wrk_run(a,server.port,case,expected,out/f'warm-{rep}-{name}-{workload}.txt',a.warmup_seconds)
                        ticks=os.sysconf('SC_CLK_TCK')
                        cpu_before=sum(map(int,pathlib.Path(f'/proc/{server.process.pid}/stat').read_text().split()[13:15]))/ticks
                        began=time.monotonic()
                        run=wrk_run(a,server.port,case,expected,out/f'run-{rep}-{name}-{workload}.txt',a.seconds)
                        cpu_after=sum(map(int,pathlib.Path(f'/proc/{server.process.pid}/stat').read_text().split()[13:15]))/ticks
                        run['server_cpu_seconds']=cpu_after-cpu_before
                        run['server_cpu_percent']=100*(cpu_after-cpu_before)/(time.monotonic()-began)
                        result['runs'].append(dict(server=name,workload=workload,repetition=rep,warmup=warm,**run))
                        (out/'results.json').write_text(json.dumps(result,indent=2));print(f'{rep} {name} {workload}: {run["requests_per_second"]:,.0f}/s',flush=True)
    assert snapshot()==before,'Source/binaries changed during evaluation; rerun from a fixed checkpoint'
    result['source_unchanged']=True
    result['medians']={name:{w:statistics.median(r['requests_per_second'] for r in result['runs'] if r['server']==name and r['workload']==w) for w in cases(rng,filedata)} for name in names} if a.benchmark else {}
    (out/'results.json').write_text(json.dumps(result,indent=2))
if __name__=='__main__':main()
