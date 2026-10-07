#!/bin/bash
# Real AppKit key-window test host; unbundled swift-test xctest cannot activate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${LUMIBASE_NATIVE_TEST_SCRATCH:?Set an authorized scratch directory}"
mkdir -p "$LUMIBASE_NATIVE_TEST_SCRATCH"
cd "$ROOT"
swift test -c release --filter SettingsKeyboardRoutingTests > "$LUMIBASE_NATIVE_TEST_SCRATCH/build.log" 2>&1
export LUMIBASE_NATIVE_TEST_ROOT="$ROOT"
export LUMIBASE_NATIVE_XCTEST="$(xcrun --find xctest)"
export LUMIBASE_NATIVE_PLATFORM="$(xcrun --show-sdk-platform-path)"
python3 - <<'PY'
import os, pathlib, plistlib, shutil
scratch = pathlib.Path(os.environ['LUMIBASE_NATIVE_TEST_SCRATCH'])
app = scratch / 'LumiBaseSettingsKeyboardTests.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True, exist_ok=True)
shutil.copy2(os.environ['LUMIBASE_NATIVE_XCTEST'], macos / 'TestHost')
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'TestHost',
    'CFBundleIdentifier': 'com.lumibase.settings-keyboard-tests',
    'CFBundleName': 'LumiBase Settings Keyboard Tests',
    'CFBundlePackageType': 'APPL', 'NSPrincipalClass': 'NSApplication'}))
platform = pathlib.Path(os.environ['LUMIBASE_NATIVE_PLATFORM'])
links = {
    app / 'Frameworks': platform / 'Developer/Library/Frameworks',
    app / 'PrivateFrameworks': pathlib.Path(os.environ['LUMIBASE_NATIVE_XCTEST']).parents[2] / 'Library/PrivateFrameworks',
    pathlib.Path(os.environ['LUMIBASE_NATIVE_TEST_ROOT']) / '.build/release/libXCTestSwiftSupport.dylib': platform / 'Developer/usr/lib/libXCTestSwiftSupport.dylib'}
for link, target in links.items():
    if not link.exists(): link.symlink_to(target)
for name in ('stdout.log', 'stderr.log'):
    (scratch / name).write_text('')
PY
open -W -n "$LUMIBASE_NATIVE_TEST_SCRATCH/LumiBaseSettingsKeyboardTests.app" \
    --env "LUMIBASE_TEST_OUTPUT=$LUMIBASE_NATIVE_TEST_SCRATCH/fixtures" \
    --stdout "$LUMIBASE_NATIVE_TEST_SCRATCH/stdout.log" \
    --stderr "$LUMIBASE_NATIVE_TEST_SCRATCH/stderr.log" \
    --args -XCTest LumiBaseTests.SettingsKeyboardRoutingTests \
    "$ROOT/.build/release/LumiBasePackageTests.xctest"
python3 - <<'PY'
import os, pathlib, re
root = pathlib.Path(os.environ['LUMIBASE_NATIVE_TEST_SCRATCH'])
text = (root / 'stdout.log').read_text() + (root / 'stderr.log').read_text()
print(text)
if not re.search(r'Executed 1 test, with 0 failures', text) or 'skipped' in text or 'failed' in text:
    raise SystemExit('Native hosted keyboard test did not pass')
PY
