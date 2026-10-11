#!/bin/bash

# Tests for ./setup install and uninstall, and for recording, against a
# throwaway HOME with stub omarchy and recorder commands. One check hard-kills a
# real ffmpeg writing a synthetic tone; nothing touches a microphone. Uses
# Omarchy's stock menu extension when it is installed. Run from the repository
# root: bash test/setup.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)

# Stubs below replace these, so keep the real ones for the test itself
REAL_PGREP=$(command -v pgrep)
REAL_PKILL=$(command -v pkill)
REAL_FFMPEG=$(command -v ffmpeg)
REAL_FFPROBE=$(command -v ffprobe)
REAL_DATE=$(command -v date)
ORIGINAL_PATH=$PATH

cleanup() {
  "$REAL_PKILL" -9 -f "$WORK/" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_RUNTIME_DIR="$WORK/runtime"
export OMARCHY_VOICERECORD_DIR="$HOME/recordings"
PLUGIN="$HOME/.config/omarchy/plugins/gg.arkship.voice-recorder"
VR="$PLUGIN/bin/voice-recorder"
STATE="$XDG_RUNTIME_DIR/omarchy-voicerecord-filename"
mkdir -p "$HOME/.config/omarchy/extensions" "$WORK/bin" "$XDG_RUNTIME_DIR" "$(dirname "$PLUGIN")"
cp -r "$ROOT" "$PLUGIN"

# Stub commands record how they were called.
for command in omarchy omarchy-shell omarchy-notification-send mpv; do
  cat >"$WORK/bin/$command" <<STUB
#!/bin/bash
echo "$command \$*" >>"$WORK/calls"
STUB
done

# The recorder counts as running while the process the capture stub recorded is
# alive. Anything but a lookup limited to this user's recorder is a bug.
cat >"$WORK/bin/pgrep" <<STUB
#!/bin/bash
if [[ "\$*" != "-u \$UID -f ^omarchy-voicerecorder " ]]; then
  echo "pgrep \$*" >>"$WORK/stub-errors"
  exit 2
fi
[[ -s "$WORK/recorder-pid" ]] && kill -0 "\$(<"$WORK/recorder-pid")" 2>/dev/null
STUB

# A bash stub can't trap the SIGINT its background launch ignores, so SIGINT is
# delivered as TERM, which the capture stub treats the way ffmpeg treats SIGINT
cat >"$WORK/bin/pkill" <<STUB
#!/bin/bash
if [[ "\${*:2}" != "-u \$UID -f ^omarchy-voicerecorder " ]]; then
  echo "pkill \$*" >>"$WORK/stub-errors"
  exit 2
fi
echo "pkill \$1" >>"$WORK/calls"
case \$1 in
-SIGINT) kill -TERM "\$(<"$WORK/recorder-pid")" ;;
-9) kill -9 "\$(<"$WORK/recorder-pid")" ;;
esac
STUB

# Stands in for every ffmpeg run. The capture (-f pulse) creates its output
# file (the last argument) once it "has the microphone", unless it stalls, and
# runs until signalled; a hanging one ignores the stop. The cleanup can wait at
# a gate, can produce nothing, or can fail its loudness pass (-af) the way
# loudnorm does on a clip too short or quiet to measure.
cat >"$WORK/bin/ffmpeg" <<STUB
#!/bin/bash
if [[ " \$* " != *" pulse "* ]]; then
  printf '%s\n' "\$@" >"$WORK/finalize-args"
  echo finalize-begin >>"$WORK/order"
  if [[ -n \${TEST_FINALIZE_GATE:-} ]]; then
    for _ in {1..400}; do
      [[ -e \$TEST_FINALIZE_GATE ]] && break
      sleep 0.05
    done
  fi
  echo finalize-end >>"$WORK/order"
  case \${TEST_FINALIZE:-} in
  empty) exit 0 ;;
  unmeasurable) [[ " \$* " == *" -af "* ]] && exit 234 ;;
  esac
  if [[ " \$* " == *" -af "* ]]; then
    echo processed >"\${@: -1}"
  else
    echo remuxed >"\${@: -1}"
  fi
  exit 0
fi

printf '%s\n' "\$@" >"$WORK/ffmpeg-args"
echo \$\$ >"$WORK/recorder-pid"
echo capture >>"$WORK/order"
if [[ \${TEST_RECORDER:-} == hangs ]]; then
  trap '' TERM
else
  trap 'exit 0' TERM
fi
[[ \${TEST_RECORDER:-} == stalls ]] || : >"\${@: -1}"
while :; do
  sleep 0.1
done
STUB

