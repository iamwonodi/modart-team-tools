#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
F="${SCRIPTS}/fetch-role-arn.sh"
ARNS="${WORK}/role-arns.json"
export FAKE_GH_ROLE_ARNS_FILE="${ARNS}" FAKE_GH_LOG="${WORK}/gh.log"
# The tests use their own environment list, not the repository's (a project may run only some).
echo '["development","staging","production"]' > "${WORK}/environments.json"
export ENVIRONMENTS_FILE="${WORK}/environments.json"
run(){ : > "${FAKE_GH_LOG}"; bash "$F" --core acme/core --repo acme/team-tools "$@"; }

echo "== fetch-role-arn.sh"
echo '{"service_role_arns":{"acme/team-tools":"arn:aws:iam::123456789012:role/acme-team-tools"}}' > "${ARNS}"
run >/dev/null 2>&1; rc=$?
check "the ARNs are found"                                  test $rc -eq 0
for e in development staging production; do
  check "$e: read from core's role-arns"                    grep -q "repos/acme/core/contents/role-arns/$e.json?ref=platform-outputs" "${FAKE_GH_LOG}"
  check "$e: set on the deploy and plan environments"       bash -c "grep -q -- '--env $e --body arn:aws:iam::' '${FAKE_GH_LOG}' && grep -q -- '--env $e-plan --body arn:aws:iam::' '${FAKE_GH_LOG}'"
done
run --environment staging >/dev/null 2>&1
check "--environment does just that one"                    bash -c "grep -q 'role-arns/staging.json' '${FAKE_GH_LOG}' && ! grep -q 'role-arns/development.json' '${FAKE_GH_LOG}'"
check "an unknown --environment is refused"                 bash -c "! bash '$F' --core acme/core --repo acme/team-tools --environment testing >/dev/null 2>&1"
echo '{"service_role_arns":{}}' > "${ARNS}"
out="$(run 2>&1)"
check "a missing role points at core's tfvars"              bash -c "grep -q 'team_tools_repository' <<< \"$out\""
echo '{"service_role_arns":{"acme/team-tools":"not-an-arn"}}' > "${ARNS}"
check "a malformed ARN is refused"                          bash -c "! run >/dev/null 2>&1"
: > "${ARNS}"
check "an unreadable core is reported"                      bash -c "! run >/dev/null 2>&1"
echo '{"service_role_arns":{"acme/team-tools":"arn:aws:iam::123456789012:role/acme-team-tools"}}' > "${ARNS}"
echo '["development","production"]' > "${WORK}/environments.json"
ENVIRONMENTS_FILE="${WORK}/environments.json" run >/dev/null 2>&1
check "by default, only the environments listed"            bash -c "grep -q 'role-arns/production.json' '${FAKE_GH_LOG}' && ! grep -q 'role-arns/staging.json' '${FAKE_GH_LOG}'"
check "one not listed is refused by name"                   bash -c "! ENVIRONMENTS_FILE='${WORK}/environments.json' bash '$F' --core acme/core --repo acme/team-tools --environment staging >/dev/null 2>&1"
finish
