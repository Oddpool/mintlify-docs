# Common runner.sh Gotchas

## 1. Install noise polluting stdout

**Symptom**: Verifiers fail because `/logs/agent/output.txt` is full of apt-get/npm/pip install output instead of the agent's answer.
**Cause**: The harness captures ALL of runner.sh's stdout into `/logs/agent/output.txt`. If your install steps print to stdout, that noise gets mixed in with the agent's real output.
**Fix**: Redirect all install output to stderr or /dev/null:
```bash
# Bad — install noise goes to stdout
apt-get install -y git
pip install my-agent
npm install -g my-agent

# Good — install noise suppressed from stdout
(apt-get update -qq && apt-get install -y -qq git) >/dev/null 2>&1
pip install my-agent 2>"$OUTPUT_DIR/install_stderr.log" >&2
npm install -g my-agent 2>&1 | tail -5 >&2
```

## 2. Stdout swallowed — agent output not captured

**Symptom**: `/logs/agent/output.txt` is empty or missing. Verifiers can't see the agent's answer.
**Cause**: Runner.sh redirects agent stdout to a file with `>`, so nothing reaches the harness.
**Fix**: Use `tee` to send output to both a file and stdout:
```bash
# Bad — stdout swallowed, harness gets nothing
my-agent --prompt "$PROBLEM_STATEMENT" > "$OUTPUT_DIR/agent.log"

# Good — stdout flows to both file and harness
my-agent --prompt "$PROBLEM_STATEMENT" 2>"$OUTPUT_DIR/agent_stderr.log" | tee "$OUTPUT_DIR/agent.log"
```

## 3. Missing system dependencies (curl, xz-utils, etc.)

**Symptom**: `curl: command not found`, `xz: command not found`, or tar failing to decompress.
**Cause**: Slim/minimal Docker images (python:3.11-slim, ubuntu:22.04, continuumio/miniconda3) don't have common tools pre-installed.
**Fix**: Check and install before using them:
```bash
# Install all system deps in one shot, suppress output
(which curl >/dev/null 2>&1 && which xz >/dev/null 2>&1) || \
  (apt-get update -qq && apt-get install -y -qq curl xz-utils) >/dev/null 2>&1 || true
```

## 4. Agent refuses to run as root

**Symptom**: Agent exits with "cannot run as root" error.
**Cause**: Docker containers run as root by default. Some agents (e.g., Claude Code) refuse root.
**Fix**:
```bash
useradd -m -s /bin/bash benchkit 2>/dev/null || true
chown -R benchkit:benchkit "$OUTPUT_DIR" 2>/dev/null || true
chmod -R 777 "$WORKING_DIR" 2>/dev/null || true
# Write a wrapper script, then:
su benchkit -p -c "bash /tmp/run_agent.sh"
```

## 5. Git not available or no git repo

**Symptom**: Agent crashes trying to run git commands.
**Cause**: Some benchmark images don't have git. Some agents need a git repo for context.
**Fix**:
```bash
which git >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq git) >/dev/null 2>&1 || true
cd "$WORKING_DIR"
git init 2>/dev/null || true
git add -A 2>/dev/null || true
git commit -m "baseline" --allow-empty 2>/dev/null || true
```

## 6. conda PATH issues (bash -c vs bash -lc)

**Symptom**: `python: command not found` in conda-based images.
**Cause**: Conda only activates in login shells (`bash -lc`). The harness uses `bash -c`.
**Fix**:
```bash
eval "$(conda shell.bash hook 2>/dev/null)" && conda activate base 2>/dev/null || true
# Or use absolute paths
/opt/miniconda3/bin/python ...
```

## 7. Quoting issues with $PROBLEM_STATEMENT

**Symptom**: Runner crashes or passes truncated/mangled problem statement.
**Cause**: Problem statements contain quotes, newlines, special characters.
**Fix**: Always double-quote `"$PROBLEM_STATEMENT"`. For passing to sub-scripts, use heredoc wrappers:
```bash
cat > /tmp/run.sh << 'RUNEOF'
#!/bin/bash
# $PROBLEM_STATEMENT is inherited from env, not expanded here
my-agent --task "$PROBLEM_STATEMENT"
RUNEOF
bash /tmp/run.sh
```

## 8. Agent expects interactive stdin

