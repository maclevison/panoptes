#!/usr/bin/env bash
#
# Deterministic self-test for bin/panoptes. Exercises the standalone CLI
# directly (local `--diff` mode, `--format json`) against a mock OpenRouter
# server (test/mock_openrouter.py), plus the `--llm-cmd` transport, the
# fallback chain, and the fail-safe/--strict exit-code contract. No real API
# call, token cost, or network is involved.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PANOPTES="$ROOT/bin/panoptes"
FIXTURE="$HERE/fixtures/sample.diff"
PORT=8137
FALLBACK_PORT=8138
DEAD_PORT_1=8199
DEAD_PORT_2=8198
BASE_URL="http://127.0.0.1:${PORT}"
FALLBACK_URL="http://127.0.0.1:${FALLBACK_PORT}"
MODEL="mock/model"
MOCK_PID=""
TMP_EMPTY_DIFF="$(mktemp)"

fail() { echo "FAIL: $1" >&2; exit 1; }

start_mock() {
  # $1 = mode, $2 = port, sets MOCK_PID
  MOCK_MODE="$1" PORT="$2" python3 "$HERE/mock_openrouter.py" &
  MOCK_PID=$!
  local url="http://127.0.0.1:${2}"
  for _ in $(seq 1 50); do
    if curl -s -o /dev/null "$url"; then break; fi
    sleep 0.1
  done
}

stop_mock() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  MOCK_PID=""
}
trap stop_mock EXIT

# Test 1 — happy path: local --diff mode + --format json against the mock,
# asserting reviewed/important/nit counts on the fixture.
start_mock ok "$PORT"
out=$("$PANOPTES" --diff "$FIXTURE" --base-url "$BASE_URL" --model "$MODEL" --format json)
stop_mock
reviewed=$(printf '%s' "$out" | jq -r '.reviewed')
nit=$(printf '%s' "$out" | jq -r '.nit')
review_text=$(printf '%s' "$out" | jq -r '.review')
[ "$reviewed" = "true" ] || fail "happy path: expected reviewed=true, got: $out"
[ "$nit" = "0" ] || fail "happy path: expected nit=0, got: $out"
printf '%s' "$review_text" | grep -q "discount.js:2" \
  || fail "happy path: expected review to reference discount.js:2, got: $out"
echo "PASS  happy path (--diff + --format json, reviewed/nit counts correct)"

# Test 2 — non-JSON 200 body must degrade gracefully (fail-safe, exit 0,
# reviewed=false), not crash the CLI.
start_mock html "$PORT"
out=$("$PANOPTES" --diff "$FIXTURE" --base-url "$BASE_URL" --model "$MODEL" --format json)
code=$?
stop_mock
[ "$code" -eq 0 ] || fail "malformed: expected exit 0, got $code"
reviewed=$(printf '%s' "$out" | jq -r '.reviewed')
[ "$reviewed" = "false" ] || fail "malformed: expected reviewed=false, got: $out"
echo "PASS  malformed 200 body degrades gracefully"

# Test 3 — empty content must degrade gracefully.
start_mock empty "$PORT"
out=$("$PANOPTES" --diff "$FIXTURE" --base-url "$BASE_URL" --model "$MODEL" --format json)
code=$?
stop_mock
[ "$code" -eq 0 ] || fail "empty: expected exit 0, got $code"
reviewed=$(printf '%s' "$out" | jq -r '.reviewed')
[ "$reviewed" = "false" ] || fail "empty: expected reviewed=false, got: $out"
echo "PASS  empty response degrades gracefully"

# Test 4 — --llm-cmd transport: a tiny mock script reads stdin and prints a
# canned review on stdout; panoptes must read it back as the review.
llm_cmd_mock="$HERE/mock_llm_cmd.sh"
out=$("$PANOPTES" --diff "$FIXTURE" --llm-cmd "$llm_cmd_mock" --format json)
reviewed=$(printf '%s' "$out" | jq -r '.reviewed')
transport=$(printf '%s' "$out" | jq -r '.transport')
review_text=$(printf '%s' "$out" | jq -r '.review')
[ "$reviewed" = "true" ] || fail "llm-cmd: expected reviewed=true, got: $out"
[ "$transport" = "cmd" ] || fail "llm-cmd: expected transport=cmd, got: $out"
printf '%s' "$review_text" | grep -q "canned review" \
  || fail "llm-cmd: expected canned review text, got: $out"
