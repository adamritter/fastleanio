import FastLeanIO.Macro

open FastLeanIO FastLeanIO Std.Http Std.Async

private structure Counts where
  opened : Nat := 0
  pulls : Nat := 0
  closed : Nat := 0
  cancelled : Nat := 0
  entered : Nat := 0
deriving Lean.ToJson

private abbrev Stats := Std.Mutex (Std.HashMap String Counts)

private def bump (stats : Stats) (id : String) (f : Counts → Counts) : IO Unit :=
  stats.atomically do modify fun table => table.insert id (f (table[id]?.getD {}))

private def number (req : FastHTTP.Request) (name : String) (fallback : Nat) : Nat :=
  ((req.header? name).bind String.toNat?).getD fallback

private def handle (stats : Stats) (id : String) (req : FastHTTP.Request) : FastHTTP.Action HTTP.Response := do
  bump stats id fun c => { c with entered := c.entered + 1 }
  let mode := (req.header? "x-mode").getD "bytes"
  if mode == "deferred" then Std.Async.sleep 30
  if mode == "wait-handler" || mode == "late" then
    ContextAsync.awaitCancellation
    bump stats id fun c => { c with cancelled := c.cancelled + 1 }
    if mode == "wait-handler" then return HTTP.text "cancelled"
  let openSource : ContextAsync FastHTTP.AsyncStream.Source := do
    if mode == "deferred-open" then Std.Async.sleep 30
    bump stats id fun c => { c with opened := c.opened + 1 }
    let index ← IO.mkRef 0
    let count := number req "x-count" 1
    let bytes := if req.body.isEmpty then
        (String.ofList (List.replicate (number req "x-size" 1024) 's')).toUTF8
      else req.body
    return {
      next := do
        bump stats id fun c => { c with pulls := c.pulls + 1 }
        if mode == "wait-stream" then
          ContextAsync.awaitCancellation
          bump stats id fun c => { c with cancelled := c.cancelled + 1 }
          return none
        let i ← index.get
        if i == count then return none
        index.set (i + 1)
        if mode == "error" && i == 1 then throw (IO.userError "producer failure")
        if mode == "empty" then return some .empty
        return some bytes
      close := bump stats id fun c => { c with closed := c.closed + 1 } }
  let response ← if mode.startsWith "sse" then do
      let openEvents : ContextAsync FastHTTP.SSE.Source := do
        bump stats id fun c => { c with opened := c.opened + 1 }
        let index ← IO.mkRef 0
        return {
          next := do
            bump stats id fun c => { c with pulls := c.pulls + 1 }
            let i ← index.get
            index.set (i + 1)
            if mode == "sse-idle" then
              ContextAsync.awaitCancellation
              bump stats id fun c => { c with cancelled := c.cancelled + 1 }
              return none
            if i == 2 then return none
            if mode == "sse-delayed" && i == 0 then Std.Async.sleep 120
            return some {
              data := if i == 0 then String.fromUTF8! req.body else "vége"
              event := some "message"
              id := some (if mode == "sse-bad" then "bad\nid" else if i == 0 then
                (req.header? "last-event-id").getD "0" else "1")
              retry := some 1000 }
          close := bump stats id fun c => { c with closed := c.closed + 1 } }
      pure (HTTP.sse openEvents 30)
    else pure (HTTP.stream openSource)
  if mode == "bad-header" then return response.withHeader "x-invalid" "bad\r\nvalue"
  if mode == "no-body-status" then return response.withStatus .noContent
  return response.withStatus .created

private def router (stats : Stats) : App.Router :=
  (App.empty
    |>.addRoute (route GET "/" => "streaming-test")
    |>.addRoute (route GET "/stats/{id}" (id : Path String) => do
      return ← stats.atomically do return (← get)[id.value]?.getD {})
    |>.addRoute (route GET "/case/{id}" (req : FastHTTP.Request) (id : Path String) =>
      handle stats id.value req)
    |>.addRoute (route POST "/case/{id}" (req : FastHTTP.Request) (id : Path String) =>
      handle stats id.value req))
    |>.addMiddleware (App.mapResponse fun response => pure (response.withHeader "x-middleware" "stream"))

def main (args : List String) : IO Unit := do
  let port := (args[0]?.getD "18211").toNat!.toUInt16
  let threads := (args[1]?.getD "1").toNat!.toUInt32
  let stats ← Std.Mutex.new ({} : Std.HashMap String Counts)
  let workers ← App.serve { port, threads, idleTimeoutMs := 1000 }
    (fun _ => pure (router stats))
  for worker in workers do IO.println (repr worker)
  IO.sleep 50
  for id in ["shutdown-stream", "shutdown-handler"] do
    let value ← stats.atomically do return (← get)[id]?.getD {}
    IO.println s!"FINAL {id} {(Lean.toJson value).compress}"
