import FastLeanIO.FormCodec
import Std.Data.HashMap.Lemmas

namespace FastLeanIO.FormCodec

set_option maxRecDepth 8192 in
set_option maxHeartbeats 2000000 in
theorem hexPair_all_bytes : ∀ n : Fin 256,
    hexPair (hexDigit (n.val / 16)) (hexDigit (n.val % 16)) = some (UInt8.ofNat n.val) := by
  decide

theorem hexPair_encodeByte (byte : UInt8) :
    hexPair (hexDigit (byte.toNat / 16)) (hexDigit (byte.toNat % 16)) = some byte := by
  have h := hexPair_all_bytes ⟨byte.toNat, byte.toNat_lt⟩
  simpa using h

theorem decodeRev_encodeList (bytes acc : List UInt8) :
    decodeRev (encodeList bytes) acc = some (acc.reverse ++ bytes) := by
  induction bytes generalizing acc with
  | nil => simp [encodeList, decodeRev]
  | cons byte rest ih =>
    simp [encodeList, List.flatMap_cons, encodeByte, decodeRev, hexPair_encodeByte]
    simpa [encodeList, List.reverse_cons, List.append_assoc] using ih (byte :: acc)

theorem decodeBytes_encodeBytes (bytes : ByteArray) :
    decodeBytes (encodeBytes bytes) = some bytes := by
  simp only [decodeBytes, encodeBytes, List.toList_data_toByteArray, decodeRev_encodeList]
  simp only [List.reverse_nil, List.nil_append, Option.map_some, Option.some.injEq]
  apply ByteArray.ext
  apply Array.toList_inj.mp
  simp

theorem decodeTextBytes_encodeUTF8 (text : String) :
    decodeTextBytes (encodeBytes text.toUTF8) = .ok text := by
  simp only [decodeTextBytes, decodeBytes_encodeBytes]
  simp [String.fromUTF8?, String.toUTF8, text.isValidUTF8, String.fromUTF8]
  rfl

theorem hexValue_replacePlus (byte : UInt8) : hexValue (replacePlus byte) = hexValue byte := by
  by_cases h : byte = 43
  · subst byte; decide
  · simp [replacePlus, h]

theorem hexPair_replacePlus (a b : UInt8) : hexPair (replacePlus a) (replacePlus b) = hexPair a b := by
  simp [hexPair, hexValue_replacePlus]

/-- Refinement: every accepted production decode agrees with the independently
staged WHATWG algorithm. Rejection of malformed escapes is a framework policy. -/
theorem accepted_agrees_with_standard (bytes acc output : List UInt8)
    (accepted : decodeRev bytes acc = some output) :
    output = acc.reverse ++ standardDecode bytes := by
  fun_induction decodeRev bytes acc <;>
    simp_all [decodeRev, standardDecode, percentDecode, replacePlus, List.reverse_cons, List.append_assoc,
      hexPair_replacePlus]
  · conv => rhs; unfold percentDecode
    simp
  · rename_i byte acc a b tail hb ih
    have hp := hexPair_replacePlus a b
    simp only [replacePlus, beq_iff_eq] at hp
    rw [hp]
    cases pair : hexPair a b with
    | none => simp [pair] at accepted
    | some value =>
      simp only [pair, Option.bind_some] at accepted
      simp only [pair]
      exact ih value accepted
  · conv => rhs; unfold percentDecode
    simp_all

-- Exact regressions are kernel theorems about the production function.
theorem literal_plus : decodeComponent "%2B" = .ok "+" := by rfl
theorem form_space : decodeComponent "+" = .ok " " := by rfl
theorem percent_once : decodeComponent "%252B" = .ok "%2B" := by rfl
theorem lowercase_hex : decodeComponent "%2b" = .ok "+" := by rfl
theorem malformed_percent : decodeComponent "%GG" = .error "invalid percent encoding" := by rfl

#print axioms hexPair_all_bytes
#print axioms hexPair_encodeByte
#print axioms decodeRev_encodeList
#print axioms decodeBytes_encodeBytes
#print axioms decodeTextBytes_encodeUTF8
#print axioms accepted_agrees_with_standard
#print axioms literal_plus
#print axioms form_space
#print axioms percent_once
#print axioms lowercase_hex
#print axioms malformed_percent

end FastLeanIO.FormCodec
