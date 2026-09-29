# ML Kit（裝置端翻譯）靠反射從元件框架取實例：R8 最佳化後 RemoteModelManager.getInstance() 回 null，
# release 版一開設定頁就崩（2026-09-29 模擬器實測 NPE in MainSections）。整包保留，體積影響很小。
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google.firebase.components.** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
