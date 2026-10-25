# FastLeanIO / Express / Axum benchmark

Measured on 2026-10-25T10:52:44Z on Lambda GH200 / Neoverse-V2 (aarch64). Source checkpoint: `95437e6ea0729e348055eaac906074affded7b73`. These are **end-to-end HTTP requests per second**, not parser microbenchmarks or estimates from raw FastHTTP throughput.

| Workload | FastLeanIO | Express 5.3.0 | Axum 0.8.9 |
|---|---:|---:|---:|
| Dynamic 1 KiB text | 76,828 | 8,495 | 103,186 |
| Mounted route + typed path | 64,863 | 8,749 | 104,513 |
| Typed query | 59,193 | 8,680 | 102,508 |
| JSON extraction | 62,694 | 7,152 | 92,003 |
| URL-encoded typed form | 58,252 | 6,923 | 95,008 |
| Binary multipart, 1 KiB file | 34,106 | 5,139 | 72,429 |
| Bearer authentication | 67,292 | 8,542 | 104,781 |
| Basic authentication | 63,745 | 8,175 | 101,783 |
| In-memory access logging | 77,749 | 8,696 | 103,858 |
| Streamed 64 KiB file | 3,136 | 3,881 | 12,474 |
| 1 KiB range at offset 256 | 3,046 | 4,374 | 3,579 |
| Finite SSE: four events | 21,855 | 8,707 | 92,965 |
| 2 ms asynchronous wait | 6,345 | 9,509 | 17,951 |

## SSE and multipart before/after

Both checkpoints used the same machine, workload definitions, affinity, connection count, warmup and timing protocol. Each checkpoint used fresh generated inputs. The earlier raw results remain in [the pre-optimization directory](results/express-axum-final). These are repeated end-to-end comparisons, not an isolated attribution of every individual change.

| Workload | Before | Optimized | Ratio |
|---|---:|---:|---:|
| Finite SSE: four events | 6,336 | 21,855 | 3.45× |
| Binary multipart, 1 KiB file | 28,456 | 34,106 | 1.20× |

SSE opening now preserves ready IO instead of creating an unnecessary task. Immediately ready events are coalesced into bounded batches, and single-line data avoids multiline normalization. A pending event never delays a ready batch. Multipart uses byte-specialized KMP and fewer header allocations. No endpoint payload or checksum work was removed.


Numbers are medians of three measured runs. SSE measures completed four-event responses, not long-lived client capacity. Static files use chunked streaming in FastLeanIO and the respective baseline file services; framing differs while payload bytes, status and middleware behavior are checked.

## Protocol and validation

Each server process and all of its threads were restricted to CPU 16. The wrk clients used two threads, 64 keep-alive connections, and affinity 24-31. Each workload had 2 seconds of validated warmup and 5 measured seconds per repetition. Framework order rotated between repetitions. The same freshly generated workload inputs were used for each framework in a repetition.

Fresh pre-benchmark correctness cases: {'fastleanio': 258, 'express': 242, 'axum': 242}. Every timed response was checked for exact status, full body and the middleware header: **25,808,084 measured responses, zero mismatches and zero socket errors**. Warmups separately validated 10,351,357 responses. Source/binary hashes were identical before and after the run. No server endpoint returns a request-dependent precomputed benchmark answer.

The source and binary hashes, random seed, compiler versions, individual rates, server CPU utilization, raw wrk output and exact Lua validators are in [the result directory](results/express-axum-optimized). The client binary hash is recorded. Rust uses the release profile with thin LTO; Node uses production mode; Lean uses the checked-in toolchain. `LEAN_NUM_THREADS=1` and `UV_THREADPOOL_SIZE=1`; all runtime/helper threads remain inside the same one-CPU affinity. Files are reopened/read per request with a warmed OS cache. Dynamic ETag hashing is disabled for Express because the other applications do not do it; static ETags remain enabled. Logging uses an in-memory counter sink, not disk/stdout writes.

## What the results show

FastLeanIO's immediate request path is substantially faster than this Express application. Axum remains faster in this comparison. FastLeanIO's file, suspended-handler and streaming paths have a much larger remaining cost than its immediate handlers; they must not be described by a blanket “100k/core” number.

The ready SSE path no longer crosses the timer just to open a source. Genuine asynchronous waits retain a transport bottleneck: the pinned lean_uv reactor checks pending wakeups on a 10 ms timer (`vendor/lean_uv/native/uv.c`, `on_tick` and `uv_timer_start(..., 10, 10)`). With 64 connections, a route that awaits once can approach a roughly 6,400/s polling ceiling even if the underlying wait is only 2 ms. This is a source-supported explanation for the delayed-route result, not a separately isolated causal benchmark. The finite SSE comparison does not measure delayed-event latency or a long-lived subscription workload. File I/O also crosses the pending path; nonzero file offsets currently require bounded skip reads because the portable Std handle has no seek API. The zero-unused-scope theorem concerns immediate handlers and does not remove these scheduling costs.

