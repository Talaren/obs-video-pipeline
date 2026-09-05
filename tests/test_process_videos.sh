#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROCESS_SCRIPT="$REPO_DIR/process_videos.sh"

TEST_TMP_ROOT="$(mktemp -d)"
LAST_OUTPUT=""
LAST_STATUS=0
BACKGROUND_PID=""
BACKGROUND_RELEASE_FILE=""

cleanup() {
  if [ -n "$BACKGROUND_RELEASE_FILE" ]; then
    : >"$BACKGROUND_RELEASE_FILE"
  fi
  if [ -n "$BACKGROUND_PID" ] && kill -0 "$BACKGROUND_PID" 2>/dev/null; then
    kill "$BACKGROUND_PID" 2>/dev/null || true
    wait "$BACKGROUND_PID" 2>/dev/null || true
  fi
  if [ -n "$TEST_TMP_ROOT" ] && [ -d "$TEST_TMP_ROOT" ]; then
    rm -rf "$TEST_TMP_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [ -n "$LAST_OUTPUT" ]; then
    printf '%s\n' '--- last output ---' >&2
    printf '%s\n' "$LAST_OUTPUT" >&2
    printf '%s\n' '-------------------' >&2
  fi
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [ "$actual" != "$expected" ]; then
    fail "$message (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local needle="$1"
  local message="$2"

  if [[ "$LAST_OUTPUT" != *"$needle"* ]]; then
    fail "$message (missing: $needle)"
  fi
}

assert_not_contains() {
  local needle="$1"
  local message="$2"

  if [[ "$LAST_OUTPUT" == *"$needle"* ]]; then
    fail "$message (unexpected: $needle)"
  fi
}

new_temp_dir() {
  mktemp -d "$TEST_TMP_ROOT/home.XXXXXX"
}

new_home() {
  local dir

  dir="$(new_temp_dir)"
  mkdir -p "$dir/Videos/OBS/final"
  printf '%s\n' "$dir"
}

run_pipeline() {
  local test_home="$1"
  shift

  set +e
  LAST_OUTPUT=$(HOME="$test_home" OBS_VIDEO_PIPELINE_INHIBITED=1 "$PROCESS_SCRIPT" "$@" 2>&1)
  LAST_STATUS=$?
  set -e
}

run_pipeline_with_uploader() {
  local test_home="$1"
  local uploader="$2"
  shift 2

  set +e
  LAST_OUTPUT=$(HOME="$test_home" OBS_VIDEO_PIPELINE_INHIBITED=1 YOUTUBE_UPLOAD_BIN="$uploader" "$PROCESS_SCRIPT" "$@" 2>&1)
  LAST_STATUS=$?
  set -e
}

test_non_dry_run_uses_sleep_inhibitor() {
  local test_home
  local fake_inhibitor
  local inhibitor_args
  test_home=$(new_home)
  fake_inhibitor="$test_home/fake-systemd-inhibit"
  inhibitor_args="$test_home/inhibitor-args.txt"

  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    ': "${INHIBITOR_ARGS_LOG:?}"' \
    'printf "%s\n" "$@" >"$INHIBITOR_ARGS_LOG"' \
    'while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done' \
    'if [ "$#" -eq 0 ]; then exit 64; fi' \
    'shift' \
    'exec "$@"' >"$fake_inhibitor"
  chmod +x "$fake_inhibitor"

  set +e
  LAST_OUTPUT=$(HOME="$test_home" \
    INHIBITOR_ARGS_LOG="$inhibitor_args" \
    SYSTEMD_INHIBIT_BIN="$fake_inhibitor" \
    "$PROCESS_SCRIPT" -e clean 2099-01-01 2>&1)
  LAST_STATUS=$?
  set -e

  assert_eq 0 "$LAST_STATUS" "non-dry-run should succeed through sleep inhibitor"
  assert_contains "Schlafsperre aktiv" "active sleep inhibitor should be logged"
  grep -Fxq -- '--what=sleep' "$inhibitor_args" || fail "sleep must be inhibited"
  if grep -Fq -- '--what=sleep:idle' "$inhibitor_args"; then
    fail "idle must remain uninhibited so display power management can still run"
  fi
  grep -Fxq -- '--mode=block' "$inhibitor_args" || fail "sleep inhibitor must use block mode"
  grep -Fxq -- "$PROCESS_SCRIPT" "$inhibitor_args" || fail "inhibitor must execute the pipeline script"
  grep -Fxq -- '-e' "$inhibitor_args" || fail "original options must survive inhibitor re-exec"
  grep -Fxq -- 'clean' "$inhibitor_args" || fail "original stage must survive inhibitor re-exec"
  grep -Fxq -- '2099-01-01' "$inhibitor_args" || fail "original date must survive inhibitor re-exec"
}

