# infra-namespace

**Status:** ACTIVE
**Version:** n/a
**Namespace:** infra (creates it)
**Sync Wave:** n/a (applied by root kustomization directly, not an ArgoCD Application)
**Tags:** `infra` `bootstrap`

---

## What it does
Creates the `infra` namespace. Applied first by the root `apps/kustomization.yml` as a raw manifest (not wrapped in an ArgoCD Application), so the namespace exists before any app in it tries to sync.

## Notes
Nothing deploys into `infra` at the moment (dhcpd, pxe-http and nfs-server, which did, were retired 2026-10-19 - see ../../RETIRED-APPS.md). The namespace is kept in case something infra-tier needs it again; it is safe to remove together with this app if it stays empty. If anything is added to `infra`, keep this at the top of `apps/kustomization.yml` so the namespace exists first.
