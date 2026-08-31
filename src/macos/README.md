# Minis for macOS

The native desktop app is built by `MinisMac.xcodeproj`. The app embeds the
`MinisRuntimeService` helper in `Contents/Helpers`; the GUI reads and writes
conversation state only through the versioned Runtime protocol.

Implemented desktop surfaces:

- native SwiftUI three-column window for conversations, agents and groups;
- Runtime-owned, versioned desktop SQLite sessions, messages, agent profiles,
  group profiles and private group-member sessions, backed by the shared
  Chat persistence value/repository contract, plus a read-only,
  transactional and idempotent importer for the legacy iOS ChatStore;
- multiple OpenAI-compatible, Anthropic, Gemini, OpenRouter, xAI and Kimi Code
  model providers with credentials in Keychain, connection testing and
  per-session bindings; OpenRouter PKCE and Kimi Code device OAuth are hosted
  by the macOS app, including single-flight Kimi token refresh;
- a shared, forward-compatible provider/model/credential value contract compiled
  by both the iOS project and the desktop Runtime;
- serial group turns and A2A resume using the shared Foundation-only group
  engine, mention router and prompts used by iOS;
- explicit workspaces and a host-shell command backend with minimal inherited
  environment, process-group cancellation, timeout and retained-output limits;
- the shared Foundation-only Agent run engine for provider → tools → provider
  cycles, with workspace-contained file tools,
  persistent SOUL/Memory/Skills context, and per-session opt-in macOS Shell
  with an explicit one-time user approval for every Agent command and a
  Runtime-owned, queryable approval/native-tool audit trail;
- a separate host PTY terminal with resize, signals and UTF-8 input/output;
- a platform-neutral ANSI screen model and selectable AppKit terminal renderer,
  including primary/alternate screens, OSC window titles and scrollback;
- independent terminal tabs and windows, including Command-J, Command-Shift-J,
  Command-K and Command-W desktop shortcuts;
- file/folder drag and drop: folders require confirmation before becoming the
  session workspace, while files remain explicit path-only context chips with
  removal and Reveal in Finder actions;
- a versioned NativeTool reverse-RPC capability matrix. The macOS host implements
  opening URLs/files, clipboard reads/writes, notifications, Calendar list/create,
  read-only Contacts search and Reminders list/create. TCC authorization is
  requested by the GUI host and remaining unavailable capabilities are reported
  explicitly instead of being exposed to the model;
- multiplexed stdio requests, cancellation, snapshots and malformed-frame
  isolation, with live sequenced Runtime events from the embedded helper;
- a single-writer Runtime lock, graceful app shutdown, one-restart safe mode,
  and persisted workspace grants.
- shared Sync V2 SessionV2/MessageV2 wire contracts with desktop export/apply,
  LWW conflict handling, unknown-field preservation, tombstones and a dirty
  queue. The embedded Runtime owns CloudKit transport scheduling, manual sync
  and status events; network sync activates only when the signed helper carries
  the configured iCloud container entitlement.

Build and test from the repository root:

```sh
swift test
xcodebuild -project src/macos/MinisMac.xcodeproj \
  -scheme MinisMac -destination 'platform=macOS,arch=arm64' \
  build CODE_SIGNING_ALLOWED=NO
```

Create an unsigned release artifact with the same inside-out packaging path
used by distribution:

```sh
zsh scripts/build_macos_release.sh --unsigned
```

For Developer ID signing or notarization, set `DEVELOPER_ID_APPLICATION` and
either `NOTARYTOOL_KEYCHAIN_PROFILE` or the documented `APPLE_*` notary
credentials, then use `--signed` or `--notarize`. Credentials are read only
from the environment/keychain and are never stored in the project.

The Debug app can use the embedded helper or fall back to an in-process direct
transport for development. Release builds require the embedded helper and fail
closed when it is missing. Distribution still requires the project's Developer
ID, provisioning profiles and notarization credentials; these secrets are
intentionally not stored in the repository.

The desktop database remains a versioned Runtime-owned store. Importing an iOS
database is one-way and never writes to the source database. Session/message
Sync V2 records share the iOS wire format. Unsigned builds deliberately fail
closed for CloudKit; live network synchronization requires the project's
container entitlement and a matching signed provisioning profile.

The shared `AgentSessionRunning` contract is now the boundary used by the iOS
agent, group, directory and subagent coordinators as well as the macOS Runtime
client. Platform presentation remains behind a small iOS adapter; neither the
high-level coordinators nor the macOS Runtime depend on `AIChatViewModel`.
