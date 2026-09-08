#!/usr/bin/env bash
#
# Creates the Google Maps API keys PingTab needs, in the caller's own project.
#
# Two keys are created, because a Google API key carries exactly one application
# restriction type. A single key cannot serve both a browser and a server:
#
#   PingTab Routes (server)   IP-restricted         Routes API, Places (New)
#   PingTab Web (browser)     referrer-restricted   Maps JS, Static Maps, Places (New)
#
# Runs as whoever is authenticated with gcloud. Designed for Google Cloud Shell,
# but works in any terminal with the Cloud SDK installed and logged in.
#
# Two modes:
#
#   ./setup.sh --code 7F3K-92QX
#       The normal path. Fetches the org's IP/referrer restrictions from the
#       PingTab API using a single-use code, creates the keys, and posts them
#       back. The customer never handles a key string.
#
#   ./setup.sh --allowed-ips 203.0.113.10 --allowed-referrers 'https://app.pingtab.com/*'
#       Manual mode. Prints the keys for the operator to paste by hand. For SDK
#       users and for anyone who would rather not have keys sent automatically.
#
set -euo pipefail

SERVER_NAME="PingTab Routes (server)"
BROWSER_NAME="PingTab Web (browser)"

# Places (New) is on the server key as well as the browser key since 2026-09-08:
# the booking site's airport address lookup is proxied through the PingTab
# backend rather than calling Google from the guest's browser, so the
# operator's server key is the one that pays for it.
SERVER_APIS=(routes.googleapis.com places.googleapis.com)
BROWSER_APIS=(maps-backend.googleapis.com static-maps-backend.googleapis.com places.googleapis.com)

ALLOWED_IPS=""
ALLOWED_REFERRERS=""
PROJECT=""
CODE=""
API_BASE="https://api.pingtab.com"
ORG_NAME=""

PROJECT_IS_NEW=0
BILLING_JUST_LINKED=0

CONSOLE_NEW_PROJECT="https://console.cloud.google.com/projectcreate"

die()  { printf '\n\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$1"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$1" >&2; }

# ------------------------------------------------------------------ asking ---

# Seconds to wait before the one enable retry. A constant on purpose: nothing in
# the environment gets to change how this script behaves.
RETRY_WAIT=10

# A prompt is only offered when there is a real terminal to answer it. No
# override: a script or a pipe must never be talked into answering yes.
is_interactive() { [[ -t 0 ]]; }

# ---------------------------------------------------------------- dry run ---

# Everything that changes the customer's Google project, or sends their keys
# anywhere, goes through run_or_print. Reads are left alone: they are safe to
# repeat and their answers are what make the walkthrough decide anything. The
# single exception is get-key-string, a read that hands back a secret, which
# dry run skips and says so rather than printing a key nobody asked for.
#
# One gate, so --dry-run cannot miss a call by omission. Adding a mutating
# gcloud command without routing it through here is the bug to watch for.
DRY_RUN=0

quote_cmd() {
  local a out=()
  for a in "$@"; do out+=("$(printf '%q' "$a")"); done
  printf '%s' "${out[*]}"
}

dry_note() { printf '\033[35m  [dry run]\033[0m %s\n' "$1"; }

run_or_print() {
  if [[ "$DRY_RUN" == "1" ]]; then
    dry_note "$(quote_cmd "$@")"
    return 0
  fi
  "$@" >/dev/null
}

# ask_yes_no <question>: true only on an explicit yes. Everything else, a bare
# Enter included, is No. These prompts spend the customer's money or create
# things in their Google account, so the safe answer has to be the default one.
ask_yes_no() {
  local reply=""
  printf '\n%s ' "$1"
  read -r reply || reply=""
  echo
  [[ "$reply" == [Yy] || "$reply" == [Yy][Ee][Ss] ]]
}

# Google's project id rules: 6 to 30 characters, lowercase letters, digits and
# hyphens, must start with a letter. The "pingtab-maps-" prefix satisfies the
# first-character rule, so the suffix only has to stay inside the alphabet, and
# hex from urandom does.
new_project_id() {
  local suffix=""
  # The "|| suffix=''" matters: without it a failure here would abort the script
  # under errexit instead of falling through to the RANDOM path below.
  suffix="$(od -An -tx1 -N4 /dev/urandom 2>/dev/null | tr -dc 'a-f0-9' | cut -c1-6)" || suffix=""
  if [[ "${#suffix}" -ne 6 ]]; then
    suffix="$(printf '%02x%02x%02x' "$((RANDOM % 256))" "$((RANDOM % 256))" "$((RANDOM % 256))")"
  fi
  printf 'pingtab-maps-%s' "$suffix"
}

usage() {
  cat <<USAGE
Usage: ./setup.sh --code <XXXX-XXXX> [--api <URL>] [--project <PROJECT_ID>]
       ./setup.sh [--allowed-ips <IP[,IP...]>] [--allowed-referrers <REF[,REF...]>]
                  [--project <PROJECT_ID>]

  --code               The setup code shown on the PingTab settings screen. The
                       script reads what it needs from PingTab, creates the keys
                       and sends them back. Nothing to copy by hand.
  --api                PingTab API address. Defaults to ${API_BASE}. PingTab
                       shows this on the screen when it is anything else.
  --project            Google Cloud project to create the keys in. Defaults to
                       the project chosen in the panel above the terminal.

  --allowed-ips        Manual mode. Creates the server key, callable only from
                       these PingTab addresses, and prints it.
  --allowed-referrers  Manual mode. Creates the browser key, callable only from
                       these website addresses, and prints it.

  --dry-run            Works with either mode. Runs every read for real, and
                       prints every step that would change something instead of
                       doing it. Nothing is created, changed or sent.

Use --code, or the two manual options. Not both.
USAGE
}

# need_value <flag> <example> <count-of-remaining-args>
# Without this a trailing "--code" runs into bash's own "shift: 2: shift count
# out of range", which under set -e is the last thing the customer sees.
need_value() {
  [[ "$3" -ge 2 ]] || die "$1 needs a value, like $1 $2"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --code)               need_value --code ABCD-2345 $#;            CODE="$2"; shift 2 ;;
    --api)                need_value --api https://api.pingtab.com $#; API_BASE="$2"; shift 2 ;;
    --allowed-ips)        need_value --allowed-ips 203.0.113.10 $#;  ALLOWED_IPS="$2"; shift 2 ;;
    --allowed-referrers)  need_value --allowed-referrers "'https://app.pingtab.com/*'" $#
                          ALLOWED_REFERRERS="$2"; shift 2 ;;
    --project)            need_value --project my-project-id $#;     PROJECT="$2"; shift 2 ;;
    --dry-run)            DRY_RUN=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    usage; die "Do not know what \"$1\" means." ;;
  esac
