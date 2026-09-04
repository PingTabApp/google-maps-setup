# PingTab: Google Maps setup

Internal notes for PingTab engineers. This repo is **public**: Cloud Shell clones it
unauthenticated, and the customer can read every line of it before running it. Treat
pushes to `main` as a release.

A [Google Cloud Shell](https://cloud.google.com/shell) walkthrough that lets a PingTab
customer create their **own** Google Maps API keys, in their **own** Google Cloud
project, billed to their **own** account, and hand just those keys back to PingTab.

## Contents

| File | Purpose |
| --- | --- |
| `tutorial.md` | The walkthrough rendered in the Cloud Shell side panel |
| `setup.sh` | Does the actual work; also runnable in any terminal with the Cloud SDK |

## The flow

The customer never handles an `AIza…` string. Three steps, one paste:

1. On the Maps settings screen in the dashboard they click **Open Google Cloud Shell**.
   The click also mints a single-use setup code in the background, and the screen shows
   the command to paste, with a copy button.
2. Cloud Shell opens on this repo with `tutorial.md` in the side panel. They pick a
   project and paste one line:

   ```
   ./setup.sh --code 7F3K-92QX
   ```

   The dashboard appends ` --api <base>` when its API base is not production, so dev and
   local get the right host without the customer knowing what that means.
3. `setup.sh` reads the restrictions from the API, creates the keys and posts them back.
   The dashboard is polling the code's status and updates itself when they land.

### The two public endpoints

Both live on the unauthenticated router at `/api/maps-setup`. The code is the only
credential.

| Call | Does |
| --- | --- |
| `GET /api/maps-setup/{code}` | Returns `organization_name`, `allowed_ips`, `allowed_referrers`, `expires_at` for a pending code. 404 with a customer-readable `detail` when unknown, used, or expired. Reading does **not** consume the code. |
| `POST /api/maps-setup/{code}/keys` | Body `{server_key?, browser_key?, project_id?}`, at least one key. Verifies and stores the server key, stores the browser key, and returns the per-key outcome: `{organization_name, server: {sent, saved, reason}, browser: {…}}`. Consumes the code **only when every key it was sent was saved**, so a run where Google refused the server key leaves the code live and the same paste works again once the operator has fixed it. |

The code is 8 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, displayed as
`XXXX-XXXX`, valid 60 minutes, single-use once fully redeemed, one live code per
organization. `setup.sh`
normalises it to uppercase without the dash and validates the alphabet locally, so a
mistyped code gets a useful message instead of an indistinguishable 404. If that
alphabet ever changes in the backend, change it here too.

Only the code is scoped: it reveals the egress IPs and referrer patterns any org viewer
can already see on the settings screen, and permits writing the two Maps credentials for
that one organization.

## Trust boundary

Everything runs as the customer, under their Google identity. PingTab never requests an
OAuth scope, never holds a Google credential, and never touches their project.

What crosses the boundary is the two restricted key strings, sent by a public script the
customer can read, over https, to a single-use code scoped to their organization. The
script refuses a non-https `--api` unless it points at localhost.

The **keys** are kept out of `argv`: the request body is fed to curl on stdin, so another
user on the machine cannot lift a key out of the process list.

The **code is not hidden, and should not be read as if it were.** The customer pastes it
on the command line, so it is in `argv`, in their shell history, and in the request URL,
which means it reaches our access logs. That is the deliberate price of a one-line paste,
and it is affordable because of what the code is: it lives 60 minutes, is consumed on the
first fully successful key POST, is scoped to one organization and to writing that
organization's two Maps credentials, and the only thing it reads back is the IP and
referrer list any org viewer can already see on the settings screen. Do not add anything
else to its scope without revisiting this paragraph.

`setup.sh` never prints a key string in code mode, with one exception: any POST that does
not come back with a per-key outcome we can read. The keys exist in the customer's project
by then, so a network failure, a non-200, an unparseable 200, and a 200 that says nothing
about a key we sent all fall back to the manual paste block. Code mode must never end
without either a parsed outcome or the keys on screen.

## Manual mode

```bash
./setup.sh \
  --allowed-ips 203.0.113.10,203.0.113.11 \
  --allowed-referrers 'https://app.pingtab.com/*'
```

Creates the same keys and prints them for the operator to paste into the **Backend API
key** and **Website API key** fields by hand. Nothing is sent anywhere. It is the
fallback for two cases: someone running this in their own terminal with the Cloud SDK
rather than in Cloud Shell, and an operator who would rather not have keys transmitted
automatically. The dashboard keeps the paste rows below the setup card for exactly this.

`--code` and the manual flags are mutually exclusive.

```bash
git clone https://github.com/PingTabApp/google-maps-setup.git
cd google-maps-setup
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
./setup.sh --allowed-ips … --allowed-referrers …
```

## The link PingTab generates

```
https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/PingTabApp/google-maps-setup&cloudshell_git_branch=main&cloudshell_tutorial=tutorial.md&cloudshell_workspace=.&cloudshell_ephemeral=true
```

| Parameter | Why |
| --- | --- |
| `cloudshell_git_repo` | Repo to clone. **Must be public**: Cloud Shell clones it unauthenticated |
| `cloudshell_git_branch=main` | Pins the branch, so work in progress never reaches customers |
| `cloudshell_tutorial=tutorial.md` | File rendered as the step-by-step panel |
| `cloudshell_workspace=.` | Opens at the repo root, so `./setup.sh` resolves |
| `cloudshell_ephemeral=true` | No persistent home disk, so nothing of the customer's is retained |

Preview a tutorial change before merging by pointing `cloudshell_git_branch` at your
branch.

## Why two keys

A Google API key carries exactly one *application* restriction type: HTTP referrers, or
IP addresses, or Android apps, or iOS bundles, never a combination. So a browser-facing
key and a server-facing key can never be the same key, regardless of how the API
restrictions are set.

| Key | Application restriction | API restriction |
| --- | --- | --- |
| `PingTab Routes (server)` | PingTab backend IPs | `routes.googleapis.com` |
| `PingTab Web (browser)` | customer website referrers | `maps-backend.googleapis.com` (Maps JS), `static-maps-backend.googleapis.com` (Maps Static), `places.googleapis.com` (Places New) |

Note the service names: Maps JavaScript API is `maps-backend`, Maps Static API is
`static-maps-backend`, and Places API (New) is `places.googleapis.com`. The legacy Places
API is `places-backend.googleapis.com` and a different SKU.

Both keys are inert anywhere else, including in the customer's own hands. `setup.sh` is
idempotent: run it again and it updates the existing keys' restrictions rather than
creating duplicates. An organization with no egress IPs configured gets only the browser
key, and only the APIs that key needs are switched on.

Android and iOS are deliberately **not** covered here. One binary ships to every
customer, so a mobile key cannot be per-customer; mobile Maps usage stays on PingTab's
own project.

## What this does not do

**It cannot create a billing account.** No Google API can. If the customer's project has
no billing account attached, `setup.sh` stops early and links them to the Cloud Console
to fix it.

The precheck only stops on an explicit `False`. Reading billing status needs
`roles/billing.viewer` on the *billing account*, which plenty of people who can otherwise
create keys in a project do not have, so an unreadable status warns and carries on: it
means a permission we lack far more often than a billing account the customer lacks, and
blocking on it would wall off a project that was configured fine. A project that truly
has no billing account stops at the API-enable step instead, which names billing.

It also does not verify the keys. The backend verifies the **server** key with one Routes
call as it stores it, and reports Google's sanitised message back through the POST
response, which the script prints in plain words. The **browser** key cannot be verified
from a server at all: a correctly referrer-restricted key is supposed to fail there. It
is stored, and the settings page offers a button that tests it from the page itself,
where the referrer is real, falling back to the shared key at call time if Google later
refuses it.

## Customer-facing language

Every string `setup.sh` prints is read by a non-technical taxi operator. No IAM role
names, no Google service names, no gcloud error text, no em dashes. Say "guest", never
"passenger". The technical reasoning belongs in the code comments, where an engineer
will go looking for it.

## Required permissions

The person running the walkthrough needs, on the target project:

- `roles/serviceusage.serviceUsageAdmin` to enable the APIs
- `roles/serviceusage.apiKeysAdmin` to create the key and read its key string
- `roles/billing.viewer` on the billing account, for the billing precheck only. Optional:
  without it the precheck warns and carries on

Project Owner or Editor covers all three.
