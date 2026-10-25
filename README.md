# FastLeanIO

A Lean 4 web framework built on **FastHTTP**. This is a breaking fork of LeanIO: FastHTTP is the default and only server backend, and LeanIO is no longer a package dependency.

```lean
import FastLeanIO
open FastLeanIO

def main : IO Unit := do
  let _ ← serve { port := 8080, threads := 1 } fun _ => pure (
    empty
      |>.addRoute (GET "/hello/{name}" (name : Path String) => do
        return s!"hello {name.value}")
      |>.addRoute (POST "/echo" (body : PlainText) => do
        return body.body))
  pure ()
```

`GET`/`POST`/... handlers use `Action`: ordinary IO and completed asynchronous operations can finish without allocating a cancellation scope. A real wait, explicit context access, or streaming response acquires a scope. `sync_route GET ...` selects an explicit `IO` handler without an async envelope. Cancellation is cooperative; this is not a claim of zero allocations or zero scheduling overhead for all asynchronous work.

## Build and run

Install Lean using the checked-in `lean-toolchain`, plus the system libuv development package (`libuv1-dev` on Ubuntu).

```sh
lake build
mkdir -p bench/data
lake exe feature_server 8080 bench/data
lake exe feature_checks
python3 scripts/verify_standards.py
lake exe action_checks 12345
```

The only Lake dependency is the pinned `adamritter/lean-fasthttp` revision in `lakefile.toml`. Its vendored lean_uv transport does not depend on LeanIO. `FeatureServer.lean` is a runnable example of the features below, including middleware, subrouters and typed extractors.

## Implemented

| Feature | API / behavior |
|---|---|
| Routing | Validated method macros; trie dispatch; literals, typed parameters and final rest capture; mounted subrouters; HEAD fallback; 404/405 and Allow |
| Extraction | `Path`, `Query`, `Json`, `PlainText`, bytes; deriving `FromPath`, `FromQuery`, `FromForm`; custom `FromParts`/`FromBody` |
| Responses | Text, bytes, JSON via `ToJson`, status pairs, headers, certified prepared responses invalidated by mutation |
| Middleware | Sync-preserving `mapResponse`, general `around`, `catchErrors`, `withExtension` and typed `Extension` state |
| Forms | Typed URL-encoded forms; strict UTF-8/percent decoding; spaces and literal plus signs preserved; duplicate fields rejected; 128-field default limit |
| Multipart | Binary buffered parts, quoted boundary/filename parameters, configurable byte/part/header limits, `MultipartPart.saveTo` to an application-selected destination |
| Files | Streaming regular files, MIME types, weak metadata ETag, If-None-Match, single byte ranges, suffix/open ranges, 416, HEAD, cache headers |
| Authentication | Basic/Bearer middleware with application-provided `Action Bool` validators; redacted credentials; 401 challenges |
| Logging | Structured method/target/status/handler-duration record and application-provided sink |
| Streaming / SSE | Pull-based response streaming, backpressure, cancellation, exactly-once cleanup, SSE events/IDs/retry/heartbeat, bounded ready-event batching |
| Async | Immediate, suspended and synchronous handlers; exception recovery; finally cleanup; cancellation scopes shared within one request and isolated across requests |

### Deliberate limits

- Requests are buffered by FastHTTP, with a default 1 MiB transport limit. Multipart defaults independently to 1 MiB, 128 parts and 8 KiB of headers per part. **These are bounded buffered uploads, not incremental request-body streaming.** `saveTo` writes the already-buffered bytes; it never trusts a client filename as a destination.
- Responses can stream without accumulating the whole file. Filesystem operations run on the Lean task pool. The portable Std file API lacks seek, so a nonzero range offset is skipped in bounded chunks; large offsets cost extra reads. Single ranges are supported; malformed/multiple ranges are ignored and return the full file. Weak ETags cannot satisfy If-Range, so those requests return the full representation. There is no multipart/byteranges response or Last-Modified conditional support.
- `StaticFiles.create` canonicalizes a deployment-owned root. Dotfiles, traversal and symlinks escaping that root are rejected. The tree must not be concurrently modified by an untrusted writer: this API is not an `openat`-based filesystem sandbox. Keep application-selected upload destinations separate from the served asset tree. File headers use chunked streaming where appropriate; HEAD need not include Content-Length.
- Logging measures handler completion, not the entire streamed response lifetime. A slow user-supplied sink can affect requests.
- There is no claim of Express ecosystem parity. Session stores, cookies, OAuth, templates, compression, CORS, WebSockets and HTTP/2 are not bundled in this release. TLS termination can be handled by a reverse proxy.

