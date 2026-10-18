# Retired apps

These apps used to live under `apps/` and were removed on 2026-10-19. None
was deployed: each had been disabled (commented out of `apps/kustomization.yml`)
or was no longer referenced, and no ArgoCD Application or cluster object
existed for any of them. Their full manifests and READMEs are in git history;
restore with:

    git checkout 9f14637 -- apps/<name>

(9f14637 is the last commit that still had them.) Read the reason below
before restoring anything.

## dhcpd (disabled 2026-09-03)
ISC DHCP server for the cluster backend network, also handing out PXE
`next-server`/`filename`. It only declared subnet 192.168.1.0/27, the
pre-VLAN20 backend; since the 2026-08-30 migration no node has an interface
there, so it exited on every start (117 restarts). Re-pointing it at
192.168.20.0/24 is NOT the fix: the UDM already serves DHCP there and two
DHCP servers on one segment is worse than none. Reservations and PXE options
are the UDM's job now (unifi-tf). Config lived in the separate `dhcpd-conf` repo.

## pxe-http (disabled 2026-09-03)
Other half of the PXE stack: TFTP bootloader hand-off plus HTTP
kernel/initrd/rootfs for diskless RPi5 nodes. Netboot was dropped (nodes boot
from local storage), its boot config pointed at an NFS root path that the live
server no longer exports, and with dhcpd gone nothing could direct a client to
it. Netboot files were staged under `/var/www/html/netboot/rpi5` on k8smaster.

## nfs-provisioner (disabled 2026-09-03)
Provided the `nfs-client` StorageClass backed by `/srv/nfs/syslog-store`. That
export went away when syslog storage moved to Longhorn, leaving the pod in
ContainerCreating on a mount that returned ENOENT. Nothing claims `nfs-client`
any more: every PVC is `longhorn` or QNAP-static.

## nfs-server (not deployed; its README still said ACTIVE)
In-cluster NFS server (hostNetwork, privileged, hostPath `/srv/nfs` on
k8smaster) for netboot root filesystems and the provisioner above. Superseded
by the QNAP, which serves every NFS volume in use. It was no longer in
`apps/kustomization.yml`.

## portainer (disabled 2026-06-06)
Web UI for browsing pods, NodePorts 30900/30943. Replaced by ArgoCD + kubectl
+ Grafana. Re-enabling recreates an empty PVC (old data was not kept).
