import AVFoundation

/// 每次成功掃描到新標籤都要發出提示聲(用戶明確要求),用App自己「設定」入面嘅
/// 靜音模式開關控制,而唔跟手機側邊嘅靜音撥掣 —— 用`.playback` audio session
/// category,令提示聲喺手機撥咗靜音掣嘅情況下都照樣播,要收聲一定要用App自己嘅開關。
/// 聲音本身用程式即時合成一段極短嘅嗶聲(WAV PCM),唔需要額外綁定音效檔案。
final class ScanSoundPlayer {
    static let shared = ScanSoundPlayer()

    private let player: AVAudioPlayer?

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(data: Self.beepWAVData())
        player?.prepareToPlay()
    }

    /// 揀選模式:0.09秒、1.5kHz、有淡入淡出包絡嘅短嗶聲,適合連續掃描時密集觸發。
    func playScanBeep() {
        guard !UserDefaults.standard.bool(forKey: SettingsKey.scanSoundMuted) else { return }
        guard let player else { return }
        player.stop()
        player.currentTime = 0
        player.play()
    }

    private static func beepWAVData() -> Data {
        let sampleRate = 44_100
        let duration = 0.09
        let frequency = 1_500.0
        let amplitude = 0.5
        let sampleCount = Int(Double(sampleRate) * duration)

        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleRate)
            // 用正弦包絡做淡入淡出,避免頭尾突然斷開產生「咔」聲。
            let envelope = sin(Double.pi * Double(i) / Double(sampleCount))
            let value = sin(2.0 * .pi * frequency * t) * amplitude * envelope
            samples.append(Int16(value * Double(Int16.max)))
        }

        var data = Data()
        func appendUInt32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2

        data.append(contentsOf: "RIFF".utf8)
        appendUInt32(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(2)
        appendUInt16(16)
        data.append(contentsOf: "data".utf8)
        appendUInt32(UInt32(dataSize))
        for sample in samples {
            appendUInt16(UInt16(bitPattern: sample))
        }
        return data
    }
}