test_dry_run_skips_sleep_inhibitor() {
  local test_home
  test_home=$(new_home)

  set +e
  LAST_OUTPUT=$(HOME="$test_home" \
    SYSTEMD_INHIBIT_BIN="$test_home/does-not-exist" \
    "$PROCESS_SCRIPT" -d -e clean 2099-01-01 2>&1)
  LAST_STATUS=$?
  set -e

  assert_eq 0 "$LAST_STATUS" "dry-run must not require a sleep inhibitor"
  assert_contains "Dry-Run: keine Dateien werden erstellt" "dry-run should still complete normally"
}

test_runtime_shutdown_control() {
  local test_home
  local fake_bin
  local uploader
  local systemctl_calls
  local final_file
  local control_file
  local date
  test_home=$(new_home)
  fake_bin="$test_home/fake-bin"
  uploader="$fake_bin/fake-uploader"
  systemctl_calls="$test_home/systemctl-calls.txt"
  mkdir -p "$fake_bin"

  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$@" >>"$SYSTEMCTL_CALLS"' >"$fake_bin/systemctl"
  chmod +x "$fake_bin/systemctl"

  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '"$PROCESS_SCRIPT_PATH" -S disable "$CONTROL_DATE"' \
    '"$PROCESS_SCRIPT_PATH" -S status "$CONTROL_DATE"' \
    'if [ "$CONTROL_SEQUENCE" = "toggle" ]; then' \
    '  "$PROCESS_SCRIPT_PATH" -S enable "$CONTROL_DATE"' \
    '  "$PROCESS_SCRIPT_PATH" -S status "$CONTROL_DATE"' \
    'fi' >"$uploader"
  chmod +x "$uploader"

  date=2099-01-02
  final_file="$test_home/Videos/OBS/final/DSA5 mit Marth 02.01.2099 final.mp4"
  control_file="$test_home/Videos/OBS/final/.shutdown_${date}.control"
  : >"$final_file"

  set +e
  LAST_OUTPUT=$(HOME="$test_home" \
    PATH="$fake_bin:$PATH" \
    OBS_VIDEO_PIPELINE_INHIBITED=1 \
    YOUTUBE_UPLOAD_BIN="$uploader" \
    PROCESS_SCRIPT_PATH="$PROCESS_SCRIPT" \
    CONTROL_DATE="$date" \
    CONTROL_SEQUENCE=disable \
    SYSTEMCTL_CALLS="$systemctl_calls" \
    "$PROCESS_SCRIPT" -s -e upload "$date" 2>&1)
  LAST_STATUS=$?
  set -e

  assert_eq 0 "$LAST_STATUS" "runtime-disabled shutdown pipeline should succeed"
  assert_contains "Shutdown fuer Pipeline-Prozess" "controller should address the active pipeline"
  assert_contains ": deaktiviert." "status should report disabled shutdown"
  assert_contains "Computer bleibt eingeschaltet" "disabled shutdown should be honored at completion"
  if [ -e "$systemctl_calls" ]; then
    fail "disabled runtime shutdown must not call systemctl"
  fi
  if [ -e "$control_file" ]; then
    fail "shutdown control file should be removed after completion"
  fi

  date=2099-01-03
  final_file="$test_home/Videos/OBS/final/DSA5 mit Marth 03.01.2099 final.mp4"
  control_file="$test_home/Videos/OBS/final/.shutdown_${date}.control"
  : >"$final_file"

  set +e
  LAST_OUTPUT=$(HOME="$test_home" \
    PATH="$fake_bin:$PATH" \
    OBS_VIDEO_PIPELINE_INHIBITED=1 \
    YOUTUBE_UPLOAD_BIN="$uploader" \
    PROCESS_SCRIPT_PATH="$PROCESS_SCRIPT" \
    CONTROL_DATE="$date" \
    CONTROL_SEQUENCE=toggle \
    SYSTEMCTL_CALLS="$systemctl_calls" \
    "$PROCESS_SCRIPT" -s -e upload "$date" 2>&1)
  LAST_STATUS=$?
  set -e

  assert_eq 0 "$LAST_STATUS" "runtime-reenabled shutdown pipeline should succeed"
  assert_contains ": deaktiviert." "shutdown should be disableable before being re-enabled"
  assert_contains ": aktiviert." "status should report re-enabled shutdown"
  assert_contains "fahre System herunter" "re-enabled shutdown should be honored at completion"
  if ! grep -Fxq poweroff "$systemctl_calls"; then
    fail "re-enabled runtime shutdown should call systemctl poweroff"
  fi
  if [ -e "$control_file" ]; then
    fail "shutdown control file should be removed before poweroff"
  fi
}

