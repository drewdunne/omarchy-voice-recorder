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

  function refresh() {
    if (!stateProc.running) stateProc.running = true
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

  // The recorder runs as ffmpeg renamed to omarchy-voicerecorder.
  Process {
    id: stateProc
    command: ["pgrep", "--quiet", "-f", "^omarchy-voicerecorder "]
    onExited: function(exitCode) {
      root.recording = exitCode === 0
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
