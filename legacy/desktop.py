"""Native desktop host for the local Music Tagger UI.

The existing Flask routes remain the application core. pywebview supplies an
Edge/WebView2 window, so the app opens like a desktop tool without launching a
user-visible browser tab or bundling a second browser engine.
"""

from __future__ import annotations

import threading
import traceback
from pathlib import Path

from werkzeug.serving import make_server

import app as application


def report_startup_failure() -> None:
    """Make a pythonw startup failure actionable instead of silently exiting."""
    details = traceback.format_exc()
    log_path = Path(__file__).with_name("music-tagger-startup-error.log")
    try:
        log_path.write_text(details, encoding="utf-8")
    except OSError:
        pass

    try:
        from tkinter import Tk, messagebox

        dialog = Tk()
        dialog.withdraw()
        messagebox.showerror(
            "Music Tagger could not start",
            "The desktop app could not open.\n\n"
            f"Technical details were saved to:\n{log_path}",
        )
        dialog.destroy()
    except Exception:
        # The log is still useful if the Windows dialog itself is unavailable.
        pass


class DesktopApi:
    """Native-only calls exposed to the embedded UI."""

    def __init__(self) -> None:
        # pywebview reflects public API attributes into JavaScript. Keeping the
        # Window public made it walk the whole WinForms/WebView2 object graph,
        # recursively, on the UI thread.
        self._window = None

    def choose_folder(self) -> str:
        """Open the host window's folder picker on the GUI side, not Flask's."""
        if self._window is None:
            return ""
        import webview

        selected = self._window.create_file_dialog(webview.FOLDER_DIALOG)
        return selected[0] if selected else ""


def main() -> None:
    try:
        import webview
    except ImportError as exc:
        raise SystemExit(
            "pywebview is not installed. Run run.bat once to install dependencies."
        ) from exc

    # Waveform decoding can take a moment on a long source file. A threaded
    # local server keeps that background preview work from delaying the range
    # request used by the audio engine to start playback.
    server = make_server("127.0.0.1", 0, application.app, threaded=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}/"
    native_api = DesktopApi()
    window = webview.create_window(
        "Music Tagger",
        url,
        width=1440,
        height=920,
        min_size=(1100, 700),
        text_select=True,
        js_api=native_api,
    )
    native_api._window = window
    try:
        webview.start(debug=False)
    finally:
        server.shutdown()


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        report_startup_failure()
        raise
