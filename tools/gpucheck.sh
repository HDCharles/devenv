#!/bin/bash

# === Configuration ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_CONFIG="$HOME/.ssh/config"
STATE_FILE="$SCRIPT_DIR/.gpucheck_state.json"
LAST_SYNC_FILE="$SCRIPT_DIR/.gpucheck_last_sync"
INVENTORY_REPO="neuralmagic/nm-alchemy"
INVENTORY_WORKFLOW="Inventory Site"
POLL_INTERVAL=300  # seconds between checks (5 minutes)
# Three EMA alpha values for different time horizons
EMA_ALPHA_FAST=0.0024   # 1 day half-life
EMA_ALPHA_MED=0.00034   # 7 day half-life (used for coloring)
EMA_ALPHA_SLOW=0.000086 # 28 day half-life

# === Get SSH username from gh auth ===
load_ssh_user() {
    SSH_USER=$(gh api user --jq '.login' 2>/dev/null)
    if [ -z "$SSH_USER" ]; then
        echo "⚠️  Could not get username. Is 'gh' authenticated? Run: gh auth login"
        exit 1
    fi
}

# === Sync hosts from remote (when a new inventory run is available) ===
sync_ssh_config() {
    local run_id
    run_id=$(gh run list -R "${INVENTORY_REPO}" -w "${INVENTORY_WORKFLOW}" -s completed --json databaseId,conclusion --jq '[.[] | select(.conclusion=="success")][0].databaseId' 2>/dev/null)

    if [ -z "$run_id" ]; then
        echo "⚠️  Could not find a successful '${INVENTORY_WORKFLOW}' workflow run. Is 'gh' authenticated?"
        return 1
    fi

    local last_synced_run=""
    [ -f "$LAST_SYNC_FILE" ] && last_synced_run=$(cat "$LAST_SYNC_FILE")

    if [ "$run_id" = "$last_synced_run" ]; then
        echo "📋 Already synced with latest inventory run ($run_id)"
        return 0
    fi

    if [ -n "$last_synced_run" ]; then
        echo "📋 Last synced with run: $last_synced_run"
    else
        echo "📋 Host list has never been synced"
    fi
    echo "📡 New inventory run available ($run_id), syncing..."

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN

    if ! gh run download "$run_id" -R "${INVENTORY_REPO}" -n github-pages -D "$tmpdir" 2>/dev/null; then
        echo "⚠️  Artifact expired. Triggering a fresh workflow run..."
        local new_run_url
        new_run_url=$(gh workflow run "${INVENTORY_WORKFLOW}" -R "${INVENTORY_REPO}" 2>&1)
        local new_run_id
        new_run_id=$(echo "$new_run_url" | grep -o '[0-9]*$')

        if [ -z "$new_run_id" ]; then
            echo "⚠️  Could not trigger workflow. Check gh auth."
            return 1
        fi

        echo "⏳ Waiting for run ${new_run_id} to complete..."
        if ! gh run watch "$new_run_id" -R "${INVENTORY_REPO}" --exit-status >/dev/null 2>&1; then
            echo "⚠️  Workflow run failed."
            return 1
        fi

        run_id="$new_run_id"
        if ! gh run download "$run_id" -R "${INVENTORY_REPO}" -n github-pages -D "$tmpdir" 2>/dev/null; then
            echo "⚠️  Could not download artifact from fresh run."
            return 1
        fi
    fi

    tar xf "$tmpdir/artifact.tar" -C "$tmpdir" data/inventory.json 2>/dev/null

    local raw
    raw=$(cat "$tmpdir/data/inventory.json" 2>/dev/null)

    if [ -z "$raw" ]; then
        echo "⚠️  Could not extract inventory from workflow artifact."
        return 1
    fi

    local existing_aliases
    existing_aliases=$(awk '/^Host[[:space:]]/ && $2 !~ /\*/ && $2 !~ /^#/ {print $2}' "$SSH_CONFIG")

    local new_block=""
    local added=0

    local parsed
    parsed=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
for host in data.get('allHosts', []):
    addr = host.get('address', '')
    name = host.get('name', '')
    access = host.get('meta', {}).get('developer_access', False)
    if access and addr and name and not any(c.isalpha() for c in addr):
        print(f'{addr}\t{name}')
" <<< "$raw" 2>/dev/null)

    if [ -z "$parsed" ]; then
        echo "⚠️  Could not parse any hosts from inventory. Will retry next run."
        return 1
    fi

    while IFS=$'\t' read -r ip alias _rest; do
        [ -z "$ip" ] || [ -z "$alias" ] && continue
        if ! echo "$existing_aliases" | grep -qxF "$alias"; then
            new_block+="Host ${alias}
  HostName ${ip}
  User ${SSH_USER}

"
            added=$((added + 1))
        fi
    done <<< "$parsed"

    if [ "$added" -gt 0 ]; then
        if grep -q "^Host \*\.redhat\.com" "$SSH_CONFIG"; then
            local tmp block_file
            tmp=$(mktemp)
            export BLOCK_FILE=$(mktemp)
            printf "%s" "$new_block" > "$BLOCK_FILE"
            awk '
                /^Host \*\.redhat\.com/ {
                    while ((getline line < ENVIRON["BLOCK_FILE"]) > 0) print line
                }
                { print }
            ' "$SSH_CONFIG" > "$tmp" && mv "$tmp" "$SSH_CONFIG"
            rm -f "$BLOCK_FILE"
            unset BLOCK_FILE
        else
            printf "\n%s" "$new_block" >> "$SSH_CONFIG"
        fi
        echo "✅ Added $added new host(s) to SSH config"
    else
        echo "✅ SSH config is up to date"
    fi

    # Rename duplicate Host entries (stale IP) by appending -old
    local dup_aliases
    dup_aliases=$(awk '/^Host[[:space:]]/ && $2 !~ /\*/ && $2 !~ /^#/ {print $2}' "$SSH_CONFIG" | sort | uniq -d)
    if [ -n "$dup_aliases" ]; then
        local tmp
        tmp=$(mktemp)
        local renamed=0
        while IFS= read -r dup; do
            [ -z "$dup" ] && continue
            local seen=0
            awk -v alias="$dup" '
                /^Host[[:space:]]/ && $2 == alias {
                    count++
                    if (count == 1) { $2 = alias "-old"; $0 = "Host " $2 }
                }
                { print }
            ' "$SSH_CONFIG" > "$tmp" && mv "$tmp" "$SSH_CONFIG"
            renamed=$((renamed + 1))
        done <<< "$dup_aliases"
        echo "🔄 Renamed $renamed stale duplicate host(s) with -old suffix"
    fi

    echo "$run_id" > "$LAST_SYNC_FILE"
}