done

# ---------------------------------------------------------------- preflight ---

command -v gcloud >/dev/null 2>&1 \
  || die "This needs to run in Google Cloud Shell. Open the link on the PingTab screen."

if [[ -n "$CODE" && ( -n "$ALLOWED_IPS" || -n "$ALLOWED_REFERRERS" ) ]]; then
  usage
  die "Use the setup code on its own. Drop the other options."
fi

if [[ -z "$CODE" && -z "$ALLOWED_IPS" && -z "$ALLOWED_REFERRERS" ]]; then
  usage
  die "Paste the whole command from the PingTab screen, including the setup code."
fi

# Placeholders the tutorial and the settings screen show as examples. Catching
# them here saves a confusing round trip to the API.
for placeholder in PASTE_IPS_HERE PASTE_REFERRERS_HERE PASTE_CODE_HERE XXXX-XXXX; do
  if [[ "$ALLOWED_IPS" == *"$placeholder"* \
     || "$ALLOWED_REFERRERS" == *"$placeholder"* \
     || "$CODE" == *"$placeholder"* ]]; then
    die "That is the example text, not your own. Copy the command from the PingTab screen."
  fi
done

# ------------------------------------------------------- code mode: fetch ---

# Normalised form sent to the API: uppercase, no dash, no spaces. The backend
# accepts either form; normalising here keeps the URL free of anything that
# would need escaping.
CODE_URL=""
if [[ -n "$CODE" ]]; then
  command -v curl >/dev/null 2>&1 \
    || die "This needs to run in Google Cloud Shell. Open the link on the PingTab screen."
  command -v python3 >/dev/null 2>&1 \
    || die "This needs to run in Google Cloud Shell. Open the link on the PingTab screen."

  API_BASE="${API_BASE%/}"
  # Keys travel over this connection, so plain http is refused everywhere except
  # a developer's own machine.
  case "$API_BASE" in
    https://*) ;;
    http://localhost|http://localhost:*|http://localhost/*) ;;
    http://127.0.0.1|http://127.0.0.1:*|http://127.0.0.1/*) ;;
    *) die "The PingTab address has to start with https://. Copy the command from the PingTab screen again." ;;
  esac

  # The alphabet drops 0/O and 1/I, so a mistyped code is caught here with a
  # useful message instead of coming back as an indistinguishable 404. Keep in
  # step with the minting alphabet in the backend if it ever changes.
  CODE_URL="$(printf '%s' "$CODE" | tr -d ' \t-' | tr '[:lower:]' '[:upper:]')"
  [[ "$CODE_URL" =~ ^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$ ]] \
    || die "That setup code does not look right. It is 8 characters, like ABCD-2345. Copy the command from the PingTab screen again."
