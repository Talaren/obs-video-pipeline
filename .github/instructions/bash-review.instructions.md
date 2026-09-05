---
applyTo: "*.sh"
---
# Bash Review Instructions

Review for correctness and safety first, style second.

## Priorities
- Flag functional regressions and data-loss risks before nits.
- Call out missing error handling around file operations and ffmpeg/ffprobe calls.
- Verify changes preserve existing CLI behavior unless explicitly requested.

## Repository-Specific Rules
- `process_videos.sh` is a concat/audio/CPU-video workflow:
  - Keep stage model: `concat,audio,video,upload,clean`.
  - Keep final video on CPU/libx264 with preset `slow` and CRF 18 defaults.
  - Preserve source resolution/frame rate and YouTube-oriented H.264 properties:
    High Profile, `yuv420p`, progressive, two B-frames, closed GOP, BT.709.
  - Keep processed AAC stream-copied into the final MP4 and retain `+faststart`.
- Preserve output naming conventions:
  - `merged_YYYY-MM-DD.mkv`
  - `processed_audio_YYYY-MM-DD.m4a`
  - `DSA5 mit Marth DD.MM.YYYY final.mp4`
- Keep dependency behavior:
  - `audio`/`video` paths must handle missing merged input deterministically.
  - No hidden WhisperX dependency.

## Bash Safety Checklist
- Require robust quoting for paths and variables.
- Prefer arrays for composed CLI args (avoid fragile string splitting).
- Watch for glob side effects and unchecked `rm` patterns.
- Ensure temporary files are cleaned on failures.
- Keep `set -euo pipefail` semantics intact.

## Tooling and Process Expectations
- Pre-commit expectations:
  - `shellcheck` clean for changed shell files.
  - `shfmt -d -i 2 -ci` clean for changed shell files.
- Mention if a change conflicts with branch-protection workflow (changes should be PR-friendly).

## Review Output Style
- Order findings by severity:
  1. blocking bugs/risk
  2. behavior mismatches
  3. maintainability nits
- Include concrete file references and actionable fixes.
