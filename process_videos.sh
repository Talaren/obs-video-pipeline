#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_ARGS=("$@")

CLEANUP=true
DRY_RUN=false
NOTIFY=false
SHUTDOWN=false
SHUTDOWN_CONTROL_ACTION=""
SHUTDOWN_CONTROL_FILE=""
SHUTDOWN_CONTROL_OWNED=false
SHUTDOWN_CONTROL_PID=""
SHUTDOWN_CONTROL_STATE=""
STAGES=""
FFMPEG_THREADS=""
FFMPEG="ffmpeg"
SYSTEMD_INHIBIT_BIN="${SYSTEMD_INHIBIT_BIN:-systemd-inhibit}"
SLEEP_INHIBIT_ACTIVE=false
AUDIO_MIX_PROFILE="${AUDIO_MIX_PROFILE:-balanced}"
VIDEO_X264_PRESET="${VIDEO_X264_PRESET:-medium}"
VIDEO_X264_CRF="${VIDEO_X264_CRF:-21}"
YOUTUBE_UPLOAD_BIN="${YOUTUBE_UPLOAD_BIN:-$SCRIPT_DIR/yt_upload.sh}"
YOUTUBE_UPLOAD_PRIVACY="unlisted"
YOUTUBE_UPLOAD_DESCRIPTION="${YOUTUBE_UPLOAD_DESCRIPTION:-Archivaufnahme einer DSA5-Runde.}"
YOUTUBE_UPLOAD_TAGS="${YOUTUBE_UPLOAD_TAGS:-}"
YOUTUBE_UPLOAD_PLAYLIST_ID="${YOUTUBE_UPLOAD_PLAYLIST_ID:-}"
YOUTUBE_UPLOAD_PLAYLIST_POSITION="${YOUTUBE_UPLOAD_PLAYLIST_POSITION:-}"
YOUTUBE_UPLOAD_EXTRA_ARGS="${YOUTUBE_UPLOAD_EXTRA_ARGS:-}"
YOUTUBE_UPLOAD_PLAYLIST_PARTIAL_STATUS=3

TEMP_FILES=()

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

write_shutdown_control_file() {
  local control_file="$1"
  local pipeline_pid="$2"
  local control_state="$3"
  local temp_file

  if [ -L "$control_file" ] || { [ -e "$control_file" ] && [ ! -f "$control_file" ]; }; then
    log_msg "Fehler: Shutdown-Steuerdatei ist keine regulaere Datei ($control_file)."
    return 1
  fi

  temp_file=$(mktemp --tmpdir="${control_file%/*}" ".shutdown-control.XXXXXX")
  chmod 0600 -- "$temp_file"
  if ! printf 'pid=%s\nstate=%s\n' "$pipeline_pid" "$control_state" >"$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi
  if ! mv -fT -- "$temp_file" "$control_file"; then
    rm -f -- "$temp_file"
    return 1
  fi
}

read_shutdown_control_file() {
  local control_file="$1"
  local key
  local value

  SHUTDOWN_CONTROL_PID=""
  SHUTDOWN_CONTROL_STATE=""

  if [ -L "$control_file" ] || [ ! -f "$control_file" ]; then
    return 1
  fi

  while IFS='=' read -r key value; do
    case "$key" in
      pid) SHUTDOWN_CONTROL_PID="$value" ;;
      state) SHUTDOWN_CONTROL_STATE="$value" ;;
      *) return 1 ;;
    esac
  done <"$control_file"

  if [[ ! "$SHUTDOWN_CONTROL_PID" =~ ^[1-9][0-9]*$ ]]; then
    return 1
  fi
  case "$SHUTDOWN_CONTROL_STATE" in
    enabled | disabled) ;;
    *) return 1 ;;
  esac
}

cleanup_shutdown_control_file() {
  if [ "$SHUTDOWN_CONTROL_OWNED" = true ] && [ -n "$SHUTDOWN_CONTROL_FILE" ]; then
    if lock_shutdown_control; then
      rm -f -- "$SHUTDOWN_CONTROL_FILE"
      SHUTDOWN_CONTROL_OWNED=false
      unlock_shutdown_control
    fi
  fi
}

lock_shutdown_control() {
  if [ -z "$SHUTDOWN_CONTROL_FILE" ] || [ ! -d "${SHUTDOWN_CONTROL_FILE%/*}" ]; then
    return 1
  fi

  exec 9<"${SHUTDOWN_CONTROL_FILE%/*}"
  if ! flock -x 9; then
    exec 9<&-
    return 1
  fi
}

unlock_shutdown_control() {
  flock -u 9
  exec 9<&-
}

cleanup_temp_files() {
  local temp_file

  for temp_file in "${TEMP_FILES[@]}"; do
    if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
      rm -f -- "$temp_file"
    fi
  done
}

handle_error() {
  local exit_status="$1"

  trap - ERR
  cleanup_temp_files || true
  cleanup_shutdown_control_file || true
  log_msg "Skript unerwartet beendet. Fuehre ggf. Aufraeumarbeiten durch..."
  exit "$exit_status"
}

