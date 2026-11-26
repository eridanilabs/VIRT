# Spec: Add a chat composer to session screens

## Goal
Send a message to or steer the session you’re viewing without leaving its chat. The composer stays above the bottom navigation.

## Acceptance criteria
- AC1: Every session chat screen shows a multiline text composer and Send action above the bottom navigation, including when the keyboard is visible.
- AC2: Send submits nonblank text to the session currently open; blank or whitespace-only text cannot be sent.
- AC3: A successful send clears the draft, and the existing live chat updates show the submitted message.
- AC4: If sending fails, the draft remains available and the screen shows a user-readable error.

## Out of scope
- Attachments, interaction-level controls, model selection, reasoning effort, and context-window controls.
- Changes to protocol or schema versions.

## Assumptions
- Send to the currently viewed session’s default chat using the pinned AHP client’s supported send operation.
- Keep sending logic in VIRTKit and surface failures without exposing host error details.

## Likely files
- `VIRT/SessionChatView.swift`: Add the composer above the bottom navigation.
- `VIRT/SessionChatViewModel.swift`: Manage the draft, submission state, and errors.
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`: Route sends through the AHP client.
- `VIRTTests/SessionChatViewModelTests.swift`: Test composer submission behavior through a fake connector.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorChatTests.swift`: Verify the outbound send targets the requested session.
- `README.md`: Remove the statement that messages cannot be sent.

## Test plan
- AC1 → `VIRTTests/SessionChatViewModelTests.swift`: Verify composer availability and placement above navigation, including with the keyboard visible.
- AC2 → `VIRTTests/SessionChatViewModelTests.swift`: Verify nonblank drafts submit to the viewed session and blank drafts do not.
- AC3 → `VIRTTests/SessionChatViewModelTests.swift`: Verify success clears the draft and live chat updates display the message.
- AC4 → `VIRTTests/SessionChatViewModelTests.swift`: Verify failure retains the draft and shows a safe error.
- AC2 → `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorChatTests.swift`: Verify the AHP send targets the requested session.

## Size estimate
Estimate: 260 code lines
- Dock a multiline composer above navigation and keep it available with the keyboard.
- Submit nonblank messages to the currently viewed session.
- Reflect successful sends through the live chat and clear the draft.
- Preserve the draft and show a safe error when sending fails.