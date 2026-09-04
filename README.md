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
| `test/` | Runs `setup.sh` against a fake gcloud and a fake API. See [`test/README.md`](test/README.md) |

```bash
./test/run.sh
```

No Google account needed, about 35 seconds, 57 cases. Run it before pushing: a push to
`main` here is a release.

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

## Dry run

`--dry-run` works with either mode and is the safe way to see what a real account would
get before touching it:

```bash
./setup.sh --code 7F3K-92QX --dry-run
```

Every **read** runs for real, because the reads are what the script decides on: the project
picker's choice, the project list, billing status, the billing accounts, whether the keys
already exist. Every **write** is printed as the exact command it would have run, prefixed
`[dry run]`, and not executed: `projects create`, `config set project`, `billing projects
link`, `services enable`, `api-keys create` and `update`, and the POST back to PingTab,
whose URL and body shape are printed with the key values replaced by `<server key>` and
`<browser key>`.

Two deliberate exceptions:

- **The GET of the config by code runs for real.** Reading does not consume the code, and
  without it a dry run could not show which restrictions the keys would carry.
- **`get-key-string` is skipped**, though it is technically a read. It is the one read that
  hands back a secret, and printing a live key during a rehearsal is exactly the accident
  this flag exists to prevent. It says so where it would have run.

Prompts still ask, so the questions a customer would face are visible, but a yes only
prints the command. A dry run that gets to the end says "Dry run: nothing was created,
changed, or sent." and exits 0. It stops early, with exit 1, for the same reasons a real
run would: a code the API does not know, a declined prompt, no project and no terminal
to ask in.

Every mutating call goes through one `run_or_print` helper. **A new mutating gcloud
command that does not go through it is a silent dry-run bug**, so route it there and add a
case to `test/run.sh` asserting zero calls of that kind.

The tutorial does not mention this flag. It exists for engineers and for support.

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

## The two prompts

`setup.sh` asks the operator exactly two questions, and only when it hits the matching
dead end. Both **default to No**: a bare Enter, an EOF, or anything that is not `y` /
`yes` declines. Each one creates something in the customer's Google account or moves
money, so consent has to be given rather than assumed, and a mistyped keypress must never
be the thing that opens a billing account.

Both are skipped entirely when stdin is not a terminal. `is_interactive` is exactly
`[[ -t 0 ]]` and **has no override**: nothing in the environment can talk this script into
believing a pipe is a person. A piped or scripted run prints what the offer would have
been and stops, rather than hanging on a `read` nobody will answer. Tests drive the
prompts through a real pseudo-terminal (`script -qfec`), which is the only honest way.

| Prompt | Fires when | Runs |
| --- | --- | --- |
| Create a project called `pingtab-maps-XXXXXX`? | The account owns no projects **and** listing them succeeded | `gcloud projects create <id> --name="PingTab Maps"`, then `gcloud config set project <id>` |
| Link project to `<billing account>`? | Billing read an explicit `False`, or the API enable failed **and Google's error names billing** | `gcloud beta billing accounts list --filter='open=true'`, then `gcloud beta billing projects link <project> --billing-account=<id>` |

A failed `gcloud projects list` is not zero projects. It stops with "Could not read your
Google Cloud projects. Check you are signed in", and never offers to create one: an
account that cannot be listed is not an account we should be making things in.

Likewise the link offer is gated on evidence, not on absence of evidence. An unreadable
billing status plus any enable failure is **not** enough, because relinking a project that
already has a billing account is not ours to do on a guess. `enable_services` captures the
command's stderr into `ENABLE_STDERR` (never shown to the customer, it is gcloud jargon)
and `enable_failed_on_billing` greps it for the word. Without that evidence the failure
message says nothing about billing and points at the API dashboard instead, because
sending someone to the billing page over a permissions problem wastes their afternoon.

The project id is `pingtab-maps-` plus six hex characters from `/dev/urandom`, which
satisfies Google's rule (6 to 30 characters, lowercase letters, digits and hyphens,
starting with a letter). `gcloud config set project` is what keeps a re-run and the Cloud
Shell project picker agreeing with what was just made, so its failure stops the run: the
project exists but nothing else knows about it, and the operator is told the one command
that fixes that.

Only **open** billing accounts are offered: a closed one links happily and pays for
nothing. One account is named in the question. Several are listed and numbered, and the
number chosen is only navigation: the pick is followed by the same explicit
"Link ... now?" question, so no single keystroke ever moves money. Linking needs
`roles/billing.user` on the *account*, a separate grant from anything on the project, so a
customer who can see an account but not spend on it is a normal case and gets a plain
message pointing at the console.

A brand new project and a freshly linked billing account both take a few seconds to
propagate, and until they do `gcloud services enable` fails with an error indistinguishable
from a real misconfiguration. After either event the script waits ten seconds and retries
the enable **once** before treating it as a failure. The wait is a constant, not an
environment variable: no knob in this script is settable by anything but its own author.

The one environment variable the script reads is `GOOGLE_CLOUD_PROJECT`, and only as the
last fallback for *which* project to use, after `--project` and `gcloud config get-value
project`. Cloud Shell sets it to the project selected when the shell opened; it is
Google's variable, not ours, and it never changes what the script does, only where.

## What this does not do

**It cannot create a billing account.** No Google API can, so the offer above can only
attach an account the customer already has. If they have none, or decline, `setup.sh`
stops and links them to the Cloud Console to create one, exactly as before.

The precheck only stops on an explicit `False`. Reading billing status needs
`roles/billing.viewer` on the *billing account*, which plenty of people who can otherwise
create keys in a project do not have, so an unreadable status warns and carries on: it
means a permission we lack far more often than a billing account the customer lacks, and
blocking on it would wall off a project that was configured fine. A project that truly
has no billing account fails at the API-enable step instead, and that is where the link
offer gets made a second time for exactly this reason.

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

The two prompts need more than that, and neither is a project role:

- `roles/resourcemanager.projectCreator` on the organization or folder, to accept the
  create-a-project offer. Accounts outside a Workspace organization have it implicitly
- `roles/billing.user` on the billing account, to accept the link offer. This is the one
  customers most often lack, and declining or failing here is a supported path, not a bug
