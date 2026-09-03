# Connect your own Google Maps billing to PingTab

<walkthrough-tutorial-duration duration="8"></walkthrough-tutorial-duration>

PingTab uses Google Maps for trip ETAs, route planning and the maps on your website.
By default those calls run on PingTab's shared key. This walkthrough creates keys in
**your own** Google Cloud project instead, so the Maps usage is billed to you and the
quota is yours alone.

You will end up with **two** keys, because a Google API key can carry only one kind of
restriction — a single key cannot safely serve both a server and a browser:

| Key | Locked to | Used for |
| --- | --- | --- |
| **Server** | PingTab's backend IP addresses | Routes API — ETAs and planned routes |
| **Browser** | your website's addresses | Maps JavaScript, Maps Static, Places (New) |

Everything below runs as **you**, in **your** project. PingTab never sees your Google
credentials — at the end you copy two key strings back into PingTab.

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

Confirm Cloud Shell picked it up:

```bash
echo "Project: ${GOOGLE_CLOUD_PROJECT:-<none selected>}"
```

If that prints `<none selected>`, use the project picker above before continuing.

<walkthrough-footnote>Cloud Shell sets GOOGLE_CLOUD_PROJECT automatically once a project is selected.</walkthrough-footnote>

## Check that billing is enabled

The Maps APIs are paid APIs. Requests fail with `PERMISSION_DENIED` if the project has
no billing account attached, so check first:

```bash
gcloud beta billing projects describe "$GOOGLE_CLOUD_PROJECT" --format='value(billingEnabled)'
```

This must print `True`.

If it prints `False` (or the command errors), open
[Billing](https://console.cloud.google.com/billing/linkedaccount) in the Cloud Console,
link a billing account to this project, then run the command again. Google offers
recurring free Maps usage each month, but the billing account still has to exist.

## Enable the Maps APIs

<walkthrough-enable-apis apis="routes.googleapis.com,maps-backend.googleapis.com,static-maps-backend.googleapis.com,places.googleapis.com"></walkthrough-enable-apis>

Or from the terminal:

```bash
gcloud services enable \
  routes.googleapis.com \
  maps-backend.googleapis.com \
  static-maps-backend.googleapis.com \
  places.googleapis.com \
  apikeys.googleapis.com
```

`maps-backend` is the Maps JavaScript API and `static-maps-backend` is the Maps Static
API — those are the service names Google uses internally. This takes a few seconds and
is safe to run again if the APIs are already on.

## Copy the restrictions from PingTab

The PingTab setup screen shows two values. Paste them into the command below, replacing
`PASTE_IPS_HERE` and `PASTE_REFERRERS_HERE`. Use comma-separated lists if PingTab shows
more than one of either.

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

The script will:

1. Re-check that billing is enabled and the APIs are on.
2. Create **PingTab Routes (server)**, restricted to the Routes API and to your
   backend IP addresses.
3. Create **PingTab Web (browser)**, restricted to Maps JavaScript, Maps Static and
   Places (New), and to your website addresses.
4. Print both key strings.

If either key already exists, the script updates its restrictions instead of creating a
duplicate — so it is safe to run twice.

## Copy the keys into PingTab

The script printed two values, each starting `AIza...`. Copy each one into the field it
names on the PingTab setup screen:

| Printed as | PingTab field |
| --- | --- |
| Server key | **Backend API key** |
| Browser key | **Website API key** |

PingTab will make one test call against each key to confirm it works and is correctly
restricted before it starts using them. If validation fails, PingTab keeps using its
shared key and tells you what went wrong.

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
