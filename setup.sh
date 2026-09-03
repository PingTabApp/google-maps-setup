#!/usr/bin/env bash
#
# Creates the Google Maps API keys PingTab needs, in the caller's own project.
#
# Two keys are created, because a Google API key carries exactly one application
# restriction type — a single key cannot serve both a browser and a server:
#
#   PingTab Routes (server)   IP-restricted     Routes API
#   PingTab Web (browser)     referrer-restricted   Maps JS, Static Maps, Places (New)
#
# Runs as whoever is authenticated with gcloud — designed for Google Cloud Shell,
# but works in any terminal with the Cloud SDK installed and logged in.
#
#   ./setup.sh --allowed-ips 203.0.113.10 --allowed-referrers 'https://app.pingtab.com/*'
#
set -euo pipefail

SERVER_NAME="PingTab Routes (server)"
BROWSER_NAME="PingTab Web (browser)"

SERVER_APIS=(routes.googleapis.com)
BROWSER_APIS=(maps-backend.googleapis.com static-maps-backend.googleapis.com places.googleapis.com)

ALLOWED_IPS=""
ALLOWED_REFERRERS=""
PROJECT="${GOOGLE_CLOUD_PROJECT:-}"

die()  { printf '\n\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$1"; }

usage() {
  cat <<USAGE
Usage: ./setup.sh [--allowed-ips <IP[,IP...]>] [--allowed-referrers <REF[,REF...]>]
                  [--project <PROJECT_ID>]

  --allowed-ips        Creates the server key, restricted to the Routes API and
                       callable only from these PingTab backend IP addresses.
  --allowed-referrers  Creates the browser key, restricted to Maps JavaScript,
                       Maps Static and Places (New), callable only from these
                       website addresses. Use Google's referrer patterns, e.g.
                       'https://app.pingtab.com/*' or '*.pingtab.com/*'.
  --project            Project to create the keys in. Defaults to
                       \$GOOGLE_CLOUD_PROJECT, then the active gcloud project.

Copy both values from the PingTab setup screen. At least one is required.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allowed-ips)        ALLOWED_IPS="${2:-}"; shift 2 ;;
    --allowed-referrers)  ALLOWED_REFERRERS="${2:-}"; shift 2 ;;
    --project)            PROJECT="${2:-}"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *)                    usage; die "Unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------- preflight ---

command -v gcloud >/dev/null 2>&1 \
  || die "gcloud is not installed. Run this in Google Cloud Shell, or install the Cloud SDK."

[[ -n "$ALLOWED_IPS" || -n "$ALLOWED_REFERRERS" ]] \
  || { usage; die "Pass --allowed-ips, --allowed-referrers, or both."; }

for placeholder in PASTE_IPS_HERE PASTE_REFERRERS_HERE; do
  if [[ "$ALLOWED_IPS" == *"$placeholder"* || "$ALLOWED_REFERRERS" == *"$placeholder"* ]]; then
    die "Placeholder text left in the arguments. Paste the real values from PingTab."
  fi
done

if [[ -z "$PROJECT" ]]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
fi
[[ -n "$PROJECT" && "$PROJECT" != "(unset)" ]] \
  || die "No project selected. Use the project picker in the tutorial, or pass --project."

info "Project: ${PROJECT}"

# ------------------------------------------------------------------ billing ---

info "Checking that billing is enabled..."
BILLING="$(gcloud beta billing projects describe "$PROJECT" \
             --format='value(billingEnabled)' 2>/dev/null || echo "unknown")"

if [[ "$BILLING" != "True" ]]; then
  cat >&2 <<BILLINGMSG

Billing is not enabled on project ${PROJECT} (or your account cannot read its
billing status).

The Maps APIs reject every request without a billing account attached, and no
script can create one for you. Link a billing account here, then re-run:

  https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT}

BILLINGMSG
  die "Billing not enabled."
fi
ok "Billing is enabled."

# -------------------------------------------------------------------- APIs ---

SERVICES=(apikeys.googleapis.com)
[[ -n "$ALLOWED_IPS" ]]       && SERVICES+=("${SERVER_APIS[@]}")
[[ -n "$ALLOWED_REFERRERS" ]] && SERVICES+=("${BROWSER_APIS[@]}")

info "Enabling required APIs (safe to repeat)..."
gcloud services enable "${SERVICES[@]}" --project="$PROJECT"
for s in "${SERVICES[@]}"; do ok "$s"; done

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
    info "\"${display_name}\" already exists — updating its restrictions."
    gcloud services api-keys update "$key_name" \
      --project="$PROJECT" "${target_args[@]}" "${restrict_flag}=${restrict_value}" >/dev/null
  else
    info "Creating \"${display_name}\"..."
    gcloud services api-keys create \
      --project="$PROJECT" --display-name="$display_name" \
      "${target_args[@]}" "${restrict_flag}=${restrict_value}" >/dev/null
    key_name="$(find_key "$display_name")"
    [[ -n "$key_name" ]] || die "Created \"${display_name}\" but could not find it again."
  fi

  KEY_STRING_OUT="$(gcloud services api-keys get-key-string "$key_name" \
                      --project="$PROJECT" --format='value(keyString)')"
  [[ -n "$KEY_STRING_OUT" ]] \
    || die "Could not read the key string for \"${display_name}\". Check your permissions."
  ok "${display_name} ready."
}

SERVER_KEY=""
BROWSER_KEY=""

if [[ -n "$ALLOWED_IPS" ]]; then
  provision_key "$SERVER_NAME" --allowed-ips "$ALLOWED_IPS" "${SERVER_APIS[@]}"
  SERVER_KEY="$KEY_STRING_OUT"
fi

if [[ -n "$ALLOWED_REFERRERS" ]]; then
  provision_key "$BROWSER_NAME" --allowed-referrers "$ALLOWED_REFERRERS" "${BROWSER_APIS[@]}"
  BROWSER_KEY="$KEY_STRING_OUT"
fi

# ------------------------------------------------------------------ output ---

echo
echo "────────────────────────────────────────────────────────────────────────────"
echo "  Paste these into the matching fields on the PingTab setup screen."
echo

if [[ -n "$SERVER_KEY" ]]; then
  echo "  Server key  (field: \"Backend API key\")"
  echo
  echo "    ${SERVER_KEY}"
  echo
  echo "    APIs          : ${SERVER_APIS[*]}"
  echo "    Callable from : ${ALLOWED_IPS}"
  echo
fi

if [[ -n "$BROWSER_KEY" ]]; then
  echo "  Browser key  (field: \"Website API key\")"
  echo
  echo "    ${BROWSER_KEY}"
  echo
  echo "    APIs          : ${BROWSER_APIS[*]}"
  echo "    Callable from : ${ALLOWED_REFERRERS}"
  echo
fi

echo "  Project       : ${PROJECT}"
echo "────────────────────────────────────────────────────────────────────────────"
echo
