#!/usr/bin/env bash

: "${CLOUD_COMPOSE_TEST_LIFECYCLE_EXECUTOR:?CLOUD_COMPOSE_TEST_LIFECYCLE_EXECUTOR is required}"

run_compose_lifecycle_executor() {
  "$CLOUD_COMPOSE_TEST_LIFECYCLE_EXECUTOR" "$@"
}
