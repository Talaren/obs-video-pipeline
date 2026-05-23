#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROCESS_SCRIPT="$REPO_DIR/process_videos.sh"

TEST_TMP=""
LAST_OUTPUT=""
LAST_STATUS=0

cleanup() {
  if [ -n "$TEST_TMP" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
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

new_home() {
  TEST_TMP="$(mktemp -d)"
  mkdir -p "$TEST_TMP/Videos/OBS/final"
  printf '%s\n' "$TEST_TMP"
}

run_pipeline() {
  local test_home="$1"
  shift

  set +e
  LAST_OUTPUT=$(HOME="$test_home" "$PROCESS_SCRIPT" "$@" 2>&1)
  LAST_STATUS=$?
  set -e
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

test_invalid_stage_and_threads() {
  local test_home
  test_home=$(new_home)

  run_pipeline "$test_home" -d -e nope 2099-01-01
  assert_eq 1 "$LAST_STATUS" "unknown stage must fail"
  assert_contains "Unbekannter Schritt: nope" "unknown stage error should mention stage"

  run_pipeline "$test_home" -d -T abc 2099-01-01
  assert_eq 1 "$LAST_STATUS" "invalid thread count must fail"
  assert_contains "Fehler: -T erwartet eine nicht-negative Ganzzahl" "invalid thread error should be clear"
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
}

test_dry_run_does_not_write_output_dir() {
  local test_home
  test_home="$(mktemp -d)"
  TEST_TMP="$test_home"

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

main() {
  test_invalid_dates
  test_invalid_stage_and_threads
  test_dry_run_upload_autostages_without_artifacts
  test_dry_run_video_autostages_without_artifacts
  test_dry_run_upload_with_final_artifact
  test_dry_run_clean_disabled_by_c_flag
  test_dry_run_finish_actions
  test_dry_run_does_not_write_output_dir
  test_invalid_thread_logs_in_non_dry_run

  printf 'All process_videos dry-run tests passed.\n'
}

main "$@"