fi

# api_call <method> [body-on-stdin]
# Sets API_STATUS and API_BODY.
#
# The key strings are deliberately kept out of argv: the request body is fed in
# on stdin, so another user on the machine cannot lift a key out of the process
# list. The code is a different matter and is NOT hidden. It arrives in argv
# because the customer pastes it there, and it goes into the request URL, so it
# lands in PingTab's access logs too. That is the accepted trade for a one-line
# paste: the code lives 60 minutes, is consumed on first full success, is scoped
# to one organization and to writing that organization's two Maps keys, and the
# only thing it can read back is the IP and referrer list any org viewer can
# already see on the settings screen. It is not worth protecting like a key.
API_STATUS=""
API_BODY=""
api_call() {
  local method="$1" url="$2" tmp rc
  tmp="$(mktemp)"
  API_STATUS=""
  API_BODY=""
  set +e
  if [[ "$method" == "POST" ]]; then
    API_STATUS="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 60 \
      -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
      --data-binary @- "$url" 2>/dev/null)"
  else
    API_STATUS="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 60 \
      -H 'Accept: application/json' "$url" 2>/dev/null)"
  fi
  rc=$?
  set -e
  API_BODY="$(cat "$tmp")"
  rm -f "$tmp"
  [[ $rc -eq 0 ]] || API_STATUS=""
  return 0
}

# Reads "detail" out of an error body. Returns empty when the body is not the
# JSON we expect (a proxy error page, say).
api_detail() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict) and isinstance(d.get("detail"), str):
    sys.stdout.write(d["detail"])
' 2>/dev/null || true
}

if [[ -n "$CODE" ]]; then
  info "Reading your PingTab settings..."
  api_call GET "${API_BASE}/api/maps-setup/${CODE_URL}"

  if [[ -z "$API_STATUS" ]]; then
    # No code and no URL in this message. Not because the code is secret (it is
    # already in argv and in the URL we just called) but because neither means
    # anything to the operator reading it, and a support screenshot is more
    # useful without them.
    die "Could not reach PingTab. Check the internet connection and paste the command again."
  fi

  if [[ "$API_STATUS" == "404" ]]; then
    detail="$(api_detail "$API_BODY")"
    die "${detail:-This code is not valid or has expired. Go back to the PingTab settings screen and click Set up again.}"
  fi

  [[ "$API_STATUS" == "200" ]] \
    || die "PingTab could not answer just now. Wait a moment and paste the command again."

  eval "$(printf '%s' "$API_BODY" | python3 -c '
import json, shlex, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = None
if not isinstance(d, dict):
    print("CONFIG_OK=0")
    sys.exit(0)

def joined(value):
    if not isinstance(value, list):
        return ""
    return ",".join(str(v) for v in value if isinstance(v, str) and v.strip())

print("CONFIG_OK=1")
print("ORG_NAME=" + shlex.quote(str(d.get("organization_name") or "")))
print("ALLOWED_IPS=" + shlex.quote(joined(d.get("allowed_ips"))))
print("ALLOWED_REFERRERS=" + shlex.quote(joined(d.get("allowed_referrers"))))
' 2>/dev/null || echo 'CONFIG_OK=0')"

  [[ "${CONFIG_OK:-0}" == "1" ]] \
    || die "PingTab sent back something this script did not understand. Try again in a minute."

  [[ -n "$ALLOWED_IPS" || -n "$ALLOWED_REFERRERS" ]] \
    || die "PingTab did not send any addresses to lock the keys to. Contact PingTab support."

  if [[ -n "$ORG_NAME" ]]; then
    ok "Setting up Google Maps for ${ORG_NAME}."
  else
    ok "Setup code accepted."
  fi
fi

# ----------------------------------------------------------------- project ---

# Order matters. The project picker in the panel writes to the gcloud config,
# while GOOGLE_CLOUD_PROJECT is fixed when the shell starts. Reading the config
# first is what makes a tab opened before the pick still do the right thing.
if [[ -z "$PROJECT" ]]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
  PROJECT="${GOOGLE_CLOUD_PROJECT:-}"
fi