handle_signal() {
  local signal_name="$1"
  local exit_status="$2"

  trap - ERR INT TERM
  cleanup_temp_files || true
  cleanup_shutdown_control_file || true
  log_msg "Skript durch $signal_name beendet."
  exit "$exit_status"
}

trap 'handle_error $?' ERR
trap 'handle_signal SIGINT 130' INT
trap 'handle_signal SIGTERM 143' TERM
trap 'cleanup_shutdown_control_file' EXIT

show_help() {
  cat <<'EOF'
Verwendung: ./process_videos.sh [Optionen] DATUM

Optionen:
  -c             Kein Aufraeumen am Ende (Standard: Aufraeumen aktiv)
  -d             Dry-Run: geplante Schritte anzeigen, nichts ausfuehren
  -n             Benachrichtigung am Ende anzeigen
  -s             Statt Benachrichtigung am Ende Shutdown ausfuhren (setzt NOTIFY=false)
  -S ACTION      Shutdown eines laufenden -s-Prozesses steuern:
                 enable, disable oder status (jeweils mit dessen DATUM)
  -e STAGES      Auszufuhrende Schritte, kommagetrennt:
                 concat,audio,video,upload,clean
                 (Wenn -e nicht gesetzt ist: concat,audio,video,clean)
  -T THREADS     Anzahl Threads pro ffmpeg-Prozess (setzt -threads bei ffmpeg-Aufrufen)
  -m PROFILE     Audio-Mix-Profil: balanced (Default) oder voice-priority
  -p PRESET      libx264-Preset fuer Video (superfast bis placebo; Standard: medium)
  -q CRF         libx264-Qualitaet 1-51 (Standard: 21; kleiner = hoehere Qualitaet)
  -h             Hilfe

Audio-Annahme (ohne Fallback):
  a:0 = Discord (alle anderen Stimmen)
  a:1 = Foundry (Atmo/Musik, wird per Autoduck bei Sprache abgesenkt)
  a:2 = Eigene Stimme (Mikro)

YouTube-Upload:
  Standard-Uploadclient: ./yt_upload.sh (lokaler API-Client)
  Fuer den ersten Upload werden OAuth Client-Secrets benoetigt.
  Zusatzparameter via YOUTUBE_UPLOAD_EXTRA_ARGS (newline-separiert), z. B.:
  $'--client-secrets\n~/.config/yt-upload/client_secrets.json\n--token-file\n~/.config/yt-upload/token.json'
  Komfort-Variablen:
  YOUTUBE_UPLOAD_TAGS="dsa5,pen-and-paper"
  YOUTUBE_UPLOAD_PLAYLIST_ID="PLxxxx..."
  YOUTUBE_UPLOAD_PLAYLIST_POSITION="0"
EOF
}

while getopts ":cdnhe:S:T:m:p:q:s" opt; do
  case "$opt" in
    c)
      CLEANUP=false
      ;;
    d)
      DRY_RUN=true
      ;;
    n)
      NOTIFY=true
      ;;
    s)
      SHUTDOWN=true
      NOTIFY=false
      ;;
    S)
      SHUTDOWN_CONTROL_ACTION="${OPTARG,,}"
      ;;
    e)
      STAGES="$OPTARG"
      ;;
    T)
      FFMPEG_THREADS="$OPTARG"
      ;;
    m)
      AUDIO_MIX_PROFILE="$OPTARG"
      ;;
    p)
      VIDEO_X264_PRESET="$OPTARG"
      ;;
    q)
      VIDEO_X264_CRF="$OPTARG"
      ;;
    h)
      show_help
      exit 0
      ;;
    \?)
      echo "Ungueltige Option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG erfordert ein Argument." >&2
      exit 1
      ;;
  esac
done

shift $((OPTIND - 1))

if [ "$SHUTDOWN" = true ]; then
  NOTIFY=false
fi

