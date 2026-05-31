# ASRBar

> A tiny floating macOS panel that turns your voice into text via [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B), served by vLLM. One Swift file. No Xcode project.

[简体中文](README.zh.md) · English

<p align="center">
  <img src="Screenshot.jpg" alt="ASRBar panel" width="500">
</p>

ASRBar lives on top of every window. Tap the mic (or hold **Space**) — speak — release. The transcript lands in your clipboard, ready to paste anywhere.

![panel idle](https://img.shields.io/badge/macOS-13%2B-orange) ![swift](https://img.shields.io/badge/Swift-5.9%2B-orange) ![license](https://img.shields.io/badge/license-Apache_2.0-blue)

## Why

I've been doing a lot of coding with Claude Code lately, and the typing was wearing me out — but its built-in voice input only seems to handle English well. Around the same time Qwen released a speech-recognition model, and I was curious to see how good LLM-based ASR actually is, so I threw this little tool together. I also didn't want a clunky browser-based UI, so I had Claude Code write me a native Mac app instead.

## Features

- **Two mics, one panel.** Left mic = fresh take. Right mic (`+`) = append to the previous result — so you can dictate a paragraph in passes without re-recording.
- **Hold-to-talk on Space.** Press-and-hold dictation, like a walkie-talkie. Smart default: continues the last result if there is one, otherwise starts fresh.
- **Auto-resizing card.** The result card grows to fit the transcript and shrinks back when you clear it. The top edge stays pinned so the panel doesn't jump.
- **Editable transcript.** Fix a misrecognized word in place; the new text is what gets copied.
- **Live VU meter** around the active mic while recording.
- **Auto language detection** by Qwen3-ASR itself — no system prompt, no language hint needed.
- **Always-on-top floating panel** that joins all Spaces and survives full-screen apps.

## Architecture

```
┌─────────────────────┐    16 kHz mono WAV    ┌──────────────────────┐
│  ASRBar (SwiftUI)   │  ───────────────────▶ │  vLLM + Qwen3-ASR    │
│  AVAudioRecorder    │  base64 in audio_url  │  /v1/chat/completions│
│  NSPanel, floating  │  ◀───────────────────  │                      │
└─────────────────────┘     transcript text   └──────────────────────┘
```

The client speaks OpenAI-compatible `chat/completions` — Qwen3-ASR is invoked as a single user message with one `audio_url` content part. The model emits `language XX <asr_text>...</asr_text>`; ASRBar strips the wrapper before showing/copying.

## Requirements

- macOS 13.0 or newer (Apple Silicon or Intel)
- Xcode Command Line Tools (`xcode-select --install`) — `swiftc`, `codesign`, `iconutil`, `sips`
- A reachable vLLM server hosting Qwen3-ASR (next section)

## 1 — Start the ASR server

Install the official Qwen3-ASR launcher (it wraps `vllm serve`):

```bash
pip install qwen-asr
```

Pick a model size:

| Model | Params | VRAM (BF16, rough) | Notes |
|---|---|---|---|
| `Qwen/Qwen3-ASR-0.6B` | 0.6B | ~3 GB | Lightweight, fast |
| `Qwen/Qwen3-ASR-1.7B` | 1.7B | ~6 GB | Highest accuracy |

Serve it:

```bash
qwen-asr-serve Qwen/Qwen3-ASR-0.6B \
    --gpu-memory-utilization 0.8 \
    --host 0.0.0.0 \
    --port 8000
```

That's it — the server now answers `POST /v1/chat/completions` on `:8000`.

> ASRBar uses HTTP (not HTTPS) by default, since the typical setup is a LAN box. The bundled `Info.plist` allows arbitrary HTTP loads. If you put the server behind TLS, point ASRBar at the `https://` URL.

## 2 — Build the app

```bash
git clone https://github.com/zdy1995love/ASRBar.git
cd ASRBar
./build.sh
open ASRBar.app
# or, to install:
cp -R ASRBar.app /Applications/
```

`build.sh` does the full bundle in one pass:

1. Generates `AppIcon.icns` from `Qwen.png` (all Retina sizes).
2. Writes a self-contained `Info.plist` (mic permission + ATS exception for plain HTTP).
3. Compiles `ASRBar.swift` with `swiftc -O`.
4. Ad-hoc codesigns the bundle (required for AVFoundation mic access on modern macOS).

No Xcode project file, no SPM manifest, no derived data. The whole `.app` is one binary plus an icon.

## 3 — Point ASRBar at your server

Launch ASRBar, click the small gear icon and set:

- **Endpoint** — `http://your-host:8000/v1/chat/completions`
- **Model** — whichever model id you served (e.g. `Qwen/Qwen3-ASR-0.6B`)

Settings persist via `@AppStorage` (`UserDefaults`).

## Usage

| Action | What happens |
|---|---|
| Click left mic 🎤 | Start a fresh recording. Click again (or stop button) to transcribe. |
| Click right mic 🎤+ | Start a recording that will be appended to the existing result. Disabled when there is no previous result. |
| Hold **Space** | Press-and-hold dictation. Append mode auto-engages if there's already a transcript. |
| Click the result | Edit it in place — the corrected text is what gets copied. |
| Copy button | Copy the current result to the clipboard. (It's already copied automatically after each transcription.) |
| Drag the panel anywhere | Reposition. The panel is movable by its background. |

## How the audio is sent

```jsonc
POST /v1/chat/completions
{
  "model": "Qwen/Qwen3-ASR-0.6B",
  "temperature": 0.01,
  "messages": [{
    "role": "user",
    "content": [{
      "type": "audio_url",
      "audio_url": { "url": "data:audio/wav;base64,UklGRiQAAA..." }
    }]
  }]
}
```

- 16 kHz mono PCM WAV, base64-encoded as a `data:` URL — no file upload step.
- `temperature: 0.01` because vLLM rejects values below `0.01`.
- No system prompt — Qwen3-ASR detects the spoken language on its own and labels its output (`language en <asr_text>...</asr_text>`), which ASRBar strips before displaying.

If you want to force a target language, you can add a `system` message such as `"Please transcribe in Japanese."` — see the Qwen3-ASR model card for the full set of supported languages (30 languages + 22 Chinese dialects).

## Privacy

ASRBar talks to **exactly one URL** — the endpoint you configured. There is no telemetry, no analytics, no background traffic. Audio is captured by `AVAudioRecorder` straight to a temp `.wav` and POSTed to that URL. The recording stays on disk only until the next transcription.

## Project layout

```
ASRBar/
├── ASRBar.swift     ← the whole app: panel, recorder, ASR client, UI
├── build.sh         ← icon + Info.plist + swiftc + codesign
├── Qwen.png         ← source image for AppIcon.icns
├── README.md
├── README.zh.md
└── LICENSE
```

That's the entire repository.

## Troubleshooting

**No mic prompt on first launch.** macOS only asks for mic permission when an app actually tries to record. Click the mic button once — the prompt appears, accept it, then re-click. If you previously denied it, fix it in *System Settings → Privacy & Security → Microphone*.

**`HTTP 400: temperature must be >= 0.01`.** You're hitting a vLLM build that's stricter than ours expected — ASRBar already sends `0.01`. Update vLLM.

**`HTTP 404`.** Your endpoint path is wrong. It must end in `/v1/chat/completions`, not just `/v1`.

**Transcript comes back with `language xx <asr_text>...`.** ASRBar should strip that prefix automatically. If it doesn't, the model returned an unexpected shape — file an issue with a sample response.

**Panel comes back at a weird size.** macOS Resume is disabled in `ASRBar`, but if you launched an older build it may have written a saved frame. Run `defaults delete com.qwen3asr.ASRBar` and relaunch.

## Credits

- **[Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)** by the Qwen team — the model doing all the actual recognition. Apache 2.0.
- **[vLLM](https://github.com/vllm-project/vllm)** — the serving engine.

## License

[Apache 2.0](LICENSE).
