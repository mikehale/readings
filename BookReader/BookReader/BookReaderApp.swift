import SwiftUI

@main
struct BookReaderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Debug/automation: `open BookReader.app --args --open-pdf /path/to/book.pdf`
                    let args = ProcessInfo.processInfo.arguments
                    if let idx = args.firstIndex(of: "--open-pdf"),
                       args.index(after: idx) < args.endIndex {
                        let path = args[args.index(after: idx)]
                        let url = URL(fileURLWithPath: path)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NotificationCenter.default.post(
                                name: .bookReaderOpenPDFAtURL,
                                object: url
                            )
                        }
                    }
                }
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
    static let bookReaderOpenPDFAtURL = Notification.Name("bookReaderOpenPDFAtURL")
}