test_invalid_dates() {
  local test_home
  test_home=$(new_home)

  run_pipeline "$test_home" yesterday
  assert_eq 1 "$LAST_STATUS" "yesterday must fail"
  assert_contains "Ungueltiges Datum: yesterday" "yesterday error should mention invalid date"

  run_pipeline "$test_home" 2025-8-1
  assert_eq 1 "$LAST_STATUS" "non-padded date must fail"
  assert_contains "Ungueltiges Datum: 2025-8-1" "non-padded date error should mention invalid date"

  run_pipeline "$test_home" 2026-02-31
  assert_eq 1 "$LAST_STATUS" "invalid calendar date must fail"
  assert_contains "Ungueltiges Datum: 2026-02-31" "invalid calendar date error should mention invalid date"
}

test_invalid_stage_threads_and_video_settings() {
  local test_home
  test_home=$(new_home)

  run_pipeline "$test_home" -d -e nope 2099-01-01
  assert_eq 1 "$LAST_STATUS" "unknown stage must fail"
  assert_contains "Unbekannter Schritt: nope" "unknown stage error should mention stage"

  run_pipeline "$test_home" -d -T abc 2099-01-01
  assert_eq 1 "$LAST_STATUS" "invalid thread count must fail"
  assert_contains "Fehler: -T erwartet eine nicht-negative Ganzzahl" "invalid thread error should be clear"

  run_pipeline "$test_home" -d -p impossible 2099-01-01
  assert_eq 1 "$LAST_STATUS" "invalid x264 preset must fail"
  assert_contains "Unbekanntes libx264-Preset" "invalid x264 preset error should be clear"

  run_pipeline "$test_home" -d -p ultrafast 2099-01-01
  assert_eq 1 "$LAST_STATUS" "ultrafast must fail because it cannot satisfy the High Profile contract"
  assert_contains "erzeugt kein H.264 High Profile" "incompatible ultrafast preset error should be clear"

  run_pipeline "$test_home" -d -q 0 2099-01-01
  assert_eq 1 "$LAST_STATUS" "lossless CRF 0 must fail because it is incompatible with High Profile"
  assert_contains "-q erwartet eine Ganzzahl von 1 bis 51" "invalid lossless CRF error should be clear"

  run_pipeline "$test_home" -d -q 52 2099-01-01
  assert_eq 1 "$LAST_STATUS" "out-of-range CRF must fail"
  assert_contains "-q erwartet eine Ganzzahl von 1 bis 51" "invalid CRF error should be clear"

  run_pipeline "$test_home" -S impossible 2099-01-01
  assert_eq 1 "$LAST_STATUS" "invalid shutdown control action must fail"
  assert_contains "-S erwartet enable, disable oder status" "invalid shutdown control action should be clear"
}

test_invalid_profile_and_extra_argument() {
  local test_home
  test_home=$(new_home)

  run_pipeline "$test_home" -d -m does-not-exist 2099-01-01
  assert_eq 1 "$LAST_STATUS" "unknown audio profile must fail in dry-run"
  assert_contains "Unbekanntes Audio-Mix-Profil" "unknown profile error should be clear"

  run_pipeline "$test_home" -d 2099-01-01 extra
  assert_eq 1 "$LAST_STATUS" "extra positional arguments must fail"
  assert_contains "Zu viele Argumente" "extra argument error should be clear"
}

