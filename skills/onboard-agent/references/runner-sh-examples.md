# runner.sh Examples

## Pattern A: Build from source — Python/uv (OpenHands CLI)

runner.sh lives at the root of the agent's repo. The entire repo is tarred and injected at `/runner/`.

```bash
#!/bin/bash
set -uo pipefail

# ── Install system deps ──
(which curl >/dev/null 2>&1 && which git >/dev/null 2>&1) || \
  (apt-get update -qq && apt-get install -y -qq curl git) >/dev/null 2>&1 || true

# ── Install uv (Python package manager) ──
curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
export PATH="$HOME/.local/bin:$PATH"

# ── Build from source at /runner ──
# uv auto-downloads the required Python version if container has wrong one
cd /runner
uv sync --python 3.12 >/dev/null 2>&1

# ── Configure ──
# Env vars (LLM_API_KEY, LLM_MODEL, etc.) are set by the user on the
# BenchSpan dashboard and injected into the container automatically.
# CRITICAL: point agent at the benchmark task dir, not the agent source
export OPENHANDS_WORK_DIR="$WORKING_DIR"

# ── Run ──
cd "$WORKING_DIR"
uv run --directory /runner openhands \
  --headless --override-with-envs \
  -t "$PROBLEM_STATEMENT" \
  2>"$OUTPUT_DIR/agent_stderr.log" | tee "$OUTPUT_DIR/openhands_output.log"
```

Key points:
- **`/runner/` is the codebase, `$WORKING_DIR` is the task.** Set agent's work dir env var explicitly.
- **`uv sync --python 3.12`** — auto-downloads Python 3.12 even if container has 3.11.
- **Env vars** — users set whatever their agent needs (`LLM_API_KEY`, `LLM_MODEL`, etc.) on the BenchSpan dashboard. They get injected into the container automatically.
- **`--override-with-envs`** — tells agent to read config from env vars instead of settings files.
- **`--headless`** — non-interactive mode, no TUI.
- Cold install takes ~90s (Python download + deps), subsequent runs use cache.

## Pattern B: Build from source — Node.js/npm

```bash
#!/bin/bash
set -uo pipefail

# ── Install system deps ──
(which curl >/dev/null 2>&1 && which xz >/dev/null 2>&1) || \
  (apt-get update -qq && apt-get install -y -qq curl xz-utils) >/dev/null 2>&1 || true

# ── Install Node.js ──
curl -fsSL https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-x64.tar.xz \
  | tar -xJ -C /usr/local --strip-components=1

# ── Build from source at /runner ──
cd /runner
npm ci --production >/dev/null 2>&1

# ── Run ──
cd "$WORKING_DIR"
node /runner/dist/index.js \
  --prompt "$PROBLEM_STATEMENT" \
  2>"$OUTPUT_DIR/agent_stderr.log" | tee "$OUTPUT_DIR/agent_output.log"
```

Key points:
- `npm ci` for reproducible installs from lockfile.
- Use absolute path `/runner/dist/index.js` since we `cd` to `$WORKING_DIR`.
- If agent uses TypeScript, build step: `cd /runner && npm run build >/dev/null 2>&1`.

## Pattern C: Published pip package (Aider)

runner.sh lives in a small `agents/<name>/` directory. Installs from PyPI.

```bash
#!/bin/bash
set -uo pipefail

# Install (noise to stderr)
pip install aider-chat 2>"$OUTPUT_DIR/install_stderr.log" >&2

# Run
cd "$WORKING_DIR"
git init 2>/dev/null || true
git add -A 2>/dev/null || true
git commit -m "baseline" --allow-empty 2>/dev/null || true

aider \
  --model anthropic/claude-haiku-4-5-20251001 \
  --yes-always \
  --no-auto-commits \
  --no-pretty \
  --no-suggest-shell-commands \
  --message "$PROBLEM_STATEMENT" \
  2>"$OUTPUT_DIR/agent_stderr.log" | tee "$OUTPUT_DIR/aider_output.log"
```

## Pattern D: Published npm package (Claude Code)