if [ $# -eq 0 ]; then
  echo "Bitte gib ein Datum im Format YYYY-MM-DD an." >&2
  show_help >&2
  exit 1
fi

if [ $# -gt 1 ]; then
  echo "Zu viele Argumente: Erwartet wird genau ein Datum im Format YYYY-MM-DD." >&2
  exit 1
fi

DATE="$1"
if [[ ! "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Ungueltiges Datum: $DATE (erwartet: YYYY-MM-DD)" >&2
  exit 1
fi

if ! NORMALIZED_DATE=$(date -d "$DATE" +"%Y-%m-%d" 2>/dev/null) || [ "$NORMALIZED_DATE" != "$DATE" ]; then
  echo "Ungueltiges Datum: $DATE (erwartet: YYYY-MM-DD)" >&2
  exit 1
fi

if ! FORMATTED_DATE=$(date -d "$DATE" +"%d.%m.%Y" 2>/dev/null); then
  echo "Ungueltiges Datum: $DATE (erwartet: YYYY-MM-DD)" >&2
  exit 1
fi

VIDEO_DIR="$HOME/Videos/OBS"
OUTPUT_DIR="$HOME/Videos/OBS/final"

MERGED_FILE="$OUTPUT_DIR/merged_${DATE}.mkv"
PROCESSED_AUDIO="$OUTPUT_DIR/processed_audio_${DATE}.m4a"
FILE_LIST_MKV="$OUTPUT_DIR/filelist_mkv_${DATE}.txt"
OUTPUT_FILE="$OUTPUT_DIR/DSA5 mit Marth ${FORMATTED_DATE} final.mp4"
SHUTDOWN_CONTROL_FILE="$OUTPUT_DIR/.shutdown_${DATE}.control"

if [ -n "$SHUTDOWN_CONTROL_ACTION" ]; then
  case "$SHUTDOWN_CONTROL_ACTION" in
    enable | disable | status) ;;
    *)
      echo "Fehler: -S erwartet enable, disable oder status (erhalten: $SHUTDOWN_CONTROL_ACTION)." >&2
      exit 1
      ;;
  esac

  if ! command -v flock >/dev/null 2>&1; then
    echo "Fehler: Benoetigtes Kommando 'flock' wurde nicht gefunden." >&2
    exit 1
  fi
  if ! lock_shutdown_control; then
    echo "Fehler: Shutdown-Steuerung fuer $DATE konnte nicht gesperrt werden." >&2
    exit 1
  fi
  if ! read_shutdown_control_file "$SHUTDOWN_CONTROL_FILE"; then
    unlock_shutdown_control
    echo "Fehler: Keine gueltige Shutdown-Steuerung fuer $DATE gefunden. Laeuft die Pipeline mit -s?" >&2
    exit 1
  fi
  if ! kill -0 "$SHUTDOWN_CONTROL_PID" 2>/dev/null; then
    unlock_shutdown_control
    echo "Fehler: Der zur Shutdown-Steuerung gehoerende Prozess $SHUTDOWN_CONTROL_PID laeuft nicht mehr." >&2
    exit 1
  fi

  case "$SHUTDOWN_CONTROL_ACTION" in
    enable)
      write_shutdown_control_file "$SHUTDOWN_CONTROL_FILE" "$SHUTDOWN_CONTROL_PID" enabled
      printf 'Shutdown fuer Pipeline-Prozess %s aktiviert.\n' "$SHUTDOWN_CONTROL_PID"
      ;;
    disable)
      write_shutdown_control_file "$SHUTDOWN_CONTROL_FILE" "$SHUTDOWN_CONTROL_PID" disabled
      printf 'Shutdown fuer Pipeline-Prozess %s deaktiviert.\n' "$SHUTDOWN_CONTROL_PID"
      ;;
    status)
      if [ "$SHUTDOWN_CONTROL_STATE" = "enabled" ]; then
        printf 'Shutdown fuer Pipeline-Prozess %s: aktiviert.\n' "$SHUTDOWN_CONTROL_PID"
      else
        printf 'Shutdown fuer Pipeline-Prozess %s: deaktiviert.\n' "$SHUTDOWN_CONTROL_PID"
      fi
      ;;
  esac
  unlock_shutdown_control
  exit 0
fi

if [ "$DRY_RUN" = false ]; then
  if [ "${OBS_VIDEO_PIPELINE_INHIBITED:-}" = "1" ]; then
    SLEEP_INHIBIT_ACTIVE=true
  else
    if ! command -v "$SYSTEMD_INHIBIT_BIN" >/dev/null 2>&1; then
      echo "Fehler: Benoetigtes Kommando '$SYSTEMD_INHIBIT_BIN' wurde nicht gefunden; die Verarbeitung kann nicht gegen automatischen Ruhezustand geschuetzt werden." >&2
      exit 1
    fi

    export OBS_VIDEO_PIPELINE_INHIBITED=1
    exec "$SYSTEMD_INHIBIT_BIN" \
      --what=sleep \
      --who=obs-video-pipeline \
      --why="OBS-Videoverarbeitung fuer $DATE" \
      --mode=block \
      -- "$SCRIPT_DIR/process_videos.sh" "${ORIGINAL_ARGS[@]}"
  fi
fi

if [ "$DRY_RUN" = false ]; then
  mkdir -p "$OUTPUT_DIR"
  LOG_FILE="$OUTPUT_DIR/full_pipeline_${DATE}_$(date +"%Y%m%d_%H%M%S").log"
  exec 3>&1
  exec > >(tee -i "$LOG_FILE") 2>&1

  log_msg "Starte Prozess fuer Datum: $DATE"
  if [ "$SLEEP_INHIBIT_ACTIVE" = true ]; then
    log_msg "Schlafsperre aktiv (systemd: sleep; Bildschirmschoner und Monitorabschaltung bleiben erlaubt)."
  fi
fi

if [ -z "$STAGES" ]; then
  STAGES="concat,audio,video,clean"
fi

selected_stages=()
IFS=',' read -ra steps <<<"$STAGES"
for step in "${steps[@]}"; do
  normalized_step="${step,,}"
  normalized_step="${normalized_step//[[:space:]]/}"

  case "$normalized_step" in
    concat | audio | video | upload | clean)
      selected_stages+=("$normalized_step")
      ;;
    *)
      log_msg "Unbekannter Schritt: $step"
      exit 1
      ;;
  esac
