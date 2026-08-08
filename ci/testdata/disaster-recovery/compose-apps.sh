#!/usr/bin/env bash

compose_app_names_array() {
  local -n result="$1"
  # shellcheck disable=SC2034 # The caller reads the array through this nameref.
  result=(alpha)
}

source_compose_app_env() {
  DOCKER_COMPOSE_DIR="${TEST_DATA_ROOT:?}/projects/$1"
  export DOCKER_COMPOSE_DIR
}

validate_compose_project_dir() {
  [[ "$1" == "${TEST_DATA_ROOT:?}/projects/"* ]]
}
