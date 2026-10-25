# FastLeanIO / Express / Axum benchmark

Measured on 2026-10-25T10:09:49Z on Lambda GH200 / Neoverse-V2 (aarch64). Source checkpoint: `e59102d2d7e0e7fce3401092bb3dbd928108e680`. These are **end-to-end HTTP requests per second**, not parser microbenchmarks or estimates from raw FastHTTP throughput.

| Workload | FastLeanIO | Express 5.3.0 | Axum 0.8.9 |
|---|---:|---:|---:|
| Dynamic 1 KiB text | 75,387 | 8,597 | 104,988 |
| Mounted route + typed path | 64,530 | 8,748 | 104,546 |
| Typed query | 60,338 | 8,804 | 103,746 |
| JSON extraction | 58,908 | 7,196 | 94,051 |
| URL-encoded typed form | 57,886 | 6,952 | 98,093 |
| Binary multipart, 1 KiB file | 28,456 | 5,225 | 73,416 |
| Bearer authentication | 68,307 | 8,721 | 100,364 |
| Basic authentication | 62,478 | 8,386 | 100,126 |
| In-memory access logging | 76,659 | 8,549 | 104,612 |
| Streamed 64 KiB file | 3,045 | 3,822 | 12,318 |
| 1 KiB range at offset 256 | 3,033 | 4,327 | 3,654 |
| Finite SSE: four events | 6,336 | 8,566 | 94,233 |
| 2 ms asynchronous wait | 6,336 | 9,637 | 18,000 |

Numbers are medians of three measured runs. SSE measures completed four-event responses, not long-lived client capacity. Static files use chunked streaming in FastLeanIO and the respective baseline file services; framing differs while payload bytes, status and middleware behavior are checked.

## Protocol and validation

Each server process and all of its threads were restricted to CPU 16. The wrk clients used two threads, 64 keep-alive connections, and affinity 24-31. Each workload had 2 seconds of validated warmup and 5 measured seconds per repetition. Framework order rotated between repetitions. The same freshly generated workload inputs were used for each framework in a repetition.

Fresh pre-benchmark correctness cases: {'fastleanio': 258, 'express': 242, 'axum': 242}. Every timed response was checked for exact status, full body and the middleware header: **25,245,808 measured responses, zero mismatches and zero socket errors**. Warmups separately validated 10,139,384 responses. Source/binary hashes were identical before and after the run. No server endpoint returns a request-dependent precomputed benchmark answer.

The source and binary hashes, random seed, compiler versions, individual rates, server CPU utilization, raw wrk output and exact Lua validators are in [the result directory](results/express-axum-final). The client binary hash is recorded. Rust uses the release profile with thin LTO; Node uses production mode; Lean uses the checked-in toolchain. `LEAN_NUM_THREADS=1` and `UV_THREADPOOL_SIZE=1`; all runtime/helper threads remain inside the same one-CPU affinity. Files are reopened/read per request with a warmed OS cache. Dynamic ETag hashing is disabled for Express because the other applications do not do it; static ETags remain enabled. Logging uses an in-memory counter sink, not disk/stdout writes.

## What the results show

FastLeanIO's immediate request path is substantially faster than this Express application. Axum remains faster in this comparison. FastLeanIO's file, suspended-handler and streaming paths have a much larger remaining cost than its immediate handlers; they must not be described by a blanket “100k/core” number.

There is a concrete transport bottleneck: the pinned lean_uv reactor checks pending wakeups on a 10 ms timer (`vendor/lean_uv/native/uv.c`, `on_tick` and `uv_timer_start(..., 10, 10)`). With 64 connections, a route that awaits once can approach a roughly 6,400/s polling ceiling even if the underlying wait is only 2 ms. This is a source-supported explanation for the delayed-route result, not a separately isolated causal benchmark. File I/O also crosses the pending path; nonzero file offsets currently require bounded skip reads because the portable Std handle has no seek API. The zero-unused-scope theorem concerns immediate handlers and does not remove these scheduling costs.

This is one host, one concurrency setting and a small application contract. It does not establish general framework rankings, production capacity, cold-start performance, TLS/database performance, or Express ecosystem parity. Compare repeated-run ranges below, rather than treating a median as an exact constant.

## Repeated-run ranges