done

stage_enabled() {
  local wanted="$1"
  local selected_stage

  for selected_stage in "${selected_stages[@]}"; do
    if [ "$selected_stage" = "$wanted" ]; then
      return 0
    fi
  done

  return 1
}

run_concat=false
run_audio=false
run_video=false
run_upload=false
run_clean=false

if stage_enabled concat; then
  run_concat=true
fi
if stage_enabled audio; then
  run_audio=true
fi
if stage_enabled video; then
  run_video=true
fi
if stage_enabled upload; then
  run_upload=true
fi
if stage_enabled clean; then
  run_clean=true
fi

if [ "$CLEANUP" = false ]; then
  run_clean=false
fi

explicit_concat=$run_concat
explicit_audio=$run_audio
explicit_video=$run_video

if $run_upload && [ ! -f "$OUTPUT_FILE" ]; then
  run_video=true
fi

if $run_video && [ ! -f "$PROCESSED_AUDIO" ]; then
  run_audio=true
fi

if { $run_audio || $run_video; } && [ ! -f "$MERGED_FILE" ]; then
  run_concat=true
fi

normalized_mix_profile="${AUDIO_MIX_PROFILE,,}"
normalized_mix_profile="${normalized_mix_profile//_/-}"
case "$normalized_mix_profile" in
  balanced | voice-priority)
    :
    ;;
  voice)
    normalized_mix_profile="voice-priority"
    ;;
  *)
    log_msg "Fehler: Unbekanntes Audio-Mix-Profil '$AUDIO_MIX_PROFILE' (erlaubt: balanced, voice-priority)."
    exit 1
    ;;
esac
AUDIO_MIX_PROFILE="$normalized_mix_profile"

case "$VIDEO_X264_PRESET" in
  superfast | veryfast | faster | fast | medium | slow | slower | veryslow | placebo)
    :
    ;;
  ultrafast)
    log_msg "Fehler: libx264-Preset 'ultrafast' erzeugt kein H.264 High Profile und wird nicht unterstuetzt."
    exit 1
    ;;
  *)
    log_msg "Fehler: Unbekanntes libx264-Preset '$VIDEO_X264_PRESET'."
    exit 1
    ;;
esac

if [[ ! "$VIDEO_X264_CRF" =~ ^[0-9]+$ ]] || [ "$VIDEO_X264_CRF" -lt 1 ] || [ "$VIDEO_X264_CRF" -gt 51 ]; then
  log_msg "Fehler: -q erwartet eine Ganzzahl von 1 bis 51 (erhalten: $VIDEO_X264_CRF)."
  exit 1
fi

if $run_audio && [ ! -f "$SCRIPT_DIR/filters/${AUDIO_MIX_PROFILE}.fffilter" ]; then
  log_msg "Fehler: Audio-Filterdatei fehlt: $SCRIPT_DIR/filters/${AUDIO_MIX_PROFILE}.fffilter"
  exit 1
fi

thread_option=()
if [ -n "$FFMPEG_THREADS" ]; then
  if [[ ! "$FFMPEG_THREADS" =~ ^[0-9]+$ ]]; then
    log_msg "Fehler: -T erwartet eine nicht-negative Ganzzahl (erhalten: $FFMPEG_THREADS)."
    exit 1
  fi
  thread_option=(-threads "$FFMPEG_THREADS")
fi

if [ "$DRY_RUN" = true ]; then
  planned_stages=()
  $run_concat && planned_stages+=(concat)
  $run_audio && planned_stages+=(audio)
  $run_video && planned_stages+=(video)
  $run_upload && planned_stages+=(upload)
  $run_clean && planned_stages+=(clean)

  printf 'Dry-Run fuer Datum: %s\n' "$DATE"
  printf 'Angeforderte Stages: %s\n' "$STAGES"
  if [ "${#planned_stages[@]}" -gt 0 ]; then
    (
      IFS=','
      printf 'Geplante Stages: %s\n' "${planned_stages[*]}"
    )
  else
    printf 'Geplante Stages: keine\n'
  fi
  if $run_concat && ! $explicit_concat; then
    printf 'Auto-Stage: concat, weil %s fehlt\n' "$MERGED_FILE"
  fi
  if $run_audio && ! $explicit_audio; then
    printf 'Auto-Stage: audio, weil %s fehlt\n' "$PROCESSED_AUDIO"
  fi
  if $run_video && ! $explicit_video; then
    printf 'Auto-Stage: video, weil %s fehlt\n' "$OUTPUT_FILE"
  fi
  printf 'Mix-Profil: %s\n' "$AUDIO_MIX_PROFILE"
  printf 'Video-Encoding: libx264, preset=%s, crf=%s\n' "$VIDEO_X264_PRESET" "$VIDEO_X264_CRF"
  printf 'FFmpeg-Threads: %s\n' "${FFMPEG_THREADS:-default}"
  printf 'Finale Datei: %s\n' "$OUTPUT_FILE"
  if [ "$SHUTDOWN" = true ]; then
    printf 'Abschlussaktion: shutdown\n'
  elif [ "$NOTIFY" = true ]; then
    printf 'Abschlussaktion: notify\n'
  else
    printf 'Abschlussaktion: keine\n'
  fi
  printf 'Dry-Run: keine Dateien werden erstellt, geaendert oder geloescht.\n'
  exit 0
