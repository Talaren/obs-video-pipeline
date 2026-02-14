#!/usr/bin/env bash
set -euo pipefail

# Standardparameter
CLEANUP=true
NOTIFY=false
SHUTDOWN=false
STAGES=""          # Wenn leer, werden standardmäßig alle Schritte ausgeführt.
# Audio-Profil: "podcast-soft" (Default) oder "podcast-strong"
AUDIO_PROFILE="podcast-soft"
# Optional: Anzahl der Threads pro ffmpeg-Prozess (falls nicht gesetzt, wird ffmpeg's Standard genutzt)
FFMPEG_THREADS=""

# Zentrale Logging-Funktion
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Cleanup-Funktion bei Fehlern/Signalen
cleanup() {
    if [ -n "${TMP_AUDIO:-}" ] && [ -f "$TMP_AUDIO" ]; then
        rm -f "$TMP_AUDIO"
    fi
    log_msg "Skript unerwartet beendet. Führe ggf. Aufräumarbeiten durch..."
}
trap cleanup ERR SIGINT SIGTERM

# Optionen auswerten (getopts: c, n, s, e, T, a, h)
while getopts ":cnhse:T:a:h" opt; do
  case $opt in
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
    a)
      AUDIO_PROFILE="$OPTARG"
      ;;
    h)
      echo "Verwendung: $0 [Optionen] DATUM"
      echo "Optionen:"
      echo "  -c             Kein Aufräumen am Ende (Standard: Aufräumen aktiv)"
      echo "  -n             Benachrichtigung am Ende anzeigen"
      echo "  -s             Statt Benachrichtigung am Ende Shutdown ausführen (setzt NOTIFY=false)"
      echo "  -e STAGES      Auszuführende Schritte, kommagetrennt: concat,audio,video,clean"
      echo "                 (Ist -e nicht angegeben, werden standardmäßig alle Schritte ausgeführt.)"
      echo "  -T THREADS     Anzahl Threads pro ffmpeg-Prozess (z. B. 5 oder 6); wenn gesetzt, wird -threads in ffmpeg-Aufrufen verwendet."
      echo "  -a PROFILE     Audio-Profil: podcast-soft (Default) oder podcast-strong"
      echo "  -h             Hilfe"
      exit 0
      ;;
    \?)
      echo "Ungültige Option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG erfordert ein Argument." >&2
      exit 1
      ;;
  esac
done

shift $((OPTIND -1))

if [ $# -lt 1 ]; then
    echo "Bitte gib ein Datum im Format YYYY-MM-DD an."
    exit 1
fi

DATE="$1"

VIDEO_DIR="$HOME/Videos/OBS"
OUTPUT_DIR="$HOME/Videos/OBS/final"
FFMPEG="ffmpeg"  # Verwende den System-ffmpeg

mkdir -p "$OUTPUT_DIR"

LOG_FILE="$OUTPUT_DIR/full_pipeline_${DATE}_$(date +"%Y%m%d_%H%M%S").log"
exec > >(tee -i "$LOG_FILE") 2>&1

log_msg "Starte Prozess für Datum: $DATE"

# Standardmäßig werden alle Schritte ausgeführt, falls STAGES nicht gesetzt ist.
if [ -z "$STAGES" ]; then
  STAGES="concat,audio,video,clean"
fi

# Initialisiere alle Schritt-Flags (Standardmäßig false)
run_concat=false
run_audio=false
run_video=false
run_clean=false

IFS=',' read -ra steps <<< "$STAGES"
for s in "${steps[@]}"; do
  case "$s" in
    concat)  run_concat=true ;;
    audio)   run_audio=true ;;
    video)   run_video=true ;;
    clean)   run_clean=true ;;
    *)
      log_msg "Unbekannter Schritt: $s"
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

MERGED_FILE="$OUTPUT_DIR/merged_${DATE}.mkv"
PROCESSED_AUDIO="$OUTPUT_DIR/processed_audio_${DATE}.m4a"
FILE_LIST_MKV="$OUTPUT_DIR/filelist_mkv.txt"
FORMATTED_DATE=$(date -d "$DATE" +"%d.%m.%Y")
OUTPUT_FILE="$OUTPUT_DIR/DSA5 mit Marth ${FORMATTED_DATE} final.mp4"
TMP_AUDIO=""

