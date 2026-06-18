#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=load-env.sh
. "$SCRIPT_DIR/load-env.sh"

machine_host() {
    case "$1" in
        brazil-01|load-test-brazil-lightnode-01) printf '%s\n' '15.228.76.228' ;;
        brazil-02|load-test-brazil-lightnode-02) printf '%s\n' '18.231.135.223' ;;
        brazil-03|load-test-brazil-lightnode-03) printf '%s\n' '18.230.203.17' ;;
        brazil-04|load-test-brazil-lightnode-04) printf '%s\n' '54.207.158.199' ;;
        philippines-01|load-test-linux-philippines-01) printf '%s\n' '96.0.146.125' ;;
        philippines-02|load-test-linux-philippines-02) printf '%s\n' '96.0.144.231' ;;
        philippines-03|load-test-linux-philippines-03) printf '%s\n' '96.0.145.227' ;;
        turkey-01|load-test-turkey-01) printf '%s\n' '130.94.1.185' ;;
        turkey-02|load-test-turkey-02) printf '%s\n' '130.94.0.169' ;;
        turkey-03|load-test-turkey-03) printf '%s\n' '130.94.1.37' ;;
        egypt-01|load-test-egypt-01) printf '%s\n' '38.60.226.43' ;;
        egypt-02|load-test-egypt-02) printf '%s\n' '38.54.59.95' ;;
        egypt-03|load-test-egypt-03) printf '%s\n' '38.60.226.153' ;;
        saudi-01|load-test-saudi-01) printf '%s\n' '130.94.58.105' ;;
        saudi-02|load-test-saudi-02) printf '%s\n' '130.94.59.246' ;;
        saudi-03|load-test-saudi-03) printf '%s\n' '130.94.58.179' ;;
        iraq-01|load-test-iraq-01) printf '%s\n' '38.60.190.170' ;;
        qatar-01|load-test-qatar-01) printf '%s\n' '149.104.121.57' ;;
        kuwait-01|load-test-kuwait-01) printf '%s\n' '130.94.82.217' ;;
        bahrain-01|load-test-bahrain-01) printf '%s\n' '149.104.106.7' ;;
        *) return 1 ;;
    esac
}

machine_user() {
    case "$1" in
        philippines-01|philippines-02|philippines-03|load-test-linux-philippines-01|load-test-linux-philippines-02|load-test-linux-philippines-03) printf '%s\n' 'ec2-user' ;;
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
        philippines-01|philippines-02|philippines-03|load-test-linux-philippines-01|load-test-linux-philippines-02|load-test-linux-philippines-03)
            resolve_repo_path "${PHILIPPINES_SSH_KEY:-load-test-linux-philippines-01.pem}"
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
        brazil-01|brazil-02|brazil-03|brazil-04|load-test-brazil-lightnode-01|load-test-brazil-lightnode-02|load-test-brazil-lightnode-03|load-test-brazil-lightnode-04) printf '%s\n' 'BRAZIL_LIGHTNODE_PASSWORD' ;;
        turkey-01|turkey-02|turkey-03|load-test-turkey-01|load-test-turkey-02|load-test-turkey-03) printf '%s\n' 'TURKEY_ROOT_PASSWORD' ;;
        egypt-01|egypt-02|egypt-03|load-test-egypt-01|load-test-egypt-02|load-test-egypt-03) printf '%s\n' 'EGYPT_ROOT_PASSWORD' ;;
        saudi-01|saudi-02|saudi-03|load-test-saudi-01|load-test-saudi-02|load-test-saudi-03) printf '%s\n' 'SAUDI_ROOT_PASSWORD' ;;
        iraq-01|load-test-iraq-01) printf '%s\n' 'IRAQ_ROOT_PASSWORD' ;;
        qatar-01|load-test-qatar-01) printf '%s\n' 'QATAR_ROOT_PASSWORD' ;;
        kuwait-01|load-test-kuwait-01) printf '%s\n' 'KUWAIT_ROOT_PASSWORD' ;;
        bahrain-01|load-test-bahrain-01) printf '%s\n' 'BAHRAIN_ROOT_PASSWORD' ;;
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
    local server_alive_interval
    local server_alive_count_max

    host="$(machine_host "$machine" || true)"
    if [ -z "$host" ]; then
        echo "[$machine] unknown host"
        return 1
    fi

    user="$(machine_user "$machine")"
    auth_type="$(machine_auth_type "$machine")"
    timeout="${SSH_CONNECT_TIMEOUT:-120}"
    server_alive_interval="${SSH_SERVER_ALIVE_INTERVAL:-30}"
    server_alive_count_max="${SSH_SERVER_ALIVE_COUNT_MAX:-6}"

    if [ "$auth_type" = "key" ]; then
        identity_file="$(machine_identity_file "$machine")"
        if [ ! -f "$identity_file" ]; then
            echo "[$machine] missing SSH key: $identity_file"
            return 1
        fi

        ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout="$timeout" \
            -o ServerAliveInterval="$server_alive_interval" \
            -o ServerAliveCountMax="$server_alive_count_max" \
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
        -o ServerAliveInterval="$server_alive_interval" \
        -o ServerAliveCountMax="$server_alive_count_max" \
        -o PreferredAuthentications=password,keyboard-interactive \
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
    local server_alive_interval
    local server_alive_count_max

    host="$(machine_host "$machine" || true)"
    if [ -z "$host" ]; then
        echo "[$machine] unknown host"
        return 1
    fi

    user="$(machine_user "$machine")"
    auth_type="$(machine_auth_type "$machine")"
    timeout="${SSH_CONNECT_TIMEOUT:-120}"
    server_alive_interval="${SSH_SERVER_ALIVE_INTERVAL:-30}"
    server_alive_count_max="${SSH_SERVER_ALIVE_COUNT_MAX:-6}"

    if [ "$auth_type" = "key" ]; then
        identity_file="$(machine_identity_file "$machine")"
        if [ ! -f "$identity_file" ]; then
            echo "[$machine] missing SSH key: $identity_file"
            return 1
        fi

        scp \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout="$timeout" \
            -o ServerAliveInterval="$server_alive_interval" \
            -o ServerAliveCountMax="$server_alive_count_max" \
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
        -o ServerAliveInterval="$server_alive_interval" \
        -o ServerAliveCountMax="$server_alive_count_max" \
        -o PreferredAuthentications=password,keyboard-interactive \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        "$user@$host:$remote_file" \
        "$local_target"
}
