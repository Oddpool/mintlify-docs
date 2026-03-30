---
name: onboard-agent
description: Onboard a new agent to BenchKit. Use when the user wants to integrate their agent, create a runner.sh, test their agent against benchmarks, or says "onboard", "integrate my agent", "create runner.sh", or "set up my agent for benchkit". Automates the full process from codebase exploration through healthcheck testing.
---

# Agent Onboarding Skill

You are onboarding a new agent to BenchKit. Your job is to explore the user's agent codebase, generate a working `runner.sh`, and verify it passes the `agent-healthcheck` benchmark.

## Phase 1: Discover

Ask the user these questions (skip any they've already answered):

1. **Where is your agent codebase?** (local path or git repo URL)
2. **Do you want to build from source or install a published package?**
   - **Build from source** — runner.sh lives at the root of your repo, builds and runs HEAD. Use this if you're actively developing and want to benchmark your latest code.
   - **Published package** — runner.sh lives in a small `agents/<name>/` directory, installs from pip/npm. Use this if you have a stable release you want to benchmark.
3. **What runtime does it use?** (Python/pip/uv, Node.js/npm, Rust/binary, Go, other)
4. **How is it invoked?** (CLI command, Python API, etc.)
5. **What env vars does your agent need?** (API keys, model config, etc.)
   - Users set these on the BenchSpan dashboard — any env var they set there gets injected into the container at runtime. There are no naming restrictions. If the agent expects `LLM_API_KEY` and `LLM_MODEL`, that's what they set on the dashboard.
6. **What type of agent is it?**
   - **Coding agent** — can read/edit files, run shell commands, interact with a codebase
   - **Reasoning/QA agent** — answers questions, solves problems, produces text output
   - **Hybrid** — does both

This determines:
- **Where runner.sh goes**: repo root (build from source) or `agents/<name>/` (published package)
- **Which healthcheck subsets to run**: `universal` (all agents) + `coding` (coding agents)

## Phase 2: Explore

Systematically read the agent's codebase to understand how to invoke it:

1. Read **README.md** or similar docs for usage instructions
2. Read **package.json** / **pyproject.toml** / **Cargo.toml** for dependencies and entry points
3. Look for **CLI entry points**: check `[project.scripts]`, `bin` field, or `main` field
4. Run `--help` if possible to discover flags
5. Identify:
   - How to install it (pip, npm, curl binary, uv sync, etc.)
   - **What Python version it requires** (check `requires-python` in pyproject.toml — the container may not have it)
   - How to pass the task/prompt (CLI flag, stdin, file)
   - Non-interactive / headless flags (--headless, --yes, --batch, --no-interactive)
   - Whether it needs git (for repo map, context, etc.)
   - Whether it can run as root
   - **What env vars it expects for config** (API keys, model name, working directory, etc.)
   - **Whether it has a working directory env var** (e.g., `OPENHANDS_WORK_DIR`) — critical for build-from-source to point the agent at `$WORKING_DIR` not `/runner/`
   - Whether it loads config from its own directory (hooks, settings files) that might interfere when the codebase is at `/runner/`
   - What output format it produces (JSONL, plain text, structured logs)
   - **Whether agent output goes to stdout** (the harness captures stdout as `/logs/agent/output.txt`)

Read the reference files for context:
- `references/runner-sh-interface.md` — the full runner.sh contract
- `references/runner-sh-examples.md` — existing runner.sh patterns (including build-from-source)
- `references/common-gotchas.md` — failure modes to prevent
- `references/trajectory-schema.md` — telemetry format

## Phase 3: Generate

**Every generated runner.sh must start with these two comment lines:**

```bash
#!/bin/bash
# Benchspan agent: <Agent Name>
# Env: <REQUIRED_VAR>, <OTHER_REQUIRED_VAR>, <OPTIONAL_VAR> (optional)
```

The CLI reads these to: (1) show the agent in `benchspan agents`, and (2) check that required env vars are set on the dashboard before starting a run. Always include them.

### Build from source pattern

If the user chose build from source, place `runner.sh` at the root of their repo. The entire repo gets tarred and injected at `/runner/` in the container. The runner.sh builds from source there and runs the agent against `$WORKING_DIR`.

```bash
#!/bin/bash
# Benchspan agent: <Agent Name>
# Env: <list required env vars here>
set -uo pipefail

# ── Phase 1: Install system deps + build from source ──
# Container only guarantees bash. Install what you need, suppress stdout.
(which curl >/dev/null 2>&1 && which git >/dev/null 2>&1) || \
  (apt-get update -qq && apt-get install -y -qq curl git) >/dev/null 2>&1 || true

# Install your build tool
curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
export PATH="$HOME/.local/bin:$PATH"

# Build from source at /runner (where the repo was injected)
cd /runner
uv sync --python 3.12 >/dev/null 2>&1

# ── Phase 2: Configure + run ──
# Env vars your agent needs (API keys, model, etc.) are set by the user on
# the BenchSpan dashboard. They get injected into the container automatically.
# CRITICAL: point agent at the benchmark task dir, not /runner
export MY_AGENT_WORK_DIR="$WORKING_DIR"

cd "$WORKING_DIR"
uv run --directory /runner my-agent \
  --headless \
  -t "$PROBLEM_STATEMENT" \
  2>"$OUTPUT_DIR/agent_stderr.log" | tee "$OUTPUT_DIR/agent_output.log"

# ── Phase 3: Telemetry (optional) ──
```

**Critical things to get right for build-from-source:**

1. **`/runner/` is your codebase, `$WORKING_DIR` is the benchmark task.** Your agent must work on `$WORKING_DIR`, not `/runner/`. If your agent has a working directory env var (like `OPENHANDS_WORK_DIR`), set it to `$WORKING_DIR`. If it uses `cwd`, make sure to `cd "$WORKING_DIR"` before running.

2. **Python version mismatch.** The container may have Python 3.11 but your project requires 3.12. Use `uv sync --python 3.12` — uv will auto-download the right version. Or install it explicitly.

3. **Env vars.** Users set whatever env vars their agent needs on the BenchSpan dashboard — they get injected into the container with the exact names configured. The runner.sh doesn't need to map or rename anything. Just make sure the user knows which env vars to set (e.g., `LLM_API_KEY`, `LLM_MODEL`).

4. **Config files in the repo.** If your repo has agent config files (hooks, settings) at `.myagent/`, they'll be at `/runner/.myagent/` — and the agent might load them. Make sure any work-directory config doesn't interfere. Set explicit env vars to override.

5. **`--agent` points at the repo root.** The user runs: `benchkit run --benchmark swebench --agent /path/to/my-repo`. The entire repo gets packaged and injected.

### Published package pattern

If the user chose published package, create a small `agents/<name>/` directory with just runner.sh. The runner.sh installs from pip/npm and runs.

```bash
#!/bin/bash
# Benchspan agent: <Agent Name>
# Env: <list required env vars here>
set -uo pipefail

# ── Phase 1: Install ──
(which curl >/dev/null 2>&1) || (apt-get update -qq && apt-get install -y -qq curl) >/dev/null 2>&1 || true
pip install my-agent 2>"$OUTPUT_DIR/install_stderr.log" >&2

# ── Phase 2: Run ──
cd "$WORKING_DIR"
my-agent --prompt "$PROBLEM_STATEMENT" \
  2>"$OUTPUT_DIR/agent_stderr.log" | tee "$OUTPUT_DIR/agent_output.log"

# ── Phase 3: Telemetry (optional) ──
```

### The two rules that matter most (both patterns):

**Rule 1: Keep stdout clean during install.** The harness captures ALL stdout. If apt-get or npm install noise goes to stdout, it pollutes `/logs/agent/output.txt` and verifiers can't find the agent's answer. Redirect install output to stderr (`>&2`) or `/dev/null`.

**Rule 2: Use `tee`, never `>`.** The harness needs to see agent output on stdout. If you redirect to a file with `>`, stdout is swallowed and `/logs/agent/output.txt` is empty. Use `tee` to write to both.

### Handle known gotchas:

- If agent refuses root: create non-root user with `useradd` + `su`
- If agent needs git: `git init && git add -A && git commit -m "baseline"`
- If using conda image: source conda explicitly or use absolute paths
- Always double-quote `"$PROBLEM_STATEMENT"`
- Always use non-interactive / headless flags
- Write at least a minimal trajectory.json

### Telemetry extraction:

If the agent outputs JSONL or structured logs, add a Python heredoc to parse them into `trajectory.json`. See `references/trajectory-schema.md` for the schema.

If the agent has no parseable output, write a minimal trajectory:
```bash
echo '{"schema_version":"1.0","instance_id":"'"$INSTANCE_ID"'","total_tokens":0,"steps":[]}' \
  > "$OUTPUT_DIR/trajectory.json"
```

## Phase 4: Setup

1. Check if benchkit CLI is installed: `which benchkit`
2. If not: `pip install -e /path/to/benchkit` (ask user for benchkit repo path)
3. Check if the user is logged in: `benchkit whoami`
4. If not logged in, have them log in: tell the user to run `! benchkit login` (this opens a browser for auth)
5. **List the specific env vars the agent needs** based on what you discovered in Phase 2. Print them clearly, e.g.:

   > Before we run the healthcheck, make sure these env vars are set on your BenchSpan dashboard:
   > - `LLM_API_KEY` — your Anthropic/OpenAI API key
   > - `LLM_MODEL` — e.g., `claude-haiku-4-5-20251001`
   >
   > Any env var you set there gets injected into the container automatically.

6. For build-from-source: the `--agent` flag should point at the repo root (where runner.sh is)
7. For published package: the `--agent` flag should point at the `agents/<name>/` directory

## Phase 5: Test

Run the healthcheck benchmark based on agent type:

```bash
# Quick smoke test first (2 instances — echo-answer + env-vars)
benchkit run --benchmark agent-healthcheck.quick --agent <path>

# Then full universal suite (7 instances — all agents must pass this)
benchkit run --benchmark agent-healthcheck.universal --agent <path>

# For coding agents, also run the coding subset (3 instances)
benchkit run --benchmark agent-healthcheck.coding --agent <path>
```

Where `<path>` is:
- Build from source: the repo root (e.g., `/path/to/my-agent-repo`)
- Published package: the agent directory (e.g., `./agents/my-agent`)

After the run completes, check results:
```bash
benchkit runs list
benchkit runs show <run_id>
```

## Phase 6: Iterate

For each failed instance:

1. Check the run results: `benchkit runs show <run_id>`
2. For detailed logs, use the BenchSpan UI or `benchkit runs show <run_id>` output
3. Check for common failure patterns (see `references/common-gotchas.md`)
4. Diagnose the root cause — common issues:
   - `/logs/agent/output.txt` empty → agent stdout is being swallowed
   - "command not found" → dependency not installed or not on PATH
   - "permission denied" → agent needs non-root user workaround
   - Timeout → agent hanging on interactive input, or install takes too long
   - Agent working on wrong directory → need to set work dir env var to `$WORKING_DIR`
   - Python version mismatch → use `uv sync --python X.Y` or install explicitly
   - API key not found → map BenchKit env var names to agent's expected names
5. Fix the runner.sh
6. Re-run the failed subset

Repeat until all required subsets pass.

### After healthcheck passes:

Suggest running a real benchmark to verify end-to-end:
```bash
# For coding agents:
benchkit run --benchmark swebench.django --agent <path> --instances 3

# For reasoning agents:
benchkit run --benchmark aime --agent <path> --instances 3
```

## Success Criteria

The agent is fully onboarded when:
- [ ] `runner.sh` exists (at repo root for build-from-source, or in `agents/<name>/`)
- [ ] `agent-healthcheck.universal` passes (all 7 instances)
- [ ] `agent-healthcheck.coding` passes (if coding agent — all 3 instances)
- [ ] `trajectory.json` is written for each instance
- [ ] The agent can solve at least 1 real benchmark instance
