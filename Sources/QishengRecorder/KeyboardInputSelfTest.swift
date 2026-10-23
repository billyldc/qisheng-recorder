import AppKit
import Carbon
import WebKit

func checkKeyboardEventPairs() throws {
    let fixture = "Ab9!@\"'\\测e\u{301}🔒"
    try KeyboardInput.validateText(fixture)
    for character in fixture {
        let events = try KeyboardInput.character(character)
        precondition(events.map(\.type) == [.keyDown, .keyUp])
        for event in events {
            precondition(event.flags.isEmpty)
            var units = [UniChar](repeating: 0, count: 20), count = 0
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
            precondition(Array(units.prefix(count)) == Array(String(character).utf16))
        }
    }
    let delete = try KeyboardInput.key(CGKeyCode(kVK_Delete))
    precondition(delete.allSatisfy { $0.flags.isEmpty && $0.getIntegerValueField(.keyboardEventKeycode) == kVK_Delete })
    for value in ["", "a\n", "a\r", "a\t", "a\u{0}"] {
        do { try KeyboardInput.validateText(value); preconditionFailure("Control characters must not be typed") }
        catch {}
    }
}

@MainActor
func runKeyboardInputSelfTest() {
    Task { @MainActor in
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 850, height: 430), configuration: configuration)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Keyboard regression fixture (dummy credentials only)"
        window.isReleasedWhenClosed = false
        window.contentView = web
        let menu = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Keyboard fixture")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(appItem); menu.addItem(editItem); NSApp.mainMenu = menu
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.close() }
        do {
            try checkKeyboardEventPairs()
            guard AXIsProcessTrusted() else { throw RecorderError.message("Keyboard fixture requires existing Accessibility permission; no permission changes were made") }
            web.loadHTMLString("""
                <!doctype html><meta charset="utf-8"><title>Keyboard fixture</title>
                <style>body{font:18px system-ui;padding:32px}input{display:block;margin:16px;padding:8px;width:500px}</style>
                <h2>Dummy keyboard input regression</h2>
                <input id="account" value="stale account" autocomplete="off">
                <input id="password" type="password" value="stale password" autocomplete="off">
                <input id="untouched" value="untouched">
                <p id="status">Waiting for native keyboard events</p>
                <script>
                window.inputs=0;window.keys=0;window.pastes=0;window.trusted=true;window.editRanges=[];
                document.addEventListener('beforeinput',e=>editRanges.push({id:e.target.id,type:e.inputType,start:e.target.selectionStart,end:e.target.selectionEnd}));
                document.addEventListener('input',e=>{inputs++;trusted=trusted&&e.isTrusted;
                  document.querySelector('#status').textContent='Input events received: '+inputs});
                document.addEventListener('keydown',()=>keys++);
                document.addEventListener('paste',()=>pastes++);
                </script>
                """, baseURL: nil)
            var ready = false
            for _ in 0..<50 {
                if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('#account')")) as? Bool == true { ready = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard ready else { throw RecorderError.message("Keyboard fixture did not load") }
            @MainActor func validate() throws {
                let flags = CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                guard NSApp.isActive, window.isKeyWindow,
                      flags.isEmpty else {
                    throw RecorderError.message("Keyboard fixture guard: active=\(NSApp.isActive) keyWindow=\(window.isKeyWindow) physicalModifiers=\(flags.rawValue)")
                }
            }
            let account = "fixture@example.invalid", password = "Fixture!9\"'\\测e\u{301}🔒"
            for (field, value) in [("account", account), ("password", password)] {
                _ = try await web.evaluateJavaScript("document.querySelector('#\(field)').focus()")
                try await Task.sleep(for: .milliseconds(150))
                try await KeyboardInput.replaceText(value, pid: getpid(), validate: validate)
            }
            func literal(_ text: String) throws -> String {
                String(data: try JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), encoding: .utf8)!
            }
            let assertion = "document.querySelector('#account').value === \(try literal(account)) && document.querySelector('#password').value === \(try literal(password)) && document.querySelector('#untouched').value === 'untouched' && inputs >= \(account.count + password.count) && keys >= \(account.count + password.count + 2) && pastes === 0 && trusted"
            guard try await web.evaluateJavaScript(assertion) as? Bool == true else {
                throw RecorderError.message("Native per-character events did not update both reactive fields correctly")
            }
            var checks = 0
            do {
                try await KeyboardInput.replaceText("must-not-be-typed", pid: getpid()) {
                    checks += 1
                    throw RecorderError.message("Fixture focus guard")
                }
                preconditionFailure("Focus guard must stop before clearing or typing")
            } catch {}
            precondition(checks == 1)
            let cancelled = Task { try await KeyboardInput.replaceText("must-not-be-typed", pid: getpid(), validate: validate) }
            cancelled.cancel()
            do { try await cancelled.value; preconditionFailure("Cancelled typing must not post events") }
            catch is CancellationError {} catch { throw error }
            guard try await web.evaluateJavaScript(assertion) as? Bool == true else {
                throw RecorderError.message("Cancelled or guarded typing changed the fixture")
            }
            _ = try await web.evaluateJavaScript("document.querySelector('#password').focus()")
            try await Task.sleep(for: .milliseconds(150))
            guard try await web.evaluateJavaScript("document.activeElement === document.querySelector('#password')") as? Bool == true else {
                throw RecorderError.message("Mid-input fixture target could not be focused")
            }
            checks = 0
            do {
                try await KeyboardInput.replaceText("abcdefghijkl", pid: getpid()) {
                    try validate()
                    checks += 1
                    if checks == 4 { throw RecorderError.message("Fixture mid-input focus loss") }
                }
                preconditionFailure("Mid-input focus loss must stop subsequent characters")
            } catch {}
            precondition(checks == 4)
            try await Task.sleep(for: .milliseconds(250))
            guard try await web.evaluateJavaScript("document.querySelector('#password').value === 'a' && document.querySelector('#untouched').value === 'untouched' && pastes === 0") as? Bool == true else {
                let state = try await web.evaluateJavaScript("({length:document.querySelector('#password').value.length,isExpected:document.querySelector('#password').value==='a',accountIsA:document.querySelector('#account').value==='a',active:document.activeElement.id,untouched:document.querySelector('#untouched').value==='untouched',ranges:editRanges.slice(-4),inputs,keys,pastes})")
                throw RecorderError.message("Mid-input fixture state did not match: \(state)")
            }
            print("PASS: native per-character key pairs update reactive account/password fields; Unicode, clear/replace, trusted input events, no paste, focus guard and cancellation")
            NSApp.terminate(nil)
        } catch {
            fputs("Keyboard self-test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
