#!/usr/bin/env bash
# UTUVO Type — benchmark runner (M0)
#
# 只跑 deterministic 路徑（P1）；P2–P5 固定為 "pending"。
# 不聯網、不需要 API key。
# 用法：./scripts/run-benchmark.sh
#
# 產出：benchmarks/report.json

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FIXTURES="$REPO_ROOT/benchmarks/cases.jsonl"
REPORT="$REPO_ROOT/benchmarks/report.json"

if [[ ! -f "$FIXTURES" ]]; then
    echo "ERROR: missing $FIXTURES" >&2
    exit 2
fi

echo "[run-benchmark] fixtures: $FIXTURES"
echo "[run-benchmark] report:   $REPORT"

# SwiftPM 執行期 cwd 已是 repo root；明確傳 fixtures/output 避免依賴預設。
swift run utuvo-bench \
    --fixtures "$FIXTURES" \
    --output "$REPORT"

# 報告 sanity：必須有 fixtureCount=30 與 pendingPaths 列出 P2..P5。
COUNT=$(jq -r '.fixtureCount' "$REPORT")
if [[ "$COUNT" != "30" ]]; then
    echo "ERROR: report fixtureCount=$COUNT (expected 30)" >&2
    exit 1
fi

for p in P2 P3 P4 P5; do
    IN_PENDING=$(jq -r --arg p "$p" '.pendingPaths | index($p) // empty' "$REPORT")
    if [[ -z "$IN_PENDING" ]]; then
        echo "ERROR: pendingPaths missing $p" >&2
        exit 1
    fi
done

PASSED=$(jq -r '.byPath.P1.summary.passed' "$REPORT")
TOTAL=$(jq -r '.byPath.P1.summary.total' "$REPORT")
PASS_RATE=$(jq -r '.byPath.P1.summary.passRate' "$REPORT")
echo "[run-benchmark] P1 deterministic: $PASSED/$TOTAL passed (passRate=$PASS_RATE)"

# Pass rate 必須 100% 在 M0（fixtures 與 normalizer 對齊過）。
if [[ "$PASSED" != "$TOTAL" ]]; then
    echo "ERROR: deterministic pass rate is not 100% (got $PASSED/$TOTAL)" >&2
    exit 1
fi

echo "[run-benchmark] OK"
