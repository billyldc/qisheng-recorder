import ApplicationServices

/// AX elements may be reachable through several paths in the same browser tree.
/// Names and geometry are not identities: distinct same-named controls stay distinct.
struct AccessibilityIdentitySet {
    private var elements: [AXUIElement] = []
    var count: Int { elements.count }

    mutating func insert(_ element: AXUIElement) -> Bool {
        guard !elements.contains(where: { CFEqual($0, element) }) else { return false }
        elements.append(element)
        return true
    }
}
