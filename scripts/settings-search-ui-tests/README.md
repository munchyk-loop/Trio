# Settings toolbar search regression

Ask the user for explicit permission before starting any simulator or running these tests. Their computer previously crashed under load. The runner uses one build job, disables parallel testing, defaults to three cycles, and stops the test process group after five minutes. Do not run alongside another build or test session.

After approval, build a current Debug simulator Trio app and run:

```sh
python3 scripts/settings-search-ui-tests/run.py --app-bundle /path/to/Trio.app --destination <simulator-UUID>
```

Requires Xcode and an installed iOS 26+ iPhone simulator. The full-app test launches Trio with a simulator-only onboarding bypass; no onboarding flags are persisted. It checks open/close behavior with empty, typed, and submitted queries, keyboard dismissal, search-result navigation, and the return of the profile and toolbar controls. Use `--cycles 15` only when a longer run is explicitly approved.

Without `--app-bundle`, the isolated helper app compiles `SettingsSearchSession`, `SettingsSearchNavigationStack`, and the search modifiers directly from `SettingsFlowRootView.swift`. Both production tab layouts now use this navigation container as the searchable owner; query and presentation are passed down to the Settings list rather than owned by that changing content. Standalone router presentations have a local fallback scope. There is no UIKit search adapter, custom search field, custom glass surface, or app-defined search animation. SwiftUI's searchable and default search toolbar item supply the native appearance and transition. Destination pages remove the inherited search item.

One presentation binding controls both the system field and results. Cancellation clears the query; selecting a result or leaving Settings also dismisses search. Keyboard submission uses the system behavior and preserves results until cancellation.

The tests find the system search field by its native accessibility type. They cover empty, typed, and keyboard-submitted queries. Keyboard Search must dismiss focus while preserving results. Close must clear the query, remove results, dismiss the keyboard, restore the search button at its original trailing anchor, and stay closed. UIKit may hide Loop Mode while search is active and restores it afterward. Endpoint assertions do not establish animation smoothness or immediate keyboard presentation; inspect those on the actual device before claiming those results.

Both modes print the test log and `.xcresult` paths. Simulator results must be reported separately from physical-device verification. `--timeout` can change the bounded duration when approved.

To generate a project without booting or installing anything, pass `--prepare-only --destination <simulator-UUID>`. Opening the generated project does not itself validate runtime behavior.

Current investigation: the navigation-scope change did not resolve cancellation on the user's device. Do not report it as fixed. In a Debug build, `[SettingsSearchTrace]` logs native binding write requests, observed presentation and environment state, search-field editing events, keyboard lifecycle, and explicit app dismissal. It records query length only, never query text. The `scope` value identifies duplicate or replaced search providers; `provider.appear version=trace-1` identifies this instrumented source. No trace observer changes focus or presentation. Release builds use the original bindings directly and omit event subscriptions and log output.

Collect the trace for both failing paths: Close while the keyboard is visible; keyboard Search followed by Close. A failed native close and a false-to-true presentation reversal must be distinguished from the recorded events rather than inferred from the animation. This instrumentation is diagnostic, not a cancellation fix.
