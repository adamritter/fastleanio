import FastLeanIO.Macro

open FastLeanIO Std.Async

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def request : FastHTTP.Request := {
  raw := "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".toUTF8
  methodEnd := 3, targetStart := 4, targetEnd := 5, headersStart := 16
  headEnd := 35, close := false, isHead := false }

private def call (h : App.Handler) (factory : IO Std.CancellationContext)
    (limit : Nat := 1024) : IO FastHTTP.Reply :=
  App.handler ((App.empty.addRoute (FastLeanIO.Router.Route.new .get "/" h)).toRouteTrie)
    limit factory request

private partial def finish (reply : FastHTTP.Reply) : IO FastHTTP.Response := do
  match reply with
  | .ready response => return response
  | .pending pending =>
    for _ in [:2000] do
      if let some result ← pending.poll then
        match ← IO.ofExcept result with
        | .ready response => return response
        | .streaming stream => stream.release; throw (IO.userError "unexpected stream")
      IO.sleep 1
    pending.cancel
    throw (IO.userError "pending timeout")
  | _ => throw (IO.userError "unexpected reply")

private def fails (action : IO α) : IO Unit := do
  let failed ← try action *> pure false catch _ => pure true
  require failed "expected failure"

private def lifecycle (seed : Nat) : IO Unit := do
  let scopes ← IO.mkRef (#[] : Array Std.CancellationContext)
  let factory : IO Std.CancellationContext := do
    let ctx ← Std.CancellationContext.new
    scopes.modify (·.push ctx)
    return ctx
  let forbidden : IO Std.CancellationContext := throw (IO.userError "unused scope was allocated")
  let value := toString seed
  let plain := HTTP.text value
  let counter ← IO.mkRef 0
  let immediate : Array App.Handler := #[
    .sync (fun _ => pure plain),
    .async (fun _ => pure plain),
    .async (fun _ => do counter.modify (· + 1); return plain),
    .async (fun _ => do
      let n ← FastHTTP.Action.ofAsync (pure value)
      return HTTP.text n),
    .async (fun _ => do
      let n ← FastHTTP.Action.ofAsync (EAsync.ofTask (Task.pure (.ok value)))
      return HTTP.text n),
    .async (fun _ => do
      try throw (IO.userError "recover") catch _ => pure plain),
    .async (fun _ => do
      try return plain finally counter.modify (· + 1)) ]
  for h in immediate do
    let response ← finish (← call h forbidden)
    require (response.payload == value.toUTF8) "immediate body"
  require ((← counter.get) == 2) "inline side effects repeated"
  fails (call (.sync fun _ => pure (plain.withHeader "bad" "\r\n")) forbidden)
  fails (call (.async fun _ => pure plain) forbidden 0)
  fails (call (.async fun _ => throw (IO.userError "failure")) forbidden)
  let _ ← finish (← App.handler (App.empty.toRouteTrie) 1024 forbidden request)
  let response ← finish (← call (.async fun _ => do
    let first ← FastHTTP.Action.getContext
    FastHTTP.Action.cancel
    let second ← FastHTTP.Action.getContext
    require ((← first.isCancelled) && (← second.isCancelled)) "context not shared"
    return plain) factory)
  require (response.payload == value.toUTF8 && (← scopes.get).size == 1) "explicit context count"
  let _ ← finish (← call (App.Handler.ofContext fun _ => pure plain) factory)
  require ((← scopes.get).size == 2) "legacy bridge context count"

  -- Deterministic suspension. The first scope access happens after the await;
  -- cancellation must already be visible and the prefix must not be replayed.
  let promise ← IO.Promise.new
  let observed ← IO.mkRef false
  let entered ← IO.mkRef 0
  let reply ← call (.async fun _ => do
    entered.modify (· + 1)
    let _ ← FastHTTP.Action.ofAsync (EAsync.ofTask
      (promise.resultD (.error (IO.userError "dropped")) : Task (Except IO.Error Unit)))
    observed.set (← FastHTTP.Action.isCancelled)
    return plain) factory
  let .pending pending := reply | throw (IO.userError "wait did not suspend")
  require ((← scopes.get).size == 3) "suspension context count"
  pending.cancel
  promise.resolve (.ok ())
  for _ in [:2000] do
    if ← observed.get then break
    IO.sleep 1
  require ((← observed.get) && (← entered.get) == 1) "cancel after await / replay"
  require ((← pending.poll).isNone) "cancelled result escaped"

  -- Two simultaneously pending requests must never share their scope.
  let firstGate ← IO.Promise.new
  let secondGate ← IO.Promise.new
  let firstObserved ← IO.mkRef false
  let secondObserved ← IO.mkRef true
  let waiting := fun gate observed => App.Handler.async fun _ => do
    let _ ← FastHTTP.Action.ofAsync (EAsync.ofTask
      (gate.resultD (.error (IO.userError "dropped")) : Task (Except IO.Error Unit)))
    observed.set (← FastHTTP.Action.isCancelled)
    return plain
  let .pending first ← call (waiting firstGate firstObserved) factory
    | throw (IO.userError "first request did not wait")
  let second ← call (waiting secondGate secondObserved) factory
  first.cancel
  firstGate.resolve (.ok ())
  secondGate.resolve (.ok ())
  let _ ← finish second
  for _ in [:2000] do
    if ← firstObserved.get then break
    IO.sleep 1
  require ((← firstObserved.get) && !(← secondObserved.get)) "request scopes leaked"

  -- try/finally and recovery are checked before and after a deterministic wait.
  for delayed in [false, true] do
    for failing in [false, true] do
      let promise ← IO.Promise.new
      let cleaned ← IO.mkRef 0
      let recovered ← IO.mkRef 0
      let action : FastHTTP.Action HTTP.Response := do
        try
          try
            if delayed then
              let _ ← FastHTTP.Action.ofAsync (EAsync.ofTask
                (promise.resultD (.error (IO.userError "dropped")) : Task (Except IO.Error Unit)))
              pure ()
            if failing then throw (IO.userError "original")
            return plain
          finally cleaned.modify (· + 1)
        catch _ =>
          recovered.modify (· + 1)
          return plain
      let reply ← call (.async fun _ => action) factory
      promise.resolve (.ok ())
      let response ← finish reply
      require (response.payload == value.toUTF8 && (← cleaned.get) == 1 &&
        (← recovered.get) == (if failing then 1 else 0)) "finally / recovery"
      let cleanupError : FastHTTP.Action HTTP.Response := do
        try
          if delayed then Std.Async.sleep 1
          return plain
        finally
          cleaned.modify (· + 1)
          (throw (IO.userError "cleanup") : FastHTTP.Action Unit)
      fails (do let reply ← call (.async fun _ => cleanupError) factory; finish reply)
      require ((← cleaned.get) == 2) "cleanup failure reran cleanup"

  -- A stream produced by a sync handler still owns one cancellation scope.
  let closed ← IO.mkRef 0
  let count := (← scopes.get).size
  let .streaming stream ← call (.sync fun _ => pure (HTTP.stream (pure {
    next := pure none, close := closed.modify (· + 1) }))) factory
    | throw (IO.userError "stream was not immediate")
  require ((← scopes.get).size == count + 1) "stream scope count"
  stream.release
  stream.release
  require ((← closed.get) == 1) "stream double cleanup"
  for ctx in ← scopes.get do require (← ctx.isCancelled) "scope not closed"

def main (args : List String) : IO Unit := do
  let seed := (args[0]?.getD "1").toNat!
  for i in [:32] do lifecycle (seed + i * 997)
  IO.println s!"PASS: 32 Action lifecycle iterations; seed={seed}; unused scopes=0"
