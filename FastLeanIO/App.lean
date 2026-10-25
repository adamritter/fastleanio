import FastLeanIO.HTTP
import FastHTTP.Action

namespace FastLeanIO.App
open FastLeanIO Std.Http Std.Async

abbrev Request := HTTP.Request
abbrev Response := HTTP.Response
abbrev Action := FastHTTP.Action
abbrev SyncHandler := Request → IO Response
abbrev AsyncHandler := Request → Action Response

/-- Synchronous handlers have no async envelope. Async handlers acquire a scope
only if their Action actually requests one. Both can return a streaming response. -/
inductive Handler where
  | sync (run : SyncHandler)
  | async (run : AsyncHandler)

def Handler.action : Handler → AsyncHandler
  | .sync run => fun req => FastHTTP.Action.ofIO (run req)
  | .async run => run

def Handler.ofContext (run : HTTP.Handler) : Handler :=
  .async fun req => FastHTTP.Action.ofContext (run req)

abbrev Router := FastLeanIO.Router.Router Handler
abbrev Route := FastLeanIO.Router.Route Handler
abbrev Middleware := FastLeanIO.Router.Middleware Handler
def empty : Router := FastLeanIO.Router.Router.empty Handler

/-- Response middleware preserves a sync handler's direct IO path. -/
def mapResponse (change : Response → IO Response) : Middleware
  | .sync run => .sync fun req => do change (← run req)
  | .async run => .async fun req => do change (← run req)

/-- General middleware can await, short-circuit, recover, or bracket resources.
Lifting a sync handler here still needs no scope when all work completes inline. -/
def around (middleware : AsyncHandler → AsyncHandler) : Middleware :=
  fun handler => .async (middleware handler.action)

class PartsExtractor (m : Type → Type) (Fn : Type) where
  extract : Fn → Request → m Response
class Extractor (m : Type → Type) (Fn : Type) where
  extract : Fn → Request → m Response

instance [Monad m] [HTTP.IntoResponse α] : PartsExtractor m (m α) :=
  ⟨fun action _ => return HTTP.IntoResponse.intoResponse (← action)⟩
instance [Monad m] [HTTP.FromParts α] [PartsExtractor m Rest] : PartsExtractor m (α → Rest) := ⟨fun f req => do
  match HTTP.FromParts.fromParts req with
  | .ok value => PartsExtractor.extract (m := m) (f value) req
  | .error e => return (HTTP.text (toString e)).withStatus e.toStatus⟩
instance [Monad m] [HTTP.IntoResponse α] : Extractor m (Unit → α) :=
  ⟨fun f _ => pure (HTTP.IntoResponse.intoResponse (f ()))⟩
instance [Monad m] [HTTP.IntoResponse α] : Extractor m (Unit → m α) :=
  ⟨fun f _ => return HTTP.IntoResponse.intoResponse (← f ())⟩
instance [Monad m] [HTTP.FromParts α] [PartsExtractor m Rest] : Extractor m (α → Rest) :=
  ⟨fun f req => PartsExtractor.extract (m := m) f req⟩
instance [Monad m] [HTTP.FromBody α] [PartsExtractor m Rest] : Extractor m (α → Rest) := ⟨fun f req => do
  match HTTP.FromBody.fromBody req.http with
  | .ok value => PartsExtractor.extract (m := m) (f value) req
  | .error e => return (HTTP.text (toString e)).withStatus e.toStatus⟩

def extractSync [Extractor IO Fn] (fn : Fn) : Handler := .sync (Extractor.extract (m := IO) fn)
def extractAsync [Extractor Action Fn] (fn : Fn) : Handler := .async (Extractor.extract (m := Action) fn)

/-- The pure completion decision is separate from context acquisition. -/
inductive Plan where
  | buffered (response : Response)
  | scoped (run : ContextAsync Response)

@[inline] def plan (step : FastHTTP.ActionStep Response) : Plan :=
  match step with
  | .ready response =>
    if response.data.stream.isSome then .scoped (pure response) else .buffered response
  | .scoped run => .scoped run

/-- Factory injection is for lifecycle tests. It must return a fresh root scope.
Normal compile always supplies Std.CancellationContext.new. -/
@[inline] def execute (decision : Plan) (maxResponseBytes : Nat := 4 * 1024 * 1024)
    (newContext : IO Std.CancellationContext := Std.CancellationContext.new) : IO FastHTTP.Reply := do
  match decision with
  | .buffered response =>
    return .ready (← IO.ofExcept ((response.prepareBounded maxResponseBytes).mapError IO.userError))
  | .scoped run =>
    let context ← newContext
    HTTP.submit context do
      HTTP.complete (← run context) context maxResponseBytes

def handler (trie : FastLeanIO.Router.RouteTrie Handler)
    (maxResponseBytes : Nat := 4 * 1024 * 1024)
    (newContext : IO Std.CancellationContext := Std.CancellationContext.new) : FastHTTP.Handler :=
  fun req => do
    match HTTP.resolve trie req with
    | .error response => execute (plan (.ready response)) maxResponseBytes newContext
    | .ok (params, .sync run) =>
      let response ← run { http := req, params }
      execute (plan (.ready response)) maxResponseBytes newContext
    | .ok (params, .async run) =>
      execute (plan (← (run { http := req, params }).run)) maxResponseBytes newContext

def compile (router : Router) (maxResponseBytes : Nat := 4 * 1024 * 1024) : IO FastHTTP.Handler := do
  let trie := router.toRouteTrie
  return handler trie maxResponseBytes

def serve (transport : LeanUV.TCP.Config) (makeRouter : UInt32 → IO Router)
    (protocol : FastHTTP.Config := {}) : IO (Array LeanUV.TCP.WorkerStats) :=
  FastHTTP.UV.serve transport (fun worker => do compile (← makeRouter worker)) protocol

end FastLeanIO.App
