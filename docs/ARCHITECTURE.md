# Architecture

Kaze は、ユーザーインターフェースと特権処理を分離し、安全制御を単一の状態機械へ集約する。

## Trust boundaries

```text
signed app / signed CLI
        │
        │ NSXPCConnection
        │ 相互のコード署名要件 + console user UID
        ▼
root launch daemon
        │
        ▼
SafetyController（直列化された唯一の制御主体）
        │
        ▼
AppleSMCTransport → SMC
```

UI は安全機構ではない。アプリや CLI が停止しても、helper 自身が lease、センサー鮮度、温度上限、書き込み結果を監視する。

## Targets

| Target | Responsibility | Privilege |
| --- | --- | --- |
| `KazeDomain` | 型、プロファイル、安全状態機械 | none |
| `KazeIPC` | versioned Codable protocol、XPC client、署名要件 | none |
| `KazeHardware` | SMC transport と検証付き fan hardware | root helper only |
| `KazeHelper` | authenticated XPC listener、power events | root daemon |
| `KazeApp` | Menu Bar UI と helper registration | user |
| `KazeCLI` | lease を保持する user CLI | user |
| `KazeRecovery` | 明示的な break-glass recovery | explicit `sudo` |

## Controller lifecycle

1. helper 起動直後に Apple automatic mode を書き戻し、readback で確認する。
2. automatic mode を確認できない場合は maximum cooling を書き、readback で確認する。
3. 初期 recovery が完了するまで制御 lease を発行しない。
4. 250 ms ごとに全必須センサー、lease、目標 RPM、readback を検査する。
5. manual mode へ移るには、連続した正常サンプルと有効な lease が必要になる。
6. lease expiry、client disconnect、sleep/wake、センサー異常、SMC 異常のいずれでも fail-safe ladder を実行する。

Kaze の manual control 中に温度上限へ達した場合は即座に `Safety Maximum` をラッチする。全センサーがそれぞれの上限より5°C以上低い状態を連続8サンプル確認した後だけ `Safety Cooling` へ移り、回転数を段階的に下げてから Apple automatic へ一度だけ引き渡す。冷却中に温度が戻れば、復帰判定を破棄して即座に maximum cooling へ戻る。すでに全 fan で Apple automatic が確認できている場合は、その安全制御をKazeが奪わず、温度超過を診断ログへ記録する。

```text
verified Apple automatic
          │ failed
          ▼
verified maximum cooling
          │ failed
          ▼
unrecovered fault + automatic recovery retry
```

「書き込み API が成功を返した」だけでは成功とみなさない。mode、target RPM、fan control mask を readback し、許容誤差内であることを確認する。

## Client authentication

production build では、双方が実行時に自身の Team ID を取得し、次を要求する。

- 同じ Team ID
- app / CLI / helper の正確な designated identifier
- Apple のコード署名検証を通ること

helper は加えて、接続プロセスの effective UID が `/dev/console` の所有者と一致することを要求する。identifier-only の要件は、明示された development marker がある ad-hoc build にだけ許可する。

## Lease semantics

制御権は XPC connection ごとのランダムな session ID に束縛される。lease は短時間で期限切れになり、所有 client だけが更新・変更できる。XPC connection が無効化された時点で helper は lease を破棄し、automatic mode へ戻す。

## Telemetry history

helper は、温度センサーを family ごとの最高値へ集約し、各 fan の actual / target RPM、制御 mode、fault code とともに1秒間隔でメモリへ記録する。保持期間は1時間であり、ディスクには永続化しない。

app は読み取り専用 XPC operation で 1分、5分、15分、1時間の履歴を取得する。応答は最大180点に制限し、間引き時も温度スパイク、fault、mode 遷移、fan 変化を優先して残す。最大 fan・sensor 構成の応答が 64 KiB の IPC 上限を超えないことを codec test で検証する。telemetry operation は control intent、lease、hardware state を変更しない。

## Packaged layout

```text
Kaze.app/
└── Contents/
    ├── MacOS/
    │   └── KazeApp
    ├── Resources/
    │   └── KazeHelper
    ├── Library/LaunchDaemons/
    │   └── com.producerguy.kaze.helper.plist
    └── Library/Utilities/
        ├── kaze
        └── kaze-recovery
```

helper は `SMAppService.daemon(plistName:)` だけで登録する。installer が `/Library/PrivilegedHelperTools` や `/Library/LaunchDaemons` を直接書き換える設計には戻さない。

アプリ更新で bundle が置き換わると、実行中 helper の vnode とディスク上の署名対象が一致しなくなる。helper は executable の device / inode 変更を監視し、変更を検出したら Apple automatic を復元して終了する。登録と承認は維持され、`launchd` の KeepAlive が新しい署名済み helper を起動する。クライアントは transport error や timeout の発生した XPC connection を再利用せず、登録状態を再確認しながら新しい connection を作る。
