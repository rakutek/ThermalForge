# Security invariants

実装を変更するとき、次の不変条件を保つ。各条件には regression test を置く。

| Invariant | Verification |
| --- | --- |
| 起動時は以前の manual state を信用しない | startup recovery tests |
| automatic の確認失敗時は maximum cooling を試す | recovery ladder tests |
| recovery 中は lease を発行しない | controller state tests |
| manual control は一つの session だけが所有する | lease ownership tests |
| 別 session は active lease を暗黙に置き換えられない | lease replacement test |
| lease expiry / disconnect は automatic へ戻す | lease lifecycle tests |
| stale / missing sensor は verified Apple automatic、またはその検証失敗時に maximum cooling へ戻す | sensor fault tests |
| Apple automatic が確認済みなら over-limit sensor を理由に手動制御を奪わない | automatic thermal advisory test |
| Kaze の manual control 中に over-limit sensor を検出したら maximum cooling にする | sensor fault tests |
| thermal override は解除ヒステリシスと連続正常サンプルを満たすまで maximum cooling を維持する | thermal recovery tests |
| thermal recovery の減速中に温度が戻れば即座に maximum cooling へ戻す | thermal recovery tests |
| SMC false-success や readback mismatch を成功扱いしない | actuation fault tests |
| target/mode が正しくても実回転が猶予時間内に追従しなければ解除する | fan response test |
| RPM は全 fan の安全範囲の交差内だけを許す | RPM validation tests |
| NaN / infinity を SMC encoding へ渡さない | hardware encoding tests |
| IPC は bounded、versioned、typed である | IPC codec tests |
| unsigned production client を許可しない | packaging code-sign verification |

テスト用 hardware は failure injection を提供する。本番の安全分岐を mock 側で省略せず、write failure、read failure、false-success、stale sample、partial recovery を再現する。

次の変更は security review を必須とする。

- XPC protocol または接続許可条件
- lease duration / timer interval
- sensor の required 判定または温度上限
- automatic / maximum recovery ladder
- SMC key、data type、byte encoding
- helper entitlement、launchd plist、署名順序
