#!/usr/bin/env bash
set -euo pipefail

exec "$(dirname "$0")/../../bin/configure-umami.sh" local
