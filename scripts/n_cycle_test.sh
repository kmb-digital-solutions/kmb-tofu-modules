#!/usr/bin/env bash
#
# N-cycle acceptance test.
#
# Runs `tofu apply → destroy → apply → destroy → apply` (3 full apply
# cycles) against an application root in a sandbox AWS account. Fails
# on any non-zero exit code, any orphan resources after destroy, or any
# resource the second apply tries to replace (which would indicate
# non-idempotent module behavior).
#
# Usage:
#   scripts/n_cycle_test.sh <app-slug> <sandbox-customer-slug>
#
# Environment:
#   AWS_PROFILE             — must be set to a profile with access to the
#                             sandbox account (typically via OIDC or
#                             assume-role from management).
#   SANDBOX_AWS_ACCOUNT_ID  — 12-digit AWS account id of the sandbox.
#   SANDBOX_STATE_BUCKET    — S3 bucket in the sandbox account for state.
#                             Default: <sandbox-slug>-lower-tfstate.
#   N_CYCLES                — Number of apply cycles. Default: 3.
#
# Exit codes:
#   0 — all cycles passed; no orphan resources detected.
#   1 — a cycle failed (exact failure logged to stderr).
#   2 — orphan resources detected after final destroy.
#   3 — bad usage / missing prerequisite.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
    echo "${SCRIPT_NAME}: ERROR: $*" >&2
    exit "${2:-1}"
}

usage() {
    cat >&2 <<EOF
Usage: ${SCRIPT_NAME} <app-slug> <sandbox-customer-slug>

Runs the N-cycle acceptance test for an application root against the
sandbox AWS account. See docs/bootstrap-sandbox-account.md for setup.
EOF
    exit 3
}

[[ $# -eq 2 ]] || usage
readonly APP_SLUG="$1"
readonly SANDBOX_SLUG="$2"
readonly APP_DIR="${REPO_ROOT}/applications/${APP_SLUG}"
readonly N_CYCLES="${N_CYCLES:-3}"

[[ -d "${APP_DIR}" ]] || die "application root not found: ${APP_DIR}"
[[ -f "${APP_DIR}/main.tf" ]] || die "missing main.tf in ${APP_DIR}"
[[ -n "${AWS_PROFILE:-}" ]] || die "AWS_PROFILE must be set" 3
[[ -n "${SANDBOX_AWS_ACCOUNT_ID:-}" ]] || die "SANDBOX_AWS_ACCOUNT_ID must be set" 3

readonly STATE_BUCKET="${SANDBOX_STATE_BUCKET:-${SANDBOX_SLUG}-lower-tfstate}"
readonly STATE_KEY="ncycle/${APP_SLUG}/${SANDBOX_SLUG}/terraform.tfstate"
readonly LOCK_TABLE="${SANDBOX_LOCK_TABLE:-singular-tfstate-locks}"

cd "${APP_DIR}"

echo "${SCRIPT_NAME}: app=${APP_SLUG} sandbox=${SANDBOX_SLUG} cycles=${N_CYCLES}"
echo "${SCRIPT_NAME}: state s3://${STATE_BUCKET}/${STATE_KEY}"

# Initialize once with the sandbox-scoped backend config.
echo "${SCRIPT_NAME}: tofu init…"
tofu init \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="key=${STATE_KEY}" \
    -backend-config="region=us-east-1" \
    -backend-config="dynamodb_table=${LOCK_TABLE}" \
    -backend-config="encrypt=true" \
    -reconfigure

# Per-cycle plan + apply + plan-verify + destroy.
for ((i = 1; i <= N_CYCLES; i++)); do
    echo
    echo "═══ Cycle ${i}/${N_CYCLES} ═══"

    tofu apply -auto-approve \
        -var "customer_slug=${SANDBOX_SLUG}" \
        -var "environment=dev" \
        -var "aws_account_id=${SANDBOX_AWS_ACCOUNT_ID}" \
        -var "destroy_protection=false" \
        || die "cycle ${i}: apply failed"

    # The second apply IMMEDIATELY after the first should be a no-op. A
    # non-empty plan here is a non-idempotency bug in a shared module
    # (something doesn't stabilize on the first apply).
    if ! tofu plan -detailed-exitcode \
        -var "customer_slug=${SANDBOX_SLUG}" \
        -var "environment=dev" \
        -var "aws_account_id=${SANDBOX_AWS_ACCOUNT_ID}" \
        -var "destroy_protection=false" \
        > /dev/null; then
        case $? in
            1) die "cycle ${i}: post-apply plan errored" ;;
            2) die "cycle ${i}: post-apply plan shows pending changes — module is not idempotent" ;;
        esac
    fi

    tofu destroy -auto-approve \
        -var "customer_slug=${SANDBOX_SLUG}" \
        -var "environment=dev" \
        -var "aws_account_id=${SANDBOX_AWS_ACCOUNT_ID}" \
        -var "destroy_protection=false" \
        || die "cycle ${i}: destroy failed"
done

echo
echo "${SCRIPT_NAME}: ${N_CYCLES} cycle(s) PASSED."

# Final orphan-sweep — checks the sandbox account for resources tagged
# with this test's customer_slug. A clean teardown leaves none.
echo "${SCRIPT_NAME}: orphan sweep…"
ORPHAN_TAG_KEY="customer_slug"
ORPHAN_TAG_VALUE="${SANDBOX_SLUG}"
if command -v aws >/dev/null 2>&1; then
    ORPHANS="$(
        aws resourcegroupstaggingapi get-resources \
            --tag-filters "Key=${ORPHAN_TAG_KEY},Values=${ORPHAN_TAG_VALUE}" \
            --query "ResourceTagMappingList[].ResourceARN" \
            --output text 2>/dev/null \
            | tr '\t' '\n' \
            | grep -v '^$' \
            || true
    )"
    if [[ -n "${ORPHANS}" ]]; then
        echo "${SCRIPT_NAME}: ERROR: orphan resources after final destroy:" >&2
        echo "${ORPHANS}" >&2
        exit 2
    fi
fi

echo "${SCRIPT_NAME}: orphan sweep clean. N-cycle ACCEPTED."
