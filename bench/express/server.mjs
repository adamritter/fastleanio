import express from 'express';
import multer from 'multer';
import path from 'node:path';
const app = express();
const root = path.resolve(process.argv[3] || 'bench/data');
app.disable('x-powered-by');
app.disable('etag'); // Dynamic responses: no implicit hashing in any baseline.
app.use((req,res,next)=>{res.set('x-middleware','ran');next()});
app.get(['/plain','/sync'],(req,res)=>res.type('text').send('x'.repeat(1024)));
app.get(['/hello/:name','/api/hello/:name'],(req,res)=>res.type('text').send(`hello ${req.params.name}`));
app.get('/query',(req,res)=>res.type('text').send(req.query.q));
const result = (body,res) => {
  if (typeof body.name!=='string' || !Number.isSafeInteger(Number(body.count)) || Number(body.count)<0) return res.sendStatus(422);
  res.type('text').send(`${body.name}:${Number(body.count)+1}`);
};
app.post('/json',express.json({limit:1048576}),(req,res)=>result(req.body,res));
app.post('/form',express.urlencoded({extended:false,limit:1048576,parameterLimit:128}),(req,res)=>result(req.body,res));
const upload=multer({storage:multer.memoryStorage(),limits:{fileSize:1048576,files:1,fields:127,parts:128}});
app.post('/multipart',(req,res,next)=>upload.single('file')(req,res,err=>{if(err)err.status=err.code==='LIMIT_FILE_SIZE'?413:400;next(err)}),(req,res)=>{
  let sum=0; for(const b of req.file.buffer)sum+=b;
  res.type('text').send(`${req.body.label}:${req.file.size}:${sum}`);
});
const auth=scheme=>(req,res,next)=>{
  const [kind,token,...rest]=(req.get('authorization')||'').split(' ');
  const accepted=scheme==='Bearer' ? token==='benchmark-secret' : Buffer.from(token||'','base64').toString()==='bench:secret';
  if(kind.toLowerCase()!==scheme.toLowerCase()||rest.length||!accepted)return res.status(401).set('www-authenticate',`${scheme} realm="Restricted Area"`).type('text').send('Unauthorized');
  next();
};
app.get('/bearer',auth('Bearer'),(req,res)=>res.type('text').send('authenticated'));
app.get('/basic',auth('Basic'),(req,res)=>res.type('text').send('authenticated'));
let logs=0;
app.get('/log',(req,res,next)=>{const start=process.hrtime.bigint();res.on('finish',()=>{const record={method:req.method,target:req.originalUrl,status:res.statusCode,elapsedNanos:process.hrtime.bigint()-start};logs++;});next()},(req,res)=>res.type('text').send('logged'));
app.get('/log-count',(req,res)=>res.type('text').send(String(logs)));
app.use('/files',(req,res,next)=>{if(req.method!=='GET')delete req.headers.range;next()},express.static(root,{etag:true,dotfiles:'deny',fallthrough:false,cacheControl:true,maxAge:0}));
app.get('/sse',(req,res)=>{res.type('text/event-stream').set('cache-control','no-cache');for(let i=0;i<4;i++)res.write(`id: ${i}\ndata: event-${i}\n\n`);res.end()});
app.get('/later',async(req,res)=>{await new Promise(r=>setTimeout(r,2));res.type('text').send('later')});
app.get('/fail',()=>{throw Error('private error')});
app.use((err,req,res,next)=>res.status(err.status||500).type('text').send(err.status?'Error':'Internal Server Error'));
app.listen(Number(process.argv[2]||18301),'127.0.0.1');