| Workload | Framework | Min / median / max requests/s | Median server CPU |
|---|---|---:|---:|
| Dynamic 1 KiB text | fastleanio | 74,579 / 75,387 / 76,898 | 99.8% |
| Dynamic 1 KiB text | express | 8,333 / 8,597 / 8,614 | 100.0% |
| Dynamic 1 KiB text | axum | 102,770 / 104,988 / 108,850 | 99.9% |
| Mounted route + typed path | fastleanio | 62,989 / 64,530 / 65,049 | 99.5% |
| Mounted route + typed path | express | 8,685 / 8,748 / 8,985 | 99.9% |
| Mounted route + typed path | axum | 99,545 / 104,546 / 105,843 | 99.7% |
| Typed query | fastleanio | 57,753 / 60,338 / 61,632 | 99.9% |
| Typed query | express | 8,747 / 8,804 / 9,008 | 100.0% |
| Typed query | axum | 101,365 / 103,746 / 104,475 | 99.9% |
| JSON extraction | fastleanio | 58,553 / 58,908 / 61,060 | 99.9% |
| JSON extraction | express | 7,192 / 7,196 / 7,303 | 99.9% |
| JSON extraction | axum | 86,336 / 94,051 / 95,336 | 100.0% |
| URL-encoded typed form | fastleanio | 54,307 / 57,886 / 60,819 | 99.5% |
| URL-encoded typed form | express | 6,946 / 6,952 / 7,027 | 100.0% |
| URL-encoded typed form | axum | 89,889 / 98,093 / 98,839 | 99.9% |
| Binary multipart, 1 KiB file | fastleanio | 25,067 / 28,456 / 29,305 | 99.9% |
| Binary multipart, 1 KiB file | express | 5,108 / 5,225 / 5,233 | 99.9% |
| Binary multipart, 1 KiB file | axum | 72,239 / 73,416 / 73,916 | 99.8% |
| Bearer authentication | fastleanio | 63,107 / 68,307 / 70,353 | 99.8% |
| Bearer authentication | express | 8,609 / 8,721 / 8,778 | 99.6% |
| Bearer authentication | axum | 99,214 / 100,364 / 103,731 | 99.6% |
| Basic authentication | fastleanio | 57,447 / 62,478 / 64,785 | 99.6% |
| Basic authentication | express | 8,272 / 8,386 / 8,389 | 100.0% |
| Basic authentication | axum | 100,023 / 100,126 / 104,533 | 99.7% |
| In-memory access logging | fastleanio | 71,827 / 76,659 / 77,619 | 99.5% |
| In-memory access logging | express | 8,445 / 8,549 / 8,716 | 99.8% |
| In-memory access logging | axum | 101,896 / 104,612 / 106,026 | 100.0% |
| Streamed 64 KiB file | fastleanio | 3,037 / 3,045 / 3,153 | 23.0% |
| Streamed 64 KiB file | express | 3,788 / 3,822 / 3,868 | 99.8% |
| Streamed 64 KiB file | axum | 12,156 / 12,318 / 12,786 | 99.7% |
| 1 KiB range at offset 256 | fastleanio | 3,032 / 3,033 / 3,169 | 23.1% |
| 1 KiB range at offset 256 | express | 4,162 / 4,327 / 4,416 | 100.0% |
| 1 KiB range at offset 256 | axum | 3,518 / 3,654 / 3,745 | 27.9% |
| Finite SSE: four events | fastleanio | 6,324 / 6,336 / 6,362 | 48.7% |
| Finite SSE: four events | express | 8,445 / 8,566 / 8,658 | 100.1% |
| Finite SSE: four events | axum | 93,202 / 94,233 / 96,006 | 100.0% |
| 2 ms asynchronous wait | fastleanio | 6,290 / 6,336 / 6,336 | 15.7% |
| 2 ms asynchronous wait | express | 9,364 / 9,637 / 9,772 | 94.8% |
| 2 ms asynchronous wait | axum | 17,981 / 18,000 / 18,027 | 18.9% |

## Reproduce

```sh
lake build
npm ci --prefix bench/express
cargo build --release --locked --manifest-path bench/axum/Cargo.toml
python3 bench/check.py --output results/reproduction --benchmark --seconds 5 --warmup-seconds 2 --repeats 3
```

Use the recorded source commit and lockfiles. Adjust CPU affinity and `--wrk` for your machine. A new run uses a fresh random seed; the exact old requests and expected responses are preserved in the recorded Lua files. The full framework surface, limits and proof coverage are in [README.md](README.md) and [standards/README.md](standards/README.md).
