#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CLEANUP=true
DRY_RUN=false
NOTIFY=false
SHUTDOWN=false
STAGES=""
FFMPEG_THREADS=""
FFMPEG="ffmpeg"
AUDIO_MIX_PROFILE="${AUDIO_MIX_PROFILE:-balanced}"
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
  log_msg "Skript unerwartet beendet. Fuehre ggf. Aufraeumarbeiten durch..."
  exit "$exit_status"
}

handle_signal() {
  local signal_name="$1"
  local exit_status="$2"

  trap - ERR INT TERM
  cleanup_temp_files || true
  log_msg "Skript durch $signal_name beendet."
  exit "$exit_status"
}

trap 'handle_error $?' ERR
trap 'handle_signal SIGINT 130' INT
trap 'handle_signal SIGTERM 143' TERM

show_help() {
  cat <<'EOF'
Verwendung: ./process_videos.sh [Optionen] DATUM

Optionen:
  -c             Kein Aufraeumen am Ende (Standard: Aufraeumen aktiv)
  -d             Dry-Run: geplante Schritte anzeigen, nichts ausfuehren
  -n             Benachrichtigung am Ende anzeigen
  -s             Statt Benachrichtigung am Ende Shutdown ausfuhren (setzt NOTIFY=false)
  -e STAGES      Auszufuhrende Schritte, kommagetrennt:
                 concat,audio,video,upload,clean
                 (Wenn -e nicht gesetzt ist: concat,audio,video,clean)
  -T THREADS     Anzahl Threads pro ffmpeg-Prozess (setzt -threads bei ffmpeg-Aufrufen)
  -m PROFILE     Audio-Mix-Profil: balanced (Default) oder voice-priority
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

while getopts ":cdnhe:T:m:s" opt; do
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
    e)
      STAGES="$OPTARG"
      ;;
    T)
      FFMPEG_THREADS="$OPTARG"
      ;;
    m)
      AUDIO_MIX_PROFILE="$OPTARG"
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

if [ "$DRY_RUN" = false ]; then
  mkdir -p "$OUTPUT_DIR"
  LOG_FILE="$OUTPUT_DIR/full_pipeline_${DATE}_$(date +"%Y%m%d_%H%M%S").log"
  exec > >(tee -i "$LOG_FILE") 2>&1

  log_msg "Starte Prozess fuer Datum: $DATE"
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
    chmod --reference="$target_file" -- "$temp_file"
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

  if [ ! -f "$MERGED_FILE" ]; then
    log_msg "Fehler: merged-Datei fehlt ($MERGED_FILE)."
    exit 1
  fi

  if [ ! -f "$PROCESSED_AUDIO" ]; then
    log_msg "Fehler: Audiodatei $PROCESSED_AUDIO fehlt."
    exit 1
  fi

  validate_output_target "$OUTPUT_FILE"

  log_msg "Erzeuge finale MP4 per Remux (Video copy + neues Audio)..."
  tmp_output=$(mktemp --tmpdir="$OUTPUT_DIR" ".final_${DATE}.XXXXXX.mp4")
  prepare_temp_output "$tmp_output"
  "$FFMPEG" "${ffmpeg_common_args[@]}" "${thread_option[@]}" \
    -i "$MERGED_FILE" -i "$PROCESSED_AUDIO" \
    -map 0:v:0 -map 1:a:0 \
    -c:v copy -c:a copy -movflags +faststart \
    "$tmp_output"

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
  if "$YOUTUBE_UPLOAD_BIN" \
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
if $run_audio; then
  require_cmd ffprobe
fi
if $run_upload; then
  require_cmd "$YOUTUBE_UPLOAD_BIN"
fi
if [ "$NOTIFY" = true ]; then
  require_cmd notify-send
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
  log_msg "Prozess abgeschlossen, fahre System herunter..."
  systemctl poweroff
elif [ "$NOTIFY" = true ]; then
  notify-send "Verarbeitung abgeschlossen" "Die Schritte ($STAGES) fuer $DATE sind abgeschlossen."
else
  log_msg "Verarbeitung abgeschlossen ohne Benachrichtigung/Shutdown."
fi

log_msg "Skript beendet."
