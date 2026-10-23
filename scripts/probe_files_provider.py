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


def resolve_udid():
    listing = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        stderr=subprocess.DEVNULL, timeout=30,
    ))
    for devices in listing["devices"].values():
        for device in devices:
            if device.get("name") == "iPhone 17":
                return device["udid"]
    raise LookupError("iPhone 17 unavailable")


def main():
    # Never emit command output: listapps contains private sandbox paths.
    # The test run may leave no booted device, so resolve the pinned UDID.
    stage = "resolve_udid"
    try:
        udid = resolve_udid()
        stage = "listapps"
        listed = subprocess.check_output(["xcrun", "simctl", "listapps", udid], stderr=subprocess.DEVNULL, timeout=60)
        stage = "plutil"
        converted = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", "-"], input=listed, stderr=subprocess.DEVNULL, timeout=30)
        stage = "parse"
        apps = json.loads(converted)
        stage = "app_container"
        try:
            app_data = subprocess.check_output(
                ["xcrun", "simctl", "get_app_container", udid, "com.infinityball.recallrail", "data"],
                text=True, stderr=subprocess.DEVNULL, timeout=30,
            ).strip()
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            app_data = None
        print(json.dumps(summarize(apps, app_data), sort_keys=True))
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, LookupError, ValueError, TypeError, KeyError) as error:
        print(json.dumps({"probe_failed_at": stage, "error_type": type(error).__name__}, sort_keys=True))
        sys.exit(1)


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
            from unittest.mock import patch
            with patch("subprocess.check_output", return_value=b'{"devices":{"runtime":[{"name":"iPhone 17","udid":"test-id"}]}}'):
                assert resolve_udid() == "test-id"
        print("Files provider probe self-test: PASS")
    else:
        main()
