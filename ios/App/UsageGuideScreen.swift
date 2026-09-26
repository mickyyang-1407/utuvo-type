import SwiftUI

/// 使用教學（2026-09-24 Micky 實機回報：「搞不懂要怎麼設定才是對的，應該要有教學」）。
/// 內容對照目前實際行為：鍵盤不能直接開麥克風 → 第一次（或閒置 3 分鐘後）會跳到 UTUVO Type → 回到原 App 再點光球說。
struct UsageGuideScreen: View {
    var body: some View {
        List {
            Section {
                step(1, "加入鍵盤", "設定 → 一般 → 鍵盤 → 鍵盤 → 加入新鍵盤 → UTUVO Type。")
                step(2, "打開「允許完整存取」", "點進剛加入的 UTUVO Type，打開「允許完整存取」。沒有它，鍵盤沒辦法把你講的話交給 UTUVO Type 辨識。")
                step(3, "允許麥克風與語音辨識", "打開 UTUVO Type App 一次，系統問麥克風和語音辨識時都按「允許」。")
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("打開設定", systemImage: "arrow.up.forward.app")
                }
            } header: {
                Text("第一次設定（只要做一次）")
            }

            Section {
                step(1, "切到 UTUVO Type 鍵盤", "在任何 App 點輸入框，按鍵盤左下角的 🌐 切到 UTUVO Type。")
                step(2, "點光球", "第一次（或超過 3 分鐘沒用）會跳到 UTUVO Type App，替鍵盤打開麥克風。")
                step(3, "回到原本的 App", "點螢幕左上角的「◀︎ 原本 App 名稱」，或從螢幕最下方往右滑。")
                step(4, "再點一次光球開始說", "講完再點一次光球（或停下來），文字就會出現在游標處。")
                step(5, "之後就不用再跳", "在「鍵盤語音保持開啟」的時間內（預設 3 分鐘，可在設定改成 10、30 分鐘或 1 小時），點光球就直接開始聽。")
            } header: {
                Text("每次用鍵盤講話")
            } footer: {
                Text("為什麼會跳到 App：iOS 不允許鍵盤直接使用麥克風，所有語音鍵盤（包括 Typeless、Wispr Flow）都要先打開自己的 App。從 iOS 26.4 起，Apple 也不再讓任何 App 自動跳回原 App，所以要手動回去一次；把「鍵盤語音保持開啟」調長，就能少跳很多次。")
            }

            Section {
                tip("把常講的專有名詞加進字典", "設定 → 字典（選「新增詞彙」）。人名、品牌、術語（Atmos、Pro Tools…）加進去：英文專名貼上前會照字典改正拼法，高準確度辨識、雲端辨識和智慧整理也會參考這些詞。手機內建辨識本身不一定認得。")
                tip("智慧整理（預設開）", "講完先貼出辨識結果，再自動刪掉贅詞、改口、補標點。有 Apple Intelligence 的 iPhone 不用設定；也可以在「智慧整理」填自己的 key 用雲端模型。")
                tip("高準確度辨識", "設定 → 高準確度辨識，下載模型後，在 UTUVO Type App 裡聽寫會更準。鍵盤聽寫時 App 在背景，iOS 不允許背景使用 GPU，所以鍵盤不會用這個模型；鍵盤想更準請用下面的「雲端辨識」。")
                tip("雲端辨識（選配，需自己的 key）", "設定 → 智慧整理，存好 Gemini、Groq 或阿里雲百鍊的 key 後，打開「雲端辨識」。鍵盤和 App 講完的錄音會用你的 key 上傳辨識，專有名詞更準；失敗會自動改用手機辨識。錄音會離開手機，在意的話不要開。")
            } header: {
                Text("讓結果更準")
            }

            Section {
                tip("一直顯示「整理中」、沒出字", "打開 UTUVO Type 看畫面上的訊息；按「結束鍵盤語音」，回到原 App 再點一次光球。")
                tip("光球按了沒反應", "確認「允許完整存取」有打開，並且在 UTUVO Type 裡允許了麥克風。")
                tip("跳過去後回不來", "點螢幕左上角「◀︎」，或從螢幕最下方往右滑。iOS 不允許自動返回（Apple 在 iOS 26.4 關掉了這個能力）。")
            } header: {
                Text("遇到問題")
            }
        }
        .navigationTitle("使用教學")
    }

    private func step(_ n: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Aurora.orange))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func tip(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
