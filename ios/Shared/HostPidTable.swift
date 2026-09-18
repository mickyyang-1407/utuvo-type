// HostPidTable.swift
// Adapted from dictus-ios (MIT License, Copyright (c) 2026 PIVI Solutions),
// DictusCore/Sources/DictusCore/HostPidTable.swift — see THIRD_PARTY_NOTICES.md.
import Foundation

/// 宿主 PID → bundle id 對照表。**可以沒有答案，絕不能給錯答案。**
///
/// - 答錯＝打開使用者不在的 app，甚至把他關掉的 app 叫起來；沒答案只是退回「手動點左上角」。
/// - iOS 會回收 PID，鍵盤 extension 又可能活好幾小時：只有「本次鍵盤出現期間」記到的才算數。
///   鍵盤每出現一次（換 app 就會重新出現）世代 +1，舊世代的紀錄保留作統計但不再回答。
/// - 同一個 PID 被報成別的 bundle：新的直接取代（PID 被回收）。
/// - 只放在 extension 記憶體，**永不寫檔**（寫進 App Group 會在 PID 回收後對錯 app）。
/// - 上限 64 筆，最舊先淘汰（extension 記憶體上限約 50 MB）。
struct HostPidTable: Equatable {
    private struct Entry: Equatable {
        let bundleId: String
        var generation: Int
    }

    static let maxEntries = 64

    private var entries: [Int: Entry] = [:]
    private var insertionOrder: [Int] = []
    private var generation = 0

    var count: Int { entries.count }
    var trustedCount: Int { entries.values.filter { $0.generation == generation }.count }

    mutating func noteAppearance() { generation &+= 1 }

    mutating func record(bundleId: String, forPid pid: Int) {
        guard !bundleId.isEmpty, pid > 0 else { return }
        if entries[pid] == nil {
            insertionOrder.append(pid)
            if insertionOrder.count > Self.maxEntries {
                entries[insertionOrder.removeFirst()] = nil
            }
        }
        entries[pid] = Entry(bundleId: bundleId, generation: generation)
    }

    func bundleId(forPid pid: Int) -> String? {
        guard let entry = entries[pid], entry.generation == generation else { return nil }
        return entry.bundleId
    }

    func hasEverSeen(pid: Int) -> Bool { entries[pid] != nil }
}
