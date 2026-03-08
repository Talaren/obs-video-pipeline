#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CLEANUP=true
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

TMP_AUDIO=""

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
  if [ -n "${TMP_AUDIO:-}" ] && [ -f "$TMP_AUDIO" ]; then
    rm -f "$TMP_AUDIO"
  fi
  log_msg "Skript unerwartet beendet. Fuhre ggf. Aufraumarbeiten durch..."
}
trap cleanup ERR SIGINT SIGTERM

show_help() {
  cat <<'EOF'
Verwendung: ./process_videos.sh [Optionen] DATUM

Optionen:
  -c             Kein Aufraumen am Ende (Standard: Aufraumen aktiv)
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
  Fur den ersten Upload werden OAuth Client-Secrets benotigt.
  Zusatzparameter via YOUTUBE_UPLOAD_EXTRA_ARGS (newline-separiert), z. B.:
  $'--client-secrets\n~/.config/yt-upload/client_secrets.json\n--token-file\n~/.config/yt-upload/token.json'
  Komfort-Variablen:
  YOUTUBE_UPLOAD_TAGS="dsa5,pen-and-paper"
  YOUTUBE_UPLOAD_PLAYLIST_ID="PLxxxx..."
  YOUTUBE_UPLOAD_PLAYLIST_POSITION="0"
EOF
}

while getopts ":cnhse:T:m:h" opt; do
  case "$opt" in
    c)
      CLEANUP=false
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
      echo "Ungultige Option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG erfordert ein Argument." >&2
      exit 1
      ;;
  esac
done

shift $((OPTIND - 1))

if [ $# -lt 1 ]; then
  echo "Bitte gib ein Datum im Format YYYY-MM-DD an." >&2
  show_help >&2
  exit 1
fi

DATE="$1"
if ! FORMATTED_DATE=$(date -d "$DATE" +"%d.%m.%Y" 2>/dev/null); then
  echo "Ungultiges Datum: $DATE (erwartet: YYYY-MM-DD)" >&2
  exit 1
fi

VIDEO_DIR="$HOME/Videos/OBS"
OUTPUT_DIR="$HOME/Videos/OBS/final"
mkdir -p "$OUTPUT_DIR"

MERGED_FILE="$OUTPUT_DIR/merged_${DATE}.mkv"
PROCESSED_AUDIO="$OUTPUT_DIR/processed_audio_${DATE}.m4a"
FILE_LIST_MKV="$OUTPUT_DIR/filelist_mkv.txt"
OUTPUT_FILE="$OUTPUT_DIR/DSA5 mit Marth ${FORMATTED_DATE} final.mp4"

LOG_FILE="$OUTPUT_DIR/full_pipeline_${DATE}_$(date +"%Y%m%d_%H%M%S").log"
exec > >(tee -i "$LOG_FILE") 2>&1

log_msg "Starte Prozess fur Datum: $DATE"

if [ -z "$STAGES" ]; then
  STAGES="concat,audio,video,clean"
fi

run_concat=false
run_audio=false
run_video=false
run_upload=false
run_clean=false

IFS=',' read -ra steps <<<"$STAGES"
for step in "${steps[@]}"; do
  normalized_step="${step,,}"
  normalized_step="${normalized_step//[[:space:]]/}"

  case "$normalized_step" in
    concat)
      run_concat=true
      ;;
    audio)
      run_audio=true
      ;;
    video)
      run_video=true
      ;;
    upload)
      run_upload=true
      ;;
    clean)
      run_clean=true
      ;;
    *)
      log_msg "Unbekannter Schritt: $step"
      exit 1
      ;;
  esac
done

if [ "$CLEANUP" = false ]; then
  run_clean=false
fi

thread_option=()
if [ -n "$FFMPEG_THREADS" ]; then
  thread_option=(-threads "$FFMPEG_THREADS")
fi

ffmpeg_common_args=(-y -loglevel error -hide_banner -nostats)

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_msg "Fehler: Benotigtes Kommando '$1' wurde nicht gefunden."
    exit 1
  fi
}

