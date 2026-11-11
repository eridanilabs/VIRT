# Build r1 (claude-opus-5.5)

## Summary
VIRT now opens on a **Hosts** screen. It lists saved hosts by name, shows an empty state, has an **Add host** button in the toolbar, and you swipe to delete a host. Tapping a host opens a sheet form for adding or editing it. The form checks the URL with `HostURLPolicy` and shows a refusal or warning message. The token goes in a `SecureField`, and editing never reads the saved token. `./scripts/test.sh` passes, there are no Swift warnings, and everything is committed on `factory/11-hosts-screen-add-edit-form`.

## Changes
- `Packages/VIRTKit/Sources/VIRTKit/HostLibrary.swift`: added `update(_:)`, which checks the URL policy, replaces the saved host and returns the warning without touching its token. It follows the same steps as the existing `save(_:token:)`. I also added a new `HostLibraryError.hostNotFound`: `update(_:)` throws it for a host that was never saved, so no host can end up without a token. **The spec didn't ask for this error.**
- `Packages/VIRTKit/Tests/VIRTKitTests/HostLibraryTests.swift`: 3 tests for `update(_:)`. They reuse the file's existing `TemporaryDefaults` and `InMemoryTokenStore`.
- `VIRT/HostsViewModel.swift` (new): `@Observable` with `load()`, `isEmpty` (true only after a load), `delete(at:)` / `delete(_:)` and an `errorMessage`. `makeAddForm()` and `makeEditForm(for:)` create the form and tell it to reload the list after a save.
- `VIRT/HostFormViewModel.swift` (new):
  - Holds `name`, `urlText`, `token`, and an `add` or `edit(Host)` mode.
  - Exposes `urlError` (can't parse, or `Refusal.message`), `urlWarning` (`Warning.message`), `canSave` and `save()`. The messages show only once the URL field has text.
  - Edit mode starts with the host's name and URL and an empty token. A blank token saves through `update(_:)`; a new one through `save(_:token:)`.
  - It clears the token after a save. Its `description`, `debugDescription` and `customMirror` don't include the token, the same way `InMemoryTokenStore` hides its tokens.
- `VIRT/HostsView.swift` (new): the `List` with swipe to delete, a `ContentUnavailableView` with an **Add host** button, the toolbar **Add host** button, the form sheet, an error alert, and a `HostLibrary.preview` used only by previews.
- `VIRT/HostFormView.swift` (new): a sheet with Name and URL `TextField`s, a token `SecureField`, a URL error or warning under the fields, a "token is saved" note in edit mode, and Cancel and Save (disabled when `!canSave`). Every control has a text label, which gives it an accessible name.
- `VIRT/VIRTApp.swift`: builds one `HostLibrary(hostStore: HostStore(), tokenStore: KeychainTokenStore())` and shows `HostsView` inside a `NavigationStack` titled "Hosts".
- `VIRT/ContentView.swift`: deleted.
- `VIRTTests/HostsViewModelTests.swift` (new): 14 Swift Testing tests, `@MainActor`, using a temporary `UserDefaults` suite and a fake token store built on `InMemoryTokenStore`. The fake can fail writes or deletes and counts token reads.
- `README.md`: a short paragraph on the Hosts screen and how the token works when you edit a host.

## AC coverage
- AC1 → not covered by a test, because there are no UI tests yet. `VIRTApp` builds `NavigationStack { HostsView }`, `HostsView` sets `.navigationTitle("Hosts")`, and `ContentView.swift` is deleted.
- AC2 → `HostsViewModelTests` › `noHostsGivesTheEmptyState`, `savedHostsListByName`
- AC3 → `HostsViewModelTests` › `deleteRemovesTheHostAndItsToken`, `failedDeleteKeepsTheHostAndShowsAnError`
- AC4 → `HostsViewModelTests` › `filledAddFormCanSave`, `blankFieldsDisableSave(blank:)` (blank name, URL or add-mode token), `unparseableURLDisablesSave`
- AC5 → `HostsViewModelTests` › `refusedURLDisablesSaveAndShowsTheRefusal` (`ws://example.com`), `carrierGradeNATURLShowsTheWarningAndCanSave` (`ws://100.100.1.2`)
- AC6 → `HostsViewModelTests` › `editFormStartsWithTheHostAndNoToken`: the fields start with the host's values, the token is empty, no field contains the stored token, and the token store is never read.
- AC7:
  - `HostsViewModelTests` › `addSavesTheHostAndTokenAndReloadsTheList`, `editWithABlankTokenKeepsTheOldToken`, `editWithANewTokenReplacesIt`
  - `HostLibraryTests` › `updateReplacesHostAndKeepsToken`, `updateRefusedURLSavesNothing`, `updateOfAnUnsavedHostSavesNothing`
- AC8 → `HostsViewModelTests` › `formNeverDescribesTheToken`: `String(describing:)`, `String(reflecting:)`, `dump` and a save error message don't contain the token. **The `SecureField` part isn't tested**, because there are no UI tests. In the code, `HostFormView` takes the token only through a `SecureField`.

## Tests
`./scripts/test.sh` passes, with no failures:
- **VIRTKit (`swift test`):** 21 tests in 4 suites, 3 of them new.
- **App (`xcodebuild test`, iPhone 18 Pro simulator):** 18 tests, 14 of them new.

```
Test case 'HostsViewModelTests/editFormStartsWithTheHostAndNoToken()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (20948)' (0.094 seconds)
Test case 'HostsViewModelTests/editWithABlankTokenKeepsTheOldToken()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (20948)' (0.095 seconds)
Test case 'HostsViewModelTests/savedHostsListByName()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (20948)' (0.096 seconds)
Test case 'HostsViewModelTests/editWithANewTokenReplacesIt()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (20948)' (0.096 seconds)
Test case 'HostsViewModelTests/deleteRemovesTheHostAndItsToken()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (20948)' (0.096 seconds)
```

## Commits
- `f462327` feat(virtkit): update a saved host without touching its token (`Refs: #11`)
- `917874d` feat(app): add the Hosts screen and the add and edit host form (`Refs: #11`)

## Not done
- AC1 and the `SecureField` part of AC8 aren't tested, as above.
- Names, URLs and tokens are trimmed of leading and trailing whitespace before saving, so a pasted token with a trailing newline still works.

Nothing was pushed, and I didn't touch `.eridanilabs/autofactory/`, `.agents/`, `.github/agents/` or `apm.lock.yaml`.
