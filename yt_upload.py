#!/usr/bin/env python3
"""Upload a video to YouTube using the official Data API v3."""

from __future__ import annotations

import argparse
import http.client
import json
import os
import random
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, List

import httplib2
from google.auth.exceptions import TransportError
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload

UPLOAD_SCOPE = "https://www.googleapis.com/auth/youtube.upload"
PLAYLIST_SCOPE = "https://www.googleapis.com/auth/youtube"
DEFAULT_CLIENT_SECRETS = Path.home() / ".config" / "yt-upload" / "client_secrets.json"
DEFAULT_TOKEN_FILE = Path.home() / ".config" / "yt-upload" / "token.json"
VALID_PRIVACY = {"private", "public", "unlisted"}
MAX_RETRIES = 10
PLAYLIST_PARTIAL_EXIT_STATUS = 3
MAX_PLAYLIST_POSITION = (2**32) - 1
RETRIABLE_STATUS_CODES = {500, 502, 503, 504}
UPLOAD_PROGRESS_FD_ENV = "YT_UPLOAD_PROGRESS_FD"
RETRIABLE_EXCEPTIONS = (
    TransportError,
    httplib2.HttpLib2Error,
    OSError,
    http.client.NotConnected,
    http.client.IncompleteRead,
    http.client.ImproperConnectionState,
    http.client.CannotSendRequest,
    http.client.CannotSendHeader,
    http.client.ResponseNotReady,
    http.client.BadStatusLine,
)


def parse_playlist_position(raw_position: str) -> int:
  try:
    position = int(raw_position)
  except ValueError as exc:
    raise argparse.ArgumentTypeError("muss eine Ganzzahl sein") from exc

  if not 0 <= position <= MAX_PLAYLIST_POSITION:
    raise argparse.ArgumentTypeError(
        f"muss zwischen 0 und {MAX_PLAYLIST_POSITION} liegen"
    )
  return position


def parse_args() -> argparse.Namespace:
  parser = argparse.ArgumentParser(description="Upload a video to YouTube")
  parser.add_argument("video_file", help="Path to video file")
  parser.add_argument("--title", required=True, help="Video title")
  parser.add_argument("--description", default="", help="Video description")
  parser.add_argument("--privacy", default="unlisted", choices=sorted(VALID_PRIVACY))
  parser.add_argument("--category-id", default="22", help="YouTube category ID")
  parser.add_argument(
      "--tags",
      default="",
      help="Comma-separated tags (optional), e.g. dsa5,pen-and-paper",
  )
  parser.add_argument(
      "--client-secrets",
      default=str(DEFAULT_CLIENT_SECRETS),
      help=f"OAuth client secrets JSON (default: {DEFAULT_CLIENT_SECRETS})",
  )
  parser.add_argument(
      "--token-file",
      default=str(DEFAULT_TOKEN_FILE),
      help=f"OAuth token cache path (default: {DEFAULT_TOKEN_FILE})",
  )
  parser.add_argument(
      "--no-browser",
      action="store_true",
      help="Print the OAuth URL without attempting to open a browser",
  )
  parser.add_argument(
      "--made-for-kids",
      action="store_true",
      help="Mark upload as made for kids (default: false)",
  )
  parser.add_argument(
      "--playlist-id",
      default="",
      help="Optional YouTube playlist ID (video will be added after upload)",
  )
  parser.add_argument(
      "--playlist-position",
      type=parse_playlist_position,
      default=None,
      help=(
          "Optional zero-based target position in playlist "
          f"(0-{MAX_PLAYLIST_POSITION}; requires --playlist-id)"
      ),
  )
  return parser.parse_args()


def required_scopes(playlist_id: str) -> List[str]:
  scopes = [UPLOAD_SCOPE]
  if playlist_id.strip():
    scopes.append(PLAYLIST_SCOPE)
  return scopes


