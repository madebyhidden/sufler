#!/bin/bash
# Сборка «Суфлёра».
#   ./build.sh        — Sufler.app для себя: модели лежат прямо внутри бандла
#   ./build.sh --dmg  — плюс dist/Sufler-<версия>.dmg для раздачи: без больших моделей,
#                       приложение само скачает их при первом запуске
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.2.2}"
MAKE_DMG=0
[ "${1:-}" = "--dmg" ] && MAKE_DMG=1

swift build -c release

# bundle <путь к .app> <1 — класть большие модели внутрь, 0 — нет>
bundle() {
  local APP="$1" WITH_MODELS="$2"
  local C="$APP/Contents"
  mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources/Models" "$C/Resources/llama-bin"

  cp .build/release/Sufler "$C/MacOS/Sufler"
  cp Assets/AppIcon.icns "$C/Resources/AppIcon.icns"
  rsync -a --delete Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$C/Frameworks/"
  rsync -a --delete --include='llama-server' --include='*.dylib' --include='LICENSE' --exclude='*' Vendor/llama-bin/ "$C/Resources/llama-bin/"

  # Модели голоса маленькие (14 МБ) — едут с приложением всегда
  [ -d Models/voice ] && rsync -a --delete Models/voice "$C/Resources/Models/"

  if [ "$WITH_MODELS" = "1" ]; then
    # Кладём клонами APFS: внутри бандла, но без второго расхода диска
    for f in Models/*; do
      [ -f "$f" ] || continue
      # Недокачанную Gemma в бандл не кладём
      case "$(basename "$f")" in gemma-4-E4B*) [ "$(stat -f %z "$f")" -ge 4590807392 ] || { rm -f "$C/Resources/Models/$(basename "$f")"; continue; } ;; esac
      local dst="$C/Resources/Models/$(basename "$f")"
      if [ ! -f "$dst" ] || [ "$(stat -f %z "$f")" != "$(stat -f %z "$dst")" ]; then cp -c "$f" "$dst"; fi
    done
  fi

  cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Sufler</string>
	<key>CFBundleIdentifier</key><string>local.sufler.app</string>
	<key>CFBundleName</key><string>Суфлёр</string>
	<key>CFBundleDisplayName</key><string>Суфлёр</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
	<key>CFBundleDevelopmentRegion</key><string>ru</string>
	<key>LSMinimumSystemVersion</key><string>14.2</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>CFBundleDocumentTypes</key>
	<array><dict>
		<key>CFBundleTypeName</key><string>Документ</string>
		<key>CFBundleTypeRole</key><string>Viewer</string>
		<key>LSHandlerRank</key><string>None</string>
		<key>LSItemContentTypes</key><array><string>public.content</string><string>public.data</string></array>
	</dict></array>
	<key>NSMicrophoneUsageDescription</key><string>Суфлёр записывает ваш голос, чтобы расшифровывать встречу. Звук не покидает компьютер.</string>
	<key>NSAudioCaptureUsageDescription</key><string>Суфлёр записывает звук звонка, чтобы расшифровывать собеседников. Звук не покидает компьютер.</string>
</dict>
</plist>
PLIST

  # Подписываем своим сертификатом, если он есть: у всех сборок получается одно и то же удостоверение,
  # и macOS не переспрашивает доступ к микрофону и звуку после каждого обновления.
  # Без сертификата — подпись «на лету»: работает, но разрешения привязаны к конкретной сборке.
  local KC="$HOME/.sufler/signing.keychain-db"
  if [ -f "$KC" ] && [ -f "$HOME/.sufler/signing.pass" ]; then
    security unlock-keychain -p "$(cat "$HOME/.sufler/signing.pass")" "$KC"
    local ID="$(security find-identity -p codesigning "$KC" | grep -oE '[0-9A-F]{40}' | head -1)"
    codesign --force --deep --sign "$ID" --keychain "$KC" "$APP" >/dev/null 2>&1 || echo "предупреждение: подпись сертификатом не удалась"
  else
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "предупреждение: подпись не удалась"
  fi
}

bundle "Sufler.app" 1
echo "Готово: $(pwd)/Sufler.app"

if [ "$MAKE_DMG" = "1" ]; then
  STAGE="dist/stage"
  DMG="dist/Sufler-$VERSION.dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  bundle "$STAGE/Суфлёр.app" 0
  ln -s /Applications "$STAGE/Applications"
  cp Assets/README-dmg.txt "$STAGE/Как открыть.txt"
  # Архив для обновлений «по воздуху»: только приложение
  rm -f "dist/Sufler-$VERSION.zip"
  ditto -c -k --keepParent "$STAGE/Суфлёр.app" "dist/Sufler-$VERSION.zip"
  hdiutil create -volname "Суфлёр" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>&1
  rm -rf "$STAGE"
  echo "Готово: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
fi
