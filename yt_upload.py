#!/usr/bin/env python3
"""Upload a video to YouTube using the official Data API v3."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import List

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload

SCOPES = [
    "https://www.googleapis.com/auth/youtube.upload",
    "https://www.googleapis.com/auth/youtube",
]
DEFAULT_CLIENT_SECRETS = Path.home() / ".config" / "yt-upload" / "client_secrets.json"
DEFAULT_TOKEN_FILE = Path.home() / ".config" / "yt-upload" / "token.json"
VALID_PRIVACY = {"private", "public", "unlisted"}


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
      type=int,
      default=None,
      help="Optional target position in playlist (requires --playlist-id)",
  )
  return parser.parse_args()


def load_credentials(client_secrets_path: Path, token_path: Path) -> Credentials:
  creds = None
  if token_path.exists():
    creds = Credentials.from_authorized_user_file(str(token_path), SCOPES)

  if creds and creds.expired and creds.refresh_token:
    creds.refresh(Request())

  # Force a new OAuth flow when scopes are missing (e.g. playlist support added later).
  if not creds or not creds.valid or not creds.has_scopes(SCOPES):
    flow = InstalledAppFlow.from_client_secrets_file(str(client_secrets_path), SCOPES)
    try:
      creds = flow.run_local_server(port=0, open_browser=True)
    except Exception:
      creds = flow.run_console()

  token_path.parent.mkdir(parents=True, exist_ok=True)
  token_path.write_text(creds.to_json(), encoding="utf-8")
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


def upload_video(args: argparse.Namespace) -> tuple[str, str | None]:
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
  creds = load_credentials(client_secrets_path, token_path)
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

  response = None
  while response is None:
    status, response = request.next_chunk()
    if status is not None:
      progress = int(status.progress() * 100)
      print(f"Upload-Fortschritt: {progress}%")

  video_id = str(response["id"])
  playlist_item_id = None
  if args.playlist_id.strip():
    playlist_item_id = add_to_playlist(
        youtube,
        video_id,
        args.playlist_id.strip(),
        args.playlist_position,
    )

  return video_id, playlist_item_id


def main() -> int:
  args = parse_args()
  if args.playlist_position is not None and not args.playlist_id.strip():
    print("Fehler: --playlist-position erfordert --playlist-id.", file=sys.stderr)
    return 1

  try:
    video_id, playlist_item_id = upload_video(args)
  except FileNotFoundError as exc:
    print(f"Fehler: {exc}", file=sys.stderr)
    return 1
  except HttpError as exc:
    try:
      details = json.loads(exc.content.decode("utf-8"))
    except Exception:
      details = {"error": {"message": str(exc)}}
    print(f"YouTube API-Fehler: {json.dumps(details, ensure_ascii=False)}", file=sys.stderr)
    return 1
  except Exception as exc:
    print(f"Unerwarteter Fehler beim Upload: {exc}", file=sys.stderr)
    return 1

  print(f"Upload erfolgreich. Video-ID: {video_id}")
  print(f"https://youtu.be/{video_id}")
  if playlist_item_id:
    print(f"Zur Playlist hinzugefugt (PlaylistItem-ID: {playlist_item_id}).")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
