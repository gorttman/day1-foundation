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
If you remove this, dhcpd, pxe-http, and nfs-server will fail to sync because `namespace: infra` won't exist. Keep it at the top of `apps/kustomization.yml`.
