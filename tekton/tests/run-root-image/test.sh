#!/usr/bin/env bash
#
# Test script for running container images in privileged mode on Testing Farm VM.
#
# This script pulls and runs a container image using podman with --privileged flag.
# The container's exit code determines the test result (0=pass, non-zero=fail).
#
# REQUIRED ENVIRONMENT VARIABLES:
#   IMAGE_REF         Container image pullspec (e.g., quay.io/user/image:tag)
#                     Provided by Tekton via --environment flag to Testing Farm
#
# OPTIONAL ENVIRONMENT VARIABLES:
#   REGISTRY_USER     Username for private container registry authentication
#   REGISTRY_PASSWORD Password/token for private container registry authentication
#   CONTAINER_CMD     Override the container's default CMD/ENTRYPOINT
#   CONTAINER_ARGS    Additional arguments to pass to CONTAINER_CMD
#
# BEHAVIOR:
#   1. Validates podman is installed
#   2. Authenticates to registry if credentials are provided
#   3. Runs the container with --rm --privileged flags
#   4. Exits with the container's exit code (determines test pass/fail)
#
# EXIT CODES:
#   0   Container executed successfully (test passed)
#   1   Container failed (test failed)
#   2   Infrastructure error (podman not found, registry login failed, etc.)
#   N   Any other exit code from the container
#
set -euo pipefail

: "${IMAGE_REF:?IMAGE_REF is required (provided by Tekton via TF_TMT_ENV)}"
CONTAINER_CMD="${CONTAINER_CMD:-}"
CONTAINER_ARGS="${CONTAINER_ARGS:-}"
REGISTRY_USER="${REGISTRY_USER:-}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-}"

echo "==> Using IMAGE_REF: ${IMAGE_REF}"

if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman not installed"
  exit 2
fi

# Login to registry if credentials are provided
if [[ -n "${REGISTRY_USER}" ]] && [[ -n "${REGISTRY_PASSWORD}" ]]; then
  # Extract registry from IMAGE_REF (e.g., quay.io from quay.io/user/image:tag)
  REGISTRY=$(echo "${IMAGE_REF}" | cut -d'/' -f1)
  echo "==> Logging into registry: ${REGISTRY}"
  echo "${REGISTRY_PASSWORD}" | podman login --username "${REGISTRY_USER}" --password-stdin "${REGISTRY}" || {
    echo "ERROR: Failed to login to ${REGISTRY}"
    exit 2
  }
  echo "==> Successfully logged in"
fi

RUN=(podman run --rm --privileged)

# Run the container and capture its exit code
# Output goes directly to stdout/stderr (captured by Testing Farm as output.txt)
if [[ -n "${CONTAINER_CMD}" ]]; then
  echo "==> Overriding image command"
  "${RUN[@]}" "${IMAGE_REF}" /bin/bash -lc "${CONTAINER_CMD} ${CONTAINER_ARGS}"
  EXIT_CODE=$?
else
  echo "==> Running image with its default CMD/ENTRYPOINT"
  "${RUN[@]}" "${IMAGE_REF}"
  EXIT_CODE=$?
fi

# Exit with the container's exit code
if [[ ${EXIT_CODE} -ne 0 ]]; then
  echo "==> Container failed with exit code: ${EXIT_CODE}"
  exit ${EXIT_CODE}
fi

echo "==> Container finished successfully"

