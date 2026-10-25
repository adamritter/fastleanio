import FastLeanIO.Support
import FastHTTP.UV
import FastHTTP.SSE

/-! Native backend for the same parameterized FastLeanIO router/trie and route DSL.
Request bodies are FastHTTP byte arrays; no Std request/response/body channels
are constructed. Response serialization happens after middleware completes. -/
namespace FastLeanIO.HTTP
open Std.Http Std.Async FastLeanIO

structure ResponseData where
  body : ByteArray := .empty
  status : Nat := 200
  reason : String := "OK"
  contentType : String := "application/octet-stream"
  headers : Array (String × String) := #[]
  /-- Open only after middleware and header validation succeed. -/
  stream : Option (ContextAsync FastHTTP.AsyncStream.Source) := none

def ResponseData.prepare (r : ResponseData) : Except String FastHTTP.Response :=
  if r.stream.isSome then .error "streaming response requires the streaming backend"
  else FastHTTP.Response.create r.body r.status r.reason r.contentType r.headers

/-- An explicitly prepared response carries an erased equality certificate.
Every modifying middleware returns fresh data, so no cached bytes can go stale. -/
inductive Response where
  | fresh (data : ResponseData)
  | prepared (data : ResponseData) (wire : FastHTTP.Response)
      (valid : data.prepare = .ok wire)

def Response.data : Response → ResponseData
  | .fresh data | .prepared data _ _ => data

def Response.prepare : Response → Except String FastHTTP.Response
  | .fresh data => data.prepare
  | .prepared _ wire _ => .ok wire

def ResponseData.prepared (data : ResponseData) : Except String Response :=
  match h : data.prepare with
  | .error e => .error e
  | .ok wire => .ok (.prepared data wire h)

def Response.withHeader (r : Response) (name value : String) : Response :=
  .fresh { r.data with headers := r.data.headers.push (name, value) }

def Response.withStatus (r : Response) (status : Status) : Response :=
  .fresh { r.data with status := status.toCode.toNat, reason := status.reasonPhrase }

def text (body : String) : Response :=
  .fresh { body := body.toUTF8, contentType := "text/plain; charset=utf-8" }

def stream (openSource : ContextAsync FastHTTP.AsyncStream.Source)
    (contentType : String := "application/octet-stream") : Response :=
  .fresh { contentType, stream := some openSource }

def sse (openSource : ContextAsync FastHTTP.SSE.Source) (heartbeatMs : Nat := 15000) : Response :=
  (stream (do return ← (← openSource).bytes heartbeatMs) "text/event-stream")
    |>.withHeader "cache-control" "no-cache"

structure Request where
  http : FastHTTP.Request
  params : List (String × String) := []
  extensions : Extensions := .empty

abbrev Handler := Request → ContextAsync Response
abbrev Router := FastLeanIO.Router.Router Handler
abbrev Route := FastLeanIO.Router.Route Handler
abbrev Middleware := FastLeanIO.Router.Middleware Handler

def empty : Router := FastLeanIO.Router.Router.empty Handler

class IntoResponse (α : Type) where
  intoResponse : α → Response

instance : IntoResponse Response := ⟨id⟩
instance : IntoResponse String := ⟨text⟩
instance : IntoResponse ByteArray := ⟨fun body => .fresh { body }⟩
instance : IntoResponse Unit := ⟨fun _ => .fresh {}⟩
instance : IntoResponse Status := ⟨fun status => (Response.fresh {}).withStatus status⟩
instance [IntoResponse α] : IntoResponse (Status × α) :=
  ⟨fun (status, value) => (IntoResponse.intoResponse value).withStatus status⟩
instance [IntoResponse ε] [IntoResponse α] : IntoResponse (Except ε α) :=
  ⟨fun value => match value with
    | .ok value => IntoResponse.intoResponse value
    | .error error => IntoResponse.intoResponse error⟩
instance (priority := 100) [Lean.ToJson α] : IntoResponse α :=
  ⟨fun value => .fresh { body := (Lean.toJson value).compress.toUTF8, contentType := "application/json" }⟩

class FromParts (α : Type) where
  fromParts : Request → Except FromRequestPartsError α

instance : FromParts Request := ⟨Except.ok⟩
instance : FromParts FastHTTP.Request := ⟨fun r => .ok r.http⟩
instance [FromPath α] : FromParts (Path α) := ⟨fun r => do
  let value ← (FromPath.fromPath (Std.HashMap.ofList r.params)).mapError FromRequestPartsError.semantic_error
  return ⟨value⟩⟩
