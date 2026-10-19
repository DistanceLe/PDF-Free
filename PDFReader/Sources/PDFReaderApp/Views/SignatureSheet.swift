import SwiftUI

/// 手写签名画布产出的数据。
///
/// `strokes` 与 `inkBounds` 都基于画布坐标系（原点左上、y 向下），
/// 由调用方负责换算到 PDF 页面坐标系。
struct SignaturePayload {
    let strokes: [[CGPoint]]
    let inkBounds: CGRect
    let canvasSize: CGSize
    let color: NSColor
}

/// 手写签名弹窗。
@MainActor
struct SignatureSheet: View {

    let onConfirm: (SignaturePayload) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var strokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []
    @State private var strokeWidth: CGFloat = 2.5
    @State private var inkColorIndex: Int = 0

    private let canvasSize = CGSize(width: 520, height: 200)
    private let inkColors: [(name: String, color: Color, nsColor: NSColor)] = [
        ("黑色", .black, .black),
        ("蓝色", .blue, .systemBlue),
        ("红色", .red, .systemRed)
    ]

    private var isEmpty: Bool { strokes.isEmpty && currentStroke.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvasArea
                .padding(20)
            Divider()
            controls
        }
        .frame(width: canvasSize.width + 40)
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Text("手写签名")
                .font(.headline)
            Spacer()
            Text("签名将插入当前可见区域，可事后拖动调整位置")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - 画布

    private var canvasArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))

            // 基准线，帮助对齐笔迹
            Path { path in
                path.move(to: CGPoint(x: 24, y: canvasSize.height - 44))
                path.addLine(to: CGPoint(x: canvasSize.width - 24, y: canvasSize.height - 44))
            }
            .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            inkPath
                .stroke(
                    inkColors[inkColorIndex].color,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                )

            if isEmpty {
                Text("在此手写签名")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    currentStroke.append(value.location)
                }
                .onEnded { _ in
                    guard !currentStroke.isEmpty else { return }
                    strokes.append(currentStroke)
                    currentStroke = []
                }
        )
    }

    private var inkPath: Path {
        var path = Path()
        for stroke in strokes {
            append(stroke, to: &path)
        }
        append(currentStroke, to: &path)
        return path
    }

    private func append(_ stroke: [CGPoint], to path: inout Path) {
        guard let first = stroke.first else { return }
        path.move(to: first)
        for point in stroke.dropFirst() {
            path.addLine(to: point)
        }
        // 单点也画一个圆点，避免"点一下"没有任何反馈
        if stroke.count == 1 {
            path.addEllipse(in: CGRect(x: first.x - strokeWidth / 2, y: first.y - strokeWidth / 2,
                                       width: strokeWidth, height: strokeWidth))
        }
    }

    // MARK: - 底部控制条

    private var controls: some View {
        HStack(spacing: 16) {
            // 笔迹颜色
            Picker("", selection: $inkColorIndex) {
                ForEach(inkColors.indices, id: \.self) { index in
                    Text(inkColors[index].name).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            // 笔宽
            HStack(spacing: 6) {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: $strokeWidth, in: 1...8)
                    .frame(width: 120)
            }

            Spacer()

            Button("清除") {
                strokes.removeAll()
                currentStroke = []
            }
            .disabled(isEmpty)

            Button("取消") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Button("插入签名") {
                confirm()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isEmpty)
        }
        .padding()
    }

    // MARK: - 确认

    private func confirm() {
        let allStrokes = strokes + (currentStroke.isEmpty ? [] : [currentStroke])
        guard let bounds = inkBounds(of: allStrokes) else { return }
        let payload = SignaturePayload(
            strokes: allStrokes,
            inkBounds: bounds,
            canvasSize: canvasSize,
            color: inkColors[inkColorIndex].nsColor
        )
        onConfirm(payload)
        dismiss()
    }

    private func inkBounds(of strokes: [[CGPoint]]) -> CGRect? {
        let points = strokes.flatMap { $0 }
        guard let first = points.first else { return nil }

        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        // 外扩半个笔宽，避免笔迹边缘被裁掉
        let padding = strokeWidth / 2 + 2
        return CGRect(
            x: minX - padding,
            y: minY - padding,
            width: maxX - minX + padding * 2,
            height: maxY - minY + padding * 2
        )
    }
}
