#!/usr/bin/env bash
#
# Creates a Google Maps Routes API key for PingTab in the caller's own project.
#
# Runs as whoever is authenticated with gcloud — designed for Google Cloud Shell,
# but works in any terminal with the Cloud SDK installed and logged in.
#
#   ./setup.sh --allowed-ips 203.0.113.10,203.0.113.11
#
set -euo pipefail

DISPLAY_NAME="PingTab Routes (server)"
ALLOWED_IPS=""
PROJECT="${GOOGLE_CLOUD_PROJECT:-}"

die()  { printf '\n\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$1"; }

usage() {
  cat <<USAGE
Usage: ./setup.sh --allowed-ips <IP[,IP...]> [--project <PROJECT_ID>] [--display-name <NAME>]

  --allowed-ips   Required. PingTab backend IP addresses allowed to use this key.
                  Copy these from the PingTab setup screen.
  --project       Google Cloud project to create the key in.
                  Defaults to \$GOOGLE_CLOUD_PROJECT, then the active gcloud project.
  --display-name  Name for the key. Default: "${DISPLAY_NAME}"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allowed-ips)   ALLOWED_IPS="${2:-}"; shift 2 ;;
    --project)       PROJECT="${2:-}"; shift 2 ;;
    --display-name)  DISPLAY_NAME="${2:-}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage; die "Unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------- preflight ---

command -v gcloud >/dev/null 2>&1 \
  || die "gcloud is not installed. Run this in Google Cloud Shell, or install the Cloud SDK."

[[ -n "$ALLOWED_IPS" ]] \
  || { usage; die "--allowed-ips is required. Copy the IP addresses from the PingTab setup screen."; }

if [[ "$ALLOWED_IPS" == *"PASTE_IPS_HERE"* ]]; then
  die "--allowed-ips still contains the placeholder. Paste the real IPs from PingTab."
fi

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

The Routes API will reject every request without a billing account attached, and
no script can create one for you. Link a billing account here, then re-run:

  https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT}

BILLINGMSG
  die "Billing not enabled."
fi
ok "Billing is enabled."

# -------------------------------------------------------------------- APIs ---

info "Enabling required APIs (safe to repeat)..."
gcloud services enable routes.googleapis.com apikeys.googleapis.com --project="$PROJECT"
ok "routes.googleapis.com and apikeys.googleapis.com are enabled."

# --------------------------------------------------------------------- key ---

find_key() {
  gcloud services api-keys list \
    --project="$PROJECT" \
    --filter="displayName=\"${DISPLAY_NAME}\"" \
    --format='value(name)' --limit=1 2>/dev/null || true
}

KEY_NAME="$(find_key)"

if [[ -n "$KEY_NAME" ]]; then
  info "A key named \"${DISPLAY_NAME}\" already exists — reusing it."
  info "Updating its restrictions to the IPs you supplied..."
  gcloud services api-keys update "$KEY_NAME" \
    --project="$PROJECT" \
    --api-target=service=routes.googleapis.com \
    --allowed-ips="$ALLOWED_IPS" >/dev/null
  ok "Restrictions updated."
else
  info "Creating key \"${DISPLAY_NAME}\"..."
  gcloud services api-keys create \
    --project="$PROJECT" \
    --display-name="$DISPLAY_NAME" \
    --api-target=service=routes.googleapis.com \
    --allowed-ips="$ALLOWED_IPS" >/dev/null
  KEY_NAME="$(find_key)"
  [[ -n "$KEY_NAME" ]] || die "Key was created but could not be found again. Check the Cloud Console."
  ok "Key created."
fi

KEY_STRING="$(gcloud services api-keys get-key-string "$KEY_NAME" \
                --project="$PROJECT" --format='value(keyString)')"

[[ -n "$KEY_STRING" ]] || die "Could not read the key string. Check your permissions on ${PROJECT}."

# ------------------------------------------------------------------ output ---

cat <<DONE

────────────────────────────────────────────────────────────────────────────
  Copy this key into the "Google Maps API key" field in PingTab:

    ${KEY_STRING}

  Restricted to : routes.googleapis.com
  Callable from : ${ALLOWED_IPS}
  Project       : ${PROJECT}
────────────────────────────────────────────────────────────────────────────

DONE
