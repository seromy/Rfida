import AVFoundation

/// 每次成功掃描到新標籤都要發出提示聲(用戶明確要求),用App自己「設定」入面嘅
/// 靜音模式開關控制,而唔跟手機側邊嘅靜音撥掣 —— 用`.playback` audio session
/// category,令提示聲喺手機撥咗靜音掣嘅情況下都照樣播,要收聲一定要用App自己嘅開關。
/// 聲音本身用程式即時合成(WAV PCM),唔需要額外綁定音效檔案。
final class ScanSoundPlayer {
    static let shared = ScanSoundPlayer()

    private let beepPlayer: AVAudioPlayer?
    private let chimePlayer: AVAudioPlayer?

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        beepPlayer = try? AVAudioPlayer(data: Self.toneData(notes: [(1_500, 0.09)], amplitude: 0.5))
        beepPlayer?.prepareToPlay()

        // 情景3(返office前清點)「全部歸還」完成音:兩個音高上升嘅音符,
        // 要明顯長過、大聲過單一標籤嗰下短嗶聲,等使用者唔使睇畫面都知道掃齊咗。
        chimePlayer = try? AVAudioPlayer(data: Self.toneData(notes: [(1_046.5, 0.14), (1_760, 0.22)], amplitude: 0.75))
        chimePlayer?.prepareToPlay()
    }

    /// 一般情景(1/2/3/4)每個標籤讀取成功嘅短嗶聲。
    func playScanBeep() {
        play(beepPlayer)
    }

    /// 情景3全部器材歸還完成嗰下先播,同一般短嗶聲要有明顯分別。
    func playAllClearChime() {
        play(chimePlayer)
    }

    private func play(_ player: AVAudioPlayer?) {
        guard !UserDefaults.standard.bool(forKey: SettingsKey.scanSoundMuted) else { return }
        guard let player else { return }
        player.stop()
        player.currentTime = 0
        player.play()
    }

    /// 將一串(頻率, 秒數)音符合成做一段16-bit PCM mono WAV。每個音符之間有短暫靜音分隔,
    /// 音符本身用正弦包絡做淡入淡出,避免頭尾突然斷開產生「咔」聲。
    private static func toneData(notes: [(frequency: Double, duration: Double)], amplitude: Double) -> Data {
        let sampleRate = 44_100
        let gapDuration = 0.02
        var samples = [Int16]()

        for (index, note) in notes.enumerated() {
            let sampleCount = Int(Double(sampleRate) * note.duration)
            for i in 0..<sampleCount {
                let t = Double(i) / Double(sampleRate)
                let envelope = sin(Double.pi * Double(i) / Double(sampleCount))
                let value = sin(2.0 * .pi * note.frequency * t) * amplitude * envelope
                samples.append(Int16(value * Double(Int16.max)))
            }
            if index < notes.count - 1 {
                let gapSamples = Int(Double(sampleRate) * gapDuration)
                samples.append(contentsOf: [Int16](repeating: 0, count: gapSamples))
            }
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
