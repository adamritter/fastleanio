import FastLeanIO.App
import FastLeanIO.Router.Macro

open Lean FastLeanIO.Router

syntax "route " method str extractorBinder* "=>" term : term
syntax "sync_route " method str extractorBinder* "=>" term : term

macro_rules
  | `(route $method:method $pat:str $bs:extractorBinder* => $body:term) => do
    let some source := method.raw.reprint | Macro.throwErrorAt method "missing method"
    expandRouteTermWith ``FastLeanIO.App.extractAsync
      (← `(FastLeanIO.App.Route))
      (resolveMethodCon (Name.mkSimple source.trimAscii.toString)) pat bs body ``FastHTTP.Action
  | `(sync_route $method:method $pat:str $bs:extractorBinder* => $body:term) => do
    let some source := method.raw.reprint | Macro.throwErrorAt method "missing method"
    expandRouteTermWith ``FastLeanIO.App.extractSync
      (← `(FastLeanIO.App.Route))
      (resolveMethodCon (Name.mkSimple source.trimAscii.toString)) pat bs body ``IO

syntax method str extractorBinder* "=>" term : term
macro_rules
  | `($method:method $pat:str $bs:extractorBinder* => $body:term) => do
    let some source := method.raw.reprint | Macro.throwErrorAt method "missing method"
    expandRouteTermWith ``FastLeanIO.App.extractAsync
      (← `(FastLeanIO.App.Route))
      (resolveMethodCon (Name.mkSimple source.trimAscii.toString)) pat bs body ``FastHTTP.Action
