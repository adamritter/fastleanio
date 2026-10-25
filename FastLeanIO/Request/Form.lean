module

import Lean
import Std.Async.ContextAsync
public import Std.Internal.Parsec.ByteArray
public import FastLeanIO.Request.FromRequestBody
public import FastLeanIO.Data.Headers.MimeType

namespace FastLeanIO
open Std.Http Std.Async MimeType
open Std Internal Parsec ByteArray Char
/-!
# URL-encoded Form Body Extraction

`Form α` + `FromForm α` parse `application/x-www-form-urlencoded` bodies into typed structs.
For buffered multipart forms, see `FastLeanIO.Forms`.
-/

public structure Form (α : Type) where
  value : α

/-- Form fields are already decoded, exactly once. -/
public class FromForm (α : Type) where
  fromForm : Std.HashMap String String → Except String α

public instance : FromForm (Std.HashMap String String) := ⟨Except.ok⟩
end FastLeanIO
