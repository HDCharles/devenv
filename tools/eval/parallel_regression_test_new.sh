#!/bin/bash
# Parallel Regression Test Script (Simplified)
# Uses parallel_utils.sh for GPU management and parallel execution
# Uses eval_utils.sh for evaluation functions

set -o pipefail

# ── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export HF_DATASETS_CACHE="$HOME/hf_hub"
export PYTHONUNBUFFERED=1
mkdir -p "$HF_DATASETS_CACHE"

MODEL_BASE_DIR="$HOME/hf_hub/regression_models"
EVAL_BASE_DIR="$SCRIPT_DIR/eval_results"
RESULTS_CSV="$SCRIPT_DIR/parallel_regression_results.csv"

# Override parallel_utils log directory
export PARALLEL_LOGS_DIR="$SCRIPT_DIR/eval_logs"

# Venv presets (set to "" to skip activation)
QUANTIZE_VENV="/home/HDCharles/rhdev/bin/activate"

# Models to test
declare -A MODELS=(
    ["Qwen/Qwen2.5-3B-Instruct"]="Qwen2.5-3B-Instruct,2048,1"
    # ["Qwen/Qwen1.5-MoE-A2.7B-Chat"]="Qwen1.5-MoE-A2.7B-Chat,2048,1"
    ["meta-llama/Meta-Llama-3-8B-Instruct"]="Meta-Llama-3-8B-Instruct,2048,1"
    ["google/gemma-4-12B-it"]="gemma-4-12B-it,4096,1"
    ["Qwen/Qwen3.5-27B"]="Qwen3.5-27B,2048,1"
    ["Qwen/Qwen3-30B-A3B"]="Qwen3-30B-A3B,2048,2"
    ["meta-llama/Llama-4-Scout-17B-16E-Instruct"]="Llama-4-Scout-17B-16E-Instruct,2048,2"
)

# TECHNIQUES=("awq_rtn" "awq_smooth" "awq_no_up_down" "rtn" "rtn_mse" "gptq" "imatrix")
TECHNIQUES=("awq_rtn" "awq_smooth" "awq_no_up_down")
# BRANCHES=("main" "mapping_reordering")
BRANCHES=("mapping_reordering")
SCHEMES=("NVFP4A16" "W4A16")

EVAL_TASKS=("wikitext" "mmlu" "gsm8k_platinum")
EVAL_LM_TASKS=("wikitext" "mmlu" "gsm8k_platinum")
EVAL_FEWSHOT=("0" "5" "5")

# Sanitize branch name for use in directory/file names (e.g. "feature/foo" -> "feature_foo")
sanitize_branch() {
    echo "${1//\//_}"
}

mkdir -p "$EVAL_BASE_DIR" "$MODEL_BASE_DIR" "$PARALLEL_LOGS_DIR"

# ── Source Utilities ────────────────────────────────────────────────────────

source "$SCRIPT_DIR/parallel_utils.sh"
source "$SCRIPT_DIR/eval_utils.sh"
get_reserved_gpus

# Eval config
eval_set_venv "/home/HDCharles/vllm/bin/activate"
eval_set_mode "direct"  # resets all eval config

# ── Helper: checkout branch and reinstall ────────────────────────────────────

switch_branch() {
    local branch=$1
    echo "════════════════════════════════════════════════════════════════"
    echo "Switching to branch: $branch"
    echo "════════════════════════════════════════════════════════════════"
    git -C "$REPO_DIR" checkout "$branch" 2>&1 | tail -5
    if [ $? -ne 0 ]; then
        echo "ERROR: git checkout $branch failed"
        return 1
    fi
    [ -n "$QUANTIZE_VENV" ] && source "$QUANTIZE_VENV"
    pip install -e "$REPO_DIR" 2>&1 | tail -1
    echo ""
}

# ── Stage 1: Quantize all branches ─────────────────────────────────────────

for branch in "${BRANCHES[@]}"; do
    safe_branch=$(sanitize_branch "$branch")
    start_stage "quantize_${safe_branch}"

    switch_branch "$branch"

    for model_key in "${!MODELS[@]}"; do
        IFS=',' read -r model_short max_len tp_size <<< "${MODELS[$model_key]}"

        for scheme in "${SCHEMES[@]}"; do
            for technique in "${TECHNIQUES[@]}"; do
                save_dir="$MODEL_BASE_DIR/${model_short}-${scheme}-${technique}-${safe_branch}"

                if [ -d "$save_dir" ] && [ -f "$save_dir/config.json" ]; then
                    echo "[Skip] $model_short / $scheme / $technique / $branch (already exists)"
                    continue
                fi

                do_parallel bash -c "
                    [ -n '$QUANTIZE_VENV' ] && source '$QUANTIZE_VENV'
                    python '$REPO_DIR/testing/quantize.py' \
                        --model '$model_key' \
                        --technique '$technique' \
                        --scheme '$scheme' \
                        --save-dir '$save_dir'
                "
                echo " <- [Quantize] $model_short / $scheme / $technique / $branch"
            done
        done
    done
done

# ── Baseline evals (unquantized models) ───────────────────────────────────────

