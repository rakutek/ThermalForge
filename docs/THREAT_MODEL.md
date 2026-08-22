# Threat model

## Protected assets

- ファンと温度制御の安全な状態
- root helper の権限境界
- SMC への書き込み整合性
- ユーザーが選択した一時的な制御 intent
- 配布物の真正性

## Adversaries in scope

- 同一ユーザー権限で動く未署名または別署名のプロセス
- XPC endpoint を発見し、任意の request を送ろうとするプロセス
- malformed、oversized、直近で重複・replay された request、out-of-version の request
- UI / CLI crash、強制終了、sleep/wake、helper restart
- SMC の read/write failure、false-success、readback mismatch
- センサー欠落、stale sample、非有限値、異常値
- dependency や CI workflow の意図しない更新

同一ユーザーであることだけを信頼しない。接続はコード署名 identity と console owner UID の両方で制限する。

## Safety assumptions

- Apple automatic mode は通常時の第一 fail-safe である。
- automatic mode を検証できない場合、検証済み maximum cooling の方が停止・低速固定より安全である。
- 必須センサーの値を安全と証明できなければ、manual control を続けない。
- 最低 RPM は機種固有 SMC metadata の交差範囲から決め、推測値を使わない。
- root helper は network listener、shell execution、任意 file write を持たない。

## Explicitly out of scope

- kernel / SMC firmware compromise
- root または同じ Team ID の signing key を奪った攻撃者
- 物理的な故障で fan が指示どおり回らないケースの修理
- Apple が非公開 SMC interface を変更した後の互換性保証

ただし hardware readback mismatch は検出し、fail-safe へ移行する。

## Main mitigations

| Threat | Mitigation |
| --- | --- |
| arbitrary local XPC client | mutual code-signing requirements、exact identifiers、console UID |
| stale or abandoned manual setting | renewable connection-bound lease |
| crash / disconnect | invalidation handler restores automatic mode |
| malformed IPC | 64 KiB limit、strict Codable envelope、protocol version |
| duplicated request | connection-local bounded replay window |
| unsafe RPM | per-fan validated limits and their intersection |
| partial or false-success SMC write | serialized writes plus readback verification |
| missing thermal signal | all discovered critical sensors are required and freshness checked |
| production bypass of signatures | development exception requires explicit marker and is omitted from signed release |
| release tampering | hardened runtime signing、notarization、stapling、SHA-256 publication |

## Residual risks

SMC は公開された安定 API ではないため、OS・hardware 世代による挙動差が残る。初めて対応する機種では automatic-only の観察期間を設け、sensor inventory と readback を採取してから manual profile を有効にする運用が望ましい。

署名済み client 自体が侵害された場合、短い lease の範囲で control request を送れる。helper 内の temperature guard、RPM bounds、readback verification はその場合も解除されない。
