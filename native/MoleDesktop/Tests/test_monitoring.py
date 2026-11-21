#!/usr/bin/env python3
"""Run native fixtures and the read-only process sampler on macOS."""
from pathlib import Path
import platform
import subprocess
import tempfile

tests = Path(__file__).resolve().parent
sources = tests.parent / "Sources"
cases = {
    "WholeDiskTests": ["DiskScanner", "DiskSnapshots", "AnalyzePage", "TreemapLayout", "Localization", "Design", "ContourMark"],
    "TreemapTests": ["DiskScanner", "DiskSnapshots", "AnalyzePage", "TreemapLayout", "Localization", "Design", "ContourMark"],
    "HardwareCounterTests": ["HardwareTelemetry"],
    "ProcessMonitorTests": ["ProcessMonitor", "Localization", "Design", "ContourMark"],
    "StatusVitalsTests": ["StatusVitals", "Localization"],
    "MenuActivityTests": ["MenuActivityFooter", "Design", "ContourMark", "Localization"],
    "MonitorSessionTests": ["MonitorSession", "StatusPage", "ProcessMonitor", "HardwareTelemetry",
                            "StatusVitals", "LinkQuality", "Design", "Localization", "ContourMark"],
}

if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="strata-monitor-tests-") as temp:
        for case, files in cases.items():
            exe = Path(temp) / case
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-target",
                            f"{platform.machine()}-apple-macosx13.0", "-module-cache-path", Path(temp) / "modules",
                            *(sources / f"{name}.swift" for name in files), tests / f"{case}.swift",
                            "-o", exe], check=True)
            subprocess.run([exe], check=True, timeout=40)