test_dry_run_upload_autostages_without_artifacts() {
  local test_home
  test_home=$(new_home)

  run_pipeline "$test_home" -d -e upload 2099-01-01
  assert_eq 0 "$LAST_STATUS" "upload dry-run without artifacts should succeed"
  assert_contains "Angeforderte Stages: upload" "requested upload stage should be shown"
  assert_contains "Geplante Stages: concat,audio,video,upload" "upload should auto-plan prerequisites"
  assert_contains "Auto-Stage: concat" "concat auto-stage should be explained"
  assert_contains "Auto-Stage: audio" "audio auto-stage should be explained"
  assert_contains "Auto-Stage: video" "video auto-stage should be explained"
  assert_contains "Dry-Run: keine Dateien werden erstellt" "dry-run no-write statement should be shown"
}

test_dry_run_video_autostages_without_artifacts() {
  local test_home
  test_home=$(new_home)

  run_pipeline "$test_home" -d -e video 2099-01-01
  assert_eq 0 "$LAST_STATUS" "video dry-run without artifacts should succeed"
  assert_contains "Geplante Stages: concat,audio,video" "video should auto-plan concat and audio"
  assert_contains "Auto-Stage: concat" "concat auto-stage should be explained"
  assert_contains "Auto-Stage: audio" "audio auto-stage should be explained"
  assert_not_contains "Auto-Stage: video" "explicit video should not be reported as auto-stage"
  assert_contains "Video-Encoding: libx264, preset=medium, crf=21" "dry-run should show production x264 defaults"

  run_pipeline "$test_home" -d -e video -p medium -q 20 2099-01-01
  assert_eq 0 "$LAST_STATUS" "custom valid x264 settings should pass dry-run"
  assert_contains "Video-Encoding: libx264, preset=medium, crf=20" "dry-run should show custom x264 settings"

  run_pipeline "$test_home" -d -e video -p superfast -q 1 2099-01-01
  assert_eq 0 "$LAST_STATUS" "supported x264 boundary settings should pass dry-run"
  assert_contains "Video-Encoding: libx264, preset=superfast, crf=1" "dry-run should show valid boundary settings"
}

test_dry_run_upload_with_final_artifact() {
  local test_home
  local final_file
  test_home=$(new_home)
  final_file="$test_home/Videos/OBS/final/DSA5 mit Marth 01.01.2099 final.mp4"
  : >"$final_file"

  run_pipeline "$test_home" -d -e upload 2099-01-01
  assert_eq 0 "$LAST_STATUS" "upload dry-run with final artifact should succeed"
  assert_contains "Geplante Stages: upload" "upload should not auto-plan prerequisites when final exists"
  assert_not_contains "Auto-Stage:" "no auto-stage should be reported when final exists"
}

test_timestamp_freshness_autostages_dependencies() {
  local test_home
  local source_file
  local merged_file
  local processed_audio
  local final_file
  local date
  test_home=$(new_home)
  date=2099-01-06
  source_file="$test_home/Videos/OBS/$date 20-00-00.mkv"
  merged_file="$test_home/Videos/OBS/final/merged_${date}.mkv"
  processed_audio="$test_home/Videos/OBS/final/processed_audio_${date}.m4a"
  final_file="$test_home/Videos/OBS/final/DSA5 mit Marth 06.01.2099 final.mp4"

  : >"$source_file"
  : >"$final_file"
  touch -d '2035-01-01 00:00:00' "$source_file"
  touch -d '2035-01-01 00:04:00' "$final_file"

  run_pipeline "$test_home" -d -e upload "$date"
  assert_eq 0 "$LAST_STATUS" "upload dry-run should accept a final file newer than cleaned prerequisites"
  assert_contains "Geplante Stages: upload" "fresh final file should remain directly uploadable after cleanup"
  assert_not_contains "Auto-Stage:" "cleaned intermediate files alone must not make a fresh final file stale"

  touch -d '2035-01-01 00:05:00' "$source_file"
  run_pipeline "$test_home" -d -e upload "$date"
  assert_eq 0 "$LAST_STATUS" "upload dry-run should rebuild a final file older than an OBS source"
  assert_contains "Geplante Stages: concat,audio,video,upload" \
    "newer OBS source should rebuild all missing prerequisites"
  assert_contains "Auto-Stage: video, weil mindestens eine OBS-Quelldatei neuer" \
    "stale final file should explain the newer OBS source"

  : >"$merged_file"
  : >"$processed_audio"
  touch -d '2035-01-01 00:01:00' "$source_file"
  touch -d '2035-01-01 00:05:00' "$processed_audio"
  touch -d '2035-01-01 00:06:00' "$final_file"
  touch -d '2035-01-01 00:07:00' "$merged_file"

  run_pipeline "$test_home" -d -e upload "$date"
  assert_eq 0 "$LAST_STATUS" "upload dry-run should follow stale intermediate dependencies"
  assert_contains "Geplante Stages: audio,video,upload" \
    "newer merged file should rebuild audio and video without rebuilding concat"
  assert_not_contains "Auto-Stage: concat" "fresh merged file should not be rebuilt"
  assert_contains "Auto-Stage: audio, weil $merged_file neuer" \
    "stale processed audio should identify the newer merged file"
  assert_contains "Auto-Stage: video, weil $merged_file neuer" \
    "stale final file should identify the newer merged file"

  touch -d '2035-01-01 00:08:00' "$source_file"
  run_pipeline "$test_home" -d -e upload "$date"
  assert_eq 0 "$LAST_STATUS" "newest OBS source should invalidate the complete dependency chain"
  assert_contains "Geplante Stages: concat,audio,video,upload" \
    "newest OBS source should rebuild concat, audio, and video"
  assert_contains "Auto-Stage: concat, weil mindestens eine OBS-Quelldatei neuer" \
    "stale merged file should explain the newer OBS source"
  assert_contains "Auto-Stage: audio, weil mindestens eine OBS-Quelldatei neuer" \
    "stale audio file should explain the newer OBS source"
}