escape_for_concat_list() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

run_concat_stage() {
  log_msg "Fuhre Concat der OBS-Segmente aus..."

  local raw_files=()
  while IFS= read -r -d '' file; do
    raw_files+=("$file")
  done < <(find "$VIDEO_DIR" -type f -name "*$DATE*.mkv" -print0 | sort -z)

  if [ "${#raw_files[@]}" -eq 0 ]; then
    log_msg "Keine Dateien fur $DATE gefunden."
    exit 1
  fi

  rm -f "$FILE_LIST_MKV"

  if [ "${#raw_files[@]}" -eq 1 ]; then
    cp -f "${raw_files[0]}" "$MERGED_FILE"
    log_msg "Nur ein Segment gefunden; merged-Datei per Copy erstellt: $MERGED_FILE"
    return
  fi

  for file in "${raw_files[@]}"; do
    printf "file '%s'\n" "$(escape_for_concat_list "$file")" >>"$FILE_LIST_MKV"
  done

  if [ ! -s "$FILE_LIST_MKV" ]; then
    log_msg "Fehler: Dateiliste $FILE_LIST_MKV ist leer."
    exit 1
  fi

  "$FFMPEG" "${ffmpeg_common_args[@]}" "${thread_option[@]}" \
    -f concat -safe 0 -i "$FILE_LIST_MKV" \
    -c copy "$MERGED_FILE"

  log_msg "Merged-Datei erstellt: $MERGED_FILE"
}