echo "PASS  --llm-cmd transport (stdin piped, stdout read back)"

# Test 4b — an agent JSON envelope: the review lives in .response and must be
# unwrapped, not posted as raw JSON.
out=$(MOCK_CMD_MODE=envelope_ok "$PANOPTES" --diff "$FIXTURE" --llm-cmd "$llm_cmd_mock" --format json)
reviewed=$(printf '%s' "$out" | jq -r '.reviewed')
review_text=$(printf '%s' "$out" | jq -r '.review')
nit=$(printf '%s' "$out" | jq -r '.nit')
[ "$reviewed" = "true" ] || fail "envelope_ok: expected reviewed=true, got: $out"
[ "$nit" = "1" ] || fail "envelope_ok: expected nit=1, got: $out"
printf '%s' "$review_text" | grep -q "canned review" \
  || fail "envelope_ok: expected .response unwrapped, got: $out"
printf '%s' "$review_text" | grep -q "conversation_id" \
  && fail "envelope_ok: raw envelope leaked into the review, got: $out"
echo "PASS  --llm-cmd unwraps .response from an agent JSON envelope"

# Test 4c — THE fail-open: an envelope reporting status=ERROR with exit 0 must
# be a transport failure. Falling back to "raw stdout is the review" here would
# post the error blob as a clean review (reviewed=true, 0 findings) and let a
# gate pass on a review that never happened.
set +e
out=$(MOCK_CMD_MODE=envelope_error "$PANOPTES" --diff "$FIXTURE" --llm-cmd "$llm_cmd_mock" --format json)
code=$?
set -e
[ "$code" -eq 0 ] || fail "envelope_error: expected advisory exit 0, got $code"
reviewed=$(printf '%s' "$out" | jq -r '.reviewed')
[ "$reviewed" = "false" ] || fail "envelope_error: status=ERROR reported as a review: $out"
printf '%s' "$out" | jq -r '.failure.primary_error' | grep -q "Agent execution terminated" \
  || fail "envelope_error: envelope .error missing from failure, got: $out"
echo "PASS  --llm-cmd envelope status=ERROR is a failure, not a review"

# Test 4d — valid JSON with no recognized review field is a failure too, for
# the same reason: the raw object is not a review.
out=$(MOCK_CMD_MODE=envelope_bare "$PANOPTES" --diff "$FIXTURE" --llm-cmd "$llm_cmd_mock" --format json)
reviewed=$(printf '%s' "$out" | jq -r '.reviewed')
[ "$reviewed" = "false" ] || fail "envelope_bare: bare JSON reported as a review: $out"
echo "PASS  --llm-cmd JSON with no review field is a failure"

# Test 4d2 — `claude -p --output-format json`: review in .result is unwrapped;
# is_error=true (quota/auth, exit 0) is a failure, not a clean review.
out=$(MOCK_CMD_MODE=claude_ok "$PANOPTES" --diff "$FIXTURE" --llm-cmd "$llm_cmd_mock" --format json)
[ "$(printf '%s' "$out" | jq -r '.reviewed')" = "true" ] || fail "claude_ok: expected reviewed=true, got: $out"
printf '%s' "$out" | jq -r '.review' | grep -q "canned review" \
  || fail "claude_ok: expected .result unwrapped, got: $out"
out=$(MOCK_CMD_MODE=claude_error "$PANOPTES" --diff "$FIXTURE" --llm-cmd "$llm_cmd_mock" --format json)
[ "$(printf '%s' "$out" | jq -r '.reviewed')" = "false" ] || fail "claude_error: is_error reported as a review: $out"
printf '%s' "$out" | jq -r '.failure.primary_error' | grep -q "usage limit" \
  || fail "claude_error: .result missing from failure, got: $out"
