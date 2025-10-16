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

# Add registry credentials if provided
if [[ -n "${REGISTRY_USER:-}" ]] && [[ -n "${REGISTRY_PASSWORD:-}" ]]; then
  TEST_ENV_ARGS+=( --environment "REGISTRY_USER=${REGISTRY_USER}" )
  TEST_ENV_ARGS+=( --environment "REGISTRY_PASSWORD=${REGISTRY_PASSWORD}" )
fi

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

# Display the exact command that will be executed
echo ""
echo "==> Executing command:"
echo "testing-farm request \\"
echo "  --compose \"${TF_COMPOSE}\" \\"
echo "  --arch \"${TF_ARCH}\" \\"
echo "  --git-url \"${TF_GIT_URL}\" \\"
echo "  --git-ref \"${TF_GIT_REF}\" \\"
echo "  --path \"${TF_PATH}\" \\"
echo "  --plan \"${TF_PLAN}\" \\"
echo "  --timeout \"${TF_TIMEOUT_MIN}\" \\"
echo "  --no-wait \\"
for arg in "${TEST_ENV_ARGS[@]}"; do
  echo "  $arg \\"
done
for arg in "${TMT_ENV_ARGS[@]}"; do
  echo "  $arg"
done
echo ""

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

# Declare TEST_LOG_URL placeholder (will be updated after test completion)
TEST_LOG_URL="${ARTIFACTS_URL}/results.xml"
echo ">> Test Log URL placeholder: $TEST_LOG_URL"

# Function to try fetching and parsing test logs from Testing Farm artifacts
# Returns: successes failures summary_text (space-separated)
try_parse_test_results() {
  local req_id="$1"
  local artifacts_base="https://artifacts.dev.testing-farm.io/${req_id}"

  # Fetch results.xml which contains all artifact paths
  echo ">> Fetching results.xml from artifacts..." >&2
  local results_xml=$(curl -s -f "${artifacts_base}/results.xml" 2>/dev/null)

  if [[ -z "${results_xml}" ]]; then
    echo ">> Could not fetch results.xml from artifacts, using defaults" >&2
    echo "0 0 "
    return
  fi

  # Extract test log URL from results.xml
  # Use two-step grep to handle any attribute order (href can be before or after name)
  local log_url=$(echo "${results_xml}" | grep 'name="testout\.log"' | grep -oP 'href="\K[^"]+' | head -1 || echo "")

  if [[ -z "${log_url}" ]]; then
    echo ">> Could not find testout.log in results.xml, using defaults" >&2
    echo "0 0 "
    return
  fi

  echo ">> Found test log at: ${log_url}" >&2

  # Download the actual log content
  local log_content=$(curl -s -f "${log_url}" 2>/dev/null)

  # If we couldn't download the log, return defaults
  if [[ -z "${log_content}" ]]; then
    echo ">> Could not download test log from ${log_url}, using defaults" >&2
    echo "0 0 "
    return
  fi

  # Parse FAILURE SUMMARY
  local total_tests=0
  local failures=0
  local successes=0
  local summary=""

  if echo "${log_content}" | grep -q "FAILURE SUMMARY"; then
    # Extract the summary section
    summary=$(echo "${log_content}" | sed -n '/FAILURE SUMMARY/,/^========================================$/p')

    # Parse "Total failures: X out of Y test binaries"
    if [[ "${summary}" =~ Total\ failures:\ ([0-9]+)\ out\ of\ ([0-9]+) ]]; then
      failures="${BASH_REMATCH[1]}"
      total_tests="${BASH_REMATCH[2]}"
      successes=$((total_tests - failures))
    fi
  else
    # No FAILURE SUMMARY means all tests passed
    # Try to count test binaries from the markers
    total_tests=$(echo "${log_content}" | grep -c "^<=== .*OK$" || echo "0")
    successes=${total_tests}
    failures=0
  fi

  echo "${successes} ${failures} ${summary}"
}

echo ">> Waiting for completion (timeout: ${TF_TIMEOUT_MIN} min)"
TIMEOUT_SECONDS=$(( ( ${TF_TIMEOUT_MIN} + 10 ) * 60 ))
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))

