import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Voice Recorder in the bar. The mic lights up while it records. Left click
// starts or stops a recording, right click opens the recordings folder.
BarWidget {
  id: root
  moduleName: "gg.arkship.voice-recorder"

  readonly property string ctl: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/gg.arkship.voice-recorder/bin/voice-recorder"

  property bool recording: false
  // A refresh asked for while a check is still running, such as the one a
  // starting recording sends, must not be dropped: that check may predate it
  property bool refreshPending: false

  function refresh() {
    if (stateProc.running) {
      root.refreshPending = true
      return
    }
    stateProc.running = true
  }

  function run(args) {
    if (root.bar) root.bar.run(Util.shellQuote(root.ctl) + " " + args)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // bin/voice-recorder calls this after starting or stopping, so every bar
  // updates at once instead of on the next poll.
  IpcHandler {
    target: "gg.arkship.voice-recorder"

    function refresh(): void {
      root.broadcast("refresh")
    }
  }

  // Only this user's recorder, which runs as ffmpeg renamed to
  // omarchy-voicerecorder
  Process {
    id: stateProc
    command: ["bash", "-c", "pgrep --quiet -u \"$UID\" -f '^omarchy-voicerecorder '"]
    onExited: function(exitCode) {
      root.recording = exitCode === 0
      if (root.refreshPending) {
        root.refreshPending = false
        Qt.callLater(root.refresh)
      }
    }
  }

  // Catches a recording that ended on its own, such as ffmpeg exiting when
  // the microphone goes away.
  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF0370)
    active: root.recording
    dimmed: !root.recording
    tooltipText: root.recording
      ? "Recording your mic\nClick to stop and save"
      : "Voice recorder\nClick to record your mic · Right-click for your recordings"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.run(root.recording ? "stop" : "start")
      else if (mouseButton === Qt.RightButton) root.run("open")
    }
  }
}
