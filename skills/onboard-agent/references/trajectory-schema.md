# trajectory.json Schema

Optional telemetry file written by agent to `$OUTPUT_DIR/trajectory.json`.

## Required Fields

```json
{
  "schema_version": "1.0",
  "instance_id": "$INSTANCE_ID"
}
```

## Full Schema

```json
{
  "schema_version": "1.0",
  "instance_id": "django__django-11099",
  "model": "claude-sonnet-4-6",
  "total_tokens": 48500,
  "prompt_tokens": 36000,
  "completion_tokens": 12500,
  "total_latency_ms": 95000,
  "cache_read_tokens": 14000,
  "cache_write_tokens": 4000,
  "steps": [
    {
      "step": 1,
      "type": "tool_call",
      "tool": "Bash",
      "input": {"command": "find /testbed -name '*.py' | head"},
      "output_tokens": 42,
      "latency_ms": 310,
      "cache_hit": true
    }
  ]
}
```

## Field Descriptions

| Field | Type | Required | Description |
|---|---|---|---|
| `schema_version` | string | Yes | Always "1.0" |
| `instance_id` | string | Yes | From `$INSTANCE_ID` env var |
| `model` | string | No | Model name/ID |
| `total_tokens` | int | No | prompt_tokens + completion_tokens |
| `prompt_tokens` | int | No | Total input tokens |
| `completion_tokens` | int | No | Total output tokens |
| `total_latency_ms` | int | No | Wall-clock time in ms |
| `cache_read_tokens` | int | No | Tokens served from cache |
| `cache_write_tokens` | int | No | Tokens written to cache |
| `steps[]` | array | No | Ordered agent steps |

## Step Types

- `tool_call` — Agent called a tool (Bash, Read, Edit, etc.)
- `model_call` — Agent made an LLM API call
- `observation` — Agent received tool output

## Metrics Computed from Trajectories

The platform aggregates these across all instances in a run:
- `resolve_rate` = resolved / total
- `avg_tokens`, `p50_tokens`, `p95_tokens`
- `avg_latency_ms`, `p50_latency_ms`, `p95_latency_ms`
- `avg_tool_calls` per instance
- `cache_hit_rate`

## Minimal Trajectory (when you can't parse agent output)

```bash
echo '{"schema_version":"1.0","instance_id":"'"$INSTANCE_ID"'","total_tokens":0,"steps":[]}' \
  > "$OUTPUT_DIR/trajectory.json"
```
