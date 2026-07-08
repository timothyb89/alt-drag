// Shared Accessibility helpers used by the resize engine, the move fallback,
// and the gesture-support probe.
import ApplicationServices
import CoreGraphics

func axPoint(_ e: AXUIElement, _ attr: String) -> CGPoint? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
    var p = CGPoint.zero
    guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
    return p
}

func axSize(_ e: AXUIElement, _ attr: String) -> CGSize? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
    var s = CGSize.zero
    guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
    return s
}

func setAXPoint(_ e: AXUIElement, _ attr: String, _ p: CGPoint) {
    var p = p
    if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(e, attr as CFString, v) }
}

func setAXSize(_ e: AXUIElement, _ attr: String, _ s: CGSize) {
    var s = s
    if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(e, attr as CFString, v) }
}

/// Walk up from the element under the cursor to its enclosing window.
func windowUnder(_ cursor: CGPoint) -> AXUIElement? {
    let sys = AXUIElementCreateSystemWide()
    var elt: AXUIElement?
    guard AXUIElementCopyElementAtPosition(sys, Float(cursor.x), Float(cursor.y), &elt) == .success,
          var cur = elt else { return nil }
    for _ in 0..<25 {
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &role) == .success,
           (role as? String) == (kAXWindowRole as String) { return cur }
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
              let p = parent else { return nil }
        cur = (p as! AXUIElement)
    }
    return nil
}
