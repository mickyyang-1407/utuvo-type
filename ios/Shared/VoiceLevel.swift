import Foundation

/// 光球的「聽感」：把麥克風音量（dBFS）變成 0…1 的能量，光球照這個值膨脹、發亮、流動加速。
///
/// 背景噪音會自己追（咖啡廳裡光球不會一直亢奮）：底噪往下立刻跟、往上慢慢爬，
/// 能量＝高出底噪多少。全部是純函式／值型別，有測試。
enum VoiceLevel {
    struct Normalizer: Equatable, Sendable {
        /// 目前估的底噪（dBFS）。
        private(set) var floor: Float = -60
        /// 底噪往上爬的時間常數（秒）：連講幾秒也不會把自己當底噪（4 秒時連講 3 秒能量掉到 0.2，測試抓到）。
        var riseSeconds: Float = 12
        /// 高出底噪多少 dB 才開始算能量、再多少 dB 算滿。
        var gate: Float = 6
        var span: Float = 30

        /// 餵一個新音量、經過 dt 秒，回傳 0…1 能量（smoothstep 曲線）。
        mutating func energy(dbfs: Float, dt: Float) -> Float {
            let db = dbfs.isFinite ? max(dbfs, -120) : -120
            if db < floor {
                floor = db
            } else {
                floor += (db - floor) * min(1, dt / riseSeconds)
            }
            floor = min(max(floor, -80), -30)
            let x = min(max((db - floor - gate) / span, 0), 1)
            return x * x * (3 - 2 * x)
        }
    }

    /// 一階平滑：上升快、下降慢——講話的起音立刻看得到，字與字之間不會閃。
    static func smooth(_ current: Float, toward target: Float, dt: Float, attack: Float = 0.05, release: Float = 0.22) -> Float {
        let tau = target > current ? attack : release
        guard tau > 0 else { return target }
        return current + (target - current) * (1 - exp(-dt / tau))
    }
}

/// 主 app → 鍵盤的即時音量通道：App Group 裡一個 16 bytes 的檔案，原地覆寫。
///
/// 為什麼不走 VoiceBridge 的 state 檔＋Darwin notification：音量每秒 40 多次，
/// 原子寫檔＋通知太重；這裡寫端 pwrite、讀端 pread 各一次 syscall，鍵盤光球每幀讀一次。
/// 讀到太舊（主 app 沒在錄、或被系統收掉）就回 nil，光球自己安靜下來。
final class VoiceLevelChannel: @unchecked Sendable {
    static let fileName = "voice-level.bin"
    /// 多舊的音量算失效（秒）。
    static let maxAge: Double = 0.35

    private struct Packet { var db: Double = -120; var time: Double = 0 }

    private let path: String
    private let writable: Bool
    private var fd: Int32 = -1
    private var lastOpenAttempt: Double = -.infinity
    private let lock = NSLock()

    /// `directory` 預設 App Group 的 `Library/VoiceBridge/`。
    init?(directory: URL? = VoiceBridge.containerURL, writable: Bool) {
        guard let directory else { return nil }
        path = directory.appendingPathComponent(Self.fileName).path
        self.writable = writable
        _ = ensureOpen(now: 0)
    }

    deinit { if fd >= 0 { close(fd) } }

    /// 讀端檔案可能還不存在（主 app 還沒錄過）：最多每秒重試一次，不要每幀 open。
    private func ensureOpen(now: Double) -> Bool {
        if fd >= 0 { return true }
        guard now - lastOpenAttempt >= 1 else { return false }
        lastOpenAttempt = now
        fd = writable ? open(path, O_RDWR | O_CREAT, 0o644) : open(path, O_RDONLY)
        return fd >= 0
    }

    /// 音訊執行緒呼叫。
    func write(db: Float, at time: Double = CFAbsoluteTimeGetCurrent()) {
        lock.lock(); defer { lock.unlock() }
        guard ensureOpen(now: time) else { return }
        var packet = Packet(db: Double(db), time: time)
        _ = withUnsafeBytes(of: &packet) { pwrite(fd, $0.baseAddress, $0.count, 0) }
    }

    /// 停止錄音時寫一筆「很安靜、而且立刻過期」，鍵盤光球馬上收，不用等 maxAge。
    func clear() { write(db: -120, at: 0) }

    /// 讀最新音量；沒有、太舊或時間怪異都回 nil。
    func read(now: Double = CFAbsoluteTimeGetCurrent()) -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard ensureOpen(now: now) else { return nil }
        var packet = Packet()
        let n = withUnsafeMutableBytes(of: &packet) { pread(fd, $0.baseAddress, $0.count, 0) }
        guard n == MemoryLayout<Packet>.size else { return nil }
        let age = now - packet.time
        guard age >= -1, age <= Self.maxAge else { return nil }
        return Float(packet.db)
    }
}
