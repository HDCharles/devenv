#!/bin/bash
# Parallel Job Execution Utilities
# Provides GPU-aware parallel job execution with stage-based synchronization
#
# Usage:
#   source parallel_utils.sh
#   get_reserved_gpus
#   start_stage "stage_name"
#   do_parallel [-n N] [-l label] command [args...]
#
# After launching a job:
#   $PARALLEL_LAST_LOG contains the log file path
#   get_stage_logs returns all log files from current stage

# ── Configuration ────────────────────────────────────────────────────────────

PARALLEL_LOGS_DIR="${PARALLEL_LOGS_DIR:-./parallel_logs}"
PARALLEL_POLL_INTERVAL="${PARALLEL_POLL_INTERVAL:-0.5}"

# ── Internal State ───────────────────────────────────────────────────────────

# GPU tracking
declare -a AVAILABLE_GPUS
declare -A GPU_IN_USE

# Job tracking (parallel arrays)
declare -a PARALLEL_JOBS_PIDS
declare -a PARALLEL_JOBS_GPUS
declare -a PARALLEL_JOBS_LOGS

# Stage tracking
CURRENT_STAGE=""
declare -a CURRENT_STAGE_LOGS

# Last log file (set by do_parallel)
PARALLEL_LAST_LOG=""

# ── GPU Detection and Initialization ─────────────────────────────────────────

get_reserved_gpus() {
    local current_user=$(whoami)

    echo "Detecting reserved GPUs via chg status..."

    # Parse chg status to find GPUs reserved by current user
    # Strip ANSI codes, parse table, find IN_USE rows with current user
    local reserved=$(chg status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | \
        awk -F '│' -v user="$current_user" 'NR > 2 && $3 ~ user && $2 ~ /IN_USE/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $1);
            print $1
        }')

    if [ -z "$reserved" ]; then
        echo "ERROR: No GPUs reserved. Please reserve GPUs using 'chg reserve <gpu_ids>' first."
        echo "Example: chg reserve 0,1,2,3"
        return 1
    fi

    # Populate AVAILABLE_GPUS array
    AVAILABLE_GPUS=($reserved)

    # Initialize GPU_IN_USE tracking (all GPUs start as available)
    for gpu in "${AVAILABLE_GPUS[@]}"; do
        GPU_IN_USE[$gpu]=0
    done

    echo "Reserved GPUs detected: ${AVAILABLE_GPUS[@]}"
    echo ""
}

# ── Helper: Release GPU ──────────────────────────────────────────────────────

_release_gpu() {
    local gpu=$1
    GPU_IN_USE[$gpu]=0
}

# ── Helper: Cleanup Completed Jobs ───────────────────────────────────────────

_cleanup_completed_jobs() {
    local new_pids=()
    local new_gpus=()
    local new_logs=()

    for i in "${!PARALLEL_JOBS_PIDS[@]}"; do
        local pid="${PARALLEL_JOBS_PIDS[$i]}"

        if kill -0 "$pid" 2>/dev/null; then
            # Still running, keep it
            new_pids+=("$pid")
            new_gpus+=("${PARALLEL_JOBS_GPUS[$i]}")
            new_logs+=("${PARALLEL_JOBS_LOGS[$i]}")
        else
            # Job finished, release its GPUs and report status
            local log_file="${PARALLEL_JOBS_LOGS[$i]}"
            local gpu_list="${PARALLEL_JOBS_GPUS[$i]}"
            IFS=',' read -ra gpus_array <<< "$gpu_list"
            for gpu in "${gpus_array[@]}"; do
                _release_gpu "$gpu"
            done

            wait "$pid" 2>/dev/null
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                echo "[Success] PID $pid | GPU(s) $gpu_list released | Log: $log_file"
            else
                echo "[FAILED] PID $pid | Exit code $exit_code | GPU(s) $gpu_list released | Log: $log_file"
            fi
        fi
    done

    # Update arrays
    PARALLEL_JOBS_PIDS=("${new_pids[@]}")
    PARALLEL_JOBS_GPUS=("${new_gpus[@]}")
    PARALLEL_JOBS_LOGS=("${new_logs[@]}")
}

# ── Helper: Allocate GPUs (internal) ────────────────────────────────────────

_allocate_gpus() {
    local need=$1
    _ALLOCATED_GPUS=""

    # Validate need is not greater than available GPUs
    if [ "$need" -gt "${#AVAILABLE_GPUS[@]}" ]; then
        echo "WARNING: Requesting $need GPUs but only ${#AVAILABLE_GPUS[@]} available. This will block forever." >&2
    fi

    # Poll until N GPUs are available
    while true; do
        # Clean up any completed jobs first
        _cleanup_completed_jobs

        local allocated=()

        # Try to allocate N available GPUs
        for gpu in "${AVAILABLE_GPUS[@]}"; do
            if [ "${GPU_IN_USE[$gpu]}" -eq 0 ]; then
                allocated+=("$gpu")
                if [ "${#allocated[@]}" -eq "$need" ]; then
                    # Found enough GPUs, claim them
                    for g in "${allocated[@]}"; do
                        GPU_IN_USE[$g]=1
                    done

                    # Set result variable (not echo — avoids subshell)
                    _ALLOCATED_GPUS=$(IFS=,; echo "${allocated[*]}")
                    return 0
                fi
            fi
        done

        # Not enough GPUs available, sleep and retry
        sleep "$PARALLEL_POLL_INTERVAL"
    done
}

