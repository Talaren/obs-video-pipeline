#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROCESS_SCRIPT="$REPO_DIR/process_videos.sh"

TEST_TMP_DIRS=()
LAST_OUTPUT=""
LAST_STATUS=0

cleanup() {
  local dir

  for dir in "${TEST_TMP_DIRS[@]}"; do
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      rm -rf "$dir"
    fi
  done
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

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command not found: $1"
  fi
}

new_home() {
  local dir

  dir="$(mktemp -d)"
  TEST_TMP_DIRS+=("$dir")
  mkdir -p "$dir/Videos/OBS/final"
  printf '%s\n' "$dir"
}

run_pipeline() {
  local test_home="$1"
  shift

  set +e
  LAST_OUTPUT=$(HOME="$test_home" "$PROCESS_SCRIPT" "$@" 2>&1)
  LAST_STATUS=$?
  set -e
}

audio_stream_count() {
  local media_file="$1"

  ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$media_file" | wc -l
}

create_three_stream_segment() {
  local output_file="$1"

  ffmpeg -y -loglevel error -hide_banner -nostats \
    -f lavfi -i "testsrc2=size=160x90:rate=10:duration=0.6" \
    -f lavfi -i "sine=frequency=440:duration=0.6" \
    -f lavfi -i "sine=frequency=660:duration=0.6" \
    -f lavfi -i "sine=frequency=880:duration=0.6" \
    -map 0:v:0 -map 1:a:0 -map 2:a:0 -map 3:a:0 \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    -c:a libopus -b:a 64k \
    -metadata:s:a:0 title=Track1 \
    -metadata:s:a:1 title=Track2 \
    -metadata:s:a:2 title=Track3 \
    "$output_file"
}

create_one_stream_segment() {
  local output_file="$1"

  ffmpeg -y -loglevel error -hide_banner -nostats \
    -f lavfi -i "testsrc2=size=160x90:rate=10:duration=0.6" \
    -f lavfi -i "sine=frequency=440:duration=0.6" \
    -map 0:v:0 -map 1:a:0 \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    -c:a libopus -b:a 64k \
    -metadata:s:a:0 title=Track1 \
    "$output_file"
}

test_concat_preserves_three_audio_streams() {
  local test_home
  local merged_file
  test_home=$(new_home)
  merged_file="$test_home/Videos/OBS/final/merged_2099-02-01.mkv"

  create_three_stream_segment "$test_home/Videos/OBS/2099-02-01 20-00-00.mkv"
  create_three_stream_segment "$test_home/Videos/OBS/2099-02-01 20-00-01.mkv"

  run_pipeline "$test_home" -c -e concat 2099-02-01
  assert_eq 0 "$LAST_STATUS" "concat stage should succeed"
  assert_eq 3 "$(audio_stream_count "$merged_file")" "merged file should keep all 3 audio streams"
}

test_audio_and_video_stages_create_outputs() {
  local test_home
  local processed_audio
  local output_file
  test_home=$(new_home)
  processed_audio="$test_home/Videos/OBS/final/processed_audio_2099-02-02.m4a"
  output_file="$test_home/Videos/OBS/final/DSA5 mit Marth 02.02.2099 final.mp4"

  create_three_stream_segment "$test_home/Videos/OBS/2099-02-02 20-00-00.mkv"
  create_three_stream_segment "$test_home/Videos/OBS/2099-02-02 20-00-01.mkv"

  run_pipeline "$test_home" -c -e concat,audio,video -m voice-priority 2099-02-02
  assert_eq 0 "$LAST_STATUS" "concat,audio,video stages should succeed"

  if [ ! -s "$processed_audio" ]; then
    fail "processed audio should be created"
  fi
  if [ ! -s "$output_file" ]; then
    fail "final MP4 should be created"
  fi
  assert_eq 1 "$(audio_stream_count "$processed_audio")" "processed audio should contain 1 audio stream"
  assert_eq 1 "$(audio_stream_count "$output_file")" "final MP4 should contain 1 audio stream"
}

test_audio_stage_rejects_non_three_stream_layout() {
  local test_home
  test_home=$(new_home)

  create_one_stream_segment "$test_home/Videos/OBS/2099-02-03 20-00-00.mkv"

  run_pipeline "$test_home" -c -e audio 2099-02-03
  assert_eq 1 "$LAST_STATUS" "audio stage should reject one-stream layout"
  assert_contains "Erwartet sind exakt 3 Audio-Streams" "audio stream count error should be clear"
}

main() {
  require_cmd ffmpeg
  require_cmd ffprobe

  test_concat_preserves_three_audio_streams
  test_audio_and_video_stages_create_outputs
  test_audio_stage_rejects_non_three_stream_layout

  printf 'All media pipeline smoke tests passed.\n'
}

main "$@"
