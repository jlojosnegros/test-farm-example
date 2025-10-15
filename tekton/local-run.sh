#!/usr/bin/env bash
set -a
source .env
set +a

set -euo pipefail

echo "==> Configuration loaded from .env:"
echo "    TESTING_FARM_API_TOKEN: ${TESTING_FARM_API_TOKEN:0:8}... (hidden)"
echo "    TF_COMPOSE: ${TF_COMPOSE}"
echo "    TF_ARCH: ${TF_ARCH}"
echo "    IMAGE_REF: ${IMAGE_REF}"
echo "    TF_GIT_URL: ${TF_GIT_URL}"
echo "    TF_GIT_REF: ${TF_GIT_REF}"
echo "    TF_PATH: ${TF_PATH}"
echo "    TF_PLAN: ${TF_PLAN}"
echo "    TF_TIMEOUT_MIN: ${TF_TIMEOUT_MIN}"
echo "    TF_TEST_ENV: ${TF_TEST_ENV}"
echo "    TF_TMT_ENV: ${TF_TMT_ENV}"
echo ""
echo ">> Submitting Testing Farm request"

# Build array of --environment arguments for test environment variables.
# Always pass IMAGE_REF, plus any user-specified variables from TF_TEST_ENV.
TEST_ENV_ARGS=( --environment "IMAGE_REF=${IMAGE_REF}" )
if [[ -n "${TF_TEST_ENV}" ]]; then
  # Space-separated "K=V K2=V2" propagated to the test environment.
  TEST_ENV_ARGS+=( --environment "${TF_TEST_ENV}" )
fi

# Build array of --tmt-environment arguments for tmt process configuration.
# Used for configuring tmt report plugins (reportportal, polarion, etc).
TMT_ENV_ARGS=()
if [[ -n "${TF_TMT_ENV}" ]]; then
  TMT_ENV_ARGS+=( --tmt-environment "${TF_TMT_ENV}" )
fi

# Submit request (with --no-wait to get ID immediately without waiting)
REQ_OUTPUT=$(testing-farm request \
  --compose "${TF_COMPOSE}" \
  --arch "${TF_ARCH}" \
  --git-url "${TF_GIT_URL}" \
  --git-ref "${TF_GIT_REF}" \
  --path "${TF_PATH}" \
  --plan "${TF_PLAN}" \
  --timeout "${TF_TIMEOUT_MIN}" \
  --no-wait \
  "${TEST_ENV_ARGS[@]}" \
  "${TMT_ENV_ARGS[@]}" 2>&1)

echo ""
echo "==> Request Output:"
echo "$REQ_OUTPUT"
echo ""

# Extract request ID from the "api" line
# Format: 🔎 api https://api.dev.testing-farm.io/v0.1/requests/REQUEST-ID
REQ_ID=$(echo "$REQ_OUTPUT" | grep -oP 'requests/\K[a-f0-9-]+' | head -1)
echo "==> Extracted Request ID: '${REQ_ID}'"

if [[ -z "${REQ_ID:-}" ]]; then
  echo "ERROR: Unable to extract Testing Farm request id"
  echo "Full output was:"
  echo "$REQ_OUTPUT"
  exit 2
fi

# Construct URLs
API_URL="https://api.dev.testing-farm.io/v0.1/requests/${REQ_ID}"
ARTIFACTS_URL="https://artifacts.dev.testing-farm.io/${REQ_ID}"

echo ""
echo ">> Request ID: $REQ_ID"
echo ">> API URL: $API_URL"
echo ">> Artifacts URL: $ARTIFACTS_URL"

echo ">> Waiting for completion (timeout: ${TF_TIMEOUT_MIN} min)"
TIMEOUT_SECONDS=$(( ( ${TF_TIMEOUT_MIN} + 10 ) * 60 ))
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))

# Poll every 30s;
while true; do
  OUT=$(testing-farm list --id "$REQ_ID" --format json || true)
  STATE=$(echo "$OUT" | jq -r '.[0].state // empty')
  RESULT=$(echo "$OUT" | jq -r '.[0].result.overall // .[0].result // empty')

  echo "Current: state=${STATE:-?} result=${RESULT:-?}"

  if [[ "$STATE" == "complete" ]]; then
    if [[ "$RESULT" == "passed" ]]; then
      echo ">> PASSED"
      exit 0
    else
      echo ">> FAILED (result=${RESULT:-unknown})"
      testing-farm list --id "$REQ_ID" --format text || true
      exit 1
    fi
  fi

  if (( $(date +%s) > DEADLINE )); then
    echo ">> TIMEOUT after ${TF_TIMEOUT_MIN} minutes"
    testing-farm list --id "$REQ_ID" --format text || true
    exit 3
  fi

  sleep 30
done

