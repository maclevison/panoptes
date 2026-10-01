#!/usr/bin/env bash
#
# Minimal mock for the --llm-cmd transport. Used only by test/selftest.sh.
# Consumes the piped prompt (system prompt + diff) from stdin and answers on
# stdout, so the --llm-cmd path can be exercised deterministically with no real
# agent CLI involved.
#
# $MOCK_CMD_MODE selects the shape of the answer:
#   text (default)  plain-text review, exit 0 — the raw-stdout contract
#   envelope_ok     agent JSON envelope with the review in .response, exit 0
#   envelope_error  agent JSON envelope with status=ERROR, exit 0 (agy does
#                   this: the failure is in the envelope, not the exit code)
#   claude_ok       `claude -p --output-format json` envelope, review in .result
#   claude_error    claude envelope with is_error=true, exit 0
#   claude_subtype  claude envelope, subtype=error_max_turns but is_error=false
#   untyped_error   is_error=true with no .type field
#   bare_result     {"result": ...} alone — not a claude success envelope
#   status_false    status:false plus a .response (jq // would skip it)
#   json_array      an array wrapping an error object
#   status_null     status:null plus a .response
#   json_scalar     a bare JSON number
#   whitespace      whitespace-only stdout
#   blank_response  SUCCESS envelope whose .response is only whitespace
#   json_stream     two JSON objects back to back (NDJSON)
#   nonstring       envelope whose .response is an object, not text
#   envelope_bare   valid JSON with no .response/.content/.text field, exit 0
#   fail_stdout     diagnostics on stdout, exit 1 (the bytes worth logging)
set -euo pipefail

cat >/dev/null  # discard the piped prompt

case "${MOCK_CMD_MODE:-text}" in
  envelope_ok)
    cat <<'J'
{"conversation_id":"c-1","status":"SUCCESS","response":"No blocking issues — reviewed via the canned review mock.\n- 🟡 Nit: cosmetic naming suggestion.","error":null,"usage":{"total":42}}
J
    ;;
  envelope_error)
    cat <<'J'
{"conversation_id":"c-1","status":"ERROR","response":null,"error":"Agent execution terminated due to error.","usage":{}}
J
    ;;
  claude_ok)
    cat <<'J'
{"type":"result","subtype":"success","is_error":false,"result":"No blocking issues — reviewed via the canned review mock.\n- 🟡 Nit: cosmetic naming suggestion.","session_id":"s-1"}
J
    ;;
  claude_error)
    cat <<'J'
{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached","session_id":"s-1"}
J
    ;;
  claude_subtype)
    printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":false,"result":"partial","session_id":"s-1"}'
    ;;
  untyped_error)
    printf '%s\n' '{"is_error":true,"result":"quota failure"}'
    ;;
  bare_result)
    printf '%s\n' '{"result":"looks like a review"}'
    ;;
  status_false)
    printf '%s\n' '{"status":false,"response":"looks like a review"}'
    ;;
  json_array)
    printf '%s\n' '[{"is_error":true,"result":"failure"}]'
    ;;
  status_null)
    printf '%s\n' '{"status":null,"response":"looks like a review"}'
    ;;
  json_scalar)
    printf '%s\n' '42'
    ;;
  whitespace)
    printf '  \n\t\n'
    ;;
  blank_response)
    printf '%s\n' '{"status":"SUCCESS","response":"\n  "}'
    ;;
  json_stream)
    printf '%s\n' '{"status":"SUCCESS","response":"one"}' '{"status":"SUCCESS","response":"two"}'
    ;;
  nonstring)
    printf '%s\n' '{"status":"SUCCESS","response":{"oops":"not text"}}'
    ;;
  envelope_bare)
    printf '%s\n' '{"conversation_id":"c-1","usage":{}}'
    ;;
  fail_stdout)
    printf '%s\n' '{"status":"ERROR","error":"backend exploded: Error ID be3a6aa3-dead-beef"}'
    exit 1
    ;;
  *)
    cat <<'REVIEW'
No blocking issues — reviewed via the canned review mock.
- 🟡 Nit: cosmetic naming suggestion.
REVIEW
    ;;
esac
