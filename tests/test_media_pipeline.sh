#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROCESS_SCRIPT="$REPO_DIR/process_videos.sh"

TEST_TMP_ROOT="$(mktemp -d)"
LAST_OUTPUT=""
LAST_STATUS=0

cleanup() {
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

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command not found: $1"
  fi
}

require_ffmpeg_encoder() {
  local encoder="$1"

  if ! ffmpeg -hide_banner -encoders 2>/dev/null | awk '{ print $2 }' | grep -Fxq "$encoder"; then
    fail "required ffmpeg encoder not found: $encoder"
  fi
}

new_home() {
  local dir

  dir="$(mktemp -d "$TEST_TMP_ROOT/home.XXXXXX")"
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

run_pipeline_with_path() {
  local test_home="$1"
  local test_path="$2"
  shift 2

  set +e
  LAST_OUTPUT=$(HOME="$test_home" OBS_VIDEO_PIPELINE_INHIBITED=1 PATH="$test_path:$PATH" "$PROCESS_SCRIPT" "$@" 2>&1)
  LAST_STATUS=$?
  set -e
}

run_pipeline_with_umask() {
  local test_home="$1"
  local test_umask="$2"
  shift 2

  set +e
  LAST_OUTPUT=$(
    HOME="$test_home" OBS_VIDEO_PIPELINE_INHIBITED=1 bash -c \
      'umask "$1"; shift; exec "$@"' \
      bash "$test_umask" "$PROCESS_SCRIPT" "$@" 2>&1
  )
  LAST_STATUS=$?
  set -e
}

audio_stream_count() {
  local media_file="$1"
  local count

  if ! count=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$media_file" | awk 'END { print NR }'); then
    fail "ffprobe failed while counting audio streams in $media_file"
  fi

  printf '%s\n' "$count"
}

audio_sample_rate() {
  local media_file="$1"

  ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$media_file"
}

audio_mean_volume() {
  local media_file="$1"
  local start_time="$2"
  local duration="$3"

  ffmpeg -hide_banner -nostats \
    -ss "$start_time" -t "$duration" -i "$media_file" \
    -map 0:a:0 -af volumedetect -f null - 2>&1 |
    sed -n 's/.*mean_volume: \(-\{0,1\}[0-9.]*\) dB/\1/p' |
    tail -1
}

assert_audio_window_audible() {
  local media_file="$1"
  local start_time="$2"
  local duration="$3"
  local message="$4"
  local mean_volume

  mean_volume=$(audio_mean_volume "$media_file" "$start_time" "$duration")
  if [ -z "$mean_volume" ] || ! awk -v level="$mean_volume" 'BEGIN { exit !(level > -50) }'; then
    fail "$message (mean volume '${mean_volume:-missing}' dB)"
  fi
}

video_property() {
  local media_file="$1"
  local property="$2"

  ffprobe -v error -select_streams v:0 -show_entries "stream=$property" -of csv=p=0 "$media_file"
}

maximum_keyframe_interval() {
  local media_file="$1"

  ffprobe -v error -select_streams v:0 \
    -show_packets -show_entries packet=pts_time,flags -of csv=p=0 "$media_file" |
    awk -F, '
      $2 ~ /K/ {
        if (keyframe_count > 0) {
          gap = $1 - previous_pts
          if (gap > maximum_gap) {
            maximum_gap = gap
          }
        }
        previous_pts = $1
        keyframe_count++
      }
      END {
        if (keyframe_count < 2) {
          exit 1
        }
        printf "%.3f\n", maximum_gap
      }
    '
}

file_mode() {
  local file="$1"

  stat -c '%a' "$file"
}

default_output_mode() {
  local current_umask
  local mode

  current_umask=$(umask)
  printf -v mode '%03o' "$((0666 & ~current_umask))"
  printf '%s\n' "$mode"
}

create_three_stream_segment() {
  local output_file="$1"

  ffmpeg -y -loglevel error -hide_banner -nostats \
    -f lavfi -i "testsrc2=size=160x90:rate=10:duration=0.6" \
    -f lavfi -i "sine=frequency=440:duration=0.6" \
    -f lavfi -i "sine=frequency=660:duration=0.6" \
    -f lavfi -i "sine=frequency=880:duration=0.6" \
    -map 0:v:0 -map 1:a:0 -map 2:a:0 -map 3:a:0 \
    -c:v mpeg4 -q:v 5 -pix_fmt yuv420p \
    -c:a aac -b:a 64k \
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
    -c:v mpeg4 -q:v 5 -pix_fmt yuv420p \
    -c:a aac -b:a 64k \
    -metadata:s:a:0 title=Track1 \
    "$output_file"
}

create_delayed_activity_segment() {
  local output_file="$1"

  ffmpeg -y -loglevel error -hide_banner -nostats \
    -f lavfi -i "color=c=black:size=64x36:rate=2:duration=9" \
    -f lavfi -i "aevalsrc=if(between(t\,0.5\,2.5)\,0.2*sin(2*PI*440*t)\,0):s=48000:d=9" \
    -f lavfi -i "aevalsrc=if(between(t\,3.25\,5.25)\,0.2*sin(2*PI*660*t)\,0):s=48000:d=9" \
    -f lavfi -i "aevalsrc=if(between(t\,6\,8)\,0.2*sin(2*PI*880*t)\,0):s=48000:d=9" \
    -map 0:v:0 -map 1:a:0 -map 2:a:0 -map 3:a:0 \
    -c:v mpeg4 -q:v 12 -pix_fmt yuv420p \
    -c:a aac -b:a 64k \
    -metadata:s:a:0 title=Track1 \
    -metadata:s:a:1 title=Track2 \
    -metadata:s:a:2 title=Track3 \
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
  assert_eq "$(default_output_mode)" "$(file_mode "$merged_file")" "new merged output should honor umask"

  chmod 0660 "$merged_file"
  run_pipeline "$test_home" -c -e concat 2099-02-01
  assert_eq 0 "$LAST_STATUS" "repeated concat stage should succeed"
  assert_eq 660 "$(file_mode "$merged_file")" "replaced merged output should preserve existing permissions"
}

test_single_segment_concat_preserves_source_permissions() {
  local test_home
  local source_file
  local merged_file
  test_home=$(new_home)
  source_file="$test_home/Videos/OBS/2099-02-06 20-00-00.mkv"
  merged_file="$test_home/Videos/OBS/final/merged_2099-02-06.mkv"

  create_three_stream_segment "$source_file"
  chmod 0600 "$source_file"

  run_pipeline_with_umask "$test_home" 0277 -c -e concat 2099-02-06
  assert_eq 0 "$LAST_STATUS" "single-segment concat should succeed with owner-write masked by umask"
  assert_eq 400 "$(file_mode "$merged_file")" "single-segment concat should retain masked source permissions"
}

test_restrictive_umask_keeps_temporary_outputs_writable() {
  local test_home
  local merged_file
  local processed_audio
  local output_file
  local file_list
  test_home=$(new_home)
  merged_file="$test_home/Videos/OBS/final/merged_2099-02-07.mkv"
  processed_audio="$test_home/Videos/OBS/final/processed_audio_2099-02-07.m4a"
  output_file="$test_home/Videos/OBS/final/DSA5 mit Marth 07.02.2099 final.mp4"
  file_list="$test_home/Videos/OBS/final/filelist_mkv_2099-02-07.txt"

  create_three_stream_segment "$test_home/Videos/OBS/2099-02-07 20-00-00.mkv"
  create_three_stream_segment "$test_home/Videos/OBS/2099-02-07 20-00-01.mkv"

  run_pipeline_with_umask "$test_home" 0277 -c -e concat,audio,video 2099-02-07
  assert_eq 0 "$LAST_STATUS" "full media pipeline should succeed with owner-write masked by umask"

  if [ ! -s "$file_list" ]; then
    fail "concat file list should be written completely with restrictive umask"
  fi
  assert_eq 400 "$(file_mode "$merged_file")" "new merged output should publish the restrictive umask mode"
  assert_eq 400 "$(file_mode "$processed_audio")" "new processed audio should publish the restrictive umask mode"
  assert_eq 400 "$(file_mode "$output_file")" "new final MP4 should publish the restrictive umask mode"
}

test_audio_and_video_stages_create_outputs() {
  local profile="$1"
  local date="$2"
  local formatted_date="$3"
  local test_home
  local processed_audio
  local output_file
  local keyframe_interval
  local log_file
  test_home=$(new_home)
  processed_audio="$test_home/Videos/OBS/final/processed_audio_${date}.m4a"
  output_file="$test_home/Videos/OBS/final/DSA5 mit Marth ${formatted_date} final.mp4"

  create_three_stream_segment "$test_home/Videos/OBS/$date 20-00-00.mkv"
  create_three_stream_segment "$test_home/Videos/OBS/$date 20-00-01.mkv"

  run_pipeline "$test_home" -c -e concat,audio,video -m "$profile" "$date"
  assert_eq 0 "$LAST_STATUS" "concat,audio,video stages should succeed for $profile"
  assert_contains "FFmpeg: frame=" "video progress should remain visible in terminal output"

  log_file=$(find "$test_home/Videos/OBS/final" -maxdepth 1 -name "full_pipeline_${date}_*.log" -print -quit)
  if [ -z "$log_file" ]; then
    fail "media pipeline should create a log for $profile"
  fi
  if grep -Fq 'FFmpeg: frame=' "$log_file"; then
    fail "FFmpeg progress must not be written to the pipeline log"
  fi

  if [ ! -s "$processed_audio" ]; then
    fail "processed audio should be created for $profile"
  fi
  if [ ! -s "$output_file" ]; then
    fail "final MP4 should be created for $profile"
  fi
  assert_eq 1 "$(audio_stream_count "$processed_audio")" "processed audio should contain 1 audio stream"
  assert_eq 1 "$(audio_stream_count "$output_file")" "final MP4 should contain 1 audio stream"
  assert_eq 48000 "$(audio_sample_rate "$processed_audio")" "processed audio should use 48 kHz"
  assert_eq h264 "$(video_property "$output_file" codec_name)" "final MP4 should use H.264"
  assert_eq High "$(video_property "$output_file" profile)" "final MP4 should use H.264 High Profile"
  assert_eq yuv420p "$(video_property "$output_file" pix_fmt)" "final MP4 should use 4:2:0 chroma subsampling"
  assert_eq 160 "$(video_property "$output_file" width)" "final MP4 should preserve video width"
  assert_eq 90 "$(video_property "$output_file" height)" "final MP4 should preserve video height"
  assert_eq 10/1 "$(video_property "$output_file" r_frame_rate)" "final MP4 should preserve frame rate"
  assert_eq 2 "$(video_property "$output_file" has_b_frames)" "final MP4 should use two B-frames"
  assert_eq progressive "$(video_property "$output_file" field_order)" "final MP4 should be progressive"
  assert_eq tv "$(video_property "$output_file" color_range)" "final MP4 should use limited color range"
  assert_eq bt709 "$(video_property "$output_file" color_space)" "final MP4 should declare BT.709 matrix coefficients"
  assert_eq bt709 "$(video_property "$output_file" color_transfer)" "final MP4 should declare BT.709 transfer characteristics"
  assert_eq bt709 "$(video_property "$output_file" color_primaries)" "final MP4 should declare BT.709 primaries"
  if ! keyframe_interval=$(maximum_keyframe_interval "$output_file"); then
    fail "final MP4 should contain enough keyframes to validate its GOP"
  fi
  if ! awk -v gap="$keyframe_interval" 'BEGIN { exit !(gap <= 0.501) }'; then
    fail "final MP4 GOP should not exceed half a second (got ${keyframe_interval}s)"
  fi
  assert_eq "$(default_output_mode)" "$(file_mode "$processed_audio")" "new processed audio should honor umask"
  assert_eq "$(default_output_mode)" "$(file_mode "$output_file")" "new final MP4 should honor umask"

  chmod 0660 "$processed_audio"
  run_pipeline "$test_home" -c -e audio -m "$profile" "$date"
  assert_eq 0 "$LAST_STATUS" "repeated audio stage should succeed for $profile"
  assert_eq 660 "$(file_mode "$processed_audio")" "replaced processed audio should preserve existing permissions"

  chmod 0660 "$output_file"
  run_pipeline "$test_home" -c -e video -m "$profile" "$date"
  assert_eq 0 "$LAST_STATUS" "repeated video stage should succeed for $profile"
  assert_eq 660 "$(file_mode "$output_file")" "replaced final MP4 should preserve existing permissions"
}

test_audio_stage_rejects_non_three_stream_layout() {
  local test_home
  test_home=$(new_home)

  create_one_stream_segment "$test_home/Videos/OBS/2099-02-03 20-00-00.mkv"

  run_pipeline "$test_home" -c -e audio 2099-02-03
  assert_eq 1 "$LAST_STATUS" "audio stage should reject one-stream layout"
  assert_contains "Erwartet sind exakt 3 Audio-Streams" "audio stream count error should be clear"
}

test_audio_stage_uses_independent_track_inputs() {
  local test_home
  local fake_bin
  local fake_ffmpeg
  local args_log
  local merged_file
  test_home=$(new_home)
  fake_bin="$test_home/fake-bin"
  fake_ffmpeg="$fake_bin/ffmpeg"
  args_log="$test_home/ffmpeg-args.txt"
  merged_file="$test_home/Videos/OBS/final/merged_2099-02-09.mkv"

  create_three_stream_segment "$merged_file"
  mkdir -p "$fake_bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'args_log=%q\n' "$args_log"
    # shellcheck disable=SC2016 # The single-quoted lines are the fake script body.
    printf '%s\n' \
      'printf "%s\n" "$@" >"$args_log"' \
      'for arg in "$@"; do output_file="$arg"; done' \
      'printf "fake audio" >"$output_file"'
  } >"$fake_ffmpeg"
  chmod +x "$fake_ffmpeg"

  run_pipeline_with_path "$test_home" "$fake_bin" -c -e audio 2099-02-09
  assert_eq 0 "$LAST_STATUS" "audio stage should succeed with the recording opened independently"
  assert_eq 3 "$(grep -Fxc -- "$merged_file" "$args_log")" "audio stage should open the merged file three times"

  if ! grep -Fq '[0:a:0]' "$args_log" ||
    ! grep -Fq '[1:a:1]' "$args_log" ||
    ! grep -Fq '[2:a:2]' "$args_log"; then
    fail "audio filter should map Discord, Foundry, and microphone from independent inputs"
  fi
}

