# MetalLB

**Status:** ACTIVE
**Version:** 0.16.1 (Helm chart)
**Namespace:** metallb-system
**Sync Wave:** 5 (controller), 10 (config)
**Tags:** `networking` `infra` `load-balancer`

---

## What it does
Provides real `LoadBalancer` IPs for cluster services, replacing k3s's built-in ServiceLB (which just opens each service's port on every node's own IP — no floating IP, no failover). MetalLB in L2 mode announces a floating IP via ARP from whichever node is currently serving it, so the IP survives a node going down.

## How it works
Two ArgoCD apps, ordered by sync-wave:
1. `metallb` (wave 5) — installs the MetalLB controller + speaker via the official Helm chart, native (L2) mode only — no FRR/BGP, this network has no BGP-speaking router.
2. `metallb-config` (wave 10) — applies `IPAddressPool`/`L2Advertisement` CRs. Must run after wave 5 since these are MetalLB CRDs that don't exist until the controller install completes; `syncPolicy.retry` handles the race if ArgoCD tries before the CRDs land.

## Config & dependencies
- IP pool: `192.168.2.240`–`192.168.2.250` — reserved and excluded from the UniFi DHCP scope (which runs `.6`–`.239`) as of 2026-07-03. Expand downward (e.g. `.230`–`.250`) if more floating IPs are needed later — exclude any new range in UniFi first.
- `L2Advertisement.spec.interfaces: [wlan0]` scopes ARP announcements to the WLAN interface only, on both nodes (`k8smaster`, `pinode-01` both name it `wlan0`) — floating IPs live on `192.168.2.x`, not the wired backend network.
- k3s's built-in ServiceLB is still active as of this app's introduction — existing `LoadBalancer` services (`pihole`, `traefik`) keep using it until it's explicitly disabled (`--disable=servicelb` in k3s config) and their services are cut over. See day1-foundation project notes for that migration step.

## Notes
Both nodes must have a live `wlan0` interface for L2Advertisement to have somewhere to announce from. If a node's WLAN interface is down, MetalLB will only announce from the other node — no failure, but reduced redundancy.