def write_token_file(token_path: Path, token_json: str) -> None:
  token_path.parent.mkdir(parents=True, exist_ok=True)

  tmp_fd, tmp_name = tempfile.mkstemp(prefix=f".{token_path.name}.", dir=str(token_path.parent))
  try:
    with os.fdopen(tmp_fd, "w", encoding="utf-8") as tmp_file:
      tmp_file.write(token_json)
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, token_path)
  finally:
    if os.path.exists(tmp_name):
      os.remove(tmp_name)


def load_credentials(
    client_secrets_path: Path,
    token_path: Path,
    scopes: List[str],
    *,
    open_browser: bool,
) -> Credentials:
  creds = None
  if token_path.exists():
    creds = Credentials.from_authorized_user_file(str(token_path), scopes)

  if creds and creds.expired and creds.refresh_token:
    creds.refresh(Request())

  # Force a new OAuth flow when scopes are missing (e.g. playlist support added later).
  if not creds or not creds.valid or not creds.has_scopes(scopes):
    flow = InstalledAppFlow.from_client_secrets_file(str(client_secrets_path), scopes)
    creds = flow.run_local_server(port=0, open_browser=open_browser)

  write_token_file(token_path, creds.to_json())
  return creds


def parse_tags(raw_tags: str) -> List[str]:
  if not raw_tags.strip():
    return []
  return [tag.strip() for tag in raw_tags.split(",") if tag.strip()]


def add_to_playlist(youtube, video_id: str, playlist_id: str, position: int | None) -> str:
  body = {
      "snippet": {
          "playlistId": playlist_id,
          "resourceId": {
              "kind": "youtube#video",
              "videoId": video_id,
          },
      }
  }
  if position is not None:
    body["snippet"]["position"] = position

  response = youtube.playlistItems().insert(part="snippet", body=body).execute()
  return str(response["id"])


def emit_upload_progress(progress: int) -> None:
  message = f"Upload-Fortschritt: {progress}%\n"
  progress_fd_value = os.environ.get(UPLOAD_PROGRESS_FD_ENV)
  if progress_fd_value is None:
    print(message, end="", flush=True)
    return

  try:
    progress_fd = int(progress_fd_value)
    if progress_fd < 0:
      raise ValueError
    os.write(progress_fd, message.encode("utf-8"))
  except (OSError, ValueError) as exc:
    raise RuntimeError(
        f"Ungueltiger Fortschritts-Dateideskriptor in {UPLOAD_PROGRESS_FD_ENV}: "
        f"{progress_fd_value}"
    ) from exc


def resumable_upload(request) -> str:
  response = None
  last_progress = None
  retry = 0

  while response is None:
    retry_error = None
    retry_after = None
    try:
      status, response = request.next_chunk()
      if status is not None:
        progress = int(status.progress() * 100)
        if progress != last_progress:
          emit_upload_progress(progress)
          last_progress = progress
    except HttpError as exc:
      if exc.resp.status not in RETRIABLE_STATUS_CODES:
        raise
      retry_error = f"HTTP {exc.resp.status}: {exc}"
      retry_after = exc.resp.get("retry-after")
    except RETRIABLE_EXCEPTIONS as exc:
      retry_error = str(exc)

    if retry_error is None:
      continue

    retry += 1
    if retry > MAX_RETRIES:
      raise RuntimeError(f"Upload nach {MAX_RETRIES} Wiederholungen abgebrochen: {retry_error}")

    if retry_after is not None:
      try:
        sleep_seconds = max(0.0, float(retry_after))
      except ValueError:
        sleep_seconds = random.random() * (2**retry)
    else:
      sleep_seconds = random.random() * (2**retry)

    print(
        f"Voruebergehender Upload-Fehler ({retry_error}); "
        f"neuer Versuch in {sleep_seconds:.1f} Sekunden.",
        file=sys.stderr,
        flush=True,
    )
    time.sleep(sleep_seconds)

  if "id" not in response:
    raise RuntimeError(f"Unerwartete Upload-Antwort ohne Video-ID: {response}")
  return str(response["id"])


