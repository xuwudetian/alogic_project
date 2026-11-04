"""Run the native HDMI regression from any working directory (Icarus on PATH)."""
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
WORKSPACE = PROJECT.parent
LOGS = PROJECT / "doc/validation/simulation/logs"
SOURCES = sorted((PROJECT / "src/user_source").rglob("*.v"))
TESTS = [(name, name, []) for name in (
    "tb_hdmi_native_top", "tb_hdmi_1024", "tb_preview_sdram", "tb_top_camera", "tb_cnn_int8",
    "tb_capture_1024", "tb_camera_config", "tb_roi_capture",
    "tb_result_display", "tb_video_io", "tb_damage_overlay",
)]
TESTS.append(("tb_damage_overlay_1024", "tb_damage_overlay", [
    "-Ptb_damage_overlay.WIDTH=1024", "-Ptb_damage_overlay.HEIGHT=768",
]))



def run_test(test, temp):
    name, top, parameters = test
    bench = PROJECT / "sim" / f"{top}.v"
    sources = SOURCES
    executable = Path(temp) / f"{name}.vvp"
    compile_command = ["iverilog", "-g2012", "-DSIMULATION", "-I", "model", "-s", top,
                       *parameters, "-o", str(executable), str(bench), *map(str, sources)]
    start = time.monotonic()
    result = {"test": name, "top": top, "compile_command": compile_command,
              "run_command": ["vvp", str(executable)], "cwd": str(PROJECT)}
    text = ""
    passed = False
    try:
        compiled = subprocess.run(compile_command, cwd=PROJECT, capture_output=True,
                                  text=True, errors="replace", timeout=120)
        text += compiled.stdout + compiled.stderr
        result["compile_returncode"] = compiled.returncode
        if compiled.returncode == 0:
            simulated = subprocess.run(result["run_command"], cwd=PROJECT, capture_output=True,
                                       text=True, errors="replace", timeout=1200)
            text += simulated.stdout + simulated.stderr
            result["run_returncode"] = simulated.returncode
            passed = (simulated.returncode == 0 and "PASS" in text
                      and not re.search(r"(?m)^(?:FAIL|FATAL|ERROR):?\b", text))
    except (OSError, subprocess.TimeoutExpired) as exc:
        text += f"\nERROR: {exc}\n"
    result.update(passed=passed, seconds=round(time.monotonic() - start, 2),
                  log=f"logs/{name}.log")
    (LOGS / f"{name}.log").write_text(text, encoding="utf-8")
    print(f"{'PASS' if passed else 'FAIL'} {name} ({result['seconds']} s)", flush=True)
    return result


def main():
    LOGS.mkdir(parents=True, exist_ok=True)
    files = SOURCES + sorted((PROJECT / "model").rglob("*")) + sorted((PROJECT / "sim").glob("*.v"))
    inputs = {str(p.relative_to(WORKSPACE)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in files if p.is_file()}
    with tempfile.TemporaryDirectory(prefix="b_hdmi_1024_") as temp:
        with ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(run_test, test, temp) for test in TESTS]
            results = [future.result() for future in as_completed(futures)]
    summary = {"all_passed": all(r["passed"] for r in results),
               "tests": sorted(results, key=lambda r: r["test"]), "input_sha256": inputs}
    (LOGS.parent / "regression_results.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(0 if summary["all_passed"] else 1)


if __name__ == "__main__":
    main()
