# Voice Recorder

### Record just your mic on Omarchy. No screen recording to throw away.

Omarchy's Capture menu can record your screen with microphone audio, but not your microphone on its own. Voice Recorder adds that: press SUPER + CTRL + C, pick **Voice Recording**, and talk. Stop it from the same menu or by clicking the mic in your bar, and you get an `.m4a` in your Music folder.

It's an [Omarchy](https://omarchy.org/) plugin, so it fits into the desktop you already have:

- **In the Capture menu.** Voice Recording sits next to Screenshot and Screenrecord, and turns into **Stop Recording** while one runs.
- **A light in the bar.** The mic lights up while you're recording, so a recording can't run without you knowing. Click it to start or stop. Right-click it to open your recordings.
- **Sounds like your screen recordings.** It applies the same audio cleanup Omarchy uses for screen recordings: it mutes the click PipeWire makes when the mic opens, then normalizes loudness to -14 LUFS.
- **Uses what's already installed.** It records the default input (the mic Omarchy's screen recorder uses) with ffmpeg through PipeWire. Nothing extra to install.

## Install

```bash
omarchy plugin add https://github.com/drewdunne/omarchy-voice-recorder
~/.config/omarchy/plugins/gg.arkship.voice-recorder/setup install
```

`setup install` adds two entries to Capture in `~/.config/omarchy/extensions/omarchy-menu.jsonc` (it backs the file up first), links `voice-recorder` into `~/.local/bin`, and adds the bar widget next to your indicators. `setup status` shows what's installed. `setup uninstall` undoes all of it.

## Use

| | |
|---|---|
| Start | SUPER + CTRL + C → Voice Recording, click the mic in the bar, or `voice-recorder` |
| Stop and save | SUPER + CTRL + C → Stop Recording, click the lit mic, or `voice-recorder` again |
| Play the last recording | Click the "Voice recording saved" notification, or SUPER + ALT + , |
| Open your recordings | Right-click the mic in the bar, or `voice-recorder open` |

`voice-recorder start`, `stop` and `running` are there for scripts and keybindings. For example, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + R", "Voice recording", "voice-recorder")
```

Recordings are saved as `voicerecording-<date>_<time>.m4a` in your Music folder (`XDG_MUSIC_DIR`, normally `~/Music`). Set `OMARCHY_VOICERECORD_DIR` to save them somewhere else.

To record from a different mic, change your default input: click the audio widget in the bar, or run `pactl set-default-source <name>`.

## Uses on this machine

ffmpeg, PipeWire (with pipewire-pulse), pgrep/pkill, and mpv for playback. All of them come with Omarchy.

## Uninstall

```bash
~/.config/omarchy/plugins/gg.arkship.voice-recorder/setup uninstall
omarchy plugin remove gg.arkship.voice-recorder
```

## Development

```bash
bash test/setup.sh
```

The test runs `setup install` and `setup uninstall`, and starts a recording, in a throwaway HOME with the omarchy commands and ffmpeg replaced by stubs.

## License

MIT
