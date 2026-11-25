#!/usr/bin/env python3
"""Build the native app for this Mac using the installed Apple developer tools."""
from pathlib import Path
import argparse
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parent
repo = project.parent.parent
bundle_id = "local.strata.DiskWorkspace"

usage_descriptions = {
    "NSDownloadsFolderUsageDescription": (
        "Measure the Downloads folder you choose in Disk Analysis.",
        "测量你在磁盘分析中选择的下载文件夹。"),
    "NSDocumentsFolderUsageDescription": (
        "Measure the Documents folder you choose in Disk Analysis.",
        "测量你在磁盘分析中选择的文稿文件夹。"),
    "NSDesktopFolderUsageDescription": (
        "Measure the Desktop folder you choose in Disk Analysis.",
        "测量你在磁盘分析中选择的桌面文件夹。"),
    "NSPhotoLibraryUsageDescription": (
        "Measure the disk space used by the Photos library you choose in Disk Analysis.",
        "测量你在磁盘分析中选择的照片图库所占的空间。"),
    "NSAppleEventsUsageDescription": (
        "During cleanup, Mole checks which apps are running to protect data that is in use.",
        "清理时，Mole 会核对正在运行的应用，保护仍在使用的数据。"),
}

# macOS can attribute the embedded mixer's requests to the enclosing app.
companion_usage_descriptions = {
    "NSBluetoothAlwaysUsageDescription": (
        "FineTune uses Bluetooth to connect paired audio devices from the Strata menu.",
        "FineTune 使用蓝牙，从 Strata 菜单连接已配对的音频设备。"),
    "NSAudioCaptureUsageDescription": (
        "FineTune uses system audio access to adjust each app’s volume and route it to the output you choose.",
        "FineTune 使用系统音频权限调节各个应用的音量，并将声音发送到你选择的输出设备。"),
    "NSMicrophoneUsageDescription": (
        "FineTune uses microphone access to capture app audio when an audio device also supports input.",
        "使用兼具输入功能的音频设备时，FineTune 需要麦克风权限来采集应用音频。"),
}


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def validate_companion(app):
    with (app / "Contents/Info.plist").open("rb") as info:
        companion = plistlib.load(info)
    custom_id = "io.github.ahyesyesyes111.FineTune.Custom"
    identifier = companion.get("CFBundleIdentifier")
    if (companion.get("StrataMixerBridgeVersion") != 2
            or companion.get("StrataMixerControlsRevision", 0) < 1
            or identifier not in {custom_id, "com.finetuneapp.FineTune"}):
        raise ValueError("Select a FineTune build with Strata mixer support.")
    run("codesign", "--verify", "--strict", app)
    if identifier != custom_id:
        return
    signing = subprocess.check_output(
        ["codesign", "--display", "--verbose=4", app], stderr=subprocess.STDOUT, text=True).splitlines()
    if "Signature=adhoc" in signing and any(line.startswith("CodeDirectory ") and "runtime" in line for line in signing):
        # Signature verification also succeeds for an individually valid
        # Sparkle framework that dyld refuses to load into an ad-hoc hardened app.
        executable = app / "Contents/MacOS" / companion["CFBundleExecutable"]
        libraries = subprocess.check_output(["xcrun", "otool", "-arch", "all", "-L", executable], text=True)
        if any(line.lstrip().startswith("@rpath/Sparkle.framework/") for line in libraries.splitlines()):
            raise ValueError("This ad-hoc hardened FineTune links Sparkle. Use FineTune's scripts/build-strata-companion.py.")


