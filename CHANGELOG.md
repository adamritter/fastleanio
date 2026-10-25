# 0.1.0

- Forked and renamed LeanIO as FastLeanIO, with FastHTTP as the only server backend and package dependency.
- Retained sync handlers, lazy async cancellation scopes, routing, extractors, certified responses, streaming and SSE.
- Added typed forms, bounded binary multipart uploads, explicit-destination upload saving, streaming files with ETag and single ranges, Basic/Bearer auth, structured logging and typed state.
- Added locked Express/Multer and Axum/Tower applications, fresh socket validation and per-response-validated benchmarks.
- Added normative standards snapshots, executable rules, general Lean proofs and an offline axiom/provenance audit.

## Negative results and corrections retained

The first UTF-8 form roundtrip test exposed loss of a literal plus sign through the inherited URI query encode/decode path. An intermediate blanket `+` escape changed spaces instead. The final API therefore stores decoded form fields directly and uses a dedicated, proved production codec. The proof additionally establishes agreement with WHATWG's ordered replacement/percent-decoding algorithm; the earlier transport proofs did not cover this application-layer behavior.

Standards review exposed a too-permissive multipart boundary alphabet, loss of quoted trailing spaces, missing Basic credential control-character checks, and Range processing on HEAD. These were corrected and covered by the corresponding rules/proofs and regressions. A subsequent range-parser change briefly treated an open-ended range beyond EOF as malformed instead of unsatisfiable; fresh cross-framework tests caught it and the parser now distinguishes an omitted last position from an explicit reversed range.

The first Express fixture returned 500 on malformed multipart input; the fixture now maps parser failures to 400 and size limits to 413. The Axum file wrapper needed explicit weak-ETag If-Range handling. Both baseline applications suppress Range on non-GET requests for the matched contract. These are application adapters, not claims that the underlying frameworks have been formally verified.