instance [FastLeanIO.FromString α] : FromParts (Path α) := ⟨fun r => do
  let [(_, value)] := r.params | throw (.semantic_error "expected exactly one path parameter")
  return ⟨← (FastLeanIO.FromString.parse value).mapError FromRequestPartsError.semantic_error⟩⟩
instance [FastLeanIO.FromString α] [FastLeanIO.FromString β] : FromParts (Path (α × β)) := ⟨fun r => do
  let [(_, a), (_, b)] := r.params | throw (.semantic_error "expected exactly two path parameters")
  let a ← (FastLeanIO.FromString.parse a).mapError FromRequestPartsError.semantic_error
  let b ← (FastLeanIO.FromString.parse b).mapError FromRequestPartsError.semantic_error
  return ⟨a, b⟩⟩
instance [FromQuery α] : FromParts (Query α) := ⟨fun r => do
  let some target := RequestTarget.parse? r.http.target | throw (.syntax_error "unsupported query")
  return ⟨← (FromQuery.fromQuery target.query).mapError FromRequestPartsError.semantic_error⟩⟩

class FromBody (α : Type) where
  fromBody : FastHTTP.Request → Except FromRequestBodyError α

def bodyBytes (r : FastHTTP.Request) : ByteArray := r.body
instance : FromBody ByteArray := ⟨fun r => .ok (bodyBytes r)⟩

private def requireType (r : FastHTTP.Request) (expected : String) : Except FromRequestBodyError Unit := do
  let some value := r.header? "content-type" | throw (.bad_media_error "missing Content-Type")
  let actual := (value.splitOn ";").head!.trimAscii.toString.toLower
  unless actual == expected do throw (.bad_media_error s!"expected {expected}")

instance : FromBody PlainText := ⟨fun r => do
  requireType r "text/plain"
  let some value := String.fromUTF8? r.body | throw (.syntax_error "invalid UTF-8 body")
  return ⟨value⟩⟩
instance [Lean.FromJson α] : FromBody (Json α) := ⟨fun r => do
  requireType r "application/json"
  let some value := String.fromUTF8? r.body | throw (.syntax_error "invalid UTF-8 body")
  let json ← (Lean.Json.parse value).mapError FromRequestBodyError.syntax_error
  let value ← (Lean.fromJson? json).mapError FromRequestBodyError.semantic_error
  return ⟨value⟩⟩

class PartsExtractor (Fn : Type) where
  extract : Fn → Handler
class Extractor (Fn : Type) where
  extract : Fn → Handler

instance [IntoResponse α] : PartsExtractor (ContextAsync α) :=
  ⟨fun action _ => return IntoResponse.intoResponse (← action)⟩
instance [FromParts α] [PartsExtractor Rest] : PartsExtractor (α → Rest) := ⟨fun f req => do
  match FromParts.fromParts req with
  | .ok value => PartsExtractor.extract (f value) req
  | .error e => return (text (toString e)).withStatus e.toStatus⟩
instance [IntoResponse α] : Extractor (Unit → α) :=
  ⟨fun f _ => pure (IntoResponse.intoResponse (f ()))⟩
instance [IntoResponse α] : Extractor (Unit → ContextAsync α) :=
  ⟨fun f _ => return IntoResponse.intoResponse (← f ())⟩
instance [FromParts α] [PartsExtractor Rest] : Extractor (α → Rest) :=
  ⟨fun f req => PartsExtractor.extract f req⟩
instance [FromBody α] [PartsExtractor Rest] : Extractor (α → Rest) := ⟨fun f req => do
  match FromBody.fromBody req.http with
  | .ok value => PartsExtractor.extract (f value) req
  | .error e => return (text (toString e)).withStatus e.toStatus⟩

/-- Decode only the routing path using the same Std URI path semantics as
FastLeanIO. Headers, query and body are not reparsed into a Std request. -/
def pathSegments (r : FastHTTP.Request) : Option (List String) := do
  let path := (r.target.splitOn "?").head!
  return (← URI.Path.parse? path).toDecodedSegments.toList