This is one host, one concurrency setting and a small application contract. It does not establish general framework rankings, production capacity, cold-start performance, TLS/database performance, or Express ecosystem parity. Compare repeated-run ranges below, rather than treating a median as an exact constant.

## Repeated-run ranges

| Workload | Framework | Min / median / max requests/s | Median server CPU |
|---|---|---:|---:|
| Dynamic 1 KiB text | fastleanio | 76,730 / 76,828 / 84,080 | 99.9% |
| Dynamic 1 KiB text | express | 8,286 / 8,495 / 8,594 | 100.0% |
| Dynamic 1 KiB text | axum | 102,143 / 103,186 / 103,347 | 99.8% |
| Mounted route + typed path | fastleanio | 63,106 / 64,863 / 66,896 | 99.8% |
| Mounted route + typed path | express | 8,588 / 8,749 / 8,862 | 100.0% |
| Mounted route + typed path | axum | 100,812 / 104,513 / 104,587 | 99.8% |
| Typed query | fastleanio | 57,956 / 59,193 / 60,167 | 99.7% |
| Typed query | express | 8,634 / 8,680 / 8,989 | 99.9% |
| Typed query | axum | 102,373 / 102,508 / 104,655 | 99.5% |
| JSON extraction | fastleanio | 59,760 / 62,694 / 63,011 | 99.5% |
| JSON extraction | express | 6,985 / 7,152 / 7,285 | 100.0% |
| JSON extraction | axum | 91,548 / 92,003 / 92,600 | 99.9% |
| URL-encoded typed form | fastleanio | 56,105 / 58,252 / 59,789 | 99.9% |
| URL-encoded typed form | express | 6,858 / 6,923 / 6,980 | 100.0% |
| URL-encoded typed form | axum | 94,976 / 95,008 / 99,077 | 99.9% |
| Binary multipart, 1 KiB file | fastleanio | 32,889 / 34,106 / 34,734 | 99.7% |
| Binary multipart, 1 KiB file | express | 5,040 / 5,139 / 5,171 | 100.1% |
| Binary multipart, 1 KiB file | axum | 71,883 / 72,429 / 73,403 | 99.5% |
| Bearer authentication | fastleanio | 66,771 / 67,292 / 68,353 | 99.8% |
| Bearer authentication | express | 8,472 / 8,542 / 8,748 | 99.9% |
| Bearer authentication | axum | 100,550 / 104,781 / 105,192 | 99.8% |
| Basic authentication | fastleanio | 63,278 / 63,745 / 64,982 | 99.9% |
| Basic authentication | express | 8,174 / 8,175 / 8,418 | 100.0% |
| Basic authentication | axum | 100,984 / 101,783 / 103,974 | 99.8% |
| In-memory access logging | fastleanio | 75,070 / 77,749 / 80,719 | 99.9% |
| In-memory access logging | express | 8,659 / 8,696 / 8,705 | 100.1% |
| In-memory access logging | axum | 100,246 / 103,858 / 106,536 | 99.9% |
| Streamed 64 KiB file | fastleanio | 3,040 / 3,136 / 3,157 | 25.0% |
| Streamed 64 KiB file | express | 3,833 / 3,881 / 3,959 | 99.8% |
| Streamed 64 KiB file | axum | 12,207 / 12,474 / 12,730 | 99.9% |
| 1 KiB range at offset 256 | fastleanio | 3,043 / 3,046 / 3,118 | 23.7% |
| 1 KiB range at offset 256 | express | 4,346 / 4,374 / 4,452 | 100.0% |
| 1 KiB range at offset 256 | axum | 3,426 / 3,579 / 3,651 | 26.5% |
| Finite SSE: four events | fastleanio | 20,928 / 21,855 / 23,967 | 100.0% |
| Finite SSE: four events | express | 8,667 / 8,707 / 8,711 | 100.0% |
| Finite SSE: four events | axum | 92,216 / 92,965 / 97,279 | 99.9% |
| 2 ms asynchronous wait | fastleanio | 6,344 / 6,345 / 6,351 | 16.3% |
| 2 ms asynchronous wait | express | 9,448 / 9,509 / 9,631 | 94.3% |
| 2 ms asynchronous wait | axum | 17,893 / 17,951 / 18,038 | 19.4% |

## Reproduce

```sh
lake build
npm ci --prefix bench/express
cargo build --release --locked --manifest-path bench/axum/Cargo.toml
python3 bench/check.py --output results/reproduction --benchmark --seconds 5 --warmup-seconds 2 --repeats 3
```

Use the recorded source commit and lockfiles. Adjust CPU affinity and `--wrk` for your machine. A new run uses a fresh random seed; the exact old requests and expected responses are preserved in the recorded Lua files. The full framework surface, limits and proof coverage are in [README.md](README.md) and [standards/README.md](standards/README.md).