if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
  PROJECT=""
  # "No projects" and "could not ask" look identical in the output of this
  # command, and they need opposite responses: one is an offer to create a
  # project, the other must never create anything. Keep the status separate.
  PROJECT_LIST=""
  PROJECT_LIST_RC=0
  PROJECT_LIST="$(gcloud projects list --format='value(projectId)' 2>/dev/null)" || PROJECT_LIST_RC=$?
  if [[ "$PROJECT_LIST_RC" != "0" ]]; then
    die "Could not read your Google Cloud projects. Check you are signed in, then paste the command again."
  fi
  PROJECT_COUNT="$(printf '%s' "$PROJECT_LIST" | grep -c . || true)"

  if [[ "$PROJECT_COUNT" == "1" ]]; then
    PROJECT="$(printf '%s' "$PROJECT_LIST" | head -n1)"
    info "Using your only Google Cloud project: ${PROJECT}"
  elif [[ "$PROJECT_COUNT" == "0" ]]; then
    if ! is_interactive; then
      # Piped or scripted: there is nobody to answer the question, so say what
      # the offer would have been rather than silently skipping it.
      cat >&2 <<NOPROJECTQUIET

You do not have a Google Cloud project yet.

Run this again in a terminal and it will offer to make one for you. Or create
one here, come back to this tab and paste the command again:

  ${CONSOLE_NEW_PROJECT}

NOPROJECTQUIET
      die "No Google Cloud project to put the keys in."
    fi

    NEW_PROJECT_ID="$(new_project_id)"
    if ! ask_yes_no "You have no Google Cloud project yet. Create one called ${NEW_PROJECT_ID} now? [y/N]"; then
      cat >&2 <<NOPROJECT

No problem. Create one here, come back to this tab and paste the command again:

  ${CONSOLE_NEW_PROJECT}

NOPROJECT
      die "No Google Cloud project to put the keys in."
    fi

    info "Creating ${NEW_PROJECT_ID}..."
    if ! run_or_print gcloud projects create "$NEW_PROJECT_ID" --name="PingTab Maps" 2>/dev/null; then
      # Two common causes, neither fixable from here: a Workspace policy that
      # requires every project to sit under a named folder or organization, and
      # an account that has hit its project quota.
      cat >&2 <<CREATEFAIL

Google would not let this script create a project for you.

That usually means your organization requires new projects to be made a certain
way, or your account has as many projects as it is allowed. Create one here,
come back to this tab and paste the command again:

  ${CONSOLE_NEW_PROJECT}

CREATEFAIL
      die "Could not create a Google Cloud project."
    fi

    PROJECT="$NEW_PROJECT_ID"
    PROJECT_IS_NEW=1
    if [[ "$DRY_RUN" == "1" ]]; then
      dry_note "Would have created ${PROJECT}. Carrying on as if it exists."
    else
      ok "Created ${PROJECT}."
    fi

    # Write it to the gcloud config so the panel's project picker and any later
    # run of this script agree with what we just made. If this fails the project
    # exists but nothing else knows about it, so stop rather than carry on with
    # a project the next run will not find.
    if ! run_or_print gcloud config set project "$PROJECT" 2>/dev/null; then
      cat >&2 <<SELECTFAIL

Created ${PROJECT} but could not select it.

Run this, then paste the command again:

  gcloud config set project ${PROJECT}

SELECTFAIL
      die "Could not select the new project."
    fi
  else
    cat >&2 <<MANYPROJECTS

You have more than one Google Cloud project. Pick the one to use in the panel
above this terminal, then paste the command again.

Your projects:

MANYPROJECTS
    printf '%s\n' "$PROJECT_LIST" | sed 's/^/  /' >&2
    echo >&2
    die "Choose a project first."
  fi
fi

info "Project: ${PROJECT}"

# ------------------------------------------------------------------ billing ---

# Reading this needs roles/billing.viewer on the *billing account*, which plenty
# of people who can otherwise create keys in a project do not have. So only an
# explicit "False" stops the run: an unreadable status is a permission we lack,
# not a billing account the customer lacks, and blocking on it would turn a
# helpful precheck into a wall in front of a project that was configured fine.
info "Checking that billing is switched on..."
BILLING="unknown"
if BILLING_STATUS="$(gcloud beta billing projects describe "$PROJECT" \
                       --format='value(billingEnabled)' 2>/dev/null)"; then
  BILLING="${BILLING_STATUS:-unknown}"
fi

billing_console_link() {
  printf '  https://console.cloud.google.com/billing/linkedaccount?project=%s\n' "$PROJECT"
}

no_billing_message() {
  cat >&2 <<BILLINGMSG

Google needs a billing account on project ${PROJECT} before it will serve maps.
No script can create a billing account for you. Add one here, then paste the
command again:

$(billing_console_link)

BILLINGMSG
}