# The cleanup output has audio when the cleanup stub wrote it
cat >"$WORK/bin/ffprobe" <<'STUB'
#!/bin/bash
if [[ -s ${@: -1} && $(<"${@: -1}") == @(processed|remuxed) ]]; then
  echo 1
else
  echo 0
fi
STUB

# Pins the timestamp in recording names when a test asks for it
cat >"$WORK/bin/date" <<STUB
#!/bin/bash
if [[ -n \${TEST_DATE:-} ]]; then
  echo "\$TEST_DATE"
else
  exec "$REAL_DATE" "\$@"
fi
STUB

chmod +x "$WORK/bin"/*
export PATH="$WORK/bin:$PATH"

MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [[ -f /usr/share/omarchy/config/omarchy/extensions/omarchy-menu.jsonc ]]; then
  cp /usr/share/omarchy/config/omarchy/extensions/omarchy-menu.jsonc "$MENU"
else
  printf '{\n  // "personal": {"label":"Personal"},\n}\n' >"$MENU"
fi
cp "$MENU" "$WORK/original.jsonc"

passed=0
failed=0

check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $name"
  fi
}

# A deadlock fails the test instead of hanging it
vr() {
  timeout 30 "$VR" "$@"
}

reset_logs() {
  rm -f "$WORK/calls" "$WORK/ffmpeg-args" "$WORK/finalize-args" "$WORK/order"
}

recorder_gone() {
  ! { [[ -s $WORK/recorder-pid ]] && kill -0 "$(<"$WORK/recorder-pid")" 2>/dev/null; }
}

wait_for_line() {
  for _ in {1..100}; do
    grep -qx -- "$1" "$2" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

# Omarchy's menu drops whole-line // comments and trailing commas, then parses
# JSON. Do the same here, without node.
menu_parses() {
  python3 - "$MENU" <<'PY'
import json, re, sys
raw = open(sys.argv[1]).read()
raw = re.sub(r"(?m)^\s*//[^\n]*(\n|$)", "", raw)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
items = json.loads(raw)
want = {"trigger.capture.voicerecord", "trigger.capture.voicerecord-stop"}
sys.exit(0 if want <= set(items) else 1)
PY
}

state_names_recording() {
  [[ $(<"$STATE") == "$HOME/recordings"/voicerecording-*.m4a && -f $(<"$STATE") ]]
}

saved_is_processed() {
  [[ -n $SAVED && $SAVED == "$RECORDING" && $(<"$SAVED") == processed ]]
}

only_recordings_left() {
  ! ls -A "$HOME/recordings" | grep -q '^\.'
}

packets() {
  "$REAL_FFPROBE" -v error -select_streams a -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$1"
}

# ---------------------------------------------------------------- install
bash "$PLUGIN/setup" install --yes >/dev/null
check "menu block parses" menu_parses
check "menu rows run the plugin's command" grep -qF '/bin/voice-recorder start"' "$MENU"
check "menu rows only see this user's recorder" grep -qF "\"when\":\"pgrep -u \$UID -f '^omarchy-voicerecorder '\"" "$MENU"
check "command is linked" test -L "$HOME/.local/bin/voice-recorder"
check "widget is enabled" grep -q "omarchy plugin enable gg.arkship.voice-recorder" "$WORK/calls"

cp "$MENU" "$WORK/once.jsonc"
bash "$PLUGIN/setup" install --yes >/dev/null
check "install twice changes nothing" cmp -s "$WORK/once.jsonc" "$MENU"

# ---------------------------------------------------------------- start
reset_logs
vr start >/dev/null 2>&1 || true
check "start creates the recordings folder" test -d "$HOME/recordings"
check "start records the default input" grep -qx default "$WORK/ffmpeg-args"
check "start records nothing but audio" grep -qx pulse "$WORK/ffmpeg-args"
check "start writes flushed fragments" grep -qx -- -flush_packets "$WORK/ffmpeg-args"
check "start never overwrites a file" grep -qx -- -n "$WORK/ffmpeg-args"
check "state file names the recording" state_names_recording
check "start refreshes the bar widget" grep -q "omarchy-shell -q gg.arkship.voice-recorder refresh" "$WORK/calls"
check "start says it is recording" grep -q "Voice recording started" "$WORK/calls"
RECORDING=$(<"$STATE")