def build(finetune_app=None, *, without_finetune=False, finetune_packages=None, output=project / "build"):
    if finetune_app:
        validate_companion(finetune_app)
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    destination = output / "Strata.app"
    if destination.exists():
        with (destination / "Contents/Info.plist").open("rb") as info:
            if destination.is_symlink() or plistlib.load(info).get("CFBundleIdentifier") != bundle_id:
                raise RuntimeError(f"Another app already exists at {destination}")
    # Finder can attach extended attributes at any time on synced folders.
    # Build and sign on the local temporary volume, then publish the signed archive.
    with tempfile.TemporaryDirectory(prefix="strata-build-") as temp:
        stage = Path(temp)
        if not without_finetune and finetune_app is None:
            finetune_app = stage / "FineTune.app"
            builder = repo / "components/FineTune/scripts/build-strata-companion.py"
            command = [sys.executable, builder, finetune_app, "--derived-data", output / "FineTuneDerivedData"]
            if finetune_packages:
                command.extend(["--packages", finetune_packages])
            run(*command)
        bundle = stage / "Strata.app"
        contents = bundle / "Contents"
        macos = contents / "MacOS"
        resources = contents / "Resources"
        cli = resources / "mole-cli"
        macos.mkdir(parents=True)
        (cli / "bin").mkdir(parents=True)
        swift = ["xcrun", "swiftc", "-swift-version", "5", "-target", f"{platform.machine()}-apple-macosx13.0",
                 "-module-cache-path", output / "ModuleCache"]
        run(*swift, "-O", *sorted((project / "Sources").glob("*.swift")), "-o", macos / "Strata")
        iconset = stage / "Strata.iconset"
        iconset.mkdir()
        run(*swift, project / "Sources/ContourMark.swift", project / "Packaging/Icon.swift", "-o", stage / "make-icon")
        run(stage / "make-icon", iconset)
        run("iconutil", "-c", "icns", iconset, "-o", resources / "Strata.icns")
        mole_source = repo / "components/Mole/macos"
        shutil.copy(mole_source / "mole", cli)
        shutil.copytree(mole_source / "lib", cli / "lib", copy_function=shutil.copy)
        for name in ("clean", "optimize"):
            shutil.copy(mole_source / f"bin/{name}.sh", cli / "bin")
        shutil.copy(repo / "LICENSE", resources)
        if finetune_app:
            helpers = contents / "Helpers"
            helpers.mkdir()
            run("/usr/bin/ditto", "--norsrc", "--noextattr", finetune_app, helpers / "FineTune.app")
        plist = {
            "CFBundleName": "Strata", "CFBundleDisplayName": "Strata", "CFBundleIconFile": "Strata",
            "CFBundleIdentifier": bundle_id, "CFBundlePackageType": "APPL", "CFBundleExecutable": "Strata",
            "CFBundleShortVersionString": "0.7.0", "CFBundleVersion": "7",
            "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "zh-Hans"],
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSMinimumSystemVersion": "13.0", "LSApplicationCategoryType": "public.app-category.utilities",
            "NSPrincipalClass": "NSApplication", "NSHighResolutionCapable": True,
            "NSHumanReadableCopyright": "Includes the Mole CLI by tw93 and contributors. GPL-3.0.",
        }
        descriptions = {**usage_descriptions, **companion_usage_descriptions} if finetune_app else usage_descriptions
        for index, language in enumerate(plist["CFBundleLocalizations"]):
            localized = {key: values[index] for key, values in descriptions.items()}
            (resources / f"{language}.lproj").mkdir()
            with (resources / f"{language}.lproj" / "InfoPlist.strings").open("wb") as file:
                plistlib.dump(localized, file, fmt=plistlib.FMT_BINARY)
            if language == plist["CFBundleDevelopmentRegion"]:
                plist.update(localized)
        if finetune_app:
            plist["NSHumanReadableCopyright"] += " Includes FineTune by Ronit Singh and contributors."
        with (contents / "Info.plist").open("wb") as file:
            plistlib.dump(plist, file)
        # Finder metadata inherited from a synced checkout is not part of the app.
        run("/usr/bin/xattr", "-cr", bundle)
        run("codesign", "--force", "--sign", "-", bundle)
        run("codesign", "--verify", "--deep", "--strict", bundle)
        # A zip preserves the signed resource layout on File Provider volumes.
        archive = stage / "Strata.zip"
        run("/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", bundle, archive)
        with tempfile.TemporaryDirectory(dir=output, prefix=".stage-") as publish_dir:
            publish = Path(publish_dir)
            prepared = publish / bundle.name
            local_archive = publish / archive.name
            shutil.copyfile(archive, local_archive)
            run("/usr/bin/ditto", "-x", "-k", local_archive, publish)
            previous = publish / "previous.app"
            if destination.exists():
                destination.rename(previous)
            try:
                prepared.rename(destination)
                local_archive.replace(output / archive.name)
            except OSError:
                if destination.exists() and not prepared.exists():
                    destination.rename(prepared)
                if previous.exists():
                    previous.rename(destination)
                raise
    # File Provider can reattach Finder metadata as soon as the bundle is published.
    verified = subprocess.run(["codesign", "--verify", "--deep", "--strict", destination],
                              capture_output=True, text=True)
    if verified.returncode:
        if "resource fork, Finder information, or similar detritus" not in verified.stderr:
            raise RuntimeError(verified.stderr.strip())
        with tempfile.TemporaryDirectory(prefix="strata-verify-") as temp:
            run("/usr/bin/ditto", "-x", "-k", output / "Strata.zip", temp)
            run("codesign", "--verify", "--deep", "--strict", Path(temp) / "Strata.app")
        print("The output folder added Finder metadata. Extract the verified ZIP in a local folder.")
        print(output / "Strata.zip")
    else:
        print(destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mixer = parser.add_mutually_exclusive_group()
    mixer.add_argument("--without-finetune", action="store_true", help="Build the desktop app without the audio companion.")
    mixer.add_argument("--finetune-app", type=Path, help="Use a prebuilt signed FineTune companion.")
    mixer.add_argument("--finetune-packages", type=Path, help="Reuse a local Xcode SourcePackages cache for the companion build.")
    parser.add_argument("--output-dir", type=Path, default=project / "build", help="Set the build and archive directory.")
    args = parser.parse_args()
    build(args.finetune_app, without_finetune=args.without_finetune,
          finetune_packages=args.finetune_packages, output=args.output_dir)
