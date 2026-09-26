// HostAppResolver.swift
// Public-API-only host resolution for the keyboard extension.
import UIKit

/// 鍵盤 extension 不使用 UIKit 私有 arbiter 或 runtime swizzle 讀宿主 App。
/// iOS 沒有公開的宿主 bundle identifier API，因此沒有可靠答案時就回報 noHostPid，
/// 主 app 會留在前景，使用者可用系統左上角返回鍵回到原本的 App。
@MainActor
enum HostAppResolver {
    enum Resolution: Equatable {
        case resolved(String, pid: Int)
        case noHostPid
        case tableMiss(pid: Int)

        var hostId: String? {
            if case .resolved(let id, _) = self { return id }
            return nil
        }
    }

    static func noteKeyboardAppeared() {}
    static func harvest() {}

    static func currentHost(for controller: UIInputViewController) -> Resolution {
        _ = controller
        return .noHostPid
    }

    /// 除錯用的一行狀態；只記錄公開 API 無法取得宿主身分，不讀取私有類別或 selector。
    static func diagnostics(_ resolution: Resolution) -> [String: String] {
        [
            "resolution": "\(resolution)",
            "hostIdentifier": "unavailable-public-api-only"
        ]
    }
}
