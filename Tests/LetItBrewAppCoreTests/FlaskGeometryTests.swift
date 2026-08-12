import CoreGraphics
import Testing
@testable import LetItBrewAppCore

@Test func anEmptyFlaskRestsOnTheBaseAndAFullOneReachesTheShoulders() {
    #expect(FlaskGeometry.surfaceY(level: 0) == FlaskGeometry.bodyBottom)
    #expect(FlaskGeometry.surfaceY(level: 1) == FlaskGeometry.bodyTop)
}

@Test func aLevelOutsideZeroToOneClampsInsteadOfSpillingPastTheCone() {
    #expect(FlaskGeometry.surfaceY(level: -1) == FlaskGeometry.bodyBottom)
    #expect(FlaskGeometry.surfaceY(level: 2) == FlaskGeometry.bodyTop)
}

@Test func halfFullPutsTheSurfaceAtTheMiddleOfTheConeNotTheGlyph() {
    let surface = FlaskGeometry.surfaceY(level: 0.5)
    #expect(abs(surface - (FlaskGeometry.bodyTop + FlaskGeometry.bodyHeight / 2)) < 0.0001)
    // The neck is excluded, so the surface sits below the middle of the canvas.
    #expect(surface > FlaskGeometry.canvas / 2)
}

@Test func theConeStartsBelowTheRimAndShareTheSameBase() {
    let body = FlaskGeometry.body(scale: 1).boundingBoxOfPath
    let outline = FlaskGeometry.outline(scale: 1).boundingBoxOfPath

    #expect(body.minY > outline.minY)
    #expect(abs(body.maxY - outline.maxY) < 0.0001)
}

@Test func theGlyphFitsInsideItsCanvas() {
    let outline = FlaskGeometry.outline(scale: 1).boundingBoxOfPath

    #expect(outline.minX >= 0)
    #expect(outline.minY >= 0)
    #expect(outline.maxX <= FlaskGeometry.canvas)
    #expect(outline.maxY <= FlaskGeometry.canvas)
}

/// Ink coverage at menu-bar size, as a percentage of the canvas. The glyph is a
/// template image, so this is exactly what macOS keys off: no ink means no icon.
private func inkPercent(level: CGFloat) -> Int {
    let side = 36
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let context = pixels.withUnsafeMutableBytes { buffer in
        CGContext(
            data: buffer.baseAddress,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }!
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    FlaskGeometry.draw(in: context, level: level, scale: CGFloat(side) / FlaskGeometry.canvas)

    let data = context.data!.bindMemory(to: UInt8.self, capacity: side * side * 4)
    var inked = 0
    for index in 0..<(side * side) where data[index * 4 + 3] > 0 { inked += 1 }
    return inked * 100 / (side * side)
}

@Test func anIdleFlaskStillDrawsItsOutline() {
    // The empty state is a visible outline, not a blank icon.
    #expect(inkPercent(level: 0) > 10)
}

@Test func theGlyphIsMostlyTransparentInBothStates() {
    // The bug this replaced: fully opaque art, which a template image renders
    // as a solid square.
    #expect(inkPercent(level: 0) < 60)
    #expect(inkPercent(level: 0.5) < 60)
}

@Test func anAwakeFlaskDrawsMoreInkThanAnIdleOne() {
    #expect(inkPercent(level: 0.5) > inkPercent(level: 0))
}

@Test func geometryScalesLinearlyWithTheRequestedSize() {
    let unit = FlaskGeometry.outline(scale: 1).boundingBoxOfPath
    let doubled = FlaskGeometry.outline(scale: 2).boundingBoxOfPath

    #expect(abs(doubled.width - unit.width * 2) < 0.0001)
    #expect(abs(doubled.maxY - unit.maxY * 2) < 0.0001)
}