# ── Job Launcher ─────────────────────────────────────────────────────────────

do_parallel() {
    if [ $# -lt 1 ]; then
        echo "ERROR: do_parallel requires at least 1 argument: command" >&2
        return 1
    fi

    local need=1
    local label="${CURRENT_STAGE:-job}"

    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n)
                need="$2"
                shift 2
                ;;
            -l)
                label="$2"
                shift 2
                ;;
            *)
                # End of options, remaining args are the command
                break
                ;;
        esac
    done

    local cmd=("$@")

    if [ ${#cmd[@]} -eq 0 ]; then
        echo "ERROR: do_parallel requires a command after options" >&2
        return 1
    fi

    # Allocate GPUs (blocks until available)
    _allocate_gpus "$need"
    local gpus="$_ALLOCATED_GPUS"

    # Create log directory
    mkdir -p "$PARALLEL_LOGS_DIR"

    # Generate unique log file name with label
    local timestamp=$(date +%Y%m%d-%H%M)
    local log_file="$PARALLEL_LOGS_DIR/${timestamp}-${label}.log"

    # Ensure unique log file (append counter if collision)
    local counter=1
    while [ -f "$log_file" ]; do
        log_file="$PARALLEL_LOGS_DIR/${timestamp}-${label}_${counter}.log"
        ((counter++))
    done

    # Launch command in background with GPU environment
    echo "Command: ${cmd[*]}" > "$log_file"
    CUDA_VISIBLE_DEVICES="$gpus" "${cmd[@]}" >> "$log_file" 2>&1 &
    local pid=$!

    # Track job
    PARALLEL_JOBS_PIDS+=("$pid")
    PARALLEL_JOBS_GPUS+=("$gpus")
    PARALLEL_JOBS_LOGS+=("$log_file")
    CURRENT_STAGE_LOGS+=("$log_file")

    # Set last log for easy access
    PARALLEL_LAST_LOG="$log_file"

    printf "[Started] PID $pid | GPU(s) $gpus | Log: $log_file"
}

# ── Stage Management ─────────────────────────────────────────────────────────

start_stage() {
    local stage_name="$1"

    # If this is the first stage, just set it and return
    if [ -z "$CURRENT_STAGE" ]; then
        CURRENT_STAGE="$stage_name"
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo "STAGE: $stage_name"
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        return 0
    fi

    # Wait for all running jobs to complete
    if [ ${#PARALLEL_JOBS_PIDS[@]} -gt 0 ]; then
        local total=${#PARALLEL_JOBS_PIDS[@]}
        echo ""
        echo "Waiting for $total job(s) from stage '$CURRENT_STAGE' to complete..."
        echo ""

        local completed=0
        local failed=0
        local pending_pids=("${PARALLEL_JOBS_PIDS[@]}")
        local pending_gpus=("${PARALLEL_JOBS_GPUS[@]}")
        local pending_logs=("${PARALLEL_JOBS_LOGS[@]}")

        while [ ${#pending_pids[@]} -gt 0 ]; do
            local new_pids=()
            local new_gpus=()
            local new_logs=()
            local found_one=false

            for i in "${!pending_pids[@]}"; do
                local pid="${pending_pids[$i]}"
                if ! kill -0 "$pid" 2>/dev/null; then
                    local log_file="${pending_logs[$i]}"
                    local gpu_list="${pending_gpus[$i]}"

                    wait "$pid" 2>/dev/null
                    local exit_code=$?

                    IFS=',' read -ra gpus_array <<< "$gpu_list"
                    for gpu in "${gpus_array[@]}"; do
                        _release_gpu "$gpu"
                    done

                    completed=$((completed + 1))
                    local remaining=$((total - completed))

                    if [ $exit_code -eq 0 ]; then
                        echo "[${completed}/${total}] Success PID $pid | GPU(s) $gpu_list released ($remaining remaining) | Log: $log_file"
                    else
                        echo "[${completed}/${total}] FAILED PID $pid | Exit $exit_code | GPU(s) $gpu_list released ($remaining remaining) | Log: $log_file"
                        ((failed++))
                    fi
                    found_one=true
                else
                    new_pids+=("$pid")
                    new_gpus+=("${pending_gpus[$i]}")
                    new_logs+=("${pending_logs[$i]}")
                fi
            done

            pending_pids=("${new_pids[@]}")
            pending_gpus=("${new_gpus[@]}")
            pending_logs=("${new_logs[@]}")

            if [ ${#pending_pids[@]} -gt 0 ]; then
                sleep "$PARALLEL_POLL_INTERVAL"
            fi
        done

        echo ""
        echo "Stage '$CURRENT_STAGE' complete: $((total - failed)) succeeded, $failed failed"
    fi

    # Clear job tracking arrays
    PARALLEL_JOBS_PIDS=()
    PARALLEL_JOBS_GPUS=()
    PARALLEL_JOBS_LOGS=()
    CURRENT_STAGE_LOGS=()

    # Move to next stage
    CURRENT_STAGE="$stage_name"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "STAGE: $stage_name"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
}

# ── Get Stage Logs ───────────────────────────────────────────────────────────

get_stage_logs() {
    # Returns all log files from the current stage
    for log in "${CURRENT_STAGE_LOGS[@]}"; do
        echo "$log"
    done
}