# Offers to attach one of the customer's existing billing accounts to $PROJECT.
# Returns:
#   0  a billing account is attached now, carry on
#   1  not attached, and the caller should print its own message and stop
#   2  not attached, already explained why, stop without repeating it
#
# Only open accounts are offered: a closed one links happily and then pays for
# nothing. Linking needs roles/billing.user on the account, which is a separate
# grant from anything on the project, so being able to see an account and being
# able to spend on it are genuinely different and a failure here is routine.
offer_billing_link() {
  is_interactive || return 1

  local list count
  list="$(gcloud beta billing accounts list --filter='open=true' \
            --format='value(name,displayName)' 2>/dev/null || true)"
  count="$(printf '%s' "$list" | grep -c . || true)"
  [[ "${count:-0}" -ge 1 ]] || return 1

  local acct_name="" acct_display="" chosen="" line choice n
  if [[ "$count" == "1" ]]; then
    chosen="$(printf '%s' "$list" | head -n1)"
    IFS=$'\t' read -r acct_name acct_display <<<"$chosen"
    echo
    echo "Project ${PROJECT} has no billing account, and you have one."
  else
    echo
    echo "Project ${PROJECT} has no billing account. These are yours:"
    echo
    n=0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      n=$((n + 1))
      printf '  %d  %s\n' "$n" "$(printf '%s' "$line" | cut -f2-)"
    done <<<"$list"
    echo
    printf 'Which one? Enter a number, or press Enter to stop. '
    read -r choice || choice=""
    echo
    # Capped at three digits before the base-10 conversion, so a long paste
    # cannot become a huge arithmetic expression, and "08" is eight rather than
    # a bad octal literal.
    [[ "$choice" =~ ^[0-9]{1,3}$ ]] || return 1
    choice=$((10#$choice))
    [[ "$choice" -ge 1 && "$choice" -le "$n" ]] || return 1
    chosen="$(printf '%s' "$list" | sed -n "${choice}p")"
    IFS=$'\t' read -r acct_name acct_display <<<"$chosen"
  fi

  # Picking a number off a list is navigation, not consent. Both paths end at
  # the same explicit question, because both end in the customer's money.
  ask_yes_no "Link ${PROJECT} to \"${acct_display}\" now? Google Maps usage from PingTab will then be billed to that account. [y/N]" \
    || return 1

  # The list gives the resource path, the link flag wants the bare id.
  local acct_id="${acct_name#billingAccounts/}"
  info "Linking ${PROJECT} to \"${acct_display}\"..."
  if run_or_print gcloud beta billing projects link "$PROJECT" \
       --billing-account="$acct_id" 2>/dev/null; then
    if [[ "$DRY_RUN" == "0" ]]; then
      ok "Linked. Google Maps usage will be billed to \"${acct_display}\"."
    fi
    return 0
  fi

  cat >&2 <<LINKFAIL

Google would not link "${acct_display}" to ${PROJECT}.

Usually that means your Google account can see that billing account but is not
allowed to spend on it. Ask whoever manages it to link the project, or do it
here, then paste the command again:

$(billing_console_link)

LINKFAIL
  return 2
}

case "$BILLING" in
  True)
    ok "Billing is switched on."
    ;;
  False)
    LINK_RC=0
    offer_billing_link || LINK_RC=$?
    case "$LINK_RC" in
      0) BILLING="True"; BILLING_JUST_LINKED=1 ;;
      2) die "No billing account on this project." ;;
      *) no_billing_message; die "No billing account on this project." ;;
    esac
    ;;
  *)
    warn "Could not check the billing status. Carrying on."
    ;;
esac

# -------------------------------------------------------------------- APIs ---

SERVICES=(apikeys.googleapis.com)
if [[ -n "$ALLOWED_IPS" ]];       then SERVICES+=("${SERVER_APIS[@]}"); fi
if [[ -n "$ALLOWED_REFERRERS" ]]; then SERVICES+=("${BROWSER_APIS[@]}"); fi

# Keeps Google's own words in ENABLE_STDERR. We never show them to the customer,
# but they are the only reliable way to tell a missing billing account from a
# missing permission, and those two need opposite responses.
ENABLE_STDERR=""
enable_services() {
  local err_file rc=0
  if [[ "$DRY_RUN" == "1" ]]; then
    run_or_print gcloud services enable "${SERVICES[@]}" --project="$PROJECT"
    ENABLE_STDERR=""
    return 0
  fi
  err_file="$(mktemp)"
  gcloud services enable "${SERVICES[@]}" --project="$PROJECT" >/dev/null 2>"$err_file" || rc=$?
  ENABLE_STDERR="$(cat "$err_file")"
  rm -f "$err_file"
  return "$rc"
}

# True only when Google's refusal actually names billing. Anything else, an
# unreadable billing status included, must not lead to a link offer: relinking a
# project that already has a billing account is not ours to do on a guess.
enable_failed_on_billing() {
  printf '%s' "$ENABLE_STDERR" | grep -qi 'billing'
}