```bash
#!/bin/bash
set -uo pipefail

# Install system deps if missing (slim images lack curl/xz)
(which curl >/dev/null 2>&1 && which xz >/dev/null 2>&1) || \
  (apt-get update -qq && apt-get install -y -qq curl xz-utils) >/dev/null 2>&1 || true

# Install Node.js (binary tarball)
curl -fsSL https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-x64.tar.xz \
  | tar -xJ -C /usr/local --strip-components=1

# Install agent (noise to stderr)
/usr/local/bin/npm install -g @anthropic-ai/claude-code 2>&1 | tail -5 >&2

# Create non-root user (Claude Code refuses to run as root)
useradd -m -s /bin/bash benchkit 2>/dev/null || true
chown -R benchkit:benchkit "$OUTPUT_DIR" 2>/dev/null || true
chmod -R 777 "$WORKING_DIR" 2>/dev/null || true

# Write wrapper to avoid quoting issues with su -c
cat > /tmp/run_agent.sh << 'RUNEOF'
#!/bin/bash
cd "$WORKING_DIR"
export HOME=/home/benchkit
/usr/local/bin/claude -p "$PROBLEM_STATEMENT" \
  --bare --dangerously-skip-permissions \
  --model claude-haiku-4-5-20251001 \
  --output-format stream-json --verbose --max-turns 30 \
  2>"$OUTPUT_DIR/agent_stderr.log" | tee "$OUTPUT_DIR/claude_output.jsonl"
RUNEOF
chmod +x /tmp/run_agent.sh
su benchkit -p -c "bash /tmp/run_agent.sh"

# Telemetry extraction (see trajectory-schema.md)
python3 << 'PYEOF'
import json
# ... parse stream-json output into trajectory.json
PYEOF
```

## Pattern E: Binary agent (Ante)

```bash
#!/bin/bash
set -uo pipefail

# Install (single binary — noise to log files)
curl -fsSL https://ante.run/install.sh | bash \
  >"$OUTPUT_DIR/install_stdout.log" 2>"$OUTPUT_DIR/install_stderr.log"
export PATH="/root/.ante/bin:$HOME/.ante/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

# Run — tee to preserve stdout for harness
cd "$WORKING_DIR"
ante \
  --provider anthropic \
  --model claude-haiku-4-5-20251001 \
  --yolo \
  --output-format json \
  -p "$PROBLEM_STATEMENT" \
  2>"$OUTPUT_DIR/agent_stderr.log" | tee "$OUTPUT_DIR/ante_output.jsonl"
```

## Pattern F: No-op baseline (testing harness)

```bash
#!/bin/bash
echo '{"schema_version":"1.0","instance_id":"'"$INSTANCE_ID"'","total_tokens":0,"steps":[]}' \
  > "$OUTPUT_DIR/trajectory.json"
```

## Key Rules

1. **Keep stdout clean**: All install noise to stderr (`>&2`) or `/dev/null`. Only the agent's actual output should be on stdout.
2. **Use `tee`**: Never `>` redirect agent stdout to a file. Use `tee` so stdout flows to both a file and the harness.
3. **Install missing deps**: Don't assume curl, git, xz, python3 exist. Check and install.
4. **Heredoc for sub-scripts**: Use `<< 'RUNEOF'` (single-quoted) to prevent premature variable expansion.
5. **Non-interactive flags**: Every agent must run without stdin. Find the right flags.

## Build-from-Source Checklist

When the agent codebase IS the agent directory:

- [ ] runner.sh is at the repo root
- [ ] System deps installed (curl, git, etc.) with stdout suppressed
- [ ] Build tool installed (uv, node, cargo) with stdout suppressed
- [ ] `cd /runner && <build command>` builds from source
- [ ] Python version handled (`uv sync --python X.Y` if needed)
- [ ] Required env vars documented in `# Env:` comment line (user sets them on Benchspan dashboard)
- [ ] Agent's working directory pointed at `$WORKING_DIR`, not `/runner/`
- [ ] Agent config files in the repo won't interfere (hooks, settings)
- [ ] `cd "$WORKING_DIR"` before running the agent
- [ ] Agent invoked with `--headless` or equivalent non-interactive flag
- [ ] Output goes through `tee` for harness capture
