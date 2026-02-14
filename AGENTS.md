# Repository Guidelines

## Project Structure & Module Organization
- Root: video processing script `process_videos.sh`.
- Inputs: `~/Videos/OBS/*.mkv` (date contained in filename).
- Outputs: `~/Videos/OBS/final/`
  - Merged session: `merged_YYYY-MM-DD.mkv`
  - Processed audio: `processed_audio_YYYY-MM-DD.m4a`
  - Concat list: `filelist_mkv.txt`
  - Final: `DSA5 mit Marth DD.MM.YYYY final.mp4`

## Build, Test, and Development Commands
- Run pipeline (default stages: concat,audio,video,clean): `./process_videos.sh 2025-08-28`
- Select stages: `./process_videos.sh -e concat,audio,video 2025-08-28`
- Audio only (auto-concat if merged file is missing): `./process_videos.sh -e audio 2025-08-28`
- Video only (requires processed audio): `./process_videos.sh -e video 2025-08-28`
- Set ffmpeg threads: `./process_videos.sh -T 6 2025-08-28`
- Lint Bash: `shellcheck process_videos.sh`
- Format Bash: `shfmt -w -i 2 -ci process_videos.sh`

## Coding Style & Naming Conventions
- Language: Bash; use `set -euo pipefail`.
- Indentation: 2 spaces; no tabs.
- Names: UPPER_CASE for constants/flags; lower_snake_case for functions.
- Logs: use `log_msg "message"`.
- Filenames: keep existing patterns (`merged_YYYY-MM-DD.mkv`, `processed_audio_YYYY-MM-DD.m4a`, final name with date).

## Testing Guidelines
- Smoke test: run with a small sample MKV and `-e concat,audio,video` to verify outputs.
- Stream-layout robustness: test with 1, 2, and 3+ audio streams (fallback filters are applied automatically).
- Idempotence: rerun stages; ensure no unexpected overwrites.
- Dependency behavior: verify `-e audio` or `-e video` auto-runs concat when `merged_YYYY-MM-DD.mkv` is absent.
- Linting: `shellcheck` must pass with no errors; fix warnings when feasible.

## Commit & Pull Request Guidelines
- Commits: use Conventional Commits (e.g., `feat: add thread option`, `fix: handle missing audio`).
- PRs: include summary, rationale, example command(s), and before/after behavior. Add logs or output snippets when relevant.

## Security & Configuration Tips
- Shutdown/notify: use `-s` (shutdown) and `-n` (notify) carefully; default is no side-effects.
- Performance: ffmpeg uses stream copy for concat/remux; option `-T` sets threads for ffmpeg calls.
- Video handling: OBS video is not re-encoded; pipeline does concat/copy to `merged_YYYY-MM-DD.mkv`, then final remux with `-c:v copy -c:a copy -movflags +faststart`.
- Audio processing: runs once on merged session. For 3+ streams, full Discord/Foundry/Mic mix is used; for 1-2 streams, fallback filters are applied automatically. Final mix targets around -16 LUFS with -2 dBTP.
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
