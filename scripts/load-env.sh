#!/usr/bin/env bash

load_env_file() {
    local script_dir
    local repo_root
    local env_file

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "$script_dir/.." && pwd)"
    env_file="${ENV_FILE:-$repo_root/.env}"

    if [ -f "$env_file" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$env_file"
        set +a
    fi
}

load_env_file
