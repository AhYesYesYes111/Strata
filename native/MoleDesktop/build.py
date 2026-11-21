#!/usr/bin/env python3
"""Build the native app for this Mac using the installed Apple developer tools."""
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile

project = Path(__file__).resolve().parent
repo = project.parent.parent
output = project / "build"
destination = output / "Strata.app"
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


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def build():
    output.mkdir(exist_ok=True)
    if destination.exists():
        with (destination / "Contents/Info.plist").open("rb") as info:
            if destination.is_symlink() or plistlib.load(info).get("CFBundleIdentifier") != bundle_id:
                raise RuntimeError(f"Another app already exists at {destination}")
    # Finder can attach extended attributes at any time on synced folders.
    # Build and sign on the local temporary volume, then publish the signed archive.
    with tempfile.TemporaryDirectory(prefix="strata-build-") as temp:
        stage = Path(temp)
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
        run(*swift, project / "Sources/PlanetMark.swift", project / "Packaging/Icon.swift", "-o", stage / "make-icon")
        run(stage / "make-icon", iconset)
        run("iconutil", "-c", "icns", iconset, "-o", resources / "Strata.icns")
        shutil.copyfile(project / "Resources/Earth.png", resources / "Earth.png")
        shutil.copy(repo / "mole", cli)
        shutil.copytree(repo / "lib", cli / "lib", copy_function=shutil.copy)
        for name in ("clean", "optimize"):
            shutil.copy(repo / f"bin/{name}.sh", cli / "bin")
        shutil.copy(repo / "LICENSE", resources)
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
        for index, language in enumerate(plist["CFBundleLocalizations"]):
            localized = {key: values[index] for key, values in usage_descriptions.items()}
            (resources / f"{language}.lproj").mkdir()
            with (resources / f"{language}.lproj" / "InfoPlist.strings").open("wb") as file:
                plistlib.dump(localized, file, fmt=plistlib.FMT_BINARY)
            if language == plist["CFBundleDevelopmentRegion"]:
                plist.update(localized)
        with (contents / "Info.plist").open("wb") as file:
            plistlib.dump(plist, file)
        # Finder metadata inherited from a synced checkout is not part of the app.
        run("/usr/bin/xattr", "-cr", bundle)
        run("codesign", "--force", "--sign", "-", bundle)
        run("codesign", "--verify", "--strict", bundle)
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
    print(destination)


if __name__ == "__main__":
    build()
