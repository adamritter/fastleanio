# FastLeanIO / Express / Axum benchmark

Measured on 2026-10-25T11:52:13Z on Lambda GH200 / Neoverse-V2 (aarch64). Corrected Axum block measured on 2026-10-25T12:09:08Z. FastLeanIO/Express checkpoint: `bbdbad638a791a49dc1c3e395f68e21348c67e84`; corrected Axum checkpoint: `d49b70cbc15dd92f8d75dfb961b767555c614edd`. FastHTTP dependency: `69e8f30075544c1d202ae5ac194ba8caccd6ceb4`. These are end-to-end completed HTTP requests per second, not parser throughput.

| Workload | FastLeanIO | Express 5.3.0 | Axum 0.8.9 |
|---|---:|---:|---:|
| Dynamic 1 KiB text | 78,357 | 8,746 | 102,910 |
| Mounted route + typed path | 67,176 | 9,043 | 101,047 |
| Typed query | 61,476 | 9,055 | 104,227 |
| JSON extraction | 58,853 | 7,295 | 100,943 |
| URL-encoded typed form | 59,021 | 7,083 | 98,472 |
| Binary multipart, 1 KiB file | 34,592 | 5,260 | 73,784 |
| Bearer authentication | 69,500 | 8,709 | 109,286 |
| Basic authentication | 64,805 | 8,237 | 104,387 |
| In-memory access logging | 76,682 | 8,474 | 102,821 |
| Streamed 64 KiB file | 11,097 | 3,795 | 12,517 |
| 1 KiB range at offset 256 | 11,804 | 4,348 | 15,107 |
| Finite SSE: four ready events | 22,145 | 8,460 | 93,320 |
| SSE: 2 ms wait, then four events | 9,995 | 7,032 | 19,581 |
| 2 ms asynchronous handler | 18,975 | 9,419 | 17,937 |

## Replacing completion polling

The old-core control uses the identical FastLeanIO feature-server source (hash equality checked), including the new delayed SSE endpoint, with FastHTTP `7b9db51c3b029990d6ea9046b09c9cd0770f84a5`. Both evaluations use the same affinity, concurrency, duration and three-repeat protocol; each uses fresh inputs. The control source patch, hashes and raw measurements are retained in [polling-control](results/event-driven/polling-control). This compares the complete dependency change, not individual internal costs.

| Workload | Polling core | Event-driven core | Ratio |
|---|---:|---:|---:|
| SSE: 2 ms wait, then four events | 3,162 | 9,995 | 3.16× |
| 2 ms asynchronous handler | 6,342 | 18,975 | 2.99× |
| Finite SSE: four ready events | 21,772 | 22,145 | 1.02× |

Task completion now explicitly wakes the owning worker. SSE selects producer completion, cancellation or an actual heartbeat deadline, with one task callback per outstanding producer. Paused-read reset detection is driven by Linux events. The 10 ms completion scan and the SSE sleep/recheck loop are gone. Idle maintenance and heartbeat timers remain. The immediately ready SSE path already bypassed polling; do not attribute its run-to-run variation to removal of a wait it never performed.

The delayed SSE case opens a response and waits 2 ms before producing four events. All three applications do the wait inside the stream (Express explicitly flushes headers); every event ID and data value is checked. This is finite-response throughput under 64 concurrent connections, not long-lived subscription capacity or isolated first-event latency.

## Matching TCP settings