# This is where a project with no billing account actually stops: Google refuses
# to activate the Maps services without one, in a message that never says the
# word "billing" near the top. Catching it here is what lets the precheck above
# be permissive. The wall is at this line, and at this line we can name it.
info "Switching on the Google Maps services (safe to repeat)..."
ENABLE_OK=0
if enable_services; then ENABLE_OK=1; fi

# A project created seconds ago, or a billing account attached seconds ago, has
# not finished propagating inside Google, and until it does this call fails with
# an error that looks exactly like a real misconfiguration. One retry costs ten
# seconds and saves a support conversation.
if [[ "$ENABLE_OK" == "0" && ( "$PROJECT_IS_NEW" == "1" || "$BILLING_JUST_LINKED" == "1" ) ]]; then
  info "Google is still finishing that off. Waiting a few seconds, then trying once more..."
  sleep "$RETRY_WAIT"
  if enable_services; then ENABLE_OK=1; fi
fi

# Offer the link only where billing is genuinely the problem: the precheck read
# an explicit False, or Google's refusal says the word itself. BILLING=="False"
# cannot normally reach here, since that branch either linked or stopped, but it
# is the condition we mean and it costs nothing to say so.
if [[ "$ENABLE_OK" == "0" ]] && { [[ "$BILLING" == "False" ]] || enable_failed_on_billing; }; then
  info "Google says this project has no billing account."
  LINK_RC=0
  offer_billing_link || LINK_RC=$?
  if [[ "$LINK_RC" == "0" ]]; then
    BILLING_JUST_LINKED=1
    info "Trying the Google Maps services again..."
    sleep "$RETRY_WAIT"
    if enable_services; then ENABLE_OK=1; fi
  elif [[ "$LINK_RC" == "2" ]]; then
    die "Could not switch on the Google Maps services."
  fi
fi

if [[ "$ENABLE_OK" == "0" ]]; then
  if [[ "$BILLING" == "False" ]] || enable_failed_on_billing; then
    cat >&2 <<ENABLEBILLING

Could not switch on the Google Maps services for project ${PROJECT}.

Google will not serve maps without a billing account on the project, and no
script can create a billing account for you. Add one here, then paste the
command again:

$(billing_console_link)

ENABLEBILLING
  else
    # Deliberately says nothing about billing: we have no evidence for it, and
    # sending someone to the billing page over a permissions problem wastes an
    # afternoon.
    cat >&2 <<ENABLEOTHER

Could not switch on the Google Maps services for project ${PROJECT}.

Ask whoever manages this Google Cloud project to run this setup, or to give you
permission to switch on APIs and create API keys. You can see what the project
has switched on here:

  https://console.cloud.google.com/apis/dashboard?project=${PROJECT}

ENABLEOTHER
  fi
  die "Could not switch on the Google Maps services."
fi
if [[ "$DRY_RUN" == "1" ]]; then
  dry_note "Would have switched on the Google Maps services."
else
  ok "Google Maps services are on."
fi

# -------------------------------------------------------------------- keys ---

find_key() {
  gcloud services api-keys list \
    --project="$PROJECT" \
    --filter="displayName=\"$1\"" \
    --format='value(name)' --limit=1 2>/dev/null || true
}

# provision_key <display-name> <restriction-flag> <restriction-value> <api>...
# Sets KEY_STRING_OUT to the resulting key string.
KEY_STRING_OUT=""
provision_key() {
  local display_name="$1" restrict_flag="$2" restrict_value="$3"
  shift 3
  local api target_args=()
  for api in "$@"; do target_args+=( "--api-target=service=${api}" ); done

  local key_name
  key_name="$(find_key "$display_name")"

  if [[ -n "$key_name" ]]; then
    info "\"${display_name}\" is already there, updating it."
    run_or_print gcloud services api-keys update "$key_name" \
      --project="$PROJECT" "${target_args[@]}" "${restrict_flag}=${restrict_value}"
  else
    info "Creating \"${display_name}\"..."
    run_or_print gcloud services api-keys create \
      --project="$PROJECT" --display-name="$display_name" \
      "${target_args[@]}" "${restrict_flag}=${restrict_value}"
    if [[ "$DRY_RUN" == "0" ]]; then
      key_name="$(find_key "$display_name")"
      [[ -n "$key_name" ]] || die "Made \"${display_name}\" but could not find it again. Paste the command again."
    fi
  fi

  # get-key-string is a read, so dry run could technically make it. It is the
  # one read that hands back a secret, and printing a live key during a
  # rehearsal is exactly the accident this flag exists to avoid.
  if [[ "$DRY_RUN" == "1" ]]; then
    KEY_STRING_OUT="$DRY_KEY_PLACEHOLDER"
    dry_note "Skipping the read of the key itself. That would print a real secret."
    return 0
  fi

  KEY_STRING_OUT="$(gcloud services api-keys get-key-string "$key_name" \
                      --project="$PROJECT" --format='value(keyString)')"
  [[ -n "$KEY_STRING_OUT" ]] \
    || die "Could not read \"${display_name}\". Your Google account may not be allowed to. Ask whoever owns this project to run this."
  ok "${display_name} is ready."
}

