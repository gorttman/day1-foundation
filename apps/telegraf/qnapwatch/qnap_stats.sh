#!/bin/sh
# QNAP health snapshot as InfluxDB line protocol. Installed on the QNAP at
# /share/CACHEDEV1_DATA/.scripts/qnap-stats.sh and run ONLY as the forced
# command of the restricted "qnapwatch" SSH key (see install_qnapwatch.sh).
# Read-only and cheap on purpose: df (statfs), /proc and getsysinfo. No du,
# no directory walks - the box has 1 GB of RAM and runs the backup mirrors.
# BusyBox 1.24: no nice/timeout, awk is available. Tags have no spaces.

fs() {  # fs <tag> <path>  -> bytes; the last 5 df fields survive line wrapping
  df -k "$2" 2>/dev/null | tail -1 | awk -v t="$1" '
    NF>=5 { s=$(NF-4)*1024; u=$(NF-3)*1024; f=$(NF-2)*1024;
            printf "qnap_fs,mount=%s total_b=%.0fi,used_b=%.0fi,free_b=%.0fi,pct=%.2f\n", t, s, u, f, (s>0? u*100/s : 0) }'
}
fs backup /share/external/DEV3302_1
fs data   /share/CACHEDEV1_DATA
fs system /mnt/HDA_ROOT

awk '{ printf "qnap_host load1=%s,load5=%s,load15=%s\n", $1, $2, $3 }' /proc/loadavg
awk '/^MemTotal/{t=$2} /^MemFree/{f=$2} /^Buffers/{b=$2} /^Cached/{c=$2}
     END { printf "qnap_mem total_kb=%di,free_kb=%di,avail_kb=%di\n", t, f, f+b+c }' /proc/meminfo
awk '{ printf "qnap_host uptime_s=%di\n", $1 }' /proc/uptime

c=$(getsysinfo cputmp 2>/dev/null | awk '{print $1+0}')
s=$(getsysinfo systmp 2>/dev/null | awk '{print $1+0}')
echo "qnap_temp cpu_c=${c:-0}i,system_c=${s:-0}i"
n=$(getsysinfo hdnum 2>/dev/null | awk '{print $1+0}')
i=1
while [ "$i" -le "${n:-0}" ]; do
  t=$(getsysinfo hdtmp "$i" 2>/dev/null | awk '{print $1+0}')
  echo "qnap_disk,disk=$i temp_c=${t:-0}i"
  i=$((i+1))
done

# Only md1 (the 6-disk data array): md9/md13 are QNAP system mirrors that
# always report 6 of 32 members and would look permanently degraded.
awk '/^md[0-9]+ :/ { a=$1 }
     /\[[0-9]+\/[0-9]+\]/ { if (a != "md1") next; match($0, /\[[0-9]+\/[0-9]+\]/); x=substr($0, RSTART+1, RLENGTH-2); split(x, p, "/");
       printf "qnap_raid,array=%s expected=%di,active=%di,degraded=%di\n", a, p[1], p[2], (p[2]<p[1]?1:0) }' /proc/mdstat

ps 2>/dev/null | awk '
  NR>1 { if ($4 ~ /^D/) d++; if ($0 ~ /rsync -a/) r++; if ($0 ~ /qnap-snapshot.sh/ && $0 !~ /awk/) sn++ }
  END { printf "qnap_proc blocked=%di,rsync=%di,snapshot_jobs=%di\n", d, r, sn }'
