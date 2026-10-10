#!/usr/bin/env bash
# Idempotent installer for the QNAP watcher (run from anywhere; safe to re-run).
#  1. Pushes qnap_stats.sh to the QNAP (atomic: write .new, then mv).
#  2. Adds a RESTRICTED SSH key to the QNAP's authorized_keys: it can run only
#     the stats script (forced command, no tty, no forwarding). The admin key
#     used by Ansible is never given to a pod.
#  3. Seals the private key + the QNAP host key into qnap-watch-sealed-secret.yml
#     (only when that file does not exist yet, so re-runs do not rotate the key).
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
QNAP=admin@192.168.20.30
ADMINKEY="$HOME/.ssh/qnap_ansible_ed25519"
SSH=(ssh -i "$ADMINKEY" -o BatchMode=yes -o ConnectTimeout=10 "$QNAP")
DEST=/share/CACHEDEV1_DATA/.scripts/qnap-stats.sh
SEALED="$HERE/qnap-watch-sealed-secret.yml"

"${SSH[@]}" "cat > $DEST.new && chmod 755 $DEST.new && mv $DEST.new $DEST" < "$HERE/qnap_stats.sh"

if [ ! -f "$SEALED" ]; then
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  ssh-keygen -q -t ed25519 -N "" -C qnapwatch -f "$T/id"
  ssh-keyscan -t rsa,ecdsa,ed25519 192.168.20.30 2>/dev/null > "$T/known_hosts"
  [ -s "$T/known_hosts" ] || { echo "could not read the QNAP host key" >&2; exit 1; }
  PUB="$(cat "$T/id.pub")"
  LINE="command=\"$DEST\",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc $PUB"
  "${SSH[@]}" "[ -f /etc/config/ssh/authorized_keys.pre_qnapwatch ] || cp -p /etc/config/ssh/authorized_keys /etc/config/ssh/authorized_keys.pre_qnapwatch"
  "${SSH[@]}" "grep -q ' qnapwatch\$' /etc/config/ssh/authorized_keys && sed -i '/ qnapwatch\$/d' /etc/config/ssh/authorized_keys; echo '$LINE' >> /etc/config/ssh/authorized_keys"
  sudo kubectl create secret generic qnap-watch-key -n monitoring \
    --from-file=id="$T/id" --from-file=known_hosts="$T/known_hosts" --dry-run=client -o yaml \
    | sudo env KUBECONFIG="$KUBECONFIG" kubeseal --format yaml > "$SEALED"
  echo "sealed key written to $SEALED"
else
  "${SSH[@]}" "grep -q ' qnapwatch\$' /etc/config/ssh/authorized_keys" \
    || { echo "sealed secret exists but the QNAP has no qnapwatch key: delete $SEALED and re-run" >&2; exit 1; }
fi
echo "QNAP watcher installed."
