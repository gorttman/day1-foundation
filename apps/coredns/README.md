# CoreDNS

**Status:** RETIRED (2026-08-06) — this app no longer exists in Argo CD.
**Tags:** `networking` `dns` `infra`

---

## What happened

This app used to replace CoreDNS's entire `Corefile` ConfigMap and patch
its Deployment to mount a custom-hosts volume. Both were always futile:
k3s ships CoreDNS as one of its own built-in, auto-deployed components
(`/var/lib/rancher/k3s/server/manifests/coredns.yaml`), and its embedded
controller continuously reconciles that ConfigMap/Deployment/Service —
confirmed live (2026-08-06) by deleting the ConfigMap directly and
watching k3s recreate it within ~2 seconds, not just on restart. Any
config we tried to own under the same name always lost, unconditionally.

It happened to *look* like it worked for months, because `k8smaster`
hadn't been restarted in 281 days — the Corefile only gets regenerated
by k3s at `k3s-server` startup, so the drift was invisible until a real
restart (2026-08-06) exposed it: our version disappeared, k3s's stock
Corefile came back, and it imports `coredns-custom`'s `.override` files
in a way our content wasn't written for (`plugin/hosts: this plugin can
only be used once per Server Block`) — CoreDNS failed to start,
breaking cluster-internal DNS during an already-serious incident.

The Deployment patch (mounting `coredns-custom`) was separately
redundant anyway — k3s's own stock Deployment already mounts
`coredns-custom` natively; that's the actual, documented, durable
customization point.

## Where DNS customization actually lives now

**`coredns-config`** — a separate Argo CD Application, defined in
`day0-bootstrap/apps/dns-config/coredns-config-app.yml`, sourced from
the `dns-conf` repo's `coredns/` path. It manages *only*
`coredns-custom` (ConfigMap, `kube-system`) — the one thing k3s actually
lets you own. That's the real, durable app; nothing here needs to exist
alongside it.

To add a static host override or a new zone: edit `dns-conf`'s
`coredns/hosts.override` or add a `fragments/*.server` file (see that
repo's own README/comments) and push — `coredns-config`'s `selfHeal`
picks it up automatically.

**Lesson for any future app in this repo**: before writing a
`ConfigMap`/`Deployment`/anything else in `kube-system` (or any
namespace) that shares a name with something k3s, a Helm chart, or
another controller already manages, check whether that owner
continuously reconciles it (`kubectl delete` it once and see if it
comes back). If it does, you cannot durably override it that way —
find the tool's actual supported customization point instead, however
narrow, rather than fighting a full replacement that only looks like it
works until something forces a real reconcile.
