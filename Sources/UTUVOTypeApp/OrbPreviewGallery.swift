import SwiftUI

/// Explicit isolated developer preview, never shown in the normal product flow.
struct OrbPreviewGallery: View {
    let model: AppModel
    let overlay: OverlayWindowController
    @State private var dark = false
    @State private var reduced = false
    @State private var diagnostics = "尚未顯示"
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Type · 聆聽光球").font(.title2.weight(.semibold))
                Spacer()
                Toggle("深色背景", isOn: $dark)
                Toggle("減少動態", isOn: $reduced)
            }
            HStack(spacing: 18) {
                sample("安靜聆聽", phase: .listening, db: -85)
                sample("說話中", phase: .listening, db: -24)
                sample("整理中", phase: .processing, db: -85)
            }
            HStack {
                Button("顯示聆聽光球") { overlay.showPreview(model: model, listening: true, position: .bottom); refresh() }
                Button("顯示整理光球") { overlay.showPreview(model: model, listening: false, position: .bottom); refresh() }
                Button("隱藏光球") { overlay.hide(); refresh() }
                Button("更新繪製狀態") { refresh() }
            }
            Text(diagnostics).font(.system(.caption, design: .monospaced))
            Text("隔離預覽・合成音量，不使用麥克風或個人資料").font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 660, height: 340)
        .background(dark ? Color(red: 0.055, green: 0.065, blue: 0.085) : Color(red: 0.96, green: 0.95, blue: 0.93))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
    private func sample(_ name: String, phase: VoiceOrbView.Phase, db: Float) -> some View {
        VStack(spacing: 0) {
            OrbPreviewSurface(phase: phase, db: db, reduceMotion: reduced, dark: dark)
                .frame(width: 170, height: 170)
            Text(name).font(.callout)
        }.frame(maxWidth: .infinity)
    }
    private func refresh() { diagnostics = overlay.previewDiagnostics }
}
