# InAppDriver — drive a debug iOS app's screen from the Mac, no test runner

InAppDriver is a small **debug-only** HTTP endpoint that lives inside your app. A tool on the Mac (a
script, an AI agent) can read what is on screen, tap, scroll, type and take a screenshot on a
**real device** — without installing or signing WebDriverAgent or any other UI-test runner. If the
app builds, the control is there.

It pairs naturally with [Mirage](https://github.com/tedKim5178/mirage-ios) (mock the server, then
*look* at the result), but it does not depend on it. No third-party dependencies.

## Install

Add the package to the app target and start it in debug builds:

```swift
#if DEBUG
import InAppDriver
#endif

func application(_ application: UIApplication, didFinishLaunchingWithOptions …) -> Bool {
    #if DEBUG
    InAppDriver.start()          // loopback 127.0.0.1:8081
    #endif
    …
}
```

`InAppDriver.stop()` shuts it down; `start()` can be called again. In release builds every call is a
no-op and the server code is compiled out.

## Use

On a real device forward the port over USB (`brew install libimobiledevice`); on the Simulator the
port is reachable directly.

```bash
iproxy 8081 8081 &
curl -s localhost:8081/status                              # {"ok":true,"ui":true}
curl -s localhost:8081/ui                                  # what is on screen, and where
curl -s -X POST "localhost:8081/ui/tap?x=196&y=743"        # activate the element at that point
curl -s -X POST "localhost:8081/ui/swipe?x1=200&y1=600&x2=200&y2=300"   # scroll down
curl -s -X POST localhost:8081/ui/type --data-binary "hello"            # into the focused field
curl -s -o screen.png localhost:8081/ui/screenshot
```

| Route | What it does |
|---|---|
| `GET /status` | `{"ok":true,"ui":true}` — `ui` is `false` where there is no UIKit (macOS) |
| `GET /ui` | `{"screen":{w,h,scale},"elements":[…]}` — each element has `type`, `label`, optional `value`/`id`/`traits`, frame `x`/`y`/`w`/`h`, and `cx`/`cy` (the point to tap). Back-to-front order |
| `POST /ui/tap?x=&y=` | Activates the element under the point → `{"done":"…"}` |
| `POST /ui/swipe?x1=&y1=&x2=&y2=` | Scrolls the scroll view under the start point by the drag distance |
| `POST /ui/type` | Inserts the request body into the focused text input (tap the field first) |
| `GET /ui/screenshot` | PNG of the app's windows, at screen scale |

Coordinates are screen **points**; screenshot pixels are `scale`× larger. Read `/ui` again after
every tap. `422` means the request was delivered but nothing at that point could be tapped or
scrolled; `503` means the main thread did not answer in time (or the server is stopping).

## Limits — it runs inside the app

- **Only this app's windows.** No system alerts, permission prompts, keyboard, home screen, or other apps.
- **A tap activates, it does not touch.** The element under the point is triggered through its
  control action, accessibility activation, table/collection cell selection, or a tap recognizer's
  action. Views that only respond to a custom gesture (e.g. a SwiftUI `Image` with `.onTapGesture`
  and no accessibility action), drags and long-presses are out of reach. `swipe` only moves scroll views.
- **Screenshots are rendered in-process.** `AVPlayerLayer` video is filled in with a still of the
  current frame (local assets only); Metal, camera previews and some web views may come out blank.
- **Private symbols, debug builds only.** SwiftUI builds its accessibility tree only when the system
  says an assistive client is listening, so the first screen call flips the "automation enabled"
  switch via `libAccessibility` symbols resolved at runtime (the same switch UI-test frameworks
  use). The tap-recognizer fallback reads UIKit's private target list. If either is missing on some
  OS version it fails soft: plain UIKit views are still listed and tappable.
- **Loopback only, but shared.** The server binds `127.0.0.1` — not reachable over Wi-Fi, no Local
  Network prompt — yet other apps on the same device can reach loopback. It can read on-screen text
  and type, so keep it to debug builds on test devices and test accounts.

Verified on a real device with iOS 26.6 (SwiftUI + UIKit screens). Not yet exercised on the
Simulator, on iPad multi-window, or on iOS 14–18.
