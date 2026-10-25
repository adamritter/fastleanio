import FastLeanIO.App
import FastLeanIO.HTTPProofs

namespace FastLeanIO.App

theorem plan_buffered (response : Response) (h : response.data.stream = none) :
    plan (.ready response) = .buffered response := by simp [plan, h]

theorem plan_stream (response : Response) (source : Std.Async.ContextAsync FastHTTP.AsyncStream.Source)
    (h : response.data.stream = some source) :
    plan (.ready response) = .scoped (pure response) := by simp [plan, h]

theorem plan_scoped (run : Std.Async.ContextAsync Response) :
    plan (.scoped run) = .scoped run := rfl

/-- The unused scope factory is absent from the executed buffered computation. -/
theorem execute_buffered (response : Response) (limit : Nat)
    (factory : IO Std.CancellationContext) :
    execute (.buffered response) limit factory = (do
      return .ready (← IO.ofExcept ((response.prepareBounded limit).mapError IO.userError))) := rfl

theorem buffered_factory_independent (response : Response) (limit : Nat)
    (first second : IO Std.CancellationContext) :
    execute (.buffered response) limit first = execute (.buffered response) limit second := rfl

/-- Immediate buffered responses retain the existing certified constructor. -/
theorem ready_buffered_certified (response : Response) (limit : Nat)
    (factory : IO Std.CancellationContext) (h : response.data.stream = none)
    (within : response.data.body.size ≤ limit) :
    execute (plan (.ready response)) limit factory = (do
      return .ready (← IO.ofExcept (response.data.prepare.mapError IO.userError))) := by
  rw [plan_buffered response h, execute_buffered, HTTP.prepareBounded_within response limit within]

theorem middleware_preserves_sync (change : Response → IO Response) (run : SyncHandler) :
    mapResponse change (.sync run) = .sync (fun req => do change (← run req)) := rfl

end FastLeanIO.App

#print axioms FastLeanIO.App.plan_buffered
#print axioms FastLeanIO.App.plan_stream
#print axioms FastLeanIO.App.plan_scoped
#print axioms FastLeanIO.App.execute_buffered
#print axioms FastLeanIO.App.buffered_factory_independent
#print axioms FastLeanIO.App.ready_buffered_certified
#print axioms FastLeanIO.App.middleware_preserves_sync
