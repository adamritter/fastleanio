use axum::{Router, routing::{get,post}, extract::{Path,Query,Multipart,DefaultBodyLimit,Request}, response::{IntoResponse,Response,Sse,sse::Event}, middleware::{self,Next}, http::{StatusCode,header,HeaderValue}, Json,Form};
use serde::Deserialize;
use axum::serve::ListenerExt;
use std::{convert::Infallible,sync::atomic::{AtomicU64,Ordering},time::{Duration,Instant,UNIX_EPOCH}};
use tower::{ServiceExt,service_fn};
use tower_http::services::ServeDir;
use base64::Engine;
static LOGS:AtomicU64=AtomicU64::new(0);
#[derive(Deserialize)]struct Fields{name:String,count:u64}
#[derive(Deserialize)]struct Search{q:String}
async fn plain()->String {"x".repeat(1024)}
async fn hello(Path(name):Path<String>)->String{format!("hello {name}")}
async fn query(Query(q):Query<Search>)->String{q.q}
async fn json(Json(b):Json<Fields>)->String{format!("{}:{}",b.name,b.count+1)}
async fn form(Form(b):Form<Fields>)->String{format!("{}:{}",b.name,b.count+1)}
async fn multipart(mut data:Multipart)->Result<String,StatusCode>{
 let(mut label,mut size,mut sum)=(String::new(),0,0u64);
 while let Some(field)=data.next_field().await.map_err(|_|StatusCode::BAD_REQUEST)?{
  let name=field.name().unwrap_or("").to_owned();
  let bytes=field.bytes().await.map_err(|_|StatusCode::BAD_REQUEST)?;
  if name=="label"{label=String::from_utf8(bytes.to_vec()).map_err(|_|StatusCode::BAD_REQUEST)?;}
  else if name=="file"{size=bytes.len();sum=bytes.iter().map(|b|*b as u64).sum();}
 }
 Ok(format!("{label}:{size}:{sum}"))
}
async fn headers(req:Request,next:Next)->Response{let mut r=next.run(req).await;r.headers_mut().insert("x-middleware",HeaderValue::from_static("ran"));r}
async fn auth(req:Request,next:Next)->Response{
 let scheme=if req.uri().path()=="/basic"{"Basic"}else{"Bearer"};
 let v=req.headers().get(header::AUTHORIZATION).and_then(|v|v.to_str().ok()).unwrap_or("");
 let p:Vec<_>=v.split(' ').collect();
 let valid=p.len()==2 && p[0].eq_ignore_ascii_case(scheme) && if scheme=="Basic"{
  base64::engine::general_purpose::STANDARD.decode(p[1]).ok().as_deref()==Some(b"bench:secret")
 }else{p[1]=="benchmark-secret"};
 if valid{next.run(req).await}else{(StatusCode::UNAUTHORIZED,[(header::WWW_AUTHENTICATE,format!("{scheme} realm=\"Restricted Area\""))],"Unauthorized").into_response()}
}
async fn log(req:Request,next:Next)->Response{let start=Instant::now();let method=req.method().clone();let target=req.uri().clone();let r=next.run(req).await;let _record=(method,target,r.status(),start.elapsed());LOGS.fetch_add(1,Ordering::Relaxed);r}
async fn sse()->Sse<impl futures_util::Stream<Item=Result<Event,Infallible>>>{Sse::new(futures_util::stream::iter((0..4).map(|i|Ok(Event::default().id(i.to_string()).data(format!("event-{i}"))))))}
async fn sse_later()->Sse<impl futures_util::Stream<Item=Result<Event,Infallible>>>{
 Sse::new(futures_util::stream::unfold(0,|i|async move{
  if i==4{return None;} if i==0{tokio::time::sleep(Duration::from_millis(2)).await;}
  Some((Ok(Event::default().id(i.to_string()).data(format!("event-{i}"))),i+1))
 }))
}
#[tokio::main(flavor="current_thread")]
async fn main(){
 let args:Vec<_>=std::env::args().collect();let port=args.get(1).map(String::as_str).unwrap_or("18302");let root=args.get(2).cloned().unwrap_or("bench/data".into());
 let files=service_fn(move|mut req:Request|{let root=root.clone();async move{
  let relative=req.uri().path().trim_start_matches('/');
  let safe=relative.split('/').all(|p|p!=".."&&!p.starts_with('.'));
  let tag=if safe{tokio::fs::metadata(std::path::Path::new(&root).join(relative)).await.ok().and_then(|m|m.modified().ok().and_then(|t|t.duration_since(UNIX_EPOCH).ok()).map(|t|format!("W/\"{}-{}-{}\"",m.len(),t.as_secs(),t.subsec_nanos())))}else{None};
  if let Some(ref tag)=tag{if req.headers().get(header::IF_NONE_MATCH).and_then(|v|v.to_str().ok())==Some(tag.as_str()){return Ok::<_,Infallible>((StatusCode::NOT_MODIFIED,[(header::ETAG,tag.clone())]).into_response());}}
  // Our ETag is weak, so no If-Range validator can authorize a partial response.
  if req.method()!=axum::http::Method::GET || req.headers().contains_key(header::IF_RANGE){req.headers_mut().remove(header::RANGE);}
  let mut r=ServeDir::new(root).oneshot(req).await.unwrap().into_response();if let Some(tag)=tag{r.headers_mut().insert(header::ETAG,HeaderValue::from_str(&tag).unwrap());}Ok(r)
 }});
 let app=Router::new().route("/plain",get(plain)).route("/sync",get(plain)).route("/hello/{name}",get(hello)).route("/api/hello/{name}",get(hello)).route("/query",get(query))
  .route("/json",post(json)).route("/form",post(form)).route("/multipart",post(multipart))
  .route("/basic",get(||async{"authenticated"}).route_layer(middleware::from_fn(auth)))
  .route("/bearer",get(||async{"authenticated"}).route_layer(middleware::from_fn(auth)))
  .route("/log",get(||async{"logged"}).route_layer(middleware::from_fn(log)))
  .route("/log-count",get(||async{LOGS.load(Ordering::Relaxed).to_string()}))
  .nest_service("/files",files).route("/sse",get(sse)).route("/sse-later",get(sse_later)).route("/later",get(||async{tokio::time::sleep(Duration::from_millis(2)).await;"later"}))
  .route("/fail",get(||async{(StatusCode::INTERNAL_SERVER_ERROR,"Internal Server Error")}))
  .layer(DefaultBodyLimit::max(1048576)).layer(middleware::from_fn(headers));
 let listener=tokio::net::TcpListener::bind(format!("127.0.0.1:{port}")).await.unwrap();let listener=listener.tap_io(|stream|stream.set_nodelay(true).expect("TCP_NODELAY"));axum::serve(listener,app).await.unwrap();
}
