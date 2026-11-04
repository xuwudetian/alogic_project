"""应急系统与 A 板之间的 UART 协议。

帧格式：A5 5A LEN SEQ CMD PAYLOAD CRC8，CRC8 多项式 0x07，
覆盖 LEN、SEQ、CMD 和 PAYLOAD。A 板返回 19 字节数据：
RESULT + 16 字节 v2 状态 + 16 位接收错误计数；兼容早期 v1 状态帧。
"""

from __future__ import annotations

from dataclasses import dataclass
from collections import Counter
import threading
import time
from typing import Callable, Optional

try:
    import serial
    from serial import SerialException
except ImportError:  # pragma: no cover - 给没有安装 pyserial 的开发机保留清晰错误
    serial = None
    SerialException = Exception


def crc8(data: bytes) -> int:
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ 0x07) & 0xFF if value & 0x80 else (value << 1) & 0xFF
    return value


@dataclass
class BoardStatus:
    result: int = 0
    protocol: int = 0
    magic: str = "--"
    dark: bool = False
    light_online: bool = False
    sound_alarm: bool = False
    collision_alarm: bool = False
    status_panel: bool = False
    directory: bool = False
    browse: bool = False
    display_ready: bool = False
    picture: int = 0
    focus: int = 0
    menu: int = 0
    directory_focus: int = 0
    run_mode: int = 2
    transition: int = 0
    volume: int = 4
    interval: int = 3
    manual_brightness: int = 0
    contrast: int = 128
    brightness: int = 0
    modes: int = 0
    switches: int = 0
    remote_switch_mask: int = 0
    remote_switch_value: int = 0
    available_images: int = 0
    ready_images: int = 0
    failed_images: int = 0
    error_code: int = 0
    state_code: int = 0
    audio_status: int = 0
    light_raw: int = 0
    sound_level: int = 0
    active_width: int = 0
    active_height: int = 0
    high_bits: int = 0
    uart_errors: int = 0
    received_at: float = 0.0

    @classmethod
    def from_response(cls, result: int, status: bytes, uart_errors: int) -> "BoardStatus":
        if result != 0:
            raise ValueError(f"设备返回错误码：{result}")
        if len(status) not in (16, 45) or status[:2] != b"BA":
            raise ValueError("状态长度或设备标识不匹配")
        if status[2] == 2 and len(status) == 16:
            flags = status[3]
            return cls(
                result=result, protocol=2, magic="BA",
                dark=bool(flags & 0x80), light_online=bool(flags & 0x40),
                sound_alarm=bool(flags & 0x20), collision_alarm=bool(flags & 0x10) and not bool(flags & 0x20),
                status_panel=bool(flags & 8), directory=bool(flags & 4),
                browse=bool(flags & 2), display_ready=bool(flags & 1),
                light_raw=int.from_bytes(status[4:6], "little"),
                sound_level=int.from_bytes(status[6:8], "little") & 0xFFF,
                picture=status[8] & 0xF, modes=status[9] >> 4,
                switches=status[9] & 0xF, state_code=status[10], error_code=status[11],
                audio_status=status[12], volume=status[13] >> 4, interval=status[13] & 0xF,
                brightness=int.from_bytes(status[14:16], "little", signed=True),
                uart_errors=uart_errors, received_at=time.time())
        if status[2] != 1 or len(status) != 45:
            raise ValueError(f"不支持的协议版本：{status[2]}")
        flags = status[3]
        # active_resolution 是 5 个 BCD 字节，宽度/高度分别占 20 bit。
        resolution = int.from_bytes(status[32:37], "little")
        width = sum(((resolution >> (20 + index * 4)) & 0xF) * 10 ** index for index in range(5))
        height = sum(((resolution >> (index * 4)) & 0xF) * 10 ** index for index in range(5))
        magic_value = int.from_bytes(status[0:3], "little")
        magic = chr(magic_value & 0xFF) + chr((magic_value >> 8) & 0xFF)
        return cls(
            result=result,
            protocol=(magic_value >> 16) & 0xFF,
            magic=magic,
            dark=bool(flags & 0x80),
            light_online=bool(flags & 0x40),
            sound_alarm=bool(flags & 0x20),
            collision_alarm=bool(flags & 0x10) and not bool(flags & 0x20),
            status_panel=bool(flags & 0x08),
            directory=bool(flags & 0x04),
            browse=bool(flags & 0x02),
            display_ready=bool(flags & 0x01),
            picture=status[4] & 0x0F,
            focus=status[5] & 0x0F,
            menu=status[6] & 0x07,
            directory_focus=status[7] & 0x03,
            run_mode=status[8] & 0x03,
            transition=status[9] & 0x0F,
            volume=status[10] & 0x0F,
            interval=status[11] & 0x0F,
            manual_brightness=int.from_bytes(status[12:14], "little", signed=True),
            contrast=int.from_bytes(status[14:16], "little"),
            brightness=int.from_bytes(status[16:18], "little", signed=True),
            modes=status[18] & 0x0F,
            switches=status[19] & 0x0F,
            remote_switch_mask=status[20] & 0x0F,
            remote_switch_value=status[21] & 0x0F,
            available_images=status[22] | ((status[37] & 0x01) << 8),
            ready_images=status[23] | ((status[37] & 0x02) << 7),
            failed_images=status[24] | ((status[37] & 0x04) << 6),
            error_code=status[25],
            state_code=status[26] & 0x0F,
            audio_status=status[27],
            light_raw=int.from_bytes(status[28:30], "little"),
            sound_level=int.from_bytes(status[30:32], "little") & 0x0FFF,
            active_width=width,
            active_height=height,
            high_bits=status[37],
            uart_errors=uart_errors,
            received_at=time.time(),
        )