The first Axum delayed-SSE run showed about 41 ms median latency and 1,544 completed responses/s. Inspection found that its TCP listener left Nagle enabled, while FastHTTP explicitly enabled TCP_NODELAY and Node HTTP defaulted to it. Axum now uses [ListenerExt.tap_io](https://docs.rs/axum/0.8.9/axum/serve/trait.ListenerExt.html) to set TCP_NODELAY on each accepted socket. All 14 Axum workloads were rerun; the original rows remain diagnostic evidence and are excluded from this table. Source/binary comparison confirms only the Axum source and executable changed between blocks. Fresh all-framework correctness at the final checkpoint is retained in [final-correctness](results/event-driven/final-correctness).

## Protocol and validation

Each server process and all its runtime/helper threads are restricted to CPU 16; clients use CPUs 24-31, two wrk threads and 64 keep-alive connections. Each workload receives 2 seconds of validated warmup and 5 measured seconds, repeated 3 times. The initial block rotated framework order and shared inputs within each repetition. After correcting Axum's socket setting, all 14 Axum workloads were rerun as a separate block with fresh inputs. The table combines unchanged FastLeanIO/Express binaries from the first block with the corrected Axum block and reports medians; time/order differences remain a limitation.

Fresh pre-benchmark correctness cases: {'fastleanio': 270, 'express': 254, 'axum': 254}. Every timed response checks exact status, full body and middleware header: **27,226,064 measured responses, zero mismatches and zero socket errors**. Warmups separately validate 10,880,209 responses. Source and binary hashes are identical before and after evaluation.

The [initial comparison directory](results/event-driven/comparison) and [corrected Axum directory](results/event-driven/axum-nodelay) contain random seeds, compiler versions, hashes, CPU utilization, individual rates, raw wrk output and exact Lua validators. Rust uses release/thin LTO; Node uses production mode; Lean uses the pinned toolchain. `LEAN_NUM_THREADS=1`, `UV_THREADPOOL_SIZE=1`, and all helper threads share the same single CPU. Files are reopened and read per request with a warm OS cache. Logging uses an in-memory counter. Dynamic ETag hashing is disabled for Express; static ETags remain enabled. Transfer framing may differ, while payload bytes and response behavior are validated.

The [streaming evaluation](results/event-driven/streaming/validation.json) covers 136 fresh cases with one and four workers: cancellation, paused-read reset, half-close, heartbeat, late completion and cleanup. The [framework audit](results/event-driven/standards/audit.json) checks 51 theorems and nine downloaded standards snapshots. FastHTTP audits 394 theorems plus four certificate factories, including ten new readiness-state transition theorems. Native C/runtime behavior remains an explicit trust boundary, tested with ASan/UBSan and post-shutdown notification floods; it is not claimed formally verified.

## Limits and retained evidence

This is one host, one concurrency setting and a small application contract. It does not establish general rankings, production capacity, TLS/database performance, cold-start performance or Express ecosystem parity. Removing polling does not make allocation, task scheduling, cancellation or stream framing cost-free, and these rates must not be replaced by a blanket 100k/core claim. Nonzero file offsets still use bounded skip reads through the portable Std file handle.

The earlier [optimized results](results/express-axum-optimized), [pre-optimization results](results/express-axum-final), and [previous report](https://github.com/adamritter/fastleanio/blob/d6f5323046b509ce6270679297be3d9935566897/BENCHMARK.md) remain available, including the negative file/async results that motivated this change. Multipart parsing and ready-event batching are unchanged in this dependency comparison.

## Repeated-run ranges

| Workload | Framework | Min / median / max requests/s | Median server CPU |
|---|---|---:|---:|
| Dynamic 1 KiB text | fastleanio | 78,319 / 78,357 / 78,375 | 99.5% |
| Dynamic 1 KiB text | express | 8,697 / 8,746 / 8,770 | 100.1% |
| Dynamic 1 KiB text | axum | 102,725 / 102,910 / 105,400 | 99.5% |
| Mounted route + typed path | fastleanio | 65,692 / 67,176 / 67,207 | 99.9% |
| Mounted route + typed path | express | 8,982 / 9,043 / 9,221 | 99.9% |
| Mounted route + typed path | axum | 101,019 / 101,047 / 104,265 | 99.5% |
| Typed query | fastleanio | 60,564 / 61,476 / 63,658 | 99.8% |
| Typed query | express | 9,003 / 9,055 / 9,163 | 99.8% |
| Typed query | axum | 102,405 / 104,227 / 105,680 | 99.9% |
| JSON extraction | fastleanio | 58,595 / 58,853 / 61,096 | 100.0% |
| JSON extraction | express | 7,249 / 7,295 / 7,368 | 99.9% |
| JSON extraction | axum | 91,494 / 100,943 / 103,276 | 99.9% |
| URL-encoded typed form | fastleanio | 58,542 / 59,021 / 60,175 | 99.9% |
| URL-encoded typed form | express | 6,887 / 7,083 / 7,162 | 99.8% |
| URL-encoded typed form | axum | 90,406 / 98,472 / 99,553 | 99.9% |
| Binary multipart, 1 KiB file | fastleanio | 33,680 / 34,592 / 34,860 | 99.8% |
| Binary multipart, 1 KiB file | express | 5,026 / 5,260 / 5,289 | 99.9% |
| Binary multipart, 1 KiB file | axum | 71,072 / 73,784 / 74,424 | 100.0% |
| Bearer authentication | fastleanio | 67,507 / 69,500 / 70,691 | 99.6% |
| Bearer authentication | express | 8,449 / 8,709 / 8,786 | 100.0% |
| Bearer authentication | axum | 106,669 / 109,286 / 109,923 | 99.9% |
| Basic authentication | fastleanio | 64,624 / 64,805 / 65,700 | 99.9% |
| Basic authentication | express | 8,120 / 8,237 / 8,430 | 100.0% |
| Basic authentication | axum | 102,297 / 104,387 / 109,019 | 99.9% |
| In-memory access logging | fastleanio | 73,624 / 76,682 / 77,680 | 99.7% |
| In-memory access logging | express | 7,874 / 8,474 / 8,525 | 99.9% |
| In-memory access logging | axum | 102,337 / 102,821 / 103,397 | 99.5% |
| Streamed 64 KiB file | fastleanio | 10,635 / 11,097 / 11,229 | 99.6% |
| Streamed 64 KiB file | express | 3,532 / 3,795 / 3,898 | 100.1% |
| Streamed 64 KiB file | axum | 12,421 / 12,517 / 12,719 | 99.9% |
| 1 KiB range at offset 256 | fastleanio | 11,566 / 11,804 / 11,959 | 99.5% |
| 1 KiB range at offset 256 | express | 4,047 / 4,348 / 4,430 | 99.9% |
| 1 KiB range at offset 256 | axum | 15,028 / 15,107 / 15,198 | 99.7% |
| Finite SSE: four ready events | fastleanio | 20,650 / 22,145 / 23,868 | 99.6% |
| Finite SSE: four ready events | express | 8,362 / 8,460 / 8,791 | 99.9% |
| Finite SSE: four ready events | axum | 91,572 / 93,320 / 96,610 | 99.9% |
| SSE: 2 ms wait, then four events | fastleanio | 9,321 / 9,995 / 10,537 | 79.1% |
| SSE: 2 ms wait, then four events | express | 6,853 / 7,032 / 7,268 | 100.0% |
| SSE: 2 ms wait, then four events | axum | 19,430 / 19,581 / 19,789 | 35.7% |
| 2 ms asynchronous handler | fastleanio | 18,264 / 18,975 / 18,989 | 55.4% |
| 2 ms asynchronous handler | express | 9,332 / 9,419 / 9,483 | 94.9% |
| 2 ms asynchronous handler | axum | 17,780 / 17,937 / 17,941 | 18.1% |

## Reproduce

```sh
lake build
npm ci --prefix bench/express
cargo build --release --locked --manifest-path bench/axum/Cargo.toml
python3 bench/check.py --output results/reproduction --benchmark --seconds 5 --warmup-seconds 2 --repeats 3
```

Use the recorded source commit and lockfiles. Adjust CPU affinity and `--wrk` for your host. A fresh random seed is generated; old requests/expected responses are retained in the Lua validators. The older polling control additionally requires its documented source patch and old FastHTTP pin.
