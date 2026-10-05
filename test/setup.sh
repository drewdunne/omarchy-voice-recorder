#!/bin/bash

# Tests for ./setup install and uninstall, and for starting a recording,
# against a throwaway HOME with stub omarchy and recorder commands. Uses
# Omarchy's stock menu extension when it is installed. Run from the repository
# root: bash test/setup.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'pkill -f "$WORK/bin/ffmpeg" 2>/dev/null || true; rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_RUNTIME_DIR="$WORK/runtime"
PLUGIN="$HOME/.config/omarchy/plugins/gg.arkship.voice-recorder"
mkdir -p "$HOME/.config/omarchy/extensions" "$WORK/bin" "$XDG_RUNTIME_DIR" "$(dirname "$PLUGIN")"
cp -r "$ROOT" "$PLUGIN"

# Stub commands record how they were called.
for command in omarchy omarchy-shell omarchy-notification-send mpv; do
  cat >"$WORK/bin/$command" <<STUB
#!/bin/bash
echo "$command \$*" >>"$WORK/calls"
STUB
  chmod +x "$WORK/bin/$command"
done

# Nothing is recording, so start rather than refuse.
cat >"$WORK/bin/pgrep" <<'STUB'
#!/bin/bash
exit 1
STUB

# Stands in for the recorder: create the output file (the last argument) the
# way ffmpeg does once capture starts, then keep running.
cat >"$WORK/bin/ffmpeg" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"$WORK/ffmpeg-args"
: >"\${@: -1}"
sleep 5
STUB
chmod +x "$WORK/bin/pgrep" "$WORK/bin/ffmpeg"
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
  [[ $(<"$XDG_RUNTIME_DIR/omarchy-voicerecord-filename") == "$HOME/recordings"/voicerecording-*.m4a ]]
}

# ---------------------------------------------------------------- install
bash "$PLUGIN/setup" install --yes >/dev/null
check "menu block parses" menu_parses
check "menu rows run the plugin's command" grep -qF '/bin/voice-recorder start"' "$MENU"
check "command is linked" test -L "$HOME/.local/bin/voice-recorder"
check "widget is enabled" grep -q "omarchy plugin enable gg.arkship.voice-recorder" "$WORK/calls"

cp "$MENU" "$WORK/once.jsonc"
bash "$PLUGIN/setup" install --yes >/dev/null
check "install twice changes nothing" cmp -s "$WORK/once.jsonc" "$MENU"

# ---------------------------------------------------------------- recording
OMARCHY_VOICERECORD_DIR="$HOME/recordings" "$PLUGIN/bin/voice-recorder" start >/dev/null 2>&1 || true
check "start creates the recordings folder" test -d "$HOME/recordings"
check "start records the default input" grep -qx default "$WORK/ffmpeg-args"
check "start records nothing but audio" grep -qx pulse "$WORK/ffmpeg-args"
check "state file names the recording" state_names_recording
check "start refreshes the bar widget" grep -q "omarchy-shell -q gg.arkship.voice-recorder refresh" "$WORK/calls"
check "start says it is recording" grep -q "Voice recording started" "$WORK/calls"
check "stop with nothing recording fails" bash -c '! "$0" stop' "$PLUGIN/bin/voice-recorder"
pkill -f "$WORK/bin/ffmpeg" 2>/dev/null || true

# ---------------------------------------------------------------- uninstall
bash "$PLUGIN/setup" uninstall --yes >/dev/null
check "uninstall restores the menu" cmp -s "$WORK/original.jsonc" "$MENU"
check "uninstall removes the link" test ! -e "$HOME/.local/bin/voice-recorder"
check "uninstall disables the widget" grep -q "omarchy plugin disable gg.arkship.voice-recorder" "$WORK/calls"

echo "$passed passed, $failed failed"
((failed == 0))
