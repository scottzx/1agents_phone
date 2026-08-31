# iOS Conversation Header Layout Debug Report

- Symptom: Partner and group conversation headers first appeared too close to
  the left edge, then jumped to the desired inset after session content loaded.
  During interactive pop, the system back button did not move with the title
  and right-side actions.
- Root cause: The three header regions were separate UINavigationBar items.
  `ChatToolbarKey.messagesEmpty` changed after the asynchronous session load,
  rebuilding the whole toolbar host and causing UIKit to remeasure/reinsert the
  principal title. The system-owned back item also lived outside the destination
  content transition.
- Fix: Hide the conversation UINavigationBar and render a destination-owned
  `MinisPageHeader` through a top safe-area inset. Back, title, optional
  partner/group settings, and the chat menu now share one stable HStack. A
  zero-size UIKit bridge keeps the navigation controller's native leading-edge
  interactive-pop recognizer enabled while the visual bar is hidden. Header
  controls use plain icons with fixed hit areas rather than glass backgrounds.
- Evidence: `git diff --check` passed; the Debug iphoneos target built and
  signed successfully; the resulting app installed and launched on device
  `00008130-00063D581AFA001C`.
- Regression coverage: The layout is architectural rather than data-dependent:
  message-loading state no longer participates in header placement or toolbar
  registration. The interactive swipe was manually verified on the physical
  device after deployment.
- Status: DONE — compiled, deployed, and manually verified on the physical
  device.
