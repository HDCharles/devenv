############ UPDATE DEV_ENV ############
if [ -d "$HOME/devenv" ]; then
    export DEV_ENV_DIR="$HOME/devenv"
elif [ -d "$HOME/network-share/devenv" ]; then
    export DEV_ENV_DIR="$HOME/network-share/devenv"
else
    echo "unable to find DEV_ENV_DIR"
fi

# Auto-update DEV_ENV_DIR from git
if [ -n "$DEV_ENV_DIR" ] && [ -d "$DEV_ENV_DIR/.git" ]; then
    git_output=$(cd "$DEV_ENV_DIR" && git pull 2>/dev/null)
    if [[ "$git_output" != "Already up to date." ]] && [[ -n "$git_output" ]]; then
        echo "DEV_ENV updated from git. Reloading bash aliases..."
        source ~/.bashrc
        return 2>/dev/null || exit
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


############ DIRS ############
export CLAUDE_CODE_USE_VERTEX=1
export CLOUD_ML_REGION=us-east5
export ANTHROPIC_VERTEX_PROJECT_ID=itpc-gcp-ai-eng-claude
export PATH=$PATH:$HOME/.npm-global/bin
export EDITOR=vim
export VISUAL=vim
############ ALIASES ############
alias debug='python -Xfrozen_modules=off -m debugpy --listen 5678 --wait-for-client'
alias ref='source ~/.bashrc'
alias seebash="code $DEV_ENV_DIR/.bash_aliases"
############ COLORS AND ENV ############
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