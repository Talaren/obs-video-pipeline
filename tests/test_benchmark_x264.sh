#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BENCHMARK_SCRIPT="$REPO_DIR/benchmark_x264.sh"

TEST_TMP_ROOT="$(mktemp -d)"
SOURCE_FILE="$TEST_TMP_ROOT/source.mkv"
LAST_OUTPUT=""
LAST_STATUS=0
BENCHMARK_TEST_PATH="$PATH"

cleanup() {
  rm -rf -- "$TEST_TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [ -n "$LAST_OUTPUT" ]; then
    printf '%s\n' '--- last output ---' "$LAST_OUTPUT" '-------------------' >&2
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

run_benchmark() {
  set +e
  LAST_OUTPUT=$(HOME="$TEST_TMP_ROOT" PATH="$BENCHMARK_TEST_PATH" \
    X264_BENCHMARK_INHIBITED=1 "$BENCHMARK_SCRIPT" "$@" 2>&1)
  LAST_STATUS=$?
  set -e
}

touch "$SOURCE_FILE"

run_benchmark -d -o "$TEST_TMP_ROOT/throughput" "$SOURCE_FILE"
assert_eq 0 "$LAST_STATUS" "throughput dry-run should succeed"
assert_contains "Testprofil: throughput" "default profile should be throughput"
assert_contains "slow_crf18_t32_la8" "throughput profile should include the 32-thread comparison"
assert_contains "medium_crf18_auto" "throughput profile should include preset medium"
if [ -e "$TEST_TMP_ROOT/throughput" ]; then
  fail "dry-run must not create its output directory"
fi

run_benchmark -d -P quality -a 00:00:00 -t 30 -o "$TEST_TMP_ROOT/quality" "$SOURCE_FILE"
assert_eq 0 "$LAST_STATUS" "quality dry-run should succeed"
assert_contains "Testprofil: quality" "selected quality profile should be shown"
assert_contains "medium_crf21_auto" "quality profile should include CRF 21"
assert_contains "Ausschnitte: 00:00:00 (je 30 Sekunden)" "custom samples should be shown"
assert_not_contains "slow_crf18_auto" "quality profile should contain only preset medium"
if [ -e "$TEST_TMP_ROOT/quality" ]; then
  fail "quality dry-run must not create its output directory"
fi

run_benchmark -d -P invalid "$SOURCE_FILE"
assert_eq 1 "$LAST_STATUS" "unknown profile must fail"
assert_contains "Unbekanntes Benchmark-Profil" "unknown profile error should be clear"

run_benchmark -d -a 01:60:00 "$SOURCE_FILE"
assert_eq 1 "$LAST_STATUS" "invalid sample timestamp must fail"
assert_contains "Ungueltige Startzeit" "invalid timestamp error should be clear"

run_benchmark -d -t 0 "$SOURCE_FILE"
assert_eq 1 "$LAST_STATUS" "zero sample duration must fail"
assert_contains "positive Ganzzahl" "invalid duration error should be clear"

run_benchmark -d -w invalid "$SOURCE_FILE"
assert_eq 1 "$LAST_STATUS" "invalid wait PID must fail"
assert_contains "positive Prozess-ID" "invalid PID error should be clear"

run_benchmark -d "$TEST_TMP_ROOT/missing.mkv"
assert_eq 1 "$LAST_STATUS" "missing source must fail"
assert_contains "Quelldatei wurde nicht gefunden" "missing source error should be clear"

mkdir "$TEST_TMP_ROOT/fake-bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf " .. libvmaf VV->V\\n"' \
  >"$TEST_TMP_ROOT/fake-bin/ffmpeg"
chmod +x "$TEST_TMP_ROOT/fake-bin/ffmpeg"
BENCHMARK_TEST_PATH="$TEST_TMP_ROOT/fake-bin:$PATH"
run_benchmark -a 00:00:00 -t 1 -o "$TEST_TMP_ROOT/invalid-source" "$SOURCE_FILE"
assert_eq 1 "$LAST_STATUS" "invalid media source must fail"
assert_contains "Videodauer konnte nicht" "invalid media error should identify the failed probe"

printf 'All x264 benchmark control-flow tests passed.\n'
