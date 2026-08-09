#!/usr/bin/env bash

set -euo pipefail

context="${SITECTL_CONTEXT_NAME:?SITECTL_CONTEXT_NAME is required}"
sitectl compose --context "$context" up -d --remove-orphans
sitectl healthcheck --context "$context" --persist