# Poll every 30s;
while true; do
  OUT=$(testing-farm list --id "$REQ_ID" --format json || true)
  STATE=$(echo "$OUT" | jq -r '.[0].state // empty')
  RESULT=$(echo "$OUT" | jq -r '.[0].result.overall // .[0].result // empty')

  echo "Current: state=${STATE:-?} result=${RESULT:-?}"

  # Check if request reached a terminal state
  if [[ "$STATE" == "complete" ]]; then
    echo ">> Test completed, attempting to fetch detailed results..."

    # Extract TEST_LOG_URL from results.xml now that test is complete
    # Use retry logic to handle race conditions and network issues
    echo ">> Extracting test log URL from results.xml..."
    MAX_RETRIES_FINAL=5
    RETRY_DELAY_FINAL=2
    RESULTS_XML_FINAL=""

    for attempt in $(seq 1 $MAX_RETRIES_FINAL); do
      echo ">> Attempt $attempt/$MAX_RETRIES_FINAL to fetch results.xml after completion..."
      RESULTS_XML_FINAL=$(curl -s -f "${ARTIFACTS_URL}/results.xml" 2>/dev/null || echo "")

      if [[ -n "${RESULTS_XML_FINAL}" ]]; then
        echo ">> results.xml fetched successfully after completion"

        # Save results.xml to local disk for debugging
        RESULTS_XML_FILE="results-${REQ_ID}.xml"
        echo "${RESULTS_XML_FINAL}" > "${RESULTS_XML_FILE}"
        echo ">> Saved results.xml to: ${RESULTS_XML_FILE}"

        break
      fi

      if [[ $attempt -lt $MAX_RETRIES_FINAL ]]; then
        echo ">> results.xml not yet available, waiting ${RETRY_DELAY_FINAL}s before retry..."
        sleep $RETRY_DELAY_FINAL
      fi
    done

    if [[ -n "${RESULTS_XML_FINAL}" ]]; then
      # Extract URL in two steps to handle any attribute order
      # Step 1: Find the line with name="testout.log"
      # Step 2: Extract href value from that line
      TEST_LOG_URL_FINAL=$(echo "${RESULTS_XML_FINAL}" | grep 'name="testout\.log"' | grep -oP 'href="\K[^"]+' | head -1 || echo "")
      if [[ -n "${TEST_LOG_URL_FINAL}" ]]; then
        echo ">> Test log URL found: ${TEST_LOG_URL_FINAL}"
        TEST_LOG_URL="${TEST_LOG_URL_FINAL}"
      else
        echo ">> Could not extract test log URL from results.xml, keeping placeholder"
      fi
    else
      echo ">> Could not fetch results.xml after $MAX_RETRIES_FINAL attempts, keeping placeholder"
    fi

    # Try to parse test results from artifacts
    read -r SUCCESSES FAILURES SUMMARY <<< "$(try_parse_test_results "$REQ_ID")"

    # If we got real metrics, use them; otherwise use defaults
    if [[ -z "${SUCCESSES}" ]] || [[ "${SUCCESSES}" == "0" && "${FAILURES}" == "0" ]]; then
      # Fallback to simple counting based on overall result
      if [[ "$RESULT" == "passed" ]]; then
        SUCCESSES=1
        FAILURES=0
      else
        SUCCESSES=0
        FAILURES=1
      fi
    fi

    # Display summary if we got one
    if [[ -n "${SUMMARY}" ]]; then
      echo ""
      echo ">> Detailed test summary:"
      echo "${SUMMARY}"
      echo ""
    fi

    if [[ "$RESULT" == "passed" ]]; then
      echo ">> PASSED (${SUCCESSES} test binaries succeeded)"
      echo ">> Test Log: ${TEST_LOG_URL}"
      exit 0
    else
      echo ">> FAILED (${FAILURES} out of $((SUCCESSES + FAILURES)) test binaries failed)"
      echo ">> Test Log: ${TEST_LOG_URL}"
      testing-farm list --id "$REQ_ID" --format text || true
      exit 1
    fi
  elif [[ "$STATE" == "error" ]]; then
    echo ">> ERROR: Infrastructure error occurred"
    testing-farm list --id "$REQ_ID" --format text || true
    exit 2
  elif [[ "$STATE" == "canceled" ]]; then
    echo ">> CANCELED: Request was canceled"
    testing-farm list --id "$REQ_ID" --format text || true
    exit 3
  fi

  # Check for timeout
  if (( $(date +%s) > DEADLINE )); then
    echo ">> TIMEOUT after ${TF_TIMEOUT_MIN} minutes"
    testing-farm list --id "$REQ_ID" --format text || true
    exit 4
  fi

  sleep 30
done

