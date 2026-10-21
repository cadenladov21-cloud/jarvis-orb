import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
#if DEBUG
// `-RegularPolicy YES` gives the debug build a normal app identity so screenshot tooling can see it.
app.setActivationPolicy(UserDefaults.standard.bool(forKey: "RegularPolicy") ? .regular : .accessory)
#else
app.setActivationPolicy(.accessory)
#endif
app.run()
