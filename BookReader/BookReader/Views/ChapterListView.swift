import SwiftUI

struct ChapterListView: View {
    let chapters: [BookChapter]
    @Binding var selection: BookChapter.ID?

    var body: some View {
        List(chapters, selection: $selection) { chapter in
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title)
                    .lineLimit(2)
                Text(chapter.pageLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(chapter.id)
            .padding(.vertical, 2)
        }
        .listStyle(.sidebar)
    }
}
