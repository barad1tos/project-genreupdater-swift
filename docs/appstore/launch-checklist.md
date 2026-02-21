# Launch Checklist — Genre Updater v1.0

## Automated (CI-verifiable)

- [ ] `swift build` succeeds for Core, Services, SharedUI
- [ ] `xcodebuild build` succeeds (unsigned)
- [ ] Core test suite passes (≥85% coverage)
- [ ] Services test suite passes (≥65% coverage)
- [ ] InputSanitizer 100% function coverage
- [ ] SwiftLint `--strict`: 0 violations
- [ ] SwiftFormat `--lint`: 0 violations
- [ ] Periphery: no unused code (with `--retain-public`)
- [ ] os_signpost markers in 8 critical paths
- [ ] Performance regression tests establish baselines
- [ ] Parity tests pass (genre + year fixtures)
- [ ] CI pipeline green on dev branch

## Manual — Developer Account

- [ ] Apple Developer Program membership active
- [ ] App ID registered in Developer Portal
- [ ] Provisioning profile created (Mac App Store)
- [ ] Signing certificate installed (distribution)
- [ ] iCloud container configured for KVS

## Manual — App Store Connect

- [ ] App record created in App Store Connect
- [ ] Bundle ID matches project configuration
- [ ] App name reserved: "Genre Updater"
- [ ] Primary language: English (U.S.)
- [ ] Category: Music
- [ ] Age rating: 4+ (no objectionable content)
- [ ] Pricing: Free with in-app purchases
- [ ] In-app purchases are configured:
  - [ ] Week Pass ($1.99, non-renewing, 7 days)
  - [ ] Pro Monthly ($4.99/mo, auto-renewable)
  - [ ] Pro Annual ($29.99/yr, auto-renewable)
- [ ] StoreKit configuration file matches Connect

## Manual — Content

- [ ] App Store description uploaded
- [ ] Keywords set (100 chars max)
- [ ] Screenshots uploaded:
  - [ ] 1280x800 (13-inch Mac)
  - [ ] 2880x1800 (16-inch Retina)
- [ ] App icon (1024x1024, no transparency)
- [ ] Privacy Policy URL set and accessible
- [ ] Support URL set
- [ ] Marketing URL (optional)

## Manual — Review Preparation

- [ ] Review notes written (NSUserAppleScriptTask)
- [ ] Justification document attached
- [ ] Demo video recorded (optional but recommended)
- [ ] Entitlements explanation included
- [ ] Sandbox test account credentials provided

## CI/CD Strategy

GitHub Actions is the primary CI (lint, test, coverage, build).
Xcode Cloud is used only for distribution: automatic archive + TestFlight upload
on tagged releases. This uses the free tier (25 hours/month with Apple Developer Program).

- [ ] Xcode Cloud workflow configured for archive + TestFlight
- [ ] Trigger: tag push matching `v*` pattern
- [ ] Distribution: TestFlight (internal + external)

## Manual — TestFlight

- [ ] Archive uploaded via Xcode Cloud (or manual Xcode upload)
- [ ] Build processing complete (no issues)
- [ ] Internal testing group created
- [ ] At least 1 week of internal testing
- [ ] External testing group created (optional)
- [ ] At least 2 weeks of beta testing
- [ ] No critical bugs in beta feedback
- [ ] Export compliance: No (no encryption)

## Manual — Submission

- [ ] Select a build in App Store Connect
- [ ] All metadata fields are complete
- [ ] Submit for App Review
- [ ] Monitor review status
- [ ] Respond to reviewer questions (if any)
- [ ] If rejected: address feedback, resubmit
- [ ] Approved: set the release date or release immediately

## Post-Launch

- [ ] Monitor crash reports (Xcode Organizer)
- [ ] Monitor App Review ratings
- [ ] Respond to user reviews
- [ ] Plan v1.1 based on feedback
