# CoreDNS

**Status:** ACTIVE
**Version:** built-in k3s (version managed by k3s upgrade, not pinned here)
**Namespace:** kube-system
**Sync Wave:** 4
**Tags:** `networking` `dns` `infra`

---

## What it does
Provides cluster DNS. This app patches and extends the CoreDNS instance that k3s installs by default — it does not deploy a new CoreDNS, it overlays config on top of the existing one.

## How it works
Two sources:
1. `day1-foundation` repo — deployment patch that mounts the custom ConfigMap, plus a Corefile replacement
2. `dns-conf` repo — hosts override file (`hosts.override`) and any extra `.server` files

The Corefile is replaced wholesale via kustomize strategic merge patch. It imports `/etc/coredns/custom/*.server` and a `hosts.override` file, then falls back to upstream `1.1.1.1` / `8.8.8.8`.

## Config & dependencies
- Config lives in the `dns-conf` repo (separate git repo, separate ArgoCD source)
- To add a static host override: edit `hosts.override` in `dns-conf` and push
- To add a custom zone: add a `.server` file in `dns-conf` and push

## Notes
Sync wave 4 — deploys after core infra (nfs-provisioner wave 1, syslog wave 2, log-archiver wave 3) but before dhcpd (wave 5) and nfs-server (wave 6).

The `import /etc/coredns/custom/*.server` directive means adding a new zone file to `dns-conf` is zero-touch — no Corefile edit needed.
