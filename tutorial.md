# Connect your own Google Maps billing to PingTab

<walkthrough-tutorial-duration duration="8"></walkthrough-tutorial-duration>

PingTab uses Google Maps for trip ETAs, route planning and the maps on your website.
By default those calls run on PingTab's shared key. This walkthrough creates keys in
**your own** Google Cloud project instead, so the Maps usage is billed to you and the
quota is yours alone.

You will end up with **two** keys, because a Google API key can carry only one kind of
restriction. A single key cannot safely serve both a server and a browser:

| Key | Locked to | Used for |
| --- | --- | --- |
| **Server** | PingTab's backend IP addresses | Routes API (ETAs and planned routes) |
| **Browser** | your website's addresses | Maps JavaScript, Maps Static, Places (New) |

Everything below runs as **you**, in **your** project. PingTab never sees your Google
credentials. At the end you copy two key strings back into PingTab.

**What you need before starting:**

- A Google Cloud project you can create API keys in (Owner, Editor, or API Keys Admin).
- A **billing account linked to that project**. Google will not serve the Maps APIs
  without one, and no script can create a billing account for you.
- The **IP addresses** and **website addresses** shown on the PingTab setup screen you
  came from.

Click **Start** to begin.

## Pick the project to use

Choose the Google Cloud project the keys should live in. If you want a brand new
project, create one here too.

<walkthrough-project-setup></walkthrough-project-setup>

Now put that choice into this terminal. Run this whether or not you used the picker:

```bash
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [ "$PROJECT" = "(unset)" ]; then PROJECT=""; fi
export GOOGLE_CLOUD_PROJECT="${PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}"
echo "Project: ${GOOGLE_CLOUD_PROJECT:-<none selected>}"
```

**The picker does not change a terminal that is already open.** Cloud Shell sets
`GOOGLE_CLOUD_PROJECT` when a shell starts, and the picker writes your choice to the
gcloud config instead, so a tab opened first keeps an empty value and commands using it
fail with `could not parse resource []`. The command above reads the config, which is
always current.

If it still prints `<none selected>`, the picker did not apply. Set the project by hand:

```bash
gcloud projects list
gcloud config set project YOUR_PROJECT_ID
export GOOGLE_CLOUD_PROJECT=YOUR_PROJECT_ID
```

<walkthrough-footnote>Run every later step in this same terminal, or repeat the export above in a new one.</walkthrough-footnote>

## Check that billing is enabled

The Maps APIs are paid APIs. Requests fail with `PERMISSION_DENIED` if the project has
no billing account attached, so check first:

```bash
gcloud beta billing projects describe \
  "${GOOGLE_CLOUD_PROJECT:-$(gcloud config get-value project)}" \
  --format='value(billingEnabled)'
```

If it prints `True`, carry on.

If it prints `False`, open
[Billing](https://console.cloud.google.com/billing/linkedaccount) in the Cloud Console,
link a billing account to this project, then run the command again. Google offers
recurring free Maps usage each month, but the billing account still has to exist.

If the command **errors instead of printing anything**, that is usually a permission
you do not have on the billing account rather than a project without billing. Carry on:
the setup script warns about it and keeps going. If the project really has no billing
account, the next step fails when it tries to switch the Maps APIs on, and says so.

## Enable the Maps APIs

`setup.sh` enables these itself in a moment, so this step is optional. It is worth doing
now anyway: if the project has no billing account, or you lack the permission to switch
services on, that shows up here, before any keys exist.

Click the button below. It runs one command against the project you picked.

<walkthrough-enable-apis apis="routes.googleapis.com,maps-backend.googleapis.com,static-maps-backend.googleapis.com,places.googleapis.com,apikeys.googleapis.com"></walkthrough-enable-apis>

If no button appears, you are reading this outside Cloud Shell. Run the same thing:

```bash
gcloud services enable \
  routes.googleapis.com \
  maps-backend.googleapis.com \
  static-maps-backend.googleapis.com \
  places.googleapis.com \
  apikeys.googleapis.com \
  --project="$GOOGLE_CLOUD_PROJECT"
```

`maps-backend` is the Maps JavaScript API and `static-maps-backend` is the Maps Static
API. Those are the service names Google uses internally. This takes a few seconds and
is safe to run again if the APIs are already on.

## Copy the restrictions from PingTab

The PingTab setup screen shows the values to lock the keys to. Paste them into the
command below, replacing `PASTE_IPS_HERE` and `PASTE_REFERRERS_HERE`. Use
comma-separated lists if PingTab shows more than one of either.

**PingTab may show only the website addresses.** The backend IP addresses are shown
only on deployments that publish them, and without them there is nothing to restrict a
server key to. In that case skip `PINGTAB_ALLOWED_IPS` entirely and follow the
browser-key-only command in the next step: you get the website key, and routes and
arrival times stay on PingTab's key.

```bash
export PINGTAB_ALLOWED_IPS="PASTE_IPS_HERE"
export PINGTAB_ALLOWED_REFERRERS="PASTE_REFERRERS_HERE"
echo "Backend IPs : $PINGTAB_ALLOWED_IPS"
echo "Website     : $PINGTAB_ALLOWED_REFERRERS"
```

This is what makes the keys safe to hand over. The server key will only work when
called from PingTab's backend; the browser key will only work on pages served from your
own website. Neither is useful to anyone who copies it.

<walkthrough-footnote>Do not skip this. An unrestricted Maps key that leaks can be used by anyone, billed to you.</walkthrough-footnote>

## Create the keys

```bash
./setup.sh \
  --allowed-ips "$PINGTAB_ALLOWED_IPS" \
  --allowed-referrers "$PINGTAB_ALLOWED_REFERRERS"
```

If PingTab showed no backend IP addresses, run this instead. It creates the browser key
alone and enables only the APIs that key needs:

```bash
./setup.sh --allowed-referrers "$PINGTAB_ALLOWED_REFERRERS"
```

The script will:

1. Re-check that billing is enabled and the APIs are on.
2. Create **PingTab Routes (server)**, restricted to the Routes API and to your
   backend IP addresses.
3. Create **PingTab Web (browser)**, restricted to Maps JavaScript, Maps Static and
   Places (New), and to your website addresses.
4. Print both key strings.

If either key already exists, the script updates its restrictions instead of creating a
duplicate, so it is safe to run twice.

## Copy the keys into PingTab

The script printed two values, each starting `AIza...`. Copy each one into the field it
names on the PingTab setup screen:

| Printed as | PingTab field |
| --- | --- |
| Server key | **Backend API key** |
| Browser key | **Website API key** |

PingTab checks the **server key** against Google as you save it, and refuses it with
Google's own message if the Routes API is off or the IP restriction does not cover
PingTab's servers.

The **browser key** cannot be checked that way: a correctly referrer-restricted key is
meant to fail when a server calls it. So PingTab saves it and gives you a **Test this
key** button beside the field, which loads a map from the page itself. Use it. If a
saved browser key turns out to be wrong, maps quietly fall back to PingTab's key and
the settings screen tells you Google refused yours.

To print the keys again later:

```bash
for name in "PingTab Routes (server)" "PingTab Web (browser)"; do
  echo "== $name"
  gcloud services api-keys get-key-string \
    "$(gcloud services api-keys list --filter="displayName=\"$name\"" \
         --format='value(name)' --limit=1)" \
    --format='value(keyString)'
done
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
- To stop using your own keys, clear the fields in PingTab and delete the keys with
  `gcloud services api-keys delete`.
