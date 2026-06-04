#!/usr/bin/env bash

load_env_file() {
    local script_dir
    local repo_root
    local env_file
    local line
    local key
    local value

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "$script_dir/.." && pwd)"
    env_file="${ENV_FILE:-$repo_root/.env}"

    if [ -f "$env_file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"

            case "$line" in
                ''|\#*) continue ;;
                export\ *) line="${line#export }" ;;
            esac

            key="${line%%=*}"
            value="${line#*=}"

            if [ "$key" = "$line" ] || [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                continue
            fi

            if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                value="${value:1:${#value}-2}"
            elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
                value="${value:1:${#value}-2}"
            fi

            printf -v "$key" '%s' "$value"
            export "$key"
        done < "$env_file"
    fi
}

load_env_file
