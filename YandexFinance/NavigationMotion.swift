import Foundation

/// Presentation only: a single owner decides whether a pan moves a page or the drawer.
enum NavigationMotion {
    static func drawerWidth(_ viewport: CGFloat) -> CGFloat { max(0, (viewport - 24) * 0.7) }

    static func drawerPosition(translation: CGFloat, width: CGFloat, wasOpen: Bool) -> CGFloat {
        min(width + 16, max(0, (wasOpen ? width + 16 : 0) + translation))
    }

    static func drawerShouldOpen(translation: CGFloat, velocity: CGFloat, width: CGFloat, wasOpen: Bool) -> Bool {
        drawerPosition(translation: translation + velocity * 0.18, width: width, wasOpen: wasOpen) > (width + 16) * 0.4
    }

    static func pageTarget(current: Int, translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Int {
        let projected = translation + velocity * 0.18
        guard abs(projected) > max(40, width * 0.22) else { return current }
        return min(3, max(1, current + (projected < 0 ? 1 : -1)))
    }
}
