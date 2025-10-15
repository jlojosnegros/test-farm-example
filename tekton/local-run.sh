#!/usr/bin/env bash
set -a
source .env
set +a

set -euo pipefail

echo ">> IMAGE_REF: ${IMAGE_REF}"
echo ">> Submitting Testing Farm request"

# Build array of --tmt-environment arguments. We pass IMAGE_REF as its own env var,
# separately from any other TF_TMT_ENV provided by the user.
TMT_ENV_ARGS=( --tmt-environment "IMAGE_REF=${IMAGE_REF}" )
if [[ -n "${TF_TMT_ENV}" ]]; then
  # Space-separated "K=V K2=V2" propagated to the plan environment.
  TMT_ENV_ARGS+=( --tmt-environment "${TF_TMT_ENV}" )
fi

# Submit request and capture JSON response (JSON by default?)
REQ_JSON=$(testing-farm request \
  --compose "${TF_COMPOSE}" \
  --arch "${TF_ARCH}" \
  --git-url "${TF_GIT_URL}" \
  --git-ref "${TF_GIT_REF}" \
  --plan "${TF_PLAN}" \
  --timeout "${TF_TIMEOUT_MIN}" \
  "${TMT_ENV_ARGS[@]}")

# Extract request id (schema may vary slightly; try common fields)
REQ_ID=$(echo "$REQ_JSON" | jq -r '.id // .request.id // empty')
if [[ -z "${REQ_ID:-}" ]]; then
  echo "ERROR: Unable to extract Testing Farm request id"
  echo "$REQ_JSON"
  exit 2
fi
echo ">> Request ID: $REQ_ID"

echo ">> Waiting for completion (timeout: ${TF_TIMEOUT_MIN} min)"
TIMEOUT_SECONDS=$(( ( ${TF_TIMEOUT_MIN} + 10 ) * 60 ))
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))

# Poll every 30s; 
while true; do
  OUT=$(testing-farm list --id "$REQ_ID" --format json || true)
  STATE=$(echo "$OUT" | jq -r '.state // .request.state // empty')
  RESULT=$(echo "$OUT" | jq -r '.result.overall // .result // empty')

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

