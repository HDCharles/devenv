############ AUTO UPDATE DEVENV ############
if [ -n "$DEV_ENV_DIR" ] && [ -d "$DEV_ENV_DIR/.git" ]; then
    git_output=$(cd "$DEV_ENV_DIR" && git pull 2>&1)
    git_exit_code=$?
    # Only reload if git pull succeeded (exit code 0) and made changes
    if [ $git_exit_code -eq 0 ] && [[ "$git_output" != "Already up to date." ]]; then
        echo "DEV_ENV updated from git. Reloading bash aliases..."
        source ~/.bashrc
        return 2>/dev/null || exit
    elif [ $git_exit_code -ne 0 ]; then
        echo "Warning: git pull failed in DEV_ENV_DIR. Run 'cd \$DEV_ENV_DIR && git status' to check."
    fi
fi

############ DIRS ############
export DEV_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPOS="$HOME/repos"
export PYTHONSTARTUP="$DEV_ENV_DIR/.pythonrc"

# Check if HF_HUB_CACHE is already set
if [ -z "$HF_HUB_CACHE" ]; then
    # Check if network share exists
    if [ -d "$HOME/network-share/hf_hub" ]; then
        HF_HUB_CACHE="$HOME/network-share/hf_hub"
    elif [-d "$HOME/hf_hub"]; then
        HF_HUB_CACHE="$HOME/hf_hub"
    fi
fi

############ VARS ############
export CLAUDE_CODE_USE_VERTEX=1
export CLOUD_ML_REGION=us-east5
export ANTHROPIC_VERTEX_PROJECT_ID=itpc-gcp-ai-eng-claude
export PATH=$PATH:$HOME/.npm-global/bin
export EDITOR=vim
export VISUAL=vim
############ ALIASES ############
alias debug='python -Xfrozen_modules=off -m debugpy --listen 5678 --wait-for-client'
alias ref='source ~/.bashrc'
alias seebash="code $DEV_ENV_DIR/.bash_profile"
############ SAFE SOURCE COMMAND ############
# Safely source a file only if it exists
safe_source() {
    if [ -f "$1" ]; then
        . "$1"
    else
        echo "Warning: File not found: $1"
    fi
}

############ COLORS AND SECRETS AND UV ENV SETUP ############
safe_source "$DEV_ENV_DIR/.colors"
safe_source "$DEV_ENV_DIR/.secrets"
safe_source ~/rhdev/bin/activate

############ COMMANDS ############
res () {
    output=$(canhazgpu reserve --gpus "$1" --duration "$2")
    export_cmd=$(echo "$output" | grep "export CUDA_VISIBLE_DEVICES" | tail -1)
    if [ -n "$export_cmd" ]; then
        eval "$export_cmd"
        echo "Successfully ran: $export_cmd"
    else
        echo "Warning: Could not find export command in output"
        exit 1
    fi
}

rel () {
    chg release
    export CUDA_VISIBLE_DEVICES=
}

run() {
    if [[ "$1" =~ ^[0-9]+$ ]]; then
    # First arg is an integer
        eval "chg run --gpus $1 -- ${*:2}"
    else
    # First arg is not an integer
        eval "chg run --gpus 1 -- $*"
    fi
}

hfread() {
    HF_TOKEN=$HF_TOKEN_READ
}

hfwrite() {
    HF_TOKEN=$HF_TOKEN_WRITE
}

running() {
    ps aux | grep HDCharles 2>&1 | tee ~/running.log
    code ~/running.log
}

uva() {
    local env_path="$1"
    
    # If it's a full path to the environment, use it directly
    if [ -d "$env_path/bin" ]; then
        source "$env_path/bin/activate"
    elif [ -d "$HOME/$env_path/bin" ]; then
        source "$HOME/$env_path/bin/activate"
    else
        echo "Environment not found: $env_path"
        return 1
    fi
}

