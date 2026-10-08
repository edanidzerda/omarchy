#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

migration="$ROOT/migrations/1786643346.sh"
test_home="$test_tmp/stale-lock-home"
stale_profiles=(
  "$test_home/.config/chromium"
  "$test_home/.config/BraveSoftware/Brave-Browser"
)
stale_socket_paths=(
  "$test_home/.config/chromium/SingletonSocket"
  "$test_home/.config/BraveSoftware/Brave-Browser/SingletonSocket"
)
stale_preferences=(
  "$test_home/.config/chromium/Default/Preferences"
  "$test_home/.config/BraveSoftware/Brave-Browser/Default/Preferences"
)
hostname=$(</proc/sys/kernel/hostname)
dead_pid=$(($(</proc/sys/kernel/pid_max) + 1))

for profile in "${stale_profiles[@]}"; do
  preferences="$profile/Default/Preferences"
  mkdir -p "$(dirname "$preferences")"
  cat >"$preferences" <<'JSON'
{"extensions":{"commands":{"linux:Alt+Shift+L":{"command_name":"copy-url","extension":"fpogfhkjagaffemmbnnnoklcppehefdo"}},"settings":{"fpogfhkjagaffemmbnnnoklcppehefdo":{"path":"/usr/share/omarchy/default/chromium/extensions/copy-url"}}}}
JSON

  # Chromium-family browsers leave host-PID symlinks and socket paths behind after a crash.
  ln -s "$hostname-$dead_pid" "$profile/SingletonLock"
done

python3 - "${stale_socket_paths[@]}" <<'PY'
import socket
import sys

for path in sys.argv[1:]:
    stale_socket = socket.socket(socket.AF_UNIX)
    stale_socket.bind(path)
    stale_socket.close()
PY

HOME="$test_home" OMARCHY_PATH="$ROOT" \
  bash -euo pipefail "$migration" >"$test_tmp/stale-lock.out" 2>&1 ||
  fail "the migration completes with stale Chromium and Brave singleton files" "$(cat "$test_tmp/stale-lock.out")"

python3 - "${stale_preferences[@]}" <<'PY' || fail "the stale Chromium and Brave profiles' Copy URL shortcuts are repaired"
import json
import sys

for path in sys.argv[1:]:
    with open(path) as preferences_file:
        preferences = json.load(preferences_file)

    command = preferences["extensions"]["commands"]["linux:Alt+Shift+L"]
    assert command["extension"] == "bgpiichlckmfanooecilcjemknkcpngb"
PY
for profile in "${stale_profiles[@]}"; do
  [[ -f $profile/Default/Preferences.omarchy-copy-url-repair.bak ]] ||
    fail "the stale profile $profile gets a repair backup"
done
pass "stale Chromium and Brave singleton files do not block the shortcut repair"

active_home="$test_tmp/active-lock-home"
active_profiles=(
  "$active_home/.config/chromium"
  "$active_home/.config/BraveSoftware/Brave-Browser"
)
socket_paths=("$test_tmp/chromium-SingletonSocket" "$test_tmp/brave-SingletonSocket")
ready="$test_tmp/socket-ready"
mkdir -p "$test_tmp/bin"
for profile in "${active_profiles[@]}"; do
  active_preferences="$profile/Default/Preferences"
  mkdir -p "$(dirname "$active_preferences")"
  cat >"$active_preferences" <<'JSON'
{"extensions":{"commands":{"linux:Alt+Shift+L":{"command_name":"copy-url","extension":"fpogfhkjagaffemmbnnnoklcppehefdo"}},"settings":{"fpogfhkjagaffemmbnnnoklcppehefdo":{"path":"/usr/share/omarchy/default/chromium/extensions/copy-url"}}}}
JSON
done

python3 - "${socket_paths[@]}" "$ready" <<'PY' &
import socket
import sys
import time

servers = []
for path in sys.argv[1:-1]:
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen()
    servers.append(server)
open(sys.argv[-1], "w").close()
time.sleep(30)
PY
socket_pid=$!
cleanup_socket() {
  kill "$socket_pid" 2>/dev/null || true
  wait "$socket_pid" 2>/dev/null || true
}
trap 'cleanup_socket; rm -rf "$test_tmp"' EXIT

for attempt in {1..50}; do
  [[ -S ${socket_paths[0]} && -S ${socket_paths[1]} && -f $ready ]] && break
  sleep 0.1
done
[[ -S ${socket_paths[0]} && -S ${socket_paths[1]} && -f $ready ]] ||
  fail "the test Chromium and Brave sockets start"
ln -s "$hostname-$socket_pid" "${active_profiles[0]}/SingletonLock"
ln -s "${socket_paths[0]}" "${active_profiles[0]}/SingletonSocket"
ln -s "foreign-$hostname-123" "${active_profiles[1]}/SingletonLock"
ln -s "${socket_paths[1]}" "${active_profiles[1]}/SingletonSocket"

cat >"$test_tmp/bin/gum" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_GUM_LOG"
exit 1
SH
chmod +x "$test_tmp/bin/gum"

if HOME="$active_home" OMARCHY_PATH="$ROOT" PATH="$test_tmp/bin:$PATH" \
  TEST_GUM_LOG="$test_tmp/gum.log" \
  bash -euo pipefail "$migration" >"$test_tmp/active-lock.out" 2>&1; then
  fail "the migration remains pending when the browser socket is live"
fi
grep -q "A running browser would undo the Copy URL shortcut repair" "$test_tmp/active-lock.out" ||
  fail "the active-profile failure explains why the repair is deferred" "$(cat "$test_tmp/active-lock.out")"
for profile in "${active_profiles[@]}"; do
  [[ ! -e $profile/Default/Preferences.omarchy-copy-url-repair.bak ]] ||
    fail "the migration does not edit active profile $profile"
done
pass "live Chromium and Brave SingletonSockets block the shortcut repair"
