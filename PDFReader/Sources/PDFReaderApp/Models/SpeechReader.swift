import AVFoundation
import Foundation

/// 基于系统 TTS（AVSpeechSynthesizer）的文本朗读。
///
/// 朗读结束后会回调 `onFinish`，供外部实现"读完整页自动翻页连读"。
@MainActor
final class SpeechReader: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false

    /// 语速，对应 `AVSpeechUtterance` 的 rate（0.0 ~ 1.0，0.5 为系统默认）
    @Published var rate: Double = 0.5

    /// 是否在朗读结束后自动进入下一页继续朗读
    @Published var autoAdvance: Bool = false

    /// 一段文本朗读完成后的回调（仅在非主动停止时触发）
    var onFinish: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    /// 标记本次语音是被 `stop()` 主动取消的，避免误触发自动连读
    private var isCancelling = false

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    static let shared = SpeechReader()

    // MARK: - 控制

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()

        isCancelling = false
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = Float(rate)
        // 按内容自动挑选中英文声音，避免中文用英文声调读出来
        if let voice = Self.voice(for: trimmed) {
            utterance.voice = voice
        }

        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused = false
    }

    func pause() {
        guard synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
    }

    func resume() {
        guard synthesizer.isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
    }

    func togglePause() {
        if isPaused {
            resume()
        } else {
            pause()
        }
    }

    func stop() {
        isCancelling = true
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        isPaused = false
    }

    // MARK: - 声音选择

    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let hasCJK = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)      // 基本汉字
                || (0x3400...0x4DBF).contains(scalar.value) // 扩展 A
                || (0x3000...0x303F).contains(scalar.value) // CJK 标点
        }
        let preferred = hasCJK ? "zh-CN" : "en-US"
        return AVSpeechSynthesisVoice(language: preferred)
            ?? AVSpeechSynthesisVoice(language: hasCJK ? "zh-Hans" : nil)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechReader: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            self.isPaused = false
            if !self.isCancelling {
                self.onFinish?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            self?.isPaused = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didPause utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isPaused = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isPaused = false
        }
    }
}
