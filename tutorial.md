# Use your own Google Maps account with PingTab

<walkthrough-tutorial-duration duration="4"></walkthrough-tutorial-duration>

This sets up Google Maps in your own Google Cloud account, so the maps and arrival
times PingTab shows are billed to you and no usage limit is shared with anyone else.
You need a Google Cloud project with billing on it, and the command shown on the PingTab
screen you came from. PingTab never sees your Google login: everything here runs as you,
in your own account.

<walkthrough-footnote>Two keys get created, not one, because Google lets a key be locked to a website or to a server, never both.</walkthrough-footnote>

## Choose your Google Cloud project

Pick the project the keys should live in, or create a new one here.

<walkthrough-project-setup></walkthrough-project-setup>

A brand new project needs a billing account linked to it before Google will serve maps.
You can do that on the
[billing page](https://console.cloud.google.com/billing/linkedaccount).

## Paste the command from PingTab

Go back to the PingTab settings screen and copy the command it shows you. It looks like
`./setup.sh --code XXXX-XXXX`, with your own code in place of the Xs.

Paste it into the terminal below this panel and press Enter.

It will:

- read your PingTab settings using that code
- switch on the Google Maps services in your project
- create the keys, locked so they only work for PingTab and for your own website
- send them straight back to PingTab

It takes about a minute. If it stops, it says why in plain words: fix that, then paste
the same command again.

## Done

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

Switch back to the PingTab tab in your browser. It will show that the keys have arrived.
Click **Test this key** beside the Browser key to watch a map load with it.

One thing worth doing now: set a
[budget alert](https://console.cloud.google.com/billing/budgets) on your billing account,
so any unexpected usage reaches you early.

<walkthrough-footnote>To stop using your own Google account for maps, clear the keys on the PingTab settings screen.</walkthrough-footnote>
