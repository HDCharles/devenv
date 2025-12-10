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

export HF_HUB_CACHE="$HOME/hf_hub"
export HF_HOME="$HOME/hf_hub"
export TRANSFORMERS_CACHE="$HOME/hf_hub"
export HF_DATASETS_CACHE="$HOME/hf_hub"
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
alias godev="cd $DEV_ENV_DIR"
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

selfcache () {
    if [ ! -d "$NETWORK_SHARE_DIR/hf_hub" ]; then
        mkdir "$NETWORK_SHARE_DIR/hf_hub"
    fi
    ln -snf "$NETWORK_SHARE_DIR/hf_hub" "$HOME/hf_hub"
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

getdirs(){
    echo "DEV_ENV_DIR= $DEV_ENV_DIR"
    echo "HF_HUB_DIR= $HF_HUB_DIR"
    echo "NETWORK_SHARE_DIR= $NETWORK_SHARE_DIR"
    echo "SELF_HF_HUB= $SELF_HF_HUB"
}


# Function to set VS Code window title prefix
setwindow() {
    local new_prefix="$1"
    local settings_file="/home/HDCharles/.vscode-server/data/Machine/settings.json"

    if [ -z "$new_prefix" ]; then
        echo "Usage: setwindow <prefix>"
        return 1
    fi

    # Create settings directory if it doesn't exist
    local settings_dir=$(dirname "$settings_file")
    if [ ! -d "$settings_dir" ]; then
        echo "Creating settings directory: $settings_dir"
        mkdir -p "$settings_dir"
    fi

    # 1. Check if settings.json exists, create if not
    if [ ! -f "$settings_file" ]; then
        echo "Creating settings file: $settings_file"
        echo '{}' > "$settings_file"
    fi

    # 2. Check if window.title is in settings.json
    if ! grep -q '"window.title"' "$settings_file"; then
        # Insert default window.title (escape $ to preserve VS Code template variables)
        local default_title=':${remoteName})${activeEditorShort}${separator}${rootName}${separator}${profileName}'
        jq --arg title "$default_title" '. + {"window.title": $title}' "$settings_file" > "${settings_file}.tmp" && mv "${settings_file}.tmp" "$settings_file"
        echo "Added default window.title to settings"
    fi

    # 3. Modify the title - replace everything before the first ':' with the new prefix
    local current_title=$(grep '"window.title"' "$settings_file" | sed 's/.*"window.title": "\(.*\)".*/\1/')
    local suffix=$(echo "$current_title" | sed 's/^[^:]*//')
    local new_title="${new_prefix}${suffix}"

    sed -i "s|\"window.title\": \".*\"|\"window.title\": \"$new_title\"|" "$settings_file"

    echo "Window title updated to: $new_title"
}

############ SETUP COMMANDS ############

env_install() {
    cd
    . ~/rhdev/bin/activate
    cd repos
    

    # cd speculators
    # uv pip install -e .[dev]
    # cd ..

    cd vllm
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

    uv pip install isort
    uv pip install pytest
    uv pip install debugpy
    uv pip install tblib

    mkdir repos
    cd repos
    git clone https://github.com/vllm-project/llm-compressor
    git clone https://github.com/neuralmagic/compressed-tensors
    git clone https://github.com/vllm-project/vllm
    git clone https://github.com/vllm-project/speculators

    echo "call \`env_install\` to complete setup"
}

fzf_setup() {
    cd ~/repos
    git clone https://github.com/junegunn/fzf.git ~/.fzf
    ~/.fzf/install
}

gcloud_setup() {
    cd
    gcloud init
    gcloud auth application-default login
    echo "add project ID itpc-gcp-ai-eng-claude"
    gcloud auth application-default set-quota-project cloudability-it-gemini
}

claude_setup() {
    cd
    mkdir ~/.npm-global
    npm config set prefix '~/.npm-global' 

    npm uninstall -g @anthropic-ai/claude-code
    npm install -g @anthropic-ai/claude-code
}

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

# helper function that checks if $1 exists, and then if $1/$2 exists
# and if so symlinks $1/$2 to $3
check_and_symlink(){
    local link_dir="$1"
    local link_name="$2"
    local target_file="$3"
    
    LINK_PATH="$link_dir/$link_name"
    if [ -d "$link_dir" ]; then
        if [ ! -e "$LINK_PATH" ]; then
            echo "Creating symlink: $LINK_PATH -> $target_file"
        fi
        ln -snf "$target_file" "$LINK_PATH"
    fi
}


############ ONE TIME SETUP ############

# Loop detection: prevent infinite reloads
if [ -z "$BASH_PROFILE_RELOAD_COUNT" ]; then
    export BASH_PROFILE_RELOAD_COUNT=0
else
    export BASH_PROFILE_RELOAD_COUNT=$((BASH_PROFILE_RELOAD_COUNT + 1))

    if [ $BASH_PROFILE_RELOAD_COUNT -ge 3 ]; then
        echo "ERROR: .bash_profile has reloaded $BASH_PROFILE_RELOAD_COUNT times."
        echo "Please manually review and fix these issues, call `seebash` to see the .bash_profile"
        unset BASH_PROFILE_RELOAD_COUNT
        return 2>/dev/null || exit 1
    fi
fi

# Track if any setup changes are made
SETUP_CHANGED=0


### OTS NETWORK-SHARE ###
export NO_NETWORK_SHARE=
if [ -L "$HOME/network-share" ]; then
    NETWORK_SHARE_DIR="$(readlink -f "$HOME/network-share")"
    NETWORK_SHARE_BASE="$(dirname "$NETWORK_SHARE_DIR")"
elif [ -d "/dev-network-share/users/engine" ]; then
    NETWORK_SHARE_BASE="/dev-network-share/users/engine"
elif [ -d "/mnt/data/engine" ]; then
    NETWORK_SHARE_BASE="/mnt/data/engine"
elif [ -d "/raid/engine" ]; then
    NETWORK_SHARE_BASE="/raid/engine"
elif [ -d "/mnt/nfs-preprod-1/engine" ]; then
    NETWORK_SHARE_BASE="/mnt/nfs-preprod-1/engine"
else
    # Prompt for custom network share base if in an interactive shell
    if [ -t 0 ]; then
        echo "No network share base directory found in default locations."
        read -p "Enter network share base directory (or press Enter to use /home): " CUSTOM_NETWORK_SHARE

        if [ -n "$CUSTOM_NETWORK_SHARE" ] && [ -d "$CUSTOM_NETWORK_SHARE" ]; then
            NETWORK_SHARE_BASE="$CUSTOM_NETWORK_SHARE"
            echo "Using custom network share base: $NETWORK_SHARE_BASE"
        elif [ -n "$CUSTOM_NETWORK_SHARE" ]; then
            echo "Warning: Directory $CUSTOM_NETWORK_SHARE does not exist. Falling back to /home"
            NETWORK_SHARE_BASE="/home"
            NO_NETWORK_SHARE=1
        else
            NETWORK_SHARE_BASE="/home"
            NO_NETWORK_SHARE=1
        fi
    else
        NETWORK_SHARE_BASE="/home"
        NO_NETWORK_SHARE=1
    fi
fi

NETWORK_SHARE_DIR="$NETWORK_SHARE_BASE/$USER"
# make HDCharles if it doesn't already exist
if [ ! -d "$NETWORK_SHARE_DIR" ]; then
    echo "Creating directory: $NETWORK_SHARE_DIR"
    mkdir "$NETWORK_SHARE_DIR"
    SETUP_CHANGED=1
fi

# Create symlink to network-share
if [ ! -d "$HOME/network-share" ]; then
    echo "Creating symlink: $HOME/network-share -> $NETWORK_SHARE_DIR"
    ln -snf "$NETWORK_SHARE_DIR" "$HOME/network-share"
    SETUP_CHANGED=1
fi

### OTS HF_HUB ###

# make a personal hf_hub
SELF_HF_HUB="$NETWORK_SHARE_DIR/hf_hub"
if [ ! -d "$SELF_HF_HUB" ]; then
    echo "Making personal hf_hub dir: $SELF_HF_HUB"
    mkdir "$SELF_HF_HUB"
fi

# try to symlink to main hf_hub/hf_hub_cache, 
#if can't find it, symlink to personal hf_hub
if [ ! -e "$HOME/hf_hub" ]; then
    if [ -d "$NETWORK_SHARE_BASE/hf_hub" ]; then
        echo "Creating symlink: $HOME/hf_hub -> $NETWORK_SHARE_BASE/hf_hub"
        ln -snf "$NETWORK_SHARE_BASE/hf_hub" "$HOME/hf_hub"
    elif [ -d "$NETWORK_SHARE_BASE/hub_cache" ]; then
        echo "Creating symlink: $HOME/hf_hub -> $NETWORK_SHARE_BASE/hub_cache"
        ln -snf "$NETWORK_SHARE_BASE/hub_cache" "$HOME/hf_hub"  
    elif [ -z "$NO_NETWORK_SHARE" ]; then
        echo "Unable to find main hf_hub, going to use personal hf_hub"
        echo "Creating symlink: $HOME/hf_hub -> $NETWORK_SHARE_DIR/hf_hub"
        ln -snf "$NETWORK_SHARE_DIR/hf_hub" "$HOME/hf_hub"
    else
        echo "This message shouldn't show up, ran into issues setting up hf_hub symlink"
    fi
    SETUP_CHANGED=1
fi
HF_HUB_DIR="$(readlink -f "$HOME/hf_hub")"


### OTS MOVE DEVENV TO NETWORK-SHARE ###
PARENT_DEV_ENV_DIR="$(dirname "$DEV_ENV_DIR")"
NETWORK_SHARE_REALPATH="$(readlink -f "$HOME/network-share")"

if [ "$PARENT_DEV_ENV_DIR" != "$HOME/network-share" ] && [ "$PARENT_DEV_ENV_DIR" != "$NETWORK_SHARE_REALPATH" ]; then
    DEV_ENV_NAME="$(basename "$DEV_ENV_DIR")"
    NEW_LOCATION="$HOME/network-share/$DEV_ENV_NAME"

    echo "Moving $DEV_ENV_DIR to $NEW_LOCATION"
    mv "$DEV_ENV_DIR" "$NEW_LOCATION"
    DEV_ENV_DIR="$NEW_LOCATION"
    SETUP_CHANGED=1
fi


### OTS .BASHRC CALLS .BASH_PROFILE ###
if [ -f ~/.bashrc ]; then
    # Check if the correct source command already exists
    if ! grep -qF "$DEV_ENV_DIR/.bash_profile" ~/.bashrc; then
        # Not found, check for the marker comment
        if grep -qF "# source devenv .bash_profile" ~/.bashrc; then
            # Marker found, replace the line after it with the correct source command
            sed -i "/# source devenv .bash_profile/{n;s|.*|. \"$DEV_ENV_DIR/.bash_profile\"|;}" ~/.bashrc
            echo "Updated .bash_profile sourcing in ~/.bashrc"
        else
            # Marker not found, append both lines
            echo "" >> ~/.bashrc
            echo "# source devenv .bash_profile" >> ~/.bashrc
            echo ". \"$DEV_ENV_DIR/.bash_profile\"" >> ~/.bashrc
            echo "Added .bash_profile sourcing to ~/.bashrc"
        fi
        SETUP_CHANGED=1
    fi
fi

### OTS GITCONFIG ###
set_git_config_if_missing "user.name" "HDCharles" "Git user.name configured"
set_git_config_if_missing "user.email" "charlesdavidhernandez@gmail.com" "Git user.email configured"
set_git_credential_helper_if_missing "https://github.com" "!/usr/bin/gh auth git-credential" "GitHub credential helper configured"
set_git_credential_helper_if_missing "https://gist.github.com" "!/usr/bin/gh auth git-credential" "Gist credential helper configured"
set_git_config_if_missing "diff.tool" "vscode" "Git diff tool configured"
set_git_config_if_missing "difftool.vscode.cmd" "code --diff \$LOCAL \$REMOTE" "Git difftool.vscode.cmd configured"
set_git_config_if_missing "commit.template" "$DEV_ENV_DIR/.git-template" "Git commit template configured: $DEV_ENV_DIR/.git-template"


### OTS LAUNCH.JSON ###
TEMPLATE_LAUNCH="$DEV_ENV_DIR/other_files/launch.json"
check_and_symlink "$HOME/.vscode" "launch.json" "$TEMPLATE_LAUNCH" 
check_and_symlink "$REPOS/.vscode" "launch.json" "$TEMPLATE_LAUNCH" 


### OTS RHDEV ###
if [ ! -d "$HOME/rhdev" ]; then
    echo "rhdev virtual environment not found. Running env_setup..."
    env_setup
    SETUP_CHANGED=1
fi

### OTS VSCODE EXTENTIONS ###
if [ $SETUP_CHANGED -eq 0 ] && command -v code &> /dev/null; then
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
    # Get list of installed extensions once
    INSTALLED_EXTENSIONS=$(code --list-extensions)

    for ext in "${REQUIRED_EXTENSIONS[@]}"; do
        if ! echo "$INSTALLED_EXTENSIONS" | grep -q "^$ext$"; then
            echo "Installing VSCode extension: $ext"
            output=$(code --install-extension "$ext" 2>&1)
            

            # Check if installation was successful by looking for success indicators in output
            if echo "$output" | grep -qi "successfully installed"; then
                :
            else
                echo "$output"
                echo "Unable to install extension $ext, please install manually to avoid triggering this on each restart"
            fi
        fi
    done
fi


### OTS CLAUDE CODE ###
if [ ! -e "$HOME/.config/gcloud/application_default_credentials.json" ]; then
    echo "No gcloud setup detected. Running gcloud setup for Claude"
    gcloud_setup
fi

if ! command -v claude &> /dev/null; then
    echo "Claude Code not found. Running claude_setup..."
    claude_setup
fi


# Refresh bash profile if any setup changes were made
if [ $SETUP_CHANGED -eq 1 ]; then
    echo "Some setup changes were detected. Reloading bash aliases..."
    source ~/.bashrc
    return 2>/dev/null || exit
else
    # Reset the counter on successful load without changes
    unset BASH_PROFILE_RELOAD_COUNT
fi
