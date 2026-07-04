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
- ServiceLB migration is complete (2026-07-04): `pihole-dns` (.245), `pihole-web` (.240) and `traefik` (.241) all carry MetalLB IPs from `wlan-pool`. A `wired-pool` (`192.168.1.2`–`.9`) with its own L2Advertisement on `end0` also exists for backend-network services.

## Notes
Both nodes must have a live `wlan0` interface for L2Advertisement to have somewhere to announce from. If a node's WLAN interface is down, MetalLB will only announce from the other node — no failure, but reduced redundancy.

## WLAN VIPs and UniFi proxy-ARP (2026-07-04)

MetalLB's ARP announcements **do not work on the WLAN by themselves**. Packet
captures on both Pis showed the UniFi AP/Dream Machine answers ARP on behalf
of clients from its client table (proxy-ARP) and never forwards ARP requests
to clients — not even for a client's own address. A floating IP that exists
only in a MetalLB speaker is not in that table, so its ARP requests are
answered by nobody and the VIP is unreachable over WiFi. (The wired network
has no such interception — `wired-pool` works with plain MetalLB L2.)

**Workaround in place:** the WLAN VIPs are additionally bound as /32
secondary addresses on `pinode-01`'s `wlan0` via NetworkManager
(`nmcli connection modify preconfigured +ipv4.addresses
"192.168.2.240/32,192.168.2.241/32,192.168.2.245/32"`). Once bound, the
Dream Machine learns the IP↔MAC binding from the kernel's gratuitous ARP /
live traffic and the VIPs resolve instantly. kube-proxy already DNATs
LoadBalancer IPs on every node, so any VIP packet reaching pinode-01 lands
on the right service. MetalLB still allocates the IPs; failover to the other
node does NOT work for these WLAN VIPs while the AP filters ARP.

**To get true MetalLB L2 on the WLAN** (and remove the static binding):
disable the ARP/broadcast optimizations for the `ARDA_HOME` SSID in the
UniFi console — Settings → WiFi → ARDA_HOME → Advanced: turn off
"Multicast Enhancement (IGMPv3)" and "Multicast and Broadcast Control" /
"Proxy ARP" (naming varies by UniFi Network version), then remove the
static addresses with `nmcli connection modify preconfigured
-ipv4.addresses "..."` on pinode-01 and re-test ARP from the other node.
