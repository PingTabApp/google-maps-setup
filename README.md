# PingTab — Google Maps setup

A [Google Cloud Shell](https://cloud.google.com/shell) walkthrough that lets a PingTab
customer create their **own** Google Maps API keys, in their **own** Google Cloud
project, billed to their **own** account — and hand just those keys back to PingTab.

Everything here runs as the customer, under their Google identity. PingTab never
requests an OAuth scope, never holds a Google credential, and never touches their
project. The only thing that crosses the boundary is two restricted key strings, pasted
by hand.

## Contents

| File | Purpose |
| --- | --- |
| `tutorial.md` | The walkthrough rendered in the Cloud Shell side panel |
| `setup.sh` | Does the actual work; also runnable in any terminal with the Cloud SDK |

## The link PingTab generates

```
https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/PingTabApp/google-maps-setup&cloudshell_git_branch=main&cloudshell_tutorial=tutorial.md&cloudshell_workspace=.&cloudshell_ephemeral=true
```

| Parameter | Why |
| --- | --- |
| `cloudshell_git_repo` | Repo to clone. **Must be public** — Cloud Shell clones it unauthenticated |
| `cloudshell_git_branch=main` | Pins the branch, so work in progress never reaches customers |
| `cloudshell_tutorial=tutorial.md` | File rendered as the step-by-step panel |
| `cloudshell_workspace=.` | Opens at the repo root, so `./setup.sh` resolves |
| `cloudshell_ephemeral=true` | No persistent home disk — nothing of the customer's is retained |

The PingTab setup screen shows this link next to the backend egress IP addresses the
customer needs to paste in, alongside the website referrer patterns for the browser
key. Neither is committed here: they change when the backend or the web domain moves,
and a stale value baked into the tutorial would produce a key that silently fails.

## What the customer ends up with

**Two** keys, not one. A Google API key carries exactly one *application* restriction
type — HTTP referrers, or IP addresses, or Android apps, or iOS bundles, never a
combination. So a browser-facing key and a server-facing key can never be the same key,
regardless of how the API restrictions are set.

| Key | Application restriction | API restriction |
| --- | --- | --- |
| `PingTab Routes (server)` | PingTab backend IPs | `routes.googleapis.com` |
| `PingTab Web (browser)` | customer website referrers | `maps-backend.googleapis.com` (Maps JS), `static-maps-backend.googleapis.com` (Maps Static), `places.googleapis.com` (Places New) |

Note the service names: Maps JavaScript API is `maps-backend`, Maps Static API is
`static-maps-backend`, and Places API (New) is `places.googleapis.com` — the legacy
Places API is `places-backend.googleapis.com` and a different SKU.

Both keys are inert anywhere else, including in the customer's own hands. `setup.sh` is
idempotent: run it again and it updates the existing keys' restrictions rather than
creating duplicates. Passing only one of `--allowed-ips` / `--allowed-referrers`
provisions only that key, and enables only the APIs it needs.

Android and iOS are deliberately **not** covered here. One binary ships to every
customer, so a mobile key cannot be per-customer; mobile Maps usage stays on PingTab's
own project.

## Running it without Cloud Shell

Some organizations disable Cloud Shell by policy. The same script works in any terminal
with an authenticated [Cloud SDK](https://cloud.google.com/sdk/docs/install):

```bash
git clone https://github.com/PingTabApp/google-maps-setup.git
cd google-maps-setup
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
./setup.sh \
  --allowed-ips 203.0.113.10,203.0.113.11 \
  --allowed-referrers 'https://app.pingtab.com/*'
```

## What this does not do

**It cannot create a billing account.** No Google API can. If the customer's project has
no billing account attached, `setup.sh` stops early and links them to the Cloud Console
to fix it. Everything downstream of that is automated.

The precheck only stops on an explicit `False`. Reading billing status needs
`roles/billing.viewer` on the *billing account*, which plenty of people who can
otherwise create keys in a project do not have, so an unreadable status warns and
carries on: it means a permission we lack far more often than a billing account the
customer lacks, and blocking on it would wall off a project that was configured fine.

It also does not verify the keys. PingTab verifies the **server** key itself, with one
Routes call as the operator saves it, and refuses it with Google's own message. The
**browser** key cannot be verified from a server at all: a correctly referrer-restricted
key is supposed to fail there. PingTab stores it and offers a button that tests it from
the settings page, where the referrer is real, and falls back to the shared key at call
time if Google later refuses it.

## Editing the tutorial

`tutorial.md` uses Cloud Shell's walkthrough syntax on top of plain Markdown:

- `#` is the title; each `##` becomes a numbered step in the panel.
- Every ```` ```bash ```` block gets an automatic "copy to Cloud Shell" button.
- `<walkthrough-project-setup>` renders the project picker and sets
  `$GOOGLE_CLOUD_PROJECT`.
- `<walkthrough-enable-apis apis="...">` renders a one-click API enable button.

Customers get whatever is on `main` the moment they click the link, so treat pushes to
`main` as a release. Preview a change before merging by pointing
`cloudshell_git_branch` at your branch.

## Required permissions

The person running the walkthrough needs, on the target project:

- `roles/serviceusage.serviceUsageAdmin` — to enable the APIs
- `roles/serviceusage.apiKeysAdmin` — to create the key and read its key string
- `roles/billing.viewer` on the billing account, for the billing precheck only. Optional:
  without it the precheck warns and carries on, and a project that truly has no billing
  account stops at the API-enable step instead, which says so

Project Owner or Editor covers all three.
