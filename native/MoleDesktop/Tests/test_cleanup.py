#!/usr/bin/env python3
"""Exercise the native confirmation boundary with a recorder in a temporary bundle."""
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile


def main():
    tests = Path(__file__).resolve().parent
    source = tests.parent / "Sources"
    with tempfile.TemporaryDirectory(prefix="strata-clean-flow-") as tmp:
        root = Path(tmp).resolve()
        home = root / "home"
        (home / ".config/mole").mkdir(parents=True)
        (home / "calls").touch()
        contents = root / "Fixture.app/Contents"
        cli = contents / "Resources/mole-cli"
        cli.mkdir(parents=True)
        (contents / "MacOS").mkdir()
        recorder = cli / "mole"
        shutil.copyfile(tests / "fake-mole", recorder)
        recorder.chmod(0o700)
        (cli / "expected-home").write_text(str(home) + "\n")
        executable = contents / "MacOS/Fixture"
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Fixture",
            "CFBundleIdentifier": "local.strata.tests.CleanupFlow",
            "CFBundlePackageType": "APPL",
        }))
        compiler = ["xcrun", "swiftc", "-swift-version", "5", "-target", f"{platform.machine()}-apple-macosx13.0",
                    "-module-cache-path", root / "modules"]
        subprocess.run([
            *compiler, source / "Localization.swift", source / "Design.swift", source / "ReliefLines.swift",
            source / "CleanupPreview.swift", source / "TimingEstimate.swift", source / "OrbitArtwork.swift", source / "PreviewPages.swift", source / "ReportSheet.swift", tests / "CleanupFlow.swift",
            "-o", executable,
        ], check=True)
        environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), BASH_ENV="/dev/null",
                           MOLE_TEST_MODE="1", MOLE_SKIP_MAIN="1", MOLE_TEST_TRASH_DIR="/dev/null",
                           MOLE_DRY_RUN="1", MOLE_TEST_NO_AUTH="1")
        subprocess.run([executable, home], env=environment, cwd=home, timeout=65, check=True)
        estimate_tests = root / "timing-tests"
        subprocess.run([*compiler, source / "Localization.swift", source / "TimingEstimate.swift", tests / "TimingEstimateTests.swift",
                        "-o", estimate_tests], check=True)
        subprocess.run([estimate_tests], env=environment, cwd=home, timeout=15, check=True)


if __name__ == "__main__":
    main()
