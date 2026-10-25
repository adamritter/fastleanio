import FastLeanIO.Standards.Rules

namespace FastLeanIO.Standards

set_option maxRecDepth 8192 in
theorem boundaryChar_ascii : ∀ n : Fin 256,
    boundaryChar (UInt8.ofNat n.val) = true → n.val < 128 := by decide

set_option maxRecDepth 8192 in
theorem boundaryChar_no_framing : ∀ n : Fin 256,
    boundaryChar (UInt8.ofNat n.val) = true → n.val ≠ 13 ∧ n.val ≠ 10 ∧ n.val ≠ 32 := by decide

theorem validBoundary_size (bytes : List UInt8) (h : validBoundary bytes = true) :
    0 < bytes.length ∧ bytes.length ≤ 70 := by
  simp [validBoundary] at h
  constructor
  · have := h.1.1.1; cases bytes <;> simp_all
  · exact h.1.1.2

theorem validBoundary_alphabet (bytes : List UInt8) (h : validBoundary bytes = true) :
    ∀ b ∈ bytes, b = 32 ∨ boundaryChar b = true := by
  simp [validBoundary] at h
  exact h.1.2

theorem delimiterTail_exact (bytes : List UInt8) :
    delimiterTail bytes = true ↔
      bytes.take 2 = [13,10] ∨ bytes = [45,45] ∨ bytes.take 4 = [45,45,13,10] := by
  simp [delimiterTail, or_assoc]

theorem delimiter_lookalike_rejected : delimiterTail [45,45,111,111] = false := by rfl

theorem validBoundary_final_nonspace (bytes : List UInt8) (h : validBoundary bytes = true) :
    ∃ last, bytes.getLast? = some last ∧ boundaryChar last = true := by
  simp [validBoundary] at h
  cases last : bytes.getLast? with
  | none => simp [last] at h
  | some value => exact ⟨value, rfl, by simpa [last] using h.2⟩

set_option maxRecDepth 8192 in
theorem bearerChar_ascii : ∀ n : Fin 256,
    bearerChar (UInt8.ofNat n.val) = true → n.val < 128 ∧ n.val ≠ 32 ∧ n.val ≠ 61 := by decide

theorem validBearer_nonempty (bytes : List UInt8) (h : validBearer bytes = true) :
    bytes ≠ [] := by
  intro e; subst bytes; simp [validBearer] at h

/-- Exact b64token decomposition, not merely a nonempty-token check. -/
theorem validBearer_grammar (bytes : List UInt8) (h : validBearer bytes = true) :
    ∃ raw padding, bytes = raw ++ padding ∧ raw ≠ [] ∧
      (∀ b ∈ raw, bearerChar b = true) ∧ (∀ b ∈ padding, b = 61) := by
  simp [validBearer] at h
  refine ⟨bytes.takeWhile bearerChar, bytes.dropWhile bearerChar, ?_, h.1, ?_, h.2⟩
  · exact List.takeWhile_append_dropWhile.symm
  · simpa only [List.all_eq_true] using (List.all_takeWhile (l := bytes) (p := bearerChar))

theorem basicEncoding_shape (bytes : List UInt8) (h : validBasicEncoding bytes = true) :
    bytes.length % 4 = 0 ∧ ∃ raw padding, bytes = raw ++ padding ∧ raw ≠ [] ∧
      (∀ b ∈ raw, base64Char b = true) ∧ padding.length ≤ 2 ∧ (∀ b ∈ padding, b = 61) := by
  simp [validBasicEncoding] at h
  refine ⟨h.1.1.2, bytes.takeWhile base64Char, bytes.dropWhile base64Char,
    List.takeWhile_append_dropWhile.symm, h.1.1.1, ?_, h.1.2, h.2⟩
  simpa only [List.all_eq_true] using (List.all_takeWhile (l := bytes) (p := base64Char))

theorem credentials_no_control (bytes : List UInt8) (h : validCredential bytes = true) :
    ∀ b ∈ bytes, 32 ≤ b.toNat ∧ b.toNat ≠ 127 := by
  simpa [validCredential] using h

theorem closedSelection_bounds (size first last start count : Nat)
    (h : closedSelection size first last = .ok (start, count)) :
    start = first ∧ 0 < count ∧ start + count ≤ size := by
  unfold closedSelection at h
  split at h <;> simp_all
  omega

theorem closedSelection_membership (size first last start count offset : Nat)
    (h : closedSelection size first last = .ok (start, count)) :
    (start ≤ offset ∧ offset < start + count) ↔
      (first ≤ offset ∧ offset ≤ last ∧ offset < size) := by
  unfold closedSelection at h
  split at h <;> simp_all
  omega

theorem suffixSelection_bounds (size suffix start count : Nat)
    (h : suffixSelection size suffix = .ok (start, count)) :
    0 < count ∧ count ≤ suffix ∧ start + count = size := by
  unfold suffixSelection at h
  split at h <;> simp_all
  omega

theorem suffixSelection_membership (size suffix start count offset : Nat)
    (h : suffixSelection size suffix = .ok (start, count)) :
    (start ≤ offset ∧ offset < start + count) ↔
      (offset < size ∧ size - offset ≤ suffix) := by
  unfold suffixSelection at h
  split at h <;> simp_all
  omega

theorem range_ignored_non_get (method : String) (size : Nat) (validator : Bool)
    (h : method ≠ "GET") : applyFileRange method size validator = false := by
  simp [applyFileRange, h]

theorem range_ignored_empty (method : String) (validator : Bool) :
    applyFileRange method 0 validator = false := by simp [applyFileRange]

theorem weak_if_range_ignored (method : String) (size : Nat) :
    applyFileRange method size true = false := by simp [applyFileRange]

theorem sse_guard_no_injection (value : String) (h : validSSEField value = true) :
    value.contains '\r' = false ∧ value.contains '\n' = false ∧ value.contains '\x00' = false := by
  simpa [validSSEField, FastHTTP.SSE.singleLine, Bool.and_eq_true, and_assoc] using h

#print axioms boundaryChar_ascii
#print axioms boundaryChar_no_framing
#print axioms validBoundary_size
#print axioms validBoundary_alphabet
#print axioms validBoundary_final_nonspace
#print axioms delimiterTail_exact
#print axioms delimiter_lookalike_rejected
#print axioms bearerChar_ascii
#print axioms validBearer_nonempty
#print axioms validBearer_grammar
#print axioms basicEncoding_shape
#print axioms credentials_no_control
#print axioms closedSelection_bounds
#print axioms closedSelection_membership
#print axioms suffixSelection_bounds
#print axioms suffixSelection_membership
#print axioms range_ignored_non_get
#print axioms range_ignored_empty
#print axioms weak_if_range_ignored
#print axioms sse_guard_no_injection
end FastLeanIO.Standards