# === Parse SSH config ===
get_ssh_hosts() {
    awk '
        /^Host[[:space:]]/ {
            if ($2 !~ /\*/ && $2 !~ /^#/) {
                host = $2
            } else {
                host = ""
            }
        }
        /^[[:space:]]+HostName[[:space:]]/ {
            if (host != "") hostname = $2
        }
        /^[[:space:]]+User[[:space:]]/ {
            if (host != "" && hostname != "") {
                print host ":" hostname ":" $2
                host = ""
                hostname = ""
            }
        }
    ' "$SSH_CONFIG"
}

# === Load or initialize state ===
load_state() {
    if [ -f "$STATE_FILE" ]; then
        echo "Resuming from saved state: $STATE_FILE"
    else
        echo '{}' > "$STATE_FILE"
        echo "Starting fresh (no prior state found)"
    fi
}

# Update state after a poll for one host (single jq call)
update_state() {
    local host="$1"
    local gpus_used="$2"
    local total_gpus="$3"
    local is_8=$([ "$gpus_used" -ge 8 ] && echo 1 || echo 0)
    local is_4=$([ "$gpus_used" -ge 4 ] && echo 1 || echo 0)

    local tmp=$(mktemp)
    jq --arg h "$host" \
       --argjson gpus "$gpus_used" \
       --argjson total "$total_gpus" \
       --argjson is_8 "$is_8" \
       --argjson is_4 "$is_4" \
       --argjson af "$EMA_ALPHA_FAST" \
       --argjson am "$EMA_ALPHA_MED" \
       --argjson as "$EMA_ALPHA_SLOW" \
       --arg ts "$(date -Iseconds)" \
       '(.[$h] // {}) as $old |
       (($old.samples) // 0) as $t |
       ([1, (pow(2; -$t) + $af)] | min) as $eaf |
       ([1, (pow(2; -$t) + $am)] | min) as $eam |
       ([1, (pow(2; -$t) + $as)] | min) as $eas |
       .[$h] = {
           ema_avg_used_fast:  ($eaf * $gpus + (1-$eaf) * (($old.ema_avg_used_fast)  // 0)),
           ema_avg_used_med:   ($eam * $gpus + (1-$eam) * (($old.ema_avg_used_med)   // 0)),
           ema_avg_used_slow:  ($eas * $gpus + (1-$eas) * (($old.ema_avg_used_slow)  // 0)),
           ema_pct_8_used_fast:($eaf * $is_8 + (1-$eaf) * (($old.ema_pct_8_used_fast)// 0)),
           ema_pct_8_used_med: ($eam * $is_8 + (1-$eam) * (($old.ema_pct_8_used_med) // 0)),
           ema_pct_8_used_slow:($eas * $is_8 + (1-$eas) * (($old.ema_pct_8_used_slow)// 0)),
           ema_pct_4_used_fast:($eaf * $is_4 + (1-$eaf) * (($old.ema_pct_4_used_fast)// 0)),
           ema_pct_4_used_med: ($eam * $is_4 + (1-$eam) * (($old.ema_pct_4_used_med) // 0)),
           ema_pct_4_used_slow:($eas * $is_4 + (1-$eas) * (($old.ema_pct_4_used_slow)// 0)),
           samples: ($t + 1),
           last_gpus_used: $gpus,
           last_total_gpus: $total,
           last_seen: $ts,
           unreachable: false,
           unreachable_reason: null
       }' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# === Check a single host ===
check_host() {
    local host_alias="$1"
    local hostname="$2"
    local user="$3"
    local tmpfile="$4"

    local ssh_opts="-o ConnectTimeout=5 \
           -o ServerAliveInterval=5 \
           -o ServerAliveCountMax=1 \
           -o StrictHostKeyChecking=accept-new \
           -o BatchMode=yes \
           -o PasswordAuthentication=no \
           -o LogLevel=ERROR"

    # Run under 'script' to give SSH a fake tty — prevents the @@@
    # host-key-changed banner from writing directly to the real terminal.
    raw_output=$(script -q /dev/null ssh $ssh_opts \
           "${user}@${hostname}" \
           "timeout 10 canhazgpu status" 2>&1)
    local rc=$?
    output=$(printf '%s' "$raw_output" | tr -d '\r')

    if [ $rc -eq 0 ]; then
        available_count=$(echo "$output" | grep -c "AVAILABLE")
        total_count=$(echo "$output" | grep -E "^ [0-9]+ " | wc -l | tr -d ' ')
        gpus_used=$((total_count - available_count))
        echo "${host_alias}|${gpus_used}|${total_count}|${available_count}" > "$tmpfile"
    else
        if echo "$output" | grep -qi "REMOTE HOST IDENTIFICATION HAS CHANGED\|Host key verification failed"; then
            echo "${host_alias}|UNREACHABLE|HOST KEY CHANGED — run locally: ssh-keygen -R ${hostname}" > "$tmpfile"
        else
            # Check if SSH itself works (connection + auth) by running a trivial command
            ssh $ssh_opts "${user}@${hostname}" "true" < /dev/null 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "${host_alias}|UNREACHABLE|(connected) canhazgpu hung or failed — GPUs may be in a bad state" > "$tmpfile"
            else
                reason=$(echo "$output" | grep -v '^@' | tr '\n' ' ' | sed 's/|//g' | cut -c1-100)
                echo "${host_alias}|UNREACHABLE|${reason}" > "$tmpfile"
            fi
        fi
    fi
}

# === Process a single result file ===
process_single_result() {
    local tmpfile="$1"
    [ -f "$tmpfile" ] || return

    local line
    line=$(cat "$tmpfile")
    local host_alias
    host_alias=$(echo "$line" | cut -d'|' -f1)

    if ! echo "$line" | grep -q "UNREACHABLE"; then
        local gpus_used total_count
        gpus_used=$(echo "$line" | cut -d'|' -f2)
        total_count=$(echo "$line" | cut -d'|' -f3)
        update_state "$host_alias" "$gpus_used" "$total_count"
    else
        local reason
        reason=$(echo "$line" | cut -d'|' -f3-)
        local tmp=$(mktemp)
        jq --arg h "$host_alias" \
           --arg ts "$(date -Iseconds)" \
           --arg reason "$reason" \
           '.[$h].last_seen = $ts | .[$h].unreachable = true | .[$h].unreachable_reason = $reason' \
           "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    fi
}

# === Helper: Display table header/footer ===
display_table_frame() {
    local mode="$1"  # "header" or "footer"
    local col2_title="$2"

    if [ "$mode" = "header" ]; then
        printf "┌──────────────────────────────┬──────────────────────┬────────────────────────┬────────────────────────┬────────────────────────┐\n"
        printf "│ %-28s │ %-20s │ %-22s │ %-22s │ %-22s │\n" \
            "Server" "$col2_title" "Avg Used (1d/7d/28d)" "% Time >=8" "% Time >=4"
        printf "├──────────────────────────────┼──────────────────────┼────────────────────────┼────────────────────────┼────────────────────────┤\n"
    else
        printf "└──────────────────────────────┴──────────────────────┴────────────────────────┴────────────────────────┴────────────────────────┘\n"
        echo
        echo "Half-lives: 1 day / 7 days / 28 days  (at 5min polling interval)"
        echo
        echo "Server name colors (based on 7 day EMA):"
        echo "  \033[0;90mGray\033[0m = Unreachable/0 GPUs  |  \033[0;31mRed\033[0m = %Time>=8 > 25%  |  \033[0;33mOrange\033[0m = %Time>=8 > 10%  |  \033[0;32mGreen\033[0m = Low usage"
        echo
        echo "Availability colors:"
        echo "  \033[0;32mGreen\033[0m >= 6 avail  |  \033[0;33mYellow\033[0m >= 4 avail  |  \033[0;31mRed\033[0m 1-3 avail  |  \033[0;90mGray\033[0m = 0 avail or Unreachable"
        echo
        echo "Individual metric colors:"
        echo "  Avg Used: \033[0;32mGreen\033[0m <= 2, \033[0;33mYellow\033[0m > 2, \033[0;31mRed\033[0m > 4  |  Percentages: \033[0;32mGreen\033[0m <= 25%, \033[0;33mYellow\033[0m > 25%, \033[0;31mRed\033[0m > 50%"
        echo
    fi
}

# === Display results from state file ===
display_results() {
    local is_startup="${1:-0}"  # 1 if displaying on startup, 0 if displaying poll results
    local host_count=$(jq 'keys | length' "$STATE_FILE")

    if [ "$host_count" -eq 0 ]; then
        [ "$is_startup" -eq 1 ] && return
        clear
        echo "No hosts found in state file."
        return
    fi

    stty sane 2>/dev/null
    clear
    if [ "$is_startup" -eq 1 ]; then
        echo "GPU Monitor — Displaying saved state from $(date '+%Y-%m-%d %H:%M:%S')"
    else
        echo "GPU Monitor — $(date '+%Y-%m-%d %H:%M:%S') — polling every ${POLL_INTERVAL}s"
    fi
    echo
    display_table_frame "header" "Current"

    # Single jq call: sort, filter, format, color, and pad all rows
    jq -r '
        def esc: "\u001b";
        def red: esc + "[0;31m";
        def ylw: esc + "[0;33m";
        def grn: esc + "[0;32m";
        def gry: esc + "[0;90m";
        def rst: esc + "[0m";

        def cnum(val; yt; rt; fmt):
            if val > rt then red + fmt + rst
            elif val > yt then ylw + fmt + rst
            else grn + fmt + rst end;

        def rpad(str; vlen; w):
            if vlen < w then str + (" " * (w - vlen)) else str end;

        def fmt1: . * 10 | floor | . / 10 | tostring |
            if test("\\.") then . else . + ".0" end;

        def fmtp: . * 100 | floor | tostring;

        to_entries |
        map({key: .key} + .value + {
            _avg_med: (.value.ema_avg_used_med // 0),
            _samples: (.value.samples // 0),
            _unreach: (.value.unreachable // false)
        }) |
        sort_by(if ._unreach then ._avg_med + 9999999 else ._avg_med end) |
        .[] |
        select(._samples > 0) |

        # Format numbers
        ((.ema_avg_used_fast // 0) | fmt1) as $af |
        ((.ema_avg_used_med  // 0) | fmt1) as $am |
        ((.ema_avg_used_slow // 0) | fmt1) as $as |
        ((.ema_pct_8_used_fast // 0) | fmtp) as $p8f |
        ((.ema_pct_8_used_med  // 0) | fmtp) as $p8m |
        ((.ema_pct_8_used_slow // 0) | fmtp) as $p8s |
        ((.ema_pct_4_used_fast // 0) | fmtp) as $p4f |
        ((.ema_pct_4_used_med  // 0) | fmtp) as $p4m |
        ((.ema_pct_4_used_slow // 0) | fmtp) as $p4s |

        # Raw values for thresholds
        ((.ema_avg_used_fast // 0)) as $avf |
        ((.ema_avg_used_med  // 0)) as $avm |
        ((.ema_avg_used_slow // 0)) as $avs |
        ((.ema_pct_8_used_fast // 0) * 100) as $p8fv |
        ((.ema_pct_8_used_med  // 0) * 100) as $p8mv |
        ((.ema_pct_8_used_slow // 0) * 100) as $p8sv |
        ((.ema_pct_4_used_fast // 0) * 100) as $p4fv |
        ((.ema_pct_4_used_med  // 0) * 100) as $p4mv |
        ((.ema_pct_4_used_slow // 0) * 100) as $p4sv |

        # Colored stat columns with padding
        (cnum($avf;2;4;$af) + "/" + cnum($avm;2;4;$am) + "/" + cnum($avs;2;4;$as)) as $avg_col |
        (($af|length) + 1 + ($am|length) + 1 + ($as|length)) as $avg_vl |

        (cnum($p8fv;25;50;$p8f) + "/" + cnum($p8mv;25;50;$p8m) + "/" + cnum($p8sv;25;50;$p8s) + "%") as $p8_col |
        (($p8f|length) + 1 + ($p8m|length) + 1 + ($p8s|length) + 1) as $p8_vl |

        (cnum($p4fv;25;50;$p4f) + "/" + cnum($p4mv;25;50;$p4m) + "/" + cnum($p4sv;25;50;$p4s) + "%") as $p4_col |
        (($p4f|length) + 1 + ($p4m|length) + 1 + ($p4s|length) + 1) as $p4_vl |

        # Server name color (based on 7d EMA)
        ((.last_total_gpus // 0) - (.last_gpus_used // 0)) as $avail |
        (if ._unreach or $avail == 0 then gry
         elif $p8mv > 25 then red
         elif $p8mv > 10 then ylw
         else grn end) as $sc |

        # Status column
        ((.last_total_gpus // 0)) as $tot |
        ((.last_gpus_used // 0)) as $used |
        ($tot - $used) as $av |
        (($av|tostring) + "/" + ($tot|tostring) + " avail (" + ($used|tostring) + " used)") as $stxt |
        (($av|tostring|length) + 1 + ($tot|tostring|length) + 8 + ($used|tostring|length) + 6) as $svl |

        (if ._unreach then rpad(gry + "UNREACHABLE" + rst; 11; 20)
         elif $av == 0 then rpad(gry + $stxt + rst; $svl; 20)
         elif $av >= 6 then rpad(grn + $stxt + rst; $svl; 20)
         elif $av >= 4 then rpad(ylw + $stxt + rst; $svl; 20)
         else rpad(red + $stxt + rst; $svl; 20) end) as $status |

        # Server name padded
        ((.key|.[:28]) + (" " * ([28 - (.key|length), 0] | max))) as $sname |

        "│ " + $sc + $sname + rst +
        " │ " + $status +
        " │ " + rpad($avg_col; $avg_vl; 22) +
        " │ " + rpad($p8_col; $p8_vl; 22) +
        " │ " + rpad($p4_col; $p4_vl; 22) + " │"
    ' "$STATE_FILE" | while IFS= read -r line; do
        echo "$line"
    done

    display_table_frame "footer"

    # Display all not-reached hosts summary (never reached + currently unreachable)
    local not_reached_count=$(jq '[to_entries[] | select(.value.samples == 0 or .value.samples == null or .value.unreachable == true)] | length' "$STATE_FILE")
    if [ "$not_reached_count" -gt 0 ]; then
        echo "Not Reached (${not_reached_count}):"
        jq -r 'to_entries | map(select(.value.samples == 0 or .value.samples == null or .value.unreachable == true)) | sort_by(.key) | .[] | .key + "|" + (.value.unreachable_reason // "No response recorded")' "$STATE_FILE" | while IFS='|' read -r host reason; do
            printf "  • %-28s %s\n" "$host" "$reason"
        done
        echo
    fi

    echo "State saved to: $STATE_FILE"
    if [ "$is_startup" -eq 1 ]; then
        echo "Starting live polling..."
    else
        echo "Next check in ${POLL_INTERVAL}s... (press any key to check now, Ctrl+C to stop)"
    fi
    echo
}

# === Main loop ===
main() {
    load_ssh_user

    sync_ssh_config

    load_state

    # Display saved state immediately if it exists
    display_results 1

    trap 'echo; echo "Stopped. State preserved in $STATE_FILE"; exit 0' INT TERM

    while true; do
        echo "🔍 Checking GPUs..."
        HOSTS_LIST=$(get_ssh_hosts)
        WORK_TMPDIR=$(mktemp -d)

        # Count total hosts for progress
        local total_hosts=$(echo "$HOSTS_LIST" | wc -l | tr -d ' ')
        local completed=0

        # Launch all checks in parallel
        OLD_IFS="$IFS"
        IFS=$'\n'
        job_count=0
        for host_entry in $HOSTS_LIST; do
            IFS="$OLD_IFS"
            host_alias=$(echo "$host_entry" | cut -d: -f1)
            hostname=$(echo "$host_entry" | cut -d: -f2)
            user=$(echo "$host_entry" | cut -d: -f3)
            tmpfile="$WORK_TMPDIR/${job_count}.txt"
            check_host "$host_alias" "$hostname" "$user" "$tmpfile" &
            job_count=$((job_count + 1))
            IFS=$'\n'
        done
        IFS="$OLD_IFS"

        # Wait for all jobs with progress indicator, processing results as they arrive
        local processed=0
        local processed_dir="$WORK_TMPDIR/.processed"
        mkdir -p "$processed_dir"

        while [ $(jobs -r | wc -l) -gt 0 ] || [ $processed -lt $total_hosts ]; do
            # Process any new completed files
            for tmpfile in "$WORK_TMPDIR"/*.txt; do
                [ -f "$tmpfile" ] || continue
                local basename=$(basename "$tmpfile")
                [ -f "$processed_dir/$basename" ] && continue

                process_single_result "$tmpfile"
                touch "$processed_dir/$basename"
                processed=$((processed + 1))
            done

            printf "\r⏳ %d/%d complete" "$processed" "$total_hosts"
            sleep 0.2
        done

        printf "\r✓ %d/%d complete\n" "$total_hosts" "$total_hosts"

        # Display sorted results
        display_results 0

        # Cleanup temp dir
        rm -rf "$WORK_TMPDIR"

        # Wait for timeout or keypress to check again immediately
        read -rsn1 -t "$POLL_INTERVAL" _ 2>/dev/null
    done
}

main
