# Kaze

Kaze is a security-first fan controller for Apple Silicon Macs. The root helper owns the complete sensor-to-actuator safety loop, while the menu bar app and CLI only submit high-level intent.

> **Alpha warning:** the control logic is covered by simulation and fault-injection tests, but every new Mac model still requires hardware-in-the-loop validation before normal use. AppleSMC is an undocumented interface.

## Security model

- No raw Unix control socket and no passwordless direct SMC fallback.
- A minimal root LaunchDaemon is registered with `SMAppService` from the signed app bundle.
- XPC authenticates both sides with code-signing requirements and accepts only the active console user.
- Every non-automatic command has a short, renewable lease bound to its XPC connection.
- The helper independently samples every discovered required sensor and owns the 250 ms control loop.
- Hardware state changes are acknowledged only after SMC read-back verification.
- A failed or stale sensor returns control to verified Apple automatic mode.
- If automatic recovery cannot be verified, the helper attempts verified maximum cooling and keeps retrying.
- Helper startup and wake always re-establish a known fail-safe state before accepting control.
- Fixed-RPM requests must fit the reported range of every fan; non-finite values never reach SMC.

See [Architecture](docs/ARCHITECTURE.md), [Threat model](docs/THREAT_MODEL.md), and [Security invariants](docs/SECURITY_INVARIANTS.md).

## Build and test

Requirements: macOS 14+, Apple Silicon, Xcode with Swift 6.

```bash
swift test
swift build -c release
```

Create a development bundle that can be inspected but may not be accepted by `SMAppService`:

```bash
Scripts/package-app.sh --adhoc --output "$PWD/dist/Kaze.app"
```

Create an installable bundle with an Apple Development or Developer ID identity:

```bash
Scripts/package-app.sh \
  --identity "Apple Development: Developer Name (TEAMID)" \
  --output /Applications/Kaze.app
```

Open the app, choose **Register / Update**, and approve the background item in System Settings. The containing app must remain in `/Applications` so the boot-time helper remains available.

## CLI

The signed CLI is bundled at:

```text
/Applications/Kaze.app/Contents/Library/Utilities/kaze
```

Examples:

```bash
kaze status --json
kaze profile smart --duration 3600
kaze max --duration 600
kaze set 4000 --duration 600
kaze auto
```

Profile, maximum, and fixed-RPM commands stay alive to renew a 20-second helper lease. Normal exit, crash, or Ctrl-C closes the XPC connection and restores Apple automatic control.

## Emergency recovery

Normal commands never bypass the helper. A separate minimal executable exists for a helper outage:

```bash
sudo /Applications/Kaze.app/Contents/Library/Utilities/kaze-recovery auto
```

It supports only `auto` and `max`, validates all inputs, and verifies the resulting hardware state.

## Distribution

Official artifacts must be Developer ID signed, use Hardened Runtime, be notarized, and have the ticket stapled. Kaze deliberately does not remove quarantine attributes.

```bash
CODESIGN_IDENTITY="Developer ID Application: Developer Name (TEAMID)" \
  Scripts/package-app.sh --output "$PWD/dist/Kaze.app"
Scripts/notarize.sh "$PWD/dist/Kaze.app" NOTARY_KEYCHAIN_PROFILE
```

Do not distribute `--adhoc` bundles. See [Release process](docs/RELEASE.md).

## License

MIT. See [LICENSE](LICENSE).