run_concat_stage() {
  log_msg "Führe Concat der OBS-Segmente aus..."

  local raw_files=()
  while IFS= read -r -d '' file; do
    raw_files+=("$file")
  done < <(find "$VIDEO_DIR" -type f -name "*$DATE*.mkv" -print0 | sort -z)

  if [ ${#raw_files[@]} -eq 0 ]; then
    log_msg "Keine Dateien für $DATE gefunden."
    exit 1
  fi

  rm -f "$FILE_LIST_MKV"

  if [ ${#raw_files[@]} -eq 1 ]; then
    cp -f "${raw_files[0]}" "$MERGED_FILE"
    log_msg "Nur ein Segment gefunden; merged-Datei per Copy erstellt: $MERGED_FILE"
    return
  fi

  printf "file '%s'\n" "${raw_files[@]}" > "$FILE_LIST_MKV"

  if [ ! -s "$FILE_LIST_MKV" ]; then
    log_msg "Fehler: Datei Liste $FILE_LIST_MKV ist leer."
    exit 1
  fi

  $FFMPEG -y -loglevel error -hide_banner -nostats "${thread_option[@]}" \
    -f concat -safe 0 -i "$FILE_LIST_MKV" \
    -c copy "$MERGED_FILE"

  log_msg "Merged-Datei erstellt: $MERGED_FILE"
}

run_audio_stage() {
  if [ ! -f "$MERGED_FILE" ]; then
    log_msg "Fehler: merged-Datei fehlt ($MERGED_FILE). Bitte zuerst den Concat-Schritt ausführen."
    exit 1
  fi

  local audio_stream_count
  audio_stream_count=$(
    ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$MERGED_FILE" | wc -l
  )

  if [ "$audio_stream_count" -lt 1 ]; then
    log_msg "Fehler: Keine Audio-Streams in $MERGED_FILE gefunden."
    exit 1
  fi

  log_msg "Gefundene Audio-Streams in merged-Datei: $audio_stream_count"

  # Audio-Filter-Chain je nach Profil aufbauen
  local filter_complex
  if [ "$audio_stream_count" -ge 3 ]; then
    case "${AUDIO_PROFILE,,}" in
      podcast-soft|soft)
        filter_complex=$(cat <<'EOT'
[0:a:0]
highpass=f=100:poles=2,
afftdn=nr=12,
anequalizer=params='c0 f=200 w=120 g=-2|c1 f=200 w=120 g=-2|c0 f=3000 w=800 g=2|c1 f=3000 w=800 g=2|c0 f=6000 w=1200 g=-1|c1 f=6000 w=1200 g=-1',
acompressor=threshold=0.1:ratio=2:attack=5:release=100:makeup=1,
deesser,
alimiter=limit=0.95
[louddiscord];

[0:a:2]
agate=threshold=0.004:range=0.063:ratio=6:attack=10:release=100:makeup=1,
highpass=f=100:poles=2,
afftdn=nr=12,
anequalizer=params='c0 f=200 w=100 g=-2|c1 f=200 w=100 g=-2|c0 f=3000 w=800 g=3|c1 f=3000 w=800 g=3',
acompressor=threshold=0.178:ratio=3:attack=10:release=50:makeup=1,
deesser,
alimiter=limit=0.95
[loudvoice];

[louddiscord][loudvoice]
amix=inputs=2:dropout_transition=3,volume=-2dB
[combined_voices];

[0:a:1]
highpass=f=50:poles=2,
loudnorm=I=-23:LRA=7:TP=-2,
volume=-20dB
[foundry_norm];

[combined_voices]
asplit=2[combined_voices_1][combined_voices_2];

[foundry_norm][combined_voices_1]
sidechaincompress=threshold=0.015:ratio=6:attack=5
[foundry_ducked];

[combined_voices_2][foundry_ducked]
amix=inputs=2:dropout_transition=3,volume=-2dB
[pre_final];

[pre_final]
loudnorm=I=-16:LRA=5:TP=-2
[final_audio]
EOT
)
      ;;
      podcast-strong|strong)
        filter_complex=$(cat <<'EOT'
[0:a:0]
highpass=f=120:poles=2,
afftdn=nr=18,
anequalizer=params='c0 f=180 w=140 g=-3|c1 f=180 w=140 g=-3|c0 f=3200 w=900 g=2.5|c1 f=3200 w=900 g=2.5|c0 f=6500 w=1300 g=-1.5|c1 f=6500 w=1300 g=-1.5',
acompressor=threshold=0.08:ratio=3:attack=4:release=120:makeup=2,
deesser,
alimiter=limit=0.95
[louddiscord];

[0:a:2]
agate=threshold=0.006:range=0.05:ratio=8:attack=8:release=120:makeup=2,
highpass=f=120:poles=2,
afftdn=nr=18,
anequalizer=params='c0 f=180 w=120 g=-3|c1 f=180 w=120 g=-3|c0 f=3200 w=900 g=3.5|c1 f=3200 w=900 g=3.5',
acompressor=threshold=0.15:ratio=4:attack=8:release=60:makeup=2,
deesser,
alimiter=limit=0.95
[loudvoice];

[louddiscord][loudvoice]
amix=inputs=2:dropout_transition=3,volume=-1.5dB
[combined_voices];

[0:a:1]
highpass=f=60:poles=2,
loudnorm=I=-24:LRA=7:TP=-2,
volume=-22dB
[foundry_norm];

[combined_voices]
asplit=2[combined_voices_1][combined_voices_2];

[foundry_norm][combined_voices_1]
sidechaincompress=threshold=0.012:ratio=8:attack=4
[foundry_ducked];

[combined_voices_2][foundry_ducked]
amix=inputs=2:dropout_transition=3,volume=-2dB
[pre_final];

[pre_final]
loudnorm=I=-16:LRA=6:TP=-2
[final_audio]
EOT
)
      ;;
      *)
        log_msg "Unbekanntes Audio-Profil: $AUDIO_PROFILE (erlaubt: podcast-soft, podcast-strong)"
        exit 1
      ;;
    esac
  elif [ "$audio_stream_count" -eq 2 ]; then
    case "${AUDIO_PROFILE,,}" in
      podcast-soft|soft)
        filter_complex=$(cat <<'EOT'
[0:a:0]
highpass=f=100:poles=2,
afftdn=nr=12,
anequalizer=params='c0 f=200 w=120 g=-2|c1 f=200 w=120 g=-2|c0 f=3000 w=800 g=2|c1 f=3000 w=800 g=2|c0 f=6000 w=1200 g=-1|c1 f=6000 w=1200 g=-1',
acompressor=threshold=0.1:ratio=2:attack=5:release=100:makeup=1,
deesser,
alimiter=limit=0.95
[a0];

[0:a:1]
highpass=f=100:poles=2,
afftdn=nr=12,
acompressor=threshold=0.15:ratio=3:attack=8:release=80:makeup=1,
deesser,
alimiter=limit=0.95
[a1];

[a0][a1]
amix=inputs=2:dropout_transition=3,volume=-2dB,
loudnorm=I=-16:LRA=5:TP=-2
[final_audio]
EOT
)
      ;;
      podcast-strong|strong)
        filter_complex=$(cat <<'EOT'
[0:a:0]
highpass=f=120:poles=2,
afftdn=nr=18,
anequalizer=params='c0 f=180 w=140 g=-3|c1 f=180 w=140 g=-3|c0 f=3200 w=900 g=2.5|c1 f=3200 w=900 g=2.5|c0 f=6500 w=1300 g=-1.5|c1 f=6500 w=1300 g=-1.5',
acompressor=threshold=0.08:ratio=3:attack=4:release=120:makeup=2,
deesser,
alimiter=limit=0.95
[a0];

[0:a:1]
highpass=f=120:poles=2,
afftdn=nr=18,
acompressor=threshold=0.12:ratio=4:attack=6:release=90:makeup=2,
deesser,
alimiter=limit=0.95
[a1];

[a0][a1]
amix=inputs=2:dropout_transition=3,volume=-1.5dB,
loudnorm=I=-16:LRA=6:TP=-2
[final_audio]
EOT
)
      ;;
      *)
        log_msg "Unbekanntes Audio-Profil: $AUDIO_PROFILE (erlaubt: podcast-soft, podcast-strong)"
        exit 1
      ;;
    esac
  else
    case "${AUDIO_PROFILE,,}" in
      podcast-soft|soft)
        filter_complex=$(cat <<'EOT'
[0:a:0]
highpass=f=100:poles=2,
afftdn=nr=12,
anequalizer=params='c0 f=200 w=120 g=-2|c1 f=200 w=120 g=-2|c0 f=3000 w=800 g=2|c1 f=3000 w=800 g=2|c0 f=6000 w=1200 g=-1|c1 f=6000 w=1200 g=-1',
acompressor=threshold=0.1:ratio=2:attack=5:release=100:makeup=1,
deesser,
alimiter=limit=0.95,
loudnorm=I=-16:LRA=5:TP=-2
[final_audio]
EOT
)
      ;;
      podcast-strong|strong)
        filter_complex=$(cat <<'EOT'
[0:a:0]
highpass=f=120:poles=2,
afftdn=nr=18,
anequalizer=params='c0 f=180 w=140 g=-3|c1 f=180 w=140 g=-3|c0 f=3200 w=900 g=2.5|c1 f=3200 w=900 g=2.5|c0 f=6500 w=1300 g=-1.5|c1 f=6500 w=1300 g=-1.5',
acompressor=threshold=0.08:ratio=3:attack=4:release=120:makeup=2,
deesser,
alimiter=limit=0.95,
loudnorm=I=-16:LRA=6:TP=-2
[final_audio]
EOT
)
      ;;
      *)
        log_msg "Unbekanntes Audio-Profil: $AUDIO_PROFILE (erlaubt: podcast-soft, podcast-strong)"
        exit 1
      ;;
    esac
  fi

  local tmp_audio
  tmp_audio=$(mktemp --tmpdir="$OUTPUT_DIR" "processed_audio_${DATE}.XXXXXX.m4a")
  TMP_AUDIO="$tmp_audio"

  log_msg "Verarbeite Audio von: $MERGED_FILE"
  log_msg "Audio-Profil: $AUDIO_PROFILE"
  $FFMPEG -y -loglevel error -hide_banner -nostats "${thread_option[@]}" \
    -i "$MERGED_FILE" \
    -filter_complex "$filter_complex" \
    -map "[final_audio]" -f mp4 -c:a aac -b:a 256k "$tmp_audio"

  mv "$tmp_audio" "$PROCESSED_AUDIO"
  TMP_AUDIO=""
  log_msg "Fertiges bearbeitetes Audio: $PROCESSED_AUDIO"
}