fi

ffmpeg_common_args=(-y -loglevel error -hide_banner -nostats)

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_msg "Fehler: Benoetigtes Kommando '$1' wurde nicht gefunden."
    exit 1
  fi
}

format_ffmpeg_progress() {
  local frame="?"
  local fps="?"
  local quality="?"
  local total_size="?"
  local size_kib="?"
  local out_time="?"
  local bitrate="?"
  local speed="?"
  local progress=""
  local line_open=false
  local key
  local value

  while IFS='=' read -r key value; do
    case "$key" in
      frame) frame="$value" ;;
      fps) fps="$value" ;;
      stream_*_q) quality="$value" ;;
      total_size) total_size="$value" ;;
      out_time) out_time="$value" ;;
      bitrate) bitrate="$value" ;;
      speed) speed="$value" ;;
      progress)
        progress="$value"
        if [[ "$total_size" =~ ^[0-9]+$ ]]; then
          size_kib=$((total_size / 1024))
        else
          size_kib="?"
        fi
        printf '\rFFmpeg: frame=%s fps=%s q=%s size=%sKiB time=%s bitrate=%s speed=%s\033[K' \
          "$frame" "$fps" "$quality" "$size_kib" "$out_time" "$bitrate" "$speed"
        line_open=true
        if [ "$progress" = "end" ]; then
          printf '\n'
          line_open=false
        fi
        ;;
    esac
  done

  if [ "$line_open" = true ]; then
    printf '\n'
  fi
}

escape_for_concat_list() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

prepare_temp_output() {
  local temp_file="$1"

  TEMP_FILES+=("$temp_file")
  # mktemp's 0600 creation mode is still filtered by umask, while cp/ffmpeg
  # reopen the path. Keep it private but owner-writable until publication.
  chmod u+rw -- "$temp_file"
}

validate_output_target() {
  local target_file="$1"

  if [ -L "$target_file" ]; then
    log_msg "Fehler: Ausgabeziel darf kein symbolischer Link sein ($target_file)."
    return 1
  fi

  if [ -e "$target_file" ] && [ ! -f "$target_file" ]; then
    log_msg "Fehler: Ausgabeziel ist keine regulaere Datei ($target_file)."
    return 1
  fi
}

publish_temp_file() {
  local temp_file="$1"
  local target_file="$2"
  local new_file_reference="${3:-}"
  local current_umask
  local reference_mode
  local target_mode

  validate_output_target "$target_file"

  if [ -e "$target_file" ]; then
    if ! cp --attributes-only --preserve=mode,ownership,xattr -- "$target_file" "$temp_file"; then
      log_msg "Fehler: Metadaten des bestehenden Ausgabeziels konnten nicht uebernommen werden ($target_file)."
      return 1
    fi
  elif [ -n "$new_file_reference" ]; then
    current_umask=$(umask)
    reference_mode=$(stat -c '%a' "$new_file_reference")
    printf -v target_mode '%03o' "$((8#$reference_mode & 0777 & ~current_umask))"
    chmod "$target_mode" -- "$temp_file"
  else
    current_umask=$(umask)
    printf -v target_mode '%03o' "$((0666 & ~current_umask))"
    chmod "$target_mode" -- "$temp_file"
  fi

  mv -fT -- "$temp_file" "$target_file"
}

run_concat_stage() {
  log_msg "Fuehre Concat der OBS-Segmente aus..."

  local raw_files=()
  local tmp_merged

  if [ ! -d "$VIDEO_DIR" ]; then
    log_msg "Fehler: Eingabeverzeichnis fehlt ($VIDEO_DIR)."
    exit 1
  fi

  while IFS= read -r -d '' file; do
    raw_files+=("$file")
  done < <(find "$VIDEO_DIR" -maxdepth 1 -type f -name "*$DATE*.mkv" -print0 | sort -z)

  if [ "${#raw_files[@]}" -eq 0 ]; then
    log_msg "Keine Dateien fuer $DATE gefunden."
    exit 1
  fi

  validate_output_target "$MERGED_FILE"
  rm -f "$FILE_LIST_MKV"
  tmp_merged=$(mktemp --tmpdir="$OUTPUT_DIR" ".merged_${DATE}.XXXXXX.mkv")
  prepare_temp_output "$tmp_merged"

  if [ "${#raw_files[@]}" -eq 1 ]; then
    cp "${raw_files[0]}" "$tmp_merged"
    publish_temp_file "$tmp_merged" "$MERGED_FILE" "${raw_files[0]}"
    log_msg "Nur ein Segment gefunden; merged-Datei per Copy erstellt: $MERGED_FILE"
    return
  fi

  : >"$FILE_LIST_MKV"
  chmod u+rw -- "$FILE_LIST_MKV"
  for file in "${raw_files[@]}"; do
    printf "file '%s'\n" "$(escape_for_concat_list "$file")" >>"$FILE_LIST_MKV"
  done

  if [ ! -s "$FILE_LIST_MKV" ]; then
    log_msg "Fehler: Dateiliste $FILE_LIST_MKV ist leer."
    exit 1
  fi

  "$FFMPEG" "${ffmpeg_common_args[@]}" "${thread_option[@]}" \
    -f concat -safe 0 -i "$FILE_LIST_MKV" \
    -map 0 -c copy "$tmp_merged"

  publish_temp_file "$tmp_merged" "$MERGED_FILE"
  log_msg "Merged-Datei erstellt: $MERGED_FILE"
}