for model_key in "${!MODELS[@]}"; do
    IFS=',' read -r model_short max_len tp_size <<< "${MODELS[$model_key]}"

    for eval_idx in "${!EVAL_TASKS[@]}"; do
        task_name="${EVAL_TASKS[$eval_idx]}"
        lm_task="${EVAL_LM_TASKS[$eval_idx]}"
        fewshot="${EVAL_FEWSHOT[$eval_idx]}"
        eval_dir="$EVAL_BASE_DIR/${model_short}-baseline/${task_name}"

        if find "$eval_dir" -name "results_*.json" -type f 2>/dev/null | grep -q .; then
            echo "[Skip] Baseline $model_short / $task_name (cached)"
            continue
        fi

        eval_set_model "$model_key"
        eval_reset_model_args
        eval_set_model_args max_model_len "$max_len"
        eval_set_model_args gpu_memory_utilization 0.9
        if [ "$tp_size" -gt 1 ]; then
            eval_set_model_args tensor_parallel_size "$tp_size"
        fi

        eval_reset_lmeval_config
        eval_set_lmeval_config --model vllm
        eval_set_lmeval_config --batch_size auto
        if [ "$task_name" != "wikitext" ]; then
            eval_set_lmeval_config --apply_chat_template
        fi
        if [ "$fewshot" -gt 0 ]; then
            eval_set_lmeval_config --fewshot_as_multiturn
        fi
        eval_set_lmeval_config --tasks "$lm_task"
        eval_set_lmeval_config --num_fewshot "$fewshot"
        eval_set_lmeval_config --output_path "$eval_dir"

        do_parallel -n "$tp_size" bash -c "run_eval"
        echo " <- [Baseline] $model_short / $task_name (${fewshot}-shot)"
    done
done

# ── Quantized model evals (launch as models become ready) ─────────────────────

# Build list of all eval jobs needed
declare -a EVAL_QUEUE_KEYS=()
declare -A EVAL_QUEUE_MODEL_KEY=()
declare -A EVAL_QUEUE_LAUNCHED=()

for model_key in "${!MODELS[@]}"; do
    IFS=',' read -r model_short max_len tp_size <<< "${MODELS[$model_key]}"
    for scheme in "${SCHEMES[@]}"; do
        for technique in "${TECHNIQUES[@]}"; do
            for branch in "${BRANCHES[@]}"; do
                safe_branch=$(sanitize_branch "$branch")
                for eval_idx in "${!EVAL_TASKS[@]}"; do
                    task_name="${EVAL_TASKS[$eval_idx]}"
                    eval_dir="$EVAL_BASE_DIR/${model_short}-${scheme}-${technique}-${safe_branch}/${task_name}"

                    if find "$eval_dir" -name "results_*.json" -type f 2>/dev/null | grep -q .; then
                        echo "[Skip] Eval $model_short / $scheme / $technique / $branch / $task_name (cached)"
                        continue
                    fi

                    local_key="${model_short}|${scheme}|${technique}|${safe_branch}|${eval_idx}"
                    EVAL_QUEUE_KEYS+=("$local_key")
                    EVAL_QUEUE_MODEL_KEY["$local_key"]="$model_key"
                    EVAL_QUEUE_LAUNCHED["$local_key"]=0
                done
            done
        done
    done
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "STAGE: evaluate (${#EVAL_QUEUE_KEYS[@]} jobs queued)"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Poll: launch eval jobs as their quantized models become ready
while true; do
    all_launched=true
    for local_key in "${EVAL_QUEUE_KEYS[@]}"; do
        [ "${EVAL_QUEUE_LAUNCHED[$local_key]}" -eq 1 ] && continue

        IFS='|' read -r model_short scheme technique safe_branch eval_idx <<< "$local_key"
        save_dir="$MODEL_BASE_DIR/${model_short}-${scheme}-${technique}-${safe_branch}"

        if [ ! -f "$save_dir/config.json" ]; then
            all_launched=false
            continue
        fi

        model_key="${EVAL_QUEUE_MODEL_KEY[$local_key]}"
        IFS=',' read -r _ max_len tp_size <<< "${MODELS[$model_key]}"
        task_name="${EVAL_TASKS[$eval_idx]}"
        lm_task="${EVAL_LM_TASKS[$eval_idx]}"
        fewshot="${EVAL_FEWSHOT[$eval_idx]}"
        eval_dir="$EVAL_BASE_DIR/${model_short}-${scheme}-${technique}-${safe_branch}/${task_name}"

        eval_set_model "$save_dir"
        eval_reset_model_args
        eval_set_model_args max_model_len "$max_len"
        eval_set_model_args gpu_memory_utilization 0.9
        if [ "$tp_size" -gt 1 ]; then
            eval_set_model_args tensor_parallel_size "$tp_size"
        fi

        eval_reset_lmeval_config
        eval_set_lmeval_config --model vllm
        eval_set_lmeval_config --batch_size auto
        if [ "$task_name" != "wikitext" ]; then
            eval_set_lmeval_config --apply_chat_template
        fi
        if [ "$fewshot" -gt 0 ]; then
            eval_set_lmeval_config --fewshot_as_multiturn
        fi
        eval_set_lmeval_config --tasks "$lm_task"
        eval_set_lmeval_config --num_fewshot "$fewshot"
        eval_set_lmeval_config --output_path "$eval_dir"

        do_parallel -n "$tp_size" bash -c "run_eval"
        echo " <- [Eval] $model_short / $scheme / $technique / $safe_branch / $task_name (${fewshot}-shot)"
        EVAL_QUEUE_LAUNCHED["$local_key"]=1
    done

    if $all_launched; then
        break
    fi

    # Some models not ready yet — wait a bit and check again
    _cleanup_completed_jobs
    sleep 2
done

# ── Done ─────────────────────────────────────────────────────────────────────

start_stage "done"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║  ALL JOBS COMPLETE                                                         ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Logs directory: $PARALLEL_LOGS_DIR"
echo ""
