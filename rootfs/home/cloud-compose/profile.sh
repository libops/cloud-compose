#!/usr/bin/env bash

# shellcheck disable=SC1091
. /home/cloud-compose/.env

DEFAULT_MAX_RETRIES=10
DEFAULT_SLEEP_INCREMENT=5

# helper to wrap commands that go over the network in "exponential" backoff
# e.g. docker pull and git pull
retry_until_success() {
    local command_to_run=("$@")
    local MAX_RETRIES="${MAX_RETRIES:-$DEFAULT_MAX_RETRIES}"
    local SLEEP_INCREMENT="${SLEEP_INCREMENT:-$DEFAULT_SLEEP_INCREMENT}"
    local RETRIES=0

    while true; do
        exit_code=0
        timeout 300 "${command_to_run[@]}" || exit_code=$?

        if [ "$exit_code" -eq 0 ]; then
            return 0
        fi

        RETRIES=$((RETRIES + 1))

        if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
            echo "FAILURE: Command '${command_to_run[*]}' failed after $MAX_RETRIES attempts (Last exit code: $exit_code)." >&2
            return 1
        fi

        local SLEEP=$(( SLEEP_INCREMENT * RETRIES ))
        echo "Command '${command_to_run[*]}' failed (Exit code: $exit_code). Retrying in $SLEEP seconds... (Attempt $RETRIES/$MAX_RETRIES)" >&2
        sleep "$SLEEP"
    done
}

# update .env variables
# usage:
# update_env var value
# e.g. update_env DOCKER_COMPOSE_PROJECT foo
# will created/override DOCKER_COMPOSE_PROJECT=foo in $(pwd)/.env
update_env() {
    VAR_NAME="$1"
    VALUE="$2"
    if [ ! -f .env ]; then
      touch .env
    fi
    if grep -Eq "^${VAR_NAME}=" .env; then
        sed -i "s/^$VAR_NAME=.*/$VAR_NAME=$VALUE/" .env
    else
        echo "${VAR_NAME}=${VALUE}" | tee -a .env
    fi
}
