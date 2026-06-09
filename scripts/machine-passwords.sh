#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=load-env.sh
. "$SCRIPT_DIR/load-env.sh"

machine_password_env_name() {
    case "$1" in
        brazil-01|brazil-02|brazil-03|brazil-04) printf '%s\n' 'BRAZIL_ROOT_PASSWORD' ;;
        philippines-01|philippines-02|philippines-03) printf '%s\n' 'PHILIPPINES_ROOT_PASSWORD' ;;
        turkey-01|turkey-02|turkey-03) printf '%s\n' 'TURKEY_ROOT_PASSWORD' ;;
        *) return 1 ;;
    esac
}

machine_password() {
    local machine="${1:-}"
    local env_name
    local password

    env_name="$(machine_password_env_name "$machine")" || return 1
    password="${!env_name:-}"

    if [ -z "$password" ]; then
        printf 'Missing %s for %s. Set it in .env or export it before running.\n' "$env_name" "$machine" >&2
        return 1
    fi

    printf '%s\n' "$password"
}