SERVER_KEY=""
BROWSER_KEY=""
DRY_KEY_PLACEHOLDER="<key not read>"

if [[ -n "$ALLOWED_IPS" ]]; then
  provision_key "$SERVER_NAME" --allowed-ips "$ALLOWED_IPS" "${SERVER_APIS[@]}"
  SERVER_KEY="$KEY_STRING_OUT"
fi

if [[ -n "$ALLOWED_REFERRERS" ]]; then
  provision_key "$BROWSER_NAME" --allowed-referrers "$ALLOWED_REFERRERS" "${BROWSER_APIS[@]}"
  BROWSER_KEY="$KEY_STRING_OUT"
fi

# ------------------------------------------------------------------ output ---

print_keys_for_manual_paste() {
  echo
  echo "────────────────────────────────────────────────────────────────────────────"
  echo "  Paste these into the matching fields on the PingTab setup screen."
  echo

  if [[ -n "$SERVER_KEY" ]]; then
    echo "  Server key  (field: \"Backend API key\")"
    echo
    echo "    ${SERVER_KEY}"
    echo
    echo "    Callable only from : ${ALLOWED_IPS}"
    echo
  fi

  if [[ -n "$BROWSER_KEY" ]]; then
    echo "  Browser key  (field: \"Website API key\")"
    echo
    echo "    ${BROWSER_KEY}"
    echo
    echo "    Callable only from : ${ALLOWED_REFERRERS}"
    echo
  fi

  echo "  Project       : ${PROJECT}"
  echo "────────────────────────────────────────────────────────────────────────────"
  echo
}

dry_run_summary() {
  echo
  echo "────────────────────────────────────────────────────────────────────────────"
  echo "  Dry run: nothing was created, changed, or sent."
  echo "────────────────────────────────────────────────────────────────────────────"
  echo
}

