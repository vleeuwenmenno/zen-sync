#!/usr/bin/env bash
set -euo pipefail

# === LOGGING ===
Log::msg() {
    local level=$1
    shift
    local msg="$*"
    local color_reset="\e[0m"
    local color_grey="\e[90m"
    local color_level=""
    local color_msg=""

    case "$level" in
        INF) color_level="\e[34m"; color_msg="\e[37m" ;; # Blue level, White text
        SUC) color_level="\e[32m"; color_msg="\e[32m" ;; # Green
        WRN) color_level="\e[33m"; color_msg="\e[33m" ;; # Yellow
        ERR) color_level="\e[31m"; color_msg="\e[31m" ;; # Red
        HDR) color_level="\e[34m"; color_msg="\e[34m" ;; # Blue header/title
        *)   color_level="\e[37m"; color_msg="\e[37m" ;; # Default White
    esac

    echo -e "${color_grey}$(date +%H:%M:%S)${color_reset} ${color_level}${level}${color_reset} ${color_msg}${msg}${color_reset}" >&2
}

Log::info()    { Log::msg "INF" "$*"; }
Log::success() { Log::msg "SUC" "$*"; }
Log::warn()    { Log::msg "WRN" "$*"; }
Log::error()   { Log::msg "ERR" "$*"; }
Log::header()  { Log::msg "HDR" "$*"; }

# === CONFIG ===
ZenSync_ConfigFile="$HOME/.zen_sync_config.json"
ZenSync_SqliteFiles=("places.sqlite" "favicons.sqlite")
ZenSync_PlainFiles=("sessionstore.jsonlz4" "zen-sessions.jsonlz4" "zen-themes.json" "zen-keyboard-shortcuts.json")
ZenSync_BackupDirs=("sessionstore-backups" "bookmarkbackups" "zen-sessions-backup")

# === CLASS: ZenSync ===

ZenSync::GetConfig() {
    if [[ -f "$ZenSync_ConfigFile" ]]; then
        cat "$ZenSync_ConfigFile"
    else
        echo "null"
    fi
}

ZenSync::SaveConfig() {
    local repo_url="$1"
    local repo_dir="$2"

    cat > "$ZenSync_ConfigFile" << INNER_EOF
{
    "repositoryUrl": "$repo_url",
    "repositoryDir": "$repo_dir",
    "lastBackup": null,
    "lastRestore": null
}
INNER_EOF
    Log::success "Configuration saved"
}

