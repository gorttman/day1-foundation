#!/usr/bin/env bash
# Run this yourself, locally. It asks for your Telegram bot token (hidden),
# checks it with Telegram, finds your chat id, sends a test message to your
# phone, and seals the token and chat id into
# grafana-telegram-sealed-secret.yml (namespace monitoring).
#
# Why a script and not pasting the token into a chat session: a credential
# typed into a chat lives in that transcript permanently. Here the token is
# read hidden, never echoed or logged, and never passed as a command-line
# argument (that would show in `ps` and shell history). Telegram is called
# with the URL fed to curl on stdin for the same reason.
#
# Before running:
#   1. In Telegram, message @BotFather, send /newbot, follow the prompts.
#      It replies with a token that looks like 123456789:AA...
#   2. Open the new bot and press Start (or send it any message). The script
#      finds your chat id from that message.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
OUT="$(dirname "$SELF")/grafana-telegram-sealed-secret.yml"

# Normal use: run it in a terminal and paste the token at the hidden prompt.
# From the Claude Code "!" box there is no hidden prompt, so the token can be
# given on the command line instead:  bash ~/seal_telegram.sh <token>
# That puts the token in the chat transcript and shell history, so if you
# ever want it gone, send /revoke to @BotFather for a new one and run this
# again.
if [ "${1:-}" != "" ]; then
  TOKEN="$1"
  echo "(token taken from the command line)"
else
  read -rsp "Telegram bot token: " TOKEN
  echo
fi
[ -n "$TOKEN" ] || { echo "empty token, aborting" >&2; exit 1; }

tg() {  # tg <method> [curl args...]  - token goes in on stdin, not argv
  local method="$1"; shift
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TOKEN" "$method" \
    | curl -sS -m 20 -K - "$@"
}
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

ME=$(tg getMe || true)
if [ "$(printf '%s' "$ME" | jget 'print(d.get("ok"))' 2>/dev/null || echo False)" != "True" ]; then
  echo "Telegram rejected the token (or could not be reached). Nothing was written." >&2
  exit 1
fi
BOT=$(printf '%s' "$ME" | jget 'print(d["result"]["username"])')
echo "Token accepted. Bot: @$BOT"

UPD=$(tg getUpdates)
CHAT=$(printf '%s' "$UPD" | jget '
msgs=[u["message"] for u in d.get("result",[]) if "message" in u]
print(msgs[-1]["chat"]["id"] if msgs else "")')
if [ -z "$CHAT" ]; then
  echo "No message found for @$BOT yet. Open it in Telegram, press Start (or send any message), then run this again." >&2
  exit 1
fi
KIND=$(printf '%s' "$UPD" | jget '
msgs=[u["message"] for u in d.get("result",[]) if "message" in u]
c=msgs[-1]["chat"]; print(c.get("type"), c.get("first_name") or c.get("title") or "")')
echo "Found your chat: $KIND"

R=$(tg sendMessage -d "chat_id=$CHAT" --data-urlencode "text=Test from your cluster: alerts will arrive in this chat. If you can read this on your phone, Telegram delivery works.")
[ "$(printf '%s' "$R" | jget 'print(d.get("ok"))')" = "True" ] \
  || { echo "Could not send the test message. Nothing was written." >&2; exit 1; }
echo "Test message sent. Check your phone (close Telegram first if you want to prove it works with the app shut)."

seal() {  # seal <KEY> <value>
  printf '%s' "$2" | kubeseal --raw --scope strict \
    --namespace monitoring --name grafana-telegram --from-file="$1"=/dev/stdin
}
ENC_TOKEN=$(seal TELEGRAM_BOT_TOKEN "$TOKEN")
ENC_CHAT=$(seal TELEGRAM_CHAT_ID "$CHAT")
unset TOKEN

cat > "$OUT" <<YAML
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  creationTimestamp: null
  name: grafana-telegram
  namespace: monitoring
spec:
  encryptedData:
    TELEGRAM_BOT_TOKEN: $ENC_TOKEN
    TELEGRAM_CHAT_ID: $ENC_CHAT
  template:
    metadata:
      creationTimestamp: null
      name: grafana-telegram
      namespace: monitoring
    type: Opaque
YAML
echo "Sealed to: $OUT"
echo "Only encrypted values were written. Now tell Claude it is done."
