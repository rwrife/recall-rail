#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "Project contract: FAIL ($1)" >&2
  exit 1
}

expect_json_string() {
  local key="$1" expected="$2"
  grep -Eq "\"$key\"[[:space:]]*:[[:space:]]*\"$expected\"" toolchain.json \
    || fail "toolchain.json $key must be $expected"
}

expect_json_string xcode_version 26.0.1
expect_json_string xcode_build 17A400
expect_json_string iphoneos_sdk 26.0
expect_json_string deployment_target 26.0
expect_json_string swift_language_mode 6
expect_json_string bundle_identifier com.infinityball.recallrail
expect_json_string targeted_device_family 1
expect_json_string implementation native-swift
expect_json_string platform ios
expect_json_string device_family iphone-only
grep -Eq '"minimum_sdk_major"[[:space:]]*:[[:space:]]*26([,[:space:]]|$)' toolchain.json \
  || fail "minimum_sdk_major must be 26"
grep -Eq '"native_ipad_support"[[:space:]]*:[[:space:]]*false' toolchain.json \
  || fail "native_ipad_support must be false"
grep -Eq '"network_allowlist"[[:space:]]*:[[:space:]]*\[\]' toolchain.json \
  || fail "network_allowlist must remain empty"

project=RecallRail.xcodeproj/project.pbxproj
family_count=$(grep -c 'TARGETED_DEVICE_FAMILY = 1;' "$project")
[[ "$family_count" -ge 6 ]] || fail "expected six iPhone-only settings, found $family_count"
if grep -Eq 'TARGETED_DEVICE_FAMILY = [^1;]' "$project"; then
  fail "non-iPhone device family found"
fi
app_bundle_count=$(grep -c 'PRODUCT_BUNDLE_IDENTIFIER = com.infinityball.recallrail;' "$project")
[[ "$app_bundle_count" -eq 2 ]] || fail "app bundle identifier must be exact in Debug and Release"
if grep 'PRODUCT_BUNDLE_IDENTIFIER =' "$project" | grep -qv 'com.infinityball.recallrail'; then
  fail "target bundle identifier outside registered prefix"
fi
swift_count=$(grep -c 'SWIFT_VERSION = 6.0;' "$project")
[[ "$swift_count" -ge 6 ]] || fail "Swift 6 missing from one or more configurations"
deployment_count=$(grep -c 'IPHONEOS_DEPLOYMENT_TARGET = 26.0;' "$project")
[[ "$deployment_count" -ge 6 ]] || fail "iOS 26 missing from one or more configurations"
grep -q 'productType = "com.apple.product-type.application";' "$project" \
  || fail "native app target missing"
grep -q 'productName = RecallRailKit;' "$project" \
  || fail "RecallRailKit product dependency missing"
grep -q 'SUPPORTS_MACCATALYST = NO;' "$project" \
  || fail "Mac Catalyst must be disabled"
grep -q 'productType = "com.apple.product-type.bundle.ui-testing";' "$project" \
  || fail "actual XCUITest target missing"
grep -q 'TEST_TARGET_NAME = RecallRail;' "$project" \
  || fail "XCUITest app target binding missing"
grep -q 'BlueprintName="RecallRailUITests"' RecallRail.xcodeproj/xcshareddata/xcschemes/RecallRail.xcscheme \
  || fail "shared scheme must run XCUITest target"
mic_count=$(grep -c 'INFOPLIST_KEY_NSMicrophoneUsageDescription =' "$project")
[[ "$mic_count" -eq 2 ]] || fail "microphone purpose string required in both app configurations"

privacy=RecallRail/PrivacyInfo.xcprivacy
grep -A1 -q '<key>NSPrivacyTracking</key>' "$privacy" || fail "tracking declaration missing"
grep -A1 '<key>NSPrivacyTracking</key>' "$privacy" | grep -q '<false/>' \
  || fail "tracking must be false"
grep -A1 '<key>NSPrivacyTrackingDomains</key>' "$privacy" | grep -q '<array/>' \
  || fail "tracking domains must be empty"
grep -A1 '<key>NSPrivacyCollectedDataTypes</key>' "$privacy" | grep -q '<array/>' \
  || fail "collected data types must be empty"

echo "Project contract: PASS (native Swift, bundle com.infinityball.recallrail, iPhone family 1, iOS 26, Swift 6, zero tracking)"
