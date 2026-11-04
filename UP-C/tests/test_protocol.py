"""Isolated synthetic protocol tests; never open a physical COM port."""
import sys
from pathlib import Path
import threading
import unittest
from unittest.mock import patch
import queue
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from serial_protocol import BoardStatus, EmergencySerial, _Pending, crc8


def payload():
    data = bytearray(b"BA\x02\xF1" + bytes(12))
    data[4:6] = (50000).to_bytes(2, "little")
    data[6:8] = (1800).to_bytes(2, "little")
    data[8:14] = bytes((8, 0xA5, 9, 0x41, 2, 0x43))
    data[14:16] = (-22).to_bytes(2, "little", signed=True)
    return bytes(data)


def frame(sequence=7, data=None, command=0x82):
    body = b"\0" + (payload() if data is None else data) + b"\x34\x12"
    packet = bytes((0xA5, 0x5A, len(body), sequence, command)) + body
    return packet + bytes((crc8(packet[2:]),))


class FakePort:
    """Synthetic fragmented endpoint used only by this test module."""
    def __init__(self, **kwargs):
        self.is_open = True
        self.queue = queue.Queue()
    def reset_input_buffer(self): pass
    def cancel_read(self): self.queue.put(b"")
    def close(self): self.is_open = False
    def read(self, count):
        try: return self.queue.get(timeout=.02)
        except queue.Empty: return b""
    def write(self, data):
        assert data[0:3] == b"\xa5\x5a\0" and data[4] == 2 and crc8(data[2:-1]) == data[-1]
        for byte in frame(data[3]): self.queue.put(bytes((byte,)))
        return len(data)


