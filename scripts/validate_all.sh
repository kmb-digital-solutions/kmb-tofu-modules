#!/usr/bin/env bash
#
# Validate every module and application root in the repository.
#
# Runs `tofu fmt -check`, `tofu init -backend=false`, `tofu validate` for
# each module in modules/* and each application root in applications/*.
# Local equivalent of the `module-validate.yml` CI workflow.
#
# Exit codes:
#   0 — everything validates clean.
#   1 — at least one module/root failed.

set -uo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${REPO_ROOT}"

FAILED=0

validate_one() {
    local dir="$1"
    local label="$2"

    if [[ ! -f "${dir}/main.tf" ]]; then
        return 0
    fi

    echo "─── ${label}: ${dir} ───"

    if ! tofu fmt -check -recursive "${dir}"; then
        echo "${SCRIPT_NAME}: ${dir}: tofu fmt failed" >&2
        FAILED=1
        return 0
    fi

    (
        cd "${dir}"
        tofu init -backend=false -input=false -no-color > /dev/null 2>&1 \
            || { echo "${SCRIPT_NAME}: ${dir}: tofu init failed" >&2; exit 1; }
        tofu validate -no-color \
            || { echo "${SCRIPT_NAME}: ${dir}: tofu validate failed" >&2; exit 1; }
    ) || FAILED=1
}

for dir in modules/*/; do
    [[ -d "${dir}" ]] || continue
    validate_one "${dir%/}" "module"
done

for dir in applications/*/; do
    [[ -d "${dir}" ]] || continue
    validate_one "${dir%/}" "application"
done

if [[ "${FAILED}" -ne 0 ]]; then
    echo
    echo "${SCRIPT_NAME}: at least one module/root failed validation." >&2
    exit 1
fi

echo
echo "${SCRIPT_NAME}: all modules + roots validate clean."