run_video_stage() {
  if [ ! -f "$MERGED_FILE" ]; then
    log_msg "Fehler: merged-Datei fehlt ($MERGED_FILE). Bitte zuerst den Concat-Schritt ausführen."
    exit 1
  fi

  if [ ! -f "$PROCESSED_AUDIO" ]; then
    log_msg "Fehler: Audiodatei $PROCESSED_AUDIO existiert nicht. Bitte zuerst den Audio-Schritt ausführen."
    exit 1
  fi

  log_msg "Erzeuge finale MP4 per Remux (Video copy + neues Audio)..."
  $FFMPEG -y -loglevel error -hide_banner -nostats "${thread_option[@]}" \
    -i "$MERGED_FILE" -i "$PROCESSED_AUDIO" \
    -map 0:v:0 -map 1:a:0 \
    -c:v copy -c:a copy -movflags +faststart \
    "$OUTPUT_FILE"

  log_msg "Fertige Videodatei erstellt: $OUTPUT_FILE"
}

if $run_concat; then
  run_concat_stage
else
  log_msg "Concat wurde übersprungen (Stage 'concat' nicht ausgewählt)."
fi

if { $run_audio || $run_video; } && [ ! -f "$MERGED_FILE" ]; then
  log_msg "Merged-Datei fehlt ($MERGED_FILE). Starte Concat automatisch, da Stage 'audio' oder 'video' gewählt wurde."
  run_concat_stage
