"""应急系统：A 工程光照、声音和报警状态监测上位机。"""
from __future__ import annotations

import csv
from collections import deque
import json
import time
import math
from datetime import datetime
import queue
from pathlib import Path
import threading
import sys
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from serial_protocol import BoardStatus, EmergencySerial

BG = "#08111f"
PANEL = "#101d30"
PANEL2 = "#14253b"
LINE = "#263b59"
TEXT = "#e8f1ff"
MUTED = "#8ea6c3"
CYAN = "#42d9ff"
GREEN = "#35e0a1"
YELLOW = "#ffd166"
RED = "#ff5577"
PURPLE = "#a995ff"
POLL_OPTIONS = {"250 ms · 4 Hz": 250, "500 ms · 2 Hz": 500, "1 s · 1 Hz": 1000, "2 s · 0.5 Hz": 2000}


class Gauge(tk.Canvas):
    def __init__(self, master, title, accent, maximum, **kwargs):
        super().__init__(master, bg=PANEL, highlightthickness=0, **kwargs)
        self.title, self.accent, self.maximum = title, accent, maximum
        self.value, self.unit = 0, ""
        self.bind("<Configure>", lambda _e: self.redraw())

    def set_value(self, value, unit=""):
        self.value = None if value is None else max(0, int(value))
        self.unit = unit
        self.redraw()

    def redraw(self):
        self.delete("all")
        width = max(220, self.winfo_width())
        height = max(120, self.winfo_height())
        self.create_text(16, 16, anchor="w", text=self.title, fill=MUTED,
                         font=("Microsoft YaHei UI", 10, "bold"))
        self.create_text(16, 47, anchor="w", text="—" if self.value is None else f"{self.value:,}", fill=TEXT,
                         font=("Segoe UI", 25, "bold"))
        self.create_text(16, 78, anchor="w", text=self.unit, fill=MUTED,
                         font=("Microsoft YaHei UI", 9))
        left, right, y = 16, width - 16, height - 22
        self.create_rectangle(left, y - 6, right, y + 6, fill="#1d304a", outline="")
        ratio = min(1, (self.value or 0) / max(1, self.maximum))
        self.create_rectangle(left, y - 6, left + (right - left) * ratio, y + 6,
                              fill=self.accent, outline="")


class TrendChart(tk.Canvas):
    def __init__(self, master, **kwargs):
        super().__init__(master, bg=PANEL, highlightthickness=0, **kwargs)
        self.samples = deque(maxlen=240)
        self.bind("<Configure>", lambda _e: self.redraw())

    def append(self, light, sound, timestamp):
        self.samples.append((timestamp, light, sound))
        self.redraw()

    def redraw(self):
        self.delete("all")
        width, height = max(360, self.winfo_width()), max(170, self.winfo_height())
        left, right, top, bottom = 62, width - 54, 45, height - 32
        self.create_text(16, 16, anchor="w", text="实时趋势 · 最近 240 点", fill=TEXT,
                         font=("Microsoft YaHei UI", 11, "bold"))
        self.create_text(right, 16, anchor="e", text="光照（左轴） / 声音（右轴）", fill=MUTED,
                         font=("Microsoft YaHei UI", 9))
        samples = list(self.samples)
        light_max = max(400, *(v[1] or 0 for v in samples)) if samples else 400
        light_max = math.ceil(light_max / 100) * 100
        sound_max = max(1000, *(v[2] for v in samples)) if samples else 1000
        sound_max = math.ceil(sound_max / 500) * 500
        for i in range(5):
            y = top + (bottom - top) * i / 4
            self.create_line(left, y, right, y, fill=LINE)
            self.create_text(left - 8, y, text=f"{light_max * (1 - i / 4):.0f}", fill=CYAN,
                             anchor="e", font=("Segoe UI", 8))
            self.create_text(right + 8, y, text=f"{sound_max * (1 - i / 4):.0f}", fill=YELLOW,
                             anchor="w", font=("Segoe UI", 8))
        y = bottom - (bottom - top) * 700 / sound_max
        self.create_line(left, y, right, y, fill="#785f38", dash=(4, 4))
        self.create_text(left + 6, y - 8, text="声音高阈值 700", fill=YELLOW, anchor="w", font=("Microsoft YaHei UI", 8))
        if len(samples) < 2:
            self.create_text((left + right) / 2, (top + bottom) / 2,
                             text="连接设备后绘制真实采样数据", fill=MUTED, font=("Microsoft YaHei UI", 10))
            return
        start, end = samples[0][0], samples[-1][0]
        for field, scale, color in ((1, light_max, CYAN), (2, sound_max, YELLOW)):
            points = []
            for timestamp, light, sound in samples:
                value = light if field == 1 else sound
                if value is None:
                    if len(points) >= 4: self.create_line(*points, fill=color, width=2)
                    points = []
                    continue
                points.extend((left + (right - left) * (timestamp - start) / max(0.001, end - start),
                               bottom - (bottom - top) * value / scale))
            if len(points) >= 4: self.create_line(*points, fill=color, width=2)
        for x, timestamp, anchor in ((left, start, "w"), (right, end, "e")):
            self.create_text(x, height - 12, text=datetime.fromtimestamp(timestamp).strftime("%H:%M:%S"),
                             fill=MUTED, anchor=anchor, font=("Segoe UI", 8))