test_pipeline_lock_is_per_date() {
  local test_home
  local fake_uploader
  local quick_uploader
  local ready_file
  local release_file
  local first_output
  local first_status
  local lock_file
  local attempt
  local date
  test_home=$(new_home)
  fake_uploader="$test_home/blocking-uploader"
  quick_uploader="$test_home/quick-uploader"
  ready_file="$test_home/uploader-ready"
  release_file="$test_home/uploader-release"
  first_output="$test_home/first-pipeline.log"
  date=2099-01-07
  lock_file="$test_home/Videos/OBS/final/.pipeline_${date}.lock"
  : >"$test_home/Videos/OBS/final/DSA5 mit Marth 07.01.2099 final.mp4"

  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    ': "${LOCK_READY_FILE:?}" "${LOCK_RELEASE_FILE:?}"' \
    ': >"$LOCK_READY_FILE"' \
    'while [ ! -e "$LOCK_RELEASE_FILE" ]; do sleep 0.05; done' >"$fake_uploader"
  chmod +x "$fake_uploader"

  BACKGROUND_RELEASE_FILE="$release_file"
  HOME="$test_home" \
    OBS_VIDEO_PIPELINE_INHIBITED=1 \
    YOUTUBE_UPLOAD_BIN="$fake_uploader" \
    LOCK_READY_FILE="$ready_file" \
    LOCK_RELEASE_FILE="$release_file" \
    "$PROCESS_SCRIPT" -e upload "$date" >"$first_output" 2>&1 &
  BACKGROUND_PID=$!

  for ((attempt = 0; attempt < 100; attempt++)); do
    [ -e "$ready_file" ] && break
    sleep 0.05
  done
  if [ ! -e "$ready_file" ]; then
    fail "first pipeline did not reach its blocking uploader"
  fi

  run_pipeline_with_uploader "$test_home" "$fake_uploader" -e upload "$date"
  assert_eq 75 "$LAST_STATUS" "second pipeline for the same date should fail with the lock conflict status"
  assert_contains "laeuft bereits eine Video-Pipeline" "same-date lock conflict should be explained"

  run_pipeline "$test_home" -e clean 2099-01-08
  assert_eq 0 "$LAST_STATUS" "a pipeline for another date should run while the first date is locked"

  run_pipeline "$test_home" -d -e upload "$date"
  assert_eq 0 "$LAST_STATUS" "dry-run should remain available while the real pipeline is locked"

  : >"$release_file"
  set +e
  wait "$BACKGROUND_PID"
  first_status=$?
  set -e
  BACKGROUND_PID=""
  BACKGROUND_RELEASE_FILE=""
  assert_eq 0 "$first_status" "first locked pipeline should finish normally after release"

  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$quick_uploader"
  chmod +x "$quick_uploader"
  run_pipeline_with_uploader "$test_home" "$quick_uploader" -e upload "$date"
  assert_eq 0 "$LAST_STATUS" "same-date lock should be released after the pipeline exits"

  if [ ! -f "$lock_file" ]; then
    fail "pipeline lock should use a persistent regular lock file"
  fi
  assert_eq 600 "$(stat -c '%a' "$lock_file")" "new pipeline lock file should be private"
}

