import SwiftUI
import UTUVOTypeCore

@main
struct UTUVOTypeIOSApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var tab = 0
    @ObservedObject private var voiceHost = KeyboardVoiceHost.shared

    init() {
        #if DEBUG
        // 鍵盤截圖姿態：主 app 收 launch arg `-utuvo.type.keyboard.debugPose recording|arc`，
        // 經 cfprefsd 正規寫進 App Group（直接改 plist 檔 cfprefsd 不認）；沒帶就清掉。
        if UserDefaults.standard.bool(forKey: "utuvo.type.debug.pidProbe") {
            typealias ProcPidPath = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32) -> Int32
            var out: [String: String] = [:]
            if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pidpath") {
                let fn = unsafeBitCast(sym, to: ProcPidPath.self)
                for (label, pid) in [("self", getpid()), ("launchd", Int32(1))] {
                    var buf = [CChar](repeating: 0, count: 4096)
                    let n = buf.withUnsafeMutableBytes { fn(pid, $0.baseAddress!, UInt32($0.count)) }
                    out[label] = n > 0 ? String(cString: buf) : "denied(\(n)) errno=\(errno)"
                }
            } else { out["dlsym"] = "nil" }
            out["safariBundle"] = KeyboardVoiceHost.bundleIdentifier(forAppPath: "/Applications/MobileSafari.app") ?? "nil"
            typealias CSOps = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer, Int) -> Int32
            if let csopsSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") {
                let csops = unsafeBitCast(csopsSym, to: CSOps.self)
                for (label, pid) in [("csops.self", getpid()), ("csops.launchd", Int32(1))] {
                    var buf = [UInt8](repeating: 0, count: 1024)
                    let rc = buf.withUnsafeMutableBytes { csops(pid, 11 /* CS_OPS_IDENTITY */, $0.baseAddress!, $0.count) }
                    // 回傳 blob：8 bytes header 後是字串
                    let ident = rc == 0 ? String(cString: Array(buf[8...]).map { CChar(bitPattern: $0) } + [0]) : "rc=\(rc) errno=\(errno)"
                    out[label] = ident
                }
            } else { out["csops"] = "no-symbol" }
            for (label, pid) in [("sysctl.self", getpid()), ("sysctl.launchd", Int32(1))] {
                var info = kinfo_proc()
                var size = MemoryLayout<kinfo_proc>.stride
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
                let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
                let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                out[label] = rc == 0 ? (name.isEmpty ? "empty(size=\(size))" : name) : "rc=\(rc) errno=\(errno)"
            }
            VoiceBridge.write(out, name: "debug-pid-probe.json")
            print("[debug] pid probe \(out)")
        }
        let key = "utuvo.type.keyboard.debugPose"
        if let pose = UserDefaults.standard.string(forKey: key) {
            KeyboardPresence.defaults.set(pose, forKey: key)
        } else {
            KeyboardPresence.defaults.removeObject(forKey: key)
        }
        #endif
    }

    var body: some View {
        ZStack {
            tabs
            // 鍵盤語音工作階段期間，整個主 app 換成專用畫面（沒有麥克風按鈕可點）。
            if voiceHost.isActive || voiceHost.lastError != nil {
                KeyboardSessionScreen(host: voiceHost)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: voiceHost.isActive)
        // 鍵盤叫起主 app：utuvotype://voice?lang=…&id=…
        .onOpenURL { url in
            tab = 0
            voiceHost.handle(url: url)
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            DictateView()
                .tabItem { Label("聽寫", systemImage: "mic.fill") }
                .tag(0)
            HistoryListView()
                .tabItem { Label("歷史", systemImage: "clock.arrow.circlepath") }
                .tag(1)
            SettingsScreen()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(2)
        }
        .tint(Aurora.orange)
    }
}