run_audio_stage() {
  if [ ! -f "$MERGED_FILE" ]; then
    log_msg "Fehler: merged-Datei fehlt ($MERGED_FILE)."
    exit 1
  fi

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

  local filter_complex
  local normalized_mix_profile
  normalized_mix_profile="${AUDIO_MIX_PROFILE,,}"
  normalized_mix_profile="${normalized_mix_profile//_/-}"

  case "$normalized_mix_profile" in
    balanced)
      filter_complex=$(
        cat <<'EOT'
[0:a:0]
aformat=sample_fmts=fltp:channel_layouts=stereo,
highpass=f=90,
lowpass=f=13500,
afftdn=nr=12:nf=-45:tn=1,
equalizer=f=180:t=q:w=1.0:g=-3,
equalizer=f=3200:t=q:w=1.0:g=4,
equalizer=f=6500:t=q:w=1.2:g=2,
dynaudnorm=f=180:g=21:m=12:p=0.95,
acompressor=threshold=0.1:ratio=3.2:attack=4:release=140:makeup=2,
alimiter=limit=0.95
[discord];

[0:a:2]
aformat=sample_fmts=fltp:channel_layouts=stereo,
highpass=f=95,
lowpass=f=14000,
afftdn=nr=10:nf=-46:tn=1,
equalizer=f=180:t=q:w=1.0:g=-2.5,
equalizer=f=3000:t=q:w=1.0:g=3.5,
equalizer=f=6000:t=q:w=1.2:g=1.5,
dynaudnorm=f=140:g=17:m=10:p=0.95,
acompressor=threshold=0.09:ratio=3:attack=3:release=120:makeup=1.8,
alimiter=limit=0.95
[voice];

[discord][voice]
amix=inputs=2:dropout_transition=2:normalize=0,
dynaudnorm=f=120:g=11:m=8:p=0.95,
acompressor=threshold=0.09:ratio=2.3:attack=3:release=120:makeup=1.2,
volume=-1dB
[voices];

[voices]
asplit=2[voices_main][voices_side];

[0:a:1]
aformat=sample_fmts=fltp:channel_layouts=stereo,
highpass=f=40,
lowpass=f=12000,
dynaudnorm=f=350:g=7:m=8:p=0.95,
volume=-19dB
[foundry_base];

[foundry_base][voices_side]
sidechaincompress=threshold=0.018:ratio=10:attack=6:release=500:makeup=1
[foundry_ducked];

[voices_main][foundry_ducked]
amix=inputs=2:dropout_transition=2:normalize=0,
loudnorm=I=-17:LRA=7:TP=-2,
alimiter=limit=0.96
[final_audio]
EOT
      )
      ;;
    voice-priority | voice)
      filter_complex=$(
        cat <<'EOT'
[0:a:0]
aformat=sample_fmts=fltp:channel_layouts=stereo,
highpass=f=95,
lowpass=f=13500,
afftdn=nr=13:nf=-45:tn=1,
equalizer=f=200:t=q:w=1.0:g=-3.5,
equalizer=f=3200:t=q:w=1.0:g=4.5,
equalizer=f=6500:t=q:w=1.2:g=2.5,
dynaudnorm=f=160:g=24:m=14:p=0.95,
acompressor=threshold=0.095:ratio=3.5:attack=3:release=130:makeup=2.2,
alimiter=limit=0.95
[discord];

[0:a:2]
aformat=sample_fmts=fltp:channel_layouts=stereo,
highpass=f=100,
lowpass=f=14000,
afftdn=nr=11:nf=-46:tn=1,
equalizer=f=200:t=q:w=1.0:g=-3,
equalizer=f=3000:t=q:w=1.0:g=4,
equalizer=f=6000:t=q:w=1.2:g=2,
dynaudnorm=f=130:g=20:m=12:p=0.95,
acompressor=threshold=0.085:ratio=3.2:attack=2:release=120:makeup=2,
alimiter=limit=0.95
[voice];

[discord][voice]
amix=inputs=2:dropout_transition=2:normalize=0,
dynaudnorm=f=110:g=13:m=9:p=0.95,
acompressor=threshold=0.085:ratio=2.6:attack=2:release=120:makeup=1.4,
volume=-0.3dB
[voices];

[voices]
asplit=2[voices_main][voices_side];

[0:a:1]
aformat=sample_fmts=fltp:channel_layouts=stereo,
highpass=f=40,
lowpass=f=10500,
dynaudnorm=f=400:g=5:m=6:p=0.95,
volume=-23dB
[foundry_base];

[foundry_base][voices_side]
sidechaincompress=threshold=0.012:ratio=12:attack=4:release=650:makeup=1
[foundry_ducked];

[voices_main][foundry_ducked]
amix=inputs=2:dropout_transition=2:normalize=0,
loudnorm=I=-16:LRA=6:TP=-2,
alimiter=limit=0.96
[final_audio]
EOT
      )
      ;;
    *)
      log_msg "Fehler: Unbekanntes Audio-Mix-Profil '$AUDIO_MIX_PROFILE' (erlaubt: balanced, voice-priority)."
      exit 1
      ;;
  esac

  local tmp_audio
  tmp_audio=$(mktemp --tmpdir="$OUTPUT_DIR" "processed_audio_${DATE}.XXXXXX.m4a")
  TMP_AUDIO="$tmp_audio"

  log_msg "Verarbeite Audio von: $MERGED_FILE"
  log_msg "Audio-Mix-Profil: $normalized_mix_profile"
  "$FFMPEG" "${ffmpeg_common_args[@]}" "${thread_option[@]}" \
    -i "$MERGED_FILE" \
    -filter_complex "$filter_complex" \
    -map "[final_audio]" \
    -f mp4 -c:a aac -b:a 256k "$tmp_audio"

  mv "$tmp_audio" "$PROCESSED_AUDIO"
  TMP_AUDIO=""
  log_msg "Fertiges bearbeitetes Audio: $PROCESSED_AUDIO"
}

