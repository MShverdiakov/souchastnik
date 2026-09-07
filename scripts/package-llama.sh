#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIM_FRAMEWORK=build/llama-simulator/framework/llama.framework
DEVICE_FRAMEWORK=Vendor/build-apple/llama.xcframework/ios-arm64/llama.framework
mkdir -p "$SIM_FRAMEWORK/Headers" "$SIM_FRAMEWORK/Modules"
cp "$DEVICE_FRAMEWORK"/Headers/*.h "$SIM_FRAMEWORK/Headers/"
cp "$DEVICE_FRAMEWORK/Modules/module.modulemap" "$SIM_FRAMEWORK/Modules/"
xcrun --sdk iphonesimulator clang++ -target arm64-apple-ios17.0-simulator \
    -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -dynamiclib -Wl,-all_load \
    build/llama-simulator/src/libllama.a \
    build/llama-simulator/ggml/src/libggml.a \
    build/llama-simulator/ggml/src/libggml-base.a \
    build/llama-simulator/vendor/hash/libvendor-hash.a \
    build/llama-simulator/ggml/src/libggml-cpu.a \
    -framework Accelerate -framework Foundation \
    -install_name @rpath/llama.framework/llama \
    -o "$SIM_FRAMEWORK/llama"
python3 - <<'PY'
from pathlib import Path
import plistlib
p = {'CFBundleExecutable':'llama','CFBundleIdentifier':'org.ggml.llama','CFBundleName':'llama','CFBundlePackageType':'FMWK','CFBundleShortVersionString':'1.0','CFBundleVersion':'10726','MinimumOSVersion':'17.0','CFBundleSupportedPlatforms':['iPhoneSimulator']}
Path('build/llama-simulator/framework/llama.framework/Info.plist').write_bytes(plistlib.dumps(p))
PY
# Output is generated only; original source and the device release remain intact.
if [ -d Vendor/llama.xcframework ]; then
    mv Vendor/llama.xcframework "build/llama-previous-$(date +%s).xcframework"
fi
xcodebuild -create-xcframework -framework "$DEVICE_FRAMEWORK" \
    -framework "$SIM_FRAMEWORK" -output Vendor/llama.xcframework
