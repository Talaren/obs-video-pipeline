#!/usr/bin/env python3
"""Unit tests for the YouTube uploader without network access."""

from __future__ import annotations

import argparse
import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch

import httplib2
from googleapiclient.errors import HttpError

import yt_upload


class FakeUploadRequest:
  def __init__(self) -> None:
    self.calls = 0

  def next_chunk(self):
    self.calls += 1
    if self.calls == 1:
      response = httplib2.Response({"status": "503", "retry-after": "0"})
      raise HttpError(response, b'{"error": {"message": "temporary"}}')
    return None, {"id": "video-123"}


class FakeTransportErrorUploadRequest:
  def __init__(self) -> None:
    self.calls = 0

  def next_chunk(self):
    self.calls += 1
    if self.calls == 1:
      raise yt_upload.TransportError("temporary credential refresh failure")
    return None, {"id": "video-transport"}


class YouTubeUploadTests(unittest.TestCase):
  def test_argparse_errors_keep_reserved_exit_status_two(self) -> None:
    argv = [
        "yt_upload.py",
        "--title",
        "Test",
        "--playlist-position",
        "not-a-number",
        "video.mp4",
    ]

    with (
        patch.object(yt_upload.sys, "argv", argv),
        redirect_stderr(io.StringIO()),
        self.assertRaises(SystemExit) as raised,
    ):
      yt_upload.parse_args()

    self.assertEqual(2, raised.exception.code)

  def test_resumable_upload_retries_temporary_http_error(self) -> None:
    request = FakeUploadRequest()

    with (
        patch.object(yt_upload.time, "sleep") as sleep,
        redirect_stderr(io.StringIO()),
    ):
      video_id = yt_upload.resumable_upload(request)

    self.assertEqual("video-123", video_id)
    self.assertEqual(2, request.calls)
    sleep.assert_called_once_with(0.0)

  def test_resumable_upload_retries_google_auth_transport_error(self) -> None:
    request = FakeTransportErrorUploadRequest()

    with (
        patch.object(yt_upload.random, "random", return_value=0.0),
        patch.object(yt_upload.time, "sleep") as sleep,
        redirect_stderr(io.StringIO()),
    ):
      video_id = yt_upload.resumable_upload(request)

    self.assertEqual("video-transport", video_id)
    self.assertEqual(2, request.calls)
    sleep.assert_called_once_with(0.0)

  def test_oauth_no_browser_uses_supported_local_server_flow(self) -> None:
    credentials = Mock()
    credentials.to_json.return_value = "{}"
    flow = Mock()
    flow.run_local_server.return_value = credentials

    with (
        tempfile.TemporaryDirectory() as temp_dir,
        patch.object(
            yt_upload.InstalledAppFlow,
            "from_client_secrets_file",
            return_value=flow,
        ),
    ):
      temp_path = Path(temp_dir)
      result = yt_upload.load_credentials(
          temp_path / "client.json",
          temp_path / "token.json",
          [yt_upload.UPLOAD_SCOPE],
          open_browser=False,
      )

    self.assertIs(credentials, result)
    flow.run_local_server.assert_called_once_with(port=0, open_browser=False)

  def test_playlist_failure_reports_uploaded_video_id(self) -> None:
    args = argparse.Namespace(
        playlist_id="playlist-123",
        playlist_position=None,
    )
    stderr = io.StringIO()
    stdout = io.StringIO()

    with (
        patch.object(yt_upload, "parse_args", return_value=args),
        patch.object(yt_upload, "upload_video", return_value=(Mock(), "video-123")),
        patch.object(yt_upload, "add_to_playlist", side_effect=RuntimeError("playlist failed")),
        redirect_stdout(stdout),
        redirect_stderr(stderr),
    ):
      exit_status = yt_upload.main()

    self.assertEqual(yt_upload.PLAYLIST_PARTIAL_EXIT_STATUS, exit_status)
    self.assertIn("Upload erfolgreich. Video-ID: video-123", stdout.getvalue())
    self.assertIn("Nicht erneut hochladen", stderr.getvalue())
    self.assertIn("video-123", stderr.getvalue())


if __name__ == "__main__":
  unittest.main()