run_audio_stage() {
  if [ ! -f "$MERGED_FILE" ]; then
    log_msg "Fehler: merged-Datei fehlt ($MERGED_FILE)."
    exit 1
  fi

  validate_output_target "$PROCESSED_AUDIO"

  local audio_stream_count
  audio_stream_count=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$MERGED_FILE" | wc -l)

  log_msg "Gefundene Audio-Streams in merged-Datei: $audio_stream_count"
  if [ "$audio_stream_count" -ne 3 ]; then
    log_msg "Fehler: Erwartet sind exakt 3 Audio-Streams (discord, foundry, stimme)."
    ffprobe -v error -select_streams a \
      -show_entries stream=index,codec_name,channels \
      -of csv=p=0 "$MERGED_FILE" || true
    exit 1
  fi

  local filter_file
  local filter_complex
  filter_file="$SCRIPT_DIR/filters/${AUDIO_MIX_PROFILE}.fffilter"
  filter_complex=$(<"$filter_file")

  local tmp_audio
  tmp_audio=$(mktemp --tmpdir="$OUTPUT_DIR" "processed_audio_${DATE}.XXXXXX.m4a")
  prepare_temp_output "$tmp_audio"

  log_msg "Verarbeite Audio von: $MERGED_FILE"
  log_msg "Audio-Mix-Profil: $AUDIO_MIX_PROFILE"
  # Open the MKV independently for every audio track. Some OBS/Matroska files
  # lose secondary streams mid-run when several tracks from one demuxer feed
  # framesync filters such as amix or sidechaincompress.
  "$FFMPEG" "${ffmpeg_common_args[@]}" "${thread_option[@]}" \
    -i "$MERGED_FILE" \
    -i "$MERGED_FILE" \
    -i "$MERGED_FILE" \
    -filter_complex "$filter_complex" \
    -map "[final_audio]" \
    -f mp4 -c:a aac -b:a 256k -ar 48000 "$tmp_audio"

  publish_temp_file "$tmp_audio" "$PROCESSED_AUDIO"
  log_msg "Fertiges bearbeitetes Audio: $PROCESSED_AUDIO"
}

