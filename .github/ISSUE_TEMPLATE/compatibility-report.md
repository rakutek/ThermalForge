---
name: Compatibility Report
about: Report whether Kaze works on your Mac
title: "[Compat] Mac __ M__"
labels: compatibility
---

**Machine:** MacBook Pro M__ (year)
**macOS version:**
**Kaze version:**
**Artifact SHA-256:**

## Results

Attach the output of the signed bundled CLI. It contains temperatures and fan metadata but should not contain a serial number.

```bash
/Applications/Kaze.app/Contents/Library/Utilities/kaze status --json > status.json
```

- [ ] Notarized app passes Gatekeeper and opens
- [ ] Helper registration is enabled or the expected approval prompt appears
- [ ] `kaze status` reads every fan and discovered sensor
- [ ] A profile starts and renews its lease
- [ ] Exiting the CLI restores Apple automatic mode
- [ ] Sleep/wake restores Apple automatic mode and drops the old lease
- [ ] Menu bar app shows fan and temperature status

Do not run the recovery executable unless the normal signed helper is unavailable. Never attach signing credentials or unrelated system logs.

## Status output

<!-- Attach status.json. -->

## Notes

<!-- Include unexpected fan keys, sensor gaps, faults, or read-back mismatches. -->
