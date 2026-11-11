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
        func require(_ condition: @autoclosure () -> Bool) throws {
            guard condition() else { throw RecorderError.message("Tavern assistance fixture did not match") }
        }
        // These seven historical images are not an outdoor navigation recording.
        // Keep their OCR checks, but never synthesize an imaginary successful route.
        for position in 1...5 {
            var map = TavernNavigationFlow(at: 0)
            _ = map.observe(texts[position], width: images[position].width, height: images[position].height, zoom: nil, at: 0)
            guard case .needsAssistance = map.observe(texts[position], width: images[position].width,
                height: images[position].height, zoom: nil, at: 26) else {
                throw RecorderError.message("Historical map screenshot incorrectly authorized navigation")
            }
        }
        var nearby = TavernNavigationFlow(at: 0)
        try require(nearby.observe(arrivalText, width: images[0].width, height: images[0].height, zoom: nil, at: 0) == .wait)
        try require(nearby.observe(arrivalText, width: images[0].width, height: images[0].height, zoom: nil, at: 1) == .wait)
        try require(nearby.observe(arrivalText, width: images[0].width, height: images[0].height, zoom: nil, at: 4) == .wait)
        try require(nearby.observe(arrivalText, width: images[0].width, height: images[0].height, zoom: nil, at: 5) == .forward)
        try require(nearby.observe(texts[6], width: images[6].width, height: images[6].height, zoom: nil, at: 6) == .wait)
        try require(nearby.observe(texts[6], width: images[6].width, height: images[6].height, zoom: nil, at: 7) == .arrived)
        _ = zoomInitial; _ = zoomFinal
        print("PASS: private screenshot OCR and assistance/nearby flow; not an outdoor navigation test; no input sent")
        NSApp.terminate(nil)
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
