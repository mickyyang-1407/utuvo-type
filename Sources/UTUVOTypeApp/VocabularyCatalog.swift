import Foundation

/// 詞庫目錄（2026-09-20 runtime 票，依 CONTRACT-V2.md 改 schema 2）。
///
/// 與 iOS `ios/Shared/VocabularyCatalog.swift` 共用同一份 schema 2 的 catalog.json
/// 與同一份選擇術語 (selector) 邏輯。Mac 端的差異只在打包（Bundle.module vs xcodegen
/// folder reference 與隨函式庫查找）——純模型資料完全一致，方便測試與 fixture 互通。
///
/// 安全要求：
/// - metadata 與 terms 分檔，不再開機就把 40 萬詞全塞進記憶體；
/// - 各包 `terms` 與 `seedTerms` 只在載入後存在；未載入的包＝nil／空集合；
/// - 從固定 id 推導檔名（`id + ".txt"`）——禁止任意路徑讀檔，避免讀到正式 catalog 外的資源。
enum VocabularyCatalog {
    /// 來自 catalog.json metadata 的一包；`terms` 預設為 nil（未載入）。
    struct Pack: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let summary: String
        let sourceName: String
        let sourceURL: String
        let licenseName: String
        let licenseURL: String
        let attribution: String
        let version: String
        let defaultOn: Bool
        let seedTerms: [String]
        let termCount: Int
        let termsSHA256: String
        /// 真實詞表（讀過 `termsFile` 後才有；未讀＝nil）。UI 不應直接 map 此陣列。
        var terms: [String]?
        let termsFile: String
    }

    struct Catalog: Sendable, Equatable {
        let schemaVersion: Int
        let packs: [Pack]
        static let empty = Catalog(schemaVersion: 0, packs: [])
        func pack(id: String) -> Pack? { packs.first { $0.id == id } }
        /// 固定六包 id（CONTRACT-V2 §1）。
        static let knownIDs: [String] = ["computing", "medicine", "finance", "law", "engineering", "music"]
    }

    enum LoadError: Error, Equatable {
        case missingResource
        case malformedJSON
        case unsupportedSchema(Int)
    }

    /// 從 Bundle 載入 metadata。Mac 上打包成 `data/vocabulary/catalog.json`。
    static func load(from bundle: Bundle = VocabularyPacks.resourceBundle, resource: String = "vocabulary/catalog") throws -> Catalog {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw LoadError.missingResource
        }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    /// 純 JSON 解析（測試與合成 fixture 共用）。不會觸發任何詞表讀檔。
    static func decode(_ data: Data) throws -> Catalog {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any] else { throw LoadError.malformedJSON }
        let schema = obj["schemaVersion"] as? Int ?? 0
        guard schema == 2 else { throw LoadError.unsupportedSchema(schema) }
        guard let arr = obj["packs"] as? [[String: Any]] else { throw LoadError.malformedJSON }
        var packs: [Pack] = []
        packs.reserveCapacity(arr.count)
        for raw in arr {
            guard let id = raw["id"] as? String,
                  let name = raw["name"] as? String else { continue }
            let summary = (raw["summary"] as? String) ?? ""
            let sourceName = (raw["sourceName"] as? String) ?? ""
            let sourceURL = (raw["sourceURL"] as? String) ?? ""
            let licenseName = (raw["licenseName"] as? String) ?? ""
            let licenseURL = (raw["licenseURL"] as? String) ?? ""
            let attribution = (raw["attribution"] as? String) ?? ""
            let version = (raw["version"] as? String) ?? ""
            let defaultOn = (raw["defaultOn"] as? Bool) ?? false
            let seedTerms = (raw["seedTerms"] as? [String]) ?? []
            let termCount = (raw["termCount"] as? Int) ?? 0
            let termsSHA256 = (raw["termsSHA256"] as? String) ?? ""
            let termsFile = (raw["termsFile"] as? String) ?? ""
            packs.append(Pack(id: id, name: name, summary: summary,
                              sourceName: sourceName, sourceURL: sourceURL,
                              licenseName: licenseName, licenseURL: licenseURL,
                              attribution: attribution, version: version,
                              defaultOn: defaultOn, seedTerms: seedTerms,
                              termCount: termCount, termsSHA256: termsSHA256,
                              terms: nil, termsFile: termsFile))
        }
        return Catalog(schemaVersion: schema, packs: packs)
    }
}