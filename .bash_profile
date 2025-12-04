############ ONE TIME SETUP ############

# Set DEV_ENV_DIR to the directory containing this .bash_profile file
export DEV_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure network-share exists (create symlink if /mnt/data/$USER exists, otherwise create directory)
if [ ! -e "$HOME/network-share" ]; then
    if [ -d "/mnt/data/$USER" ]; then
        ln -s /mnt/data/$USER "$HOME/network-share"
        echo "Created symlink: $HOME/network-share -> /mnt/data/$USER"
    else
        mkdir -p "$HOME/network-share"
        echo "Created directory: $HOME/network-share"
    fi
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
    else
        export DEV_ENV_DIR="$NEW_LOCATION"
    fi
fi

# After relocation, ensure .bashrc sources the .bash_profile from new location
if [ -f ~/.bashrc ]; then
    # Check if there's already a line sourcing this file
    if ! grep -qF "$DEV_ENV_DIR/.bash_profile" ~/.bashrc; then
        echo "" >> ~/.bashrc
        echo ". \"$DEV_ENV_DIR/.bash_profile\"" >> ~/.bashrc
        echo "Added .bash_profile sourcing to ~/.bashrc"
    fi
fi

# Setup .gitconfig
if [ -n "$DEV_ENV_DIR" ]; then
    if ! grep -qF "template = $DEV_ENV_DIR/.git-template" ~/.gitconfig 2>/dev/null; then
        echo "" >> ~/.gitconfig
        echo "[commit]" >> ~/.gitconfig
        echo "	template = $DEV_ENV_DIR/.git-template" >> ~/.gitconfig
        echo "Git commit template configured: $DEV_ENV_DIR/.git-template"
    fi
fi

# Check if rhdev virtual environment exists, if not run env_setup
if [ ! -d "$HOME/rhdev" ]; then
    echo "rhdev virtual environment not found. Running env_setup..."
    env_setup
fi

# Check if claude-code is installed, if not run claude_setup
if ! command -v claude &> /dev/null; then
    echo "Claude Code not found. Running claude_setup..."
    claude_setup
fi

############ UPDATE DEVENV ############

# Auto-update DEV_ENV_DIR from git
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

export REPOS="$HOME/repos"
export PYTHONSTARTUP="$DEV_ENV_DIR/.pythonrc"

# Check if HF_HUB_CACHE is already set
if [ -z "$HF_HUB_CACHE" ]; then
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
############ COLORS AND SECRETS AND UV ############
. "$DEV_ENV_DIR/.colors"
. "$DEV_ENV_DIR/.secrets"
. ~/rhdev/bin/activate

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

############ SETUP ############

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