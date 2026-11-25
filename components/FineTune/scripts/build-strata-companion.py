#!/usr/bin/env python3
"""Build the ad-hoc, hardened FineTune companion embedded by Strata's build.py."""
import argparse
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "io.github.ahyesyesyes111.FineTune.Custom"


def verify(app):
    executable = app / "Contents/MacOS/FineTune"
    libraries = subprocess.check_output(["otool", "-L", executable], text=True).splitlines()
    # A structurally valid nested signature can still be rejected by dyld's
    # hardened-runtime team check. This build needs only system libraries.
    for library in libraries:
        if not library.startswith("\t"):  # per-architecture header in universal binaries
            continue
        path = library.strip().split(" (", 1)[0]
        if not path.startswith(("/System/Library/", "/usr/lib/")):
            raise RuntimeError(f"Unexpected non-system launch dependency: {path}")
    if (app / "Contents/Frameworks/Sparkle.framework").exists():
        raise RuntimeError("The companion must ship without the independent updater")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("StrataMixerBridgeVersion") != 2
            or info.get("StrataMixerControlsRevision") != 1 or "SUFeedURL" in info):
        raise RuntimeError("The companion bundle identity or capabilities are incorrect")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
    description = subprocess.run(["codesign", "-dvvv", app], capture_output=True, text=True, check=True)
    if "runtime" not in next((s for s in description.stderr.splitlines() if s.startswith("CodeDirectory ")), ""):
        raise RuntimeError("The hardened runtime must be enabled")
    entitlement_data = subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", app])
    entitlements = plistlib.loads(entitlement_data)
    if entitlements.get("com.apple.security.cs.disable-library-validation") or entitlements.get("com.apple.security.get-task-allow"):
        raise RuntimeError("Companion must retain library validation and disallow debugger attachment")
    if not entitlements.get("com.apple.security.device.audio-input") or not entitlements.get("com.apple.security.device.bluetooth"):
        raise RuntimeError("Companion is missing audio or Bluetooth entitlements")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="new FineTune.app bundle to create")
    parser.add_argument("--derived-data", type=Path, default=ROOT / "build/strata-companion-derived")
    parser.add_argument("--packages", type=Path, help="reuse a local Xcode SourcePackages checkout")
    parser.add_argument("--build-number", default="2026112505")
    parser.add_argument("--verify-only", action="store_true", help="check an existing staged or installed companion")
    args = parser.parse_args()
    destination = args.destination.absolute()
    if args.verify_only:
        verify(destination)
        return
    if destination.suffix != ".app" or destination.exists():
        parser.error("destination must be a new .app path")
    derived = args.derived_data.resolve()
    command = ["xcodebuild", "-project", ROOT / "FineTune.xcodeproj", "-scheme", "FineTune",
               "-configuration", "Release", "-destination", "platform=macOS",
               "-derivedDataPath", derived, "-onlyUsePackageVersionsFromResolvedFile"]
    if args.packages:
        command += ["-clonedSourcePackagesDirPath", args.packages.resolve(), "-skipPackageUpdates"]
    command += [f"PRODUCT_BUNDLE_IDENTIFIER={BUNDLE_ID}", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
                "ENABLE_HARDENED_RUNTIME=YES", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) STRATA_COMPANION",
                "OTHER_LDFLAGS=$(inherited) -Wl,-dead_strip_dylibs",
                "MARKETING_VERSION=1.9.0", f"CURRENT_PROJECT_VERSION={args.build_number}", "build"]
    subprocess.run(command, cwd=ROOT, check=True)
    built = derived / "Build/Products/Release/FineTune.app"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="finetune-stage-", dir=destination.parent) as staging:
        app = Path(staging) / "FineTune.app"
        # Xcode embeds all framework package products linked by the standalone
        # target. The companion discards Sparkle after the linker omits its dylib.
        subprocess.run(["ditto", "--norsrc", "--noextattr", built, app], check=True)
        sparkle = app / "Contents/Frameworks/Sparkle.framework"
        if sparkle.is_dir():
            shutil.rmtree(sparkle)
        info_path = app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        for key in ("SUFeedURL", "SUPublicEDKey", "SUEnableInstallerLauncherService"):
            info.pop(key, None)
        info["CFBundleDisplayName"] = info["CFBundleName"] = "FineTune Custom"
        for entry in info.get("CFBundleURLTypes", []):
            entry["CFBundleURLName"] = BUNDLE_ID
        info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime",
                        "--preserve-metadata=entitlements", app], check=True)
        verify(app)
        os.rename(app, destination)
    print(destination)


if __name__ == "__main__":
    main()
