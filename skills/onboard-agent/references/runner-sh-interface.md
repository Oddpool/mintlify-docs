# runner.sh Interface Specification

## The Contract

Your agent runs inside a Docker container via `runner.sh`. The benchmark harness calls your script, you solve the problem, the harness scores the result.

```
Docker Container
├── entry.sh (harness — you don't touch this)
│   1. Set environment variables
│   2. Call runner.sh  ◄── YOUR CODE
│   3. Capture git diff / check results
│   4. Run evaluation
│   5. Write score.json
└── runner.sh (YOUR agent)
    1. Install your agent
    2. Read $PROBLEM_STATEMENT
    3. Run your agent in $WORKING_DIR
    4. Agent edits files to solve the problem
    5. (Optional) Write trajectory.json to $OUTPUT_DIR
```

## Environment Variables

| Variable | Example | Description |
|---|---|---|
| `$PROBLEM_STATEMENT` | "Fix the bug in..." | Natural language task |
| `$WORKING_DIR` | `/app` or `/testbed` | Directory with repo/files to solve |
| `$OUTPUT_DIR` | `/output` | Write logs + trajectory here |
| `$METADATA_FILE` | `/benchkit/metadata.json` | Benchmark-specific JSON data |
| `$INSTANCE_ID` | `"django__django-11099"` | Unique instance identifier |
| (custom env vars) | `LLM_API_KEY`, etc. | Any env var set on the BenchSpan dashboard |

## Outputs

There are two output channels — stdout capture and file writes:

### 1. Stdout (captured automatically by the harness)

Whatever `runner.sh` prints to stdout becomes:
- **`100_runner.log`** on the host (for debugging)
- **`/logs/agent/output.txt`** inside the container (for verifiers/grading)

Many benchmarks (QA, math, reasoning) grade by reading `/logs/agent/output.txt`. **If your runner.sh swallows stdout, the agent will fail.**

**Good**: `my-agent --prompt "$PROBLEM_STATEMENT"` (output goes to stdout)
**Good**: `my-agent ... | tee "$OUTPUT_DIR/agent.log"` (stdout preserved + file copy)
**Bad**: `my-agent ... > "$OUTPUT_DIR/agent.log"` (stdout swallowed!)

### 2. Files in `$WORKING_DIR` (for coding benchmarks)

For coding benchmarks (SWEbench, HumanEvalFix, etc.), the harness checks what files the agent modified in `$WORKING_DIR`. The agent edits code, and the harness diffs it.

### 3. Optional outputs

- `$OUTPUT_DIR/trajectory.json` — token usage, tool calls, latency
- `$OUTPUT_DIR/*.log` — any logs your agent writes

## runner.sh Three-Phase Pattern

```bash
#!/bin/bash
set -uo pipefail

# ── Phase 1: Install ──
# Container has: bash, curl. Everything else you install.
pip install my-agent        # or npm install, or curl binary

# ── Phase 2: Run ──
cd "$WORKING_DIR"
my-agent solve --task "$PROBLEM_STATEMENT"
# CRITICAL: agent output must flow to stdout (not redirected to a file)

# ── Phase 3: Telemetry (optional) ──
# Parse agent output into trajectory.json
```

## Exit Codes

- Exit 0: Normal completion (harness grades the result)
- Exit non-zero: Container marked as "error"
- Convention: Always exit 0. Let the harness handle scoring.

## Container Environment

- **Runtime**: Docker, linux/amd64
- **User**: root (by default)
- **Network**: Full internet access
- **stdin**: NOT available (non-interactive only)
- **Timeout**: Per-benchmark (typically 120s-3600s)

## What Happens After runner.sh Exits

1. Harness captures git diff from `$WORKING_DIR`
2. Harness runs benchmark-specific evaluation (tests, scoring)
3. Harness writes `$OUTPUT_DIR/score.json`
4. Platform collects all artifacts from `$OUTPUT_DIR`
5. Container is destroyed
