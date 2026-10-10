#!/bin/sh
# NFS client statistics per server, read from the HOST's mountstats (the
# built-in nfsclient plugin reads its own container's mount namespace, which
# has no NFS mounts, so it returns nothing here). Added 2026-10-10 to find
# out what happens during a k8smaster "NFS wedge": counters are cumulative,
# so graph them as a rate.
# Runs in the nfs-stats sidecar (root, sees ONLY the host's /proc/1/mountstats
# through a single-file hostPath) because telegraf itself is not root and the
# file is unreadable to it. The sidecar writes /out/nfs.lp; telegraf reads it.
#   timeouts / retrans   climbing = network or server not answering
#   connects             climbing = the TCP session keeps being re-made
#   backlog              requests waiting to be sent (client-side queue)
#   rtt_ms / queue_ms    time on the wire vs time waiting in the client
# Healthy numbers while tasks are stuck would point at the client itself.
awk '
function mx(arr, k, v) { if (v + 0 > arr[k] + 0) arr[k] = v + 0 }
/^device / {
    inm = ($0 ~ / with fstype nfs4? /)
    if (inm) { dev = $2; sub(/:.*/, "", dev); seen[dev] = 1 }
    next
}
# NFSv4.1 mounts to one server share a single client session, so every mount
# (and there are 30+, one per pod volume) reports the SAME counters. They are
# per SERVER, not per export: take one copy per server, never add them up.
inm && $1 == "xprt:" {
    mx(connects, dev, $5); mx(sends, dev, $8); mx(backlog, dev, $12); mx(pending, dev, $15)
    next
}
inm && $1 ~ /^[A-Z_0-9]+:$/ && $2 ~ /^[0-9]+$/ && NF >= 9 {
    op = dev SUBSEP $1
    o[op] = $2; nt[op] = $3; to[op] = $4; q[op] = $7; r[op] = $8; e[op] = $9; names[op] = dev
}
END {
    # one value per (export, operation) from the last mount seen, summed over operations,
    # then the largest across mounts of that export is not needed: ops repeat identically.
    for (op in o) {
        d = names[op]
        mx_ops[d] += o[op]; mx_nt[d] += nt[op]; mx_to[d] += to[op]
        mx_q[d] += q[op]; mx_r[d] += r[op]; mx_e[d] += e[op]
    }
    for (d in seen) {
        retrans = mx_nt[d] - mx_ops[d]; if (retrans < 0) retrans = 0
        printf "nfs_mountstats,server=%s ops=%.0fi,retrans=%.0fi,timeouts=%.0fi,queue_ms=%.0fi,rtt_ms=%.0fi,exec_ms=%.0fi,connects=%.0fi,sends=%.0fi,backlog=%.0fi,pending=%.0fi\n",
            d, mx_ops[d], retrans, mx_to[d], mx_q[d], mx_r[d], mx_e[d], connects[d], sends[d], backlog[d], pending[d]
    }
}' "${MOUNTSTATS:-/proc/1/mountstats}"
