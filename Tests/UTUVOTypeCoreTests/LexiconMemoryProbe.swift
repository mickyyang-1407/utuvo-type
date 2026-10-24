import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif

// 詞庫「留在映射的檔案裡、沒被整份讀進記憶體」的檢查工具（FX-10）。
//
// 為什麼不能只看 phys_footprint 前後差：完整 `swift test` 跑到後段時，heap 會重用前面測試已釋放、
// 但仍計入 footprint 的記憶體，連「真的把整檔讀進 heap」的對照都量到 0 bytes——那時 footprint 測試
// 什麼也沒檢查卻是綠的，對照本身則看測試順序紅綠。
//
// - `MappedFileProbe`（主檢查，跟 heap 歷史與測試順序無關）：問 kernel 位元組所在的 VM region 背後是
//   哪個檔（裝置號＋inode＋檔內位移）。heap 複本落在匿名 region，一定被判「不是檔案映射」。
// - `FootprintGate`（輔助）：footprint 斷言只在「同一個行程狀態下，整檔讀進 heap 的對照看得見」時才給數字；
//   看不見就把原因印在測試輸出、不給數字，呼叫端不斷言，結構檢查照跑。

enum MappedFileProbe {
    struct Region: CustomStringConvertible {
        let start: UInt64
        let end: UInt64
        /// region 起點對應的檔內位移。
        let fileOffset: UInt64
        /// 背後的檔；匿名記憶體（heap、anonymous mmap）＝nil。
        let device: UInt32?
        let inode: UInt64?
        let path: String

        var description: String {
            let range = "0x" + String(start, radix: 16) + "-0x" + String(end, radix: 16)
            guard let device, let inode else { return "\(range) 匿名記憶體（heap／anonymous）" }
            return "\(range) \(path)（dev \(device) ino \(inode) off \(fileOffset)）"
        }
    }

    /// 非 Darwin 平台沒有 proc_pidinfo：明講跳過的原因。
    static func requireAvailable() throws {
        #if !canImport(Darwin)
        throw XCTSkip("此平台沒有 proc_pidinfo，無法檢查詞庫是不是檔案映射")
        #endif
    }

    /// `address` 所在的 VM region；位址沒被映射或平台不支援回 nil。
    static func region(containing address: UnsafeRawPointer) -> Region? {
        #if canImport(Darwin)
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        let addr = UInt64(UInt(bitPattern: address))
        guard proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, addr, &info, size) == size else { return nil }
        let start = info.prp_prinfo.pri_address
        let end = start + info.prp_prinfo.pri_size
        // 位址落在洞裡時 kernel 回報的是「下一個」region，不能當成命中
        guard start <= addr, addr < end else { return nil }
        let path = withUnsafeBytes(of: info.prp_vip.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let st = info.prp_vip.vip_vi.vi_stat
        let fileBacked = !path.isEmpty || st.vst_ino != 0
        return Region(start: start, end: end, fileOffset: info.prp_prinfo.pri_offset,
                      device: fileBacked ? st.vst_dev : nil,
                      inode: fileBacked ? st.vst_ino : nil,
                      path: path)
        #else
        return nil
        #endif
    }

    /// `bytes` 是不是 `file` 整檔的映射：長度等於檔長，頭尾位元組都落在背後是這個檔（同裝置號＋inode）的
    /// region，且位址換算回檔內位移正好是 0 與檔長−1。是＝回 nil；不是＝回原因（給斷言訊息）。
    static func mismatch(_ bytes: UnsafeRawBufferPointer, wholeFile file: URL) -> String? {
        #if canImport(Darwin)
        var st = stat()
        guard stat(file.path, &st) == 0 else { return "stat 失敗：\(file.path)" }
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return "沒有位元組" }
        guard bytes.count == Int(st.st_size) else { return "位元組數 \(bytes.count) ≠ \(file.lastPathComponent) 檔長 \(st.st_size)" }
        for (name, offset) in [("頭", 0), ("尾", bytes.count - 1)] {
            let p = base + offset
            guard let r = region(containing: p) else { return "\(name)位元組 \(p) 不在任何 VM region 裡" }
            guard let dev = r.device, let ino = r.inode else {
                return "\(name)位元組在 \(r)：不是檔案映射，是複本"
            }
            guard dev == UInt32(bitPattern: st.st_dev), ino == st.st_ino else {
                return "\(name)位元組映射的是別的檔 \(r)，不是 \(file.lastPathComponent)（dev \(st.st_dev) ino \(st.st_ino)）"
            }
            let fileOffset = r.fileOffset + (UInt64(UInt(bitPattern: p)) - r.start)
            guard fileOffset == UInt64(offset) else {
                return "\(name)位元組對到檔內位移 \(fileOffset)，應為 \(offset)（\(r)）"
            }
        }
        return nil
        #else
        return "此平台沒有 proc_pidinfo"
        #endif
    }
}

enum FootprintGate {
    /// 行程的 phys_footprint（Jetsam 用來判定鍵盤 extension 記憶體上限的同一個數字）。
    static func physFootprint() -> Int? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : nil
        #else
        return nil
        #endif
    }

    /// 跑 `body` 並量它讓 footprint 長了多少；`delta` 只在儀器此刻看得見「把 `file` 整份讀進 heap」時才有值：
    /// 1. 先請 malloc 把已釋放的頁還給系統（提高看得見的機率；不倚賴它）。
    /// 2. 對照：把 `file` 整份讀進 heap（`Data(contentsOf:)`，正是「拿掉 .alwaysMapped」的退化讀法），
    ///    footprint 要長超過檔長一半。看不見＝把原因印在測試輸出、`delta` 為 nil，呼叫端不斷言。
    /// 3. 對照的複本留著不放（`body` 不能回收再用它的記憶體），在同一個狀態下量 `body`。
    static func measure<T>(_ label: String, wholeFileReadOf file: URL,
                           _ body: () throws -> T) throws -> (value: T, delta: Int?) {
        guard physFootprint() != nil else {
            print("[footprint] \(label)：此平台沒有 phys_footprint，footprint 斷言不評估；結構檢查照跑")
            return (try body(), nil)
        }
        #if canImport(Darwin)
        _ = malloc_zone_pressure_relief(nil, 0)
        #endif
        let c0 = physFootprint()!
        let control = try Data(contentsOf: file)
        let c1 = physFootprint()!
        let seen = c1 - c0
        guard seen > control.count / 2 else {
            print("[footprint] \(label)：儀器此刻看不見——對照把 \(file.lastPathComponent) 整份 \(control.count) bytes"
                  + " 讀進 heap，footprint 只長 \(seen) bytes（heap 在重用已釋放、仍計入 footprint 的記憶體）。"
                  + "footprint 斷言不評估；結構檢查照跑。")
            return (try body(), nil)
        }
        return try withExtendedLifetime(control) {
            let before = physFootprint()!
            let value = try body()
            let after = physFootprint()!
            print("[footprint] \(label)：對照整檔讀入 +\(seen) bytes（看得見）；受測 +\(after - before) bytes，門檻 < \(control.count / 2)")
            return (value, after - before)
        }
    }
}