class EmergencySystem(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("应急系统")
        icon = Path(__file__).with_name("assets") / "emergency.ico"
        if sys.platform == "win32" and icon.exists(): self.iconbitmap(str(icon))
        self.geometry(f"{min(1480, self.winfo_screenwidth() - 100)}x{min(1040, self.winfo_screenheight() - 100)}")
        self.minsize(1120, 720)
        self.configure(bg=BG)
        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self.events = queue.Queue()
        self.last_status = None
        self.history = []
        self.csv_rows = deque(maxlen=50000)
        self.event_rows = deque(maxlen=1000)
        self.total_samples = 0
        self.generation = 0
        self.closing = threading.Event()
        self.connecting = False
        self.want_connection = False
        self.connection_port = ""
        self.connection_hwid = ""
        self.port_infos = []
        self._opening_client = None
        self._next_reconnect = 0
        self._last_valid = 0
        self._clock_refresh = 0
        self._history_dirty = True
        self._last_alarm_beep = 0
        self.connection_failures = 0
        self.response_timeouts = 0
        self.chart_paused = False
        self.stale = True
        self._record_handle = None
        self._record_writer = None
        self.settings_path = Path(sys.executable if getattr(sys, "frozen", False) else __file__).with_name("settings.json")
        try:
            saved = json.loads(self.settings_path.read_text(encoding="utf-8"))
            if not isinstance(saved, dict): saved = {}
        except (OSError, ValueError):
            saved = {}
        self.auto_reconnect = tk.BooleanVar(value=saved.get("auto_reconnect", True) is True)
        self.sound_notify = tk.BooleanVar(value=saved.get("sound_notify", False) is True)
        self.poll_interval = tk.StringVar(value=saved.get("poll_interval") if saved.get("poll_interval") in POLL_OPTIONS else "500 ms · 2 Hz")
        self.history_filter = tk.StringVar(value="全部采样")
        self.polling = False
        self.serial = EmergencySerial(on_error=self._enqueue_error)
        self.build_style()
        self.build_ui()
        self.refresh_ports()
        if saved.get("port") in self.port_combo["values"]: self.port_var.set(saved["port"])
        self.bind("<Control-e>", lambda _e: self.export_csv())
        self.bind("<F5>", lambda _e: self.request_status())
        self.after(100, self.drain_events)
        self.after(500, self.poll_once)

    def build_style(self):
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure("TFrame", background=BG)
        style.configure("TLabel", background=BG, foreground=TEXT, font=("Microsoft YaHei UI", 10))
        style.configure("Muted.TLabel", background=BG, foreground=MUTED, font=("Microsoft YaHei UI", 9))
        style.configure("Title.TLabel", background=BG, foreground=TEXT, font=("Microsoft YaHei UI", 23, "bold"))
        style.configure("Sub.TLabel", background=BG, foreground=MUTED, font=("Microsoft YaHei UI", 10))
        style.configure("Accent.TButton", background=CYAN, foreground="#04101d", borderwidth=0,
                        padding=(12, 7), font=("Microsoft YaHei UI", 9, "bold"))
        style.map("Accent.TButton", background=[("active", "#75e5ff")])
        style.configure("Dark.TButton", background=PANEL2, foreground=TEXT, borderwidth=0,
                        padding=(10, 6), font=("Microsoft YaHei UI", 9))
        style.map("Dark.TButton", background=[("active", "#203956")])
        style.configure("TCombobox", fieldbackground=PANEL2, background=PANEL2, foreground=TEXT, arrowcolor=CYAN)
        style.map("TCombobox", fieldbackground=[("readonly", PANEL2)], foreground=[("readonly", TEXT)],
                  selectbackground=[("readonly", PANEL2)], selectforeground=[("readonly", TEXT)])
        style.configure("Vertical.TScrollbar", background=PANEL2, troughcolor=PANEL, arrowcolor=MUTED,
                        bordercolor=PANEL, lightcolor=PANEL2, darkcolor=PANEL2)
        style.configure("Treeview", background=PANEL, fieldbackground=PANEL, foreground=TEXT,
                        borderwidth=0, rowheight=23, font=("Microsoft YaHei UI", 9))
        style.configure("Treeview.Heading", background=PANEL2, foreground=MUTED, relief="flat",
                        bordercolor=LINE, lightcolor=LINE, darkcolor=LINE, font=("Microsoft YaHei UI", 9, "bold"))
        style.map("Treeview", background=[("selected", "#224464")], foreground=[("selected", TEXT)])
        style.configure("TNotebook", background=BG, borderwidth=0)
        style.configure("TNotebook.Tab", background=BG, foreground=MUTED, padding=(24, 10),
                        font=("Microsoft YaHei UI", 10, "bold"), borderwidth=0)
        style.map("TNotebook.Tab", background=[("selected", PANEL2)], foreground=[("selected", CYAN)])
        style.configure("TCheckbutton", background=PANEL, foreground=TEXT, font=("Microsoft YaHei UI", 10))
        style.map("TCheckbutton", background=[("active", PANEL2)])

    def panel(self, master):
        return tk.Frame(master, bg=PANEL, highlightbackground=LINE, highlightthickness=1)

    def build_ui(self):
        header = ttk.Frame(self)
        header.pack(fill="x", padx=28, pady=(22, 12))
        tk.Label(header, text="＋", bg=CYAN, fg=BG, font=("Segoe UI", 22, "bold"), width=2).pack(side="left", padx=(0, 14))
        ttk.Label(header, text="应急系统", style="Title.TLabel").pack(side="left")
        ttk.Label(header, text="EMERGENCY SYSTEM  /  A 板监测中心", style="Sub.TLabel").pack(side="left", padx=18, pady=(9, 0))
        self.connection_label = tk.Label(header, text="● 未连接", bg=BG, fg=MUTED,
                                         font=("Microsoft YaHei UI", 10, "bold"))
        self.connection_label.pack(side="right", pady=(8, 0))

        footer = tk.Frame(self, bg="#0c1727", height=32)
        footer.pack(side="bottom", fill="x")
        self.footer_label = tk.Label(footer, text="就绪  ·  请连接 A 板串口", bg="#0c1727", fg=MUTED,
                                     font=("Microsoft YaHei UI", 9))
        self.footer_label.pack(side="left", padx=28, pady=6)
        self.clock_label = tk.Label(footer, text="", bg="#0c1727", fg=MUTED, font=("Consolas", 10))
        self.clock_label.pack(side="right", padx=28)

        conn = ttk.Frame(self)
        conn.pack(fill="x", padx=28, pady=(0, 14))
        ttk.Label(conn, text="串口", style="Muted.TLabel").pack(side="left")
        self.port_var = tk.StringVar()
        self.port_combo = ttk.Combobox(conn, textvariable=self.port_var, width=15, state="readonly")
        self.port_combo.pack(side="left", padx=8)
        ttk.Label(conn, text="波特率", style="Muted.TLabel").pack(side="left")
        self.baud_var = tk.StringVar(value="115200")
        ttk.Combobox(conn, textvariable=self.baud_var, values=("115200",),
                     width=10, state="readonly").pack(side="left", padx=8)
        ttk.Button(conn, text="刷新端口", style="Dark.TButton", command=self.refresh_ports).pack(side="left", padx=3)
        self.connect_button = ttk.Button(conn, text="连接 A 板", style="Accent.TButton", command=self.toggle_connection)
        self.connect_button.pack(side="left", padx=3)
        ttk.Button(conn, text="导出 CSV", style="Dark.TButton", command=self.export_csv).pack(side="right", padx=3)
        ttk.Label(conn, text="115200 · 8N1", style="Muted.TLabel").pack(side="right", padx=14)

        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill="both", expand=True, padx=28, pady=(0, 14))
        overview = ttk.Frame(self.notebook)
        self.notebook.add(overview, text="实时总览")
        self.dashboard = tk.Canvas(overview, bg=BG, highlightthickness=0)
        dashboard_scroll = ttk.Scrollbar(overview, command=self.dashboard.yview)
        dashboard_scroll.pack(side="right", fill="y")
        self.dashboard.pack(side="left", fill="both", expand=True)
        self.dashboard.configure(yscrollcommand=dashboard_scroll.set)
        root = ttk.Frame(self.dashboard, padding=(0, 14, 0, 0))
        window_id = self.dashboard.create_window(0, 0, anchor="nw", window=root)
        def fit_dashboard(_event=None):
            self.dashboard.itemconfigure(window_id, width=self.dashboard.winfo_width(),
                height=max(root.winfo_reqheight(), self.dashboard.winfo_height()))
            self.dashboard.configure(scrollregion=self.dashboard.bbox("all"))
        root.bind("<Configure>", fit_dashboard)
        self.dashboard.bind("<Configure>", fit_dashboard)
        def scroll_dashboard(event):
            widget = event.widget
            while widget is not None:
                if widget is overview:
                    if self.dashboard.yview() != (0.0, 1.0): self.dashboard.yview_scroll(-int(event.delta / 120), "units")
                    break
                if isinstance(widget, (ttk.Treeview, tk.Text)): break
                widget = getattr(widget, "master", None)
        self.bind("<MouseWheel>", scroll_dashboard, add=True)
        self.history_page = ttk.Frame(self.notebook, padding=(0, 14, 0, 0))
        self.settings_page = ttk.Frame(self.notebook, padding=(0, 14, 0, 0))
        self.guide_page = ttk.Frame(self.notebook, padding=(0, 14, 0, 0))
        self.notebook.add(self.history_page, text="数据记录")
        self.notebook.add(self.settings_page, text="通信与设置")
        self.notebook.add(self.guide_page, text="接入指南")
        root.columnconfigure(0, weight=3, uniform="main")
        root.columnconfigure(1, weight=2, uniform="main")
        root.rowconfigure(1, weight=3)
        root.rowconfigure(2, weight=2)

        cards = ttk.Frame(root)
        cards.grid(row=0, column=0, columnspan=2, sticky="nsew", pady=(0, 12))
        cards.columnconfigure(0, weight=1, uniform="cards")
        cards.columnconfigure(1, weight=1, uniform="cards")
        cards.columnconfigure(2, weight=1, uniform="cards")
        lp, sp, ap = self.panel(cards), self.panel(cards), self.panel(cards)
        lp.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        sp.grid(row=0, column=1, sticky="nsew", padx=8)
        ap.grid(row=0, column=2, sticky="nsew", padx=(8, 0))
        self.light_gauge = Gauge(lp, "01  环境光照 · 原始值", CYAN, 65535, height=120)
        self.light_gauge.pack(fill="both", expand=True, padx=12, pady=10)
        self.sound_gauge = Gauge(sp, "02  声音幅度 · ADC 峰峰值", YELLOW, 4095, height=120)
        self.sound_gauge.pack(fill="both", expand=True, padx=12, pady=10)
        self.light_gauge.set_value(None, "等待设备数据")
        self.sound_gauge.set_value(None, "等待设备数据")
        tk.Label(ap, text="03  安全状态", bg=PANEL, fg=MUTED, font=("Microsoft YaHei UI", 10, "bold")).pack(anchor="w", padx=18, pady=(16, 2))
        self.alarm_value = tk.Label(ap, text="等待数据", bg=PANEL, fg=MUTED, font=("Microsoft YaHei UI", 23, "bold"))
        self.alarm_value.pack(anchor="w", padx=18)
        self.alarm_detail = tk.Label(ap, text="连接 A 板后显示报警来源", bg=PANEL, fg=MUTED, font=("Microsoft YaHei UI", 9), wraplength=320, justify="left")
        self.alarm_detail.pack(anchor="w", padx=18, pady=(2, 0))
        self.alarm_bar = tk.Frame(ap, bg=LINE, height=8)
        self.alarm_bar.pack(fill="x", padx=18, pady=(18, 12))

        chart_panel = self.panel(root)
        chart_panel.grid(row=1, column=0, sticky="nsew", padx=(0, 8), pady=(0, 12))
        chart_panel.rowconfigure(0, weight=1)
        chart_panel.columnconfigure(0, weight=1)
        self.chart = TrendChart(chart_panel, height=230, width=500)
        self.chart.grid(row=0, column=0, sticky="nsew", padx=8, pady=8)

        snapshot = self.panel(root)
        snapshot.grid(row=1, column=1, sticky="nsew", padx=(8, 0), pady=(0, 12))
        tk.Label(snapshot, text="设备快照", bg=PANEL, fg=TEXT, font=("Microsoft YaHei UI", 11, "bold")).pack(anchor="w", padx=18, pady=(14, 8))
        self.snapshot_text = tk.Text(snapshot, bg=PANEL, fg=MUTED, relief="flat", height=8, width=36,
                                     font=("Consolas", 10), padx=18, pady=4, state="disabled")
        self.snapshot_text.pack(fill="both", expand=True)
        self.snapshot_text.configure(state="normal")
        self.snapshot_text.insert("1.0", "等待设备连接\n\n光照、声音、画面和错误码\n将在收到有效状态帧后显示。")
        self.snapshot_text.configure(state="disabled")

        bottom = ttk.Frame(root)
        bottom.grid(row=2, column=0, columnspan=2, sticky="nsew")
        bottom.rowconfigure(0, weight=1)
        bottom.columnconfigure(0, weight=3, uniform="bottom")
        bottom.columnconfigure(1, weight=2, uniform="bottom")
        events = self.panel(bottom)
        events.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        events.rowconfigure(1, weight=1)
        events.columnconfigure(0, weight=1)
        tk.Label(events, text="事件日志", bg=PANEL, fg=TEXT, font=("Microsoft YaHei UI", 11, "bold")).grid(row=0, column=0, sticky="w", padx=18, pady=(12, 6))
        ttk.Button(events, text="清空", style="Dark.TButton", command=self.clear_events).grid(row=0, column=0, sticky="e", padx=12, pady=6)
        self.event_tree = ttk.Treeview(events, columns=("time", "level", "message"), show="headings", height=6)
        for col, title, width in (("time", "时间", 86), ("level", "级别", 66), ("message", "信息", 420)):
            self.event_tree.heading(col, text=title)
            self.event_tree.column(col, width=width, minwidth=60, stretch=col == "message", anchor="center" if col != "message" else "w")
        self.event_tree.grid(row=1, column=0, sticky="nsew", padx=(10, 0), pady=(0, 10))
        scrollbar = ttk.Scrollbar(events, orient="vertical", command=self.event_tree.yview)
        scrollbar.grid(row=1, column=1, sticky="ns", pady=(0, 10))
        self.event_tree.configure(yscrollcommand=scrollbar.set)
        self.event_tree.tag_configure("ALARM", foreground=RED)
        self.event_tree.tag_configure("WARN", foreground=YELLOW)
        self.event_tree.tag_configure("ERROR", foreground=RED)

        controls = self.panel(bottom)
        controls.grid(row=0, column=1, sticky="nsew", padx=(8, 0))
        tk.Label(controls, text="监测操作", bg=PANEL, fg=TEXT,
                 font=("Microsoft YaHei UI", 11, "bold")).pack(anchor="w", padx=18, pady=(12, 8))
        actions = tk.Frame(controls, bg=PANEL)
        actions.pack(fill="x", padx=18)
        actions.columnconfigure((0, 1), weight=1)
        ttk.Button(actions, text="立即读取", style="Dark.TButton", command=self.request_status).grid(row=0, column=0, sticky="ew", padx=(0, 5), pady=4)
        self.pause_button = ttk.Button(actions, text="暂停曲线", style="Dark.TButton", command=self.toggle_chart)
        self.pause_button.grid(row=0, column=1, sticky="ew", padx=(5, 0), pady=4)
        self.record_button = ttk.Button(actions, text="开始记录 CSV", style="Dark.TButton", command=self.toggle_recording)
        self.record_button.grid(row=1, column=0, sticky="ew", padx=(0, 5), pady=4)
        ttk.Button(actions, text="导出事件日志", style="Dark.TButton", command=self.export_events).grid(row=1, column=1, sticky="ew", padx=(5, 0), pady=4)
        self.sample_label = tk.Label(controls, text="采样 0 条 · 自动读取 2 Hz", bg=PANEL, fg=CYAN,
                                    font=("Microsoft YaHei UI", 9))
        self.sample_label.pack(anchor="w", padx=18, pady=(10, 4))
        tk.Label(controls, text="光照：暗 <160 / 恢复 >320。\n声音：高 >700 / 低 <350；报警以板端判定为准。",
                 bg=PANEL, fg=MUTED, justify="left", wraplength=410,
                 font=("Microsoft YaHei UI", 9)).pack(anchor="w", padx=18, pady=(0, 10))
        self.build_history_page()
        self.build_settings_page()
        self.build_guide_page()
        self.notebook.bind("<<NotebookTabChanged>>", self.on_page_changed)

    def on_page_changed(self, _event=None):
        page = self.notebook.index("current")
        if page == 1: self.refresh_history()
        elif page == 2: self.refresh_diagnostics()

    def build_history_page(self):
        bar = ttk.Frame(self.history_page)
        bar.pack(fill="x", pady=(0, 12))
        self.history_summary = ttk.Label(bar, text="暂无采样记录", style="Sub.TLabel")
        self.history_summary.pack(side="left")
        choice = ttk.Combobox(bar, textvariable=self.history_filter, values=("全部采样", "报警采样", "光照离线"),
                              state="readonly", width=14)
        choice.pack(side="right")
        choice.bind("<<ComboboxSelected>>", lambda _e: self.refresh_history())
        ttk.Button(bar, text="导出全部缓存", style="Accent.TButton", command=self.export_csv).pack(side="right", padx=10)
        panel = self.panel(self.history_page)
        panel.pack(fill="both", expand=True)
        panel.rowconfigure(0, weight=1)
        panel.columnconfigure(0, weight=1)
        columns = ("time", "light", "online", "sound", "alarm", "picture", "error")
        self.history_tree = ttk.Treeview(panel, columns=columns, show="headings")
        for col, title, width in zip(columns, ("采样时间", "光照原始值", "光照在线", "声音幅度", "报警状态", "画面", "错误码"),
                                    (230, 130, 110, 130, 170, 100, 100)):
            self.history_tree.heading(col, text=title)
            self.history_tree.column(col, width=width, minwidth=70, anchor="center")
        self.history_tree.grid(row=0, column=0, sticky="nsew", padx=(12, 0), pady=12)
        scroll = ttk.Scrollbar(panel, command=self.history_tree.yview)
        scroll.grid(row=0, column=1, sticky="ns", pady=12)
        self.history_tree.configure(yscrollcommand=scroll.set)
        self.history_tree.tag_configure("alarm", foreground=RED)
        ttk.Label(self.history_page, text="显示最近 1,000 条匹配记录 · 缓存上限 50,000 条 · 长时间监测请开启连续 CSV 记录",
                  style="Muted.TLabel").pack(anchor="w", pady=12)

    def refresh_history(self):
        rows = list(self.csv_rows)
        if self.history_filter.get() == "报警采样":
            rows = [r for r in rows if r["声音报警"] or r["碰撞报警"]]
        elif self.history_filter.get() == "光照离线":
            rows = [r for r in rows if not r["光照在线"]]
        self.history_summary.configure(text=f"累计采样 {self.total_samples:,} 条  /  当前匹配 {len(rows):,} 条")
        self.history_tree.delete(*self.history_tree.get_children())
        for row in reversed(rows[-1000:]):
            alarm = "碰撞报警" if row["碰撞报警"] else "声音报警" if row["声音报警"] else "光照不足" if row["光照不足"] else "—"
            self.history_tree.insert("", "end", values=(row["时间"].replace("T", " "),
                row["光照原始值"] if row["光照在线"] else "—", "在线" if row["光照在线"] else "离线",
                row["声音幅度"], alarm, f"PIC{row['画面']}", f"0x{row['错误码']:02X}"),
                tags=("alarm",) if row["声音报警"] or row["碰撞报警"] else ())
        self._history_dirty = False

    def build_settings_page(self):
        self.settings_page.columnconfigure((0, 1), weight=1, uniform="settings")
        self.settings_page.rowconfigure(0, weight=1)
        prefs, diagnostic = self.panel(self.settings_page), self.panel(self.settings_page)
        prefs.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        diagnostic.grid(row=0, column=1, sticky="nsew", padx=(8, 0))
        tk.Label(prefs, text="监测偏好", bg=PANEL, fg=TEXT, font=("Microsoft YaHei UI", 15, "bold")).pack(anchor="w", padx=24, pady=(22, 20))
        tk.Label(prefs, text="状态读取周期", bg=PANEL, fg=MUTED, font=("Microsoft YaHei UI", 10)).pack(anchor="w", padx=24)
        interval = ttk.Combobox(prefs, textvariable=self.poll_interval, values=tuple(POLL_OPTIONS), state="readonly", width=24)
        interval.pack(anchor="w", padx=24, pady=(8, 22))
        interval.bind("<<ComboboxSelected>>", lambda _e: self.save_settings())
        ttk.Checkbutton(prefs, text="意外断线后自动重连原端口", variable=self.auto_reconnect, command=self.save_settings).pack(anchor="w", padx=24, pady=10)
        ttk.Checkbutton(prefs, text="新报警时播放电脑提示音", variable=self.sound_notify, command=self.save_settings).pack(anchor="w", padx=24, pady=10)
        tk.Label(prefs, text="手动断开后停止重连。自动重连间隔为 3 秒。\n提示音只在新声音 / 碰撞报警时响一次。\n这些设置仅作用于上位机。", bg=PANEL, fg=MUTED,
                 justify="left", font=("Microsoft YaHei UI", 10), wraplength=440).pack(anchor="w", padx=24, pady=24)
        ttk.Button(prefs, text="导出诊断报告", command=self.export_diagnostics, style="Dark.TButton").pack(anchor="w", padx=24)
        tk.Label(diagnostic, text="通信诊断", bg=PANEL, fg=TEXT, font=("Microsoft YaHei UI", 15, "bold")).pack(anchor="w", padx=24, pady=(22, 12))
        self.diagnostic_text = tk.Text(diagnostic, bg=PANEL, fg=MUTED, relief="flat", font=("Microsoft YaHei UI", 10),
                                       wrap="word", padx=24, pady=10, width=38, state="disabled")
        self.diagnostic_text.pack(fill="both", expand=True)

    def build_guide_page(self):
        panel = self.panel(self.guide_page)
        panel.pack(fill="both", expand=True)
        tk.Label(panel, text="连接与使用", bg=PANEL, fg=TEXT, font=("Microsoft YaHei UI", 18, "bold")).pack(anchor="w", padx=30, pady=(24, 8))
        guide = tk.Text(panel, bg=PANEL, fg=TEXT, relief="flat", wrap="word", padx=30, pady=12,
                        font=("Microsoft YaHei UI", 11), spacing3=12, height=12)
        guide.pack(side="left", fill="both", expand=True, pady=(0, 20))
        scroll = ttk.Scrollbar(panel, command=guide.yview)
        scroll.pack(side="right", fill="y", pady=20)
        guide.configure(yscrollcommand=scroll.set)
        guide.insert("1.0", "01  准备 A 板\n烧录带 EMERGENCY_UART 的 A 板固件，旧 NO_UART 固件无法返回数据。B 板继续使用原固件。\n"
                     "02  连接串口\n使用板卡的 USB 转串口接口，选择对应 COM 口并点击「连接 A 板」。固定 115200 / 8N1 / 无流控。"
                     "外接转换器时，FPGA RX F12 ← 转换器 TX，FPGA TX D12 → 转换器 RX，使用 3.3 V TTL 并共地。\n"
                     "03  查看真实读数\n光照为 0–65535 原始值；声音为 0–4095 ADC 峰峰值。两者未标定为 lux / dB。"
                     "报警以 A 板判定为准，包含持续确认和冷却；曲线越过阈值不等于已经报警。\n"
                     "04  留存记录\n「开始记录 CSV」持续写入采样；「导出 CSV」导出当前缓存。暂停曲线后，报警和记录仍继续。"
                     "「数据记录」可筛选报警、光照离线记录；「通信与设置」查看接收量、超时和坏帧。\n"
                     "05  常见问题\n没有串口：检查 USB 数据线和 CH340 驱动。端口被占用：关闭串口助手。"
                     "有串口但无数据：检查固件和 TX/RX。光照离线：检查传感器接线。"
                     "断线后数据立即标记失效，历史曲线仅供回看。\n"
                     "快捷键  F5 立即读取  ·  Ctrl+E 导出采样\n")
        guide.configure(state="disabled")

    def save_settings(self):
        try:
            self.settings_path.write_text(json.dumps({"port": self.port_var.get(), "poll_interval": self.poll_interval.get(),
                "auto_reconnect": self.auto_reconnect.get(), "sound_notify": self.sound_notify.get()}, ensure_ascii=False, indent=2), encoding="utf-8")
        except OSError as exc:
            self.log("WARN", f"偏好未保存：{exc}")

    def diagnostics(self):
        return {"应用": "应急系统", "版本": "2.1", "时间": datetime.now().isoformat(timespec="seconds"),
                "端口": self.connection_port, "设备标识": self.connection_hwid,
                "已打开": self.serial.connected, "数据有效": not self.stale, "累计采样": self.total_samples,
                "通信计数": self.serial.statistics, "重连失败次数": self.connection_failures,
                "板端UART错误": self.last_status.uart_errors if self.last_status else None}

    def refresh_diagnostics(self):
        stats = self.serial.statistics
        lines = [f"当前端口      {self.connection_port or '未选择'}", "串口参数      115200 / 8N1 / 无流控",
                 f"数据状态      {'等待有效数据' if self.stale else '实时接收中'}",
                 f"发送请求      {stats.get('requests', 0):,}", f"有效采样      {stats.get('samples', 0):,}",
                 f"响应超时      {stats.get('timeouts', 0):,}", f"坏帧 / 截断      {stats.get('invalid_frames', 0)} / {stats.get('partial_frames', 0)}",
                 f"收 / 发字节      {stats.get('rx_bytes', 0):,} / {stats.get('tx_bytes', 0):,}",
                 f"板端接收错误      {self.last_status.uart_errors if self.last_status else '—'}",
                 "", "端口信息"]
        lines.extend(f"{p['port']}  ·  {p['description']}" for p in getattr(self, "port_infos", []))
        self.diagnostic_text.configure(state="normal")
        self.diagnostic_text.delete("1.0", "end")
        self.diagnostic_text.insert("1.0", "\n".join(lines))
        self.diagnostic_text.configure(state="disabled")

    def export_diagnostics(self):
        target = filedialog.asksaveasfilename(title="导出诊断报告", defaultextension=".json", filetypes=(("JSON", "*.json"),),
                                             initialfile=f"应急系统_诊断_{datetime.now():%Y%m%d_%H%M%S}.json")
        if not target: return
        try:
            Path(target).write_text(json.dumps(self.diagnostics(), ensure_ascii=False, indent=2), encoding="utf-8")
            self.log("INFO", "通信诊断报告已导出")
        except OSError as exc:
            messagebox.showerror("导出失败", str(exc))

    def refresh_ports(self):
        try:
            ports = self.serial.list_ports()
            self.port_infos = self.serial.port_details()
        except Exception as exc:
            self.log("ERROR", f"端口枚举失败：{exc}")
            return
        self.port_combo["values"] = ports
        if not self.want_connection and ports and self.port_var.get() not in ports:
            self.port_var.set(ports[0])
        if not ports and not self.want_connection:
            self.port_var.set("")

    def toggle_connection(self):
        if self.serial.connected or self.connecting or self.want_connection:
            self.want_connection = False
            self.generation += 1
            self.polling = False
            self.connecting = False
            self.serial.close()
            if self._opening_client: self._opening_client.close()
            self.show_unavailable("设备已断开")
            self.connection_label.configure(text="● 未连接", fg=MUTED)
            self.connect_button.configure(text="连接 A 板")
            self.log("INFO", "已断开 A 板串口")
            self.port_combo.configure(state="readonly")
            return
        if not self.port_var.get():
            messagebox.showwarning("应急系统", "没有发现串口，请连接 A 板后刷新端口。")
            return
        self.want_connection = True
        self.connection_port = self.port_var.get()
        self.connection_hwid = next((p["hwid"] for p in getattr(self, "port_infos", []) if p["port"] == self.connection_port), "")
        self.start_connection()

    def start_connection(self):
        self.generation += 1
        generation, port = self.generation, self.connection_port
        self.polling = False
        self.connecting = True
        self.serial.close()
        client = EmergencySerial(on_error=lambda message: self.events.put(("error", (generation, message))))
        self._opening_client = client
        self.port_combo.configure(state="disabled")
        self.connect_button.configure(text="停止连接")
        self.connection_label.configure(text=f"● 正在连接 {port}", fg=YELLOW)
        def connect():
            try:
                client.open(port, 115200)
                error = None
            except Exception as exc:
                error = str(exc)
            if self.closing.is_set() or generation != self.generation:
                client.close()
            else:
                self.events.put(("opened", (generation, client, error)))
        threading.Thread(target=connect, daemon=True, name="应急系统连接").start()

    def finish_connection(self, generation, client, error):
        if generation != self.generation:
            client.close()
            return
        self.connecting = False
        self._opening_client = None
        if error:
            client.close()
            self.connection_failures += 1
            if self.connection_failures == 1 or self.connection_failures % 10 == 0:
                self.log("ERROR", f"连接 {self.connection_port} 失败：{error}")
            self.show_unavailable("连接失败，请检查端口、驱动或占用情况")
            self._next_reconnect = time.monotonic() + 3
            if not self.auto_reconnect.get(): self.want_connection = False
            return
        self.serial = client
        self.connection_failures = 0
        self.response_timeouts = 0
        self.last_status = None
        self.chart.samples.clear()
        self.chart.redraw()
        self.show_unavailable("串口已打开，等待有效数据")
        self.connection_label.configure(text=f"● 等待数据 {self.connection_port}", fg=YELLOW)
        self.save_settings()
        self.connect_button.configure(text="断开连接")
        self.log("INFO", f"串口已打开：{self.connection_port} @ 115200，等待 A 板状态")
        self.request_status(silent=True)

    def poll_once(self):
        if self.serial.connected:
            self.request_status(silent=True)
        if not self.closing.is_set(): self.after(POLL_OPTIONS[self.poll_interval.get()], self.poll_once)

    def poll_worker(self, generation, client):
        try:
            status = client.poll_status()
            if status is not None:
                self.events.put(("status", (generation, status)))
            else:
                self.events.put(("timeout", generation))
        except Exception as exc:
            self.events.put(("error", (generation, f"读取状态失败：{exc}")))
        finally:
            self.events.put(("poll_done", generation))

    def request_status(self, silent=False):
        if self.serial.connected and not self.polling:
            self.polling = True
            threading.Thread(target=self.poll_worker, args=(self.generation, self.serial), daemon=True).start()
        elif not self.serial.connected and not silent:
            self.log("WARN", "读取状态前请先连接 A 板")

    def _enqueue_error(self, message):
        self.events.put(("error", (self.generation, message)))

    def drain_events(self):
        try:
            for _ in range(100):
                kind, payload = self.events.get_nowait()
                if kind == "status":
                    generation, status = payload
                    if generation == self.generation and self.serial.connected: self.update_status(status)
                elif kind == "poll_done":
                    if payload == self.generation: self.polling = False
                elif kind == "opened":
                    self.finish_connection(*payload)
                elif kind == "timeout":
                    if payload == self.generation and self.serial.connected:
                        self.response_timeouts += 1
                        if self.response_timeouts == 1:
                            self.log("WARN", "未收到有效状态，请确认 UART 固件、端口和接线")
                        self.show_unavailable(f"响应超时 {self.response_timeouts} 次，请检查 UART 固件和接线")
                elif kind == "error":
                    generation, message = payload
                    if generation == self.generation: self.log("ERROR", message)
        except queue.Empty:
            pass
        now = time.monotonic()
        if not self.serial.connected and not self.connecting:
            if not self.stale: self.show_unavailable("串口已断开")
            if self.want_connection and self.auto_reconnect.get():
                self.connect_button.configure(text="停止重连")
                self.connection_label.configure(text=f"● 等待重连 {self.connection_port}", fg=YELLOW)
                if now >= self._next_reconnect:
                    self._next_reconnect = now + 3
                    # Never silently switch to another available device.
                    self.refresh_ports()
                    matches = [p for p in self.port_infos if p["port"] == self.connection_port]
                    if matches and (not self.connection_hwid or matches[0]["hwid"] == self.connection_hwid):
                        self.start_connection()
            else:
                self.want_connection = False
                self.connect_button.configure(text="连接 A 板")
                self.port_combo.configure(state="readonly")
                self.connection_label.configure(text="● 未连接", fg=MUTED)
        elif self.last_status and now - self._last_valid > max(3, POLL_OPTIONS[self.poll_interval.get()] / 1000 + 1.5):
            if not self.stale: self.show_unavailable("数据已过期，请检查连接")
        if now - self._clock_refresh >= 1:
            self._clock_refresh = now
            self.clock_label.configure(text=datetime.now().strftime("%Y.%m.%d   %H:%M:%S"))
            if self.notebook.index("current") == 1 and self._history_dirty: self.refresh_history()
            if self.notebook.index("current") == 2: self.refresh_diagnostics()
        if not self.closing.is_set(): self.after(100, self.drain_events)

    def show_unavailable(self, reason):
        self.stale = True
        self.alarm_value.configure(text="等待有效数据", fg=MUTED)
        self.alarm_detail.configure(text=reason, fg=MUTED)
        self.alarm_bar.configure(bg=LINE)
        self.light_gauge.set_value(None, "无实时数据")
        self.sound_gauge.set_value(None, "无实时数据")
        self.footer_label.configure(text=reason, fg=YELLOW)
        self.snapshot_text.configure(state="normal")
        self.snapshot_text.delete("1.0", "end")
        self.snapshot_text.insert("1.0", "暂无有效设备快照\n" + reason)
        self.snapshot_text.configure(state="disabled")
        if self.serial.connected: self.connection_label.configure(text="● 等待数据", fg=YELLOW)

    def update_status(self, status: BoardStatus):
        previous = self.last_status
        was_stale = self.stale
        self.last_status = status
        self.history.append(status)
        self.history = self.history[-600:]
        self.stale = False
        self._last_valid = time.monotonic()
        self.response_timeouts = 0
        self._history_dirty = True
        self.connection_label.configure(text=f"● 在线 {self.connection_port or self.port_var.get()}", fg=GREEN)
        self.footer_label.configure(text=f"实时监测  ·  协议 v{status.protocol}  ·  最近更新 {datetime.fromtimestamp(status.received_at):%H:%M:%S}", fg=MUTED)
        self.total_samples += 1
        row = self.make_row(status)
        self.csv_rows.append(row)
        self.sample_label.configure(text=f"累计 {self.total_samples:,} 条 · 缓存 {len(self.csv_rows):,} 条 · {1000 / POLL_OPTIONS[self.poll_interval.get()]:g} Hz")
        if self._record_writer:
            try:
                self._record_writer.writerow(row)
                self._record_handle.flush()
            except OSError as exc:
                self.stop_recording()
                self.log("ERROR", f"记录文件写入失败：{exc}")
        self.light_gauge.set_value(status.light_raw if status.light_online else None,
                                   "传感器在线 · 原始值 0–65535" if status.light_online else "光照传感器离线")
        self.sound_gauge.set_value(status.sound_level, "ADC 峰峰值 0–4095 · 非分贝")
        if status.collision_alarm:
            title, detail, color = "车辆碰撞报警", "A 板已进入碰撞提示场景", RED
        elif status.sound_alarm:
            title, detail, color = "声音超阈值", f"声音幅度 {status.sound_level}，已进入声音提示场景", YELLOW
        elif not status.light_online:
            title, detail, color = "光照传感器离线", "声音仍在监测，请检查光照传感器连接", YELLOW
        elif status.error_code:
            title, detail, color = "设备状态异常", f"A 板错误码 0x{status.error_code:02X}，请查看设备快照", YELLOW
        elif status.dark:
            title, detail, color = "环境光照不足", "光照传感器在线，系统正在提高画面亮度", CYAN
        else:
            title, detail, color = "系统正常", "A 板当前无碰撞或声音报警", GREEN
        self.alarm_value.configure(text=title, fg=color)
        self.alarm_detail.configure(text=detail, fg=color if status.collision_alarm or status.sound_alarm else MUTED)
        self.alarm_bar.configure(bg=color)
        if not self.chart_paused:
            if was_stale: self.chart.samples.clear()
            self.chart.append(status.light_raw if status.light_online else None, status.sound_level, status.received_at)
        self.write_snapshot(status)
        for attr, label in (("collision_alarm", "车辆碰撞报警"), ("sound_alarm", "声音阈值报警"),
                            ("dark", "环境光照不足"), ("light_online", "光照传感器在线")):
            active = getattr(status, attr)
            if (previous and active != getattr(previous, attr)) or (previous is None and (active or attr == "light_online")):
                level = "ALARM" if active and "alarm" in attr else "WARN" if attr == "light_online" and not active else "INFO"
                self.log(level, f"{label}：{'是' if active else '否'}")
                if active and "alarm" in attr and self.sound_notify.get() and time.monotonic() - self._last_alarm_beep > 1:
                    self._last_alarm_beep = time.monotonic()
                    self.bell()
        if status.error_code and (not previous or status.error_code != previous.error_code):
            self.log("WARN", f"A 板错误码 0x{status.error_code:02X}")

    @staticmethod
    def make_row(status):
        return {"时间": datetime.fromtimestamp(status.received_at).isoformat(timespec="milliseconds"),
                "光照原始值": status.light_raw, "光照在线": int(status.light_online),
                "声音幅度": status.sound_level, "光照不足": int(status.dark),
                "声音报警": int(status.sound_alarm), "碰撞报警": int(status.collision_alarm),
                "画面": status.picture + 1, "显示就绪": int(status.display_ready),
                "状态码": status.state_code, "错误码": status.error_code, "亮度": status.brightness,
                "UART错误": status.uart_errors, "协议版本": status.protocol}

    def write_snapshot(self, status):
        lines = [f"光照原始值     {status.light_raw:>5}   在线：{'是' if status.light_online else '否'}",
                 f"声音幅度       {status.sound_level:>5}   高阈值：700",
                 f"光照不足       {'是' if status.dark else '否'}",
                 f"当前画面       PIC{status.picture + 1}    显示：{'就绪' if status.display_ready else '启动中'}",
                 f"状态码         0x{status.state_code:02X}   错误码：0x{status.error_code:02X}",
                 f"亮度偏移       {status.brightness:>5}   音量：{status.volume}",
                 f"UART 错误      {status.uart_errors}   协议：v{status.protocol}",
                 f"最后更新       {datetime.fromtimestamp(status.received_at):%H:%M:%S}"]
        self.snapshot_text.configure(state="normal")
        self.snapshot_text.delete("1.0", "end")
        self.snapshot_text.insert("1.0", chr(10).join(lines))
        self.snapshot_text.configure(state="disabled")

    def toggle_chart(self):
        self.chart_paused = not self.chart_paused
        self.pause_button.configure(text="继续曲线" if self.chart_paused else "暂停曲线")
        if not self.chart_paused:
            self.chart.samples.clear()
            self.chart.redraw()
        self.log("INFO", "曲线已暂停，报警监测和记录继续" if self.chart_paused else "曲线已继续")

    def toggle_recording(self):
        if self._record_handle:
            self.stop_recording()
            return
        target = filedialog.asksaveasfilename(title="记录实时数据", defaultextension=".csv",
            filetypes=(("CSV 文件", "*.csv"),), initialfile=f"应急系统_连续记录_{datetime.now():%Y%m%d_%H%M%S}.csv")
        if not target: return
        try:
            handle = open(target, "w", newline="", encoding="utf-8-sig")
            writer = csv.DictWriter(handle, fieldnames=list(self.make_row(BoardStatus(received_at=time.time()))))
            writer.writeheader()
            handle.flush()
        except OSError as exc:
            if 'handle' in locals(): handle.close()
            messagebox.showerror("记录失败", str(exc))
            return
        self._record_handle, self._record_writer = handle, writer
        self.record_button.configure(text="停止记录 ●")
        self.log("INFO", f"开始记录：{Path(target).name}")

    def stop_recording(self):
        if self._record_handle:
            try: self._record_handle.close()
            except OSError: pass
        self._record_handle = self._record_writer = None
        self.record_button.configure(text="开始记录 CSV")
        self.log("INFO", "实时文件记录已停止")

    def export_events(self):
        if not self.event_rows: return
        target = filedialog.asksaveasfilename(title="导出事件日志", defaultextension=".csv",
            filetypes=(("CSV 文件", "*.csv"),), initialfile=f"应急系统_事件_{datetime.now():%Y%m%d_%H%M%S}.csv")
        if not target: return
        try:
            with open(target, "w", newline="", encoding="utf-8-sig") as handle:
                writer = csv.writer(handle)
                writer.writerow(("时间", "级别", "信息"))
                writer.writerows(self.event_rows)
        except OSError as exc:
            messagebox.showerror("导出失败", str(exc))
            return
        self.log("INFO", f"事件日志已导出：{Path(target).name}")

    def log(self, level, message):
        self.event_rows.append((datetime.now().isoformat(timespec="seconds"), level, message))
        self.event_tree.insert("", 0, values=(datetime.now().strftime("%H:%M:%S"), level, message), tags=(level,))
        items = self.event_tree.get_children()
        if len(items) > 100:
            self.event_tree.delete(items[-1])

    def clear_events(self):
        self.event_rows.clear()
        for item in self.event_tree.get_children():
            self.event_tree.delete(item)

    def export_csv(self):
        if not self.csv_rows:
            messagebox.showinfo("应急系统", "还没有可导出的采样数据。")
            return
        target = filedialog.asksaveasfilename(title="导出监测记录", defaultextension=".csv",
                                              filetypes=(("CSV 文件", "*.csv"), ("所有文件", "*.*")),
                                              initialfile=f"应急系统_{datetime.now():%Y%m%d_%H%M%S}.csv")
        if not target:
            return
        try:
            with open(target, "w", newline="", encoding="utf-8-sig") as handle:
                writer = csv.DictWriter(handle, fieldnames=list(self.csv_rows[0]))
                writer.writeheader()
                writer.writerows(self.csv_rows)
        except OSError as exc:
            messagebox.showerror("导出失败", str(exc))
            return
        self.log("INFO", f"监测记录已导出：{Path(target).name}")

    def on_close(self):
        self.closing.set()
        self.want_connection = False
        self.generation += 1
        self.stop_recording()
        self.serial.close()
        if self._opening_client: self._opening_client.close()
        for identifier in self.tk.splitlist(self.tk.call("after", "info")):
            self.after_cancel(identifier)
        self.destroy()


if __name__ == "__main__":
    # Keep Windows from stretching the UI bitmap on high-DPI displays.
    try:
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (AttributeError, OSError):
        pass
    EmergencySystem().mainloop()