run_video_stage() {
  if [ ! -f "$MERGED_FILE" ]; then
    log_msg "Fehler: merged-Datei fehlt ($MERGED_FILE)."
    exit 1
  fi

  if [ ! -f "$PROCESSED_AUDIO" ]; then
    log_msg "Fehler: Audiodatei $PROCESSED_AUDIO fehlt."
    exit 1
  fi

  log_msg "Erzeuge finale MP4 per Remux (Video copy + neues Audio)..."
  "$FFMPEG" "${ffmpeg_common_args[@]}" "${thread_option[@]}" \
    -i "$MERGED_FILE" -i "$PROCESSED_AUDIO" \
    -map 0:v:0 -map 1:a:0 \
    -c:v copy -c:a copy -movflags +faststart \
    "$OUTPUT_FILE"

  log_msg "Fertige Videodatei erstellt: $OUTPUT_FILE"
}

run_upload_stage() {
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
  "$YOUTUBE_UPLOAD_BIN" \
    --privacy="$YOUTUBE_UPLOAD_PRIVACY" \
    --title="$title" \
    --description="$YOUTUBE_UPLOAD_DESCRIPTION" \
    "${upload_optional_args[@]}" \
    "${upload_extra_args[@]}" \
    "$OUTPUT_FILE"

  log_msg "YouTube-Upload abgeschlossen."
}

require_cmd "$FFMPEG"
require_cmd ffprobe
if $run_upload; then
  require_cmd "$YOUTUBE_UPLOAD_BIN"
fi

if $run_concat; then
  run_concat_stage
else
  log_msg "Concat wurde ubersprungen (Stage 'concat' nicht ausgewahlt)."
fi

if { $run_audio || $run_video; } && [ ! -f "$MERGED_FILE" ]; then
  log_msg "Merged-Datei fehlt ($MERGED_FILE). Starte Concat automatisch."
  run_concat_stage
fi

if $run_audio; then
  run_audio_stage
else
  log_msg "Audio-Verarbeitung wurde ubersprungen (Stage 'audio' nicht ausgewahlt)."
fi

if $run_video && [ ! -f "$PROCESSED_AUDIO" ]; then
  log_msg "Audiodatei fehlt ($PROCESSED_AUDIO). Starte Audio-Schritt automatisch."
  run_audio_stage
fi

if $run_video; then
  run_video_stage
else
  log_msg "Video-Verarbeitung wurde ubersprungen (Stage 'video' nicht ausgewahlt)."
fi

if $run_upload && [ ! -f "$OUTPUT_FILE" ]; then
  log_msg "Finale Datei fehlt ($OUTPUT_FILE). Erzeuge Video automatisch fur Upload."
  if [ ! -f "$MERGED_FILE" ]; then
    run_concat_stage
  fi
  if [ ! -f "$PROCESSED_AUDIO" ]; then
    run_audio_stage
  fi
  run_video_stage
fi

if $run_upload; then
  run_upload_stage
else
  log_msg "Upload wurde ubersprungen (Stage 'upload' nicht ausgewahlt)."
fi

if $run_clean; then
  log_msg "Bereinige Dateien..."
  rm -f "$PROCESSED_AUDIO"
  rm -f "$MERGED_FILE"
  rm -f "$FILE_LIST_MKV"
  rm -f "$OUTPUT_DIR/"*"$DATE"*"_piece.mp4"
  rm -f "$OUTPUT_DIR/"*"$DATE"*"_processed_audio.m4a"
  rm -f "$OUTPUT_DIR/filelist.txt"
  log_msg "Bereinigung abgeschlossen, nur finale Datei bleibt erhalten."
fi

if [ -n "$TMP_AUDIO" ] && [ -f "$TMP_AUDIO" ]; then
  rm -f "$TMP_AUDIO"
fi

if [ "$SHUTDOWN" = true ]; then
  log_msg "Prozess abgeschlossen, fahre System herunter..."
  systemctl poweroff
elif [ "$NOTIFY" = true ]; then
  notify-send "Verarbeitung abgeschlossen" "Die Schritte ($STAGES) fur $DATE sind abgeschlossen."
else
  log_msg "Verarbeitung abgeschlossen ohne Benachrichtigung/Shutdown."
fi

log_msg "Skript beendet."
