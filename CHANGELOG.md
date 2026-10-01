# Changelog

## Unreleased

- **`panoptes --version` and `panoptes --self-update`.** A standalone install
  (a copy on your PATH, not a clone) can now update itself to the latest `v2`
  release: the new script is downloaded next to the old one, checked with
  `bash -n` and `--version`, then moved into place atomically. It refuses to
  overwrite a symlink or a file inside a git checkout, which git should update
  instead. README's install snippet now installs from the `v2` tag.

## v2.14.0 — 2026-10-01

- **Default model: `moonshotai/kimi-k2.7-code` → `openai/gpt-5-mini`.** Kimi
  reasons without bound even at `reasoning_effort: low`: it used 11k of the
  16k completion budget on a 237-line diff, then returned empty content
  (`finish_reason=length`) on 265- and 273-line diffs. On a 455-line diff it
  exhausted 32k. GPT-5 Mini reviewed the same diffs in ~1.1k completion
  tokens at ~1/25 the cost, with comparable findings. To keep Kimi, pin it
  in the calling workflow's `with:` block:
  `model: moonshotai/kimi-k2.7-code-20260612` (and raise `max_tokens`).
- **`--llm-cmd` understands `claude -p --output-format json`.** The review is
  read from `.result`, and a `type:"result"` envelope that is not
  `subtype:"success"` with `is_error:false` is a transport failure — so a
  local review can run on a Claude subscription without a quota or auth error
  being posted as a clean review. README shows the recommended invocation.
- **`--llm-cmd` envelope checks fail closed on two more shapes:** a falsey
  `status` (`false`, `null`, `""`) is no longer read as "no status field",
  and JSON stdout that is not a single object (an array, a scalar) is a
  failure instead of being posted verbatim as the review.
- **Standalone local CLI: `bin/panoptes`.** The review engine previously
  embedded as a ~430-line `run:` step in `.github/workflows/review.yml` is now
  a dependency-free executable (`bash`, `git`, `jq`, `curl`, and `gh` for
  `--pr` mode) that runs anywhere — no GitHub Actions required. Same diff
  triage, prompt assembly (including the exact `SYSTEM_PROMPT` and the
  `REVIEW.md` injection-safety property), severity tally, E2BIG guards, and
  fail-safe philosophy as before. See the README's new
  ["Run it locally"](README.md#run-it-locally) section.
  - Three diff sources: `--diff <file|->`, `--base <ref>` (local `git diff`),
    `--pr <number>` (only mode that can `--comment`, via `gh pr diff`).
  - Two transports: the existing OpenAI-compatible HTTP call
    (`--base-url`/`--model`, key from `PANOPTES_API_KEY` falling back to
    `OPENROUTER_API_KEY`), or `--llm-cmd` to pipe the prompt into a local
    agent CLI instead. `--llm-cmd` reads non-JSON stdout as the review
    verbatim; JSON stdout is treated as an agent envelope, where a `status`
    other than SUCCESS is a transport failure (reporting the envelope's
    `error`) and the review is the first non-empty string among `.response`,
    `.content`, `.text` and `.result`.
    JSON carrying none of those is a failure too — never a review, so an
    agent that reports its own breakage in-band (`agy --output-format json`
    answers `{"status":"ERROR","response":null}` and still exits 0) can't
    have its error blob posted as a clean review.
  - A failing `--llm-cmd` reports the tail of the command's own stdout, which
    is where agent CLIs put their diagnosis — matching what the HTTP
    transport already does with the provider's error body. (The command's
    stderr is untouched and still streams through live.)
  - A one-shot fallback transport (`--fallback-base-url`/`--fallback-model`
    or `--fallback-llm-cmd`) tried once on primary failure, plus `--strict`
    for callers that want a hard failure instead of the advisory exit 0.
    Either half of an HTTP fallback pair may be omitted and inherits the
    primary's value.
  - `--format json` for machine-readable output (`reviewed`, `important`,
    `nit`, `pre_existing`, `review`, `model`, `transport`, `fallback_used`,
    `failure`). `model`/`transport` describe the attempt that produced the
    review and are null when none did; `failure` is null on a skip and
    `{primary_error, fallback_error}` when every transport failed — so a
    caller can tell "nothing to review" from "the review died".
  - A provider HTTP error quotes the provider's own message (a retired model
    id says so) instead of only guessing at the API key or credit balance.
- **`review.yml` is now a thin wrapper.** It fetches `bin/panoptes` from this
  repo at the exact ref that is running (so a consumer pinned to `@v2` keeps
  getting the `@v2` engine) and shells out to it in `--pr --comment --format
  json` mode. Inputs, outputs, defaults, and the posted comment format are
  unchanged — consumers pinned to a tag see identical behavior.