/-- Shared route resolution for the compatibility and lazy-scope backends. -/
def resolve {H : Type} (trie : FastLeanIO.Router.RouteTrie H) (req : FastHTTP.Request) :
    Except Response (List (String × String) × H) := do
  let some method := Method.ofString? req.method | throw ((text "Unsupported method").withStatus .notImplemented)
  let some segments := pathSegments req | throw ((text "Unsupported path").withStatus .notImplemented)
  let methodError (allowed : List Method) :=
    ((text "").withStatus .methodNotAllowed).withHeader "allow" (FastLeanIO.Router.RouteTrie.allowValue allowed)
  match trie.lookup method segments with
  | .found params f => return (params, f)
  | .noMatch =>
    match trie.notFound with
    | some f => return ([], f)
    | none => throw ((text "Not Found").withStatus .notFound)
  | .methodMismatch allowed =>
    if method == .head && allowed.contains .get then
      match trie.lookup .get segments with
      | .found params f => return (params, f)
      | _ => throw (methodError allowed)
    else throw (methodError allowed)

def dispatch (trie : FastLeanIO.Router.RouteTrie Handler) (req : FastHTTP.Request) : ContextAsync Response :=
  match resolve trie req with
  | .ok (params, f) => f { http := req, params }
  | .error response => pure response

/-- The same size check and certified constructor serve both completion paths. -/
def Response.prepareBounded (result : Response) (maxResponseBytes : Nat) : Except String FastHTTP.Response :=
  if result.data.body.size > maxResponseBytes then .error "native response limit exceeded"
  else result.prepare

def complete (result : Response) (context : Std.CancellationContext)
    (maxResponseBytes : Nat) : Async FastHTTP.Completion := do
  if let some openSource := result.data.stream then
    -- Validate before acquiring resources, including when source opening suspends.
    let data := result.data
    let headers ← IO.ofExcept ((FastHTTP.StreamResponse.create
      (throw (IO.userError "unattached stream")) (pure ()) data.status data.reason
      (#[ ("content-type", data.contentType) ] ++ data.headers)).mapError IO.userError)
    let source ← openSource context
    return .streaming (← FastHTTP.AsyncStream.attach headers source context)
  else
    let response ← IO.ofExcept ((result.prepareBounded maxResponseBytes).mapError IO.userError)
    context.cancel .cancel
    return .ready response

def submit (context : Std.CancellationContext) (action : Async FastHTTP.Completion) :
    IO FastHTTP.Reply := do
  let guarded : Async FastHTTP.Completion := do
    try action catch error =>
      context.cancel .cancel
      throw error
  match ← guarded.toRawBaseIO with
  | .pure result =>
    match ← IO.ofExcept result with
    | .ready response => return .ready response
    | .streaming response => return .streaming response
  | .ofTask task =>
    let (pending, resolve) ← FastHTTP.Pending.create (context.cancel .cancel)
    BaseIO.chainTask task fun result => do
      let _ ← (resolve result).toBaseIO
      pure ()
    return .pending pending

def handler (trie : FastLeanIO.Router.RouteTrie Handler)
    (maxResponseBytes : Nat := 4 * 1024 * 1024) : FastHTTP.Handler :=
  fun request => do
    let context ← Std.CancellationContext.new
    -- Inspect dispatch once. A synchronous buffered result needs no async
    -- continuation closures or pending gate; it still runs all middleware,
    -- validates output, enforces the body limit and cancels its context.
    match ← (dispatch trie request context).toRawBaseIO with
    | .pure (.error error) =>
      context.cancel .cancel
      throw error
    | .pure (.ok result) =>
      if result.data.stream.isNone then
        try
          return .ready (← IO.ofExcept ((result.prepareBounded maxResponseBytes).mapError IO.userError))
        finally context.cancel .cancel
      else
        submit context (complete result context maxResponseBytes)
    | .ofTask task =>
      submit context do
        let result ← EAsync.ofTask task
        complete result context maxResponseBytes

/-- Compile in IO during worker initialization. A pure function returning a
handler can be eta-expanded by Lean, rebuilding the trie on every request. -/
def compile (router : Router) (maxResponseBytes : Nat := 4 * 1024 * 1024) : IO FastHTTP.Handler := do
  let trie := router.toRouteTrie
  return handler trie maxResponseBytes

def serve (transport : LeanUV.TCP.Config) (makeRouter : UInt32 → IO Router)
    (protocol : FastHTTP.Config := {}) : IO (Array LeanUV.TCP.WorkerStats) :=
  FastHTTP.UV.serve transport (fun worker => do compile (← makeRouter worker)) protocol

end FastLeanIO.HTTP
