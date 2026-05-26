# Proxy load-sweep benchmark

Illustrative numbers - re-run `benchmark/workload_bench/run.py` to produce your own.

- Target: `https://google.com` (HEAD), through the in-path nginx proxy
- Per-step duration: 5s; concurrency swept over [25, 50, 100, 200, 400, 800]
- Estimated data-processing cost this run: **$0.1772** (ANF $0.065/GB + NAT $0.045/GB)

| concurrency | rps | p50 ms | p95 ms | p99 ms | requests |
|---:|---:|---:|---:|---:|---:|
| 25 | 1380.0 | 16.2 | 24.1 | 31.0 | 6900 |
| 50 | 2610.0 | 18.4 | 30.5 | 42.7 | 13050 |
| 100 | 3820.0 | 25.1 | 44.8 | 63.2 | 19100 |
| 200 | 4410.0 | 44.0 | 78.5 | 112.0 | 22050 |
| 400 | 4520.0 | 87.6 | 162.3 | 233.0 | 22600 |
| 800 | 4380.0 | 181.2 | 340.7 | 498.0 | 21900 |
