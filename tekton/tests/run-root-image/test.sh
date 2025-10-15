#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE_REF:?IMAGE_REF is required (provided by Tekton via TF_TMT_ENV)}"
CONTAINER_CMD="${CONTAINER_CMD:-}"
CONTAINER_ARGS="${CONTAINER_ARGS:-}"

echo "==> Using IMAGE_REF: ${IMAGE_REF}"

if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman not installed"
  exit 2
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