out=$(MOCK_CMD_MODE=claude_subtype "$PANOPTES" --diff "$FIXTURE" --llm-cmd "$llm_cmd_mock" --format json)
[ "$(printf '%s' "$out" | jq -r '.reviewed')" = "false" ] || fail "claude_subtype: error subtype reported as a review: $out"
out=$(MOCK_CMD_MODE=nonstring "$PANOPTES" --diff "$FIXTURE" --llm-cmd "$llm_cmd_mock" --format json)
[ "$(printf '%s' "$out" | jq -r '.reviewed')" = "false" ] || fail "nonstring: non-string field reported as a review: $out"
for mode in untyped_error bare_result status_false json_array; do
  out=$(MOCK_CMD_MODE=$mode "$PANOPTES" --diff "$FIXTURE" --llm-cmd "$llm_cmd_mock" --format json)
  [ "$(printf '%s' "$out" | jq -r '.reviewed')" = "false" ] || fail "$mode: reported as a review: $out"
done
echo "PASS  --llm-cmd claude envelope fails closed (is_error, error subtype, untyped, non-string, falsey status, non-object)"

# Test 4e — a command that fails must carry its own stdout into the error, so
# the diagnosis does not require re-running it by hand.
out=$(MOCK_CMD_MODE=fail_stdout "$PANOPTES" --diff "$FIXTURE" --llm-cmd "$llm_cmd_mock" --format json)
printf '%s' "$out" | jq -r '.failure.primary_error' | grep -q "be3a6aa3-dead-beef" \
  || fail "fail_stdout: command stdout missing from the error, got: $out"
echo "PASS  --llm-cmd failure carries the command's stdout tail"

# Test 5 — fallback chain: primary points at a dead port, fallback at the
# mock. Must succeed via the fallback and report fallback_used=true.
start_mock ok "$FALLBACK_PORT"
out=$("$PANOPTES" --diff "$FIXTURE" \
  --base-url "http://127.0.0.1:${DEAD_PORT_1}" --model dead/model \
  --fallback-base-url "$FALLBACK_URL" --fallback-model "$MODEL" \
  --format json)
stop_mock
reviewed=$(printf '%s' "$out" | jq -r '.reviewed')
fallback_used=$(printf '%s' "$out" | jq -r '.fallback_used')
[ "$reviewed" = "true" ] || fail "fallback: expected reviewed=true, got: $out"
[ "$fallback_used" = "true" ] || fail "fallback: expected fallback_used=true, got: $out"
echo "PASS  fallback chain (primary down, fallback mock succeeds)"

# Test 6 — fail-safe: both primary and fallback point at dead ports.
# Default (no --strict): exit 0, reviewed=false.
set +e
out=$("$PANOPTES" --diff "$FIXTURE" \
  --base-url "http://127.0.0.1:${DEAD_PORT_1}" --model dead/model \
  --fallback-base-url "http://127.0.0.1:${DEAD_PORT_2}" --fallback-model dead/model2 \
  --format json)
code=$?
set -e
[ "$code" -eq 0 ] || fail "fail-safe: expected exit 0, got $code"
reviewed=$(printf '%s' "$out" | jq -r '.reviewed')
[ "$reviewed" = "false" ] || fail "fail-safe: expected reviewed=false, got: $out"
echo "PASS  fail-safe (both transports down, exit 0, reviewed=false)"

# Test 6b — when nothing produced a review, model/transport must be null rather
# than a mix of the fallback's model and the primary's transport, and the two
# errors must be reported per attempt.
out=$(MOCK_CMD_MODE=fail_stdout "$PANOPTES" --diff "$FIXTURE" \
  --llm-cmd "$llm_cmd_mock" \
  --fallback-base-url "http://127.0.0.1:${DEAD_PORT_2}" --fallback-model dead/model2 \
  --format json)
[ "$(printf '%s' "$out" | jq -r '.model')" = "null" ] \
  || fail "metadata: expected model=null when nothing succeeded, got: $out"
[ "$(printf '%s' "$out" | jq -r '.transport')" = "null" ] \
  || fail "metadata: expected transport=null when nothing succeeded, got: $out"
printf '%s' "$out" | jq -e '.failure.primary_error != "" and .failure.fallback_error != null' >/dev/null \
  || fail "metadata: expected both per-attempt errors in failure, got: $out"
echo "PASS  total failure reports model/transport null + per-attempt errors"

# Test 6c — a skip (empty diff) is not a failure: reviewed=false but failure
# stays null, so a consumer can tell "nothing to review" from "review died".
: > "$TMP_EMPTY_DIFF"
out=$("$PANOPTES" --diff "$TMP_EMPTY_DIFF" --llm-cmd "$llm_cmd_mock" --format json)
[ "$(printf '%s' "$out" | jq -r '.reviewed')" = "false" ] \
  || fail "empty diff: expected reviewed=false, got: $out"