uvl() {
    echo "UV virtual environments found:"
    for dir in ~/*; do
        if [ -d "$dir" ] && [ -f "$dir/bin/activate" ] && [ -f "$dir/pyvenv.cfg" ]; then
            echo "  $(basename "$dir"): $dir"
        fi
    done
    
    # Also check in common project directories
    if [ -d ~/repos ]; then
        for dir in ~/repos/*; do
            if [ -d "$dir" ] && [ -f "$dir/bin/activate" ] && [ -f "$dir/pyvenv.cfg" ]; then
                echo "  $(basename "$dir"): $dir"
            fi
        done
    fi
}

gitclean() {
    set -e

    echo "Fetching from remote...\n"
    git fetch -p

    echo "Checking for merged branches that are deleted from remote..."
    echo ""

    # Find branches that are gone from remote and merged
    branches_to_delete=()
    for branch in $(git branch -vv | grep ': gone]' | awk '{print $1}'); do
        if git branch --merged | grep -q "^  $branch$"; then
            branches_to_delete+=("$branch")
        fi
    done

    # Display results
    if [ ${#branches_to_delete[@]} -eq 0 ]; then
        echo "No merged branches to clean up."
        return 0
    fi

    echo "The following branches are merged and deleted from remote:"
    for branch in "${branches_to_delete[@]}"; do
        echo "  - $branch"
    done
    echo ""

    # Prompt for confirmation
    read -p "Delete all these branches? (y/n): " confirm

    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        for branch in "${branches_to_delete[@]}"; do
            git branch -d "$branch"
            echo "Deleted: $branch"
        done
        echo "Cleanup complete!"
    else
        echo "Cleanup cancelled."
    fi
}

############ SETUP COMMANDS ############

env_install() {
    cd
    . ~/rhdev/bin/activate
    cd repos
    cd vllm

    cd speculators
    uv pip install -e .[dev]

    VLLM_USE_PRECOMPILED=1 uv pip install --editable . --prerelease=allow
    # uv pip install -e .
    cd ..

    cd llm-compressor
    uv pip install -e .[dev]
    cd ..

    cd compressed-tensors
    uv pip install -e .[dev]
    cd ..


}


env_setup() {
    cd
    uv venv --python 3.11 rhdev 
    . ~/rhdev/bin/activate

    uv pip install black
    uv pip install isort
    uv pip install ruff
    uv pip install pytest
    uv pip install debugpy
    uv pip install tblib

    mkdir repos
    cd repos
    git clone https://github.com/vllm-project/llm-compressor
    git clone https://github.com/neuralmagic/compressed-tensors
    git clone https://github.com/vllm-project/vllm
    git clone https://github.com/vllm-project/speculators

    env_install
}


claude_setup() {
    cd
    gcloud init
    gcloud auth application-default login
    echo "add project ID itpc-gcp-ai-eng-claude"
    gcloud auth application-default set-quota-project cloudability-it-gemini

    mkdir ~/.npm-global
    npm config set prefix '~/.npm-global' 

    npm uninstall -g @anthropic-ai/claude-code
    npm install -g @anthropic-ai/claude-code
}


############ ONE TIME SETUP ############

# Track if any setup changes are made
SETUP_CHANGED=0

# Ensure network-share exists (create symlink if /mnt/data/$USER exists, otherwise create directory)
if [ ! -e "$HOME/network-share" ]; then
    if [ -d "/mnt/data/$USER" ]; then
        ln -s /mnt/data/$USER "$HOME/network-share"
        echo "Created symlink: $HOME/network-share -> /mnt/data/$USER"
    else
        mkdir -p "$HOME/network-share"
        echo "Created directory: $HOME/network-share"
    fi
    SETUP_CHANGED=1
fi

# Move DEV_ENV_DIR to network-share if it's not already there
DEV_ENV_PARENT="$(dirname "$DEV_ENV_DIR")"
NETWORK_SHARE_REALPATH="$(readlink -f "$HOME/network-share")"

if [ "$DEV_ENV_PARENT" != "$HOME/network-share" ] && [ "$DEV_ENV_PARENT" != "$NETWORK_SHARE_REALPATH" ]; then
    DEV_ENV_NAME="$(basename "$DEV_ENV_DIR")"
    NEW_LOCATION="$HOME/network-share/$DEV_ENV_NAME"

    if [ ! -d "$NEW_LOCATION" ]; then
        echo "Moving $DEV_ENV_DIR to $NEW_LOCATION..."
        mv "$DEV_ENV_DIR" "$NEW_LOCATION"
        export DEV_ENV_DIR="$NEW_LOCATION"
        echo "DEV_ENV_DIR relocated to network share"
        SETUP_CHANGED=1
    else
        export DEV_ENV_DIR="$NEW_LOCATION"
        SETUP_CHANGED=1
    fi
fi

# After relocation, ensure .bashrc sources the .bash_profile from new location
if [ -f ~/.bashrc ]; then
    # Check if there's already a line sourcing this file
    if ! grep -qF "$DEV_ENV_DIR/.bash_profile" ~/.bashrc; then
        echo "" >> ~/.bashrc
        echo ". \"$DEV_ENV_DIR/.bash_profile\"" >> ~/.bashrc
        echo "Added .bash_profile sourcing to ~/.bashrc"
        SETUP_CHANGED=1
    fi
fi

# Helper function to set git config if missing
set_git_config_if_missing() {
    local config_key="$1"
    local config_value="$2"
    local description="$3"

    if [ -z "$(git config --global "$config_key")" ]; then
        git config --global "$config_key" "$config_value"
        echo "$description"
        SETUP_CHANGED=1
    fi
}

# Helper function to set credential helper if missing
set_git_credential_helper_if_missing() {
    local credential_url="$1"
    local helper_cmd="$2"
    local description="$3"

    if [ -z "$(git config --global --get-all credential."$credential_url".helper)" ]; then
        git config --global credential."$credential_url".helper ""
        git config --global --add credential."$credential_url".helper "$helper_cmd"
        echo "$description"
        SETUP_CHANGED=1
    fi
}

# Setup git configuration
if [ -n "$DEV_ENV_DIR" ]; then
    set_git_config_if_missing "user.name" "HDCharles" "Git user.name configured"
    set_git_config_if_missing "user.email" "charlesdavidhernandez@gmail.com" "Git user.email configured"
    set_git_credential_helper_if_missing "https://github.com" "!/usr/bin/gh auth git-credential" "GitHub credential helper configured"
    set_git_credential_helper_if_missing "https://gist.github.com" "!/usr/bin/gh auth git-credential" "Gist credential helper configured"
    set_git_config_if_missing "diff.tool" "vscode" "Git diff tool configured"
    set_git_config_if_missing "difftool.vscode.cmd" "code --diff \$LOCAL \$REMOTE" "Git difftool.vscode.cmd configured"
    set_git_config_if_missing "commit.template" "$DEV_ENV_DIR/.git-template" "Git commit template configured: $DEV_ENV_DIR/.git-template"
fi

# setup HF HUB CACHE
if [ -z "$HF_HUB_CACHE" ] || [ ! -d "$HF_HUB_CACHE" ]; then
    # Check if network share exists
    if [ -d "$HOME/network-share" ]; then
        HF_HUB_CACHE="$HOME/network-share/hf_hub"
    else
        HF_HUB_CACHE="$HOME/hf_hub"
    fi

    # Check if the hf_hub directory exists, create if it doesn't
    if [ ! -d "$HF_HUB_CACHE" ]; then
        echo "Creating HuggingFace cache directory: $HF_HUB_CACHE"
        mkdir -p "$HF_HUB_CACHE"
        SETUP_CHANGED=1
    fi
fi


# Check if rhdev virtual environment exists, if not run env_setup
if [ ! -d "$HOME/rhdev" ]; then
    echo "rhdev virtual environment not found. Running env_setup..."
    env_setup
    SETUP_CHANGED=1
fi

# Check if claude-code is installed, if not run claude_setup
if ! command -v claude &> /dev/null; then
    echo "Claude Code not found. Running claude_setup..."
    claude_setup
    SETUP_CHANGED=1
fi

# Check for required VSCode extensions
if command -v code &> /dev/null; then
    REQUIRED_EXTENSIONS=(
        "anthropic.claude-code"
        "eamodio.gitlens"
        "letmaik.git-tree-compare"
        "ms-python.debugpy"
        "ms-python.python"
        "ms-python.vscode-pylance"
        "ms-python.vscode-python-envs"
        "zhoukz.safetensors"
    )

    for ext in "${REQUIRED_EXTENSIONS[@]}"; do
        if ! code --list-extensions | grep -q "^$ext$"; then
            echo "Installing VSCode extension: $ext"
            code --install-extension "$ext"
            SETUP_CHANGED=1
        fi
    done
fi

# Setup launch.json for VSCode debugging via symlink
if [ -d "$REPOS" ]; then
    VSCODE_DIR="$REPOS/.vscode"
    LAUNCH_JSON="$VSCODE_DIR/launch.json"
    TEMPLATE_LAUNCH="$DEV_ENV_DIR/other_files/launch.json"

    if [ ! -e "$LAUNCH_JSON" ]; then
        mkdir -p "$VSCODE_DIR"
        ln -s "$TEMPLATE_LAUNCH" "$LAUNCH_JSON"
        echo "Created symlink: $LAUNCH_JSON -> $TEMPLATE_LAUNCH"
        SETUP_CHANGED=1
    fi
fi

# Refresh bash profile if any setup changes were made
if [ $SETUP_CHANGED -eq 1 ]; then

    echo "Some setup changes were made. Reloading bash aliases..."
    source ~/.bashrc
    return 2>/dev/null || exit
fi