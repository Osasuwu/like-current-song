"""Settings window — the tkinter view.

Thin by design: every value comes from `model.settings_from_config`, every
save goes through `model.validate` + `ConfigDocument.save`, and every
non-config side effect (OAuth, autostart) goes through `services`. This
module only lays out widgets and moves values between them and a
`Settings`.

Toolkit: stdlib tkinter/ttk. No extra dependency for the pipx install, and
PyInstaller bundles Tcl/Tk through its standard hook.
"""

from __future__ import annotations

import queue
import sys
import threading
import tkinter as tk
import webbrowser
from collections.abc import Callable
from tkinter import messagebox, ttk

from . import model, services

_TITLE = "Like Current Song — Settings"
_PAD = {"padx": 8, "pady": 3}
_HINT_WRAP = 460


class SettingsWindow:
    def __init__(self, root: tk.Tk, doc: model.ConfigDocument, *, from_tray: bool) -> None:
        self.root = root
        self.doc = doc
        self.from_tray = from_tray
        # (kind, error, result) — `result` carries the created spreadsheet
        # back from the worker thread; the connect jobs leave it None.
        self._results: queue.Queue[tuple[str, Exception | None, object]] = queue.Queue()
        self._busy = False

        s = doc.initial_settings()
        self._initial = s
        yt_id, yt_secret = services.saved_google_client("ytmusic")
        g_id, g_secret = services.saved_google_client("sheets")

        self.v_provider = tk.StringVar(value=s.provider)
        self.v_spotify_id = tk.StringVar(value=s.spotify_client_id)
        self.v_yt_id = tk.StringVar(value=yt_id)
        self.v_yt_secret = tk.StringVar(value=yt_secret)
        self.v_account = tk.StringVar()

        self.v_like_dest = tk.StringVar(value=s.like_destination)
        self.v_like_playlist = tk.StringVar(value=s.like_playlist)

        self.v_hotkey = tk.StringVar(value=s.hotkey)
        self.v_remove_hotkey = tk.StringVar(value=s.remove_hotkey)
        self.v_volume = tk.IntVar(value=round(s.feedback_volume * 100))
        self.v_volume_label = tk.StringVar()

        self.v_backend = tk.StringVar(value=s.storage_backend)
        self.v_sheet_id = tk.StringVar(value=s.sheets_spreadsheet_id)
        self.v_g_id = tk.StringVar(value=g_id)
        self.v_g_secret = tk.StringVar(value=g_secret)
        self.v_sheets_status = tk.StringVar()

        self._autostart_initial = services.autostart_enabled()
        self.v_autostart = tk.BooleanVar(value=bool(self._autostart_initial))

        self.v_archive_on = tk.BooleanVar(value=s.archive_enabled)
        self.v_archive_name = tk.StringVar(value=s.archive_playlist)
        self.v_best_on = tk.BooleanVar(value=s.best_enabled)
        self.v_best_name = tk.StringVar(value=s.best_playlist)
        self.v_best_n = tk.StringVar(value=str(s.best_threshold))
        self.v_follow_on = tk.BooleanVar(value=s.follow_enabled)
        self.v_follow_n = tk.StringVar(value=str(s.follow_threshold))
        self.v_cool_on = tk.BooleanVar(value=s.cooldown_enabled)
        self.v_cool_min = tk.StringVar(value=str(s.cooldown_minutes))
        self.v_extras_title = tk.StringVar()
        self._extras_open = False

        self.v_status = tk.StringVar()

        self._build()
        self._on_provider_change()
        self._on_like_destination_change()
        self._on_backend_change()
        self._on_volume_change()
        self._refresh_extras_title()

    # ── Layout ────────────────────────────────────────────────────────

    def _build(self) -> None:
        root = self.root
        root.title(_TITLE)
        root.resizable(False, False)
        root.protocol("WM_DELETE_WINDOW", self._on_cancel)
        root.bind("<Escape>", lambda _e: self._on_cancel())

        frame = ttk.Frame(root, padding=12)
        frame.grid(sticky="nsew")
        frame.columnconfigure(0, weight=1)
        outer = self._build_scroll_area(frame)
        row = 0

        if self.doc.load_error:
            ttk.Label(
                outer,
                text=(
                    f"Couldn't read your existing settings: {self.doc.load_error}.\n"
                    "Saving replaces the file; the unreadable copy is kept next to it."
                ),
                foreground="#b00020",
                wraplength=_HINT_WRAP + 40,
                justify="left",
            ).grid(row=row, column=0, sticky="w", pady=(0, 8))
            row += 1

        for build in (
            self._build_music,
            self._build_like,
            self._build_hotkeys,
            self._build_feedback,
            self._build_storage,
            self._build_startup,
            self._build_extras,
        ):
            section = build(outer)
            if section is not None:
                section.grid(row=row, column=0, sticky="ew", pady=(0, 8))
                row += 1

        # Status + buttons sit below the scroll area so they stay on screen
        # however tall the expanded sections get.
        ttk.Label(
            frame, textvariable=self.v_status, foreground="#555", wraplength=_HINT_WRAP + 40
        ).grid(row=1, column=0, sticky="w")

        buttons = ttk.Frame(frame)
        buttons.grid(row=2, column=0, sticky="e", pady=(6, 0))
        ttk.Button(buttons, text="Cancel", command=self._on_cancel).grid(row=0, column=0, padx=4)
        self.save_button = ttk.Button(buttons, text="Save", command=self._on_save, default="active")
        self.save_button.grid(row=0, column=1)

    def _build_scroll_area(self, parent) -> ttk.Frame:
        """A frame inside a canvas that is as tall as its content, up to
        most of the screen; past that it scrolls. Expanding "Extra actions"
        on a small / scaled display would otherwise push Save off-screen."""
        canvas = tk.Canvas(parent, highlightthickness=0, borderwidth=0)
        bar = ttk.Scrollbar(parent, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=bar.set)
        canvas.grid(row=0, column=0, sticky="nsew")
        content = ttk.Frame(canvas)
        content.columnconfigure(0, weight=1)
        canvas.create_window(0, 0, window=content, anchor="nw")
        # Leave room for the title bar, the buttons below and the taskbar.
        max_height = max(300, int(self.root.winfo_screenheight() * 0.62))

        def fit(_event=None) -> None:
            width, height = content.winfo_reqwidth(), content.winfo_reqheight()
            scrolls = height > max_height
            canvas.configure(
                width=width, height=min(height, max_height), scrollregion=(0, 0, width, height)
            )
            if scrolls:
                bar.grid(row=0, column=1, sticky="ns", padx=(4, 0))
            else:
                bar.grid_remove()
                canvas.yview_moveto(0)
            self._scrolls = scrolls
            self.root.after_idle(self._keep_on_screen)

        def wheel(event) -> None:
            if self._scrolls:
                canvas.yview_scroll(int(-event.delta / 120) or (-1 if event.delta > 0 else 1), "units")

        self._scrolls = False
        self._canvas = canvas
        content.bind("<Configure>", fit)
        self.root.bind_all("<MouseWheel>", wheel)
        return content

    def _keep_on_screen(self) -> None:
        """Nudge the window up if growing pushed its bottom off-screen."""
        root = self.root
        root.update_idletasks()
        bottom_limit = root.winfo_screenheight() - 60  # taskbar
        overflow = root.winfo_rooty() + root.winfo_height() - bottom_limit
        if overflow > 0:
            root.geometry(f"+{root.winfo_x()}+{max(0, root.winfo_y() - overflow)}")

    def _section(self, parent, title: str) -> ttk.LabelFrame:
        frame = ttk.LabelFrame(parent, text=title, padding=(8, 4))
        frame.columnconfigure(1, weight=1)
        return frame

    def _hint(self, parent, text: str, row: int, column: int = 0, columnspan: int = 3):
        label = ttk.Label(
            parent, text=text, foreground="#666", wraplength=_HINT_WRAP, justify="left"
        )
        label.grid(row=row, column=column, columnspan=columnspan, sticky="w", padx=8, pady=(0, 4))
        return label

    def _link(self, parent, text: str, url: str, row: int, column: int = 0):
        label = ttk.Label(parent, text=text, foreground="#1a5fb4", cursor="hand2")
        label.bind("<Button-1>", lambda _e: webbrowser.open(url))
        label.grid(row=row, column=column, columnspan=3, sticky="w", padx=8, pady=(0, 4))
        return label

    def _entry(self, parent, label: str, var: tk.StringVar, row: int, *, secret=False, width=44):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", **_PAD)
        entry = ttk.Entry(parent, textvariable=var, width=width, show="•" if secret else "")
        entry.grid(row=row, column=1, columnspan=2, sticky="ew", **_PAD)
        return entry

    def _build_music(self, parent):
        box = self._section(parent, "Music service and account")
        radios = ttk.Frame(box)
        radios.grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 4))
        for i, (name, label) in enumerate(model.PROVIDER_LABELS.items()):
            ttk.Radiobutton(
                radios,
                text=label,
                value=name,
                variable=self.v_provider,
                command=self._on_provider_change,
            ).grid(row=0, column=i, sticky="w", padx=(0, 16))

        # Spotify account
        self.spotify_frame = ttk.Frame(box)
        self.spotify_frame.columnconfigure(1, weight=1)
        self._entry(self.spotify_frame, "Client ID", self.v_spotify_id, 0)
        self._hint(
            self.spotify_frame,
            "Create an app on the Spotify dashboard with the redirect URI "
            f"{services.SPOTIFY_REDIRECT_URI}, then paste its Client ID.",
            1,
        )
        self._link(self.spotify_frame, "Open the Spotify dashboard", services.SPOTIFY_DASHBOARD_URL, 2)

        # YouTube Music account
        self.yt_frame = ttk.Frame(box)
        self.yt_frame.columnconfigure(1, weight=1)
        self._entry(self.yt_frame, "Google Client ID", self.v_yt_id, 0)
        self._entry(self.yt_frame, "Client Secret", self.v_yt_secret, 1, secret=True)
        self._hint(
            self.yt_frame,
            "Your own Google OAuth client (Desktop app) with the YouTube Data "
            "API v3 enabled. Stored with the YouTube tokens, not in config.json.",
            2,
        )
        self._link(self.yt_frame, "YouTube Music setup steps", services.YTMUSIC_SETUP_URL, 3)

        status = ttk.Frame(box)
        status.grid(row=2, column=0, columnspan=3, sticky="ew", pady=(2, 0))
        status.columnconfigure(0, weight=1)
        ttk.Label(status, textvariable=self.v_account).grid(row=0, column=0, sticky="w", padx=8)
        self.connect_button = ttk.Button(status, text="Connect…", command=self._on_connect_account)
        self.connect_button.grid(row=0, column=1, sticky="e", padx=8)
        return box

    def _build_like(self, parent):
        """Where a like lands. A core like setting, so it sits next to the
        music service rather than under the collapsed "Extra actions"."""
        box = self._section(parent, "Where a like goes")
        radios = ttk.Frame(box)
        radios.grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 4))
        for i, (name, label) in enumerate(model.LIKE_DESTINATION_LABELS.items()):
            ttk.Radiobutton(
                radios,
                text=label,
                value=name,
                variable=self.v_like_dest,
                command=self._on_like_destination_change,
            ).grid(row=0, column=i, sticky="w", padx=(0, 16))

        self.like_playlist_entry = self._entry(box, "Playlist name", self.v_like_playlist, 1)
        self._hint(box, model.LIKE_DESTINATION_HINT, 2)
        return box

    def _build_hotkeys(self, parent):
        box = self._section(parent, "Hotkeys")
        self._entry(box, "Like current track", self.v_hotkey, 0, width=28)
        self._entry(box, "Discard current track", self.v_remove_hotkey, 1, width=28)
        self._hint(
            box,
            "Keys joined with '+', e.g. ctrl+shift+alt+w. Discard dislikes the "
            "track on your music service (where that service has a dislike) and "
            "takes it out of the archive playlist, if one is set.",
            2,
        )
        return box

    def _build_feedback(self, parent):
        box = self._section(parent, "Feedback")
        ttk.Label(box, text="Sound volume").grid(row=0, column=0, sticky="w", **_PAD)
        ttk.Scale(
            box,
            from_=0,
            to=100,
            orient="horizontal",
            variable=self.v_volume,
            command=lambda _v: self._on_volume_change(),
        ).grid(row=0, column=1, sticky="ew", **_PAD)
        ttk.Label(box, textvariable=self.v_volume_label, width=5).grid(row=0, column=2, sticky="w")
        if sys.platform == "win32":
            ttk.Button(box, text="Test", command=self._on_test_sound).grid(row=0, column=3, padx=4)
        return box

    def _build_storage(self, parent):
        box = self._section(parent, "Like counter (optional)")
        ttk.Label(box, text="Count likes in").grid(row=0, column=0, sticky="w", **_PAD)
        combo = ttk.Combobox(
            box,
            textvariable=self.v_backend,
            values=model.STORAGE_BACKENDS,
            state="readonly",
            width=12,
        )
        combo.grid(row=0, column=1, sticky="w", **_PAD)
        combo.bind("<<ComboboxSelected>>", lambda _e: self._on_backend_change())
        self._hint(
            box,
            "Google Sheets counts your likes across devices, into a spreadsheet "
            "you own. Likes work without it; best and follow-artist need it.",
            1,
        )

        self.sheets_frame = ttk.Frame(box)
        self.sheets_frame.columnconfigure(1, weight=1)
        self._entry(self.sheets_frame, "Google Client ID", self.v_g_id, 0)
        self._entry(self.sheets_frame, "Client Secret", self.v_g_secret, 1, secret=True)
        ttk.Label(self.sheets_frame, textvariable=self.v_sheets_status).grid(
            row=2, column=0, columnspan=2, sticky="w", padx=8
        )
        self.sheets_button = ttk.Button(
            self.sheets_frame, text="Connect Google…", command=self._on_connect_sheets
        )
        self.sheets_button.grid(row=2, column=2, sticky="e", padx=8)
        # Creating comes before the ID box, because that is the order most
        # people need: sign in, get a sheet, and only paste one when they
        # already have a household sheet to join.
        self.create_sheet_button = ttk.Button(
            self.sheets_frame, text="Create spreadsheet", command=self._on_create_sheet
        )
        self.create_sheet_button.grid(row=3, column=2, sticky="e", padx=8)
        self._hint(
            self.sheets_frame,
            "Once Google is connected, 'Create spreadsheet' makes one in your "
            "Drive with the tabs and headers filled in. Already have one — a "
            "sheet your phone counts in? Paste its ID instead.",
            3,
            columnspan=2,
        )
        self._entry(self.sheets_frame, "Spreadsheet ID", self.v_sheet_id, 4)
        self._link(
            self.sheets_frame, "Create a Google OAuth client", services.GOOGLE_CREDENTIALS_URL, 5
        )
        # A second link, because they are two different pages: the
        # credentials one makes the client, and an API is only ever
        # switched on from its own page in the library (#165).
        self._link(
            self.sheets_frame, "Enable the Google Sheets API", services.GOOGLE_SHEETS_API_URL, 6
        )
        return box

    def _build_startup(self, parent):
        if not services.autostart_supported():
            return None
        box = self._section(parent, "Startup")
        ttk.Checkbutton(
            box, text="Start Like Current Song when I sign in to Windows", variable=self.v_autostart
        ).grid(row=0, column=0, columnspan=3, sticky="w", **_PAD)
        return box

    def _build_extras(self, parent):
        box = ttk.Frame(parent)
        box.columnconfigure(0, weight=1)
        ttk.Button(
            box, textvariable=self.v_extras_title, command=self._toggle_extras, style="Toolbutton"
        ).grid(row=0, column=0, sticky="w")

        body = ttk.Frame(box, padding=(8, 4))
        body.columnconfigure(1, weight=1)
        self.extras_body = body
        r = 0

        def action(title: str, var: tk.BooleanVar, hint_key: str) -> None:
            nonlocal r
            ttk.Checkbutton(
                body, text=title, variable=var, command=self._refresh_extras_title
            ).grid(row=r, column=0, columnspan=3, sticky="w", pady=(6, 0))
            r += 1
            self._hint(body, model.ACTION_HINTS[hint_key], r)
            r += 1

        action("Archive clean-up", self.v_archive_on, "archive_remove")
        self._entry(body, "Playlist", self.v_archive_name, r)
        r += 1

        action("Promote to best", self.v_best_on, "promote_to_best")
        self._entry(body, "Playlist", self.v_best_name, r)
        r += 1
        self._spin(body, "After N likes", self.v_best_n, r)
        r += 1

        action("Follow artist", self.v_follow_on, "follow_artist")
        self._spin(body, "After N tracks", self.v_follow_n, r)
        r += 1

        action("Like cooldown", self.v_cool_on, "like_cooldown")
        self._spin(body, "Minutes", self.v_cool_min, r, to=1440)
        return box

    def _spin(self, parent, label: str, var: tk.StringVar, row: int, *, to: int = 999):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", **_PAD)
        ttk.Spinbox(parent, from_=1, to=to, textvariable=var, width=6).grid(
            row=row, column=1, sticky="w", **_PAD
        )

    # ── Reactions ─────────────────────────────────────────────────────

    def _on_provider_change(self) -> None:
        if self.v_provider.get() == "ytmusic":
            self.spotify_frame.grid_remove()
            self.yt_frame.grid(row=1, column=0, columnspan=3, sticky="ew")
        else:
            self.yt_frame.grid_remove()
            self.spotify_frame.grid(row=1, column=0, columnspan=3, sticky="ew")
        self._refresh_account_status()

    def _refresh_account_status(self) -> None:
        if self.v_provider.get() == "ytmusic":
            connected = services.ytmusic_connected()
        else:
            connected = services.spotify_connected(self.v_spotify_id.get())
        self.v_account.set("✓ Connected" if connected else "Not connected")
        self.connect_button.configure(text="Reconnect…" if connected else "Connect…")

    def _on_like_destination_change(self) -> None:
        """Grey the playlist field out while likes only go to the service.

        The typed name stays in the box, so switching back and forth to
        compare the choices doesn't cost the user a retype.
        """
        wanted = self.v_like_dest.get() != model.NATIVE
        self.like_playlist_entry.state(["!disabled"] if wanted else ["disabled"])

    def _on_backend_change(self) -> None:
        """Show the Google Sheets fields iff the counter is switched on.

        Sheets is the counter, not one option among several: the only other
        choice is "none", so this hides the fields rather than swapping
        between alternative backend panels.
        """
        if self.v_backend.get() == "sheets":
            self.sheets_frame.grid(row=2, column=0, columnspan=3, sticky="ew")
            connected = services.sheets_connected()
            self.v_sheets_status.set("✓ Google connected" if connected else "Google not connected")
        else:
            self.sheets_frame.grid_remove()

    def _on_volume_change(self) -> None:
        self.v_volume_label.set(f"{int(float(self.v_volume.get()))}%")

    def _on_test_sound(self) -> None:
        volume = int(float(self.v_volume.get())) / 100

        def play() -> None:
            try:
                from like_spotify.hosts.windows import feedback

                feedback._play_tone(feedback._synth_tones(volume)["like"])
            except Exception:
                pass

        threading.Thread(target=play, daemon=True).start()

    def _toggle_extras(self) -> None:
        self._extras_open = not self._extras_open
        if self._extras_open:
            self.extras_body.grid(row=1, column=0, sticky="ew")
            # Bring what was just revealed into view when the area scrolls.
            self.root.after(100, lambda:self._scrolls and self._canvas.yview_moveto(1.0))
        else:
            self.extras_body.grid_remove()
        self._refresh_extras_title()

    def _refresh_extras_title(self) -> None:
        on = sum(
            v.get() for v in (self.v_archive_on, self.v_best_on, self.v_follow_on, self.v_cool_on)
        )
        arrow = "▾" if self._extras_open else "▸"
        state = f"{on} on" if on else "all off"
        self.v_extras_title.set(f"{arrow} Extra actions ({state})")

    # ── OAuth (runs on a worker thread; results polled back) ──────────

    def _on_connect_account(self) -> None:
        if self.v_provider.get() == "ytmusic":
            fn = lambda: services.connect_ytmusic(self.v_yt_id.get(), self.v_yt_secret.get())  # noqa: E731
        else:
            fn = lambda: services.connect_spotify(self.v_spotify_id.get())  # noqa: E731
        self._run_connect("account", fn)

    def _on_connect_sheets(self) -> None:
        self._run_connect(
            "sheets", lambda: services.connect_sheets(self.v_g_id.get(), self.v_g_secret.get())
        )

    def _on_create_sheet(self) -> None:
        """Make the counter spreadsheet, unless one is already named.

        Refusing out loud rather than quietly obliging: a second sheet
        would leave the counts in the first one stranded, and the field
        below is the only record of which sheet the other devices use.
        """
        existing = self.v_sheet_id.get().strip()
        if existing:
            self.v_status.set(
                f"A spreadsheet is already set up ({existing}). Clear the "
                "Spreadsheet ID first if you really want a new one."
            )
            return
        if not services.sheets_connected():
            self.v_status.set("Connect Google first — creating a sheet needs the tokens.")
            return
        self._run_connect(
            "create_sheet",
            services.create_counter_sheet,
            status="Creating a spreadsheet in your Google Drive…",
        )

    def _run_connect(
        self,
        kind: str,
        fn: Callable[[], object],
        *,
        status: str = "Waiting for you to finish signing in in the browser…",
    ) -> None:
        if self._busy:
            return
        self._busy = True
        self.connect_button.state(["disabled"])
        self.sheets_button.state(["disabled"])
        self.create_sheet_button.state(["disabled"])
        self.v_status.set(status)

        def work() -> None:
            try:
                self._results.put((kind, None, fn()))
            except Exception as e:  # surfaced in the window, never swallowed
                self._results.put((kind, e, None))

        threading.Thread(target=work, daemon=True).start()
        self.root.after(200, self._poll_connect)

    def _poll_connect(self) -> None:
        try:
            kind, error, result = self._results.get_nowait()
        except queue.Empty:
            self.root.after(200, self._poll_connect)
            return
        self._busy = False
        self.connect_button.state(["!disabled"])
        self.sheets_button.state(["!disabled"])
        self.create_sheet_button.state(["!disabled"])
        if error is not None and kind == "create_sheet":
            self.v_status.set(services.describe_create_failure(error))
        elif error is not None:
            self.v_status.set(f"Sign-in failed: {error}")
        elif kind == "create_sheet":
            # The id goes straight into the field the counter reads, so
            # Save keeps it and the user can copy it to their phone.
            self.v_sheet_id.set(result.spreadsheet_id)
            where = f" — {result.url}" if result.url else ""
            self.v_status.set(
                f"Created {result.spreadsheet_id}{where}. Save to keep your settings."
            )
        elif kind == "sheets":
            self.v_status.set("Google connected. Save to keep your settings.")
        else:
            self.v_status.set("Account connected. Save to keep your settings.")
        self._refresh_account_status()
        self._on_backend_change()

    # ── Save / cancel ─────────────────────────────────────────────────

    def collect(self) -> tuple[model.Settings | None, list[str]]:
        """Read the widgets into a `Settings`, or (None, problems)."""
        problems: list[str] = []

        def number(var: tk.StringVar, label: str, enabled: bool) -> int:
            try:
                return int(var.get().strip())
            except ValueError:
                if enabled:
                    problems.append(f"{label} must be a whole number.")
                return 1

        s = model.Settings(
            provider=self.v_provider.get(),
            spotify_client_id=self.v_spotify_id.get().strip(),
            like_destination=self.v_like_dest.get(),
            like_playlist=self.v_like_playlist.get().strip(),
            storage_backend=self.v_backend.get(),
            sheets_spreadsheet_id=self.v_sheet_id.get().strip(),
            hotkey=self.v_hotkey.get().strip(),
            remove_hotkey=self.v_remove_hotkey.get().strip(),
            feedback_volume=int(float(self.v_volume.get())) / 100,
            archive_enabled=self.v_archive_on.get(),
            archive_playlist=self.v_archive_name.get().strip(),
            best_enabled=self.v_best_on.get(),
            best_playlist=self.v_best_name.get().strip(),
            best_threshold=number(self.v_best_n, "Best N", self.v_best_on.get()),
            follow_enabled=self.v_follow_on.get(),
            follow_threshold=number(self.v_follow_n, "Follow-artist N", self.v_follow_on.get()),
            cooldown_enabled=self.v_cool_on.get(),
            cooldown_minutes=number(self.v_cool_min, "Cooldown minutes", self.v_cool_on.get()),
        )
        return (None, problems) if problems else (s, [])

    def _on_save(self) -> None:
        if self._busy:
            self.v_status.set("Finish (or cancel) the browser sign-in first.")
            return
        s, problems = self.collect()
        if s is not None:
            result = model.validate(s)
            problems = [i.message for i in result.errors] + _keyboard_problems(s)
        if problems:
            messagebox.showerror(_TITLE, "Please fix:\n\n• " + "\n• ".join(problems), parent=self.root)
            return
        if result.warnings:
            text = "\n• ".join(i.message for i in result.warnings)
            if not messagebox.askokcancel(_TITLE, f"Heads up:\n\n• {text}\n\nSave anyway?", parent=self.root):
                return

        try:
            backup = self.doc.save(s)
        except OSError as e:
            messagebox.showerror(_TITLE, f"Couldn't save {self.doc.path}:\n\n{e}", parent=self.root)
            return

        autostart_error = None
        if self._autostart_initial is not None and self.v_autostart.get() != self._autostart_initial:
            try:
                services.set_autostart(self.v_autostart.get())
            except Exception as e:
                autostart_error = e

        notes = []
        if backup is not None:
            notes.append(f"Your unreadable old settings were kept at {backup}.")
        if autostart_error is not None:
            notes.append(f"Couldn't change autostart: {autostart_error}")
        if not self.from_tray:
            notes.append(
                "If the tray app is already running, quit it and start it again "
                "to use the new settings. (Settings opened from the tray menu "
                "apply on their own.)"
            )
        if notes:
            messagebox.showinfo(_TITLE, f"Saved to {self.doc.path}.\n\n" + "\n\n".join(notes), parent=self.root)
        self.root.destroy()

    def _on_cancel(self) -> None:
        s, _ = self.collect()
        dirty = s != self._initial or (
            self._autostart_initial is not None and self.v_autostart.get() != self._autostart_initial
        )
        if dirty and not messagebox.askyesno(_TITLE, "Discard your changes?", parent=self.root):
            return
        self.root.destroy()


