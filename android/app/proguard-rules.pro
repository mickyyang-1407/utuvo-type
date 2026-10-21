# ML Kit（裝置端翻譯）靠反射從元件框架取實例：R8 最佳化後 RemoteModelManager.getInstance() 回 null，
# release 版一開設定頁就崩（2026-09-29 模擬器實測 NPE in MainSections）。整包保留，體積影響很小。
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google.firebase.components.** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }

# LiteRT-LM（手機上的智慧整理）：JNI 從原生端回呼 Kotlin 類別與欄位、Gson／kotlin-reflect 轉訊息格式，
# R8 改名或拿掉就會在載入模型時崩。整包保留。
-keep class com.google.ai.edge.litertlm.** { *; }
