"""Isolated synthetic UI smoke test; no physical COM connection or saved readings."""
import sys
from pathlib import Path
import time
import unittest
from unittest.mock import patch
import tempfile
import csv

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from emergency_system import EmergencySystem, BoardStatus
from test_protocol import FakePort


class UiTests(unittest.TestCase):
    def test_history_filters_and_stale_snapshot(self):
        app = EmergencySystem()
        app.withdraw()
        try:
            app.update_status(BoardStatus(protocol=2, light_online=True, received_at=time.time()))
            app.update_status(BoardStatus(protocol=2, sound_alarm=True, received_at=time.time()))
            app.history_filter.set("报警采样")
            app.refresh_history()
            self.assertEqual(len(app.history_tree.get_children()), 1)
            app.history_filter.set("光照离线")
            app.refresh_history()
            self.assertEqual(len(app.history_tree.get_children()), 1)
            app.show_unavailable("synthetic offline")
            self.assertIn("暂无有效设备快照", app.snapshot_text.get("1.0", "end"))
            app.update_status(BoardStatus(light_online=True, received_at=time.time()))
            self.assertEqual(len(app.chart.samples), 1, "Do not draw across an offline gap")
        finally: app.on_close()

    def test_connection_worker_manual_disconnect_and_generation_guard(self):
        app = EmergencySystem()
        app.withdraw()
        try:
            with tempfile.TemporaryDirectory() as directory, patch("serial_protocol.serial.Serial", FakePort):
                app.settings_path = Path(directory) / "settings.json"
                app.port_var.set("SYNTHETIC_TEST_ONLY")
                app.toggle_connection()
                deadline = time.monotonic() + 2
                while app.last_status is None and time.monotonic() < deadline:
                    app.update()
                    time.sleep(.01)
                self.assertIsNotNone(app.last_status)
                self.assertFalse(app.stale)
                app.toggle_connection()
                self.assertFalse(app.want_connection)
                self.assertFalse(app.serial.connected)
                self.assertTrue(app.stale)
                app.polling = True
                app.events.put(("poll_done", app.generation - 1))
                app.drain_events()
                self.assertTrue(app.polling, "Old completion cannot reset a new poll")
        finally: app.on_close()

    def test_reconnect_only_original_device(self):
        app = EmergencySystem()
        app.withdraw()
        try:
            app.want_connection = True
            app.auto_reconnect.set(True)
            app.connection_port, app.connection_hwid = "COM_TEST", "DEVICE_A"
            with patch.object(app.serial, "list_ports", return_value=["COM_TEST"]), patch.object(app.serial, "port_details", return_value=[
                    {"port": "COM_TEST", "hwid": "DEVICE_OTHER", "description": "synthetic"}]), patch.object(app, "start_connection") as start:
                app.drain_events()
                start.assert_not_called()
            app._next_reconnect = 0
            with patch.object(app.serial, "list_ports", return_value=["COM_TEST"]), patch.object(app.serial, "port_details", return_value=[
                    {"port": "COM_TEST", "hwid": "DEVICE_A", "description": "synthetic"}]), patch.object(app, "start_connection") as start:
                app.drain_events()
                start.assert_called_once()
        finally: app.on_close()

    def test_states_ranges_and_exports(self):
        app = EmergencySystem()
        app.withdraw()
        errors = []
        app.report_callback_exception = lambda *args: errors.append(args)
        try:
            now = time.time()
            s = BoardStatus(protocol=2, light_raw=50000, sound_level=1800, light_online=True,
                            sound_alarm=True, collision_alarm=True, received_at=now)
            app.update_status(s)
            self.assertEqual(app.light_gauge.value, 50000)
            self.assertEqual(app.sound_gauge.value, 1800)
            self.assertEqual(app.alarm_value.cget("text"), "车辆碰撞报警")
            s.collision_alarm = False
            app.update_status(s)
            self.assertEqual(app.alarm_value.cget("text"), "声音超阈值")
            app.toggle_chart()
            size = len(app.chart.samples)
            app.update_status(s)
            self.assertEqual(len(app.chart.samples), size)
            app.toggle_chart()
            s.sound_alarm=False; s.light_online=False
            app.update_status(s)
            self.assertIsNone(app.light_gauge.value)
            self.assertEqual(app.alarm_value.cget("text"), "光照传感器离线")
            # Exercise charts containing offline gaps and values above old UI caps.
            for i in range(20): app.chart.append(None if i % 3 == 0 else 50000, 1800, now+i)
            app.show_unavailable("synthetic test disconnected")
            self.assertTrue(app.stale)
            self.assertIsNone(app.sound_gauge.value)
            with tempfile.TemporaryDirectory(prefix="emergency_synthetic_test_") as directory:
                target = str(Path(directory)/"synthetic.csv")
                with patch("emergency_system.filedialog.asksaveasfilename", return_value=target):
                    app.export_csv()
                with open(target, encoding="utf-8-sig") as handle:
                    rows = list(csv.DictReader(handle))
                    self.assertEqual(rows[0]["光照原始值"], "50000")
                with patch("emergency_system.filedialog.asksaveasfilename", return_value=target):
                    app.toggle_recording()
                app.update_status(s)
                app.stop_recording()
                with open(target, encoding="utf-8-sig") as handle:
                    self.assertEqual(len(list(csv.DictReader(handle))), 1)
            app.update_idletasks()
            self.assertFalse(errors, errors)
        finally:
            app.on_close()


if __name__ == "__main__": unittest.main()
