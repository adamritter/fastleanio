import Std
import FastHTTP.SSE

namespace FastLeanIO.Standards

/-- RFC 2046 §5.1.1 bcharsnospace, used by RFC 7578 §4.1. -/
def boundaryChar (byte : UInt8) : Bool :=
  let n := byte.toNat
  (48 ≤ n && n ≤ 57) || (65 ≤ n && n ≤ 90) || (97 ≤ n && n ≤ 122) ||
    [39,40,41,43,95,44,45,46,47,58,61,63].contains byte

def validBoundary (bytes : List UInt8) : Bool :=
  !bytes.isEmpty && bytes.length ≤ 70 &&
    bytes.all (fun b => b == 32 || boundaryChar b) &&
    bytes.getLast?.any boundaryChar

/-- RFC 2046 §5.1.1 boundary line suffix, without optional transport padding.
Inspect at most four following bytes; `--` alone is the closing boundary at EOF. -/
def delimiterTail (bytes : List UInt8) : Bool :=
  bytes.take 2 == [13, 10] || bytes == [45,45] || bytes.take 4 == [45,45,13,10]

/-- RFC 6750 §2.1 b64token alphabet (padding is allowed only at the end). -/
def bearerChar (byte : UInt8) : Bool :=
  let n := byte.toNat
  (48 ≤ n && n ≤ 57) || (65 ≤ n && n ≤ 90) || (97 ≤ n && n ≤ 122) ||
    [45,46,95,126,43,47].contains byte

def validBearer (bytes : List UInt8) : Bool :=
  let raw := bytes.takeWhile bearerChar
  !raw.isEmpty && (bytes.dropWhile bearerChar).all (· == 61)

/-- RFC 4648 §4 standard base64 alphabet; the URL-safe alphabet is distinct. -/
def base64Char (byte : UInt8) : Bool :=
  let n := byte.toNat
  (48 ≤ n && n ≤ 57) || (65 ≤ n && n ≤ 90) || (97 ≤ n && n ≤ 122) ||
    byte == 43 || byte == 47

def validBasicEncoding (bytes : List UInt8) : Bool :=
  let raw := bytes.takeWhile base64Char
  let padding := bytes.dropWhile base64Char
  !raw.isEmpty && bytes.length % 4 == 0 && padding.length ≤ 2 && padding.all (· == 61)

/-- RFC 7617 §2 forbids CTL in either decoded credential component. -/
def validCredential (bytes : List UInt8) : Bool :=
  bytes.all fun b => 32 ≤ b.toNat && b.toNat != 127

/-- RFC 9110 §14.1.2 inclusive integer byte range. -/
def closedSelection (size first last : Nat) : Except Unit (Nat × Nat) :=
  if first ≥ size || last < first then .error ()
  else .ok (first, min last (size - 1) - first + 1)

def suffixSelection (size suffix : Nat) : Except Unit (Nat × Nat) :=
  if suffix == 0 || size == 0 then .error ()
  else .ok (size - min suffix size, min suffix size)

/-- RFC 9110 §14.2: GET only; ignore Range on empty representations (permitted).
Our file validators are weak, and therefore cannot satisfy If-Range (§13.1.5). -/
def applyFileRange (method : String) (size : Nat) (hasIfRange : Bool) : Bool :=
  method == "GET" && size > 0 && !hasIfRange

/-- HTML §9.2.5/9.2.6: an event/id field must not inject a new line; IDs exclude NUL.
The actual encoder's shared guard is used directly. -/
def validSSEField := FastHTTP.SSE.singleLine

end FastLeanIO.Standards
