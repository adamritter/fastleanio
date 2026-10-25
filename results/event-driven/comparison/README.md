# Initial frozen comparison and retained network-setting diagnostic

This completed 126-run checkpoint is unchanged and all responses passed.
FastLeanIO and Express measurements are retained in the final report. Axum used
its TCP listener default (Nagle enabled), unlike FastHTTP and Node HTTP. Its
new delayed SSE case showed approximately 41 ms median latency and 1.5k/s.
These Axum rows are diagnostic and are not used in the corrected comparison.
All 14 Axum workloads are rerun in ../axum-nodelay with TCP_NODELAY enabled.
FastLeanIO and Express source/executables are unchanged; their hashes are
checked against the corrected checkpoint, which also runs fresh correctness.
