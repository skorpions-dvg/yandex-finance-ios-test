import Foundation

@main
struct NavigationMotionTests {
    static func main() {
        let width = NavigationMotion.drawerWidth(390)
        // Slow drags must work without relying on a flick velocity.
        precondition(!NavigationMotion.drawerShouldOpen(translation: 20, velocity: 0, width: width, wasOpen: false))
        precondition(NavigationMotion.drawerShouldOpen(translation: width * 0.7, velocity: 0, width: width, wasOpen: false))
        precondition(NavigationMotion.drawerShouldOpen(translation: 30, velocity: 900, width: width, wasOpen: false))
        precondition(!NavigationMotion.drawerShouldOpen(translation: -width * 0.8, velocity: 0, width: width, wasOpen: true))
        precondition(NavigationMotion.drawerShouldOpen(translation: -20, velocity: 0, width: width, wasOpen: true))
        precondition(NavigationMotion.drawerPosition(translation: -1000, width: width, wasOpen: true) == 0)
        precondition(NavigationMotion.drawerPosition(translation: 1000, width: width, wasOpen: false) == width + 16)
        precondition(NavigationMotion.drawerPosition(translation: 90, width: width, wasOpen: false) == 90)
        precondition(NavigationMotion.pageTarget(current: 1, translation: -150, velocity: 0, width: 390) == 2)
        precondition(NavigationMotion.pageTarget(current: 2, translation: 20, velocity: 600, width: 390) == 1)
        precondition(NavigationMotion.pageTarget(current: 2, translation: -20, velocity: 0, width: 390) == 2)
        precondition(NavigationMotion.pageTarget(current: 3, translation: -200, velocity: -1000, width: 390) == 3)
        precondition(NavigationMotion.pageTarget(current: 1, translation: 200, velocity: 1000, width: 390) == 1)
        print("Navigation motion checks passed: slow drags, flicks, snap-back and boundaries")
    }
}
