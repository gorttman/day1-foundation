# cert-manager

Issues every TLS certificate in the cluster. As of 2026-08-21 all ingress
certs come from **Let's Encrypt via DNS-01**, not the private CA.

## Issuers

| Issuer | Used for | Notes |
|---|---|---|
| `letsencrypt-prod` | every app Ingress | publicly trusted, auto-renews |
| `letsencrypt-staging` | validating new plumbing only | untrusted certs; effectively unlimited rate limits |
| `private-ca` | nothing, currently | kept so the CA and its cert aren't destroyed; see "Why not both" |
| `selfsigned` | bootstrapping `private-ca` itself | leave alone |

To request a cert, annotate the Ingress and give it a `tls:` block —
cert-manager's ingress-shim creates the Certificate automatically:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  tls:
    - hosts: [myapp.i3sec.com.au]
      secretName: myapp-tls
```

## Why Let's Encrypt instead of the private CA

The Immich **mobile app** cannot be made to trust `i3sec-private-ca` — by
any means. Its networking layer (`background_downloader`) rejects private
CAs in release builds and ignores the iOS/Android system trust store
entirely. Installing the CA profile on the device, enabling Full Trust,
and importing the CA into the app's own "SSL certificate" setting all
fail, because none of them are consulted. This is a long-standing upstream
limitation, not a misconfiguration here:

- immich-app/immich#28929 — iOS "server is not reachable" with a private CA
- immich-app/immich#15188 — self-signed certs break downloads/playback
- immich-app/immich discussion #2375 — request to trust system CAs

A publicly-trusted certificate is the only thing that works, and DNS-01
gets one **without exposing anything publicly** — Let's Encrypt only ever
sees a TXT record, never the service.

Rolled out fleet-wide rather than for Immich alone: two issuers signing
the same hostnames is a maintenance trap, and having one answer to "where
do certs come from" is worth more than the private CA's independence.

## The split-horizon DNS trap (read this before debugging issuance)

`cert-manager` **must** run with:

```
--dns01-recursive-nameservers-only
--dns01-recursive-nameservers=1.1.1.1:53,9.9.9.9:53
```

set via Helm `extraArgs` in `day0-bootstrap/apps/cert-manager/cert-manager-app.yml`.

Without them, issuance hangs forever in "Waiting for DNS-01 challenge
propagation" and eventually times out. Cause: Pi-hole's split-horizon
lines are `address=/<host>.i3sec.com.au/<ip>`, and in dnsmasq `address=`
matches **the domain and all its subdomains**. So a TXT query for
`_acme-challenge.<host>.i3sec.com.au` hits that rule and returns
NOERROR with zero answers (NODATA) instead of the real public TXT record
cert-manager just wrote via the Cloudflare API. cert-manager resolves
through CoreDNS → the host's `resolv.conf` → Pi-hole, so it never sees
its own challenge. The flags point *only* the ACME self-check at public
resolvers; normal cluster DNS is untouched.

Verified 2026-08-21: `dig TXT _acme-challenge.immich.i3sec.com.au
@192.168.2.245` → NOERROR/0 answers.

## Credentials

DNS-01 authenticates to Cloudflare with the **same API token** that
`cloudflare-tf` already uses (verified to carry Zone:Read + DNS:Edit,
which is all DNS-01 needs), copied into this namespace as
`cloudflare-api-token` rather than minting a second one — one credential
to rotate, not two.

To rotate: reseal from the source secret without ever printing it —

```sh
kubectl get secret -n infra cloudflare-tf-secrets \
  -o jsonpath='{.data.TF_VAR_cloudflare_api_token}' | base64 -d > /tmp/cf-tok
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-file=api-token=/tmp/cf-tok --dry-run=client -o yaml \
| sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubeseal --format yaml \
  > cloudflare-api-token-sealedsecret.yml
shred -u /tmp/cf-tok
```

(`KUBECONFIG` must come *after* `sudo` — sudo strips it otherwise, and
`kubeseal` has none of the k3s fallback that makes bare `kubectl` work.)

## Rate limits

Let's Encrypt allows **50 certs per registered domain per week** and
**5 identical certs per week**. There are ~29 certs across 19 hostnames,
because 9 apps have both a Traefik Ingress (LAN path) and an
ingress-nginx Ingress (tunnel path), each requesting its own cert for the
same hostname — e.g. `argocd-tls` and `argocd-public-tls`. Those 9 pairs
sit at 2 of the 5 identical-cert allowance, so a reissue loop would hit
that ceiling before the 50/week one. Check there first if issuance starts
failing.

Always validate new plumbing against `letsencrypt-staging` first.

## What this does NOT solve: off-LAN mobile app access

The Immich app works on the **LAN**. It does not work off-LAN, and no
certificate change can make it.

Off-LAN traffic goes through the Cloudflare Tunnel, which is gated by the
zone-wide default-deny mTLS WAF rule. Satisfying it requires presenting a
client certificate. Safari can (the client cert is in the iOS keychain);
the Immich app cannot — client-cert support in the mobile app is an open
upstream request (immich-app/immich#1611), not a shipped feature.
Confirmed live 2026-08-21: an edge request without a client cert returns
**403** for `immich.i3sec.com.au` and `books.i3sec.com.au` alike.

Note the two certs are unrelated and point opposite ways: the **server**
cert (Let's Encrypt) proves the server's identity to the client; the
**client** cert (mTLS) proves the device's identity to Cloudflare. One
cannot substitute for the other, and the client cert is already installed
on the devices — the app simply never presents it.

Both workarounds were considered and rejected 2026-08-21:

- **Route it over WARP** — built, then reverted. Works technically, but
  requires a VPN client running on the phone. Unacceptable friction for a
  household user; a photo app that depends on knowing where you're
  standing is broken.
- **Exempt Immich from the mTLS rule** — would work immediately with no
  VPN, but makes the family photo library reachable from the internet
  behind only its own login, while every other host on the zone stays
  behind mTLS. Rejected on principle.

The remaining position: **backup happens automatically at home over
WiFi** (which is how large photo backups should be configured anyway),
and Safari covers off-LAN viewing using the mTLS client cert already on
the devices.

This is a genuine dead end, not an unfinished task. Any native mobile app
needs to reach its server; with no VPN and no public reachability there is
no path, and no alternative photo app escapes it — the research on
2026-08-21 found none combining native iOS camera-roll backup with private
CA support (PhotoPrism handles certs correctly but has no native app at
all, requiring PhotoSync driven by hand).

Revisit only if immich-app/immich#1611 ships.