- `test/selftest.sh` now exercises `bin/panoptes` directly (local `--diff`
  mode + `--format json`) instead of carrying an inline copy of the request/
  parse/guard logic that had to be hand-kept in sync with `review.yml`. Added
  coverage for the `--llm-cmd` transport, the fallback chain, and the
  fail-safe/`--strict` exit-code contract.

## v2.13.0 — 2026-07-10

- **Fix `E2BIG` on large diffs (curl side).** The request body is sent with
  `--data-binary @file` instead of an argument, so a big diff no longer
  overflows the per-argument limit. (#14)

## v2.12.0 — 2026-07-10

- **Fix `E2BIG` on large diffs (jq side).** The diff and system prompt are
  passed to jq via `--rawfile`, not `--arg`. (#13)

## v2.11.2 — 2026-07-03

- **`show_model_footer` now renders at the foot of the comment**, not directly
  under the heading — it is an actual footer again. Still off by default. The
  self-review workflow no longer enables it (the model line is omitted on
  panoptes' own PRs).

## v2.11.1 — 2026-07-03

- **Fix empty reviews on the default model — raise default `max_tokens`
  8000 → 16000.** The default model (`moonshotai/kimi-k2.7-code`) is a
  reasoning model; its thinking tokens share the completion budget, so 8000
  could be fully spent on reasoning and leave no written review
  (`finish_reason=length`, empty content). Doubling the default gives the
  review room. Cost per review rises accordingly; override `max_tokens` (or
  use a non-reasoning model) to tune.
- **Dogfood: panoptes now self-reviews its own PRs.** Added
  `.github/workflows/self-review.yml`, which calls the reusable `review.yml`
  locally (`uses: ./…`) on every pull request — an end-to-end self-test that
  exercises the reviewer as changed in the same PR, complementing the offline
  `selftest.yml` mock. Repo-internal only; no change to the consumer-facing
  reusable workflow. Requires an `OPENROUTER_API_KEY` secret on the repo/org;
  it is passed explicitly (not `secrets: inherit`), so a missing secret
  resolves to an empty string and the review degrades to an "unavailable"
  comment rather than hard-failing. Fork PRs are skipped (no secret, read-only
  token). Use a spend-capped OpenRouter key, since a same-repo branch that
  edits `review.yml` runs its own version with that key — an inherent dogfood
  tradeoff.

## v2.11.0 — 2026-07-03

- Rebrand to **Panoptes** (the hundred-eyed watchman). Default `bot_name` is now
  `👁 Panoptes` (was `🤖 Kimo Reviewer`). Consumers that set `bot_name`
  explicitly are unaffected. Added hero art and an eye-mark logo under `assets/`.

## v2.10.1 — 2026-07-03

Hardening pass (from an ultrareview of v2.10.0):

- **Security — REVIEW.md prompt injection fixed.** `REVIEW.md` now loads from
  the PR **target branch** (`base.sha`), not the PR head. A contributor can no
  longer add a `REVIEW.md` in their own PR to steer/neutralize its review. It is
  also appended LAST so it truly outranks `extra_instructions` on conflict.
- **Gating now works across jobs.** Severity counts are exposed as
  `workflow_call` outputs (`reviewed`, `important`, `nit`, `pre_existing`) so a
  downstream `needs:` job can gate — a per-job `$GITHUB_STEP_SUMMARY` can't be
  read across jobs, so the previous README recipe silently passed. `reviewed` is
  `'true'` only when a review actually completed, so gates can fail closed.
- **No misleading tally on empty reviews.** The tally now runs only past the
  empty-review guard, so a failed/empty model reply no longer emits `0/0/0`.
- **Triage regexes anchored.** `auth`/`config` no longer match substrings like
  `AUTHORS.md`/`oracle` (mid-word); pytest `test_*.py` is now counted as a test.
- **Template aligned.** `templates/code-review-guidelines.md` Severity/Response
  sections use the 🔴/🟡/🟣 scheme (were still `Blocker/Warning/Nit`).

## v2.10.0 — 2026-07-03

- Repo-root `REVIEW.md` support: injected verbatim as highest-priority,
  review-only instructions that override the defaults and the guidelines file.
  Absent file → no change.
- Severity tally in the job summary: counts the review's `🔴`/`🟡`/`🟣` markers
  and exposes the counts as workflow outputs so teams can OPT IN to CI gating.
  The review job stays advisory and always exits green.
- Docs: README and `templates/code-review-guidelines.md` document REVIEW.md,
  the severity markers, and gating via workflow outputs.

  REVIEW.md convention and severity-marker approach inspired by
  [Claude Code Review](https://docs.claude.com/en/docs/claude-code/github-actions)
  and the MIT-licensed
  [awesome-skills/code-review-skill](https://github.com/obra/awesome-skills).

## v2.9.0 — 2026-07-03

- New `reasoning_effort` input (default `low`): caps how much a thinking
  model (e.g. Kimi) spends reasoning, so it stops burning the whole
  `max_tokens` budget on thought and returning empty content
  (`finish_reason=length`). Also lowers cost. Set `''` to omit the param.

  Root cause fix for the `:robot: Code review unavailable … finish_reason=length`
  comments seen on large PRs with a reasoning model.

## v2.8.0 — 2026-07-02

- New `max_tokens` input (default `8000`) sent in the request, so reasoning
  models don't starve the reply and truncate it to empty content.
- `finish_reason` is now logged and shown in the usage table; a
  `finish_reason=length` warning is surfaced in the log and folded into the
  "review unavailable" comment when it causes an empty reply.
- Template `code-review-guidelines.md`: clean reviews now name what was
  checked instead of printing a bare verdict.

## v2.7.0 — 2026-07-02

- Default `show_model_footer` is now `false` — the `_Model: … advisory_`
  line is hidden unless a repo opts back in with `show_model_footer: true`.

## v2.6.0 — 2026-07-02

- Default `bot_name` is now `🤖 Kimo Reviewer` (was
  `:robot: Automated code review`). Repos that set their own `bot_name`
  are unaffected.

## v2.5.0 — 2026-07-02

- Customizable comment heading: new `bot_name` input (default
  `:robot: Automated code review`) sets the H2 title, and
  `show_model_footer` (default `true`) toggles the `_Model: … advisory_`
  line. Defaults reproduce the previous output — backward-compatible.

## v2.4.0 — 2026-07-02

- Added a deterministic self-test (`test/selftest.sh` + `test/mock_openrouter.py`,
  run by `.github/workflows/selftest.yml`): exercises the review pipeline —
  request building, response parsing, and graceful degradation on non-JSON
  and empty responses — against a mock endpoint, with no real API call or
  token cost. Repo-internal only; does not change the reusable workflow.

## v2.3.0 — 2026-07-02

- New `require_zero_retention` input (OpenRouter): routes only to providers
  that do not retain data (`provider.data_collection=deny`). Default
  `false` — no change to existing behavior.
- Observability: token usage (and cost when reported) is written to the
  GitHub Actions job summary on every run.
- README: added a "Data handling & providers" section (Azure OpenAI,
  Bedrock, self-hosted vLLM/Ollama/LiteLLM via `base_url`).

All additions are backward-compatible; consumers on `@v2` need no changes.

## v2.2.0 — 2026-07-02

- Default `model` changed from `deepseek/deepseek-v4-flash-20260423` to
  `moonshotai/kimi-k2.7-code-20260612` (code-specialized). Override via the
  `model` input.

## v2.1.0 — 2026-07-02

- Repo-specific review guidelines: the bot now reads
  `.github/code-review-guidelines.md` (configurable via the new
  `guidelines_path` input) from the reviewed repo at the PR head commit and
  appends it to the built-in prompt. Absent file → defaults unchanged.
- Added `templates/code-review-guidelines.md` as a starting point.

## v2.0.0 — 2026-07-02

**Breaking:** engine switched from the Claude Code Action to a provider-
agnostic single-shot review via OpenRouter (much cheaper per PR).

- Reusable workflow renamed `claude-review.yml` → `review.yml`; consumers
  pin `@v2` and call `.../review.yml@v2`.
- Secret renamed `ANTHROPIC_API_KEY` → `OPENROUTER_API_KEY`.
- New/changed inputs: `model` now an OpenRouter model id
  (default `deepseek/deepseek-v4-flash-20260423`), new `base_url`
  (default `https://openrouter.ai/api/v1`).
- One API call per PR posts a single advisory summary comment (no more
  agentic multi-turn run, no inline comments). Draft skip, superseded-run
  cancellation, and the `max_diff_lines` guard are retained.
- Provider errors / empty responses post a short "review unavailable"
  comment and exit successfully instead of failing the check.

## v1.1.0 — 2026-07-02

- Default `model` changed from `claude-opus-4-8` to `claude-sonnet-5`
  (lower cost, strong review quality). Override via the `model` input.
- Enable `track_progress: true` on the action: PRs now show a live
  "in progress" tracking comment while the review runs.

## v1.0.0 — 2026-07-02

Initial release.

- Reusable workflow `claude-review.yml`: advisory Claude code review on
  pull requests via `anthropics/claude-code-action@v1`.
- Inputs: `model` (default `claude-opus-4-8`), `extra_instructions`,
  `max_diff_lines` (default 5000).
- Skips draft PRs, cancels superseded runs, skips oversized diffs with an
  explanatory comment.
- Consumer template and adoption guide.
