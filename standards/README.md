# Normative sources and proof coverage

The complete, unmodified standards snapshots are in `sources/`. `manifest.json` records their origin URLs, retrieval timestamps, byte lengths, HTTP validators where available, and SHA-256 hashes. Original copyright and license notices are retained; these documents are not relicensed by FastLeanIO's MIT license. `scripts/fetch_standards.py` explicitly refreshes the snapshots. Ordinary builds and audits are offline.

The formalization is **a documented subset of these standards**, not a claim of complete RFC or browser conformance. Each property below refers to a definition used by the running framework. Tests of sockets, foreign code and the filesystem are separately labeled.

| Source / section | Formalized property | Runtime connection | Remaining scope |
|---|---|---|---|
| [WHATWG URL](https://url.spec.whatwg.org/#application/x-www-form-urlencoded), §1.3, §5.1 | `accepted_agrees_with_standard`: every successful production decode equals the reference algorithm that replaces input `+` with space **before** percent decoding. `decodeBytes_encodeBytes` for every byte array; `decodeTextBytes_encodeUTF8` for every Lean string. Exact `+`, `%2B`, `%252B`, lowercase-hex and malformed-input theorems. | `decodeFormComponent` directly calls `FormCodec.decodeComponent`; `decodeForm` stores decoded names/values once, with no encode/decode roundtrip. | Whole form field splitting, hash-map insertion, typed application extraction and resource limits have regression tests, not an end-to-end parser theorem. The encoder percent-escapes every byte; it is a valid form component encoder, not the exact pretty/canonical serializer of §5.2. |
| [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986.html#section-2.1), §2.1 | `hexPair_all_bytes`, `hexPair_encodeByte`: the percent triplet recovers every possible octet. Hex decoding supports upper/lowercase. | The real component parser uses `hexPair`. | No claim to formalize the entire URI/IRI standard. |
| [RFC 7578](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.1), §4.1–4.2; [RFC 2046](https://www.rfc-editor.org/rfc/rfc2046.html#section-5.1.1), §5.1.1 | Boundary alphabet, ASCII/framing exclusions, nonempty length ≤70, allowed final character; exact boundary-line suffix alternatives and rejection of a closing-boundary lookalike. | `parseMultipart` calls `Standards.validBoundary` and `Standards.delimiterTail` before accepting a delimiter. | KMP search, quoted parameter parsing, payload slices and full MIME multipart grammar are tested, not fully verified. This bounded subset rejects preambles/epilogues and transport padding; charset conversion and nested multipart/mixed are not implemented. Parts preserve raw bytes and repeated names. |
| [RFC 4648](https://www.rfc-editor.org/rfc/rfc4648.html#section-4), §4; [RFC 7617](https://www.rfc-editor.org/rfc/rfc7617.html#section-2), §2 | `basicEncoding_shape`: alphabet prefix, at most two trailing padding characters, multiple-of-four length. `credentials_no_control`: decoded credentials exclude CTL. | `basicAuth` checks both predicates before invoking its validator; it uses first-colon separation and advertises UTF-8 in its challenge. | The inherited Base64 decoder itself has no general inverse proof. UTF-8 normalization, credential storage, password hashing and validator policy are application concerns. |
| [RFC 6750](https://www.rfc-editor.org/rfc/rfc6750.html#section-2.1), §2.1 | `validBearer_grammar`: an accepted token decomposes into a nonempty b64token alphabet prefix followed only by `=` padding. | `bearerAuth` invokes this recognizer before the application validator. | This is header bearer authentication, not an OAuth authorization server, token issuer, TLS proof or scope policy. |
| [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#section-14), §14.1.2, §14.2, §13.1.5 | General closed/suffix range bounds and exact byte-membership equivalences; non-GET/empty-representation suppression; weak-validator If-Range fallback. Natural-number arithmetic cannot overflow fixed-width machine integers. | `byteRange` uses `closedSelection`/`suffixSelection`; `StaticFiles.respond` uses `applyFileRange`. | Header tokenization, ETag-list parsing, metadata races, OS reads and the entire response lifecycle are not proved by these arithmetic theorems. Empty files ignore Range (permitted by §14.2). |
| [WHATWG HTML](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream), §9.2.5–9.2.6 | `sse_guard_no_injection`: the real encoder's event/id guard excludes CR, LF and NUL. | `Standards.validSSEField` is an alias of `FastHTTP.SSE.singleLine`, which `Event.encode` uses. | This proves field admission, not the entire browser EventSource state machine. Data newline encoding, heartbeat, backpressure and cleanup have socket tests. |

## Strict form policy versus the URL Standard

WHATWG percent decoding preserves malformed escapes, and its UTF-8 algorithm can replace invalid sequences. FastLeanIO deliberately rejects malformed escapes and invalid UTF-8; duplicate decoded field names are rejected by typed form extraction. These are explicit stricter server policies. The refinement theorem is conditional on the **actual decoder succeeding**, and proves agreement for all such inputs. No oracle or input-dependent candidate filtering is used in tests or benchmarks.

The reference algorithm and executable decoder are separate: the former makes the normative two-stage ordering explicit, and the latter performs one tail-recursive pass. A roundtrip proof alone would not establish conformance, because an incorrect encoder and incorrect decoder could agree with each other. The refinement theorem addresses that gap.

## Audit and trust boundary

Run:

```sh
lake build
python3 scripts/verify_standards.py
```

The audit verifies every downloaded source hash and enumerates all theorem declarations in the four framework proof modules, including the retained integration proofs. It asks Lean for each theorem's transitive axioms and rejects anything outside `propext`, `Classical.choice`, and `Quot.sound`. Proof sources containing `sorry`, `admit` or `native_decide` fail the audit. Finite byte cases use kernel-checked `decide`; generalized sequence and arithmetic properties use induction and kernel-checked tactics.

The trusted boundary still includes Lean's kernel/compiler/runtime, the linked libuv/C transport, and operating-system behavior. Passing this audit does not establish that all framework code is bug-free. The precise distinction between proved and tested behavior above is part of the result.
