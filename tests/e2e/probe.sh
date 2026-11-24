#!/usr/bin/env bash
# Fragt während eines Deploys durchgehend /readyz ab und zählt Fehler (Nachweis: keine Unterbrechung).
#   probe.sh start | stop [max-fehler]
set -euo pipefail
DIR=/tmp/factory-probe
case "$1" in
  start)
    rm -rf "$DIR"; mkdir -p "$DIR"
    ( ok=0; fail=0
      while [ ! -f "$DIR/stop" ]; do
        if curl -fsS -m 2 http://127.0.0.1:5101/readyz >/dev/null 2>&1; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
        echo "$ok $fail" > "$DIR/count"
        sleep 0.1
      done ) &
    echo $! > "$DIR/pid"
    ;;
  stop)
    max="${2:-0}"
    touch "$DIR/stop"; wait "$(cat "$DIR/pid")" 2>/dev/null || true; sleep 0.3
    read -r ok fail < "$DIR/count"
    echo "Anfragen während des Deploys: $ok erfolgreich, $fail fehlgeschlagen"
    [ "$ok" -gt 20 ] || { echo "::error::Zu wenige Anfragen gemessen ($ok)"; exit 1; }
    [ "$fail" -le "$max" ] || { echo "::error::$fail Anfragen fehlgeschlagen (erlaubt: $max)"; exit 1; }
    ;;
esac
