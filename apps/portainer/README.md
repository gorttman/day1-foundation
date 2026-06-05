# Portainer

**Status:** DISABLED (2026-06-06 — not needed day-to-day, replaced by ArgoCD + kubectl)
**Version:** portainer/portainer-ce:2.21.4
**Namespace:** portainer
**Sync Wave:** 1
**Tags:** `ui` `mgmt`

---

## What it does
Web UI for browsing and managing containers/pods in the cluster. Provides a visual alternative to kubectl for ad-hoc inspection.

## How it works
Single-replica Deployment with a PVC (`portainer-data`, 10Gi, local-path) for state. Exposed via NodePort service (HTTP 30900, HTTPS 30943, Edge agent 30800). RBAC via dedicated ServiceAccount with ClusterRole.

## Config & dependencies
No external config repo. All state stored in the PVC. No ingress — access is direct NodePort only.

## Access
- HTTP: http://192.168.2.10:30900
- HTTPS: https://192.168.2.10:30943
- Credentials: admin / admin (password reset 2026-06-01)

## Notes
**Re-enable:** uncomment `- portainer/portainer-app.yml` in `apps/kustomization.yml` and push. ArgoCD will recreate the namespace and deployment. The PVC will be recreated empty — previous config data is not retained after disable.

PVC data path when active: `/var/lib/rancher/k3s/storage/pvc-*/portainer_portainer-data/portainer.db`