# ---------------------------------------------------------------- stop
reset_logs
SAVED=$(vr stop 2>/dev/null) || true
check "stop sends the recorder SIGINT and nothing harsher" grep -qx "pkill -SIGINT" "$WORK/calls"
check "stop does not force-kill a recorder that stops" bash -c '! grep -q "pkill -9" "$0"' "$WORK/calls"
check "stop ends the recorder" recorder_gone
check "the cleanup never reads the terminal" grep -qx -- -nostdin "$WORK/finalize-args"
check "stop saves the cleaned-up recording" saved_is_processed
check "stop leaves no intermediate file" only_recordings_left
check "stop removes the state file" test ! -e "$STATE"
check "stop says it saved" grep -q "Voice recording saved" "$WORK/calls"
check "stop refreshes the bar widget" grep -q "omarchy-shell -q gg.arkship.voice-recorder refresh" "$WORK/calls"

# ---------------------------------------------------------------- same second
export TEST_DATE="2026-01-01_00-00-00"
vr start >/dev/null 2>&1 || true
FIRST=$(<"$STATE")
vr stop >/dev/null 2>&1 || true
reset_logs
vr start >/dev/null 2>&1 || true
SECOND=$(<"$STATE")
check "a restart within the same second gets a new name" test "$SECOND" != "$FIRST"
check "a restart within the same second really records" grep -q "Voice recording started" "$WORK/calls"
check "a restart within the same second keeps the first recording" grep -qx processed "$FIRST"
vr stop >/dev/null 2>&1 || true
unset TEST_DATE

# ---------------------------------------------------------------- sidecar
vr start >/dev/null 2>&1 || true
RECORDING=$(<"$STATE")
echo untouched >"$WORK/canary"
ln -s "$WORK/canary" "${RECORDING%.m4a}-processed.m4a"
vr stop >/dev/null 2>&1 || true
check "the cleanup never writes through a file it didn't create" grep -qx untouched "$WORK/canary"
rm -f "${RECORDING%.m4a}-processed.m4a"

# ---------------------------------------------------------------- state write
reset_logs
mkdir "$STATE"
check "a start whose state can't be saved fails" bash -c '! timeout 30 "$0" start' "$VR"
check "a start whose state can't be saved ends its recorder" recorder_gone
rmdir "$STATE"

# ---------------------------------------------------------------- force-kill
TEST_RECORDER=hangs vr start >/dev/null 2>&1 || true
RECORDING=$(<"$STATE")
reset_logs
SAVED=$(vr stop 2>/dev/null) || true
check "a recorder that ignores SIGINT is force-killed" grep -qx "pkill -9" "$WORK/calls"
check "force-killing ends the recorder" recorder_gone
check "force-killing says so" grep -q "Voice recording force-stopped" "$WORK/calls"
check "a force-killed recording is still saved" saved_is_processed

# ---------------------------------------------------------------- failed cleanup
vr start >/dev/null 2>&1 || true
RECORDING=$(<"$STATE")
echo "as recorded" >"$RECORDING"
reset_logs
check "a cleanup that produces no audio is a failure" bash -c '! TEST_FINALIZE=empty timeout 30 "$0" stop' "$VR"
check "a failed cleanup keeps the recording as recorded" grep -qx "as recorded" "$RECORDING"
check "a failed cleanup leaves no intermediate file" only_recordings_left
check "a failed cleanup says the recording may be damaged" grep -q "Voice recording may be damaged" "$WORK/calls"
check "a failed cleanup is not announced as saved" bash -c '! grep -q "Voice recording saved" "$0"' "$WORK/calls"

# ---------------------------------------------------------------- unmeasurable
vr start >/dev/null 2>&1 || true
RECORDING=$(<"$STATE")
reset_logs
check "a recording too short to measure is saved" bash -c 'TEST_FINALIZE=unmeasurable timeout 30 "$0" stop' "$VR"
check "a recording too short to measure is kept as recorded" grep -qx remuxed "$RECORDING"
check "a recording too short to measure is announced as saved" grep -q "Voice recording saved" "$WORK/calls"

# ---------------------------------------------------------------- stalled start
reset_logs
check "a recorder that never gets the mic is a failed start" bash -c '! TEST_RECORDER=stalls timeout 30 "$0" start' "$VR"
check "a stalled recorder is ended" recorder_gone
check "a stalled start leaves no state" test ! -e "$STATE"
check "a stalled start says so" grep -q "Voice recording failed to start" "$WORK/calls"
set +e
timeout 5 "$VR" stop >/dev/null 2>&1
stop_status=$?
set -e
check "a stalled start releases the lock" test "$stop_status" -eq 1

# ---------------------------------------------------------------- overlap
vr start >/dev/null 2>&1 || true
FIRST=$(<"$STATE")
reset_logs
TEST_FINALIZE_GATE="$WORK/gate" vr stop >"$WORK/first-saved" 2>/dev/null &
stop_pid=$!
wait_for_line finalize-begin "$WORK/order" || true
vr start >/dev/null 2>&1 &
start_pid=$!
if wait_for_line capture "$WORK/order"; then
  early=true
