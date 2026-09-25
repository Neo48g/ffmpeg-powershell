## FFmpeg interactive console toolkit for Windows, written in PowerShell, that combines the capabilities of FFmpeg, ffprobe, and yt-dlp into a single menu.

<img width="515" height="355" alt="image" src="https://github.com/user-attachments/assets/92e1efcd-3930-4787-9c4a-d384a041e2c0" /><img width="515" height="355" alt="image" src="https://github.com/user-attachments/assets/2ff441ee-048f-428e-9661-944cef5368c6" />

<img width="660" height="746" alt="ffmpeg3" src="https://github.com/user-attachments/assets/d6e7e007-59cf-4a23-92c1-43b1c78621fd" />

### Features
- Compress video with CPU and GPU.
- Convert video, images, and audio.
- Trim video by timecode.
- Download video, audio, playlists, and video fragments.
- Install and update tools from the menu.
- Video quality check using VMAF.
- Automatic CRF reduction if quality is insufficient.
#### Manage dependencies, presets, logs.
use RUN_HUB.bat

### Project structure
| File | Description |
|------|-------------|
| `RUN_HUB.bat` | Main launcher — opens the interactive hub menu |
| `ffmpeg_hub.ps1` | Hub: tool menu, dependency installer, global settings, help |
| `common.ps1` | Shared module: config (`global_config.json`), localization EN/RU, UI helpers, tools/ PATH & tool discovery |
| `compress_video.ps1` | Batch video compression (CPU/GPU, VMAF, Auto-CRF, presets) |
| `convert-media.ps1` | Converter for video / image / audio formats |
| `trim-video.ps1` | Trim video by timecode (fast stream-copy or exact re-encode) |
| `yt-dlp-menu.ps1` | Downloader: video, audio, playlists, fragments (cookies support) |
| `run_*.bat` | Standalone launchers for each tool |
| `oldver/` | Archive of previous versions (v1–v6) |

Runtime-generated files (gitignored): `global_config.json`, `presets.json`, `logs/`, `tools/`.

### Dependent
- FFmpeg - compress, trim, convert media
- yt-dlp - downland media
- Node.js - for correctly working yt-dlp
All three can be installed/updated right from the hub menu (item 5) into the local `tools/` folder — no admin rights required.
