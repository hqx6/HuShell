#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
build_dir="$PWD/build"
app_dir="$build_dir/HuShell.app"
binary_dir="$app_dir/Contents/MacOS"
resources_dir="$app_dir/Contents/Resources"
mkdir -p "$binary_dir" "$resources_dir" "$build_dir/module-cache"
cp Sources/HuShell/Resources/* "$resources_dir/"

icon_png="$build_dir/HuShellIcon.png"
iconset="$build_dir/HuShell.iconset"
mkdir -p "$iconset"
CLANG_MODULE_CACHE_PATH="$build_dir/module-cache" \
  swiftc -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" \
  Assets/make-icon.swift -o "$build_dir/make-icon" -framework AppKit
"$build_dir/make-icon" "$icon_png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$icon_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
if ! iconutil -c icns "$iconset" -o "$resources_dir/HuShell.icns" 2>/dev/null; then
  # Restricted build sandboxes can block iconutil's temporary files.
  cp Assets/HuShell.icns "$resources_dir/HuShell.icns"
fi

CLANG_MODULE_CACHE_PATH="$build_dir/module-cache" \
  swiftc -O -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$build_dir/module-cache" \
  Sources/HuShell/*.swift -o "$binary_dir/HuShell" \
  -framework SwiftUI -framework AppKit

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>HuShell</string>
  <key>CFBundleDisplayName</key><string>HuShell</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
  <key>CFBundleExecutable</key><string>HuShell</string>
  <key>CFBundleIconFile</key><string>HuShell</string>
  <key>CFBundleIdentifier</key><string>com.huqixin.HuShell</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$app_dir" >/dev/null

echo "$app_dir"