else
  early=false
fi
touch "$WORK/gate"
wait "$stop_pid" || true
wait "$start_pid" || true
check "a start during a save waits for it" test "$early" == false
check "a start during a save runs after it" test "$(paste -sd' ' "$WORK/order")" == "finalize-begin finalize-end capture"
check "the overlapped stop saves its own recording" test "$(<"$WORK/first-saved")" == "$FIRST"
check "the waiting start keeps its own state" bash -c '[[ -s $0 && $(<"$0") != "$1" ]]' "$STATE" "$FIRST"
vr stop >/dev/null 2>&1 || true

# ---------------------------------------------------------------- idle
reset_logs
check "stop with nothing recording fails" bash -c '! timeout 30 "$0" stop' "$VR"
check "stop with nothing recording clears a stale bar" grep -q "omarchy-shell -q gg.arkship.voice-recorder refresh" "$WORK/calls"
check "every recorder lookup and signal is limited to this user's recorder" test ! -s "$WORK/stub-errors"

# ---------------------------------------------------------------- real audio
# Hard-kill a real ffmpeg writing a synthetic tone with the recorder's fragment
# settings, then stop it through the command with the real ffmpeg cleanup.
eval "$(sed -n 's/^\(FRAGMENT_ARGS=(.*)\)$/\1/p' "$VR")"
SYNTHETIC="$HOME/recordings/voicerecording-synthetic.m4a"
"$REAL_FFMPEG" -nostdin -hide_banner -loglevel error -re -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -c:a aac "${FRAGMENT_ARGS[@]}" "$SYNTHETIC" &
synthetic_pid=$!
sleep 3
kill -9 "$synthetic_pid"
wait "$synthetic_pid" 2>/dev/null || true
check "a hard-killed recording still decodes" test "$(packets "$SYNTHETIC")" -gt 47

mkdir -p "$WORK/real-bin"
cp "$WORK/bin"/{pgrep,pkill,omarchy-shell,omarchy-notification-send} "$WORK/real-bin/"
bash -c 'trap "exit 0" TERM; while :; do sleep 0.1; done' &
echo $! >"$WORK/recorder-pid"
echo "$SYNTHETIC" >"$STATE"
reset_logs
PATH="$WORK/real-bin:$ORIGINAL_PATH" timeout 60 "$VR" stop >/dev/null 2>&1 || true
check "a hard-killed recording is cleaned up and saved" grep -q "Voice recording saved" "$WORK/calls"
check "the cleaned-up recording decodes" test "$(packets "$SYNTHETIC")" -gt 47
check "the cleaned-up recording is a regular .m4a" bash -c '! LC_ALL=C grep -a -q moof "$0"' "$SYNTHETIC"

# A second of silence is too quiet for loudnorm, so the real cleanup has to
# fall back to keeping it as recorded
QUIET="$HOME/recordings/voicerecording-quiet.m4a"
"$REAL_FFMPEG" -nostdin -hide_banner -loglevel error -f lavfi -i "anullsrc=r=48000:cl=stereo" -t 1 \
  -c:a aac "${FRAGMENT_ARGS[@]}" "$QUIET"
bash -c 'trap "exit 0" TERM; while :; do sleep 0.1; done' &
echo $! >"$WORK/recorder-pid"
echo "$QUIET" >"$STATE"
reset_logs
PATH="$WORK/real-bin:$ORIGINAL_PATH" timeout 60 "$VR" stop >/dev/null 2>&1 || true
check "a short silent recording is saved" grep -q "Voice recording saved" "$WORK/calls"
check "a short silent recording decodes" test "$(packets "$QUIET")" -gt 0
check "a short silent recording is a regular .m4a" bash -c '! LC_ALL=C grep -a -q moof "$0"' "$QUIET"

# ---------------------------------------------------------------- leftovers
check "no recorder stub outlives the tests" bash -c '! "$0" -f "$1"' "$REAL_PGREP" "$WORK/bin/[f]fmpeg"

# ---------------------------------------------------------------- uninstall
bash "$PLUGIN/setup" uninstall --yes >/dev/null
check "uninstall restores the menu" cmp -s "$WORK/original.jsonc" "$MENU"
check "uninstall removes the link" test ! -e "$HOME/.local/bin/voice-recorder"
check "uninstall disables the widget" grep -q "omarchy plugin disable gg.arkship.voice-recorder" "$WORK/calls"

echo "$passed passed, $failed failed"
((failed == 0))
