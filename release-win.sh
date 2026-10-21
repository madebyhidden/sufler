#!/bin/bash
# Выпуск версии «Суфлёра» для Windows: сборка на Mac, подпись, публикация на GitHub.
#   ./release-win.sh 0.3.0 "Что изменилось"
# У всех, у кого стоит версия с обновлениями, появится кнопка «Обновить до 0.3.0».
set -euo pipefail
cd "$(dirname "$0")"

# Только собрать архив, ничего не публикуя: ./release-win.sh --build 0.4.0
BUILD_ONLY=0
[ "${1:-}" = "--build" ] && { BUILD_ONLY=1; shift; }
[ $# -ge 1 ] || { echo "Использование: ./release-win.sh [--build] <версия x.y.z> [\"что изменилось\"]"; exit 1; }
VERSION="$1"
NOTES="${2:-Исправления и улучшения.}"
REPO="madebyhidden/sufler"
KEY="$HOME/.sufler/update_key"
[ -f "$KEY" ] || { echo "Нет ключа подписи $KEY"; exit 1; }

PROJ="windows/Sufler.Win"
OUT="$PROJ/out"
rm -rf "$OUT"
(cd windows && python3 check-xaml.py)
dotnet publish "$PROJ" -c Release -r win-x64 --self-contained -p:Version="$VERSION" -o "$OUT" >/dev/null

# Оставляем только библиотеки для 64-битной Windows
find "$OUT/runtimes" -mindepth 1 -maxdepth 1 ! -name win-x64 ! -name vulkan -exec rm -rf {} +
find "$OUT/runtimes/vulkan" -mindepth 1 -maxdepth 1 ! -name win-x64 -exec rm -rf {} +
rm -f "$OUT"/*.pdb
cp windows/README.txt "$OUT/README.txt"

mkdir -p dist
ZIP="dist/Sufler-win-$VERSION.zip"
rm -f "$ZIP"
(cd "$OUT" && zip -qr "../../../$ZIP" .)

[ "$BUILD_ONLY" = "1" ] && { echo "Собрано: $ZIP ($(du -h "$ZIP" | cut -f1))"; exit 0; }

SIG="$(Sufler.app/Contents/MacOS/Sufler --sign "$ZIP" "$KEY")"
VERSION="$VERSION" NOTES="$NOTES" SIG="$SIG" SIZE="$(stat -f %z "$ZIP")" REPO="$REPO" python3 - <<'PY'
import json, os
v = os.environ["VERSION"]
json.dump({
    "version": v,
    "notes": os.environ["NOTES"],
    "url": f"https://github.com/{os.environ['REPO']}/releases/download/win-v{v}/Sufler-win-{v}.zip",
    "signature": os.environ["SIG"],
    "size": int(os.environ["SIZE"]),
}, open("dist/update-win.json", "w"), ensure_ascii=False, indent=2)
PY

# Выпуски для Windows не помечаем «последними»: по «последнему» выпуску обновляется версия для Mac
if gh release view "win-v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "win-v$VERSION" "$ZIP" --repo "$REPO" --clobber
else
  gh release create "win-v$VERSION" "$ZIP" --repo "$REPO" --latest=false --title "Суфлёр для Windows $VERSION" --notes "$NOTES"
fi
# Файл с номером последней версии для Windows лежит в отдельном постоянном выпуске
gh release view win-channel --repo "$REPO" >/dev/null 2>&1 || \
  gh release create win-channel --repo "$REPO" --latest=false --prerelease --title "Канал обновлений Windows" --notes "Служебный выпуск: здесь лежит файл, по которому версия для Windows узнаёт об обновлениях."
cp "$ZIP" dist/Sufler-windows.zip
# Постоянная ссылка «скачать последнюю версию для Windows» для сайта и README
gh release upload win-channel dist/update-win.json dist/Sufler-windows.zip --repo "$REPO" --clobber
echo "Выпущено: https://github.com/$REPO/releases/tag/win-v$VERSION ($(du -h "$ZIP" | cut -f1))"
