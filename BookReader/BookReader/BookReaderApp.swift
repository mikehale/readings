import SwiftUI

@main
struct BookReaderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") {
                    NotificationCenter.default.post(name: .bookReaderOpenPDF, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let bookReaderOpenPDF = Notification.Name("bookReaderOpenPDF")
}
