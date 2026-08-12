import CoreGraphics

/// Conical-flask geometry for the menu-bar glyph, expressed on a 24×24 canvas
/// with coordinates increasing rightward and downward from the top-left corner.
///
/// The glyph is drawn rather than shipped as a template PNG. The PNG pair this
/// replaced rendered as a solid filled square in the menu bar: template
/// rendering keys off the alpha channel alone, and both files were exported
/// fully opaque with a white background baked in, so macOS painted the whole
/// canvas with the menu-bar colour.
public enum FlaskGeometry {
    public static let canvas: CGFloat = 24
    public static let strokeWidth: CGFloat = 1.8

    /// Where the neck meets the shoulders of the cone. The liquid level is a
    /// fraction of the cone alone, so the neck is deliberately excluded.
    public static let bodyTop: CGFloat = 7.65
    public static let bodyBottom: CGFloat = 21
    public static var bodyHeight: CGFloat { bodyBottom - bodyTop }

    private static let rimY: CGFloat = 2.5
    private static let rimLeft: CGFloat = 9
    private static let rimRight: CGFloat = 15
    private static let neckLeft: CGFloat = 9.75
    private static let neckRight: CGFloat = 14.25
    private static let footRadius: CGFloat = 3

    /// The cone's left side runs from the neck through (4.8, 16.6). Extended to
    /// `bodyBottom` it meets the base here — the sharp corner the rounded foot
    /// is drawn tangent to.
    private static let footLeftX: CGFloat = {
        let run = 4.8 - neckLeft
        let rise = 16.6 - bodyTop
        return neckLeft + run * (bodyBottom - bodyTop) / rise
    }()

    private static let footRightX: CGFloat = canvas - footLeftX

    /// Rim, neck, and cone as a single strokable outline: the empty flask.
    public static func outline(scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(rimLeft, rimY, scale))
        path.addLine(to: point(rimRight, rimY, scale))

        path.move(to: point(neckLeft, rimY, scale))
        path.addLine(to: point(neckLeft, bodyTop, scale))
        addFeet(to: path, scale: scale)
        path.addLine(to: point(neckRight, bodyTop, scale))
        path.addLine(to: point(neckRight, rimY, scale))
        return path
    }

    /// The cone alone, closed — the region liquid is allowed to occupy.
    public static func body(scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(neckLeft, bodyTop, scale))
        addFeet(to: path, scale: scale)
        path.addLine(to: point(neckRight, bodyTop, scale))
        path.closeSubpath()
        return path
    }

    /// Height of the liquid surface for `level`, measured down from the top of
    /// the canvas. Levels outside 0…1 clamp rather than spilling past the cone.
    public static func surfaceY(level: CGFloat) -> CGFloat {
        bodyBottom - bodyHeight * min(max(level, 0), 1)
    }

    /// Draw the flask filled to `level` into a y-down context, using whatever
    /// fill and stroke colours the caller has already set. Kept free of AppKit
    /// so it can be drawn into a plain bitmap and counted in a test.
    public static func draw(in context: CGContext, level: CGFloat, scale: CGFloat) {
        if level > 0 {
            context.saveGState()
            context.addPath(body(scale: scale))
            context.clip()
            let surface = surfaceY(level: level) * scale
            context.fill(CGRect(
                x: 0,
                y: surface,
                width: canvas * scale,
                height: bodyBottom * scale - surface
            ))
            context.restoreGState()
        }

        context.addPath(outline(scale: scale))
        context.setLineWidth(strokeWidth * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    /// Both rounded feet and the base between them, starting from a current
    /// point on the left side of the cone and ending on the right side.
    private static func addFeet(to path: CGMutablePath, scale: CGFloat) {
        path.addArc(
            tangent1End: point(footLeftX, bodyBottom, scale),
            tangent2End: point(footRightX, bodyBottom, scale),
            radius: footRadius * scale
        )
        path.addArc(
            tangent1End: point(footRightX, bodyBottom, scale),
            tangent2End: point(neckRight, bodyTop, scale),
            radius: footRadius * scale
        )
    }

    private static func point(_ x: CGFloat, _ y: CGFloat, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }
}