[ "$(printf '%s' "$out" | jq -r '.failure')" = "null" ] \
  || fail "empty diff: a skip must not report a failure, got: $out"
echo "PASS  skip reports failure=null (distinguishable from a dead transport)"

# Test 7 — fail-safe with --strict: same setup, must exit 1.
set +e
"$PANOPTES" --diff "$FIXTURE" \
  --base-url "http://127.0.0.1:${DEAD_PORT_1}" --model dead/model \
  --fallback-base-url "http://127.0.0.1:${DEAD_PORT_2}" --fallback-model dead/model2 \
  --strict --format json >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 1 ] || fail "--strict: expected exit 1, got $code"
echo "PASS  --strict escalates the fail-safe path to exit 1"

# Test 8 — a fallback given only a --fallback-base-url must inherit the
# primary's model, not send an empty model field.
start_mock ok "$FALLBACK_PORT"
out=$("$PANOPTES" --diff "$FIXTURE" \
  --base-url "http://127.0.0.1:${DEAD_PORT_1}" --model "$MODEL" \
  --fallback-base-url "$FALLBACK_URL" \
  --format json)
stop_mock
reviewed=$(printf '%s' "$out" | jq -r '.reviewed')
used_model=$(printf '%s' "$out" | jq -r '.model')
[ "$reviewed" = "true" ] || fail "fallback inherit: expected reviewed=true, got: $out"
[ "$used_model" = "$MODEL" ] || fail "fallback inherit: expected model=$MODEL, got: $out"
echo "PASS  --fallback-base-url alone inherits the primary model"

# Tests 9/10 — --pr --comment mode, with `gh` stubbed on PATH (see mock_gh.sh).
# This is the mode review.yml runs, and the only one where panoptes shells out
# to a command that writes to stdout of its own accord.
GH_STUB_DIR="$(mktemp -d)"
cp "$HERE/mock_gh.sh" "$GH_STUB_DIR/gh"
chmod +x "$GH_STUB_DIR/gh"
COMMENT_OUT="$(mktemp)"
cleanup_pr_mode() { rm -rf "$GH_STUB_DIR" "$COMMENT_OUT" "$TMP_EMPTY_DIFF"; }
trap 'stop_mock; cleanup_pr_mode' EXIT

# Test 9 — stdout stays pure JSON in --pr --comment --format json. `gh pr
# comment` echoes the created comment's URL on stdout; if that leaks into
# panoptes' stdout, review.yml's `jq -r '.reviewed'` dies on it (exit 5) and
# fails the job on every PR — green model or not.
start_mock ok "$PORT"
out=$(PATH="$GH_STUB_DIR:$PATH" MOCK_GH_FIXTURE="$FIXTURE" MOCK_GH_COMMENT_OUT="$COMMENT_OUT" \
  "$PANOPTES" --pr 1 --repo mock/repo \
  --base-url "$BASE_URL" --model "$MODEL" \
  --show-model-footer --comment --format json 2>/dev/null)
stop_mock
printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
  || fail "pr mode: stdout is not valid JSON (gh chatter leaked?), got: $out"
reviewed=$(printf '%s' "$out" | jq -r '.reviewed')
[ "$reviewed" = "true" ] || fail "pr mode: expected reviewed=true, got: $out"
echo "PASS  --pr --comment --format json keeps stdout pure JSON"

# Test 10 — the model footer is a footer: it must come after the review body,
# not between the heading and the review.
grep -q '^_Model: ' "$COMMENT_OUT" || fail "footer: no model line in comment: $(cat "$COMMENT_OUT")"
footer_line=$(grep -n '^_Model: ' "$COMMENT_OUT" | head -n1 | cut -d: -f1)
body_line=$(grep -n 'discount.js:2' "$COMMENT_OUT" | head -n1 | cut -d: -f1)
[ -n "$body_line" ] || fail "footer: no review body in comment: $(cat "$COMMENT_OUT")"
[ "$footer_line" -gt "$body_line" ] \
  || fail "footer: model line at $footer_line precedes review body at $body_line"
echo "PASS  --show-model-footer renders below the review body"

echo "ALL SELFTESTS PASSED"
