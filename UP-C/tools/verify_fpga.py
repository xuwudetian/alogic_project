"""Verify the actual A-board TX bits with the production Python decoder.

Requires Icarus Verilog in PATH. Uses isolated simulation output, never a COM port.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import threading

app = Path(__file__).resolve().parents[1]
workspace = app.parent
sys.path.insert(0, str(app))
from serial_protocol import EmergencySerial, BoardStatus, _Pending

source = workspace / "lab_ex_bestA/sim/tb_uart_telemetry.v"
rtl = workspace / "lab_ex_bestA/src/user_source/hdl_source/extension/player_uart_status.v"
with tempfile.TemporaryDirectory(prefix="uart_hdl_verification_") as directory:
    work = Path(directory)
    bench = source.read_text()
    (work / "bench.v").write_text(bench)
    subprocess.run(["iverilog", "-g2012", "-s", "tb_uart_telemetry", "-o", "test.vvp", "bench.v", str(rtl)], cwd=work, check=True)
    subprocess.run(["vvp", "test.vvp"], cwd=work, check=True)
    data = bytes(int(line, 16) for line in (work / "uart_frames.hex").read_text().splitlines()
                 if line.strip() and not line.startswith("//"))
    client = EmergencySerial()
    pending = _Pending(0x17, threading.Event())
    client._pending[0x17] = pending
    # Feed physical UART output in tiny fragments, exactly like a USB serial driver.
    for byte in data[:25]:
        client._rx.append(byte)
        client._parse_frames()
    assert pending.event.is_set(), "Python could not decode the HDL response"
    status = BoardStatus.from_response(*pending.response)
    assert (status.light_raw, status.sound_level, status.brightness, status.uart_errors) == (4660, 2307, -35, 0)
    assert status.protocol == 2 and status.sound_alarm and status.light_online and status.dark
    print("PASS HDL -> Python: physical TX frame, CRC, byte fragmentation, sensor fields, signed brightness")