test_invalid_pipeline_lock_targets_are_rejected() {
  local test_home
  local lock_file
  local symlink_target
  local date
  test_home=$(new_home)
  date=2099-01-09
  lock_file="$test_home/Videos/OBS/final/.pipeline_${date}.lock"
  symlink_target="$test_home/lock-target"
  : >"$symlink_target"
  ln -s "$symlink_target" "$lock_file"

  run_pipeline "$test_home" -e clean "$date"
  assert_eq 1 "$LAST_STATUS" "symbolic-link pipeline lock target should be rejected"
  assert_contains "Pipeline-Sperrdatei ist keine regulaere Datei" \
    "symbolic-link pipeline lock error should be explicit"
  if [ ! -L "$lock_file" ] || [ ! -f "$symlink_target" ]; then
    fail "rejected symbolic-link pipeline lock target should remain untouched"
  fi

  rm "$lock_file"
  mkdir "$lock_file"
  run_pipeline "$test_home" -e clean "$date"
  assert_eq 1 "$LAST_STATUS" "directory pipeline lock target should be rejected"
  assert_contains "Pipeline-Sperrdatei ist keine regulaere Datei" \
    "directory pipeline lock error should be explicit"
  if [ ! -d "$lock_file" ]; then
    fail "rejected directory pipeline lock target should remain untouched"
  fi
}

test_dry_run_clean_disabled_by_c_flag() {
  local test_home
  test_home=$(new_home)

  run_pipeline "$test_home" -d -e clean -c 2099-01-01
  assert_eq 0 "$LAST_STATUS" "clean dry-run with -c should succeed"
  assert_contains "Angeforderte Stages: clean" "requested clean stage should be shown"
  assert_contains "Geplante Stages: keine" "-c should disable clean stage"
}

test_dry_run_finish_actions() {
  local test_home
  test_home=$(new_home)

  run_pipeline "$test_home" -d -s 2099-01-01
  assert_eq 0 "$LAST_STATUS" "shutdown dry-run should succeed"
  assert_contains "Abschlussaktion: shutdown" "shutdown action should be shown"

  run_pipeline "$test_home" -d -n 2099-01-01
  assert_eq 0 "$LAST_STATUS" "notify dry-run should succeed"
  assert_contains "Abschlussaktion: notify" "notify action should be shown"

  run_pipeline "$test_home" -d -s -n 2099-01-01
  assert_eq 0 "$LAST_STATUS" "shutdown should win regardless of option order"
  assert_contains "Abschlussaktion: shutdown" "shutdown should take precedence over notify"

  run_pipeline "$test_home" -d -n -s 2099-01-01
  assert_eq 0 "$LAST_STATUS" "shutdown should win in the opposite option order"
  assert_contains "Abschlussaktion: shutdown" "shutdown precedence should be order-independent"
}

test_dry_run_does_not_write_output_dir() {
  local test_home
  test_home="$(new_temp_dir)"

  run_pipeline "$test_home" -d -e upload 2099-01-01
  assert_eq 0 "$LAST_STATUS" "dry-run should succeed without pre-existing output directory"

  if [ -e "$test_home/Videos" ]; then
    fail "dry-run must not create ~/Videos or output directories"
  fi
}

test_invalid_thread_logs_in_non_dry_run() {
  local test_home
  local log_file
  test_home=$(new_home)

  run_pipeline "$test_home" -T abc -e clean 2099-01-01
  assert_eq 1 "$LAST_STATUS" "non-dry-run invalid thread count must fail"
  assert_contains "Fehler: -T erwartet eine nicht-negative Ganzzahl" "invalid thread error should be printed"

  log_file=$(find "$test_home/Videos/OBS/final" -maxdepth 1 -name 'full_pipeline_2099-01-01_*.log' -print -quit)
  if [ -z "$log_file" ]; then
    fail "non-dry-run validation error should create a pipeline log"
  fi
  if ! grep -q "Fehler: -T erwartet eine nicht-negative Ganzzahl" "$log_file"; then
    fail "pipeline log should contain validation error"
  fi
}

