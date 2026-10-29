//
//  VoiceInput.swift
//  NpcLab
//
//  按住说话 → 转文字 → 填进输入框。
//
//  为什么用 SFSpeechRecognizer 而不是丢给模型做 ASR：
//  iOS 自带的识别器免费、离线可用（需先下过语言包），而且延迟低到能边说话边出字。
//  走网络把音频甩给模型，一条 10 秒的语音要几百 KB，还多一次往返。
//
//  权限两个：
//    NSMicrophoneUsageDescription   录音
//    NSSpeechRecognitionUsageDescription  识别
//  两个都在 Info.plist 里（设置 → 权限 能看到）。用户拒了就把 route 置 .denied，
//  界面上显示一句原因，不弹第二次系统框（iOS 不会再弹）。
//

import Foundation
import SwiftUI
import AVFoundation
import Speech

@MainActor
final class VoiceInput: ObservableObject {

    enum Route: Equatable {
        case idle
        case listening
        case denied(String)
        case failed(String)
    }

    @Published private(set) var route: Route = .idle
    /// 已识别的文字，边说边更
    @Published private(set) var transcript = ""
    /// 音量 0...1，画波形用
    @Published private(set) var level: Double = 0

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    var isListening: Bool { route == .listening }

    // MARK: 开始 / 停止

    func start() async {
        guard !isListening else { return }
        transcript = ""

        // 1. 权限（两个都要）
        let mic = await Self.askMic()
        guard mic else {
            route = .denied("麦克风被拒。到 设置 → 小徐TuT 里打开。")
            return
        }
        let speech = await Self.askSpeech()
        guard speech else {
            route = .denied("语音识别被拒。到 设置 → 小徐TuT 里打开。")
            return
        }

        guard let rec = recognizer, rec.isAvailable else {
            route = .failed("识别器不可用（可能没下中文语言包，或没网）")
            return
        }

        // 2. 会话
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let eng = AVAudioEngine()
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if rec.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = true    // 能离线就离线，省流量也快
            }

            let input = eng.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
                req.append(buf)
                // 算个粗音量：取 RMS 再压到 0...1
                guard let self else { return }
                let lv = Self.rms(buf)
                Task { @MainActor in self.level = lv }
            }

            eng.prepare()
            try eng.start()

            engine = eng
            request = req
            route = .listening

            task = rec.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                Task { @MainActor in
                    if let r = result {
                        self.transcript = r.bestTranscription.formattedString
                        if r.isFinal { self.stop() }
                    }
                    if error != nil, self.route == .listening {
                        // 静音太久会抛，当作正常结束
                        self.stop()
                    }
                }
            }
        } catch {
            route = .failed(error.localizedDescription)
            teardown()
        }
    }

    func stop() {
        if route == .listening { route = .idle }
        request?.endAudio()
        task?.cancel()
        teardown()
    }

    /// 取走文字并清空（发送后用）
    func take() -> String {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        return t
    }

    // MARK: 内部

    private func teardown() {
        engine?.stop()
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request = nil
        task = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func rms(_ buf: AVAudioPCMBuffer) -> Double {
        guard let ch = buf.floatChannelData?[0] else { return 0 }
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let r = sqrt(sum / Float(n))
        // -50dB 到 0dB 映射到 0...1，太小的底噪直接归零
        let db = 20 * log10(max(r, 1e-7))
        return Double(max(0, min(1, (db + 50) / 50)))
    }

    private static func askMic() async -> Bool {
        await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
    }

    private static func askSpeech() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { st in
                c.resume(returning: st == .authorized)
            }
        }
    }
}

// MARK: - 按钮 + 波形

/// 输入框左边那个话筒。按住说话，松手停。
struct VoiceButton: View {

    @ObservedObject var voice: VoiceInput
    var onDone: (String) -> Void

    var body: some View {
        Image(systemName: voice.isListening ? "waveform" : "mic")
            .font(.system(size: 15))
            .foregroundColor(voice.isListening ? T.red : T.txt2)
            .frame(width: 30, height: 40)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !voice.isListening {
                            Task { await voice.start() }
                        }
                    }
                    .onEnded { _ in
                        voice.stop()
                        let t = voice.take()
                        if !t.isEmpty { onDone(t) }
                    }
            )
            .alert(isPresented: Binding(
                get: {
                    if case .denied = voice.route { return true }
                    if case .failed = voice.route { return true }
                    return false
                },
                set: { if !$0 { voice.stop() } }
            )) {
                Alert(title: Text("语音输入用不了"), message: alertText,
                      dismissButton: .default(Text("知道了")))
            }
    }

    private var alertText: Text {
        switch voice.route {
        case .denied(let m), .failed(let m): return Text(verbatim: m)
        default: return Text("")
        }
    }
}

/// 录音时输入框上方那条实时文字 + 音量条
struct VoiceOverlay: View {
    @ObservedObject var voice: VoiceInput

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(T.red)
                .frame(width: 6, height: 6)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(T.card).frame(height: 3)
                    Capsule().fill(T.red.opacity(0.8))
                        .frame(width: max(2, g.size.width * voice.level), height: 3)
                }
                .frame(height: 3)
            }
            .frame(height: 3)

            Text(voice.transcript.isEmpty ? "在听…" : voice.transcript)
                .font(.system(size: 11.5))
                .foregroundColor(voice.transcript.isEmpty ? T.txt3 : T.txt)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