test_delayed_audio_tracks_survive_processing() {
  local test_home
  local processed_audio
  test_home=$(new_home)
  processed_audio="$test_home/Videos/OBS/final/processed_audio_2099-02-10.m4a"

  create_delayed_activity_segment "$test_home/Videos/OBS/2099-02-10 20-00-00.mkv"
  run_pipeline "$test_home" -c -e audio 2099-02-10
  assert_eq 0 "$LAST_STATUS" "audio stage should process tracks that become active at different times"
  assert_audio_window_audible "$processed_audio" 0.5 2 "Discord window should remain audible"
  assert_audio_window_audible "$processed_audio" 3.25 2 "delayed Foundry window should remain audible"
  assert_audio_window_audible "$processed_audio" 6 2 "delayed microphone window should remain audible"
}

test_failed_video_stage_preserves_existing_output() {
  local test_home
  local fake_bin
  local real_ffmpeg
  local output_file
  local original_output
  test_home=$(new_home)
  fake_bin="$test_home/fake-bin"
  output_file="$test_home/Videos/OBS/final/DSA5 mit Marth 05.02.2099 final.mp4"
  original_output="$test_home/original-final.mp4"
  real_ffmpeg=$(command -v ffmpeg)

  create_three_stream_segment "$test_home/Videos/OBS/2099-02-05 20-00-00.mkv"
  run_pipeline "$test_home" -c -e concat,audio,video 2099-02-05
  assert_eq 0 "$LAST_STATUS" "initial video build should succeed"
  cp "$output_file" "$original_output"

  mkdir -p "$fake_bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'real_ffmpeg=%q\n' "$real_ffmpeg"
    # shellcheck disable=SC2016 # The single-quoted lines are the fake script body.
    printf '%s\n' \
      'if [[ " $* " == *" -h encoder=libx264 "* ]]; then exec "$real_ffmpeg" "$@"; fi' \
      'for arg in "$@"; do output_file="$arg"; done' \
      'printf broken >"$output_file"' \
      'exit 1'
  } >"$fake_bin/ffmpeg"
  chmod +x "$fake_bin/ffmpeg"

  run_pipeline_with_path "$test_home" "$fake_bin" -c -e video 2099-02-05
  assert_eq 1 "$LAST_STATUS" "failing video encode should fail the pipeline"

  if ! cmp -s "$original_output" "$output_file"; then
    fail "failed video encode must preserve the previous final MP4"
  fi

  if find "$test_home/Videos/OBS/final" -maxdepth 1 -name '.final_2099-02-05.*.mp4' -print -quit | grep -q .; then
    fail "failed video encode should clean up its temporary output"
  fi
}

