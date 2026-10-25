import FastLeanIO

open FastLeanIO Std.Async

private structure Fields where
  name : String
  count : Nat
deriving Lean.FromJson, FromForm
private structure SearchQuery where
  q : String
deriving FromQuery

private def multipartResult (form : Multipart) : Except Std.Http.Status String := do
  let mut label := ""
  let mut size := 0
  let mut checksum := 0
  for part in form.parts do
    if part.name == "label" then
      label ← (String.fromUTF8? part.body).toExcept .badRequest
    if part.name == "file" then
      size := part.body.size
      checksum := part.body.foldl (fun n byte => n + byte.toNat) 0
  return s!"{label}:{size}:{checksum}"

private def events (delayed : Bool := false) : ContextAsync FastHTTP.SSE.Source := do
  let index ← IO.mkRef 0
  return { next := do
    let i ← index.get
    if i == 4 then return none
    if delayed && i == 0 then Std.Async.sleep 2
    index.set (i + 1)
    return some { data := s!"event-{i}", id := some (toString i) } }

private def router (files : StaticFiles) (logged : IO.Ref Nat) : FastLeanIO.Router :=
  empty
    |>.addRoute (GET "/plain" => do return String.ofList (List.replicate 1024 'x'))
    |>.addRoute (sync_route GET "/sync" => do return String.ofList (List.replicate 1024 'x'))
    |>.addRoute (GET "/hello/{name}" (name : Path String) => do return s!"hello {name.value}")
    |>.addRoute (GET "/query" (query : Query SearchQuery) => do return query.value.q)
    |>.addRoute (POST "/json" (body : Json Fields) => do return s!"{body.body.name}:{body.body.count + 1}")
    |>.addRoute (POST "/form" (body : Form Fields) => do return s!"{body.value.name}:{body.value.count + 1}")
    |>.addRoute (POST "/multipart" (body : Multipart) => do return multipartResult body)
    |>.addRoute ((GET "/bearer" => "authenticated").addMiddleware (bearerAuth fun token => pure (token.expose == "benchmark-secret")))
    |>.addRoute ((GET "/basic" => "authenticated").addMiddleware (basicAuth fun user password => pure (user == "bench" && password.expose == "secret")))
    |>.addRoute ((GET "/log" => "logged").addMiddleware (requestLogger fun _ => logged.modify (· + 1)))
    |>.addRoute (GET "/log-count" => do return toString (← logged.get))
    |>.addRoute (GET "/files/{*path}" (path : Path String) (req : HTTP.Request) => do return ← files.respond path.value req)
    |>.addRoute (GET "/sse" => sse (events false) 0)
    |>.addRoute (GET "/sse-later" => sse (events true) 0)
    |>.addRoute (GET "/later" => do Std.Async.sleep 2; return "later")
    |>.addRoute (GET "/fail" => do throw (IO.userError "private error"); return "unreachable")
    |>.addRouter "/api" (empty.addRoute (GET "/hello/{name}" (name : Path String) => do return s!"hello {name.value}"))
    |>.addMiddleware (mapResponse fun response => pure (response.withHeader "x-middleware" "ran"))
    |>.addMiddleware catchErrors

def main (args : List String) : IO Unit := do
  let port := (args[0]?.getD "18300").toNat!.toUInt16
  let root := args[1]?.getD "bench/data"
  let files ← StaticFiles.create root
  let _ ← serve { port, threads := 1 } fun _ => do
    let logged ← IO.mkRef 0
    return router files logged
  pure ()
