# Release process

## Prerequisites

- Developer ID Application certificate
- notarization 用 keychain profile
- clean checkout と最新の macOS / Xcode command line tools

## Build and sign

```bash
./Scripts/package-app.sh \
  --identity "Developer ID Application: Example (TEAMID)" \
  --output "$PWD/dist/Kaze.app"
```

script は nested executables を先に、app bundle を最後に hardened runtime 付きで署名する。production package に development marker や署名緩和用 environment variable は含めない。

## Verify before upload

```bash
codesign --verify --deep --strict --verbose=2 dist/Kaze.app
codesign -dv --verbose=4 dist/Kaze.app
codesign -dv --verbose=4 \
  dist/Kaze.app/Contents/Resources/KazeHelper
plutil -lint dist/Kaze.app/Contents/Library/LaunchDaemons/com.producerguy.kaze.helper.plist
```

app と helper の Team ID、identifier、hardened runtime を確認する。

## Notarize and staple

```bash
./Scripts/notarize.sh \
  "$PWD/dist/Kaze.app" \
  kaze-notary
```

script は一時 archive を notarization service へ送信し、ticket を app に staple / validate してから最終 `Kaze.zip` を作る。Gatekeeper assessment 後に出力される `Kaze.zip.sha256` の値を公開する。

## Rollout checks

1. 未インストール環境で app の起動と helper approval を確認する。
2. helper restart 後に automatic mode から始まることを確認する。
3. app kill、CLI kill、lease expiry、sleep/wake で automatic mode に戻ることを確認する。
4. sensor read failure と SMC write failure の fault-injection test を再実行する。
5. notarized artifact の checksum を release notes に記録する。

新しい hardware family では、最初の release を automatic-only の観察対象とし、fan metadata と critical sensor inventory が妥当だと確認してから profile control を有効にする。
