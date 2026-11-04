"""Reproduce native XGA RGB332 display and control/audio/link regressions.

Each run has its own logs/runtime; no prior validation data is overwritten.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
import hashlib
import json
import re
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
ROOT = PROJECT.parent
HDL = PROJECT / "src/user_source/hdl_source"
TESTS = ['tb_alarm_glow', 'tb_ui_controls', 'tb_sensor_policy', 'tb_sensor_return', 'tb_rgb332_top', 'tb_control', 'tb_end_to_end', 'tb_directory_animation', 'tb_rgb332_timing', 'tb_rgb332_sw4_audio', 'tb_rgb332_preview_cdc', 'tb_audio_selection', 'tb_alarm_audio', 'tb_boot_overlay', 'tb_controls', 'tb_media_catalog', 'tb_storage_media', 'tb_uart_remote', 'tb_uart_telemetry', 'tb_rgb332_adc', 'tb_rgb332_serializer', 'tb_rgb332_hdmi_phy']
LINK_TESTS = {"tb_control", "tb_end_to_end"}


def run_test(name, output):
    work = output / name / "runtime"
    work.mkdir(parents=True)
    (work.parent / "doc/validation").mkdir(parents=True)
    source = (PROJECT / "sim/link" if name in LINK_TESTS else PROJECT / "sim") / (name + ".v")
    if name in ("tb_layout576", "tb_layout576_ui"):
        source = HERE / (name + ".v")
    binary = work / (name + ".vvp")
    command = ["iverilog", "-g2012", "-DSIMULATION", "-s", name,
               "-y", str(HDL), "-y", str(HDL / "extension"), "-y", str(HDL / "SD"),
               "-y", str(HDL / "extension"),
               "-I", str(HDL / "SD"), "-I", str(HDL / "include"),
               "-o", str(binary), str(source)]
    command += [str(HDL / relative) for relative in (
        "extension/player_xga.v", "extension/player_control.v", "extension/player_video.v", "extension/thumbnail_video.v",
        "SD/frame_read_write.v", "SD/color_bar.v", "video_rgb_to_axis_640x480.v",
        "IP/afifo_16_32_256.v", "IP/afifo_32_16_256.v")]
    command.append(str(PROJECT / "sim/eg_bram32k_model.v"))
    if name == "tb_hdmi576_line_memory":
        command.append(str(HDL / "extension/bmp_bilinear.v"))
    if name == "tb_no_signal":
        command.append(str(PROJECT / "doc/validation/no_signal_20261027/player_ui_overlay_before.v"))
    if name in ("tb_hdmi576_adc", "tb_microphone_adc", "tb_xga9_adc", "tb_rgb332_adc"):
        command.append(str(PROJECT / "sim/adc_boundary_model.v"))
    if name in ("tb_xga9_top", "tb_xga9_sw4_audio", "tb_xga9_preview_cdc", "tb_xga9_pipeline", "tb_rgb332_top", "tb_rgb332_sw4_audio", "tb_rgb332_preview_cdc", "tb_rgb332_pipeline"):
        command += [str(HDL / "top_tf_hdmi_audio.v"), str(PROJECT / ("sim/rgb332_vendor_model.v" if name.startswith("tb_rgb332") else "sim/xga9_vendor_model.v")),
                    str(PROJECT / "sim/adc_boundary_model.v")]
    if name=="tb_nine_bank": command.append(str(PROJECT/"sim/tb_storage_flow.v"))
    if name in ("tb_hotplug", "tb_storage_media", "tb_storage_reset_glitch", "tb_preview_failure", "tb_cache_audio"):
        command.append(str(PROJECT/"sim/tb_storage.v"))
    if name in ("tb_rgb332_serializer", "tb_rgb332_hdmi_phy"):
        vendor = Path("D:/software/anlogic_TD/sim_release/eg4/eg_logic_io.v").read_text()
        public_oddr = "module EG_LOGIC_ODDR" + vendor.split("module EG_LOGIC_ODDR",1)[1].split("endmodule",1)[0] + "endmodule"
        model = work / "vendor_oddr.v"
        model.write_text("\x60timescale 1ns/1ps\n" + public_oddr)
        command[1:1] = ["-s", "glbl"]
        command += [str(HDL / "lane_lvds_10_1.v"), str(model)]
        if name == "tb_rgb332_hdmi_phy":
            command.append(str(HDL / "hdmi_phy_warpper.v"))
    if name == "tb_rgb332_top":
        command[1:1] = ["-s", "top_sensor_binding_check"]
        command.append(str(PROJECT / "sim/top_sensor_binding_check.v"))
    started = time.monotonic()
    compile_result = subprocess.run(command, cwd=work, capture_output=True, text=True,
                                    errors="replace", timeout=120)
    (work.parent / "compile.log").write_text(compile_result.stdout + compile_result.stderr, encoding="utf-8")
    passed = False
    log = ""
    if compile_result.returncode == 0:
        try:
            result = subprocess.run(["vvp", str(binary)], cwd=work, capture_output=True,
                                    text=True, errors="replace", timeout=1200)
            log = result.stdout + result.stderr
            passed = result.returncode == 0 and "PASS" in log and not re.search(r"(?m)^(FATAL|ERROR|FAIL):", log)
        except subprocess.TimeoutExpired as exc:
            log = "TIMEOUT\n" + str(exc.stdout) + str(exc.stderr)
    (work.parent / "simulation.log").write_text(log, encoding="utf-8")
    row = {"test": name, "test_source_sha256": hashlib.sha256(source.read_bytes()).hexdigest() if source.is_file() else None, "passed": passed, "seconds": round(time.monotonic()-started, 2),
           "compile_command": command, "directory": str(work.parent)}
    print(("PASS " if passed else "FAIL ") + name + " " + str(row["seconds"]) + "s", flush=True)
    if not passed:
        print((compile_result.stdout + compile_result.stderr if compile_result.returncode else log)[-3000:], flush=True)
    return row


def main():
    names=sys.argv[1:] or TESTS
    output=PROJECT/'doc/validation'/('checks_'+datetime.now().strftime('%Y%m%d_%H%M%S'))
    output.mkdir(parents=True)
    sources = {str(p.relative_to(PROJECT)): hashlib.sha256(p.read_bytes()).hexdigest()
               for p in sorted((PROJECT / "src/user_source").rglob("*")) if p.is_file()}
    (output / "source_hashes.json").write_text(json.dumps(sources, indent=2))
    results=[]
    with ThreadPoolExecutor(max_workers=3) as pool:
        for f in as_completed([pool.submit(run_test,n,output) for n in names]):
            results.append(f.result())
            (output/'results.json').write_text(json.dumps(results,indent=2))
    raise SystemExit(0 if all(r['passed'] for r in results) else 1)
if __name__=='__main__': main()
