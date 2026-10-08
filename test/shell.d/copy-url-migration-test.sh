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
  "$test_home/.config/google-chrome"
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
  lock_pid=$dead_pid
  if [[ $profile == "$test_home/.config/google-chrome" ]]; then
    # Simulate a stale lock whose PID has been reused by this unrelated test
    # process. It is live, but its command line does not identify this profile.
    lock_pid=$$
  fi
  ln -s "$hostname-$lock_pid" "$profile/SingletonLock"
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
pass "stale singleton files and a reused PID do not block the shortcut repair"

active_home="$test_tmp/active-lock-home"
active_profile="$active_home/.config/BraveSoftware/Brave-Browser"
socket_path="$test_tmp/brave-SingletonSocket"
ready="$test_tmp/socket-ready"
mkdir -p "$test_tmp/bin"
active_preferences="$active_profile/Default/Preferences"
mkdir -p "$(dirname "$active_preferences")"
cat >"$active_preferences" <<'JSON'
{"extensions":{"commands":{"linux:Alt+Shift+L":{"command_name":"copy-url","extension":"fpogfhkjagaffemmbnnnoklcppehefdo"}},"settings":{"fpogfhkjagaffemmbnnnoklcppehefdo":{"path":"/usr/share/omarchy/default/chromium/extensions/copy-url"}}}}
JSON

python3 - "$socket_path" "$ready" <<'PY' &
import socket
import sys
import time

server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen()
open(sys.argv[2], "w").close()
time.sleep(30)
PY
socket_pid=$!
profile_pid=""
cleanup_socket() {
  kill "$socket_pid" 2>/dev/null || true
  wait "$socket_pid" 2>/dev/null || true
  if [[ -n $profile_pid ]]; then
    kill "$profile_pid" 2>/dev/null || true
    wait "$profile_pid" 2>/dev/null || true
  fi
}
trap 'cleanup_socket; rm -rf "$test_tmp"' EXIT

for attempt in {1..50}; do
  [[ -S $socket_path && -f $ready ]] && break
  sleep 0.1
done
[[ -S $socket_path && -f $ready ]] ||
  fail "the test Brave socket starts"
ln -s "foreign-$hostname-123" "$active_profile/SingletonLock"
ln -s "$socket_path" "$active_profile/SingletonSocket"

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
[[ ! -e $active_preferences.omarchy-copy-url-repair.bak ]] ||
  fail "the migration does not edit the active profile"
pass "a live Brave SingletonSocket blocks repair with a foreign-host lock"

pid_home="$test_tmp/active-pid-home"
pid_profile="$pid_home/.config/chromium"
pid_preferences="$pid_profile/Default/Preferences"
pid_ready="$test_tmp/profile-process-ready"
mkdir -p "$(dirname "$pid_preferences")"
cat >"$pid_preferences" <<'JSON'
{"extensions":{"commands":{"linux:Alt+Shift+L":{"command_name":"copy-url","extension":"fpogfhkjagaffemmbnnnoklcppehefdo"}},"settings":{"fpogfhkjagaffemmbnnnoklcppehefdo":{"path":"/usr/share/omarchy/default/chromium/extensions/copy-url"}}}}
JSON

python3 -c 'import sys, time; open(sys.argv[-1], "w").close(); time.sleep(30)' \
  --user-data-dir "$pid_profile" "$pid_ready" &
profile_pid=$!
for attempt in {1..50}; do
  [[ -f $pid_ready ]] && break
  sleep 0.1
done
[[ -f $pid_ready ]] || fail "the process for the same-host lock starts"
ln -s "$hostname-$profile_pid" "$pid_profile/SingletonLock"

if HOME="$pid_home" OMARCHY_PATH="$ROOT" PATH="$test_tmp/bin:$PATH" \
  TEST_GUM_LOG="$test_tmp/pid-gum.log" \
  bash -euo pipefail "$migration" >"$test_tmp/active-pid.out" 2>&1; then
  kill "$profile_pid" 2>/dev/null || true
  wait "$profile_pid" 2>/dev/null || true
  fail "the migration remains pending when the same-host profile process is live"
fi
kill "$profile_pid" 2>/dev/null || true
wait "$profile_pid" 2>/dev/null || true
grep -q "A running browser would undo the Copy URL shortcut repair" "$test_tmp/active-pid.out" ||
  fail "the same-host PID failure explains why the repair is deferred" "$(cat "$test_tmp/active-pid.out")"
[[ ! -e $pid_preferences.omarchy-copy-url-repair.bak ]] ||
  fail "the migration does not edit the profile identified by the live PID"
[[ ! -e $pid_profile/SingletonSocket ]] ||
  fail "the same-host PID case has no socket to trigger the fallback"
pass "a live same-host PID using the profile blocks repair"
