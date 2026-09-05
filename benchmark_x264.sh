#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_ARGS=("$@")

DRY_RUN=false
WAIT_PID=""
BENCHMARK_PROFILE="throughput"
SAMPLE_DURATION=60
SAMPLE_TIMES_CSV="00:20:00,01:20:00,02:30:00"
OUTPUT_DIR=""
SYSTEMD_INHIBIT_BIN="${SYSTEMD_INHIBIT_BIN:-systemd-inhibit}"

show_help() {
  cat <<'EOF'
Verwendung: ./benchmark_x264.sh [Optionen] QUELLDATEI

Vergleicht mehrere libx264-Konfigurationen mit Ausschnitten aus einer echten
OBS-Aufnahme. Die Quelldatei wird nur gelesen; Audio wird nicht verarbeitet.

Optionen:
  -d             Dry-Run: Testplan anzeigen, keine Dateien erzeugen
  -w PID         Warten, bis der angegebene Prozess beendet ist
  -t SEKUNDEN    Laenge jedes Ausschnitts (Standard: 60)
  -a ZEITEN      Kommagetrennte Startzeiten HH:MM:SS
                 (Standard: 00:20:00,01:20:00,02:30:00)
  -o VERZEICHNIS Ergebnisverzeichnis (muss noch nicht existieren)
  -P PROFIL      Testprofil: throughput (Standard) oder quality
  -h             Hilfe

Ergebnisse:
  results.csv    Einzelmessungen
  summary.csv    Zusammenfassung je Konfiguration
  *.mp4          Codierte Testausschnitte
  *.encode.log   Kurzes FFmpeg-/x264-Protokoll
  *.vmaf.log     Qualitätsmessung gegen die OBS-Quelle
EOF
}

log_msg() {
  printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_msg "Fehler: Benoetigtes Kommando '$1' wurde nicht gefunden."
    exit 1
  fi
}

timestamp_to_seconds() {
  local timestamp="$1"

  awk -v timestamp="$timestamp" 'BEGIN {
    count = split(timestamp, parts, ":")
    if (count != 3 || parts[1] !~ /^[0-9]+$/ || parts[2] !~ /^[0-9][0-9]$/ ||
        parts[3] !~ /^[0-9][0-9]$/ || parts[2] >= 60 || parts[3] >= 60) {
      exit 1
    }
    print (parts[1] * 3600) + (parts[2] * 60) + parts[3]
  }'
}

process_start_time() {
  local pid="$1"
  local process_stat

  process_stat=$(<"/proc/$pid/stat") || return 1
  process_stat="${process_stat##*) }"
  awk '{ print $20 }' <<<"$process_stat"
}

wait_for_process() {
  local pid="$1"
  local expected_start_time
  local current_start_time

  if [ ! -r "/proc/$pid/stat" ]; then
    log_msg "Warteprozess $pid laeuft bereits nicht mehr."
    return
  fi

  if ! expected_start_time=$(process_start_time "$pid"); then
    log_msg "Warteprozess $pid wurde waehrend der Pruefung beendet."
    return
  fi
  log_msg "Warte auf das Ende von Prozess $pid..."

  while kill -0 "$pid" 2>/dev/null; do
    if [ ! -r "/proc/$pid/stat" ]; then
      break
    fi
    if ! current_start_time=$(process_start_time "$pid"); then
      break
    fi
    if [ "$current_start_time" != "$expected_start_time" ]; then
      break
    fi
    sleep 15
  done

  log_msg "Prozess $pid ist beendet; Benchmark startet."
}

while getopts ":da:ho:P:t:w:" opt; do
  case "$opt" in
    d) DRY_RUN=true ;;
    a) SAMPLE_TIMES_CSV="$OPTARG" ;;
    h)
      show_help
      exit 0
      ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    P) BENCHMARK_PROFILE="${OPTARG,,}" ;;
    t) SAMPLE_DURATION="$OPTARG" ;;
    w) WAIT_PID="$OPTARG" ;;
    \?)
      printf 'Ungueltige Option: -%s\n' "$OPTARG" >&2
      exit 1
      ;;
    :)
      printf 'Option -%s erfordert ein Argument.\n' "$OPTARG" >&2
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

if [ "$#" -ne 1 ]; then
  printf 'Fehler: Genau eine Quelldatei wird erwartet.\n' >&2
  show_help >&2
  exit 1
fi

SOURCE_FILE="$1"
if [ ! -f "$SOURCE_FILE" ]; then
  printf 'Fehler: Quelldatei wurde nicht gefunden: %s\n' "$SOURCE_FILE" >&2
  exit 1
fi

