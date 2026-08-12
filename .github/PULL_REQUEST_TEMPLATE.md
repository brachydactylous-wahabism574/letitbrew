<!-- Feature and release-process changes need an agreed issue first.
     Bug fixes and documentation can go straight to a PR. -->

## What changes for the user

<!-- The user-visible behavior, and the failure mode this addresses. -->

Fixes #

## Tests run

- [ ] `swift test`
- [ ] `scripts/tests/upgrade-transaction-tests.sh`
- [ ] `scripts/tests/update-runner-tests.sh`
- [ ] `scripts/tests/direct-distribution-tests.sh`
- [ ] `xcodebuild ... -scheme LetItBrew -configuration Debug build`

<!-- Paste the decisive output line, not the whole log. -->

## Safety

- [ ] Does not read `SMAppService.status`
- [ ] Does not overwrite a running signed executable
- [ ] Preserves the exact readable `SleepDisabled` baseline (unreadable is an error, not `0`)
- [ ] N/A — this change does not touch power, the daemon, or the update path

## Remaining manual UAT

<!-- If this touches Sources/LetItBrewApp/, the live update path, or uninstall,
     say so — swift test does not cover those. See docs/ATTENDED-UAT.md.
     Write "none" if nothing is outstanding. -->
