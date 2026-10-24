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


def _simctl_json(args, timeout, attempts=3):
    # CoreSimulator daemon cold-start can push the first hosted simctl call
    # past its timeout; bounded retries keep the probe honest about hosts
    # that are genuinely stuck (all attempts fail -> raise).
    for attempt in range(attempts):
        try:
            return json.loads(subprocess.check_output(
                ["xcrun", "simctl", *args], stderr=subprocess.DEVNULL, timeout=timeout))
        except subprocess.TimeoutExpired:
            if attempt == attempts - 1:
                raise
    raise RuntimeError("unreachable: no simulator list")


def resolve_udid():
    listing = _simctl_json(["list", "devices", "available", "-j"], 60)
    for devices in listing["devices"].values():
        for device in devices:
            if device.get("name") == "iPhone 17":
                return device["udid"]
    raise LookupError("iPhone 17 unavailable")


def main(warm=False):
    # Never emit command output: listapps contains private sandbox paths.
    # Use the exact test destination after xcodebuild shuts its device down.
    stage = "resolve_udid"
    try:
        udid = os.environ.get("RECALL_SIM_UDID") or resolve_udid()
        stage = "boot"
        subprocess.run(["xcrun", "simctl", "boot", udid], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=60, check=False)
        stage = "bootstatus"
        subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=300, check=True)
        if warm:
            stage = "launch_files"
            subprocess.run(["xcrun", "simctl", "launch", udid, "com.apple.DocumentsApp"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60, check=True)
            print(json.dumps({"files_app_launched": True}, sort_keys=True))
            return
        stage = "listapps"
        listed = subprocess.check_output(["xcrun", "simctl", "listapps", udid], stderr=subprocess.DEVNULL, timeout=60)
        stage = "plutil"
        converted = subprocess.check_output(["plutil", "-convert", "json", "-o", "-"], input=listed, stderr=subprocess.DEVNULL, timeout=30)
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
        result = summarize(apps, app_data)
        print(json.dumps(result, sort_keys=True))
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
            with patch("subprocess.check_output", side_effect=[
                subprocess.TimeoutExpired("simctl", 60),
                b'{"devices":{"runtime":[{"name":"iPhone 17","udid":"test-id"}]}}',
            ]) as mock_list:
                assert resolve_udid() == "test-id"
                assert mock_list.call_count == 2
            with patch("subprocess.check_output", side_effect=subprocess.TimeoutExpired("simctl", 60)) as mock_list:
                try:
                    resolve_udid()
                    raise AssertionError("retry bound did not fail closed")
                except subprocess.TimeoutExpired:
                    assert mock_list.call_count == 3
            with patch("subprocess.run") as mock_run, patch.dict(os.environ, {"RECALL_SIM_UDID": "test-id"}):
                import io
                from contextlib import redirect_stdout
                buf = io.StringIO()
                with redirect_stdout(buf):
                    main(warm=True)
                assert json.loads(buf.getvalue()) == {"files_app_launched": True}
                assert mock_run.call_count == 3
                assert mock_run.call_args_list[1].kwargs["timeout"] == 300
            with patch("subprocess.run") as mock_run, patch.dict(os.environ, {"RECALL_SIM_UDID": "test-id"}):
                mock_run.side_effect = [None, subprocess.TimeoutExpired("bootstatus", 300)]
                with redirect_stdout(io.StringIO()) as failure:
                    try:
                        main(warm=True)
                        raise AssertionError("bootstatus timeout did not fail closed")
                    except SystemExit as error:
                        assert error.code == 1
                assert json.loads(failure.getvalue())["probe_failed_at"] == "bootstatus"
            # ponytail: bounded simctl retries; full daemon health only native CI can establish.
        print("Files provider probe self-test: PASS")
    elif sys.argv[1:] == ["--udid"]:
        try:
            print(resolve_udid())
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError, ValueError, KeyError, LookupError) as error:
            print(json.dumps({"probe_failed_at": "resolve_udid", "error_type": type(error).__name__}))
            sys.exit(1)
    elif sys.argv[1:] == ["--warm"]:
        main(warm=True)
    else:
        main()
