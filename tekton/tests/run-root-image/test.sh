#!/usr/bin/env bash
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

if [[ -n "${CONTAINER_CMD}" ]]; then
  echo "==> Overriding image command"
  "${RUN[@]}" "${IMAGE_REF}" /bin/bash -lc "${CONTAINER_CMD} ${CONTAINER_ARGS}"
else
  echo "==> Running image with its default CMD/ENTRYPOINT"
  "${RUN[@]}" "${IMAGE_REF}"
fi

echo "==> Container finished successfully"

