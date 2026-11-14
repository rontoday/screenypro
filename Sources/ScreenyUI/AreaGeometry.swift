import CoreGraphics
import Foundation

/// Pure math for the display area (capture crop): clamping, aspect lock, picker drag/resize and
/// coordinate conversion. No AppKit, so it can be checked in isolation.
///
/// Coordinate spaces:
/// - **Display rect**: points, relative to one display, origin TOP-left (what `CaptureConfig.cropRect` takes
///   and what is persisted).
/// - **AppKit global**: points, origin bottom-left of the primary display, y up (`NSScreen.frame`, window frames).
///   A secondary display left of or below the primary display has a negative origin.
enum AreaGeometry {
    /// Smallest area side in points (the capture module treats smaller areas as "whole display").
    static let minimumSide: CGFloat = 64

    // MARK: Coordinate conversion

    /// Display rect (top-left origin) → AppKit global rect, for a display whose `NSScreen.frame` is `screenFrame`.
    static func appKitRect(fromDisplayRect rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + rect.minX,
               y: screenFrame.maxY - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// AppKit global rect → display rect (top-left origin) of the display whose `NSScreen.frame` is `screenFrame`.
    static func displayRect(fromAppKitRect rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX - screenFrame.minX,
               y: screenFrame.maxY - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    // MARK: Clamping and aspect

    /// Keeps the rect inside a display of `size`: a rect larger than the display is cut to it,
    /// a rect partly outside is moved in (its size kept).
    static func clamp(_ rect: CGRect, to size: CGSize) -> CGRect {
        let r = rect.standardized
        let width = min(max(r.width, 0), size.width)
        let height = min(max(r.height, 0), size.height)
        let x = min(max(r.minX, 0), size.width - width)
        let y = min(max(r.minY, 0), size.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The largest rect of `aspect` (width / height) that fits a display of `size`, centered.
    static func defaultArea(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        var height = size.height
        var width = height * aspect
        if width > size.width {
            width = size.width
            height = width / aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// True when the rect already has `aspect` (relative tolerance).
    static func hasAspect(_ rect: CGRect, _ aspect: CGFloat, tolerance: CGFloat = 0.004) -> Bool {
        guard rect.height > 0, aspect > 0 else { return false }
        return abs(rect.width / rect.height - aspect) / aspect <= tolerance
    }

    /// Fits a saved area to a new aspect: keeps its center and width and changes the height.
    /// When the new height does not fit the display, the height becomes the display height and the width follows.
    /// The result is clamped into the display.
    static func adjust(_ rect: CGRect, toAspect aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0 else { return clamp(rect, to: size) }
        var width = min(rect.width, size.width)
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        let adjusted = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        return clamp(adjusted, to: size)
    }

    /// The area to capture for a saved rect: clamped, and in a locked aspect when `aspect` is set.
    static func effectiveArea(saved: CGRect, aspect: CGFloat?, in size: CGSize) -> CGRect {
        guard let aspect else { return clamp(saved, to: size) }
        if hasAspect(saved, aspect) {
            let clamped = clamp(saved, to: size)
            if hasAspect(clamped, aspect) { return clamped }
        }
        return adjust(saved, toAspect: aspect, in: size)
    }

    // MARK: Picker interaction (flipped view coordinates: y grows downward)

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// -1 = left/top edge moves, +1 = right/bottom edge moves, 0 = that axis does not move.
        var dx: CGFloat {
            switch self {
            case .topLeft, .left, .bottomLeft: return -1
            case .topRight, .right, .bottomRight: return 1
            case .top, .bottom: return 0
            }
        }

        var dy: CGFloat {
            switch self {
            case .topLeft, .top, .topRight: return -1
            case .bottomLeft, .bottom, .bottomRight: return 1
            case .left, .right: return 0
            }
        }

        var isCorner: Bool { dx != 0 && dy != 0 }

        func point(in rect: CGRect) -> CGPoint {
            let x = dx < 0 ? rect.minX : (dx > 0 ? rect.maxX : rect.midX)
            let y = dy < 0 ? rect.minY : (dy > 0 ? rect.maxY : rect.midY)
            return CGPoint(x: x, y: y)
        }
    }

    /// A new rect while drawing from `start` to `current`. With an aspect, the larger side follows the cursor.
    /// Stays inside `bounds`. May be smaller than the minimum (the caller decides on mouse up).
    static func drawnRect(from start: CGPoint, to current: CGPoint, aspect: CGFloat?, bounds: CGRect) -> CGRect {
        let s = CGPoint(x: min(max(start.x, bounds.minX), bounds.maxX), y: min(max(start.y, bounds.minY), bounds.maxY))
        let c = CGPoint(x: min(max(current.x, bounds.minX), bounds.maxX), y: min(max(current.y, bounds.minY), bounds.maxY))
        guard let aspect, aspect > 0 else {
            return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
        }
        let signX: CGFloat = current.x >= start.x ? 1 : -1
        let signY: CGFloat = current.y >= start.y ? 1 : -1
        let maxWidth = signX > 0 ? bounds.maxX - s.x : s.x - bounds.minX
        let maxHeight = signY > 0 ? bounds.maxY - s.y : s.y - bounds.minY
        var width = max(abs(current.x - start.x), abs(current.y - start.y) * aspect)
        var height = width / aspect
        if width > maxWidth { width = maxWidth; height = width / aspect }
        if height > maxHeight { height = maxHeight; width = height * aspect }
        let x = signX > 0 ? s.x : s.x - width
        let y = signY > 0 ? s.y : s.y - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Moves the rect by `delta` and keeps it inside `bounds`.
    static func moved(_ rect: CGRect, by delta: CGSize, in bounds: CGRect) -> CGRect {
        let x = min(max(rect.minX + delta.width, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY + delta.height, bounds.minY), bounds.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// Resizes `rect` by dragging `handle` to `point`. The opposite edge or corner stays in place.
    /// With an aspect: a corner keeps the aspect with the larger change winning; an edge changes the other
    /// side symmetrically around the rect's center line. Never smaller than `minSide`, never outside `bounds`.
    static func resized(_ rect: CGRect, handle: Handle, to point: CGPoint, aspect: CGFloat?, bounds: CGRect,
                        minSide: CGFloat = minimumSide) -> CGRect {
        let anchorX = handle.dx > 0 ? rect.minX : rect.maxX
        let anchorY = handle.dy > 0 ? rect.minY : rect.maxY
        let maxWidthFromAnchor = handle.dx > 0 ? bounds.maxX - anchorX : anchorX - bounds.minX
        let maxHeightFromAnchor = handle.dy > 0 ? bounds.maxY - anchorY : anchorY - bounds.minY

        var width = rect.width
        var height = rect.height
        if handle.dx != 0 { width = (point.x - anchorX) * handle.dx }
        if handle.dy != 0 { height = (point.y - anchorY) * handle.dy }

        if let aspect, aspect > 0 {
            // Limits for the symmetric axis of an edge handle.
            let maxWidth: CGFloat
            let maxHeight: CGFloat
            if handle.isCorner {
                maxWidth = maxWidthFromAnchor
                maxHeight = maxHeightFromAnchor
            } else if handle.dx != 0 {
                maxWidth = maxWidthFromAnchor
                maxHeight = bounds.height
            } else {
                maxWidth = bounds.width
                maxHeight = maxHeightFromAnchor
            }
            if handle.isCorner {
                width = max(width, height * aspect)
            } else if handle.dy != 0 {
                width = height * aspect
            }
            let minWidth = max(minSide, minSide * aspect)
            width = max(width, minWidth)
            height = width / aspect
            if width > maxWidth { width = maxWidth; height = width / aspect }
            if height > maxHeight { height = maxHeight; width = height * aspect }

            var x = handle.dx > 0 ? anchorX : (handle.dx < 0 ? anchorX - width : rect.midX - width / 2)
            var y = handle.dy > 0 ? anchorY : (handle.dy < 0 ? anchorY - height : rect.midY - height / 2)
            // Edge handles grow the other axis around the center line; push it back inside.
            x = min(max(x, bounds.minX), bounds.maxX - width)
            y = min(max(y, bounds.minY), bounds.maxY - height)
            return CGRect(x: x, y: y, width: width, height: height)
        }

        width = min(max(width, minSide), handle.dx != 0 ? maxWidthFromAnchor : rect.width)
        height = min(max(height, minSide), handle.dy != 0 ? maxHeightFromAnchor : rect.height)
        let x = handle.dx > 0 ? anchorX : (handle.dx < 0 ? anchorX - width : rect.minX)
        let y = handle.dy > 0 ? anchorY : (handle.dy < 0 ? anchorY - height : rect.minY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// A rect at least `minSide` on both sides, grown around its center and kept inside `bounds`.
    static func ensuringMinimum(_ rect: CGRect, aspect: CGFloat?, bounds: CGRect, minSide: CGFloat = minimumSide) -> CGRect {
        var width = rect.width
        var height = rect.height
        if let aspect, aspect > 0 {
            width = max(width, minSide, minSide * aspect)
            height = width / aspect
        } else {
            width = max(width, minSide)
            height = max(height, minSide)
        }
        width = min(width, bounds.width)
        height = min(height, bounds.height)
        let grown = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        return moved(grown, by: .zero, in: bounds)
    }
}
