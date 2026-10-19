import SwiftUI

@MainActor
struct DocumentInfoView: View {
    let info: PDFViewModel.DocumentInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文档信息")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            Divider()

            Form {
                if let title = info.title, !title.isEmpty {
                    LabeledContent("标题", value: title)
                }
                if let author = info.author, !author.isEmpty {
                    LabeledContent("作者", value: author)
                }
                if let subject = info.subject, !subject.isEmpty {
                    LabeledContent("主题", value: subject)
                }
                if let creator = info.creator, !creator.isEmpty {
                    LabeledContent("创建工具", value: creator)
                }
                LabeledContent("页数", value: "\(info.pageCount)")
                if let fileSize = info.fileSize {
                    LabeledContent("文件大小", value: fileSize)
                }
                if let date = info.creationDate {
                    LabeledContent("创建日期", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let date = info.modificationDate {
                    LabeledContent("修改日期", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .formStyle(.grouped)
            .padding()

            Spacer()
        }
        .frame(width: 380, height: 320)
    }
}
