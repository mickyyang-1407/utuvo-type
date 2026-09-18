// HostAppResolver.swift
// Adapted from dictus-ios (MIT License, Copyright (c) 2026 PIVI Solutions),
// DictusKeyboard/HostAppResolver.swift — see THIRD_PARTY_NOTICES.md.
import UIKit

/// 找出鍵盤正在服務哪個 app，讓「跳到主 app 開麥克風」之後能自動回去。
///
/// 宿主身分不在 input view controller、parent、extensionContext 或 window scene 上，
/// 而在 UIKit 的 `_UIKeyboardArbiterClient` 單例（預設休眠，由 HostArbiterActivation 在載入期喚醒）。
///
/// **不能直接用 arbiter 的 `sourceBundleIdentifier`**：Dictus 真機 190 筆紀錄裡有 7 筆是舊 app、
/// 4 筆十秒都沒更正——直接用會有約四分之一開錯 app。可靠的一半是自己 controller 上的
/// `_hostProcessIdentifier`（16/16 正確），所以：每次讀 arbiter 都把 (pid, bundle) 記進表，
/// 答案＝`table[hostPid]`，把「錯答案」變成「沒答案」。
///
/// 真機上 `proc_pidpath`／`sysctl`／`csops` 對他程序都是 EPERM（2026-09-18 本機實測），
/// 模擬器卻會成功——那是陷阱，不能拿來當方法。
@MainActor
enum HostAppResolver {
    private static let arbiterClassNames = ["_UIKeyboardArbiterClient", "UIKeyboardArbiterClient"]
    private static let sharedClientSelector = "automaticSharedArbiterClient"
    private static var table = HostPidTable()

    enum Resolution: Equatable {
        case resolved(String, pid: Int)
        case noHostPid
        case tableMiss(pid: Int)

        var hostId: String? {
            if case .resolved(let id, _) = self { return id }
            return nil
        }
    }

    /// 鍵盤出現：舊的證據退役。要在這次出現的第一次 harvest 之前呼叫。
    static func noteKeyboardAppeared() { table.noteAppearance() }

    /// 讀一次 arbiter 並記錄。出現、打字、移動游標、點光球前都呼叫（首次出現約 200 ms 後才有資料）。
    static func harvest() {
        guard let state = currentClientState(),
              let bundleId = read("sourceBundleIdentifier", from: state) as? String,
              let pid = (read("processIdentifier", from: state) as? NSNumber)?.intValue,
              !bundleId.isEmpty, pid > 0 else { return }
        table.record(bundleId: bundleId, forPid: pid)
    }

    static func currentHost(for controller: UIInputViewController) -> Resolution {
        harvest()
        guard let pid = (read("_hostProcessIdentifier", from: controller) as? NSNumber)?.intValue, pid > 0 else {
            return .noHostPid
        }
        guard let bundleId = table.bundleId(forPid: pid) else { return .tableMiss(pid: pid) }
        return .resolved(bundleId, pid: pid)
    }

    /// 除錯用的一行狀態（寫進 debug 檔，真機用 devicectl 撈）。
    static func diagnostics(_ resolution: Resolution) -> [String: String] {
        let state = currentClientState()
        return [
            "resolution": "\(resolution)",
            "swizzleAtLoad": UTUVOHostArbiterActivation.loadTimeOutcome(),
            "swizzleRetry": UTUVOHostArbiterActivation.activate(),
            "arbiterClass": String(resolveArbiterClass() != nil),
            "clientState": String(state != nil),
            "arbiterSays": state.map { "\(read("sourceBundleIdentifier", from: $0) ?? "nil")@\(read("processIdentifier", from: $0) ?? "nil")" } ?? "no-state",
            "tableKnown": String(table.count),
            "tableTrusted": String(table.trustedCount),
        ]
    }

    private static func currentClientState() -> NSObject? {
        guard let cls = resolveArbiterClass() else { return nil }
        let selector = NSSelectorFromString(sharedClientSelector)
        let classObject = cls as AnyObject
        guard classObject.responds(to: selector),
              let client = classObject.perform(selector)?.takeUnretainedValue() as? NSObject else { return nil }
        return read("currentClientState", from: client) as? NSObject
    }

    private static func resolveArbiterClass() -> NSObject.Type? {
        for name in arbiterClassNames {
            if let cls = NSClassFromString(name) as? NSObject.Type { return cls }
        }
        return nil
    }

    /// 不會丟例外的 KVC：key 不存在時 value(forKey:) 會丟 ObjC 例外，Swift 接不住。
    private static func read(_ key: String, from object: NSObject) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }
}
