module

import Std.Async.ContextAsync
public import FastLeanIO.Router.Route

namespace FastLeanIO
open Std.Http Std.Async

public inductive FromRequestPartsError where
| syntax_error (msg: String) -- 400 bad request
| semantic_error (msg: String) -- 422 unprocessable entity
| io_error (e: IO.Error) -- 500 internal server error

public def FromRequestPartsError.toStatus : FromRequestPartsError → Status
  | .syntax_error _ => Status.badRequest
  | .semantic_error _ => Status.unprocessableEntity
  | .io_error _ => Status.internalServerError

public instance : ToString FromRequestPartsError where
  toString
  | .syntax_error msg => msg
  | .semantic_error msg => msg
  | .io_error e => e.toString

public instance : MonadLift (Except String) (Except FromRequestPartsError) where
  monadLift
    | .ok x => .ok x
    | .error e => .error (.semantic_error e)

public class FromPath (α : Type) where
  fromPath : Std.HashMap String String → Except String α

public instance: FromPath (Std.HashMap String String) where
  fromPath h := .ok h

public class FromString (α : Type) where
  parse: String → Except String α

public instance : FromString String where
  parse s := .ok s

public instance : FromString Nat where
  parse s := match s.toNat? with
    | some n => .ok n
    | none => .error s!"Impossible to parse {s} as a Nat"

public instance : FromString Int where
  parse s := match s.toInt? with
    | some n => .ok n
    | none => .error s!"Impossible to parse {s} as a Int"

public instance : FromString Bool where
  parse s := match s with
    | "true" => .ok true
    | "false" => .ok false
    | _ => .error s!"Impossible to parse {s} as a Bool"

public structure Path (α : Type) where
  value : α

public structure Query (α : Type) where
  value: α

public class FromQuery (α : Type) where
  fromQuery : URI.Query → Except String α


end FastLeanIO