test_upload_exit_codes_are_disambiguated() {
  local test_home
  local uploader
  local final_file
  test_home=$(new_home)
  uploader="$test_home/fake-uploader"
  final_file="$test_home/Videos/OBS/final/DSA5 mit Marth 01.01.2099 final.mp4"
  : >"$final_file"

  printf '%s\n' '#!/usr/bin/env bash' 'exit 3' >"$uploader"
  chmod +x "$uploader"

  run_pipeline_with_uploader "$test_home" "$uploader" -e upload 2099-01-01
  assert_eq 3 "$LAST_STATUS" "playlist partial success should retain its dedicated exit status"
  assert_contains "Playlist-Zuordnung ist fehlgeschlagen" "partial success should be reported clearly"
  assert_not_contains "Skript unerwartet beendet" "known partial success should not be reported as an unexpected failure"

  printf '%s\n' '#!/usr/bin/env bash' 'exit 2' >"$uploader"

  run_pipeline_with_uploader "$test_home" "$uploader" -e upload 2099-01-01
  assert_eq 2 "$LAST_STATUS" "argparse-style failures should retain exit status 2"
  assert_not_contains "Playlist-Zuordnung ist fehlgeschlagen" "argparse failure must not claim a completed upload"
  assert_contains "Skript unerwartet beendet" "argparse failure should follow the normal error path"

  printf '%s\n' '#!/usr/bin/env bash' 'exit 75' >"$uploader"

  run_pipeline_with_uploader "$test_home" "$uploader" -e upload 2099-01-01
  assert_eq 75 "$LAST_STATUS" "uploader status 75 should pass through the pipeline"
  assert_not_contains "laeuft bereits eine Video-Pipeline" \
    "child status 75 must not be misreported as a pipeline lock conflict"
}

test_upload_progress_bypasses_pipeline_log() {
  local test_home
  local uploader
  local final_file
  local log_file
  test_home=$(new_home)
  uploader="$test_home/fake-uploader"
  final_file="$test_home/Videos/OBS/final/DSA5 mit Marth 01.01.2099 final.mp4"
  : >"$final_file"

  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    ': "${YT_UPLOAD_PROGRESS_FD:?}"' \
    'printf "Upload-Fortschritt: 42%%\n" >&"$YT_UPLOAD_PROGRESS_FD"' \
    'printf "Upload erfolgreich. Video-ID: test-video\n"' >"$uploader"
  chmod +x "$uploader"

  run_pipeline_with_uploader "$test_home" "$uploader" -e upload 2099-01-01
  assert_eq 0 "$LAST_STATUS" "upload with dedicated progress output should succeed"
  assert_contains "Upload-Fortschritt: 42%" "upload progress should remain visible in terminal output"
  assert_contains "Upload erfolgreich. Video-ID: test-video" "normal uploader output should remain visible"

  log_file=$(find "$test_home/Videos/OBS/final" -maxdepth 1 -name 'full_pipeline_2099-01-01_*.log' -print -quit)
  if [ -z "$log_file" ]; then
    fail "upload should create a pipeline log"
  fi
  if grep -Fq 'Upload-Fortschritt:' "$log_file"; then
    fail "upload progress must not be written to the pipeline log"
  fi
  if ! grep -Fq 'Upload erfolgreich. Video-ID: test-video' "$log_file"; then
    fail "normal uploader output should remain in the pipeline log"
  fi
}

main() {
  test_invalid_dates
  test_invalid_stage_threads_and_video_settings
  test_invalid_profile_and_extra_argument
  test_dry_run_upload_autostages_without_artifacts
  test_dry_run_video_autostages_without_artifacts
  test_dry_run_upload_with_final_artifact
  test_timestamp_freshness_autostages_dependencies
  test_dry_run_clean_disabled_by_c_flag
  test_dry_run_finish_actions
  test_dry_run_does_not_write_output_dir
  test_non_dry_run_uses_sleep_inhibitor
  test_dry_run_skips_sleep_inhibitor
  test_runtime_shutdown_control
  test_pipeline_lock_is_per_date
  test_invalid_pipeline_lock_targets_are_rejected
  test_invalid_thread_logs_in_non_dry_run
  test_upload_exit_codes_are_disambiguated
  test_upload_progress_bypasses_pipeline_log

  printf 'All process_videos control-flow tests passed.\n'
}

main "$@"