**Symptom**: Agent hangs waiting for user input.
**Cause**: Agent not configured for non-interactive mode.
**Fix**: Always pass non-interactive flags:
- Aider: `--yes-always --no-pretty --no-suggest-shell-commands`
- Claude Code: `--bare --dangerously-skip-permissions`
- Ante: `--yolo`
- Generic: Check for `--non-interactive`, `--yes`, `--batch`, `-y` flags

## 9. Agent timeout

**Symptom**: Container killed before agent finishes.
**Cause**: Agent runs longer than the benchmark timeout.
**Fix**: Use cheaper/faster models for healthcheck testing (e.g., claude-haiku). Set `--max-turns` or similar limits.

## 10. npm/pip installing to wrong location

**Symptom**: Installed package not found on PATH.
**Cause**: Conda or virtualenv redirecting installs.
**Fix**: Use `npm install -g` with explicit prefix, or `pip install --break-system-packages`:
```bash
/usr/local/bin/npm install -g my-agent
# or
pip install --break-system-packages my-agent
```

## 11. Large problem statements exceed shell limits

**Symptom**: "Argument list too long" error.
**Cause**: Very large problem statements passed via command-line arguments.
**Fix**: Write problem statement to a file and pass the file path:
```bash
echo "$PROBLEM_STATEMENT" > /tmp/problem.txt
my-agent --task-file /tmp/problem.txt
```

## 12. Missing trajectory.json

**Symptom**: Run completes but no telemetry in dashboard.
**Cause**: Agent doesn't write trajectory.json, or writes it to wrong path.
**Fix**: Always write to `$OUTPUT_DIR/trajectory.json`. Even a minimal one helps:
```bash
echo '{"schema_version":"1.0","instance_id":"'"$INSTANCE_ID"'","total_tokens":0,"steps":[]}' \
  > "$OUTPUT_DIR/trajectory.json"
```

---

## Build-from-Source Gotchas

## 13. Agent works on its own codebase instead of $WORKING_DIR

**Symptom**: Agent edits files in `/runner/` (its own source code) instead of the benchmark task directory.
**Cause**: Build-from-source agents are injected at `/runner/`. If the agent defaults to cwd or its own directory, it works on itself.
**Fix**: Set the agent's working directory env var explicitly:
```bash
export OPENHANDS_WORK_DIR="$WORKING_DIR"    # OpenHands
export AGENT_WORKSPACE="$WORKING_DIR"       # Generic
cd "$WORKING_DIR"                           # For agents that use cwd
```

## 14. Python version mismatch

**Symptom**: `uv sync` fails or hangs. Error about `requires-python` not satisfied.
**Cause**: Agent requires Python 3.12 but container has 3.11 (or vice versa).
**Fix**: Use uv's Python management to auto-download the right version:
```bash
uv sync --python 3.12 >/dev/null 2>&1
```

## 15. Agent's required env vars not set

**Symptom**: Agent says "not logged in" or "API key missing".
**Cause**: The user hasn't set the env vars their agent expects on the BenchSpan dashboard. The dashboard lets you set any env var — there are no naming restrictions.
**Fix**: Tell the user which env vars their agent needs (e.g., `LLM_API_KEY`, `LLM_MODEL`) and have them add those on the BenchSpan dashboard. The runner.sh doesn't need to map or rename anything — whatever is set on the dashboard gets injected into the container as-is.

## 16. Agent config files in the repo interfere

**Symptom**: Agent loads hooks, settings, or configs from its own repo at `/runner/` that weren't intended for benchmarking.
**Cause**: Many agents look for config files like `.myagent/hooks.json` or `.myagent/settings.json` in the work directory or their install directory.
**Fix**: Set env vars to override config paths, or ensure `$WORKING_DIR` is the cwd (not `/runner/`):
```bash
export OPENHANDS_PERSISTENCE_DIR="/tmp/openhands_config"
cd "$WORKING_DIR"  # Agent looks for config in cwd, which is now clean
```

## 17. Agent needs --override-with-envs or similar flag

**Symptom**: Agent says "please configure settings first" or "run setup" in headless mode.
**Cause**: Agent expects a pre-existing config file (created by interactive setup). In a fresh container there's no config.
**Fix**: Find the flag that lets the agent read config from env vars:
```bash
openhands --headless --override-with-envs -t "$PROBLEM_STATEMENT"
```
Check the agent's docs for: `--override-with-envs`, `--config-from-env`, `--no-config`, or similar.
