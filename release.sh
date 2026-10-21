#!/bin/bash
# Выпуск новой версии «Суфлёра»: сборка, подпись, публикация на GitHub.
#   ./release.sh 0.3 "Что изменилось — одной-двумя строками"
# После этого у всех, у кого стоит версия с обновлениями, появится кнопка «Обновление 0.3».
set -euo pipefail
cd "$(dirname "$0")"

[ $# -ge 1 ] || { echo "Использование: ./release.sh <версия> [\"что изменилось\"]"; exit 1; }
export VERSION="$1"
NOTES="${2:-Исправления и улучшения.}"
REPO="madebyhidden/sufler"
KEY="$HOME/.sufler/update_key"
[ -f "$KEY" ] || { echo "Нет ключа подписи $KEY — без него обновления не примутся."; exit 1; }

./build.sh --dmg
ZIP="dist/Sufler-$VERSION.zip"
DMG="dist/Sufler-$VERSION.dmg"
# Постоянное имя для ссылки «скачать последнюю версию» на сайте и в README
LATEST_DMG="dist/Sufler-mac.dmg"

# Подпись архива: приложение установит только то, что подписано этим ключом
SIG="$(Sufler.app/Contents/MacOS/Sufler --sign "$ZIP" "$KEY")"
SIZE="$(stat -f %z "$ZIP")"
VERSION="$VERSION" NOTES="$NOTES" SIG="$SIG" SIZE="$SIZE" REPO="$REPO" python3 - <<'PY'
import json, os
v = os.environ["VERSION"]
json.dump({
    "version": v,
    "notes": os.environ["NOTES"],
    "url": f"https://github.com/{os.environ['REPO']}/releases/download/v{v}/Sufler-{v}.zip",
    "signature": os.environ["SIG"],
    "size": int(os.environ["SIZE"]),
}, open("dist/update.json", "w"), ensure_ascii=False, indent=2)
PY

if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  # Версия уже выпущена — заменяем файлы (перевыпуск с исправлением)
  cp "$DMG" "$LATEST_DMG"
  gh release upload "v$VERSION" "$ZIP" "$DMG" "$LATEST_DMG" dist/update.json --repo "$REPO" --clobber
else
  cp "$DMG" "$LATEST_DMG"
  gh release create "v$VERSION" "$ZIP" "$DMG" "$LATEST_DMG" dist/update.json --repo "$REPO" --title "Суфлёр $VERSION" --notes "$NOTES"
fi
echo "Выпущено: https://github.com/$REPO/releases/tag/v$VERSION"
