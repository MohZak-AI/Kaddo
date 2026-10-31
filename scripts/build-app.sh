#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/swift-module-cache"

build_options=(--disable-sandbox --cache-path .build/cache --config-path .build/config
    --security-path .build/security -c release)
swift build "${build_options[@]}" --product Kaddo
binary_directory=$(swift build "${build_options[@]}" --show-bin-path)
app_directory="$PWD/.build/Kaddo.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$binary_directory/Kaddo" "$app_directory/Contents/MacOS/Kaddo"
ditto "$binary_directory/Kaddo_KaddoCanvas.bundle" \
    "$app_directory/Contents/Resources/Kaddo_KaddoCanvas.bundle"
cat > "$app_directory/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>Kaddo</string>
    <key>CFBundleIdentifier</key><string>com.kaddo.canvas</string>
    <key>CFBundleName</key><string>Kaddo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key><dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict></plist>
PLIST
codesign --force --sign - "$app_directory"
print -r -- "Built $app_directory"
