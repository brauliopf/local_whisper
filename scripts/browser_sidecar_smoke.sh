#!/bin/sh
set -eu

sidecar_dir="${SIDECAR_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../browser-sidecar" && pwd)}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/local-whisper-sidecar.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
fifo="$tmp_dir/input"
output="$tmp_dir/output"
mkfifo "$fifo"

node "$sidecar_dir/dist/server.js" <"$fifo" >"$output" 2>"$tmp_dir/error" &
pid=$!
exec 3>"$fifo"

send() {
  printf '%s\n' "$1" >&3
  sleep 1
}

session="smoke-session"
send "{\"id\":\"start\",\"version\":1,\"session_id\":\"$session\",\"deadline_ms\":$(($(date +%s) * 1000 + 30000)),\"type\":\"start\"}"
send "{\"id\":\"pause\",\"version\":1,\"session_id\":\"$session\",\"deadline_ms\":$(($(date +%s) * 1000 + 30000)),\"type\":\"pause\"}"
send "{\"id\":\"snapshot\",\"version\":1,\"session_id\":\"$session\",\"deadline_ms\":$(($(date +%s) * 1000 + 30000)),\"type\":\"snapshot\"}"
send "{\"id\":\"resume\",\"version\":1,\"session_id\":\"$session\",\"deadline_ms\":$(($(date +%s) * 1000 + 30000)),\"type\":\"resume\"}"
send "{\"id\":\"stop\",\"version\":1,\"session_id\":\"$session\",\"deadline_ms\":$(($(date +%s) * 1000 + 30000)),\"type\":\"stop\"}"
exec 3>&-
wait "$pid"

grep -q '"id":"start","version":1,"session_id":"smoke-session","ok":true,"status":"running"' "$output"
grep -q '"id":"pause","version":1,"session_id":"smoke-session","ok":true,"status":"paused"' "$output"
grep -q '"id":"snapshot","version":1,"session_id":"smoke-session","ok":true,"status":"paused"' "$output"
grep -q '"id":"resume","version":1,"session_id":"smoke-session","ok":true,"status":"running"' "$output"
grep -q '"id":"stop","version":1,"session_id":"smoke-session","ok":true,"status":"stopped"' "$output"
