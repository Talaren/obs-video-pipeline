# OBS Video Pipeline

Automates post-processing for OBS recordings by date, without re-encoding the video stream.

## What It Does
- Collects `*$DATE*.mkv` from `~/Videos/OBS` in stable sorted order.
- Concatenates segments with stream copy into `merged_YYYY-MM-DD.mkv`.
- Processes audio once for the full session into `processed_audio_YYYY-MM-DD.m4a`.
- Remuxes final MP4 as:
  - `DSA5 mit Marth DD.MM.YYYY final.mp4`
  - Video: `-c:v copy`
  - Audio: `-c:a copy`
  - `-movflags +faststart`

## Usage
- Full default pipeline:
  - `./process_videos.sh 2025-08-28`
- Select stages:
  - `./process_videos.sh -e concat,audio,video,clean 2025-08-28`
- Audio only (auto-runs concat if merged file is missing):
  - `./process_videos.sh -e audio 2025-08-28`
- Video only (requires processed audio):
  - `./process_videos.sh -e video 2025-08-28`
- Set ffmpeg threads:
  - `./process_videos.sh -T 6 2025-08-28`

## Stages
- `concat`: Build `merged_YYYY-MM-DD.mkv` with concat demuxer (`-c copy`).
- `audio`: Run audio filter chain once on merged session.
- `video`: Remux merged video + processed audio into final MP4.
- `clean`: Remove intermediate artifacts.

Default stage order:
- `concat,audio,video,clean`

## Audio Stream Robustness
- 3+ audio streams: full Discord/Foundry/Mic mix profile.
- 2 streams: fallback 2-stream mix.
- 1 stream: single-stream fallback filter.

## Output Layout
- Input:
  - `~/Videos/OBS/*.mkv`
- Output (`~/Videos/OBS/final/`):
  - `merged_YYYY-MM-DD.mkv`
  - `processed_audio_YYYY-MM-DD.m4a`
  - `filelist_mkv.txt`
  - `DSA5 mit Marth DD.MM.YYYY final.mp4`

## Quality & Security Guardrails
- Commit signing via SSH key is enabled.
- `main` branch is protected on GitHub (review required, no force-push/delete).
- Pre-commit hook at `.githooks/pre-commit` (when enabled with `git config core.hooksPath .githooks`) enforces:
  - `shellcheck`
  - `shfmt -d -i 2 -ci`
- Enable hook path locally:
  - `git config core.hooksPath .githooks`