ZenSync::InitRepo() {
    local action="$1"

    Log::header "Repository Setup for $action"
    Log::info "You need to provide a Git repository URL for your backups."
    Log::info "Examples:"
    Log::info "  SSH: git@github.com:username/zen-browser-backup.git"
    Log::info "  HTTPS: https://github.com/username/zen-browser-backup.git"

    while true; do
        read -p "Enter your backup repository URL: " repo_url
        if [[ -z "$repo_url" ]]; then
            Log::error "Repository URL cannot be empty"
            continue
        fi

        if [[ ! "$repo_url" =~ ^(https://|git@).*\.git$ ]]; then
            Log::error "Invalid repository URL format"
            continue
        fi

        break
    done

    local repo_name
    repo_name=$(basename "$repo_url" .git)
    local repo_dir="/tmp/zen-backup-$repo_name"

    ZenSync::SaveConfig "$repo_url" "$repo_dir"
    echo "{\"Url\":\"$repo_url\",\"Dir\":\"$repo_dir\"}"
}

ZenSync::GetProfilePaths() {
    local profiles=()

    # Check for regular Zen Browser profiles
    if [[ "$OSTYPE" == "linux"* ]]; then
        # Linux - check standard, legacy, and flatpak paths
        local zen_bases=("$HOME/.config/zen" "$HOME/.zen" "$HOME/.var/app/app.zen_browser.zen/.zen")

        for zen_base in "${zen_bases[@]}"; do
            local ini_path="$zen_base/profiles.ini"

            if [[ -f "$ini_path" ]]; then
                # Parse profiles.ini correctly using process substitution to avoid subshell issues
                while IFS= read -r profile; do
                    [[ -n "$profile" ]] && profiles+=("$profile")
                done < <(awk '
                    /^Name=/ { name=$0; sub(/^Name=/, "", name); current_name=name }
                    /^Path=/ { path=$0; sub(/^Path=/, "", path); current_path=path }
                    current_name && current_path {
                        print current_name":"zen_base"/"current_path
                        current_name=""
                        current_path=""
                    }
                ' zen_base="$zen_base" "$ini_path")
            fi
        done
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        local zen_base="$HOME/Library/Application Support/Zen"
        local ini_path="$zen_base/profiles.ini"

        if [[ -f "$ini_path" ]]; then
            # Parse profiles.ini correctly using process substitution
            while IFS= read -r profile; do
                [[ -n "$profile" ]] && profiles+=("$profile")
            done < <(awk '
                /^Name=/ { name=$0; sub(/^Name=/, "", name); current_name=name }
                /^Path=/ { path=$0; sub(/^Path=/, "", path); current_path=path }
                /^IsRelative=/ { is_relative=$0; sub(/^IsRelative=/, "", is_relative) }
                current_name && current_path {
                    if (is_relative == "1") {
                        print "Regular:"zen_base"/"current_path
                    } else {
                        print "Regular:"current_path
                    }
                    current_name=""
                    current_path=""
                    is_relative=""
                }
            ' zen_base="$zen_base" "$ini_path")
        fi
    fi

    # Check for Twilight Zen Browser profiles on Windows
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
        local twilight_profiles_path="$APPDATA/zen/Profiles"
        if [[ -d "$twilight_profiles_path" ]]; then
            for dir in "$twilight_profiles_path"/*; do
                if [[ -d "$dir" ]]; then
                    local profile_name
                    profile_name=$(basename "$dir")
                    profiles+=("Twilight ($profile_name):$dir")
                fi
            done
        fi
    else
        # Check for Twilight Zen Browser profiles on Linux/macOS
        for twilight_base in "$HOME/.config/zen/profiles" "$HOME/.zen/profiles"; do
            if [[ -d "$twilight_base" ]]; then
                for dir in "$twilight_base"/*; do
                    if [[ -d "$dir" ]]; then
                        local profile_name
                        profile_name=$(basename "$dir")
                        profiles+=("Twilight ($profile_name):$dir")
                    fi
                done
            fi
        done
    fi

    printf '%s\n' "${profiles[@]}"
}

ZenSync::SelectProfile() {
    # Get profiles and store in array
    local profiles=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && profiles+=("$line")
    done < <(ZenSync::GetProfilePaths)

    if [[ ${#profiles[@]} -eq 0 ]]; then
        Log::error "No Zen Browser profiles found. Make sure Zen Browser is installed and has been run at least once."
        exit 1
    fi

    if [[ ${#profiles[@]} -eq 1 ]]; then
        local profile_path
        profile_path=$(echo "${profiles[0]}" | cut -d':' -f2)
        Log::info "Using single profile: ${profiles[0]}"
        echo "$profile_path"
        return
    fi

    Log::header "Found ${#profiles[@]} Zen Browser profiles:"
    echo "" >&2

    # Display profiles
    for i in "${!profiles[@]}"; do
        local profile_name
        profile_name=$(echo "${profiles[i]}" | cut -d':' -f1)
        local profile_path
        profile_path=$(echo "${profiles[i]}" | cut -d':' -f2)
        echo -e "  \e[34m[$((i+1))]\e[0m \e[37m$profile_name\e[0m" >&2
        echo -e "      \e[90m$profile_path\e[0m" >&2
    done

    echo "" >&2
    while true; do
        echo -ne "\e[33mSelect profile (1-${#profiles[@]}): \e[0m" >&2
        read -r selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#profiles[@]} ]]; then
            local profile_path
            profile_path=$(echo "${profiles[$((selection-1))]}" | cut -d':' -f2)
            echo "$profile_path"
            return
        fi
        Log::error "Invalid selection. Please enter a number between 1 and ${#profiles[@]}."
    done
}

ZenSync::CheckRunning() {
    # Check for any process containing 'zen' in its name or command line,
    # excluding this script itself and grep.
    # This catches zen, zen-bin, zen-beta, zen-alpha, etc.
    if pgrep -i -f "zen" | grep -v -e "$$" -e "grep" > /dev/null; then
        # Double check it's actually the browser by looking for typical browser process arguments
        if pgrep -i -f "zen.*--type=" > /dev/null || pgrep -i -f "zen-beta" > /dev/null || pgrep -i -f "zen-alpha" > /dev/null || pgrep -i -x "zen" > /dev/null || pgrep -i -x "zen-bin" > /dev/null; then
            Log::error "Zen Browser is currently running!"
            Log::error "Please close all Zen Browser windows before running backup or restore."
            Log::info "Running processes:"
            pgrep -i -a -f "zen" | grep -v -e "$$" -e "grep" | head -n 5 | while read -r pid cmd; do
                local bin
                bin=$(echo "$cmd" | awk '{print $1}' | xargs basename 2>/dev/null || echo "$cmd")
                Log::info "  PID $pid  $bin"
            done
            exit 1
        fi
    fi
}

ZenSync::CheckPrerequisites() {
    if ! command -v git &> /dev/null; then
        Log::error "Git not found. Please install Git"
        exit 1
    fi

    if ! command -v tar &> /dev/null; then
        Log::error "tar not found. Please install tar"
        exit 1
    fi

    if ! command -v sqlite3 &> /dev/null; then
        Log::error "sqlite3 not found. Please install sqlite3"
        Log::info "  Linux: sudo apt install sqlite3 / nix-env -iA nixpkgs.sqlite"
        Log::info "  macOS: brew install sqlite3"
        exit 1
    fi
}

ZenSync::BackupSqlite() {
    local src="$1"
    local dst="$2"

    if [[ ! -f "$src" ]]; then
        Log::warn "SQLite file not found: $src"
        return 1
    fi

    Log::info "Backing up SQLite database: $(basename "$src")..."
    # sqlite3 .backup creates a consistent snapshot even if the DB is in use
    # Open source DB as read-only URI to avoid needing write access to the source directory
    if sqlite3 "file:$src?mode=ro" ".backup '$dst'" 2>/dev/null; then
        Log::success "SQLite backup successful: $(basename "$src")"
    else
        Log::warn "sqlite3 .backup failed for $(basename "$src"), falling back to file copy"
        cp "$src" "$dst"
        # Also copy WAL/SHM if they exist, since we're doing a raw copy
        if [[ -f "$src-wal" ]]; then cp "$src-wal" "$dst-wal"; fi
        if [[ -f "$src-shm" ]]; then cp "$src-shm" "$dst-shm"; fi
    fi
}

ZenSync::Backup() {
    Log::header "Starting Zen Browser Backup..."

    # Ensure repo is configured before doing anything else
    local config
    config=$(ZenSync::GetConfig)
    if [[ "$config" == "null" ]]; then
        Log::error "No repository configured!"
        Log::info "Run: $0 repo set <url>"
        exit 1
    fi

    local repo_url
    repo_url=$(echo "$config" | jq -r '.repositoryUrl' 2>/dev/null || echo "")
    if [[ -z "$repo_url" || "$repo_url" == "null" ]]; then
        Log::error "No repository URL configured!"
        Log::info "Run: $0 repo set <url>"
        exit 1
    fi

    ZenSync::CheckRunning
    ZenSync::CheckPrerequisites


    local repo_dir
    repo_dir=$(echo "$config" | jq -r '.repositoryDir')
    
    local full_path
    full_path=$(ZenSync::SelectProfile)

    Log::info "Selected Zen Profile: $full_path"

    # Clean up any existing repo directory
    if [[ -d "$repo_dir" ]]; then
        rm -rf "$repo_dir"
    fi

    # Clone or create repository
    Log::info "Setting up repository..."

    # Try to clone first (repo exists)
    if git clone "$repo_url" "$repo_dir" 2>/dev/null; then
        Log::success "Repository cloned successfully"
    else
        # Repo doesn't exist or clone failed, initialize new
        Log::info "Initializing new repository..."
        mkdir -p "$repo_dir"
        cd "$repo_dir"

        git init >/dev/null
        git remote add origin "$repo_url"

        # Create initial commit
        echo "# Zen Browser Backups" > README.md
        git add README.md
        git commit -m "Initial commit" >/dev/null

        # Push to set up remote
        git push -u origin master 2>/dev/null || git push -u origin main 2>/dev/null
    fi

    cd "$repo_dir"

    local changed=false

    # Backup SQLite databases using sqlite3 .backup for consistency
    for file in "${ZenSync_SqliteFiles[@]}"; do
        local src="$full_path/$file"
        local dst="$repo_dir/$file"

        if [[ -f "$src" ]]; then
            ZenSync::BackupSqlite "$src" "$dst"
            changed=true
        else
            Log::warn "File not found: $file (skipping)"
        fi
    done

    # Backup plain (non-SQLite) files
    for file in "${ZenSync_PlainFiles[@]}"; do
        local src="$full_path/$file"
        local dst="$repo_dir/$file"

        if [[ -f "$src" ]]; then
            Log::info "Copying $file..."
            cp "$src" "$dst"
            changed=true
        else
            Log::warn "File not found: $file (skipping)"
        fi
    done

    # Backup folders
    for folder in "${ZenSync_BackupDirs[@]}"; do
        local src_folder="$full_path/$folder"
        local tar_file="$repo_dir/$folder.tar.gz"

        if [[ -d "$src_folder" ]]; then
            Log::info "Archiving $folder..."
            tar -czf "$tar_file" -C "$full_path" "$folder"
            changed=true
        else
            Log::warn "Folder not found: $folder (skipping)"
        fi
    done

    if [[ "$changed" == true ]]; then
        Log::info "Pushing to repository..."
        git add .
        git commit -m "Zen Browser backup - $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null
        
        if git push >/dev/null 2>&1; then
            Log::success "Backup completed successfully!"
            # Update config
            jq --arg last_backup "$(date '+%Y-%m-%d %H:%M:%S')" '.lastBackup = $last_backup' "$ZenSync_ConfigFile" > temp.json && mv temp.json "$ZenSync_ConfigFile"
        else
            Log::error "Failed to push to repository"
            exit 1
        fi
    else
        Log::warn "No files found to backup"
    fi

    # Cleanup
    cd /
    rm -rf "$repo_dir"
}

ZenSync::Restore() {
    Log::header "Starting Zen Browser Restore..."

    # Ensure repo is configured before doing anything else
    local config
    config=$(ZenSync::GetConfig)
    if [[ "$config" == "null" ]]; then
        Log::error "No repository configured!"
        Log::info "Run: $0 repo set <url>"
        exit 1
    fi

    local repo_url
    repo_url=$(echo "$config" | jq -r '.repositoryUrl' 2>/dev/null || echo "")
    if [[ -z "$repo_url" || "$repo_url" == "null" ]]; then
        Log::error "No repository URL configured!"
        Log::info "Run: $0 repo set <url>"
        exit 1
    fi

    ZenSync::CheckRunning
    ZenSync::CheckPrerequisites

    local repo_dir
    repo_dir=$(echo "$config" | jq -r '.repositoryDir')
    
    local full_path
    full_path=$(ZenSync::SelectProfile)

    Log::info "Selected Zen Profile: $full_path"

    # Clean up any existing repo directory
    if [[ -d "$repo_dir" ]]; then
        rm -rf "$repo_dir"
    fi

    # Clone repository
    Log::info "Cloning backup repository..."
    if ! git clone "$repo_url" "$repo_dir" 2>/dev/null; then
        Log::error "Failed to clone repository"
        exit 1
    fi

    cd "$repo_dir"

    # Restore SQLite databases
    for file in "${ZenSync_SqliteFiles[@]}"; do
        local src="$repo_dir/$file"
        local dst="$full_path/$file"

        if [[ -f "$src" ]]; then
            Log::info "Restoring $file..."

            # Backup existing file and associated WAL/SHM files
            for ext in "" "-wal" "-shm"; do
                if [[ -f "$dst$ext" ]]; then
                    local bak_file="$dst$ext.bak"
                    Log::info "Backing up existing $(basename "$dst$ext") to $(basename "$bak_file")"
                    mv "$dst$ext" "$bak_file"
                fi
            done

            cp "$src" "$dst"
        else
            Log::warn "Backup not found: $file"
        fi
    done

    # Restore plain (non-SQLite) files
    for file in "${ZenSync_PlainFiles[@]}"; do
        local src="$repo_dir/$file"
        local dst="$full_path/$file"

        if [[ -f "$src" ]]; then
            Log::info "Restoring $file..."

            # Backup existing file
            if [[ -f "$dst" ]]; then
                local bak_file="$dst.bak"
                Log::info "Backing up existing $file to $(basename "$bak_file")"
                mv "$dst" "$bak_file"
            fi

            cp "$src" "$dst"
        else
            Log::warn "Backup not found: $file"
        fi
    done

    # Restore folders
    for folder in "${ZenSync_BackupDirs[@]}"; do
        local src="$repo_dir/$folder.tar.gz"
        local dst_folder="$full_path/$folder"

        if [[ -f "$src" ]]; then
            Log::info "Restoring $folder..."

            # Backup existing folder
            if [[ -d "$dst_folder" ]]; then
                local bak_folder="$dst_folder.bak"
                Log::info "Backing up existing $folder to $(basename "$bak_folder")"
                if [[ -d "$bak_folder" ]]; then
                    rm -rf "$bak_folder"
                fi
                mv "$dst_folder" "$bak_folder"
            fi

            tar -xzf "$src" -C "$full_path"
        else
            Log::warn "Backup not found: $folder.tar.gz"
        fi
    done

    Log::success "Restore completed successfully!"

    # Update config
    jq --arg last_restore "$(date '+%Y-%m-%d %H:%M:%S')" '.lastRestore = $last_restore' "$ZenSync_ConfigFile" > temp.json && mv temp.json "$ZenSync_ConfigFile"

    # Cleanup
    cd /
    rm -rf "$repo_dir"
}

# === MAIN ===
ZenSync::ShowStatus() {
    local config
    config=$(ZenSync::GetConfig)
    local missing=()

    echo -e "" >&2
    echo -e "  \e[34mZen Browser Profile Backup & Restore\e[0m" >&2
    echo -e "  \e[90m────────────────────────────────────\e[0m" >&2
    echo -e "" >&2
    echo -e "  \e[37mUsage:\e[0m  \e[33m$0\e[0m \e[36m<command>\e[0m" >&2
    echo -e "" >&2
    echo -e "  \e[37mCommands:\e[0m" >&2
    echo -e "    \e[36mbackup\e[0m       Back up your Zen profile to a Git repository" >&2
    echo -e "    \e[36mrestore\e[0m      Restore your Zen profile from a Git repository" >&2
    echo -e "    \e[36mrepo\e[0m         Show the current backup repository" >&2
    echo -e "    \e[36mrepo set\e[0m     Set or change the backup repository URL" >&2
    echo -e "    \e[36mrepo clear\e[0m   Remove the repository configuration" >&2
    echo -e "" >&2

    # Check prerequisites
    echo -e "  \e[37mStatus:\e[0m" >&2

    # Git repo
    if [[ "$config" != "null" ]]; then
        local repo_url
        repo_url=$(echo "$config" | jq -r '.repositoryUrl' 2>/dev/null || echo "")
        if [[ -n "$repo_url" && "$repo_url" != "null" ]]; then
            echo -e "    \e[32m✓\e[0m Repository  \e[90m$repo_url\e[0m" >&2
        else
            echo -e "    \e[31m✗\e[0m Repository  \e[90mRun: $0 repo set <url>\e[0m" >&2
        fi
    else
        echo -e "    \e[31m✗\e[0m Repository  \e[90mRun: $0 repo set <url>\e[0m" >&2
    fi

    # git
    if command -v git &> /dev/null; then
        echo -e "    \e[32m✓\e[0m git         \e[90m$(git --version 2>/dev/null | head -c 30)\e[0m" >&2
    else
        echo -e "    \e[31m✗\e[0m git         \e[90mNot installed\e[0m" >&2
        missing+=("git")
    fi

    # jq
    if command -v jq &> /dev/null; then
        echo -e "    \e[32m✓\e[0m jq          \e[90m$(jq --version 2>/dev/null)\e[0m" >&2
    else
        echo -e "    \e[31m✗\e[0m jq          \e[90mNot installed\e[0m" >&2
        missing+=("jq")
    fi

    # sqlite3
    if command -v sqlite3 &> /dev/null; then
        echo -e "    \e[32m✓\e[0m sqlite3     \e[90m$(sqlite3 --version 2>/dev/null | cut -d' ' -f1)\e[0m" >&2
    else
        echo -e "    \e[31m✗\e[0m sqlite3     \e[90mNot installed\e[0m" >&2
        missing+=("sqlite3")
    fi

    # tar
    if command -v tar &> /dev/null; then
        echo -e "    \e[32m✓\e[0m tar         \e[90mInstalled\e[0m" >&2
    else
        echo -e "    \e[31m✗\e[0m tar         \e[90mNot installed\e[0m" >&2
        missing+=("tar")
    fi

    echo -e "" >&2

    # Show install instructions for missing packages
    if [[ ${#missing[@]} -gt 0 ]]; then
        local pkgs="${missing[*]}"
        echo -e "  \e[31mMissing packages:\e[0m \e[37m$pkgs\e[0m" >&2
        echo -e "" >&2
        echo -e "  \e[37mInstall with:\e[0m" >&2
        echo -e "    \e[90mDebian/Ubuntu:\e[0m  sudo apt install $pkgs" >&2
        echo -e "    \e[90mArch:\e[0m           sudo pacman -S $pkgs" >&2
        echo -e "    \e[90mFedora:\e[0m         sudo dnf install $pkgs" >&2
        echo -e "    \e[90mAlpine:\e[0m         sudo apk add $pkgs" >&2
        echo -e "    \e[90mNixOS:\e[0m          nix-env -iA nixpkgs.{$(IFS=,; echo "${missing[*]}")}" >&2
        echo -e "    \e[90mmacOS:\e[0m          brew install $pkgs" >&2
        echo -e "" >&2
    fi
}

if [[ $# -eq 0 ]]; then
    ZenSync::ShowStatus
    exit 1
fi

case "$1" in
    backup)
        ZenSync::Backup
        ;;
    restore)
        ZenSync::Restore
        ;;
    repo)
        if [[ $# -lt 2 ]]; then
            # Show current repo
            config=$(ZenSync::GetConfig)
            if [[ "$config" == "null" ]]; then
                Log::warn "No repository configured yet"
                Log::info "Run: $0 repo set <url>"
                exit 1
            fi
            repo_url=$(echo "$config" | jq -r '.repositoryUrl')
            last_backup=$(echo "$config" | jq -r '.lastBackup // "never"')
            last_restore=$(echo "$config" | jq -r '.lastRestore // "never"')
            echo -e "" >&2
            echo -e "  \e[37mRepository:\e[0m  \e[36m$repo_url\e[0m" >&2
            echo -e "  \e[37mLast backup:\e[0m \e[90m$last_backup\e[0m" >&2
            echo -e "  \e[37mLast restore:\e[0m\e[90m $last_restore\e[0m" >&2
            echo -e "" >&2
        else
            case "$2" in
                set)
                    if [[ $# -ge 3 ]]; then
                        repo_url="$3"
                    else
                        read -p "Enter your backup repository URL: " repo_url
                    fi

                    if [[ -z "$repo_url" ]]; then
                        Log::error "Repository URL cannot be empty"
                        exit 1
                    fi

                    if [[ ! "$repo_url" =~ ^(https://|git@).*\.git$ ]]; then
                        Log::error "Invalid repository URL format"
                        Log::info "Examples:"
                        Log::info "  SSH:   git@github.com:user/zen-backup.git"
                        Log::info "  HTTPS: https://github.com/user/zen-backup.git"
                        exit 1
                    fi

                    repo_name=$(basename "$repo_url" .git)
                    repo_dir="/tmp/zen-backup-$repo_name"
                    ZenSync::SaveConfig "$repo_url" "$repo_dir"
                    Log::success "Repository set to: $repo_url"
                    ;;
                clear)
                    if [[ -f "$ZenSync_ConfigFile" ]]; then
                        rm -f "$ZenSync_ConfigFile"
                        Log::success "Repository configuration removed"
                    else
                        Log::warn "No configuration to remove"
                    fi
                    ;;
                *)
                    Log::error "Unknown repo command: $2"
                    Log::info "Usage: $0 repo [set|clear]"
                    exit 1
                    ;;
            esac
        fi
        ;;
    *)
        Log::error "Unknown command: $1"
        ZenSync::ShowStatus
        exit 1
        ;;
esac