## Breaking migration

Replace `import LeanIO` / `LeanIOFastHTTP.*` with `import FastLeanIO`. Use `FastLeanIO.empty`, the method macros, and `FastLeanIO.serve` with a `LeanUV.TCP.Config`. There is no Std.Http server entry point. `FromForm` receives **already-decoded fields** in `Std.HashMap String String`; do not decode them a second time. The former generic router is retained under `FastLeanIO.Router.Router H`, while `FastLeanIO.Router` names the FastHTTP application router.

## Validation and proof scope

`lake build` checks the retained 18 integration theorems and the new standards-derived codec/grammar/range theorems and builds the feature and lifecycle regressions. The pinned FastHTTP revision retains its existing protocol proof audit. The integration proofs cover certified response preparation, bounded buffered responses, Action completion decisions and sync-preserving middleware. The additional standards proofs and their exact limits are mapped in [standards/README.md](standards/README.md). They do **not** prove the whole multipart parser, filesystem behavior, authentication policies or arbitrary application code correct.

`feature_checks` covers 8,000 fresh search comparisons with an independent exhaustive matcher, ready SSE opening, strict form decoding, binary multipart delimiter lookalikes, quoted filenames, all multipart limits, exact saved upload bytes, and 162,792 closed/suffix range cases. `action_checks` exercises 32 lifecycle iterations. `streaming_check.py` runs fresh real-socket tests with one and four workers, including disconnects, late results, backpressure, heartbeat, timeout and shutdown. The cross-framework suite uses fresh random inputs and checks successful and failing requests.

## Express and Axum comparison

See [BENCHMARK.md](BENCHMARK.md) for the final measured results and limitations. The applications implement the same workloads with Express + Multer, Axum + Tower HTTP, and FastLeanIO. Dependencies are locked; Rust is built in release mode and Node runs in production mode.

```sh
npm ci --prefix bench/express
cargo build --release --locked --manifest-path bench/axum/Cargo.toml
python3 bench/check.py --output results/my-check
python3 bench/check.py --output results/my-benchmark --benchmark --seconds 5 --repeats 3
```

Defaults reserve server CPU 16 and client CPUs 24–31 on Lambda; override `--server-cpu` and `--client-cpus` for another host. Supply `--wrk` if needed. Every timed response is checked for status, middleware header and exact body; finite SSE responses are first checked semantically, then their full wire body is checked during timing. Source and binary hashes are frozen before and after each run. SSE numbers mean completed four-event responses per second, not long-lived connection capacity.

Original MIT attribution and source revisions are preserved in [ORIGIN.md](ORIGIN.md) and [LICENSE](LICENSE).

## SSE and multipart optimization

SSE opening preserves immediately completed IO. FastHTTP coalesces ready events
into batches of at most 32 pulls, stopping after reaching 16 KiB (one indivisible
event may exceed that byte limit). A pending next event does not delay buffered
events. This changes HTTP chunk boundaries, not SSE event bytes. The producer can
be read ahead by one bounded batch; cancellation and close ownership are retained.
Ordinary one-line data avoids the multiline normalization allocations.

Multipart uses byte-specialized KMP with machine-sized cursors and kernel-checked
bounds at each byte access, plus fewer header-string allocations. It remains a
bounded, buffered upload parser. The complete KMP/parser algorithm is regression
tested rather than formally verified; its RFC boundary predicates remain proved.

The pinned FastHTTP core audits 394 theorems plus four certificate factories,
including five batch-payload conservation theorems and the single-line SSE wire
form. The framework audit still checks 51 theorems and all nine standards snapshots.
Suspended handlers and SSE now wake on task completion, without periodic polling.
SSE selects completion, cancellation or the heartbeat deadline. Ten additional
core theorems cover notification state transitions; C/runtime behavior remains
covered by explicit assumptions and native sanitizer/network tests.
See [BENCHMARK.md](BENCHMARK.md) for measured results and retained controls.
