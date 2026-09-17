# UTUVO Type benchmark report — M0 baseline

Run date: 2026-08-21

Command:

```text
./scripts/run-benchmark.sh
```

Deterministic local path (P1): **30/30 fixtures passed**. The report is
`benchmarks/report.json`; it records 10 required categories and marks P2–P5
as pending because no cloud request, model download, or fabricated provider
measurement is allowed in M0.

Pending real-provider paths:

- P2: local ASR adapter + Bailian streaming ASR + qwen3.7-flash
- P3: Bailian formatter fallback chain
- P4: local ASR + small local editor
- P5: local ASR + explicit local 27B Deep mode

Latency, P50/P95, list accuracy, meaning preservation, hallucination rate,
Traditional Chinese accuracy, timeout rate, and fallback success rate must be
collected from timestamped runs on each path. No M0 number is evidence for a
cloud or 27B path.
