// macOS uses the same pure normalizer as ios/Shared/VoiceLevel.swift. No App Group IO.
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
