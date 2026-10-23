#!/usr/bin/env python3
"""Report simulator Files-provider availability without exporting private paths or files."""
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import unquote, urlparse


def summarize(apps, app_data):
    files = apps.get("com.apple.DocumentsApp", {})
    group = files.get("GroupContainers", {}).get("group.com.apple.FileProvider.LocalStorage")
    if group:
        parsed = urlparse(group)
        storage = Path(unquote(parsed.path)) / "File Provider Storage" if parsed.scheme == "file" else None
    else:
        storage = None
    exports = Path(app_data) / "Documents" / "Exports" if app_data else None
    return {
        "files_app_registered": bool(files),
        "local_storage_group_registered": bool(group),
        "local_storage_directory_exists": bool(storage and storage.is_dir()),
        "local_storage_directory_writable": bool(storage and os.access(storage, os.W_OK)),
        "app_exports_directory_exists": bool(exports and exports.is_dir()),
    }


def main():
    # simctl listapps emits an OpenStep plist; macOS plutil converts it to JSON.
    listed = subprocess.check_output(["xcrun", "simctl", "listapps", "booted"], timeout=30)
    converted = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", "-"], input=listed, timeout=30)
    try:
        app_data = subprocess.check_output(
            ["xcrun", "simctl", "get_app_container", "booted", "com.infinityball.recallrail", "data"],
            text=True, stderr=subprocess.DEVNULL, timeout=30,
        ).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        app_data = None
    print(json.dumps(summarize(json.loads(converted), app_data), sort_keys=True))


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "File Provider Storage").mkdir()
            (root / "app" / "Documents" / "Exports").mkdir(parents=True)
            apps = {"com.apple.DocumentsApp": {"GroupContainers": {
                "group.com.apple.FileProvider.LocalStorage": root.as_uri()}}}
            result = summarize(apps, str(root / "app"))
            assert result["files_app_registered"] and result["local_storage_directory_exists"]
            assert result["app_exports_directory_exists"]
            assert not summarize({}, None)["local_storage_group_registered"]
        print("Files provider probe self-test: PASS")
    else:
        main()