test_invalid_output_target_types_are_rejected() {
  local test_home
  local output_file
  local symlink_target
  test_home=$(new_home)
  output_file="$test_home/Videos/OBS/final/DSA5 mit Marth 08.02.2099 final.mp4"
  symlink_target="$test_home/symlink-target"

  create_three_stream_segment "$test_home/Videos/OBS/2099-02-08 20-00-00.mkv"
  run_pipeline "$test_home" -c -e concat,audio 2099-02-08
  assert_eq 0 "$LAST_STATUS" "video prerequisites should be created"

  mkdir "$output_file"
  run_pipeline "$test_home" -c -e video 2099-02-08
  assert_eq 1 "$LAST_STATUS" "directory output target must be rejected"
  assert_contains "Ausgabeziel ist keine regulaere Datei" "directory target error should be explicit"
  if [ ! -d "$output_file" ]; then
    fail "directory output target should remain untouched"
  fi
  if find "$output_file" -mindepth 1 -print -quit | grep -q .; then
    fail "temporary output must not be moved inside a directory target"
  fi

  rmdir "$output_file"
  mkdir "$symlink_target"
  ln -s "$symlink_target" "$output_file"

  run_pipeline "$test_home" -c -e video 2099-02-08
  assert_eq 1 "$LAST_STATUS" "symlink output target must be rejected"
  assert_contains "Ausgabeziel darf kein symbolischer Link sein" "symlink target error should be explicit"
  if [ ! -L "$output_file" ]; then
    fail "symlink output target should remain untouched"
  fi
  if find "$symlink_target" -mindepth 1 -print -quit | grep -q .; then
    fail "temporary output must not be moved through a symlink target"
  fi
}

main() {
  require_cmd ffmpeg
  require_cmd ffprobe
  require_cmd stat
  require_ffmpeg_encoder aac
  require_ffmpeg_encoder mpeg4
  require_ffmpeg_encoder libx264

  test_concat_preserves_three_audio_streams
  test_single_segment_concat_preserves_source_permissions
  test_restrictive_umask_keeps_temporary_outputs_writable
  test_audio_and_video_stages_create_outputs balanced 2099-02-02 02.02.2099
  test_audio_and_video_stages_create_outputs voice-priority 2099-02-04 04.02.2099
  test_audio_stage_rejects_non_three_stream_layout
  test_audio_stage_uses_independent_track_inputs
  test_delayed_audio_tracks_survive_processing
  test_failed_video_stage_preserves_existing_output
  test_invalid_output_target_types_are_rejected

  printf 'All media pipeline smoke tests passed.\n'
}

main "$@"
