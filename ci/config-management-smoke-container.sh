#!/usr/bin/env bash

set -euo pipefail

install -d -m 0755 /work
tar -C /work -xf -
cd /work
exec bash ci/config-management-smoke-inner.sh