run_video_stage() {
  local tmp_output
  local source_width
  local source_height
  local source_frame_rate
  local gop_size
  local output_codec
  local output_profile
  local output_pixel_format
  local output_width
  local output_height
  local output_frame_rate
  local output_b_frames
  local output_field_order
  local output_color_range
  local output_color_space
  local output_color_transfer
  local output_color_primaries
  local output_audio_count

  if [ ! -f "$MERGED_FILE" ]; then
    log_msg "Fehler: merged-Datei fehlt ($MERGED_FILE)."
    exit 1
  fi

  if [ ! -f "$PROCESSED_AUDIO" ]; then
    log_msg "Fehler: Audiodatei $PROCESSED_AUDIO fehlt."
    exit 1
  fi

  validate_output_target "$OUTPUT_FILE"

  source_width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$MERGED_FILE")
  source_height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$MERGED_FILE")
  source_frame_rate=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$MERGED_FILE")

  if [[ ! "$source_width" =~ ^[0-9]+$ ]] || [ "$source_width" -lt 1 ] ||
    [[ ! "$source_height" =~ ^[0-9]+$ ]] || [ "$source_height" -lt 1 ]; then
    log_msg "Fehler: Videogroesse konnte nicht aus $MERGED_FILE gelesen werden."
    exit 1
  fi

  if ! gop_size=$(awk -v rate="$source_frame_rate" 'BEGIN {
    part_count = split(rate, parts, "/")
    if (part_count != 2 || parts[1] <= 0 || parts[2] <= 0) {
      exit 1
    }
    gop = int((parts[1] / parts[2] / 2) + 0.5)
    if (gop < 1) {
      gop = 1
    }
    print gop
  }'); then
    log_msg "Fehler: Bildrate konnte nicht aus $MERGED_FILE gelesen werden ($source_frame_rate)."
    exit 1
  fi

  log_msg "Erzeuge finale MP4 per CPU/libx264 (preset=$VIDEO_X264_PRESET, crf=$VIDEO_X264_CRF, GOP=$gop_size)..."
  tmp_output=$(mktemp --tmpdir="$OUTPUT_DIR" ".final_${DATE}.XXXXXX.mp4")
  prepare_temp_output "$tmp_output"
  "$FFMPEG" "${ffmpeg_common_args[@]}" -stats_period 30 \
    -i "$MERGED_FILE" -i "$PROCESSED_AUDIO" \
    -map 0:v:0 -map 1:a:0 \
    -c:v libx264 -preset "$VIDEO_X264_PRESET" -crf "$VIDEO_X264_CRF" \
    -profile:v high -pix_fmt yuv420p -coder cabac \
    -g "$gop_size" -keyint_min 1 -bf 2 \
    -x264-params open-gop=0:colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited \
    -r "$source_frame_rate" -fps_mode cfr \
    -color_range tv -colorspace bt709 -color_trc bt709 -color_primaries bt709 \
    "${thread_option[@]}" \
    -c:a copy -movflags +faststart \
    -progress >(format_ffmpeg_progress >&3) \
    "$tmp_output"

  output_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$tmp_output")
  output_profile=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile -of csv=p=0 "$tmp_output")
  output_pixel_format=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$tmp_output")
  output_width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$tmp_output")
  output_height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$tmp_output")
  output_frame_rate=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$tmp_output")
  output_b_frames=$(ffprobe -v error -select_streams v:0 -show_entries stream=has_b_frames -of csv=p=0 "$tmp_output")
  output_field_order=$(ffprobe -v error -select_streams v:0 -show_entries stream=field_order -of csv=p=0 "$tmp_output")
  output_color_range=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_range -of csv=p=0 "$tmp_output")
  output_color_space=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_space -of csv=p=0 "$tmp_output")
  output_color_transfer=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of csv=p=0 "$tmp_output")
  output_color_primaries=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of csv=p=0 "$tmp_output")
  output_audio_count=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$tmp_output" | awk 'END { print NR }')

  if [ "$output_codec" != "h264" ] ||
    [ "$output_profile" != "High" ] ||
    [ "$output_pixel_format" != "yuv420p" ] ||
    [ "$output_width" != "$source_width" ] ||
    [ "$output_height" != "$source_height" ] ||
    [ "$output_frame_rate" != "$source_frame_rate" ] ||
    [ "$output_b_frames" != "2" ] ||
    [ "$output_field_order" != "progressive" ] ||
    [ "$output_color_range" != "tv" ] ||
    [ "$output_color_space" != "bt709" ] ||
    [ "$output_color_transfer" != "bt709" ] ||
    [ "$output_color_primaries" != "bt709" ] ||
    [[ ! "$output_audio_count" =~ ^[0-9]+$ ]] ||
    [ "$output_audio_count" -ne 1 ]; then
    log_msg "Fehler: CPU-x264-Ausgabe hat unerwartete Stream-Eigenschaften: codec=$output_codec, profile=$output_profile, pix_fmt=$output_pixel_format, size=${output_width}x${output_height}, fps=$output_frame_rate, b_frames=$output_b_frames, field_order=$output_field_order, colors=${output_color_range}/${output_color_space}/${output_color_transfer}/${output_color_primaries}, audio_streams=$output_audio_count."
    return 1
  fi

  publish_temp_file "$tmp_output" "$OUTPUT_FILE"
  log_msg "Fertige Videodatei erstellt: $OUTPUT_FILE"
}

run_upload_stage() {
  local upload_status

  if [ ! -f "$OUTPUT_FILE" ]; then
    log_msg "Fehler: Finale Datei fehlt ($OUTPUT_FILE)."
    exit 1
  fi

  local title
  title="DSA5 mit Marth $FORMATTED_DATE"

  local upload_extra_args=()
  if [ -n "${YOUTUBE_UPLOAD_EXTRA_ARGS-}" ]; then
    while IFS= read -r arg; do
      [ -n "$arg" ] || continue
      upload_extra_args+=("$arg")
    done <<<"$YOUTUBE_UPLOAD_EXTRA_ARGS"
  fi

  local upload_optional_args=()
  if [ -n "$YOUTUBE_UPLOAD_TAGS" ]; then
    upload_optional_args+=(--tags "$YOUTUBE_UPLOAD_TAGS")
  fi
  if [ -n "$YOUTUBE_UPLOAD_PLAYLIST_ID" ]; then
    upload_optional_args+=(--playlist-id "$YOUTUBE_UPLOAD_PLAYLIST_ID")
  fi
  if [ -n "$YOUTUBE_UPLOAD_PLAYLIST_POSITION" ]; then
    upload_optional_args+=(--playlist-position "$YOUTUBE_UPLOAD_PLAYLIST_POSITION")
  fi

  log_msg "Lade Video zu YouTube hoch (Privacy: $YOUTUBE_UPLOAD_PRIVACY)..."
  if YT_UPLOAD_PROGRESS_FD=3 "$YOUTUBE_UPLOAD_BIN" \
    --privacy="$YOUTUBE_UPLOAD_PRIVACY" \
    --title="$title" \
    --description="$YOUTUBE_UPLOAD_DESCRIPTION" \
    "${upload_optional_args[@]}" \
    "${upload_extra_args[@]}" \
    "$OUTPUT_FILE"; then
    :
  else
    upload_status=$?
    if [ "$upload_status" -eq "$YOUTUBE_UPLOAD_PLAYLIST_PARTIAL_STATUS" ]; then
      log_msg "Video wurde hochgeladen, aber die Playlist-Zuordnung ist fehlgeschlagen."
      exit "$YOUTUBE_UPLOAD_PLAYLIST_PARTIAL_STATUS"
    fi
    return "$upload_status"
  fi

  log_msg "YouTube-Upload abgeschlossen."
}

