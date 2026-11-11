# Spec: Hosts screen and add/edit form

## Goal
VIRT opens on a **Hosts** screen. From there you add, edit and delete the AHP hosts it should reach. You type the token into a masked field, and VIRT never shows it again.

## Acceptance criteria
- AC1: `VIRTApp` opens on `HostsView` inside a `NavigationStack` titled "Hosts". `VIRT/ContentView.swift` is deleted.
- AC2: `HostsViewModel` loads hosts with `HostLibrary.hosts()` and lists them by `name`. With no hosts it reports the empty state, and the view shows a `ContentUnavailableView` with an **Add host** button. A toolbar **Add host** button is always available.
- AC3: Deleting a host from the list (swipe to delete) calls `HostLibrary.delete(_:)` and removes it from the list. If the delete fails, the host stays and an error message shows.
- AC4: `HostFormViewModel` has `name`, `urlText` and `token`, and runs in add mode or edit mode (for a `Host`). Save is disabled while the name is blank, while the URL is blank or won't parse, or, in add mode, while the token is blank.
- AC5: When `HostURLPolicy().evaluate(_:)` refuses the URL, save is disabled and the form shows `Refusal.message`. When the URL is accepted with `.carrierGradeNAT`, the form shows `Warning.message` and save stays enabled.
- AC6: In edit mode, the name and URL start with the host's values and `token` starts empty. The form never calls `HostLibrary.token(for:)`. It says a token is saved and offers a `SecureField` to replace it.
- AC7: Saving in add mode calls `HostLibrary.save(_:token:)`. Saving in edit mode with a non-blank token calls `save(_:token:)` with the new token. With a blank token it calls a new `HostLibrary.update(_:)`, which checks the policy and saves the host without touching its token. The Hosts list reloads after a save.
- AC8: The token field is always a `SecureField`. No view model puts the token in a `description`, a log or a message.

## Out of scope
- Connecting to a host or checking a token (#4).
- Reordering hosts, or checking whether a token works.

## Assumptions
- Every saved host has a token, because `HostLibrary` saves the host only after its token. So edit mode always says "Token saved" without reading the Keychain.
- `HostLibrary.update(_:)` is the smallest VIRTKit addition that keeps a saved token without the app reading it. It throws `HostURLPolicy.Refusal` and returns the warning, the same as `save(_:token:)`.
- The app builds one `HostLibrary(hostStore: HostStore(), tokenStore: KeychainTokenStore())` at launch and injects it into the view models.
- The form is a sheet. Any validation message shows only after the URL field has text.

## Likely files
- `VIRT/VIRTApp.swift`: builds the `HostLibrary` and shows `HostsView`.
- `VIRT/ContentView.swift`: delete it.
- `VIRT/HostsView.swift`, `VIRT/HostsViewModel.swift`: the list, the empty state and delete.
- `VIRT/HostFormView.swift`, `VIRT/HostFormViewModel.swift`: the add and edit form.
- `Packages/VIRTKit/Sources/VIRTKit/HostLibrary.swift`: add `update(_:)`.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostLibraryTests.swift`: tests for `update(_:)`.

## Test plan
All tests use Swift Testing, `InMemoryTokenStore` and a temporary `UserDefaults(suiteName:)`.
- AC2 → `VIRTTests/HostsViewModelTests.swift`: no hosts gives the empty state. Saved hosts list by name.
- AC3 → `VIRTTests/HostsViewModelTests.swift`: delete removes the host and its token.
- AC4/AC5 → `VIRTTests/HostsViewModelTests.swift`: `ws://example.com` disables save and shows `insecureHostNotAllowed.message`. `ws://100.100.1.2` enables save and shows the CGNAT warning. A blank name, URL or add-mode token disables save.
- AC6 → `VIRTTests/HostsViewModelTests.swift`: an edit-mode form for a host with a stored token has an empty `token`, and its fields don't contain the stored token.
- AC7 → `VIRTTests/HostsViewModelTests.swift`: editing with a blank token keeps the old token and saves the new name. A non-blank token replaces it.
- AC7 → `Packages/VIRTKit/Tests/VIRTKitTests/HostLibraryTests.swift`: `update(_:)` keeps the token, replaces the host and throws the refusal for a refused URL, saving nothing.

## Size estimate
Estimate: 280 code lines
- Hosts screen first, with an empty state, Add host and delete
- Add and edit form, with a masked token you can replace
