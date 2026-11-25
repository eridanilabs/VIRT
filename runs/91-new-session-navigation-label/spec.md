# Spec: Update the bottom navigation New Session action

## Goal
Make the bottom navigation action’s chat-session purpose clear with a chat bubble icon and the visible label “New Session.” Keep the action connected to the existing new-session flow.

## Acceptance criteria
- AC1: The bottom navigation action displays a chat bubble icon instead of the plus icon.
- AC2: Its visible label reads “New Session.”
- AC3: Tapping the action still opens the existing new-session form.

## Out of scope
- Changing the new-session form or creation behavior.
- Changing other bottom navigation items.

## Assumptions
- Use the existing `bubble.left.and.bubble.right` SF Symbol, already used elsewhere in the app for chat.

## Likely files
- `VIRT/AppNavigationView.swift`: update the bottom navigation icon and label while preserving its existing action.

## Test plan
- AC1, AC2, AC3 → simulator smoke check: confirm the icon and label, then tap the action and confirm the existing new-session form opens.

## Size estimate
Estimate: 3 code lines
- Replace the bottom navigation icon and label while keeping the existing new-session action.
