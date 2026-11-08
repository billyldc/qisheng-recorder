import AppKit
import ImageIO
import ReplayCore

@MainActor
func runTavernSelfTest() {
    do {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--tavern-self-test"), args.count == index + 3,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[index + 1]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RecorderError.message("Invalid fixture arguments") }
        let lines: [TextLine]
        switch args[index + 2] {
        case "worldCropped": lines = try Metadata.worldNavigationText(in: image, arrival: false)
        case "worldArrival": lines = try Metadata.worldNavigationText(in: image, arrival: true)
        case "worldFull", "princePrompt", "princeGreeting", "princeUnknown": lines = try Metadata.cloudNavigationText(in: image)
        default: lines = try Metadata.text(in: image)
        }
        let result: Bool
        switch args[index + 2] {
        case "world": result = TavernNavigationEvidence.worldVisible(lines) && TavernNavigationEvidence.princeNearby(lines)
        case "worldCropped": result = TavernNavigationEvidence.worldVisible(lines) && TavernNavigationEvidence.princeNearby(lines)
        case "worldArrival": result = TavernNavigationEvidence.princeNearby(lines)
        case "worldFull": result = TavernNavigationEvidence.worldVisible(lines)
        case "princePrompt": result = CloudLaunchPolicy.state(lines) == .prince
        case "princeGreeting": result = CloudLaunchPolicy.state(lines) == .princeGreeting && CloudLaunchPolicy.confirmedPrinceGreetingPoint(lines, lines) != nil
        case "princeUnknown": result = CloudLaunchPolicy.state(lines) == .unknown && CloudLaunchPolicy.hasPrinceSpeaker(lines)
        case "regions": result = TavernNavigationEvidence.regionPoint(lines) != nil
        case "cityInitial": result = TavernNavigationEvidence.isMondstadtMap(lines) && GameViewport.rgba(image).flatMap { TavernMapZoom.point(rgba: $0, width: image.width, height: image.height) } != nil
        case "city": result = TavernNavigationEvidence.isMondstadtMap(lines) && TavernNavigationEvidence.clusterPoint(lines, width: image.width, height: image.height) != nil && GameViewport.rgba(image).flatMap { TavernMapZoom.point(rgba: $0, width: image.width, height: image.height) } != nil
        case "candidates": result = TavernNavigationEvidence.tavernCandidatePoint(lines) != nil
        case "panel": result = TavernNavigationEvidence.teleportPoint(lines) != nil
        default: result = false
        }
        guard result else { throw RecorderError.message("Fixture evidence did not match \(args[index + 2])") }
        print("PASS: private tavern fixture \(args[index + 2])")
        NSApp.terminate(nil)
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

/// Reuses ordered, repeated fixture images for state transitions; it never sends input.
@MainActor
func runTavernFlowSelfTest() {
    do {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--tavern-flow-self-test"), args.count == index + 8 else {
            throw RecorderError.message("Invalid tavern flow fixture arguments")
        }
        func image(_ offset: Int) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[index + offset]) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RecorderError.message("Unable to read tavern fixture") }
            return image
        }
        let images = try (1...7).map(image)
        let texts = try images.enumerated().map { position, image in
            if position == 0 { return try Metadata.worldNavigationText(in: image, arrival: false) }
            return try position == 6 ? Metadata.cloudNavigationText(in: image) : Metadata.text(in: image)
        }
        let arrivalText = try Metadata.worldNavigationText(in: images[0], arrival: true)
        let zoomInitial = GameViewport.rgba(images[2]).flatMap { TavernMapZoom.point(rgba: $0, width: images[2].width, height: images[2].height) }
        let zoomFinal = GameViewport.rgba(images[3]).flatMap { TavernMapZoom.point(rgba: $0, width: images[3].width, height: images[3].height) }
        guard let zoomInitial, let zoomFinal else { throw RecorderError.message("Zoom fixture not recognized") }
        var flow = TavernNavigationFlow(at: 0)
        func observe(_ position: Int, _ time: Double, _ zoom: UnitPoint? = nil) -> TavernNavigationFlow.Action {
            flow.observe(texts[position], width: images[position].width, height: images[position].height, zoom: zoom, at: time)
        }
        func require(_ condition: @autoclosure () -> Bool) throws {
            guard condition() else { throw RecorderError.message("Tavern flow fixture did not match") }
        }
        let away = texts[0].filter { !$0.text.contains("小王子") && !$0.text.contains("猫之牌圣") }
        try require(flow.observe(away, width: images[0].width, height: images[0].height, zoom: nil, at: 0) == .wait &&
                    flow.observe(away, width: images[0].width, height: images[0].height, zoom: nil, at: 1) == .openMap)
        try require(observe(2, 2) == .wait)
        if case .click(_, .mapLayers) = observe(2, 3) {} else { throw RecorderError.message("Map layer fixture did not match") }
        try require(observe(1, 4) == .wait)
        if case .click(_, .mondstadt) = observe(1, 5) {} else { throw RecorderError.message("Region fixture did not match") }
        for step in 0..<8 {
            let at = 6.0 + Double(step) * 2, position = step == 0 ? 2 : 3
            let zoom = step == 0 ? zoomInitial : zoomFinal
            try require(observe(position, at, zoom) == .wait)
            if case .click(_, .zoom) = observe(position, at + 1, zoom) {} else { throw RecorderError.message("Zoom flow fixture did not match") }
        }
        try require(observe(3, 22, zoomFinal) == .wait)
        if case .click(_, .iconCluster) = observe(3, 23, zoomFinal) {} else { throw RecorderError.message("Cluster fixture did not match") }
        try require(observe(4, 24) == .wait)
        if case .click(_, .tavernCandidate) = observe(4, 25) {} else { throw RecorderError.message("Tavern candidate fixture did not match") }
        try require(observe(5, 26) == .wait)
        if case .click(_, .teleport) = observe(5, 27) {} else { throw RecorderError.message("Teleport fixture did not match") }
        try require(flow.observe(arrivalText, width: images[0].width, height: images[0].height, zoom: nil, at: 30) == .wait &&
                    flow.observe(arrivalText, width: images[0].width, height: images[0].height, zoom: nil, at: 31) == .forward)
        try require(observe(6, 32) == .wait && observe(6, 33) == .arrived)
        var nearby = TavernNavigationFlow(at: 0)
        func near(_ position: Int, _ time: Double) -> TavernNavigationFlow.Action {
            nearby.observe(texts[position], width: images[position].width, height: images[position].height, zoom: nil, at: time)
        }
        try require(near(0, 0) == .wait && near(0, 1) == .wait)
        try require(nearby.observe(arrivalText, width: images[0].width, height: images[0].height, zoom: nil, at: 4) == .wait &&
                    nearby.observe(arrivalText, width: images[0].width, height: images[0].height, zoom: nil, at: 5) == .forward)
        try require(near(6, 6) == .wait && near(6, 7) == .arrived)
        print("PASS: reordered repeated private tavern screenshots through production OCR and navigation flow; no input sent")
        NSApp.terminate(nil)
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
