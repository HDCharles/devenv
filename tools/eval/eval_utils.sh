#!/bin/bash
# Evaluation Utilities
# Provides a stateful config API for running lm-eval evaluations,
# extracting metrics from results, and printing comparison tables.
#
# Usage:
#   source eval_utils.sh
#
#   eval_set_venv "/path/to/venv/bin/activate"
#   eval_set_mode "direct"
#
#   eval_set_model "/path/to/model"
#   eval_set_model_args dtype auto
#   eval_set_model_args add_bos_token True
#
#   eval_set_lmeval_config --model hf
#   eval_set_lmeval_config --tasks wikitext
#   eval_set_lmeval_config --num_fewshot 0
#   eval_set_lmeval_config --batch_size auto
#   eval_set_lmeval_config --apply_chat_template
#   eval_set_lmeval_config --output_path "/path/to/output"
#
#   # For served mode:
#   eval_set_serve_config tensor-parallel-size 2
#   eval_set_serve_config gpu-memory-utilization 0.85
#
#   do_parallel bash -c "run_eval"
#
# Config vars (optional):
#   VLLM_BASE_PORT   - base port for vllm serve mode (default: 8100)
#   RESULTS_CSV      - path to results CSV for print_comparison

export VLLM_BASE_PORT="${VLLM_BASE_PORT:-8100}"

# ── Setters ─────────────────────────────────────────────────────────────────

eval_set_venv() {
    export _EVAL_VENV="$1"
}

eval_set_mode() {
    export _EVAL_MODE="$1"
    export _EVAL_MODEL_ARGS=""
    export _EVAL_SERVE_ARGS=""
    export _EVAL_EVAL_ARGS=""
}

eval_set_model() {
    export _EVAL_MODEL="$1"
}

eval_set_model_args() {
    local key=$1
    local value=$2
    if [ -z "$_EVAL_MODEL_ARGS" ]; then
        export _EVAL_MODEL_ARGS="${key}=${value}"
    else
        export _EVAL_MODEL_ARGS="${_EVAL_MODEL_ARGS},${key}=${value}"
    fi
}

eval_set_serve_config() {
    local key=$1
    local value=$2
    if [ "$_EVAL_MODE" != "served" ]; then
        echo "ERROR: eval_set_serve_config requires mode 'served' (current: '$_EVAL_MODE')" >&2
        return 1
    fi
    export _EVAL_SERVE_ARGS="${_EVAL_SERVE_ARGS} --${key} ${value}"
}

eval_set_lmeval_config() {
    local flag=$1
    local value=$2
    if [ -n "$value" ]; then
        export _EVAL_EVAL_ARGS="${_EVAL_EVAL_ARGS} ${flag} ${value}"
    else
        export _EVAL_EVAL_ARGS="${_EVAL_EVAL_ARGS} ${flag}"
    fi
}

# ── Resets ──────────────────────────────────────────────────────────────────

eval_reset_model_args() {
    export _EVAL_MODEL_ARGS=""
}

eval_reset_serve_config() {
    export _EVAL_SERVE_ARGS=""
}

eval_reset_lmeval_config() {
    export _EVAL_EVAL_ARGS=""
}

# ── run_eval ────────────────────────────────────────────────────────────────

run_eval() {
    echo "============================================================"
    echo "Eval Configuration"
    echo "============================================================"
    echo "  Model:      ${_EVAL_MODEL}"
    echo "  Mode:       ${_EVAL_MODE}"
    echo "  Model args: ${_EVAL_MODEL_ARGS}"
    echo "  Eval args:  ${_EVAL_EVAL_ARGS}"
    [ "$_EVAL_MODE" == "served" ] && echo "  Serve args: ${_EVAL_SERVE_ARGS}"
    echo "============================================================"
    echo ""

    if [ -n "$_EVAL_VENV" ]; then
        source "$_EVAL_VENV"
    fi

    if [ "$_EVAL_MODE" == "served" ]; then
        _run_eval_served
    else
        _run_eval_direct
    fi
}

_run_eval_direct() {
    local model_args="pretrained=${_EVAL_MODEL}"
    if [ -n "$_EVAL_MODEL_ARGS" ]; then
        model_args="${model_args},${_EVAL_MODEL_ARGS}"
    fi

    lm_eval --model_args "$model_args" $_EVAL_EVAL_ARGS
}

_run_eval_served() {
    local gpu_id="${CUDA_VISIBLE_DEVICES%%,*}"
    local port=$(( VLLM_BASE_PORT + gpu_id ))
    local server_pid=""

    _eval_cleanup_server() {
        if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
            echo "Stopping vllm server (PID $server_pid)..."
            kill "$server_pid" 2>/dev/null
            wait "$server_pid" 2>/dev/null
        fi
    }
    trap _eval_cleanup_server EXIT

    echo "Starting vllm serve on port $port..."
    vllm serve "$_EVAL_MODEL" \
        $_EVAL_SERVE_ARGS \
        --port "$port" &
    server_pid=$!

    local timeout=300
    local elapsed=0
    echo "Waiting for vllm server to be ready (timeout: ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        if curl -s "http://localhost:${port}/health" > /dev/null 2>&1; then
            echo "vllm server ready after ${elapsed}s"
            break
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
            echo "ERROR: vllm server process died during startup"
            return 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge $timeout ]; then
        echo "ERROR: vllm server failed to start within ${timeout}s"
        _eval_cleanup_server
        return 1
    fi

    local base_url="http://localhost:${port}/v1/chat/completions"
    local model_args="model=${_EVAL_MODEL},base_url=${base_url}"
    if [ -n "$_EVAL_MODEL_ARGS" ]; then
        model_args="${model_args},${_EVAL_MODEL_ARGS}"
    fi

    lm_eval \
        --model local-chat-completions \
        --model_args "$model_args" \
        $_EVAL_EVAL_ARGS
    local eval_exit=$?

    _eval_cleanup_server
    trap - EXIT

    return $eval_exit
}

