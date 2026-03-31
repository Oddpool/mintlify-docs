---
name: onboard-agent
description: Onboard a new agent to Benchspan. Use when the user wants to integrate their agent, create a runner.sh, test their agent against benchmarks, or says "onboard", "integrate my agent", "create runner.sh", or "set up my agent for benchspan". Automates the full process from codebase exploration through healthcheck testing.
---

# Agent Onboarding Skill

You are onboarding a new agent to Benchspan. Your job is to explore the user's agent codebase, generate a working `runner.sh`, and verify it passes the `agent-healthcheck` benchmark.

## Phase 1: Discover

Ask the user these questions (skip any they've already answered):

1. **Where is your agent codebase?** (local path or git repo URL)
2. **Do you want to build from source or install a published package?**
   - **Build from source** — runner.sh lives at the root of your repo, builds and runs HEAD. Use this if you're actively developing and want to benchmark your latest code.
   - **Published package** — runner.sh lives in a small `agents/<name>/` directory, installs from pip/npm. Use this if you have a stable release you want to benchmark.
3. **What runtime does it use?** (Python/pip/uv, Node.js/npm, Rust/binary, Go, other)
4. **How is it invoked?** (CLI command, Python API, etc.)
5. **What env vars does your agent need?** (API keys, model config, etc.)
   - Users set these on the Benchspan dashboard — any env var they set there gets injected into the container at runtime. There are no naming restrictions. If the agent expects `LLM_API_KEY` and `LLM_MODEL`, that's what they set on the dashboard.
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
# the Benchspan dashboard. They get injected into the container automatically.
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

3. **Env vars.** Users set whatever env vars their agent needs on the Benchspan dashboard — they get injected into the container with the exact names configured. The runner.sh doesn't need to map or rename anything. Just make sure the user knows which env vars to set (e.g., `LLM_API_KEY`, `LLM_MODEL`).

4. **Config files in the repo.** If your repo has agent config files (hooks, settings) at `.myagent/`, they'll be at `/runner/.myagent/` — and the agent might load them. Make sure any work-directory config doesn't interfere. Set explicit env vars to override.

5. **`--agent` points at the repo root.** The user runs: `benchspan run --benchmark swebench --agent /path/to/my-repo`. The entire repo gets packaged and injected.

6. **Create a `.benchspanignore` file.** When building from source, the CLI packages the entire repo. Large files (build artifacts, test data, datasets) slow down uploads. Create a `.benchspanignore` at the repo root to exclude them. It works like `.gitignore` — one pattern per line, `#` comments. These are always excluded by default: `.git`, `__pycache__`, `node_modules`, `.venv`, `*.pyc`. Example:
   ```
   # Build artifacts
   dist/
   build/
   *.egg-info/

   # Test data
   tests/fixtures/large/
   *.bin
   ```
   Always create this file for build-from-source agents.

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

1. Check if the Benchspan CLI is installed: `which benchspan`
2. If not installed: `pip install benchspan`
3. Check if the user is logged in: `benchspan whoami`
4. If not logged in, have them log in: tell the user to run `! benchspan login` (this opens a browser for auth)
5. **List the specific env vars the agent needs** based on what you discovered in Phase 2, and ask the user to set them on the Benchspan dashboard. Print them clearly and end with a clear handoff, e.g.:

   > Before we can test your agent, please set these env vars on your Benchspan dashboard at https://benchspan.com/dashboard/settings/profile:
   >
   > - `LLM_API_KEY` — your LLM provider API key
   > - `LLM_MODEL` — the model to use (e.g., `claude-haiku-4-5-20251001`)
   >
   > Any env var you set there gets injected into the container automatically when your agent runs.
   >
   > Let me know once they are set and I'll start testing your agent integration.

6. **Wait for the user to confirm** before proceeding to Phase 5.

## Phase 5: Test

Run the healthcheck benchmark based on agent type:

```bash
# Quick smoke test first (2 instances — echo-answer + env-vars)
benchspan run --benchmark agent-healthcheck.quick --agent <path>

# Then full universal suite (7 instances — all agents must pass this)
benchspan run --benchmark agent-healthcheck.universal --agent <path>

# For coding agents, also run the coding subset (3 instances)
benchspan run --benchmark agent-healthcheck.coding --agent <path>
```

Where `<path>` is:
- Build from source: the repo root (e.g., `/path/to/my-agent-repo`)
- Published package: the agent directory (e.g., `./agents/my-agent`)

After the run completes, check results:
```bash
benchspan runs show <run_id>
```

## Phase 6: Iterate

For each failed instance:

1. Check the run results: `benchspan runs show <run_id>`
2. **Download the logs** to inspect what actually happened:
   ```bash
   # Download only failed instances
   benchspan runs download <run_id> --failed

   # Or download a specific instance
   benchspan runs download <run_id> --instance <instance_id>
   ```
   This downloads the run artifacts to a local directory.

3. **Read the logs** to diagnose the root cause. Start with `100_runner.log` (your runner.sh output) and `200_scoring.log` (verifier output):
   ```bash
   cat run_<id>/<instance_id>/100_runner.log
   cat run_<id>/<instance_id>/200_scoring.log
   ```

4. **Determine if it's a runner.sh issue or an agent behavior issue.** This is critical.
   - **Runner.sh issues** (fix these): install failures, missing deps, stdout swallowed, wrong working directory, timeout during install, env vars not reaching the agent, Python version mismatch.
   - **Agent behavior issues** (don't fix in runner.sh): the LLM gave a wrong answer, the agent's paradigm doesn't fit the task (e.g., a patch-based agent can't produce stdout text), the agent misunderstood the prompt.

   If a test fails because of agent behavior, **do not hack the runner.sh to game that specific test**. The runner.sh should faithfully install and invoke the agent — not work around the agent's limitations for individual healthcheck tasks. Move on.

5. Common runner.sh issues:
   - `/logs/agent/output.txt` empty → agent stdout is being swallowed (use `tee`)
   - "command not found" → dependency not installed or not on PATH
   - "permission denied" → agent needs non-root user workaround
   - Timeout → agent hanging on interactive input, or install takes too long
   - Agent working on wrong directory → need to set work dir env var to `$WORKING_DIR`
   - Python version mismatch → use `uv sync --python X.Y` or install explicitly
   - Env vars not found → make sure they are set on the Benchspan dashboard

6. Fix the runner.sh based on what the logs show and re-run.

The goal is a **complete and resilient runner.sh**, not 100% on healthcheck. If the runner.sh correctly installs and invokes the agent, and most tests pass, it's ready for real benchmarks.

### After healthcheck passes:

Once you're confident the runner.sh is solid, do a final run with only the tests you know pass for this agent. For example, if the agent passes echo-answer, env-vars, no-python3, no-git, conda-env, file-create, and file-edit but not special-chars and large-problem, run:

```bash
benchspan run --benchmark agent-healthcheck.echo-answer,agent-healthcheck.env-vars,agent-healthcheck.no-python3,agent-healthcheck.no-git,agent-healthcheck.conda-env,agent-healthcheck.file-create,agent-healthcheck.file-edit --agent <path>
```

Then suggest running a real benchmark to verify end-to-end:
```bash
# For coding agents:
benchspan run --benchmark swebench --agent <path> --instances 3

# For reasoning agents:
benchspan run --benchmark aime --agent <path> --instances 3
```

## Success Criteria & Communicating Completion

When you're ready to declare the agent onboarded, **explain the results clearly to the user**. They may not understand what the healthcheck tests or why some failures are okay. Write a summary like:

> Your agent is onboarded and ready to run real benchmarks. Here's what we verified:
>
> **Runner.sh works:** Your agent installs, runs, and produces output correctly across different container environments.
>
> **Healthcheck results: 7/9 passed.** The healthcheck covers a range of capabilities — stdout output, file editing, handling missing dependencies, etc. Different agents have different capabilities and tools, so not every test applies to every agent. For example, a coding agent that works through patches may not produce direct stdout answers, and a QA agent won't create files. The tests that matter for your agent all pass.
>
> **Next step:** Run a real benchmark to see how your agent performs:
> ```
> benchspan run --benchmark swebench --agent <path> --instances 5
> ```

Adapt the specific details (which tests passed/failed, why the failures don't apply) to the actual results. The key message: **the runner.sh integration is solid and your agent is ready for real benchmarks.**

The agent is fully onboarded when:
- [ ] `runner.sh` exists (at repo root for build-from-source, or in `agents/<name>/`)
- [ ] `runner.sh` has `# Benchspan agent:` and `# Env:` comment lines
- [ ] `.benchspanignore` exists (if build-from-source)
- [ ] `agent-healthcheck.quick` passes (both instances)
- [ ] Most of `agent-healthcheck.universal` passes — any failures are agent behavior, not runner.sh issues
- [ ] `agent-healthcheck.coding` passes (if coding agent — both instances)
- [ ] User understands the results and knows how to run real benchmarks
