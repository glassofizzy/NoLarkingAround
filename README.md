# No Larking Around

A full-screen meeting takeover for **Lark Calendar** on macOS — the thing
[inyourface.app](https://www.inyourface.app/) does for Google/Outlook/iCloud, which
do not include Lark.

A menu-bar agent polls your Lark calendar through `lark-cli` and, a few minutes
before each real meeting, blocks every display with a full-screen takeover so you
can't miss it.

**[Screenshot: full-screen takeover — meeting title, time, room, attendees, Join button]**

![Takeover design render](takeover-render.png)

**[Screenshot: menu bar dropdown — next meeting countdown, pause / lead-time / test-takeover / re-auth actions]**

## Features

- **Full-screen, unmissable.** One borderless window per display, above fullscreen apps.
- **Smart filtering.** Skips all-day events, declined invites, solo blocks (no other
  attendee), and anything matching your ignore-keyword list — so "Lunch" and "Focus
  block" never take over the screen.
- **Fires twice, safely.** A lead-time alert before the meeting, and a fallback at
  the start time if you missed the first one — deduplicated per occurrence.
- **Clash-aware.** Shows what else is competing for that slot.
- **Sleep-safe.** A fire time that passed while the Mac was asleep is skipped, not
  fired late in a burst.
- **Fail-open.** If the attendee lookup can't be performed, it alerts anyway — a
  lookup failure must never cause a missed meeting.

## Build

```bash
./build.sh          # produces NoLarkingAround.app — needs only Command Line Tools
```

No Xcode project, no SwiftPM, no third-party dependencies.

> **Note:** on recent Swift toolchains, building needs a full Xcode.app install —
> not just Command Line Tools. `TakeoverView.swift` uses SwiftUI property wrappers
> (`@State`, `.onReceive`, `.onHover`) that compile through a macro plugin
> (`SwiftUIMacros`) that ships inside Xcode.app, not with standalone CLT. If
> `./build.sh` fails with `external macro implementation type ... could not be
> found`, run `xcode-select -s /Applications/Xcode.app` (installing Xcode first if
> you don't have it) and try again.

## Run

```bash
open NoLarkingAround.app             # menu-bar agent, no dock icon
./install-login-item.sh             # optional: start at login
```

The status item shows the next meeting (`◷ 12m · Metric Tree`) and offers pause,
lead time, a test takeover, and re-authentication.

**⌥⌘P pauses alerts for an hour.** Use it before you present — see Limitations.

## Verify

```bash
./nolarkingaround --selftest        # 30 checks: alert lifecycle, room parsing, filters
./nolarkingaround --print-agenda    # next 18h, with each event's alert/skip verdict
./nolarkingaround --print-agenda --explain <event_id>    # raw attendee response
./nolarkingaround --snapshot out.png --lead 15 --minutes 3 --scale 1   # design QA
```

`--snapshot` renders offscreen, so design work never hijacks your display. The
render is pixel-identical to the reference prototype (verified band-by-band).

## Behaviour

| Action | Effect |
|---|---|
| **Join call** | Opens the Lark VC link, closes the takeover, no re-fire |
| **Dismiss** | Kills that occurrence — no at-start re-fire |
| **Snooze → until it starts** | Hidden until the start time, then shown again |
| Ignored | Stays up through the start, auto-clears 2 min after |

An event produces a takeover when it is busy, not declined, not all-day, not
matched by an ignore keyword, has at least one other human attendee, and you have
accepted it. If the attendee lookup fails the event **still alerts** — a lookup we
cannot perform must never cause a missed meeting.

## Config — `~/.config/nolarkingaround/config.json`

Any subset of keys is valid; absent keys keep their defaults.

```json
{
  "leadMinutes": 3,
  "alsoAtStart": true,
  "autoClearSeconds": 120,
  "pollSeconds": 60,
  "requireOtherAttendees": true,
  "requireAccepted": true,
  "attendeeCacheSeconds": 300,
  "roomPriority": ["CPT"],
  "ignoreKeywords": ["lunch", "focus", "block", "hold", "ooo"],
  "quietHours": { "start": "22:00", "end": "08:00" },
  "soundName": "Submarine",
  "larkCLIPath": "/opt/homebrew/bin/lark-cli"
}
```

`requireAccepted: false` also alerts on meetings you have not answered yet.

`roomPriority` decides which room to show when an event books several offices
at once — the first room whose name contains the earliest-listed pattern wins.
Default `["CPT"]` prefers Capital Tower in Singapore over a Jakarta room.

## Diagnosing a missed alert

If a takeover didn't fire when you expected it to, check `/tmp/nolarkingaround.err`
(the login-item's stderr) for a timestamped trace of pause/resume toggles, blocked
fires (already-showing takeover, paused, or quiet hours), and successful fires.
`./nolarkingaround --print-agenda` shows the same verdict logic for the next 18h,
but only looks forward from "now" — it won't explain a meeting that already passed.

## Limitations

- **Screen sharing.** A takeover mid-presentation broadcasts the meeting title,
  attendee names and your clash to everyone watching. macOS exposes no reliable
  "am I sharing" signal to an agent like this, so the mitigation is manual: ⌥⌘P, or
  Pause from the menu.
- **Lark token.** `lark-cli` refreshes automatically, but the refresh grant expires
  periodically; after that the calendar is unreadable until `lark-cli auth login` is
  re-run. The menu bar shows ⚠️ rather than failing silently.
- **Mac must be awake.** Fire times that passed while asleep are skipped rather
  than firing a burst of stale takeovers.
- **Unsigned.** Ad-hoc signed, so it runs locally without a Gatekeeper prompt, but
  it is not notarised and not distributable to teammates as-is.
- **iOS.** The handoff's phone frames are not built. `MeetingAlert` is deliberately
  platform-agnostic so a port is view code only.

## Layout

```
Sources/
  main.swift            CLI dispatch; default mode runs the agent
  App.swift             Menu bar, ⌥⌘P hot key, actions
  AlertScheduler.swift  Fire times, dismiss/snooze/auto-clear, pause, quiet hours
  EventStore.swift      Poll, classify, attendee cache, clash detection
  MeetingAlert.swift     View model + room parsing + formatting (no AppKit)
  TakeoverView.swift    The design, recreated in SwiftUI
  TakeoverWindow.swift  One borderless window per display, above fullscreen
  DesignTokens.swift    Colours, fonts, variable-axis weight selection
  LarkClient.swift      lark-cli over Process, envelope decoding
  Models.swift          Lark wire types
  Config.swift          Settings, partial-file tolerant
  SelfTest.swift        Virtual-clock lifecycle checks
Resources/Fonts/        Schibsted Grotesk + JetBrains Mono (OFL, licences included)
```

Fonts are OFL-licensed; their licence files ship in `Resources/Fonts/`.

## License

MIT — see [LICENSE](LICENSE). The bundled fonts (Schibsted Grotesk, JetBrains
Mono) are separately OFL-licensed; see `Resources/Fonts/` for their license
files.