if [[ ! "$SAMPLE_DURATION" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Fehler: -t erwartet eine positive Ganzzahl.\n' >&2
  exit 1
fi

if [ -n "$WAIT_PID" ] && [[ ! "$WAIT_PID" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Fehler: -w erwartet eine positive Prozess-ID.\n' >&2
  exit 1
fi

IFS=',' read -r -a SAMPLE_TIMES <<<"$SAMPLE_TIMES_CSV"
if [ "${#SAMPLE_TIMES[@]}" -eq 0 ]; then
  printf 'Fehler: Mindestens eine Startzeit wird benoetigt.\n' >&2
  exit 1
fi

for sample_time in "${SAMPLE_TIMES[@]}"; do
  if ! timestamp_to_seconds "$sample_time" >/dev/null; then
    printf 'Fehler: Ungueltige Startzeit: %s (erwartet: HH:MM:SS)\n' "$sample_time" >&2
    exit 1
  fi
done

if [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="$HOME/Videos/OBS/final/x264-benchmark_$(date +'%Y%m%d_%H%M%S')"
fi

case "$BENCHMARK_PROFILE" in
  throughput)
    VARIANT_NAMES=(
      slow_crf18_auto
      slow_crf18_la8
      slow_crf18_t16_la8
      slow_crf18_t32_la8
      medium_crf18_auto
      slow_crf20_la8
    )
    VARIANT_PRESETS=(slow slow slow slow medium slow)
    VARIANT_CRFS=(18 18 18 18 18 20)
    VARIANT_THREADS=(auto auto 16 32 auto auto)
    VARIANT_LOOKAHEADS=(auto 8 8 8 auto 8)
    ;;
  quality)
    VARIANT_NAMES=(
      medium_crf18_auto
      medium_crf20_auto
      medium_crf21_auto
      medium_crf22_auto
      medium_crf24_auto
    )
    VARIANT_PRESETS=(medium medium medium medium medium)
    VARIANT_CRFS=(18 20 21 22 24)
    VARIANT_THREADS=(auto auto auto auto auto)
    VARIANT_LOOKAHEADS=(auto auto auto auto auto)
    ;;
  *)
    printf 'Fehler: Unbekanntes Benchmark-Profil: %s (erlaubt: throughput, quality)\n' \
      "$BENCHMARK_PROFILE" >&2
    exit 1
    ;;
esac

if [ "$DRY_RUN" = true ]; then
  printf 'x264-Benchmark (Dry-Run)\n'
  printf 'Quelle: %s\n' "$SOURCE_FILE"
  printf 'Testprofil: %s\n' "$BENCHMARK_PROFILE"
  printf 'Warte-PID: %s\n' "${WAIT_PID:-keine}"
  printf 'Ausschnitte: %s (je %s Sekunden)\n' "$SAMPLE_TIMES_CSV" "$SAMPLE_DURATION"
  printf 'Ausgabe: %s\n' "$OUTPUT_DIR"
  printf 'Varianten:\n'
  for index in "${!VARIANT_NAMES[@]}"; do
    printf '  %s: preset=%s, crf=%s, threads=%s, lookahead_threads=%s\n' \
      "${VARIANT_NAMES[$index]}" \
      "${VARIANT_PRESETS[$index]}" \
      "${VARIANT_CRFS[$index]}" \
      "${VARIANT_THREADS[$index]}" \
      "${VARIANT_LOOKAHEADS[$index]}"
  done
  printf 'Dry-Run: keine Dateien werden erstellt.\n'
  exit 0
fi

require_cmd ffmpeg
require_cmd ffprobe
require_cmd awk
require_cmd /usr/bin/time
require_cmd nproc
require_cmd grep

FFMPEG_FILTERS=$(ffmpeg -hide_banner -filters 2>/dev/null)
if ! grep -Eq '[[:space:]]libvmaf[[:space:]]' <<<"$FFMPEG_FILTERS"; then
  log_msg "Fehler: Diese FFmpeg-Installation enthaelt den Filter libvmaf nicht."
  exit 1
fi

if [ "${X264_BENCHMARK_INHIBITED:-}" != "1" ]; then
  require_cmd "$SYSTEMD_INHIBIT_BIN"
  export X264_BENCHMARK_INHIBITED=1
  exec "$SYSTEMD_INHIBIT_BIN" \
    --what="${X264_BENCHMARK_INHIBIT_WHAT:-sleep}" \
    --who=obs-video-pipeline-x264-benchmark \
    --why="x264-Benchmark mit OBS-Aufnahme" \
    --mode=block \
    -- "$SCRIPT_DIR/benchmark_x264.sh" "${ORIGINAL_ARGS[@]}"
fi

if [ -n "$WAIT_PID" ]; then
  wait_for_process "$WAIT_PID"
fi

if ! SOURCE_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SOURCE_FILE"); then
  log_msg "Fehler: Videodauer konnte nicht aus $SOURCE_FILE gelesen werden."
  exit 1
fi
if ! SOURCE_FRAME_RATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$SOURCE_FILE"); then
  log_msg "Fehler: Bildrate konnte nicht aus $SOURCE_FILE gelesen werden."
  exit 1
fi
if ! SOURCE_WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$SOURCE_FILE") ||
  ! SOURCE_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$SOURCE_FILE"); then
  log_msg "Fehler: Videogroesse konnte nicht aus $SOURCE_FILE gelesen werden."
  exit 1
fi
CPU_COUNT=$(nproc)

if [[ ! "$SOURCE_DURATION" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
  ! awk -v duration="$SOURCE_DURATION" 'BEGIN { exit !(duration > 0) }'; then
  log_msg "Fehler: Videodauer konnte nicht aus $SOURCE_FILE gelesen werden."
  exit 1
fi
if [[ ! "$SOURCE_WIDTH" =~ ^[1-9][0-9]*$ ]] || [[ ! "$SOURCE_HEIGHT" =~ ^[1-9][0-9]*$ ]]; then
  log_msg "Fehler: Videogroesse konnte nicht aus $SOURCE_FILE gelesen werden."
  exit 1
fi

if ! GOP_SIZE=$(awk -v rate="$SOURCE_FRAME_RATE" 'BEGIN {
  count = split(rate, parts, "/")
  if (count != 2 || parts[1] <= 0 || parts[2] <= 0) {
    exit 1
  }
  gop = int((parts[1] / parts[2] / 2) + 0.5)
  if (gop < 1) {
    gop = 1
  }
  print gop
}'); then
  log_msg "Fehler: Bildrate konnte nicht gelesen werden ($SOURCE_FRAME_RATE)."
  exit 1
fi

FRAME_RATE_DECIMAL=$(awk -v rate="$SOURCE_FRAME_RATE" 'BEGIN {
  split(rate, parts, "/")
  printf "%.8f", parts[1] / parts[2]
}')

for sample_time in "${SAMPLE_TIMES[@]}"; do
  sample_seconds=$(timestamp_to_seconds "$sample_time")
  if ! awk -v start="$sample_seconds" -v sample_length="$SAMPLE_DURATION" -v total="$SOURCE_DURATION" \
    'BEGIN { exit !((start + sample_length) <= total) }'; then
    log_msg "Fehler: Ausschnitt $sample_time + ${SAMPLE_DURATION}s liegt ausserhalb der Quelldatei (${SOURCE_DURATION}s)."
    exit 1
  fi
done

if [ -e "$OUTPUT_DIR" ]; then
  log_msg "Fehler: Ergebnisverzeichnis existiert bereits: $OUTPUT_DIR"
  exit 1
fi
mkdir -- "$OUTPUT_DIR"

RESULTS_FILE="$OUTPUT_DIR/results.csv"
SUMMARY_FILE="$OUTPUT_DIR/summary.csv"
printf '%s\n' \
  'variant,preset,crf,threads,lookahead_threads,gop,sample_start,duration_seconds,elapsed_seconds,cpu_percent,fps,size_bytes,bit_rate,vmaf' \
  >"$RESULTS_FILE"

log_msg "Quelle: $SOURCE_FILE"
log_msg "Video: ${SOURCE_WIDTH}x${SOURCE_HEIGHT}, $SOURCE_FRAME_RATE FPS, Dauer ${SOURCE_DURATION}s"
log_msg "Testprofil: $BENCHMARK_PROFILE"
log_msg "Teste ${#VARIANT_NAMES[@]} Varianten an ${#SAMPLE_TIMES[@]} Ausschnitten zu je ${SAMPLE_DURATION}s."
log_msg "Ergebnisse: $OUTPUT_DIR"

for index in "${!VARIANT_NAMES[@]}"; do
  variant="${VARIANT_NAMES[$index]}"
  preset="${VARIANT_PRESETS[$index]}"
  crf="${VARIANT_CRFS[$index]}"
  threads="${VARIANT_THREADS[$index]}"
  lookahead="${VARIANT_LOOKAHEADS[$index]}"

  for sample_time in "${SAMPLE_TIMES[@]}"; do
    sample_label="${sample_time//:/}"
    output_file="$OUTPUT_DIR/${variant}_${sample_label}.mp4"
    encode_log="$OUTPUT_DIR/${variant}_${sample_label}.encode.log"
    time_file="$OUTPUT_DIR/${variant}_${sample_label}.time"
    vmaf_log="$OUTPUT_DIR/${variant}_${sample_label}.vmaf.log"
    x264_params='open-gop=0:colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited'
    thread_args=()

    if [ "$lookahead" != auto ]; then
      x264_params+=":lookahead-threads=$lookahead"
    fi
    if [ "$threads" != auto ]; then
      thread_args=(-threads "$threads")
    fi

    log_msg "Kodiere $variant, Ausschnitt $sample_time..."
    if ! /usr/bin/time \
      -f $'elapsed_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\ncpu_percent=%P\nmax_rss_kib=%M' \
      -o "$time_file" \
      ffmpeg -y -hide_banner -loglevel info -nostats \
      -ss "$sample_time" -t "$SAMPLE_DURATION" -i "$SOURCE_FILE" \
      -map 0:v:0 -an \
      -c:v libx264 -preset "$preset" -crf "$crf" \
      -profile:v high -pix_fmt yuv420p -coder cabac \
      -g "$GOP_SIZE" -keyint_min 1 -bf 2 \
      -x264-params "$x264_params" \
      -r "$SOURCE_FRAME_RATE" -fps_mode cfr \
      -color_range tv -colorspace bt709 -color_trc bt709 -color_primaries bt709 \
      "${thread_args[@]}" \
      -movflags +faststart \
      "$output_file" >"$encode_log" 2>&1; then
      log_msg "Fehler: Codierung von $variant bei $sample_time fehlgeschlagen (Log: $encode_log)."
      exit 1
    fi

    elapsed_seconds=$(awk -F= '$1 == "elapsed_seconds" { print $2 }' "$time_file")
    cpu_percent=$(awk -F= '$1 == "cpu_percent" { gsub(/%/, "", $2); print $2 }' "$time_file")
    size_bytes=$(stat -c %s "$output_file")
    bit_rate=$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 "$output_file")
    fps=$(awk -v rate="$FRAME_RATE_DECIMAL" -v sample_length="$SAMPLE_DURATION" -v elapsed="$elapsed_seconds" \
      'BEGIN { printf "%.3f", (rate * sample_length) / elapsed }')

    log_msg "Ermittle VMAF fuer $variant, Ausschnitt $sample_time..."
    if ! ffmpeg -hide_banner -loglevel info -nostats \
      -ss "$sample_time" -t "$SAMPLE_DURATION" -i "$SOURCE_FILE" \
      -i "$output_file" \
      -filter_complex \
      '[0:v]setpts=PTS-STARTPTS,scale=1920:-2:flags=bicubic[reference];[1:v]setpts=PTS-STARTPTS,scale=1920:-2:flags=bicubic[distorted];[distorted][reference]libvmaf=n_threads=8' \
      -an -f null - >"$vmaf_log" 2>&1; then
      log_msg "Fehler: VMAF-Messung von $variant bei $sample_time fehlgeschlagen (Log: $vmaf_log)."
      exit 1
    fi
    vmaf=$(awk '/VMAF score:/ { score=$NF } END { print score }' "$vmaf_log")
    if [ -z "$vmaf" ]; then
      log_msg "Fehler: VMAF-Ergebnis fehlt fuer $variant, Ausschnitt $sample_time."
      exit 1
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$variant" "$preset" "$crf" "$threads" "$lookahead" "$GOP_SIZE" \
      "$sample_time" "$SAMPLE_DURATION" "$elapsed_seconds" "$cpu_percent" \
      "$fps" "$size_bytes" "$bit_rate" "$vmaf" >>"$RESULTS_FILE"
  done
done

printf '%s\n' \
  'variant,total_elapsed_seconds,process_cpu_percent,total_cpu_capacity_percent,aggregate_fps,total_size_bytes,aggregate_bit_rate,projected_full_video_size_bytes,projected_full_video_size_gib,mean_vmaf' \
  >"$SUMMARY_FILE"
awk -F, -v cpu_count="$CPU_COUNT" -v source_duration="$SOURCE_DURATION" '
  NR > 1 {
    if (!seen[$1]++) {
      variants[++variant_count] = $1
    }
    elapsed[$1] += $9
    weighted_cpu[$1] += $10 * $9
    frames[$1] += $11 * $9
    size[$1] += $12
    duration[$1] += $8
    vmaf[$1] += $14
  }
  END {
    for (i = 1; i <= variant_count; i++) {
      name = variants[i]
      process_cpu = weighted_cpu[name] / elapsed[name]
      projected_size = (size[name] / duration[name]) * source_duration
      printf "%s,%.3f,%.2f,%.2f,%.3f,%.0f,%.0f,%.0f,%.3f,%.4f\n", name,
        elapsed[name], process_cpu, process_cpu / cpu_count, frames[name] / elapsed[name],
        size[name], size[name] * 8 / duration[name], projected_size,
        projected_size / 1073741824, vmaf[name] / seen[name]
    }
  }
' "$RESULTS_FILE" >>"$SUMMARY_FILE"

log_msg "Benchmark abgeschlossen. Zusammenfassung:"
column -s, -t "$SUMMARY_FILE" 2>/dev/null || sed 's/,/  /g' "$SUMMARY_FILE"
log_msg "Vollstaendige Ergebnisse: $OUTPUT_DIR"
