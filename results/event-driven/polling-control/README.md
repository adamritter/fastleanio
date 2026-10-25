# Old polling-core control

Reproduction base: FastLeanIO d6f5323046b509ce6270679297be3d9935566897,
FastHTTP 7b9db51c3b029990d6ea9046b09c9cd0770f84a5. Apply source.patch to
add the same delayed SSE endpoint and workload selector as the new evaluation.
The feature server source is identical to the new version; the dependency is
kept at its old revision. Results record actual source/binary hashes, fresh
inputs, all response validators and all three repeats. Only FastLeanIO ran;
Express/Axum binary hashes present in metadata are unused harness inventory.