fi

if $run_audio; then
  run_audio_stage
else
  log_msg "Audio Verarbeitung wurde übersprungen (Stage 'audio' nicht ausgewählt)."
fi

if $run_video; then
  run_video_stage
else
  log_msg "Video Verarbeitung wurde übersprungen (Stage 'video' nicht ausgewählt)."
fi

# Clean-Schritt: Nur ausführen, wenn run_clean aktiviert ist.
if $run_clean; then
    log_msg "Bereinige Dateien..."
    rm -f "$PROCESSED_AUDIO"
    rm -f "$MERGED_FILE"
    rm -f "$FILE_LIST_MKV"
    rm -f "$OUTPUT_DIR/"*"$DATE"*"_piece.mp4"
    rm -f "$OUTPUT_DIR/"*"$DATE"*"_processed_audio.m4a"
    rm -f "$OUTPUT_DIR/filelist.txt"
    log_msg "Bereinigung abgeschlossen, nur finale Datei übrig."
fi

if [ -n "$TMP_AUDIO" ] && [ -f "$TMP_AUDIO" ]; then
    rm -f "$TMP_AUDIO"
fi

if [ "$SHUTDOWN" = true ]; then
    log_msg "Prozess abgeschlossen, fahre System herunter..."
    systemctl poweroff
elif [ "$NOTIFY" = true ]; then
    notify-send "Verarbeitung abgeschlossen" "Die Schritte ($STAGES) für $DATE sind abgeschlossen."
else
    log_msg "Verarbeitung abgeschlossen ohne Benachrichtigung/Shutdown."
fi

log_msg "Skript beendet."
