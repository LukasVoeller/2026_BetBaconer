import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let url = Bundle.module.url(forResource: "logo", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = makeSquareApplicationIcon(from: icon)
        }
    }

    private func makeSquareApplicationIcon(from image: NSImage) -> NSImage {
        let squareSide = max(image.size.width, image.size.height)
        let targetSize = NSSize(width: squareSide, height: squareSide)
        let squareImage = NSImage(size: targetSize)

        squareImage.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: targetSize)).fill()

        // Use aspect-fill for the Dock icon so the mark occupies the largest possible square area.
        let aspectRatio = max(targetSize.width / image.size.width, targetSize.height / image.size.height)
        let drawSize = NSSize(width: image.size.width * aspectRatio, height: image.size.height * aspectRatio)
        let clipRect = NSRect(origin: .zero, size: targetSize)
        clipRect.clip()
        let drawOrigin = NSPoint(
            x: (targetSize.width - drawSize.width) / 2,
            y: (targetSize.height - drawSize.height) / 2
        )

        image.draw(
            in: NSRect(origin: drawOrigin, size: drawSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
        squareImage.unlockFocus()
        return squareImage
    }
}

@main
struct BetBaconerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
        }
        .windowResizability(.contentMinSize)
    }
}