def _keyboard_problems(s: model.Settings) -> list[str]:
    """Ask the `keyboard` library (the real parser) about each hotkey.

    Best effort: if `keyboard` can't load on this platform the syntactic
    check in `model.validate` is all we get.
    """
    try:
        import keyboard
    except Exception:
        return []
    combos = [("Like hotkey", s.hotkey)]
    if s.remove_hotkey.strip():
        combos.append(("Discard hotkey", s.remove_hotkey))
    problems = []
    for label, combo in combos:
        try:
            keyboard.parse_hotkey(combo)
        except ValueError as e:
            problems.append(f"{label} '{combo}' isn't a key combination the hotkey library knows ({e}).")
        except Exception:
            pass
    return problems


def _enable_dpi_awareness() -> None:
    """Crisp text on scaled Windows displays (Tk is blurry otherwise)."""
    if sys.platform != "win32":
        return
    from like_spotify.hosts.windows.dpi import enable_dpi_awareness

    enable_dpi_awareness()


def _set_icon(root: tk.Tk) -> None:
    try:
        from PIL import ImageTk

        from like_spotify.hosts.windows.feedback import _make_logo_icon

        image = ImageTk.PhotoImage(_make_logo_icon())
        root.iconphoto(True, image)
        root._heart_icon = image  # keep a reference; Tk doesn't
    except Exception:
        pass


def run(*, from_tray: bool = False) -> int:
    _enable_dpi_awareness()
    try:
        root = tk.Tk()
    except tk.TclError as e:  # no display (headless / SSH without X)
        print(f"Can't open the settings window: {e}", file=sys.stderr)
        return 2
    _set_icon(root)
    SettingsWindow(root, model.ConfigDocument(), from_tray=from_tray)
    # Come to the front: a window spawned from a tray click otherwise
    # tends to open behind whatever had focus.
    root.lift()
    root.attributes("-topmost", True)
    root.after(300, lambda: root.attributes("-topmost", False))
    root.focus_force()
    root.mainloop()
    return 0