if [[ -z "$CODE" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    dry_run_summary
    exit 0
  fi
  print_keys_for_manual_paste
  exit 0
fi

# ------------------------------------------------------- code mode: send ---

if [[ "$DRY_RUN" == "1" ]]; then
  # Shows the shape of the request without ever holding a key to put in it.
  DRY_BODY=""
  if [[ -n "$ALLOWED_IPS" ]];       then DRY_BODY+='"server_key": "<server key>", '; fi
  if [[ -n "$ALLOWED_REFERRERS" ]]; then DRY_BODY+='"browser_key": "<browser key>", '; fi
  DRY_BODY+="\"project_id\": \"${PROJECT}\""

  info "Sending the keys to PingTab..."
  dry_note "POST ${API_BASE}/api/maps-setup/${CODE_URL}/keys"
  dry_note "{${DRY_BODY}}"
  dry_run_summary
  exit 0
fi

info "Sending the keys to PingTab..."

# Keys go in on stdin, never in argv, and never through a temporary file.
POST_BODY="$(PT_SERVER_KEY="$SERVER_KEY" PT_BROWSER_KEY="$BROWSER_KEY" PT_PROJECT="$PROJECT" \
  python3 -c '
import json, os
body = {}
if os.environ.get("PT_SERVER_KEY"):
    body["server_key"] = os.environ["PT_SERVER_KEY"]
if os.environ.get("PT_BROWSER_KEY"):
    body["browser_key"] = os.environ["PT_BROWSER_KEY"]
if os.environ.get("PT_PROJECT"):
    body["project_id"] = os.environ["PT_PROJECT"][:100]
print(json.dumps(body))
')"

# A here-string, not a pipe: a piped function would run in a subshell and its
# API_STATUS / API_BODY would never come back.
api_call POST "${API_BASE}/api/maps-setup/${CODE_URL}/keys" <<<"$POST_BODY"

if [[ "$API_STATUS" != "200" ]]; then
  # The keys exist in the customer's project either way, so the work is never
  # lost: fall back to the manual paste block. A 404 here means the code was
  # used or expired between the two calls, which is worth naming.
  echo >&2
  if [[ "$API_STATUS" == "404" ]]; then
    detail="$(api_detail "$API_BODY")"
    warn "${detail:-This code is not valid any more.}"
  else
    warn "The keys were created, but PingTab did not confirm they arrived."
  fi
  warn "Nothing is lost. Copy them across by hand instead."
  print_keys_for_manual_paste
  exit 0
fi

RESULT_OK=0
SERVER_CLEAR=0
BROWSER_CLEAR=0

eval "$(printf '%s' "$API_BODY" | python3 -c '
import json, shlex, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = None
if not isinstance(d, dict):
    print("RESULT_OK=0")
    sys.exit(0)


def is_clear(part):
    """A section we can honestly report on.

    Strict on purpose. JSON has no schema here, so "saved": "yes" and
    "saved": null are both truthy-ish shapes that would otherwise be read as an
    outcome. Anything short of real booleans means we do not know what happened
    to the key, and not knowing has to look like failure, not success.
    """
    if not isinstance(part, dict):
        return False
    if part.get("sent") is not True:
        return False
    if not isinstance(part.get("saved"), bool):
        return False
    reason = part.get("reason")
    if reason is not None and not isinstance(reason, str):
        return False
    return True


print("RESULT_OK=1")
print("ORG_NAME=" + shlex.quote(str(d.get("organization_name") or "")))
for which in ("server", "browser"):
    part = d.get(which)
    prefix = which.upper()
    print("%s_CLEAR=%s" % (prefix, "1" if is_clear(part) else "0"))
    if not isinstance(part, dict):
        part = {}
    print("%s_SENT=%s" % (prefix, "1" if part.get("sent") is True else "0"))
    print("%s_SAVED=%s" % (prefix, "1" if part.get("saved") is True else "0"))
    reason = part.get("reason")
    print("%s_REASON=%s" % (prefix, shlex.quote(reason if isinstance(reason, str) else "")))
' 2>/dev/null || echo 'RESULT_OK=0')"

# A 200 whose body we cannot read, or which does not report a proper outcome for
# a key we sent, is no better than a failed POST: we do not know whether the key
# landed. Treat it the same way and print the keys. Code mode must never end
# without either a per-key outcome or the keys on screen.
POST_UNCLEAR=0
[[ "${RESULT_OK:-0}" == "1" ]] || POST_UNCLEAR=1
if [[ "$POST_UNCLEAR" == "0" ]]; then
  [[ -z "$SERVER_KEY"  || "${SERVER_CLEAR:-0}"  == "1" ]] || POST_UNCLEAR=1
  [[ -z "$BROWSER_KEY" || "${BROWSER_CLEAR:-0}" == "1" ]] || POST_UNCLEAR=1
fi

if [[ "$POST_UNCLEAR" == "1" ]]; then
  echo >&2
  warn "The keys were created, but PingTab did not confirm they arrived."
  warn "Nothing is lost. Copy them across by hand instead."
  print_keys_for_manual_paste
  exit 0
fi

echo
echo "────────────────────────────────────────────────────────────────────────────"
if [[ -n "$ORG_NAME" ]]; then
  echo "  Google Maps setup for ${ORG_NAME}"
else
  echo "  Google Maps setup"
fi
echo

FIX_NEEDED=0

if [[ "${SERVER_SENT:-0}" == "1" ]]; then
  if [[ "${SERVER_SAVED:-0}" == "1" ]]; then
    echo "  Routes and arrival times : saved, and Google confirmed it works."
  else
    FIX_NEEDED=1
    echo "  Routes and arrival times : Google would not accept this key, so it"
    echo "                             was not saved."
    if [[ -n "${SERVER_REASON:-}" ]]; then
      echo "                             Google said: ${SERVER_REASON}"
    fi
  fi
fi

if [[ "${BROWSER_SENT:-0}" == "1" ]]; then
  if [[ "${BROWSER_SAVED:-0}" == "1" ]]; then
    echo "  Maps on your website     : saved. Click \"Test this key\" next to it"
    echo "                             on the PingTab screen to see a map load."
  else
    FIX_NEEDED=1
    echo "  Maps on your website     : not saved."
    if [[ -n "${BROWSER_REASON:-}" ]]; then
      echo "                             Reason: ${BROWSER_REASON}"
    fi
  fi
fi

echo
if [[ "$FIX_NEEDED" == "0" ]]; then
  echo "  Go back to the PingTab tab in your browser."
  echo "────────────────────────────────────────────────────────────────────────────"
  echo
  exit 0
fi

# The backend consumes the code only when every key it was sent was saved, so a
# part-failure leaves the code live and the same paste works again. Anything
# already saved above stays saved: the re-run just overwrites it.
echo "  Whatever says \"saved\" above is done and stays done."
echo "  Your setup code still works. Fix the point above, then paste the same"
echo "  command again to finish the rest."
echo "────────────────────────────────────────────────────────────────────────────"
echo
exit 1
