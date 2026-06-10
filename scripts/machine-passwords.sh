#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=load-env.sh
. "$SCRIPT_DIR/load-env.sh"

machine_host() {
    case "$1" in
        brazil-01) printf '%s\n' '130.94.106.105' ;;
        brazil-02) printf '%s\n' '130.94.107.80' ;;
        brazil-03) printf '%s\n' '130.94.107.139' ;;
        brazil-04) printf '%s\n' '130.94.106.176' ;;
        philippines-01|load-test-linux-philippines-01) printf '%s\n' 'ec2-18-140-61-84.ap-southeast-1.compute.amazonaws.com' ;;
        philippines-02) printf '%s\n' '38.54.36.76' ;;
        philippines-03) printf '%s\n' '38.54.87.127' ;;
        turkey-01) printf '%s\n' '38.60.208.217' ;;
        turkey-02) printf '%s\n' '130.94.1.175' ;;
        turkey-03) printf '%s\n' '38.54.105.77' ;;
        egypt-01|load-test-egypt-01) printf '%s\n' '38.54.59.190' ;;
        egypt-02|load-test-egypt-02) printf '%s\n' '38.60.226.10' ;;
        egypt-03|load-test-egypt-03) printf '%s\n' '38.60.226.153' ;;
        saudi-01|load-test-saudi-01) printf '%s\n' '130.94.58.123' ;;
        saudi-02|load-test-saudi-02) printf '%s\n' '130.94.58.144' ;;
        saudi-03|load-test-saudi-03) printf '%s\n' '130.94.57.133' ;;
        *) return 1 ;;
    esac
}

machine_user() {
    case "$1" in
        philippines-01|load-test-linux-philippines-01) printf '%s\n' 'ec2-user' ;;
        *) printf '%s\n' 'root' ;;
    esac
}

resolve_repo_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$REPO_ROOT/$1" ;;
    esac
}

machine_identity_file() {
    case "$1" in
        philippines-01|load-test-linux-philippines-01)
            resolve_repo_path "${PHILIPPINES_SSH_KEY:-philly.pem}"
            ;;
        *) return 1 ;;
    esac
}

machine_auth_type() {
    if machine_identity_file "$1" >/dev/null 2>&1; then
        printf '%s\n' 'key'
    else
        printf '%s\n' 'password'
    fi
}

machine_password_env_name() {
    case "$1" in
        brazil-01|brazil-02|brazil-03|brazil-04) printf '%s\n' 'BRAZIL_ROOT_PASSWORD' ;;
        philippines-02|philippines-03) printf '%s\n' 'PHILIPPINES_ROOT_PASSWORD' ;;
        turkey-01|turkey-02|turkey-03) printf '%s\n' 'TURKEY_ROOT_PASSWORD' ;;
        egypt-01|egypt-02|egypt-03|load-test-egypt-01|load-test-egypt-02|load-test-egypt-03) printf '%s\n' 'EGYPT_ROOT_PASSWORD' ;;
        saudi-01|saudi-02|saudi-03|load-test-saudi-01|load-test-saudi-02|load-test-saudi-03) printf '%s\n' 'SAUDI_ROOT_PASSWORD' ;;
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

require_machine_ssh_tools() {
    local machine
    local needs_sshpass="false"

    if ! command -v ssh >/dev/null 2>&1; then
        echo "ssh not found"
        return 1
    fi

    for machine in "$@"; do
        if [ "$(machine_auth_type "$machine")" = "password" ]; then
            needs_sshpass="true"
        fi
    done

    if [ "$needs_sshpass" = "true" ] && ! command -v sshpass >/dev/null 2>&1; then
        echo "sshpass not found"
        return 1
    fi
}

require_machine_scp_tools() {
    require_machine_ssh_tools "$@" || return 1

    if ! command -v scp >/dev/null 2>&1; then
        echo "scp not found"
        return 1
    fi
}

machine_ssh() {
    local machine="$1"
    shift

    local host
    local user
    local auth_type
    local identity_file
    local password
    local timeout

    host="$(machine_host "$machine" || true)"
    if [ -z "$host" ]; then
        echo "[$machine] unknown host"
        return 1
    fi

    user="$(machine_user "$machine")"
    auth_type="$(machine_auth_type "$machine")"
    timeout="${SSH_CONNECT_TIMEOUT:-30}"

    if [ "$auth_type" = "key" ]; then
        identity_file="$(machine_identity_file "$machine")"
        if [ ! -f "$identity_file" ]; then
            echo "[$machine] missing SSH key: $identity_file"
            return 1
        fi

        ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout="$timeout" \
            -i "$identity_file" \
            "$user@$host" \
            "$@"
        return $?
    fi

    password="$(machine_password "$machine" || true)"
    if [ -z "$password" ]; then
        return 1
    fi

    sshpass -p "$password" \
        ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="$timeout" \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        "$user@$host" \
        "$@"
}

machine_scp_from() {
    local machine="$1"
    local remote_file="$2"
    local local_target="$3"

    local host
    local user
    local auth_type
    local identity_file
    local password
    local timeout

    host="$(machine_host "$machine" || true)"
    if [ -z "$host" ]; then
        echo "[$machine] unknown host"
        return 1
    fi

    user="$(machine_user "$machine")"
    auth_type="$(machine_auth_type "$machine")"
    timeout="${SSH_CONNECT_TIMEOUT:-30}"

    if [ "$auth_type" = "key" ]; then
        identity_file="$(machine_identity_file "$machine")"
        if [ ! -f "$identity_file" ]; then
            echo "[$machine] missing SSH key: $identity_file"
            return 1
        fi

        scp \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout="$timeout" \
            -i "$identity_file" \
            "$user@$host:$remote_file" \
            "$local_target"
        return $?
    fi

    password="$(machine_password "$machine" || true)"
    if [ -z "$password" ]; then
        return 1
    fi

    sshpass -p "$password" \
        scp \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="$timeout" \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        "$user@$host:$remote_file" \
        "$local_target"
}
