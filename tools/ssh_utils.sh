#!/bin/bash
# SSH config utilities — sourced by gpucheck.sh

_SSH_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"
LAST_SYNC_FILE="${LAST_SYNC_FILE:-$_SSH_UTILS_DIR/.gpucheck_last_sync}"
SYNC_INTERVAL="${SYNC_INTERVAL:-86400}"  # seconds between syncs (1 day)
INVENTORY_REPO="${INVENTORY_REPO:-neuralmagic/nm-alchemy}"
INVENTORY_WORKFLOW="${INVENTORY_WORKFLOW:-Inventory Site}"

MANAGED_START="### managed config starts here ###"
MANAGED_END="### managed config ends here ###"

# Get SSH username from gh auth
ssh_load_user() {
    SSH_USER=$(gh api user --jq '.login' 2>/dev/null)
    if [ -z "$SSH_USER" ]; then
        echo "⚠️  Could not get username. Is 'gh' authenticated? Run: gh auth login"
        exit 1
    fi
}

# Parse SSH config into host_alias:hostname:user lines
ssh_get_hosts() {
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

# List all Host aliases (excluding wildcards/comments)
ssh_list_aliases() {
    awk '/^Host[[:space:]]/ && $2 !~ /\*/ && $2 !~ /^#/ {print $2}' "$SSH_CONFIG"
}

# Remove state file entries whose aliases are not in SSH config
ssh_prune_state_file() {
    local state_file="$1"
    local ssh_aliases
    ssh_aliases=$(ssh_list_aliases)
    local tmp
    tmp=$(mktemp)
    jq --arg aliases "$ssh_aliases" '
        ($aliases | split("\n") | map(select(. != ""))) as $valid |
        with_entries(select(.key as $k | $valid | any(. == $k)))
    ' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
    echo "📊 State file has $(jq 'keys | length' "$state_file") host(s)"
}

# Replace the managed section of SSH config with new content
# If markers don't exist, append them at the end
ssh_write_managed_section() {
    local new_content="$1"
    local escaped
    escaped=$(printf '%s' "$new_content" | sed 's/\\/\\\\/g; s/\n/\\n/g' | tr '\n' '~' | sed 's/~/\\n/g')
    local tmp
    tmp=$(mktemp)

    if grep -qF "$MANAGED_START" "$SSH_CONFIG"; then
        awk -v start="$MANAGED_START" -v end="$MANAGED_END" -v content="$escaped" '
            $0 == start { print; printf "%s", content; skip=1; next }
            $0 == end { skip=0 }
            !skip { print }
        ' "$SSH_CONFIG" > "$tmp" && mv "$tmp" "$SSH_CONFIG"
    else
        printf "\n%s\n%s%s\n" "$MANAGED_START" "$new_content" "$MANAGED_END" >> "$SSH_CONFIG"
    fi
}

# Sync SSH config with the nm-alchemy inventory (once per day)
ssh_sync_config() {
    local state_file="$1"

    # Skip if synced within the last day
    if [ -f "$LAST_SYNC_FILE" ]; then
        local last_sync_time
        last_sync_time=$(stat -f %m "$LAST_SYNC_FILE" 2>/dev/null || stat -c %Y "$LAST_SYNC_FILE" 2>/dev/null)
        local now
        now=$(date +%s)
        if [ -n "$last_sync_time" ] && [ $((now - last_sync_time)) -lt "$SYNC_INTERVAL" ]; then
            echo "📋 SSH config synced less than a day ago, skipping"
            return 0
        fi
    fi

    local run_id
    run_id=$(gh run list -R "${INVENTORY_REPO}" -w "${INVENTORY_WORKFLOW}" -s completed --json databaseId,conclusion --jq '[.[] | select(.conclusion=="success")][0].databaseId' 2>/dev/null)

    if [ -z "$run_id" ]; then
        echo "⚠️  Could not find a successful '${INVENTORY_WORKFLOW}' workflow run. Is 'gh' authenticated?"
        return 1
    fi

    local last_synced_run=""
    [ -f "$LAST_SYNC_FILE" ] && last_synced_run=$(head -1 "$LAST_SYNC_FILE")

    if [ "$run_id" = "$last_synced_run" ]; then
        echo "📋 Already synced with latest inventory run ($run_id)"
        return 0
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

    local parsed
    parsed=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
for host in data.get('allHosts', []):
    addr = host.get('address', '')
    name = host.get('name', '')
    meta = host.get('meta', {})
    access = meta.get('developer_access', False)
    gpu_type = meta.get('gpu_type', 'none') or 'none'
    has_gpus = gpu_type not in ('none', 'unknown')
    if access and has_gpus and addr and name and not any(c.isalpha() for c in addr):
        print(f'{addr}\t{name}')
" <<< "$raw" 2>/dev/null)

    if [ -z "$parsed" ]; then
        echo "⚠️  Could not parse any hosts from inventory. Will retry next run."
        return 1
    fi

    local managed_block=""
    local host_count=0
    while IFS=$'\t' read -r ip alias _rest; do
        [ -z "$ip" ] || [ -z "$alias" ] && continue
        managed_block+="Host ${alias}
  HostName ${ip}
  User ${SSH_USER}

"
        host_count=$((host_count + 1))
    done <<< "$parsed"

    ssh_write_managed_section "$managed_block"
    echo "✅ Wrote $host_count host(s) to managed SSH config section"

    ssh_prune_state_file "$state_file"

    printf "%s\n%s\n" "$run_id" "$(date -Iseconds)" > "$LAST_SYNC_FILE"
}
