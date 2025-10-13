#!/usr/bin/env bash
# This test ensures we are running as root and then runs the target script.

set -euo pipefail

echo "==> Checking we are root"
if [ "$(id -u)" != "0" ]; then
  echo "ERROR: Not running as root (uid=$(id -u))"
  exit 1
fi

# Variables controllable from TF_TMT_ENV:
#  - SCRIPT_PATH: path to your script in the repo (default: ./tests/script.sh)
#  - SCRIPT_ARGS: arguments for your script (default: empty)

SCRIPT_PATH="${SCRIPT_PATH:-./tests/script.sh}"
SCRIPT_ARGS="${SCRIPT_ARGS:-}"

echo "==> Script path: ${SCRIPT_PATH}"
echo "==> Script args: ${SCRIPT_ARGS}"

# Ensure the script exists and is executable
if [ ! -f "${SCRIPT_PATH}" ]; then
  echo "ERROR: Script not found at ${SCRIPT_PATH}"
  exit 2
fi
chmod +x "${SCRIPT_PATH}"

echo "==> Running script on the VM (root)"
./"${SCRIPT_PATH}" ${SCRIPT_ARGS}

echo "==> Script finished successfully"