class ProtocolTests(unittest.TestCase):
    def test_write_failure_closes_connection_and_releases_waiter(self):
        class BrokenPort(FakePort):
            def write(self, data): raise OSError("synthetic unplug")
        errors = []
        client = EmergencySerial(on_error=errors.append)
        with patch("serial_protocol.serial.Serial", BrokenPort):
            client.open("SYNTHETIC_TEST_ONLY")
            self.assertIsNone(client.poll_status())
            self.assertFalse(client.connected)
            self.assertFalse(client._pending)
            self.assertEqual(len(errors), 1)
            client.close()

    def test_truncated_legacy_header_recovers_after_byte_gap(self):
        class PartialPort(FakePort):
            def write(self, data):
                self.queue.put(b"\xa5\x5a\x30\x99\x82" + frame(data[3]))
                return len(data)
        client = EmergencySerial()
        with patch("serial_protocol.serial.Serial", PartialPort):
            try:
                client.open("SYNTHETIC_TEST_ONLY")
                self.assertEqual(client.poll_status().light_raw, 50000)
                self.assertEqual(client.statistics["partial_frames"], 1)
            finally: client.close()

    def test_obsolete_session_cannot_match_current_request(self):
        client, pending = self.client()
        client._session = 4
        pending.session = 4
        client._parse_frames(bytearray(frame()), session=3)
        self.assertFalse(pending.event.is_set())
        client._release_pending(session=3)
        self.assertFalse(pending.event.is_set())
        client._parse_frames(bytearray(frame()), session=4)
        self.assertTrue(pending.event.is_set())

    def test_close_during_request_then_reopen(self):
        class QuietPort(FakePort):
            def write(self, data): return len(data)
        client = EmergencySerial()
        with patch("serial_protocol.serial.Serial", QuietPort):
            client.open("SYNTHETIC_TEST_ONLY")
            result = []
            worker = threading.Thread(target=lambda: result.append(client.poll_status()))
            worker.start()
            deadline = time.monotonic() + 1
            while not client._pending and time.monotonic() < deadline: time.sleep(.001)
            client.close()
            worker.join(1)
            self.assertFalse(worker.is_alive())
            self.assertEqual(result, [None])
        with patch("serial_protocol.serial.Serial", FakePort):
            try:
                client.open("SYNTHETIC_TEST_ONLY")
                self.assertEqual(client.poll_status().light_raw, 50000)
                self.assertEqual(client.statistics["samples"], 1)
            finally: client.close()

    def test_status_timeout_has_diagnostic_counter(self):
        class QuietPort(FakePort):
            def write(self, data): return len(data)
        client = EmergencySerial()
        with patch("serial_protocol.serial.Serial", QuietPort):
            try:
                client.open("SYNTHETIC_TEST_ONLY")
                self.assertIsNone(client.request(timeout=.01))
                self.assertEqual(client.statistics["timeouts"], 1)
                self.assertFalse(client._pending)
            finally: client.close()

    def client(self):
        client = EmergencySerial()
        pending = _Pending(7, threading.Event())
        client._pending[7] = pending
        return client, pending

    def test_crc_known_vector(self):
        self.assertEqual(crc8(b"123456789"), 0xF4)

    def test_v2_real_ranges_and_flags(self):
        status = BoardStatus.from_response(0, payload(), 4660)
        self.assertEqual((status.light_raw, status.sound_level, status.brightness), (50000, 1800, -22))
        self.assertTrue(status.sound_alarm and status.light_online and status.dark)
        self.assertFalse(status.collision_alarm)
        self.assertEqual((status.picture, status.switches, status.modes, status.volume, status.interval), (8, 5, 10, 4, 3))

    def test_alarm_source_matches_board_priority(self):
        data = bytearray(payload())
        for flags, sound, collision in ((0x30, True, False), (0x10, False, True), (0x00, False, False)):
            data[3] = flags
            status = BoardStatus.from_response(0, data, 0)
            self.assertEqual((status.sound_alarm, status.collision_alarm), (sound, collision))

    def test_every_serial_fragment_boundary(self):
        packet = frame()
        for split in range(len(packet)+1):
            client, pending = self.client()
            for part in (packet[:split], packet[split:]):
                client._rx.extend(part); client._parse_frames()
            self.assertTrue(pending.event.is_set(), f"split={split}")
            self.assertEqual(pending.response, (0, payload(), 4660))

    def test_noise_crc_resync_and_command(self):
        client, pending = self.client()
        bad = bytearray(frame()); bad[-1] ^= 0x55
        client._rx.extend(b"noise\xa5\0\xa5\x5a\xff" + bytes(bad) + frame(command=0x90))
        client._parse_frames()
        self.assertFalse(pending.event.is_set())
        client._rx.extend(frame()); client._parse_frames()
        self.assertTrue(pending.event.is_set())

    def test_wrong_sequence_is_not_matched(self):
        client, pending = self.client()
        client._rx.extend(frame(sequence=8)); client._parse_frames()
        self.assertFalse(pending.event.is_set())

    def test_legacy_resolution_and_ninth_image(self):
        data = bytearray(45); data[:3] = b"BA\1"
        data[32:37] = int("0102400768", 16).to_bytes(5, "little")
        data[37] = 7
        s = BoardStatus.from_response(0, data, 0)
        self.assertEqual((s.active_width, s.active_height), (1024, 768))
        self.assertEqual((s.ready_images, s.available_images, s.failed_images), (256, 256, 256))

    def test_incompatible_status_rejected(self):
        for result, data in ((1, payload()), (0, b"XX" + payload()[2:]), (0, b"BA\x03" + payload()[3:])):
            with self.assertRaises(ValueError): BoardStatus.from_response(result, data, 0)

    def test_threaded_roundtrip_and_reconnect(self):
        with patch("serial_protocol.serial.Serial", FakePort):
            client = EmergencySerial()
            for _ in range(2):
                client.open("SYNTHETIC_TEST_ONLY")
                self.assertTrue(client.connected)
                self.assertEqual(client.poll_status().light_raw, 50000)
                client.close()
                self.assertFalse(client.connected)
            self.assertIsNone(client.request())

    def test_close_releases_waiters(self):
        client, pending = self.client()
        client.close()
        self.assertTrue(pending.event.is_set())


if __name__ == "__main__": unittest.main()
