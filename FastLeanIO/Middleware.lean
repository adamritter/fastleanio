import FastLeanIO.App
import FastLeanIO.Utils

namespace FastLeanIO
open App HTTP Std.Async

/-- Errors are mapped before serialization; do not expose exception details to clients. -/
def catchErrors (onError : IO.Error → IO Unit := fun _ => pure ()) : App.Middleware :=
  App.around fun next req => do
    try next req catch e =>
      onError e
      return (HTTP.text "Internal Server Error").withStatus .internalServerError

structure RequestLog where
  method : String
  target : String
  status : Nat
  elapsedNanos : Nat

/-- Measures handler completion, not stream lifetime. The caller controls the sink. -/
def requestLogger (sink : RequestLog → IO Unit) : App.Middleware :=
  App.around fun next req => do
    let start ← IO.monoNanosNow
    let response ← next req
    let elapsed := (← IO.monoNanosNow) - start
    sink { method := req.http.method, target := req.http.target, status := response.data.status, elapsedNanos := elapsed }
    return response

private def credentials (req : HTTP.Request) (scheme : String) : Option String := do
  let auth ← req.http.header? "authorization"
  let parts := auth.splitOn " "
  unless parts.length == 2 && parts.head!.toLower == scheme do none
  let token := parts[1]!
  unless !token.isEmpty do none
  return token

private def unauthorized (scheme : String) : HTTP.Response :=
  ((HTTP.text "Unauthorized").withStatus .unauthorized).withHeader "www-authenticate" (scheme ++ " realm=\"Restricted Area\"")

/-- The validator owns credential storage and policy. No credentials enter logs. -/
def bearerAuth (validate : Redacted → FastHTTP.Action Bool) : App.Middleware :=
  App.around fun next req => do
    let some token := credentials req "bearer" | return unauthorized "Bearer"
    unless ← validate ⟨token⟩ do return unauthorized "Bearer"
    next req

def basicAuth (validate : String → Redacted → FastHTTP.Action Bool) : App.Middleware :=
  App.around fun next req => do
    let some token := credentials req "basic" | return unauthorized "Basic"
    -- Reject malformed padding rather than accepting arbitrary '=' placement.
    let raw := token.dropEndWhile (· == '=') |>.toString
    unless token.length % 4 == 0 && token.length - raw.length ≤ 2 &&
        raw.toList.all (fun c => c.isAlphanum && c.toNat < 128 || c == '+' || c == '/') do
      return unauthorized "Basic"
    let some decoded := Utils.base64DecodeString token | return unauthorized "Basic"
    let some (user, password) := decoded.splitOnce ':' | return unauthorized "Basic"
    unless ← validate user.toString ⟨password.toString⟩ do return unauthorized "Basic"
    next req

/-- Typed application state. Allocate shared state outside the per-worker router factory. -/
def withExtension [TypeName α] (value : α) : App.Middleware :=
  App.around fun next req => next { req with extensions := req.extensions.insert value }

structure Extension (α : Type) where
  value : α

instance [TypeName α] : HTTP.FromParts (Extension α) := ⟨fun req => do
  match req.extensions.get α with
  | some value => return ⟨value⟩
  | none => throw (.semantic_error "missing application state")⟩

end FastLeanIO