def upload_video(args: argparse.Namespace) -> tuple[Any, str]:
  video_path = Path(args.video_file).expanduser().resolve()
  if not video_path.is_file():
    raise FileNotFoundError(f"Videodatei nicht gefunden: {video_path}")

  client_secrets_path = Path(args.client_secrets).expanduser().resolve()
  if not client_secrets_path.is_file():
    raise FileNotFoundError(
        "OAuth Client-Secrets fehlen: "
        f"{client_secrets_path}\n"
        "Bitte in Google Cloud ein Desktop OAuth Client JSON erstellen "
        "und den Pfad mit --client-secrets angeben."
    )

  token_path = Path(args.token_file).expanduser()
  scopes = required_scopes(args.playlist_id)
  creds = load_credentials(
      client_secrets_path,
      token_path,
      scopes,
      open_browser=not args.no_browser,
  )
  youtube = build("youtube", "v3", credentials=creds)

  body = {
      "snippet": {
          "title": args.title,
          "description": args.description,
          "categoryId": str(args.category_id),
      },
      "status": {
          "privacyStatus": args.privacy,
          "selfDeclaredMadeForKids": bool(args.made_for_kids),
      },
  }
  tags = parse_tags(args.tags)
  if tags:
    body["snippet"]["tags"] = tags

  request = youtube.videos().insert(
      part="snippet,status",
      body=body,
      media_body=MediaFileUpload(str(video_path), chunksize=8 * 1024 * 1024, resumable=True),
  )

  return youtube, resumable_upload(request)


def format_http_error(exc: HttpError) -> str:
  try:
    details = json.loads(exc.content.decode("utf-8"))
  except Exception:
    details = {"error": {"message": str(exc)}}
  return json.dumps(details, ensure_ascii=False)


def main() -> int:
  args = parse_args()
  if args.playlist_position is not None and not args.playlist_id.strip():
    print("Fehler: --playlist-position erfordert --playlist-id.", file=sys.stderr)
    return 1

  try:
    youtube, video_id = upload_video(args)
  except FileNotFoundError as exc:
    print(f"Fehler: {exc}", file=sys.stderr)
    return 1
  except HttpError as exc:
    print(f"YouTube API-Fehler: {format_http_error(exc)}", file=sys.stderr)
    return 1
  except Exception as exc:
    print(f"Unerwarteter Fehler beim Upload: {exc}", file=sys.stderr)
    return 1

  print(f"Upload erfolgreich. Video-ID: {video_id}", flush=True)
  print(f"https://youtu.be/{video_id}", flush=True)

  if args.playlist_id.strip():
    try:
      playlist_item_id = add_to_playlist(
          youtube,
          video_id,
          args.playlist_id.strip(),
          args.playlist_position,
      )
    except HttpError as exc:
      print(
          "Video wurde hochgeladen, konnte aber nicht zur Playlist hinzugefuegt werden. "
          f"Nicht erneut hochladen; vorhandene Video-ID verwenden: {video_id}",
          file=sys.stderr,
      )
      print(f"YouTube API-Fehler: {format_http_error(exc)}", file=sys.stderr)
      return PLAYLIST_PARTIAL_EXIT_STATUS
    except Exception as exc:
      print(
          "Video wurde hochgeladen, konnte aber nicht zur Playlist hinzugefuegt werden. "
          f"Nicht erneut hochladen; vorhandene Video-ID verwenden: {video_id}",
          file=sys.stderr,
      )
      print(f"Playlist-Fehler: {exc}", file=sys.stderr)
      return PLAYLIST_PARTIAL_EXIT_STATUS

    print(f"Zur Playlist hinzugefuegt (PlaylistItem-ID: {playlist_item_id}).", flush=True)
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
