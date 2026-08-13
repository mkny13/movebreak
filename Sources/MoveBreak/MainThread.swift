import Foundation

/// Runs `work` on the main thread, immediately if already there.
///
/// Detection polling happens on a background queue, so every callback that touches AppKit
/// has to come back through here. A plain `DispatchQueue.main.async` would also work, but
/// executing inline when already on main keeps ordering intuitive — a prompt triggered
/// from a main-thread path shows up before the next statement rather than a turn later.
func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
        work()
    } else {
        DispatchQueue.main.async(execute: work)
    }
}
