# make sure to set VSCODE_IPC_HOOK_CLI for tmux sessions to allow vscode cli commands to work
if [ -n "$TMUX" ]; then
export VSCODE_IPC_HOOK_CLI=$(ls -t /run/user/$(id -u)/vscode-ipc-*.sock 2>/dev/null | head -1)
# Update PATH to use latest VS Code server in tmux
    if [ -d "$HOME/.vscode-server/cli/servers" ]; then
        # Remove any old vscode-server paths from PATH
        PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '\.vscode-server/cli/servers' | tr '\n' ':' | sed 's/:$//')
        # Add the latest server to PATH
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