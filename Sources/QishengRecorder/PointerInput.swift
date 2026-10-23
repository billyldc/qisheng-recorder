import AppKit

enum PointerInput {
    case click, keepAlive

    func events(at point: CGPoint) throws -> [CGEvent] {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw RecorderError.message("无法创建鼠标输入源。")
        }
        let steps: [(CGEventType, CGPoint)]
        switch self {
        case .click:
            steps = [(.mouseMoved, point), (.leftMouseDown, point), (.leftMouseUp, point)]
        case .keepAlive:
            steps = [(.mouseMoved, CGPoint(x: point.x + 2, y: point.y)), (.mouseMoved, point)]
        }
        return try steps.enumerated().map { index, step in
            guard let event = CGEvent(mouseEventSource: source, mouseType: step.0,
                                      mouseCursorPosition: step.1, mouseButton: .left) else {
                throw RecorderError.message("无法创建鼠标输入事件。")
            }
            if self == .keepAlive {
                event.setIntegerValueField(.mouseEventDeltaX, value: index == 0 ? 2 : -2)
                event.setIntegerValueField(.mouseEventDeltaY, value: 0)
            }
            return event
        }
    }
}
