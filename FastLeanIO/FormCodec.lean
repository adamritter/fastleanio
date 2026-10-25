import Std
import Std.Http.Data.URI.Encoding

/-! The production form component codec. Decoding is strict and happens once.
The encoder deliberately percent-encodes every byte; it is canonical and simple
rather than a URL pretty-printer. The tail-recursive decoder also accepts raw
bytes and `+` for spaces, as required by URL-encoded forms. -/
namespace FastLeanIO.FormCodec

def hexDigit (n : Nat) : UInt8 :=
  UInt8.ofNat (if n < 10 then n + 48 else n + 55)

def hexValue (byte : UInt8) : Option Nat :=
  let n := byte.toNat
  if 48 ≤ n && n ≤ 57 then some (n - 48)
  else if 65 ≤ n && n ≤ 70 then some (n - 55)
  else if 97 ≤ n && n ≤ 102 then some (n - 87)
  else none

def hexPair (a b : UInt8) : Option UInt8 := do
  return UInt8.ofNat ((← hexValue a) * 16 + (← hexValue b))

def encodeByte (byte : UInt8) : List UInt8 :=
  [37, hexDigit (byte.toNat / 16), hexDigit (byte.toNat % 16)]

def encodeList (bytes : List UInt8) : List UInt8 := bytes.flatMap encodeByte

def decodeRev : List UInt8 → List UInt8 → Option (List UInt8)
  | [], acc => some acc.reverse
  | byte :: rest, acc =>
    if byte == 43 then decodeRev rest (32 :: acc)
    else if byte == 37 then
      match rest with
      | a :: b :: tail => do
        let value ← hexPair a b
        decodeRev tail (value :: acc)
      | _ => none
    else decodeRev rest (byte :: acc)

/-- WHATWG URL §1.3: malformed percent escapes are copied literally. -/
def percentDecode (bytes : List UInt8) : List UInt8 :=
  match bytes with
  | [] => []
  | byte :: rest =>
    if byte == 37 then
      match h : rest with
      | a :: b :: tail =>
        match hexPair a b with
        | some value => value :: percentDecode tail
        | none => byte :: percentDecode rest
      | _ => byte :: percentDecode rest
    else byte :: percentDecode rest

termination_by bytes.length
decreasing_by all_goals simp_all <;> omega

/-- WHATWG URL §5.1 step 3.4 is performed before percent decoding (step 3.5). -/
def replacePlus (byte : UInt8) : UInt8 := if byte == 43 then 32 else byte

def standardDecode (bytes : List UInt8) : List UInt8 :=
  percentDecode (bytes.map replacePlus)

def encodeBytes (bytes : ByteArray) : ByteArray :=
  (encodeList bytes.data.toList).toByteArray

def decodeBytes (bytes : ByteArray) : Option ByteArray :=
  (decodeRev bytes.data.toList []).map List.toByteArray

def decodeTextBytes (input : ByteArray) : Except String String := do
  let some bytes := decodeBytes input | throw "invalid percent encoding"
  let some text := String.fromUTF8? bytes | throw "invalid UTF-8"
  return text

/-- Both wire parsing and the public decoder use this exact function. -/
def decodeComponent (input : String) : Except String String :=
  decodeTextBytes input.toUTF8

end FastLeanIO.FormCodec
