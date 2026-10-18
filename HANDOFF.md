# Settings redesign work in progress

Snapshot prepared October 18, 2026 for continuing work on another computer.

- Repository: https://github.com/munchyk-loop/Trio
- Branch: `feat/settings-redesign`
- This commit preserves all current parent-repository edits, including Claude's latest rewrite of `Trio/Sources/Views/SettingsRedesign/SettingsFlowRootView.swift`. It is a work-in-progress checkpoint, not a release or a claim that search is fixed.
- The current app uses native SwiftUI `.searchable` without an `isPresented` binding. `SettingsSearchAwareContent` reads `isSearching` and uses `dismissSearch` for result navigation. Claude replaced the prior composed toolbar implementation; do not overwrite that work with the archived prototype.
- Search's desired design is a top-right search button that morphs into a field in the top navigation bar. The user reported failed cancellation/reopening and results remaining visible in prior implementations. Bottom/keyboard-mounted fields and the earlier custom appearance were rejected. Current runtime behavior still needs verification.
- The user requires strictly SwiftUI and will build/test manually in Xcode. Do not run simulators, builds, installs, debugger actions or device tests without the user's permission.
- The existing `scripts/settings-search-ui-tests` harness contains historical checks and a pre-Claude backup. Its `ProbeApp.swift` still refers to the removed `SettingsSearchToolbar` helper and must be reconciled with the current implementation before use. Tests were not run for this checkpoint.
- The prior standalone project is archived under `scripts/settings-search-ui-tests/archived-standalone`. It is separate from the current app and unverified on device.

## Restore the two LibreLoop localization edits

LibreLoop is a submodule of a separate upstream repository. To preserve its two local string-catalog edits without publishing to that upstream or changing dependency history, their complete diff is stored in `scripts/handoff/libreloop-localizations.patch`. The parent repository retains its existing LibreLoop commit.

After checking out this branch on the other computer, run from the Trio repository root:

```sh
git submodule update --init --recursive
git -C LibreLoop apply --check ../scripts/handoff/libreloop-localizations.patch
git -C LibreLoop apply ../scripts/handoff/libreloop-localizations.patch
```

This intentionally leaves those two files modified inside LibreLoop, matching the original checkout. Apply the patch only once. No build or simulator is involved.
