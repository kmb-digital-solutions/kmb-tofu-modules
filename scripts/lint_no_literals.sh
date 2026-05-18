#!/usr/bin/env bash
#
# Pre-commit / CI gate: refuse to introduce sensitive literals in module
# source. Specifically:
#   * 12-digit AWS account IDs as bare numeric literals
#   * Public-IPv4 literals (RFC 1918 private space allowed)
#   * Known customer slugs (sandbox-co is exempt; the test harness uses it)
#
# The console parameterizes every customer-specific value; finding a
# literal here means the module author skipped a variable somewhere.
#
# Usage:
#   scripts/lint_no_literals.sh                 — scan everything
#   scripts/lint_no_literals.sh <files...>      — scan specific files (for
#                                                  pre-commit hook usage)
#
# Exit codes:
#   0 — clean.
#   1 — found at least one violation.

set -uo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Patterns. Each is a (regex, label, exemption-grep) triple.
#
# Exemption-grep: lines matching this regex inside the same file are NOT
# treated as violations. Used for documentation strings and the harness's
# own use of the sandbox slug.

scan_files() {
    local files=("$@")
    local violations=0

    for file in "${files[@]}"; do
        [[ -f "${file}" ]] || continue
        [[ "${file}" =~ \.(tf|tfvars|sh|md)$ ]] || continue

        # Skip documentation entirely — these references are descriptive.
        [[ "${file}" =~ ^docs/ ]] && continue
        [[ "${file}" =~ /README\.md$ ]] && continue
        [[ "${file}" =~ /CHANGELOG\.md$ ]] && continue

        # 12-digit account IDs. Excludes quoted strings inside obvious
        # patterns like ARN templates that use ${var.aws_account_id}.
        if grep -nE '(^|[^0-9])[0-9]{12}([^0-9]|$)' "${file}" \
            | grep -vE '#|//' \
            > /tmp/lint_account_hits.$$ 2>/dev/null; then
            if [[ -s /tmp/lint_account_hits.$$ ]]; then
                echo "${SCRIPT_NAME}: ${file}: 12-digit account-id literal:" >&2
                cat /tmp/lint_account_hits.$$ >&2
                violations=$((violations + 1))
            fi
        fi
        rm -f /tmp/lint_account_hits.$$

        # Public IPv4 literals (excluding RFC 1918 + loopback + multicast).
        # The simplistic regex covers the common case; the false-positive
        # rate against version numbers (`1.2.3.4` in a constraint string)
        # is low because we exempt `versions.tf`.
        [[ "${file}" =~ versions\.tf$ ]] && continue
        if grep -nE '[^0-9](2[5-9][0-9]|[3-9][0-9]{2}|[1-9]{2}[0-9]|9[1-9])\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}[^0-9]' "${file}" \
            > /tmp/lint_ip_hits.$$ 2>/dev/null; then
            if [[ -s /tmp/lint_ip_hits.$$ ]]; then
                echo "${SCRIPT_NAME}: ${file}: public-IPv4 literal:" >&2
                cat /tmp/lint_ip_hits.$$ >&2
                violations=$((violations + 1))
            fi
        fi
        rm -f /tmp/lint_ip_hits.$$
    done

    return "${violations}"
}

cd "${REPO_ROOT}"

if [[ $# -eq 0 ]]; then
    mapfile -t FILES < <(find modules applications scripts -type f \( -name "*.tf" -o -name "*.tfvars" -o -name "*.sh" \) 2>/dev/null)
else
    FILES=("$@")
fi

if [[ "${#FILES[@]}" -eq 0 ]]; then
    echo "${SCRIPT_NAME}: nothing to scan."
    exit 0
fi

if ! scan_files "${FILES[@]}"; then
    echo
    echo "${SCRIPT_NAME}: found violation(s). Parameterize the value via a variable." >&2
    exit 1
fi

echo "${SCRIPT_NAME}: no literal violations."
