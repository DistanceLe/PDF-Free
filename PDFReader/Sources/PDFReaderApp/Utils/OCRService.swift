import AppKit
import PDFKit
import Vision

/// 基于 Vision 框架的 OCR 文字识别（针对扫描版 / 无文本层 PDF）。
enum OCRService {

    struct PageResult: Sendable, Identifiable {
        let pageIndex: Int
        let lines: [String]

        var id: Int { pageIndex }
        var text: String { lines.joined(separator: "\n") }
    }

    enum OCRError: LocalizedError {
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .renderFailed:
                return "无法渲染该页面以进行识别。"
            }
        }
    }

    /// 识别指定页。
    ///
    /// 页面渲染必须在主线程完成（PDFKit 要求），识别本身在后台队列执行。
    @MainActor
    static func recognize(
        page: PDFPage,
        pageIndex: Int,
        scale: CGFloat = 2.0,
        languages: [String] = ["zh-Hans", "en-US"]
    ) async throws -> PageResult {
        guard let cgImage = render(page: page, scale: scale) else {
            throw OCRError.renderFailed
        }

        // CGImage 跨线程传递：包一层显式声明只读共享
        let box = UnsafeSendableBox(value: cgImage)
        let lines: [String] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = performRecognition(on: box.value, languages: languages)
                continuation.resume(returning: result)
            }
        }
        return PageResult(pageIndex: pageIndex, lines: lines)
    }

    // MARK: - 渲染

    @MainActor
    private static func render(page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // 2 倍分辨率：再低小字号识别率会明显下降
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: target, for: .cropBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - 识别

    private struct Fragment {
        let text: String
        let minX: CGFloat
        let midY: CGFloat
        let height: CGFloat
    }

    nonisolated private static func performRecognition(on image: CGImage, languages: [String]) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let wanted = languages.filter { supported.contains($0) }
        if !wanted.isEmpty {
            request.recognitionLanguages = wanted
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }

        let fragments: [Fragment] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return Fragment(text: text, minX: box.minX, midY: box.midY, height: box.height)
        }

        // Vision 的归一化坐标原点在左下角：先按纵坐标从上到下排，
        // 再把纵坐标接近的碎片归为同一行，行内按横坐标从左到右合并。
        let sorted = fragments.sorted { $0.midY > $1.midY }

        var rows: [[Fragment]] = []
        for fragment in sorted {
            if var lastRow = rows.last, let reference = lastRow.first,
               abs(reference.midY - fragment.midY) < max(reference.height, fragment.height) * 0.6 {
                lastRow.append(fragment)
                rows[rows.count - 1] = lastRow
            } else {
                rows.append([fragment])
            }
        }

        return rows.map { row in
            joinLine(row.sorted { $0.minX < $1.minX }.map(\.text))
        }
    }

    /// 行内拼接：中文之间不加空格，西文之间保留空格。
    private static func joinLine(_ texts: [String]) -> String {
        var result = ""
        for text in texts {
            if result.isEmpty {
                result = text
                continue
            }
            let needsSpace = !endsWithCJK(result) && !startsWithCJK(text)
            result += (needsSpace ? " " : "") + text
        }
        return result
    }

    private static func startsWithCJK(_ text: String) -> Bool {
        text.unicodeScalars.first.map(isCJK) ?? false
    }

    private static func endsWithCJK(_ text: String) -> Bool {
        text.unicodeScalars.last.map(isCJK) ?? false
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)      // 基本汉字
            || (0x3400...0x4DBF).contains(scalar.value) // 扩展 A
            || (0x3000...0x303F).contains(scalar.value) // CJK 标点
            || (0xFF00...0xFFEF).contains(scalar.value) // 全角字符
    }
}
