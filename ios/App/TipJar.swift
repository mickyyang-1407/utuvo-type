import StoreKit
import SwiftUI

/// 幫我加油（2026-09-26 Micky：「像 Buy Me a Coffee」；選 App 內購買小費——外部付款連結在美國以外會被 3.1.1 退件）。
/// 三個消耗型項目，**不解鎖任何功能**；買完只說謝謝。沒有伺服器，交易只在 StoreKit 裡完成。
enum TipJar {
    static let productIDs = ["com.utuvo.type.ios.tip.coffee", "com.utuvo.type.ios.tip.lunch", "com.utuvo.type.ios.tip.boost"]

    static func emoji(for id: String) -> String {
        switch id {
        case "com.utuvo.type.ios.tip.coffee": return "☕️"
        case "com.utuvo.type.ios.tip.lunch": return "🍱"
        default: return "🚀"
        }
    }

    /// 由便宜到貴；價格一樣照 productIDs 的順序（商店回傳順序不固定）。
    static func ordered<T>(_ items: [T], id: (T) -> String, price: (T) -> Decimal) -> [T] {
        items.sorted { a, b in
            price(a) != price(b) ? price(a) < price(b)
                : (productIDs.firstIndex(of: id(a)) ?? .max) < (productIDs.firstIndex(of: id(b)) ?? .max)
        }
    }

    /// 背景完成的加油（家長同意 Ask to Buy 核准後）：畫面收到這個通知就說謝謝、清掉那一筆的「等待核准」。
    static let completedNotification = Notification.Name("utuvo.type.tipJar.completed")
    /// 背景完成但當下沒有畫面在看（例如 App 關著時被核准）：記下來，下次打開加油頁再說謝謝。
    static let pendingThanksKey = "utuvo.type.tipJar.pendingThanks"

    /// 家長同意（Ask to Buy）等延遲完成的交易：App 一啟動就收，驗證過就 finish，免得一直掛著；
    /// 是加油品項就通知畫面（review 0.2.4 R1：只 finish 不通知，核准後畫面一直停在「等待核准」）。
    static func startListening() {
        Task.detached {
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                if productIDs.contains(transaction.productID) {
                    let productID = transaction.productID
                    await MainActor.run {
                        UserDefaults.standard.set(true, forKey: pendingThanksKey)
                        NotificationCenter.default.post(name: completedNotification, object: nil, userInfo: ["productID": productID])
                    }
                }
            }
        }
    }
}

@MainActor
final class TipJarModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, unavailable }

    @Published private(set) var products: [Product] = []
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var purchasing: String?
    @Published var thanks = false
    @Published var message: String?
    /// 完成交易（消耗型一定要 finish，不然每次開 App 都會再收到一次）。測試換成計數器來確認有呼叫。
    var finish: (StoreKit.Transaction) async -> Void = { await $0.finish() }
    /// 在等家長同意的筆數（同一品項可能買了好幾次）：全部核准完才清掉「等待核准」訊息。
    @Published private(set) var awaitingApproval: [String: Int] = [:]
    // deinit 不在 MainActor 上：只在 init 寫一次、deinit 讀一次，不會同時存取。
    nonisolated(unsafe) private var completion: NSObjectProtocol?

    init() {
        completion = NotificationCenter.default.addObserver(forName: TipJar.completedNotification, object: nil, queue: .main) { [weak self] note in
            let productID = note.userInfo?["productID"] as? String
            MainActor.assumeIsolated { self?.completedInBackground(productID: productID) }
        }
        consumePendingThanks()
    }

    deinit {
        if let completion { NotificationCenter.default.removeObserver(completion) }
    }

    func completedInBackground(productID: String?) {
        if let productID, let n = awaitingApproval[productID] {
            awaitingApproval[productID] = n > 1 ? n - 1 : nil
        }
        consumePendingThanks()
    }

    /// 背景完成過的加油：說一次謝謝就清掉旗標；還有別筆在等核准就留著「等待核准」。
    func consumePendingThanks() {
        guard UserDefaults.standard.bool(forKey: TipJar.pendingThanksKey) else { return }
        UserDefaults.standard.removeObject(forKey: TipJar.pendingThanksKey)
        if awaitingApproval.isEmpty { message = nil }
        thanks = true
    }

    func load() async {
        do {
            let fetched = try await Product.products(for: TipJar.productIDs)
            products = TipJar.ordered(fetched, id: \.id, price: \.price)
            phase = products.isEmpty ? .unavailable : .ready
        } catch {
            phase = .unavailable
        }
    }

    func buy(_ product: Product) async {
        purchasing = product.id
        defer { purchasing = nil }
        message = nil
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await finish(transaction)
                thanks = true
            case .success(.unverified):
                message = String(localized: "App Store 沒辦法確認這筆交易，沒有扣款的話可以再試一次。")
            case .pending:
                awaitingApproval[product.id, default: 0] += 1
                message = String(localized: "等待核准中（例如家長同意），完成後會自動入帳。")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = String(localized: "沒有完成：\(error.localizedDescription)")
        }
    }
}

struct TipJarScreen: View {
    @StateObject private var model = TipJarModel()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("UTUVO Type 免費、沒有廣告，也沒有自己的伺服器。")
                        .font(.body.weight(.semibold))
                    Text("如果它幫你省下打字的時間，歡迎請我喝杯咖啡，讓我繼續把它做得更好。")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                switch model.phase {
                case .loading:
                    HStack { ProgressView(); Text("讀取中…").foregroundStyle(.secondary) }
                case .unavailable:
                    Text("現在連不到 App Store，稍後再試。")
                        .foregroundStyle(.secondary)
                case .ready:
                    ForEach(model.products, id: \.id) { product in
                        HStack(spacing: 14) {
                            Text(TipJar.emoji(for: product.id)).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.displayName).font(.body.weight(.semibold))
                                Text(product.description).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await model.buy(product) }
                            } label: {
                                if model.purchasing == product.id { ProgressView() } else { Text(product.displayPrice) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Aurora.orange)
                            .disabled(model.purchasing != nil)
                            .accessibilityIdentifier("tip:\(product.id)")
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("加油是一次性的小費，不會解鎖任何功能，也不會自動續訂。")
            }
        }
        .navigationTitle("幫我加油")
        .task { await model.load() }
        .alert("謝謝你的加油！", isPresented: $model.thanks) {
            Button("不客氣") {}
        } message: {
            Text("收到了 🧡 我會繼續把 UTUVO Type 做得更好。")
        }
    }
}