# ── extract_metric ──────────────────────────────────────────────────────────
# Extracts the primary metric from lm-eval JSON results.
#
# Args: eval_output_dir task_name

extract_metric() {
    local eval_output_dir=$1
    local task=$2

    local results_json
    results_json=$(find "$eval_output_dir" -name "results_*.json" -type f 2>/dev/null | sort | tail -1)

    if [ -z "$results_json" ]; then
        echo "N/A"
        return
    fi

    python3 -c "
import json, sys
with open('$results_json') as f:
    data = json.load(f)
results = data.get('results', {})
task = '$task'

task_results = None
for key in results:
    if task in key:
        task_results = results[key]
        break

if task_results is None:
    print('N/A')
    sys.exit()

if 'gsm8k' in task:
    val = task_results.get('exact_match,strict-match')
    if val is not None:
        print(f'{val*100:.2f}%')
    else:
        print('N/A')
elif 'wikitext' in task:
    val = task_results.get('word_perplexity,none')
    if val is not None:
        print(f'{val:.2f}')
    else:
        print('N/A')
elif 'mmlu' in task:
    val = task_results.get('acc,none')
    if val is not None:
        print(f'{val*100:.2f}%')
    else:
        print('N/A')
else:
    for k, v in task_results.items():
        if 'stderr' not in k and k != 'alias' and isinstance(v, (int, float)):
            print(f'{v:.4f}')
            sys.exit()
    print('N/A')
" 2>/dev/null || echo "N/A"
}

# ── print_comparison ────────────────────────────────────────────────────────
# Prints a branch comparison table from the results CSV.
#
# Args: results_csv (optional, defaults to $RESULTS_CSV)

print_comparison() {
    local csv_path="${1:-$RESULTS_CSV}"

    if [ ! -f "$csv_path" ]; then
        return
    fi

    python3 - "$csv_path" <<'PYEOF'
import csv, sys

csv_path = sys.argv[1]

rows = []
with open(csv_path) as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get('status') in ['PASSED', 'CACHED']:
            rows.append(r)

if not rows:
    sys.exit()

lookup = {}
for r in rows:
    key = (r["model"], r["scheme"], r["technique"], r["task"])
    lookup.setdefault(key, {})
    lookup[key][r["branch"]] = r["metric"]

entries = [(k, v) for k, v in lookup.items()
           if "main" in v and any(b != "main" for b in v)]
if not entries:
    sys.exit()

pr_branch = [b for b in next(iter(lookup.values())) if b != "main"]
pr_branch = pr_branch[0] if pr_branch else "pr"

def parse_metric(s):
    s = s.strip()
    if s.endswith("%"):
        try:
            return float(s[:-1]), True
        except ValueError:
            return None, False
    try:
        return float(s), False
    except ValueError:
        return None, False

def calc_change(main_str, pr_str, task):
    m_val, _ = parse_metric(main_str)
    p_val, _ = parse_metric(pr_str)
    if m_val is None or p_val is None or m_val == 0:
        return "N/A"
    if "wikitext" in task:
        pct = (m_val - p_val) / m_val * 100
    else:
        pct = (p_val - m_val) / m_val * 100
    sign = "+" if pct >= 0 else ""
    return f"{sign}{pct:.2f}%"

print("")
print("=" * 120)
print(f"  BRANCH COMPARISON (main vs {pr_branch})")
print("=" * 120)
print("")

header = (f"{'model':<30} {'scheme':<10} {'technique':<16} {'task':<18} "
          f"{'main':>14} {'PR':>14} {'change':>12}")
print(header)
print("-" * len(header))

for (model, scheme, technique, task), metrics in sorted(entries):
    m = metrics.get("main", "")
    p = metrics.get(pr_branch, "")
    change = calc_change(m, p, task) if m and p else ""
    print(f"{model:<30} {scheme:<10} {technique:<16} {task:<18} "
          f"{m:>14} {p:>14} {change:>12}")

print("")
PYEOF
}

# ── Export all functions for bash -c subshells ──────────────────────────────

export -f eval_set_venv eval_set_mode eval_set_model
export -f eval_set_model_args eval_set_serve_config eval_set_lmeval_config
export -f eval_reset_model_args eval_reset_serve_config eval_reset_lmeval_config
export -f run_eval _run_eval_direct _run_eval_served
export -f extract_metric print_comparison
