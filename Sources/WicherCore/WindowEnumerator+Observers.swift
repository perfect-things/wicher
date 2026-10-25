import AppKit
// AXObserver/AXUIElement predate Sendable; they cross to the main thread here.
@preconcurrency import ApplicationServices

extension WindowEnumerator {
    // MARK: - AX observers

    private static let observerCallback: AXObserverCallback = { observer, element, notification, refcon in
        guard let refcon else { return }
        let enumerator = Unmanaged<WindowEnumerator>.fromOpaque(refcon).takeUnretainedValue()
        // A new window: watch for it closing. Registering is a round trip to
        // the app — awake, since it just made the window, but possibly busy —
        // and this is the main thread, so it goes to the scan queue.
        if (notification as String) == kAXWindowCreatedNotification {
            let timeout = enumerator.backgroundTimeout
            let refconBits = UInt(bitPattern: refcon)   // a raw pointer isn't Sendable; its bits are
            enumerator.scanQueue.async {
                guard let refcon = UnsafeMutableRawPointer(bitPattern: refconBits) else { return }
                observeDestruction(of: [element], with: observer, refcon: refcon, timeout: timeout)
            }
        }
        // The element names the app it belongs to, with no round trip, so
        // only that app needs asking again.
        var pid: pid_t = 0
        let known = AXUIElementGetPid(element, &pid) == .success
        // The observer's run-loop source is on the main run loop.
        MainActor.assumeIsolated {
            if known {
                enumerator.scheduleRefresh(pid: pid, after: 0.15)
            } else {
                enumerator.scheduleRefresh(after: 0.15)
            }
        }
    }

    /// Registers `kAXUIElementDestroyedNotification` on each window, so closing
    /// one triggers a refresh. The registration dies with the window. Each
    /// registration is a round trip to the app, bounded by `timeout`.
    private static func observeDestruction(of windows: [AXUIElement],
                                           with observer: AXObserver,
                                           refcon: UnsafeMutableRawPointer,
                                           timeout: TimeInterval) {
        for window in windows {
            AXUIElementSetMessagingTimeout(window, Float(timeout))
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
        }
    }

    @MainActor func installObservers(for apps: [NSRunningApplication]) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let apps = apps
            .filter { $0.activationPolicy != .prohibited && !$0.isTerminated && $0.processIdentifier != selfPID }
            .filter { observers[$0.processIdentifier] == nil }
        guard !apps.isEmpty else { return }

        // Attaching to a sleeping app can block, so do it off the main thread.
        scanQueue.async { [weak self] in
            guard let self else { return }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for app in apps {
                let pid = app.processIdentifier
                var observer: AXObserver?
                guard AXObserverCreate(pid, Self.observerCallback, &observer) == .success,
                      let observer else { continue }
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, Float(self.backgroundTimeout))
                var attached = false
                for name in Self.observedNotifications {
                    if AXObserverAddNotification(observer, axApp, name as CFString, refcon) == .success {
                        attached = true
                    }
                }
                guard attached else { continue }
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                   let windows = value as? [AXUIElement] {
                    Self.observeDestruction(of: windows, with: observer, refcon: refcon,
                                            timeout: self.backgroundTimeout)
                }
                DispatchQueue.main.async {
                    // The app may have quit while we were attaching; its
                    // `removeObserver` has already run, and storing this one
                    // would block a later app that reuses the pid.
                    guard self.observers[pid] == nil, !app.isTerminated else { return }
                    self.observers[pid] = observer
                    CFRunLoopAddSource(CFRunLoopGetMain(),
                                       AXObserverGetRunLoopSource(observer),
                                       .defaultMode)
                }
            }
        }
    }

    @MainActor func removeObserver(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(observer),
                              .defaultMode)
    }
}
