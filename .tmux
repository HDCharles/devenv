# Refresh VSCODE_IPC_HOOK_CLI if unset or stale — works in both tmux and VS Code integrated terminal
if [ -z "$VSCODE_IPC_HOOK_CLI" ] || [ ! -S "$VSCODE_IPC_HOOK_CLI" ]; then
    _sock=$(ls -t /run/user/$(id -u)/vscode-ipc-*.sock 2>/dev/null | head -1)
    if [ -n "$_sock" ] && [ -S "$_sock" ]; then
        export VSCODE_IPC_HOOK_CLI="$_sock"
    else
        unset VSCODE_IPC_HOOK_CLI
    fi
    unset _sock
fi

if [ -n "$TMUX" ]; then
    # Auto-call ref when attaching to this tmux session so VSCODE_IPC_HOOK_CLI gets refreshed
    tmux set-hook -g client-attached 'run-shell "pane_cmd=\"$(tmux display-message -p \"#{pane_current_command}\")\"; case \"$pane_cmd\" in bash|zsh|sh) tmux send-keys \"ref\" Enter;; esac"'
    # Update PATH to use latest VS Code server
    if [ -d "$HOME/.vscode-server/cli/servers" ]; then
        PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '\.vscode-server/cli/servers' | tr '\n' ':' | sed 's/:$//')
        LATEST_VSCODE_SERVER=$(ls -td ~/.vscode-server/cli/servers/Stable-* 2>/dev/null | head -1)
        if [ -n "$LATEST_VSCODE_SERVER" ] && [ -d "$LATEST_VSCODE_SERVER/server/bin/remote-cli" ]; then
            export PATH="$LATEST_VSCODE_SERVER/server/bin/remote-cli:$PATH"
        fi
    fi
fi

# helper commands

tmuxhelp() {
    echo "tmux: new session"
    echo "tmux new -s <name> : new session with name"
    echo "tmux attach: attach to most recent"
    echo "tma: interactive choose-session"
    echo "exit: kill session from inside"
    echo "tmux kill-session/tmux kill-session -t <name>: killing sessions from outside"
}

tma() {                                                                 
    local session                                                       
    session=$(tmux ls -F "#{session_name}" 2>/dev/null | fzf --prompt="Select tmux session: ")
    if [ -n "$session" ]; then                                          
        tmux attach -t "$session"                                       
    fi                                                                  
} 