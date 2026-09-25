# The old browser-based UI

Moved here on 2026-09-25. The native app (`ui/`, built with `build.bat` or
`build.sh`) replaced it, and nothing in the main app uses these files.

- `app.py` — the Flask server that was the application core
- `desktop.py` — a pywebview window around it
- `launcher.py` — a small .exe that started `desktop.py`
- `templates/` — its single-page front end
- `run-webview.bat`, `build-webview.bat` — how it was started and packaged

It still runs from here (`legacy\run-webview.bat`) against the same `mtag/`
package, model and `libraries.json` in the project root. Delete this folder
once nobody needs it; `flask` and `pywebview` can then leave requirements.txt.
