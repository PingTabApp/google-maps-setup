#!/usr/bin/env bash
#
# Runs setup.sh against a fake gcloud and a fake PingTab API, and asserts what
# it did. No Google account, no network beyond loopback, nothing written into
# the repo. See test/README.md.
#
#   ./test/run.sh              every case
#   ./test/run.sh billing      only cases whose name contains "billing"
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
SETUP="${REPO}/setup.sh"
FILTER="${1:-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pingtab-maps-test.XXXXXX")"
# "Nothing is written into the repo" has to hold whatever TMPDIR says.
case "$(cd "$WORK" && pwd -P)" in
  "$(cd "$REPO" && pwd -P)"/*) rmdir "$WORK"; echo "TMPDIR points inside the repository; refusing." >&2; exit 2 ;;
esac
API_PIDS=()

# shellcheck disable=SC2329  # invoked by the trap below
cleanup() {
  local pid
  for pid in ${API_PIDS+"${API_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  for pid in ${API_PIDS+"${API_PIDS[@]}"}; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASSED=0
FAILED=0
SKIPPED=0
FAILED_NAMES=()

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
grey()  { printf '\033[90m%s\033[0m' "$1"; }

# ------------------------------------------------------------- fake servers ---

# Only for the "API unreachable" case, which wants a port nobody listens on.
# Servers do not use this: they bind port 0 themselves and report back, so
# there is no window in which something else can take the port first.
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# start_api <mode>: sets API_URL_OUT to the base URL. Its POST log, which is how
# we count what was actually sent, is $WORK/api-<mode>.log.
#
# Never call this in a command substitution. It has to run in this shell so the
# server pid reaches API_PIDS for the cleanup trap and the log path reaches
# API_LOG for the assertions; a subshell would silently lose both.
declare -A API_URL=()
declare -A API_LOG=()
API_URL_OUT=""
start_api() {
  local mode="$1" port url tries=0
  if [[ -n "${API_URL[$mode]:-}" ]]; then
    API_URL_OUT="${API_URL[$mode]}"
    return 0
  fi

  local pid portfile="${WORK}/api-${mode}.port"
  python3 "${HERE}/fakeapi.py" "$mode" 0 "$portfile" >"${WORK}/api-${mode}.log" 2>&1 &
  pid=$!
  API_PIDS+=("$pid")
  while (( tries < 50 )); do
    if [[ -s "$portfile" ]] && kill -0 "$pid" 2>/dev/null; then
      port="$(<"$portfile")"
      url="http://127.0.0.1:${port}"
      if curl -sS -m 1 -o /dev/null "${url}/api/maps-setup/ABCD2345" 2>/dev/null; then break; fi
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  if (( tries >= 50 )) || ! kill -0 "$pid" 2>/dev/null; then
    echo "fake API (${mode}) did not come up. Its log:" >&2
    cat "${WORK}/api-${mode}.log" >&2 || true
    exit 2
  fi
  API_URL["$mode"]="$url"
  API_LOG["$mode"]="${WORK}/api-${mode}.log"
  API_URL_OUT="$url"
}

# ------------------------------------------------------------------- runner ---

# Set before each case; consumed and reset by run_case.
CASE_ENV=()
CASE_ANSWERS=""

OUT=""
STATUS=0
STATE=""

# run_case <name> <args...>
# Runs setup.sh with CASE_ENV exported and, if CASE_ANSWERS is set, through a
# pseudo-terminal so the prompts actually appear. Leaves the output in OUT, the
# exit status in STATUS, and the shim's state directory in STATE.
run_case() {
  local name="$1"; shift
  STATE="${WORK}/state-$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')"
  rm -rf "$STATE"; mkdir -p "$STATE"

  local env_args=(
    "PATH=${HERE}/bin:${PATH}"
    "SHIM_STATE=${STATE}"
    "GOOGLE_CLOUD_PROJECT="
  )
  env_args+=(${CASE_ENV+"${CASE_ENV[@]}"})

  local cmd=(env "${env_args[@]}" "$SETUP" "$@")

  if [[ -n "$CASE_ANSWERS" ]]; then
    # setup.sh only prompts when [ -t 0 ], and there is deliberately no
    # override for that, so a real pty is the only way to answer it.
    local quoted
    quoted="$(printf '%q ' "${cmd[@]}")"
    OUT="$(printf '%b' "$CASE_ANSWERS" | script -qfec "$quoted" /dev/null 2>&1 | tr -d '\r')"
    STATUS=$?
  else
    OUT="$("${cmd[@]}" 2>&1)"
    STATUS=$?
  fi
  # setup.sh colours its output. Strip the escapes so assertions can match the
  # words a person would read, "[dry run] gcloud ..." included.
  OUT="$(printf '%s' "$OUT" | sed $'s/\033\[[0-9;]*m//g')"
  CASE_ENV=()
  CASE_ANSWERS=""
}

# Assertions. Each appends to PROBLEMS; check() reports and resets.
PROBLEMS=()

expect_status() {
  [[ "$STATUS" == "$1" ]] || PROBLEMS+=("exit status was ${STATUS}, wanted ${1}")
}
expect_out() {
  grep -qF -- "$1" <<<"$OUT" || PROBLEMS+=("output missing: $1")
}
expect_not_out() {
  grep -qF -- "$1" <<<"$OUT" && PROBLEMS+=("output should not contain: $1")
  return 0
}
# expect_calls <count> <grep pattern> -- how many matching gcloud calls happened
expect_calls() {
  local want="$1" pat="$2" got=0
  [[ -f "${STATE}/calls.log" ]] && got="$(grep -cE -- "$pat" "${STATE}/calls.log" || true)"
  [[ "$got" == "$want" ]] || PROBLEMS+=("gcloud calls matching /${pat}/ were ${got}, wanted ${want}")
}
# expect_posts <count> <api mode>
expect_posts() {
  local want="$1" mode="$2" got=0
  [[ -f "${API_LOG[$mode]:-}" ]] && got="$(grep -c '^POST ' "${API_LOG[$mode]}" || true)"
  [[ "$got" == "$want" ]] || PROBLEMS+=("POSTs to the ${mode} API were ${got}, wanted ${want}")
}
# expect_post_body <api mode> <fragment> -- a logged POST body contains this
expect_post_body() {
  local mode="$1" frag="$2"
  grep '^POST ' "${API_LOG[$mode]:-/dev/null}" 2>/dev/null | grep -qF -- "$frag" \
    || PROBLEMS+=("no POST to the ${mode} API carried: $frag")
}
# The fake API answers 422 and logs BAD POST when a request breaks the contract.
expect_no_bad_posts() {
  local mode="$1"
  if grep -q '^BAD POST ' "${API_LOG[$mode]:-/dev/null}" 2>/dev/null; then
    PROBLEMS+=("the ${mode} API rejected a POST: $(grep '^BAD POST ' "${API_LOG[$mode]}" | head -1)")
  fi
}
expect_no_keys() { expect_not_out "AIza"; }
expect_keys()    { expect_out "AIza"; }

check() {
  local name="$1"
  if (( ${#PROBLEMS[@]} == 0 )); then
    printf '%s  %s\n' "$(green PASS)" "$name"
    PASSED=$((PASSED + 1))
  else
    printf '%s  %s\n' "$(red FAIL)" "$name"
    local p
    for p in "${PROBLEMS[@]}"; do printf '        %s\n' "$p"; done
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$name")
  fi
  PROBLEMS=()
}

skip() {
  printf '%s  %s (%s)\n' "$(grey SKIP)" "$1" "$2"
  SKIPPED=$((SKIPPED + 1))
}

wanted() { [[ -z "$FILTER" || "$1" == *"$FILTER"* ]]; }

# ------------------------------------------------------------------ preflight ---

for tool in python3 curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "run.sh needs ${tool}." >&2; exit 2; }
done
[[ -x "$SETUP" ]] || { echo "Cannot find an executable ${SETUP}." >&2; exit 2; }

HAVE_SCRIPT=1
command -v script >/dev/null 2>&1 || HAVE_SCRIPT=0

ONE_ACCOUNT="$(printf 'billingAccounts/012345-ABCDEF\tKerala Cabs Billing')"
THREE_ACCOUNTS="$(printf 'billingAccounts/012345-ABCDEF\tKerala Cabs Billing\nbillingAccounts/999888-ZZZZZZ\tPersonal Card\nbillingAccounts/777777-YYYYYY\tThird Account')"

start_api ok; OK_API="$API_URL_OUT"
CODE=(--code ABCD-2345 --api "$OK_API")

echo
echo "setup.sh test suite"
echo

# ===================================================== code mode, happy path ===

if wanted "code mode happy path"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "code mode happy path" "${CODE[@]}"
  expect_status 0
  expect_no_keys
  expect_out "saved, and Google confirmed it works."
  expect_out 'Test this key'
  expect_posts 1 ok
  expect_no_bad_posts ok
  expect_post_body ok '"server_key": "AIzaSyFAKEserverKEY0000000000000000000"'
  expect_post_body ok '"browser_key": "AIzaSyFAKEbrowserKEY000000000000000000"'
  expect_post_body ok '"project_id": "pepper-cabs-01"'
  expect_post_body ok '/api/maps-setup/ABCD2345/keys'
  check "code mode happy path"
fi

if wanted "code mode is idempotent"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "code mode is idempotent" "${CODE[@]}"
  # Run again against the same state, where the first run's keys already exist.
  # The call log is emptied first so the counts below describe the second run
  # only, which is the run whose behaviour is in question.
  STATE_KEEP="$STATE"
  : >"${STATE_KEEP}/calls.log"
  OUT="$(env "PATH=${HERE}/bin:${PATH}" "SHIM_STATE=${STATE_KEEP}" \
        SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True GOOGLE_CLOUD_PROJECT= \
        "$SETUP" "${CODE[@]}" 2>&1)"
  STATUS=$?
  STATE="$STATE_KEEP"
  expect_status 0
  expect_out "is already there, updating it"
  expect_calls 0 "api-keys create"
  expect_calls 2 "api-keys update"
  check "code mode is idempotent"
fi

if wanted "code mode lowercase code is normalised"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "code mode lowercase code is normalised" --code "  abcd-2345  " --api "$OK_API"
  expect_status 0
  expect_out "saved, and Google confirmed it works."
  check "code mode lowercase code is normalised"
fi

if wanted "code mode browser key only"; then
  start_api noips; NOIPS_API="$API_URL_OUT"
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "code mode browser key only" --code ABCD-2345 --api "$NOIPS_API"
  expect_status 0
  expect_no_keys
  expect_not_out "Routes and arrival times"
  expect_calls 0 "routes.googleapis.com"
  expect_posts 1 noips
  expect_no_bad_posts noips
  expect_post_body noips '"browser_key": "AIzaSyFAKEbrowserKEY000000000000000000"'
  check "code mode browser key only"
fi

if wanted "code mode server key refused"; then
  start_api serverreject; REJECT_API="$API_URL_OUT"
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "code mode server key refused" --code ABCD-2345 --api "$REJECT_API"
  expect_status 1
  expect_no_keys
  expect_out "Google would not accept this key"
  expect_out "Your setup code still works."
  expect_posts 1 serverreject
  expect_no_bad_posts serverreject
  check "code mode server key refused"
fi

# ======================================================= code mode, fallbacks ===

if wanted "fallback GET 404"; then
  start_api notfound; NF_API="$API_URL_OUT"
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "fallback GET 404" --code ABCD-2345 --api "$NF_API"
  expect_status 1
  expect_out "not valid or has expired"
  expect_calls 0 "."        # nothing touched Google at all
  check "fallback GET 404"
fi

if wanted "fallback API unreachable"; then
  DEAD_PORT="$(free_port)"
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "fallback API unreachable" --code ABCD-2345 --api "http://127.0.0.1:${DEAD_PORT}"
  expect_status 1
  expect_out "Could not reach PingTab"
  expect_not_out "ABCD"     # the code never appears in an error
  check "fallback API unreachable"
fi

for spec in "postfail:POST 500" "post404:POST 404" "postgarbage:unreadable 200" \
            "incomplete:200 with no sections" "halfincomplete:200 missing a section" \
            "emptysection:200 with an empty section" "savedstring:200 with saved as a string"; do
  mode="${spec%%:*}"; label="${spec#*:}"
  name="fallback ${label} prints the keys"
  wanted "$name" || continue
  start_api "$mode"; API="$API_URL_OUT"
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "$name" --code ABCD-2345 --api "$API"
  expect_status 0
  expect_keys
  expect_out "Paste these into the matching fields"
  check "$name"
done

# =============================================================== manual mode ===

if wanted "manual mode both keys"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "manual mode both keys" --allowed-ips 203.0.113.10 \
    --allowed-referrers 'https://app.pingtab.com/*'
  expect_status 0
  expect_keys
  expect_out 'Server key'
  expect_out 'Browser key'
  check "manual mode both keys"
fi

if wanted "manual mode referrers only"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "manual mode referrers only" --allowed-referrers 'https://app.pingtab.com/*'
  expect_status 0
  expect_out 'Browser key'
  expect_not_out 'Server key'
  check "manual mode referrers only"
fi

# ================================================== project resolution, reads ===

if wanted "project from the gcloud config"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=from-config SHIM_BILLING=True)
  run_case "project from the gcloud config" "${CODE[@]}"
  expect_status 0
  expect_out "Project: from-config"
  check "project from the gcloud config"
fi

if wanted "project falls back to the environment"; then
  CASE_ENV=("SHIM_CONFIG_PROJECT=(unset)" GOOGLE_CLOUD_PROJECT=from-env SHIM_BILLING=True)
  run_case "project falls back to the environment" "${CODE[@]}"
  expect_status 0
  expect_out "Project: from-env"
  check "project falls back to the environment"
fi

if wanted "project flag wins"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=from-config GOOGLE_CLOUD_PROJECT=from-env SHIM_BILLING=True)
  run_case "project flag wins" "${CODE[@]}" --project from-flag
  expect_status 0
  expect_out "Project: from-flag"
  check "project flag wins"
fi

if wanted "project one project is used"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT= SHIM_PROJECTS=only-77 SHIM_BILLING=True)
  run_case "project one project is used" "${CODE[@]}"
  expect_status 0
  expect_out "Using your only Google Cloud project: only-77"
  check "project one project is used"
fi

if wanted "project many projects stop"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT= "SHIM_PROJECTS=$(printf 'a-1\nb-2')" SHIM_BILLING=True)
  run_case "project many projects stop" "${CODE[@]}"
  expect_status 1
  expect_out "You have more than one Google Cloud project"
  expect_out "a-1"
  check "project many projects stop"
fi

if wanted "project list failure is not zero projects"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT= SHIM_PROJECTS_FAIL=1 SHIM_BILLING=True)
  run_case "project list failure is not zero projects" "${CODE[@]}"
  expect_status 1
  expect_out "Could not read your Google Cloud projects"
  expect_calls 0 "projects create"
  check "project list failure is not zero projects"
fi

if wanted "project zero projects without a terminal"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT= SHIM_PROJECTS= SHIM_BILLING=True)
  run_case "project zero projects without a terminal" "${CODE[@]}"
  expect_status 1
  expect_out "Run this again in a terminal"
  expect_calls 0 "projects create"
  check "project zero projects without a terminal"
fi

# ================================================= prompts, needing a real pty ===

if (( HAVE_SCRIPT == 0 )); then
  for n in "prompt create a project, yes" "prompt create a project, no" \
           "prompt create a project fails" "prompt create then cannot select" \
           "prompt billing one account, yes" "prompt billing one account, no" \
           "prompt billing many accounts, pick and confirm" \
           "prompt billing many accounts, pick then decline" \
           "prompt billing pick 02 means 2" "prompt billing pick out of range" \
           "prompt billing link fails" "prompt enable retry after a new project" \
           "prompt enable failure names billing" \
           "prompt enable failure without billing" \
           "dry run creates nothing with prompts"; do
    wanted "$n" && skip "$n" "script(1) not installed"
  done
else

if wanted "prompt create a project, yes"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT= SHIM_PROJECTS= SHIM_BILLING=True)
  CASE_ANSWERS='y\n'
  run_case "prompt create a project, yes" "${CODE[@]}"
  expect_status 0
  expect_out "Create one called pingtab-maps-"
  expect_calls 1 "projects create pingtab-maps-"
  expect_calls 1 "config set project pingtab-maps-"
  check "prompt create a project, yes"
fi

if wanted "prompt create a project, no"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT= SHIM_PROJECTS= SHIM_BILLING=True)
  CASE_ANSWERS='\n'
  run_case "prompt create a project, no" "${CODE[@]}"
  expect_status 1
  expect_out "console.cloud.google.com/projectcreate"
  expect_calls 0 "projects create"
  check "prompt create a project, no"
fi

if wanted "prompt create a project fails"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT= SHIM_PROJECTS= SHIM_CREATE_FAIL=1 SHIM_BILLING=True)
  CASE_ANSWERS='y\n'
  run_case "prompt create a project fails" "${CODE[@]}"
  expect_status 1
  expect_out "would not let this script create a project"
  expect_calls 0 "config set project"
  check "prompt create a project fails"
fi

if wanted "prompt create then cannot select"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT= SHIM_PROJECTS= SHIM_CONFIG_SET_FAIL=1 SHIM_BILLING=True)
  CASE_ANSWERS='y\n'
  run_case "prompt create then cannot select" "${CODE[@]}"
  expect_status 1
  expect_out "but could not select it"
  expect_out "gcloud config set project pingtab-maps-"
  expect_calls 0 "api-keys create"
  check "prompt create then cannot select"
fi

if wanted "prompt created project id is well formed"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT= SHIM_PROJECTS= SHIM_BILLING=True)
  CASE_ANSWERS='y\n'
  run_case "prompt created project id is well formed" "${CODE[@]}"
  expect_status 0
  # Google's rule: 6 to 30 characters, lowercase letters, digits and hyphens,
  # starting with a letter.
  id="$(cat "${STATE}/created_project" 2>/dev/null || true)"
  [[ "$id" =~ ^[a-z][a-z0-9-]{5,29}$ ]] || PROBLEMS+=("project id \"${id}\" is not a legal Google project id")
  check "prompt created project id is well formed"
fi

if wanted "prompt billing one account, yes"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=False "SHIM_ACCOUNTS=${ONE_ACCOUNT}")
  CASE_ANSWERS='y\n'
  run_case "prompt billing one account, yes" "${CODE[@]}"
  expect_status 0
  expect_out 'Link pepper-cabs-01 to "Kerala Cabs Billing" now?'
  expect_calls 1 "billing projects link .* --billing-account=012345-ABCDEF"
  expect_out "saved, and Google confirmed it works."
  check "prompt billing one account, yes"
fi

if wanted "prompt billing one account, no"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=False "SHIM_ACCOUNTS=${ONE_ACCOUNT}")
  CASE_ANSWERS='n\n'
  run_case "prompt billing one account, no" "${CODE[@]}"
  expect_status 1
  expect_calls 0 "billing projects link"
  expect_out "No script can create a billing account for you"
  check "prompt billing one account, no"
fi

if wanted "prompt billing many accounts, pick and confirm"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=False "SHIM_ACCOUNTS=${THREE_ACCOUNTS}")
  CASE_ANSWERS='2\ny\n'
  run_case "prompt billing many accounts, pick and confirm" "${CODE[@]}"
  expect_status 0
  expect_out "Which one?"
  expect_out 'Link pepper-cabs-01 to "Personal Card" now?'
  expect_calls 1 "billing projects link .* --billing-account=999888-ZZZZZZ"
  check "prompt billing many accounts, pick and confirm"
fi

if wanted "prompt billing many accounts, pick then decline"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=False "SHIM_ACCOUNTS=${THREE_ACCOUNTS}")
  CASE_ANSWERS='2\nn\n'
  run_case "prompt billing many accounts, pick then decline" "${CODE[@]}"
  expect_status 1
  expect_calls 0 "billing projects link"
  check "prompt billing many accounts, pick then decline"
fi

if wanted "prompt billing pick 02 means 2"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=False "SHIM_ACCOUNTS=${THREE_ACCOUNTS}")
  CASE_ANSWERS='02\ny\n'
  run_case "prompt billing pick 02 means 2" "${CODE[@]}"
  expect_status 0
  expect_calls 1 "billing projects link .* --billing-account=999888-ZZZZZZ"
  check "prompt billing pick 02 means 2"
fi

if wanted "prompt billing pick out of range"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=False "SHIM_ACCOUNTS=${THREE_ACCOUNTS}")
  # 08 would be an illegal octal literal without the base-10 normalisation.
  CASE_ANSWERS='08\n'
  run_case "prompt billing pick out of range" "${CODE[@]}"
  expect_status 1
  expect_calls 0 "billing projects link"
  check "prompt billing pick out of range"
fi

if wanted "prompt billing link fails"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=False SHIM_LINK_FAIL=1 "SHIM_ACCOUNTS=${ONE_ACCOUNT}")
  CASE_ANSWERS='y\n'
  run_case "prompt billing link fails" "${CODE[@]}"
  expect_status 1
  expect_out "Google would not link"
  expect_calls 1 "billing projects link"
  check "prompt billing link fails"
fi

if wanted "prompt enable retry after a new project"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT= SHIM_PROJECTS= SHIM_BILLING=True SHIM_ENABLE_FAIL_ONCE=1)
  CASE_ANSWERS='y\n'
  run_case "prompt enable retry after a new project" "${CODE[@]}"
  expect_status 0
  expect_out "Google is still finishing that off"
  expect_calls 2 "services enable"
  check "prompt enable retry after a new project"
fi

if wanted "prompt enable failure names billing"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=error SHIM_ENABLE_FAIL_ONCE=1
            SHIM_ENABLE_ERR=billing "SHIM_ACCOUNTS=${ONE_ACCOUNT}")
  CASE_ANSWERS='y\n'
  run_case "prompt enable failure names billing" "${CODE[@]}"
  expect_status 0
  expect_out "Google says this project has no billing account."
  expect_calls 1 "billing projects link"
  check "prompt enable failure names billing"
fi

if wanted "prompt enable failure without billing"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=error SHIM_ENABLE_FAIL=1
            SHIM_ENABLE_ERR=permission "SHIM_ACCOUNTS=${ONE_ACCOUNT}")
  CASE_ANSWERS='y\n'
  run_case "prompt enable failure without billing" "${CODE[@]}"
  expect_status 1
  expect_out "permission to switch on APIs and create API keys"
  expect_not_out "billing/linkedaccount"
  expect_calls 0 "billing accounts list"
  expect_calls 0 "billing projects link"
  check "prompt enable failure without billing"
fi

if wanted "dry run creates nothing with prompts"; then
  start_api dryprompt; DRY_PROMPT_API="$API_URL_OUT"
  CASE_ENV=(SHIM_CONFIG_PROJECT= SHIM_PROJECTS= SHIM_BILLING=False "SHIM_ACCOUNTS=${ONE_ACCOUNT}")
  CASE_ANSWERS='y\ny\n'
  run_case "dry run creates nothing with prompts" --code ABCD-2345 --api "$DRY_PROMPT_API" --dry-run
  expect_status 0
  expect_out "Create one called pingtab-maps-"
  expect_out "[dry run] gcloud projects create"
  expect_out "[dry run] gcloud beta billing projects link"
  expect_out "Dry run: nothing was created, changed, or sent."
  expect_calls 0 "projects create"
  expect_calls 0 "billing projects link"
  expect_calls 0 "config set project"
  expect_posts 0 dryprompt
  check "dry run creates nothing with prompts"
fi

fi  # HAVE_SCRIPT

# ==================================================================== dry run ===

if wanted "dry run code mode changes nothing"; then
  start_api dryrun; DRY_API="$API_URL_OUT"
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "dry run code mode changes nothing" --code ABCD-2345 --api "$DRY_API" --dry-run
  expect_status 0
  expect_out "[dry run] gcloud services enable"
  expect_out "[dry run] gcloud services api-keys create"
  expect_out "[dry run] POST ${DRY_API}/api/maps-setup/ABCD2345/keys"
  expect_out '"server_key": "<server key>"'
  expect_out '"browser_key": "<browser key>"'
  expect_out "Dry run: nothing was created, changed, or sent."
  expect_no_keys
  expect_calls 0 "services enable"
  expect_calls 0 "api-keys create"
  expect_calls 0 "api-keys update"
  expect_calls 0 "get-key-string"
  expect_posts 0 dryrun
  check "dry run code mode changes nothing"
fi

if wanted "dry run still does its reads"; then
  start_api dryreads; DRY2_API="$API_URL_OUT"
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "dry run still does its reads" --code ABCD-2345 --api "$DRY2_API" --dry-run
  expect_status 0
  expect_calls 1 "config get-value project"
  expect_calls 1 "billing projects describe"
  expect_calls 2 "api-keys list"
  expect_out "Setting up Google Maps for Pepper Kerala Cabs."
  check "dry run still does its reads"
fi

if wanted "dry run manual mode changes nothing"; then
  CASE_ENV=(SHIM_CONFIG_PROJECT=pepper-cabs-01 SHIM_BILLING=True)
  run_case "dry run manual mode changes nothing" --allowed-referrers 'https://x.example/*' --dry-run
  expect_status 0
  expect_out "Dry run: nothing was created, changed, or sent."
  expect_no_keys
  expect_calls 0 "api-keys create"
  expect_calls 0 "get-key-string"
  check "dry run manual mode changes nothing"
fi

# ============================================================ argument guards ===

for flag in --code --api --project --allowed-ips --allowed-referrers; do
  name="guard ${flag} needs a value"
  wanted "$name" || continue
  run_case "$name" "$flag"
  expect_status 1
  expect_out "${flag} needs a value"
  check "$name"
done

if wanted "guard no arguments"; then
  run_case "guard no arguments"
  expect_status 1
  expect_out "Paste the whole command from the PingTab screen"
  check "guard no arguments"
fi

if wanted "guard unknown flag"; then
  run_case "guard unknown flag" --nonsense
  expect_status 1
  expect_out "Do not know what"
  check "guard unknown flag"
fi

if wanted "guard code and manual flags are exclusive"; then
  run_case "guard code and manual flags are exclusive" --code ABCD-2345 --allowed-ips 1.2.3.4
  expect_status 1
  expect_out "Use the setup code on its own"
  check "guard code and manual flags are exclusive"
fi

for ph in XXXX-XXXX PASTE_CODE_HERE; do
  name="guard placeholder ${ph}"
  wanted "$name" || continue
  run_case "$name" --code "$ph"
  expect_status 1
  expect_out "That is the example text"
  check "$name"
done

if wanted "guard placeholder PASTE_IPS_HERE"; then
  run_case "guard placeholder PASTE_IPS_HERE" --allowed-ips PASTE_IPS_HERE
  expect_status 1
  expect_out "That is the example text"
  check "guard placeholder PASTE_IPS_HERE"
fi

if wanted "guard api must be https"; then
  run_case "guard api must be https" --code ABCD-2345 --api http://api.example.com
  expect_status 1
  expect_out "has to start with https://"
  check "guard api must be https"
fi

for bad in NOPE ABC0-O345 ABCD-23456; do
  name="guard malformed code ${bad}"
  wanted "$name" || continue
  run_case "$name" --code "$bad" --api "$OK_API"
  expect_status 1
  expect_out "does not look right"
  check "$name"
done

# ==================================================================== summary ===

echo
printf '%d passed' "$PASSED"
(( FAILED  > 0 )) && printf ', %d failed' "$FAILED"
(( SKIPPED > 0 )) && printf ', %d skipped' "$SKIPPED"
printf '\n'

if (( FAILED > 0 )); then
  echo
  echo "Failed:"
  for n in "${FAILED_NAMES[@]}"; do echo "  ${n}"; done
  exit 1
fi
exit 0