@dataclass
class _Pending:
    sequence: int
    event: threading.Event
    response: Optional[tuple[int, bytes, int]] = None
    session: int = 0


class EmergencySerial:
    """线程安全的 UART 客户端，负责收发、校验和请求匹配。"""

    def __init__(self, on_status: Optional[Callable[[BoardStatus], None]] = None,
                 on_error: Optional[Callable[[str], None]] = None):
        self.on_status = on_status
        self.on_error = on_error
        self._serial = None
        self._reader: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._pending: dict[int, _Pending] = {}
        self._request_lock = threading.Lock()
        self._sequence = 0
        self._rx = bytearray()
        self.last_status: Optional[BoardStatus] = None
        self._session = 0
        self._stats = Counter()

    @property
    def statistics(self) -> dict:
        with self._lock:
            return dict(self._stats)

    def _count(self, key: str, amount: int = 1):
        with self._lock:
            self._stats[key] += amount

    @property
    def connected(self) -> bool:
        return bool(self._serial and self._serial.is_open and not self._stop.is_set())

    def list_ports(self) -> list[str]:
        if serial is None:
            return []
        from serial.tools import list_ports
        return sorted(port.device for port in list_ports.comports())

    def port_details(self) -> list[dict]:
        if serial is None:
            return []
        from serial.tools import list_ports
        return [{"port": p.device, "description": p.description, "hwid": p.hwid}
                for p in sorted(list_ports.comports(), key=lambda p: p.device)]

    def open(self, port: str, baudrate: int = 115200) -> None:
        if serial is None:
            raise RuntimeError("未安装 pyserial，请先运行：python -m pip install -r requirements.txt")
        self.close()
        self._serial = serial.Serial(port=port, baudrate=baudrate, bytesize=8,
                                     parity=serial.PARITY_NONE, stopbits=1,
                                     timeout=0.05, write_timeout=0.5)
        self._rx.clear()
        self._stats.clear()
        self.last_status = None
        try:
            self._serial.reset_input_buffer()
        except Exception:
            self.close()
            raise
        self._stop = threading.Event()
        self._reader = threading.Thread(target=self._reader_loop, args=(self._serial, self._stop, self._session), name="应急系统串口接收", daemon=True)
        self._reader.start()

    def close(self) -> None:
        self._session += 1
        self._stop.set()
        port = self._serial
        self._serial = None
        if port:
            try:
                port.cancel_read()
            except (AttributeError, OSError):
                pass
            try:
                port.close()
            except Exception:
                pass
        self._release_pending()
        if self._reader and self._reader is not threading.current_thread():
            self._reader.join(timeout=0.6)
        self._reader = None

    def _release_pending(self, session=None):
        with self._lock:
            for sequence, pending in list(self._pending.items()):
                if session is None or pending.session == session:
                    pending.event.set()
                    del self._pending[sequence]

    def request(self, command: int = 0x02, payload: bytes = b"", timeout: float = 1.0):
        if command != 0x02 or payload:
            raise ValueError("A 工程串口仅支持读取状态")
        session = self._session
        with self._request_lock:
            if session != self._session:
                return None
            return self._request(command, payload, timeout)

    def _request(self, command: int, payload: bytes = b"", timeout: float = 1.2) -> Optional[tuple[int, bytes, int]]:
        if not self.connected:
            return None
        port, stop, session = self._serial, self._stop, self._session
        if len(payload) > 3:
            raise ValueError("A 板协议单次最多携带 3 字节参数")
        with self._lock:
            sequence = self._sequence
            self._sequence = (self._sequence + 1) & 0xFF
            pending = _Pending(sequence, threading.Event(), session=session)
            self._pending[sequence] = pending
        frame = bytes((0xA5, 0x5A, len(payload), sequence, command)) + payload
        frame += bytes((crc8(frame[2:]),))
        try:
            if stop.is_set():
                self._release_pending(session)
                return None
            if port.write(frame) != len(frame):
                raise OSError("串口未完整写入请求帧")
            if session == self._session:
                self._count("requests")
                self._count("tx_bytes", len(frame))
        except Exception as exc:
            with self._lock:
                if self._pending.get(sequence) is pending: self._pending.pop(sequence)
            if session == self._session: self._emit_error(f"串口发送失败：{exc}")
            stop.set()
            self._release_pending(session)
            return None
        if not pending.event.wait(timeout):
            with self._lock:
                if self._pending.get(sequence) is pending: self._pending.pop(sequence)
            if session == self._session: self._count("timeouts")
            return None
        return pending.response

    def poll_status(self) -> Optional[BoardStatus]:
        session = self._session
        response = self.request(0x02)
        if not response or session != self._session:
            return None
        result, status, errors = response
        try:
            board_status = BoardStatus.from_response(result, status, errors)
        except ValueError as exc:
            self._emit_error(f"状态解析失败：{exc}")
            return None
        self.last_status = board_status
        self._count("samples")
        if self.on_status:
            self.on_status(board_status)
        return board_status

    def _reader_loop(self, port, stop, session) -> None:
        rx = bytearray()
        last_byte = time.monotonic()
        while not stop.is_set():
            try:
                data = port.read(256)
                if data:
                    if stop.is_set() or session != self._session:
                        return
                    self._count("rx_bytes", len(data))
                    rx.extend(data)
                    last_byte = time.monotonic()
                    self._parse_frames(rx, session)
                elif rx and time.monotonic() - last_byte > .2:
                    # A truncated packet must not trap the next valid response.
                    self._count("partial_frames")
                    del rx[:1]
                    self._parse_frames(rx, session)
                    rx.clear()
            except Exception as exc:
                if not stop.is_set() and session == self._session:
                    stop.set()
                    self._emit_error(f"串口接收失败：{exc}")
                    try:
                        port.close()
                    except Exception:
                        pass
                    self._release_pending()
                return

    def _parse_frames(self, buffer=None, session=None) -> None:
        if session is not None and session != self._session:
            return
        rx = self._rx if buffer is None else buffer
        while True:
            start = rx.find(bytes((0xA5, 0x5A)))
            if start < 0:
                # Keep a split A5/5A header across serial read boundaries.
                rx[:] = b"\xA5" if rx.endswith(b"\xA5") else b""
                return
            if start:
                del rx[:start]
            if len(rx) < 6:
                return
            length = rx[2]
            total = 2 + 1 + 1 + 1 + length + 1
            if length not in (19, 48):
                self._count("invalid_frames")
                del rx[:2]
                continue
            if len(rx) < total:
                return
            frame = bytes(rx[:total])
            if crc8(frame[2:-1]) != frame[-1] or frame[4] != 0x82:
                self._count("invalid_frames")
                del rx[:1]
                continue
            del rx[:total]
            self._count("responses")
            sequence = frame[3]
            payload = frame[5:-1]
            result = payload[0]
            status = payload[1:-2]
            errors = int.from_bytes(payload[-2:], "little")
            with self._lock:
                pending = self._pending.get(sequence)
                if pending and (session is None or pending.session == session == self._session):
                    self._pending.pop(sequence)
                else:
                    pending = None
            if pending:
                pending.response = (result, status, errors)
                pending.event.set()

    def _emit_error(self, message: str) -> None:
        if self.on_error:
            self.on_error(message)
