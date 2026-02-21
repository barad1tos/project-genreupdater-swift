# NSUserAppleScriptTask Justification

## Why NSUserAppleScriptTask Is Required

Genre Updater reads and writes metadata in Apple Music (Music.app).
MusicKit provides read-only access to the user's library but
**offers no API for writing** track properties such as genre or year.

The only supported mechanism for a sandboxed Mac app to modify
Music.app metadata is AppleScript sent via the `scripting-targets`
entitlement. `NSUserAppleScriptTask` is Apple's documented approach
for running AppleScript from within an App Sandbox.

## Scripts Used

| Script | Purpose |
|--------|---------|
| `fetch_tracks_by_ids.scpt` | Read track metadata by persistent ID |
| `fetch_track_ids.scpt` | Enumerate all track IDs in the library |
| `update_property.scpt` | Set a single property (genre, year) |
| `batch_update_tracks.scpt` | Batch-update multiple tracks |
| `check_music_running.scpt` | Verify Music.app is running |

All scripts are pre-compiled `.scpt` files installed into
`~/Library/Application Scripts/<bundle-id>/` during onboarding.
The user is shown a consent dialog before installation.

## Security Measures

1. **InputSanitizer** validates every argument before it reaches
   AppleScript. It blocks 10 categories of dangerous patterns
   including `do shell script`, `tell application "Finder"`,
   `load script`, `open location`, `keystroke`, etc.

2. **escapeStringValue** escapes quotes and backslashes in
   user-provided data (track names, album titles) to prevent
   injection into AppleScript string literals.

3. **sanitizeScriptCode** strips shell metacharacters
   (`;|&` `` ` `` `$(){}`) from code fragments.

4. **validateScriptCode** rejects any code matching dangerous
   AppleScript patterns via case-insensitive regex.

5. **Actor serialization** (`AppleScriptBridge` actor) ensures
   only one script executes at a time, preventing race conditions.

6. Scripts are compiled (`.scpt`), not plain text. The app never
   constructs AppleScript source at runtime.

## Apple Documentation References

- [NSUserAppleScriptTask](https://developer.apple.com/documentation/foundation/nsuserapplescripttask)
- [App Sandbox: Scripting Other Apps](https://developer.apple.com/documentation/security/app-sandbox#Scripting-Other-Apps)
- [com.apple.security.scripting-targets](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_scripting-targets)
