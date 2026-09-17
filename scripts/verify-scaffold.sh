#!/usr/bin/env bash
# UTUVO Type — scaffold verifier (M0)
#
# 不寫秘密、不聯網、不動 repo 以外檔案。失敗一律 exit 非 0。
# 用法：./scripts/verify-scaffold.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FAIL=0

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; FAIL=1; }

log "[verify] repo: $REPO_ROOT"

# 1. fixtures 必須存在 + 恰好 30 行 + 全部 JSON 合法 + 必要 category 覆蓋
FIXTURES="$REPO_ROOT/benchmarks/cases.jsonl"
if [[ ! -f "$FIXTURES" ]]; then
    err "missing $FIXTURES"
else
    LINE_COUNT=$(wc -l < "$FIXTURES" | tr -d ' ')
    if [[ "$LINE_COUNT" != "30" ]]; then
        err "cases.jsonl must have exactly 30 lines, got $LINE_COUNT"
    fi
    if ! jq -c . "$FIXTURES" >/dev/null 2>&1; then
        err "cases.jsonl has invalid JSON"
    fi
    # 必要 10 個 category
    PRESENT=$(jq -r '.category' "$FIXTURES" | sort -u)
    REQUIRED=(short-dictation mixed-zh-en proper-noun self-correction list-cue todo long-paragraph meeting-notes selection-edit markdown)
    for cat in "${REQUIRED[@]}"; do
        if ! grep -qx "$cat" <<<"$PRESENT"; then
            err "missing required category: $cat"
        fi
    done
    # 每個 category 至少 3 題
    COUNTS=$(jq -r '.category' "$FIXTURES" | sort | uniq -c | awk '{print $1" "$2}')
    while read -r count cat; do
        if [[ "$count" -lt 3 ]]; then
            err "category $cat has only $count cases (need >= 3)"
        fi
    done <<<"$COUNTS"
    # 不准出現 forbidden output token
    if grep -q '<think>' "$FIXTURES"; then
        err "fixtures contain <think> token"
    fi
    if grep -q '</think>' "$FIXTURES"; then
        err "fixtures contain </think> token"
    fi
    if grep -q '```' "$FIXTURES"; then
        err "fixtures contain triple-backtick code fence"
    fi
    if grep -q 'JSON' "$FIXTURES"; then
        err "fixtures contain JSON literal"
    fi
fi

# 2. example configs 不含真實金鑰
for f in "$REPO_ROOT"/config/*.example.json; do
    [[ -f "$f" ]] || continue
    if grep -q 'sk-' "$f"; then err "$f contains sk- prefix"; fi
    if grep -q 'Bearer ' "$f"; then err "$f contains Bearer token"; fi
    if grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f"; then
        err "$f contains email literal"
    fi
    if grep -q 'hooks.slack.com' "$f"; then err "$f contains slack webhook"; fi
    if grep -q 'script.google.com' "$f"; then err "$f contains Apps Script webhook"; fi
done

# 3. prompt 範本必須包含輸出政策，但不能真的放入 code fence 結構。
PROMPT="$REPO_ROOT/prompts/formatter-v1.txt"
if [[ ! -f "$PROMPT" ]]; then
    err "missing $PROMPT"
else
    if grep -q '```' "$PROMPT"; then err "$PROMPT contains triple backtick"; fi
    if ! grep -q '不要輸出分析、推理、JSON、Markdown code fence 或 <think> 標籤。' "$PROMPT"; then
        err "$PROMPT is missing the required output policy"
    fi
fi

# 4. Swift build + test + native app product
log "[verify] swift build"
if ! swift build >/dev/null 2>&1; then
    err "swift build failed"
    swift build
else
    log "[verify] swift build: ok"
fi

log "[verify] native app product"
if ! swift build --product utuvo-type >/dev/null 2>&1; then
    err "native app product failed"
else
    log "[verify] native app product: ok"
fi

log "[verify] swift test"
if ! swift test 2>&1 | tee "$REPO_ROOT/.verify-test.log" >/dev/null; then
    err "swift test failed (see .verify-test.log)"
fi

# 5. 整體結果
if [[ $FAIL -ne 0 ]]; then
    err "verify-scaffold FAILED"
    exit 1
fi
log "[verify] OK"
exit 0
