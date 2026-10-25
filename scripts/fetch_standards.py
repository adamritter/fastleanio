#!/usr/bin/env python3
"""Explicitly refresh normative snapshots; builds never access the network."""
from pathlib import Path
import concurrent.futures, datetime, hashlib, json, urllib.request
ROOT=Path(__file__).resolve().parents[1]
SOURCES={f'rfc{n}.txt':f'https://www.rfc-editor.org/rfc/rfc{n}.txt' for n in [2046,3986,4648,6750,7578,7617,9110]}
SOURCES.update({'whatwg-url.html':'https://url.spec.whatwg.org/','whatwg-sse.html':'https://html.spec.whatwg.org/multipage/server-sent-events.html'})
def fetch(item):
 name,url=item
 with urllib.request.urlopen(url,timeout=60) as r:
  body=r.read();headers=dict(r.headers);resolved=r.url
 (ROOT/'standards/sources'/name).write_bytes(body)
 return {'file':'sources/'+name,'url':url,'resolved_url':resolved,'sha256':hashlib.sha256(body).hexdigest(),'bytes':len(body),'retrieved_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'last_modified':headers.get('Last-Modified'),'etag':headers.get('ETag')}
if __name__=='__main__':
 (ROOT/'standards/sources').mkdir(parents=True,exist_ok=True)
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:entries=list(pool.map(fetch,SOURCES.items()))
 (ROOT/'standards/manifest.json').write_text(json.dumps({'sources':entries},indent=2)+'\n')
 print(f'Downloaded {len(entries)} complete normative documents; original notices retained.')