if { $run_concat || $run_audio || $run_video; }; then
  require_cmd "$FFMPEG"
fi
if $run_audio || $run_video; then
  require_cmd ffprobe
fi
if $run_video && ! "$FFMPEG" -hide_banner -h encoder=libx264 >/dev/null 2>&1; then
  log_msg "Fehler: FFmpeg stellt den Encoder libx264 nicht bereit."
  exit 1
fi
if $run_upload; then
  require_cmd "$YOUTUBE_UPLOAD_BIN"
fi
if [ "$NOTIFY" = true ]; then
  require_cmd notify-send
fi
if [ "$SHUTDOWN" = true ]; then
  require_cmd systemctl
  require_cmd flock
  lock_shutdown_control
  write_shutdown_control_file "$SHUTDOWN_CONTROL_FILE" "$$" enabled
  SHUTDOWN_CONTROL_OWNED=true
  unlock_shutdown_control
  log_msg "Shutdown nach Abschluss aktiviert. Laufzeitsteuerung: ./process_videos.sh -S disable|enable|status $DATE"
fi

if $run_concat; then
  if ! $explicit_concat; then
    log_msg "Merged-Datei fehlt ($MERGED_FILE). Starte Concat automatisch."
  fi
  run_concat_stage
else
  log_msg "Concat wurde uebersprungen (Stage 'concat' nicht ausgewaehlt)."
fi

if $run_audio; then
  if ! $explicit_audio; then
    log_msg "Audiodatei fehlt ($PROCESSED_AUDIO). Starte Audio-Schritt automatisch."
  fi
  run_audio_stage
else
  log_msg "Audio-Verarbeitung wurde uebersprungen (Stage 'audio' nicht ausgewaehlt)."
fi

if $run_video; then
  if ! $explicit_video; then
    log_msg "Finale Datei fehlt ($OUTPUT_FILE). Starte Video-Schritt automatisch."
  fi
  run_video_stage
else
  log_msg "Video-Verarbeitung wurde uebersprungen (Stage 'video' nicht ausgewaehlt)."
fi

if $run_upload; then
  run_upload_stage
else
  log_msg "Upload wurde uebersprungen (Stage 'upload' nicht ausgewaehlt)."
fi

if $run_clean; then
  log_msg "Bereinige Dateien..."
  rm -f "$PROCESSED_AUDIO"
  rm -f "$MERGED_FILE"
  rm -f "$FILE_LIST_MKV"
  rm -f "$OUTPUT_DIR/filelist_mkv.txt"
  rm -f "$OUTPUT_DIR/"*"$DATE"*"_piece.mp4"
  rm -f "$OUTPUT_DIR/"*"$DATE"*"_processed_audio.m4a"
  rm -f "$OUTPUT_DIR/filelist.txt"
  log_msg "Bereinigung abgeschlossen; finale Datei und Logs bleiben erhalten."
fi

cleanup_temp_files

if [ "$SHUTDOWN" = true ]; then
  if lock_shutdown_control; then
    if read_shutdown_control_file "$SHUTDOWN_CONTROL_FILE" && [ "$SHUTDOWN_CONTROL_PID" = "$$" ]; then
      if [ "$SHUTDOWN_CONTROL_STATE" = "enabled" ]; then
        rm -f -- "$SHUTDOWN_CONTROL_FILE"
        SHUTDOWN_CONTROL_OWNED=false
        log_msg "Prozess abgeschlossen, fahre System herunter..."
        systemctl --check-inhibitors=yes poweroff
      else
        log_msg "Shutdown wurde waehrend des Laufs deaktiviert; der Computer bleibt eingeschaltet."
      fi
    else
      log_msg "Warnung: Shutdown-Steuerung fehlt oder ist ungueltig; der Computer bleibt sicherheitshalber eingeschaltet."
    fi

    rm -f -- "$SHUTDOWN_CONTROL_FILE"
    SHUTDOWN_CONTROL_OWNED=false
    unlock_shutdown_control
  else
    log_msg "Warnung: Shutdown-Steuerung konnte nicht gesperrt werden; der Computer bleibt sicherheitshalber eingeschaltet."
  fi
elif [ "$NOTIFY" = true ]; then
  notify-send "Verarbeitung abgeschlossen" "Die Schritte ($STAGES) fuer $DATE sind abgeschlossen."
else
  log_msg "Verarbeitung abgeschlossen ohne Benachrichtigung/Shutdown."
fi

log_msg "Skript beendet."
