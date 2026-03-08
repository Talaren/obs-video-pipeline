# Repository Guidelines

## Project Structure & Module Organization
- Root scripts:
  - `process_videos.sh` (main pipeline)
  - `yt_upload.sh` (YouTube upload wrapper)
  - `yt_upload.py` (YouTube Data API uploader)
- Inputs: `~/Videos/OBS/*.mkv` (date contained in filename).
- Outputs: `~/Videos/OBS/final/`
  - Merged session: `merged_YYYY-MM-DD.mkv`
  - Processed audio: `processed_audio_YYYY-MM-DD.m4a`
  - Concat list: `filelist_mkv.txt`
  - Final: `DSA5 mit Marth DD.MM.YYYY final.mp4`

## Build, Test, and Development Commands
- Run pipeline (default stages: concat,audio,video,clean): `./process_videos.sh 2025-08-28`
- Select stages: `./process_videos.sh -e concat,audio,video,clean 2025-08-28`
- Include upload explicitly: `./process_videos.sh -e concat,audio,video,upload,clean 2025-08-28`
- Audio only (auto-concat if merged file is missing): `./process_videos.sh -e audio -m balanced 2025-08-28`
- Video only (auto-runs audio when processed audio is missing): `./process_videos.sh -e video 2025-08-28`
- Upload only (requires final MP4 or auto-builds missing prerequisites): `./process_videos.sh -e upload 2025-08-28`
- Set ffmpeg threads: `./process_videos.sh -T 6 2025-08-28`
- Mix profile: `./process_videos.sh -m voice-priority 2025-08-28`
- Lint Bash: `shellcheck process_videos.sh`
- Format Bash: `shfmt -w -i 2 -ci process_videos.sh`
- Python upload deps (local venv): `python3 -m venv .venv-youtube-upload && .venv-youtube-upload/bin/pip install google-api-python-client google-auth-oauthlib google-auth-httplib2`

## Coding Style & Naming Conventions
- Languages:
  - Bash scripts: `set -euo pipefail`
  - Python: keep code straightforward and typed where useful
- Indentation: 2 spaces; no tabs.
- Names: UPPER_CASE for constants/flags; lower_snake_case for functions.
- Logs: use `log_msg "message"`.
- Filenames: keep existing patterns (`merged_YYYY-MM-DD.mkv`, `processed_audio_YYYY-MM-DD.m4a`, final name with date).

## Testing Guidelines
- Smoke test: run with a small sample MKV and `-e concat,audio,video` to verify outputs.
- Audio stream contract: exactly 3 audio streams are required; verify failure message for non-3 stream layouts.
- Mix profile checks: test both `-m balanced` and `-m voice-priority`.
- Idempotence: rerun stages; ensure no unexpected overwrites.
- Dependency behavior:
  - `-e audio` and `-e video` auto-run concat when `merged_YYYY-MM-DD.mkv` is absent.
  - `-e video` auto-runs audio when processed audio is missing.
  - `-e upload` auto-builds missing prerequisites up to final MP4.
- Upload behavior: verify clear error when OAuth client secrets are missing.
- Linting: `shellcheck` must pass with no errors; fix warnings when feasible.

## Commit & Pull Request Guidelines
- Commits: use Conventional Commits (e.g., `feat: add thread option`, `fix: handle missing audio`).
- PRs: include summary, rationale, example command(s), and before/after behavior. Add logs or output snippets when relevant.

## Security & Configuration Tips
- Shutdown/notify: use `-s` (shutdown) and `-n` (notify) carefully; default is no side-effects.
- Performance: ffmpeg uses stream copy for concat/remux; option `-T` sets threads for ffmpeg calls.
- Video handling: OBS video is not re-encoded; pipeline does concat/copy to `merged_YYYY-MM-DD.mkv`, then final remux with `-c:v copy -c:a copy -movflags +faststart`.
- Audio processing: runs once on merged session and expects strict stream mapping:
  - `a:0` discord
  - `a:1` foundry
  - `a:2` own voice
  - No fallback path for 1/2 streams.
- Mix profile:
  - `balanced` (default): clear speech with moderate ducking.
  - `voice-priority`: stronger speech focus and stronger ducking of foundry.
- YouTube upload:
  - Default upload client is `./yt_upload.sh` (wrapper over `yt_upload.py` with Google API).
  - Privacy is `unlisted`.
  - Requires OAuth desktop client secrets at `~/.config/yt-upload/client_secrets.json`.
  - Token is cached at `~/.config/yt-upload/token.json`.
  - Base scope is `youtube.upload`; playlist insertion requires an additional YouTube scope.
  - `YOUTUBE_UPLOAD_TAGS` sets comma-separated tags.
  - `YOUTUBE_UPLOAD_PLAYLIST_ID` adds uploaded video to a playlist.
  - `YOUTUBE_UPLOAD_PLAYLIST_POSITION` optionally sets insertion index in that playlist.
  - Extra uploader args are passed via newline-separated `YOUTUBE_UPLOAD_EXTRA_ARGS`.
- Cleanup: `clean` removes current workflow artifacts (`merged_*`, `processed_audio_*`, `filelist_mkv.txt`) and legacy per-segment artifacts for the selected date (`*_piece.mp4`, `*_processed_audio.m4a`, `filelist.txt`).

## Git Safety Baseline
- Branch: `main` is protected on GitHub (`Talaren/obs-video-pipeline`).
- Branch protection rules: PR review required (1 approval), stale reviews dismissed, admin enforcement enabled, force-push disabled, branch deletion disabled, conversation resolution required.
- Commit signing: SSH signing is enabled (`commit.gpgsign=true`, `gpg.format=ssh`), using the configured `user.signingkey`.
- Local hook policy: configure locally with `git config core.hooksPath .githooks`.
- Pre-commit hook: `.githooks/pre-commit` (when enabled via `core.hooksPath`) runs `shellcheck` and `shfmt -d -i 2 -ci` on staged `*.sh` files and blocks non-compliant commits.
- Hook implementation note: staged file filtering uses POSIX tools (`grep`), so no `rg` dependency is required.
- Required local tools for commits: `shellcheck`, `shfmt`.
- Privilege model: no unattended root actions; package/system changes require manual `sudo` approval.
- Secret model: GitHub/Codex API operations require explicit token/app approval.
