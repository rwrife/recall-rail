#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
# Every raw signing output and key is ephemeral, outside the artifact directory.
private=$(mktemp -d)
trap 'rm -rf "$private"' EXIT
mkdir -p ReleaseEvidence "$private/tmp"
export TMPDIR="$private/tmp"
# Trap unexpected shell errors using a fixed label; subprocess output stays private.
trap 'echo release_step_failed' ERR
python3 - "$private" > "$private/setup-output" 2>&1 <<'PY'
import os,pathlib,sys,json,plistlib
root=pathlib.Path(sys.argv[1])
(root/('AuthKey_'+os.environ['ASC_KEY_ID']+'.p8')).write_text(os.environ['ASC_KEY_P8'])
with (root/'ExportOptions.plist').open('wb') as stream:
    plistlib.dump({'method':'app-store-connect','destination':'upload','signingStyle':'automatic','teamID':os.environ['ASC_TEAM_ID'],'manageAppVersionAndBuildNumber':False},stream)
PY
unset ASC_KEY_P8
key="$private/AuthKey_${ASC_KEY_ID}.p8"
build="${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}"
python3 - > "$private/toolchain-output" 2>&1 <<'PY'
import json,subprocess
contract=json.load(open('toolchain.json'))
assert subprocess.check_output(['xcodebuild','-version'],text=True).splitlines()==['Xcode '+contract['xcode_version'],'Build version '+contract['xcode_build']]
assert subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-version'],text=True).strip()==contract['iphoneos_sdk']
PY
run_private() {
  local category="$1"; shift
  local status=0
  "$@" > "$private/output" 2>&1 || status=$?
  python3 scripts/release_support.py sanitize "$private/output" > "ReleaseEvidence/$category.json"
  rm "$private/output"
  if [ "$status" -ne 0 ]; then echo "release_${category}_failed"; exit 1; fi
}
marketing=$(python3 - <<'PYMARKETING'
import re
text=open('RecallRail.xcodeproj/project.pbxproj').read()
values=set(re.findall(r'MARKETING_VERSION = ([0-9.]+);',text))
assert len(values)==1
print(values.pop())
PYMARKETING
)
run_private monotonic python3 scripts/release_support.py monotonic "$key" "$build" "$marketing"
run_private archive xcodebuild -project RecallRail.xcodeproj -scheme RecallRail -configuration Release -destination 'generic/platform=iOS' -archivePath "$private/RecallRail.xcarchive" CURRENT_PROJECT_VERSION="$build" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Distribution" DEVELOPMENT_TEAM="$ASC_TEAM_ID" -allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" archive
app="$private/RecallRail.xcarchive/Products/Applications/RecallRail.app"
run_private signature codesign --verify --deep --strict "$app"
python3 scripts/release_support.py verify "$app" > ReleaseEvidence/archive-verification.txt 2> "$private/verify-output"
run_private monotonic_preupload python3 scripts/release_support.py monotonic "$key" "$build" "$marketing"
since=$(date +%s)
run_private upload xcodebuild -exportArchive -archivePath "$private/RecallRail.xcarchive" -exportOptionsPlist "$private/ExportOptions.plist" -exportPath "$private/export" -allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
python3 scripts/release_support.py poll "$key" "$build" "$since" ReleaseEvidence/processed-build.json 2> "$private/poll-output"
python3 - "$build" <<'PY'
import json,os,sys,subprocess
json.dump({'sha':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'build_number':sys.argv[1],'toolchain':json.load(open('toolchain.json'))},open('ReleaseEvidence/release.json','w'))
PY
