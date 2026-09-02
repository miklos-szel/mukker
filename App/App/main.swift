import AppKit

// The app used to be a SwiftUI `App` whose one and only scene was a
// `MenuBarExtra`. The menu bar item now hosts a calendar view, which a SwiftUI
// menu cannot do, so it is a hand-built `NSStatusItem` (see `MenuBarController`)
// and no scene is left. Everything else was already AppKit: there is no
// `WindowGroup` and deliberately no `Settings` scene — every window is an
// app-owned `NSWindow` created in `AppDelegate`.
let application = NSApplication.shared
// Top-level code is not main-actor isolated under Swift 5's minimal concurrency
// checking, but it does run on the main thread before `run()` — which is exactly
// what `assumeIsolated` asserts.
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = appDelegate
application.run()
