# Security policy

## Reporting a vulnerability

公開 issue に exploit details、signing information、machine identifiers を投稿しないでください。GitHub の private vulnerability reporting が利用できる場合はそれを使い、利用できない場合は repository owner へ非公開の連絡経路を依頼してください。

報告には、影響する version、macOS / hardware、再現手順、期待した fail-safe と実際の状態を含めてください。受領確認後、影響範囲と暫定 mitigation を優先して案内します。

## Supported versions

security fix は最新の release line を対象とする。非公開 SMC interface に依存するため、未検証の hardware / OS では manual control を有効にしないでください。

## Operational safety

異常な温度、fan readback mismatch、helper fault が見えた場合は profile を再適用せず、`kaze auto` を実行してください。通常 client が使えない場合に限り、bundle 内の `kaze-recovery auto` を明示的に `sudo` で実行します。
