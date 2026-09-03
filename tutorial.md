# Connect your own Google Maps billing to PingTab

<walkthrough-tutorial-duration duration="6"></walkthrough-tutorial-duration>

PingTab uses the **Google Routes API** to calculate trip ETAs and planned routes. By
default those calls run on PingTab's shared key. This walkthrough creates a key in
**your own** Google Cloud project instead, so the Maps usage is billed to you and the
quota is yours alone.

Everything below runs as **you**, in **your** project. PingTab never sees your Google
credentials — at the end you copy one key string back into PingTab.

**What you need before starting:**

- A Google Cloud project you can create API keys in (Owner, Editor, or API Keys Admin).
- A **billing account linked to that project**. Google will not serve the Routes API
  without one, and no script can create a billing account for you.
- The **allowed IP addresses** shown on the PingTab setup screen you came from.

Click **Start** to begin.

## Pick the project to use

Choose the Google Cloud project the key should live in. If you want a brand new
project, create one here too.

<walkthrough-project-setup></walkthrough-project-setup>

Confirm Cloud Shell picked it up:

```bash
echo "Project: ${GOOGLE_CLOUD_PROJECT:-<none selected>}"
```

If that prints `<none selected>`, use the project picker above before continuing.

<walkthrough-footnote>Cloud Shell sets GOOGLE_CLOUD_PROJECT automatically once a project is selected.</walkthrough-footnote>

## Check that billing is enabled

The Routes API is a paid API. Requests fail with `PERMISSION_DENIED` if the project has
no billing account attached, so check first:

```bash
gcloud beta billing projects describe "$GOOGLE_CLOUD_PROJECT" --format='value(billingEnabled)'
```

This must print `True`.

If it prints `False` (or the command errors), open
[Billing](https://console.cloud.google.com/billing/linkedaccount) in the Cloud Console,
link a billing account to this project, then run the command again. Google offers
recurring free Maps usage each month, but the billing account still has to exist.

## Enable the Routes API

<walkthrough-enable-apis apis="routes.googleapis.com"></walkthrough-enable-apis>

Or from the terminal:

```bash
gcloud services enable routes.googleapis.com
```

This takes a few seconds. It is safe to run again if it is already enabled.

## Set the IP restriction

Copy the allowed IP addresses from the PingTab setup screen and paste them into the
command below, replacing `PASTE_IPS_HERE`. Use a comma-separated list if PingTab shows
more than one.

```bash
export PINGTAB_ALLOWED_IPS="PASTE_IPS_HERE"
echo "Restricting the key to: $PINGTAB_ALLOWED_IPS"
```

This is what makes the key safe to hand over: it will only work when called from
PingTab's backend, and is useless anywhere else.

<walkthrough-footnote>Do not skip this. An unrestricted Maps key that leaks can be used by anyone, billed to you.</walkthrough-footnote>

## Create the API key

```bash
./setup.sh --allowed-ips "$PINGTAB_ALLOWED_IPS"
```

The script will:

1. Re-check that billing is enabled and the Routes API is on.
2. Create a key named **PingTab Routes (server)**, restricted to the Routes API only
   and to the IP addresses you supplied.
3. Print the key string.

If a key with that name already exists, the script reuses it instead of creating a
duplicate — so it is safe to run twice.

## Copy the key into PingTab

The script printed a line starting with `AIza...`. Copy that whole value and paste it
into the **Google Maps API key** field on the PingTab setup screen, then save.

PingTab will make one test call to the Routes API to confirm the key works and is
correctly restricted before it starts using it. If validation fails, PingTab keeps
using its shared key and tells you what went wrong.

To print the key again later:

```bash
gcloud services api-keys get-key-string \
  "$(gcloud services api-keys list \
       --filter='displayName="PingTab Routes (server)"' \
       --format='value(name)' --limit=1)" \
  --format='value(keyString)'
```

## Done

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

Your PingTab organization now runs its Maps calls on your own project and your own
billing account.

**Good things to do next:**

- Set a [budget alert](https://console.cloud.google.com/billing/budgets) on the billing
  account so surprise usage is caught early.
- Review usage any time under
  [Google Maps Platform → Metrics](https://console.cloud.google.com/google/maps-apis/metrics).
- To stop using your own key, clear the field in PingTab and delete the key with
  `gcloud services api-keys delete`.
