# Benchmark summary

Illustrative numbers — re-run `benchmark/run.py` to produce your own.

- Target: `https://google.com` (HEAD)
- Estimated data-processing cost this run: **$0.0021** (ANF $0.065/GB + NAT $0.045/GB)

## Latency probe (low concurrency)

| scenario | p50 ms | p95 ms | p99 ms | rps |
|---|---:|---:|---:|---:|
| proxy | 18.4 | 31.2 | 47.5 | 215.0 |
| baseline | 14.1 | 24.8 | 39.7 | 280.3 |

**Added latency (proxy − baseline):** p50 +4.3 ms, p95 +6.4 ms, p99 +7.8 ms

## Max RPS (high concurrency)

| scenario | rps | p95 ms |  p99 ms |
|---|---:|---:|---:|
| proxy | 1842.7 | 48.1 | 71.0 |
| baseline | 2310.5 | 39.2 | 58.4 |
