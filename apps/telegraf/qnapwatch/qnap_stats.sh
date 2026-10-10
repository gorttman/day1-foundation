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

# CPU over a one-second window: two reads of /proc/stat, one second apart.
# busy = everything except idle and iowait; iowait is shown separately because
# on a NAS it is the number that says "waiting on the disks".
cpu() { awk '/^cpu /{ print $2+$3+$4+$7+$8+$9, $6, $5 }' /proc/stat; }
set -- $(cpu); b1=$1; w1=$2; i1=$3
sleep 1
set -- $(cpu); b2=$1; w2=$2; i2=$3
awk -v b=$((b2-b1)) -v w=$((w2-w1)) -v i=$((i2-i1)) 'BEGIN { t=b+w+i; if (t>0) printf "qnap_cpu busy_pct=%.1f,iowait_pct=%.1f\n", b*100/t, w*100/t }'

# SMART health per bay, refreshed every 15 minutes (not every run: it asks each
# disk, and the QNAP is already busy). Points are written only on a refresh, so
# the newest SMART point is never older than ~15 min while the watcher is up.
# Attribute ids are matched as text with leading zeros stripped: this BusyBox
# awk reads 011 as octal. Power-on hours on Seagates carries extra bits in the high half of the raw
# value, so only the low 32 bits are used. The USB backup drive is not a SATA
# bay, so this tool cannot read it.
SC=/tmp/.qnapwatch_smart_stamp
now=$(date +%s)
last=$(cat "$SC" 2>/dev/null || echo 0)
if [ $((now - last)) -ge 900 ]; then
  echo "$now" > "$SC"
  n=$(getsysinfo hdnum 2>/dev/null | awk '{print $1+0}')
  i=1
  while [ "$i" -le "${n:-0}" ]; do
    m=$(getsysinfo hdmodel "$i" 2>/dev/null | tr -d ' ')
    /sbin/get_hd_smartinfo -d "$i" 2>/dev/null | awk -v d="$i" -v m="$m" '
      { id=$1; sub(/^0+/, "", id); raw=$3; st=$NF; if (st != "OK") bad++; seen[id]=1 }
      id=="5"   { re=raw }
      id=="197" { pe=raw }
      id=="198" { un=raw }
      id=="199" { cr=raw }
      id=="9"   { x=raw+0; hrs=x-4294967296*int(x/4294967296) }
      id=="12"  { y=raw+0; pc=y-4294967296*int(y/4294967296) }
      id=="193" { lc=raw }
      id=="187" { ru=raw }
      id=="188" { z=raw+0; to=z-65536*int(z/65536) }
      id=="240" { h=raw+0; hh=h-4294967296*int(h/4294967296) }
      id=="241" { lw=raw }
      id=="242" { lr=raw }
      END {
        s = sprintf("qnap_smart,disk=%s,model=%s reallocated=%.0fi,pending=%.0fi,uncorrectable=%.0fi,crc_errors=%.0fi,power_on_hours=%.0fi,power_cycles=%.0fi,failing_attrs=%di", d, m, re, pe, un, cr, hrs, pc, bad)
        if ("193" in seen) s = s sprintf(",load_cycles=%.0fi", lc)
        if ("187" in seen) s = s sprintf(",reported_uncorrect=%.0fi", ru)
        if ("188" in seen) s = s sprintf(",cmd_timeouts=%.0fi", to)
        if ("240" in seen) s = s sprintf(",head_hours=%.0fi", hh)
        if ("241" in seen) s = s sprintf(",lba_written=%.0fi", lw)
        if ("242" in seen) s = s sprintf(",lba_read=%.0fi", lr)
        print s
      }'
    i=$((i+1))
  done
fi
