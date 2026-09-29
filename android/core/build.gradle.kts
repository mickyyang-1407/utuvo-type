// 純 Kotlin／JVM 模組：文字整理、注音、拼音。不碰 Android API，測試在電腦上直接跑（不用模擬器）。
plugins {
    kotlin("jvm")
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    // org.json：Android 內建（執行期由系統提供），電腦上測試才另外帶。
    compileOnly("org.json:json:20250517")
    testImplementation(kotlin("test"))
    testImplementation("org.json:json:20250517")
}

tasks.test {
    useJUnitPlatform()
    // 詞庫與 iOS 共用同一份檔案（不複製），測試直接讀 ios/Keyboard/Resources。
    systemProperty("utuvo.resources", rootDir.resolve("../ios/Keyboard/Resources").canonicalPath)
    // OpenCC 詞表跟 iOS 共用同一份（不複製），繁體修正的測試直接讀。
    systemProperty("utuvo.opencc", rootDir.resolve("../ios/Shared/Resources/OpenCC").canonicalPath)
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}
