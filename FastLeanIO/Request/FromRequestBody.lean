module

public import Lean
public import Std.Async.ContextAsync
public import FastLeanIO.Data.Headers.MimeType

namespace FastLeanIO
open Std.Http Std.Async Lean MimeType

public inductive FromRequestBodyError where
| bad_media_error (msg: String) -- 415 unsupported media type
| syntax_error (msg: String) -- 400 bad request
| semantic_error (msg: String) -- 422 unprocessable entity
| io_error (e: IO.Error) -- 500 internal server error

public def FromRequestBodyError.toStatus : FromRequestBodyError → Status
  | .bad_media_error _ => Status.unsupportedMediaType
  | .syntax_error _ => Status.badRequest
  | .semantic_error _ => Status.unprocessableEntity
  | .io_error _ => Status.internalServerError

public instance : ToString FromRequestBodyError where
  toString
  | .bad_media_error msg => msg
  | .syntax_error msg => msg
  | .semantic_error msg => msg
  | .io_error e => e.toString

public structure Json (α : Type) where
  body : α
public structure PlainText where
  body : String
end FastLeanIO
