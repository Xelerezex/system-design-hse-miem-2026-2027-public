# HW1 V2: reproducible comparison (k6, 30 iterations/s, 60 s)

| Variant | Run | Paid | Checks | HTTP errors | Dropped | Hold p50 ms | Hold p95 ms | Hold p99 ms | Order p99 ms | Pay p99 ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| base | 1 | 1801 | 1.000 | 0.0000 | 0 | 3.38 | 4.57 | 5.84 | 7.35 | 318.12 |
| base | 2 | 1801 | 1.000 | 0.0000 | 0 | 3.42 | 4.67 | 6.03 | 7.39 | 317.09 |
| base | 3 | 1801 | 1.000 | 0.0000 | 0 | 3.48 | 4.56 | 5.92 | 7.06 | 318.09 |
| opt1 | 1 | 1801 | 1.000 | 0.0000 | 0 | 3.40 | 5.92 | 15.42 | 14.29 | 353.70 |
| opt1 | 2 | 1800 | 1.000 | 0.0000 | 0 | 3.41 | 6.38 | 15.44 | 14.45 | 353.70 |
| opt1 | 3 | 1800 | 1.000 | 0.0000 | 0 | 3.55 | 6.29 | 16.56 | 14.63 | 353.59 |
| opt2 | 1 | 1801 | 1.000 | 0.0000 | 0 | 3.27 | 4.46 | 5.80 | 7.92 | 318.83 |
| opt2 | 2 | 1801 | 1.000 | 0.0000 | 0 | 3.24 | 4.28 | 5.75 | 7.38 | 318.22 |
| opt2 | 3 | 1800 | 1.000 | 0.0000 | 0 | 3.30 | 4.45 | 5.63 | 7.41 | 317.80 |

## Medians across independent runs

| Variant | Runs | Hold p99 median ms | Order p99 median ms | Pay p99 median ms |
|---|---:|---:|---:|---:|
| base | 3 | 5.92 | 7.35 | 318.09 |
| opt1 | 3 | 15.44 | 14.45 | 353.70 |
| opt2 | 3 | 5.75 | 7.41 | 318.22 |

Baseline hold p99 median: 5.918 ms.
opt1 hold p99 median change from base: +160.9% (worse).
opt2 hold p99 median change from base: -2.8% (better).

> These values measure end-to-end HTTP latency under a FIXED arrival rate; they do not establish maximum throughput or causal effects by themselves.
> A partial index that makes p99 worse is an unsuccessful optimization for this workload.
