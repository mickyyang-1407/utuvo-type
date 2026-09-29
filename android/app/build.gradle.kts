plugins {
    id("com.android.application")
}

android {
    namespace = "com.utuvo.type"
    compileSdk = 36

    defaultConfig {
        // ⚠️ 上架 Google Play 後套件名稱就改不了——第一次上傳前確認（暫定 com.utuvo.type）。
        applicationId = "com.utuvo.type"
        minSdk = 29
        targetSdk = 36
        versionCode = 2
        versionName = "0.2.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // 詞庫 .dat 與 iOS 共用同一份（不複製），以不壓縮方式打包，才能直接 mmap。
    sourceSets {
        getByName("main") {
            assets.srcDir("../../ios/Keyboard/Resources")
            // OpenCC 詞表（繁體修正）同樣跟 iOS 共用一份，執行期從 assets 讀 `OpenCC/<name>.txt`。
            assets.srcDir("../../ios/Shared/Resources")
            // 2026-09-20 runtime 票：catalog.json + computing.txt 等（CONTRACT-V2 schema 2 metadata + 分檔詞表）。
            // 不壓縮 txt（runtime 端用 UTF-8 讀檔，壓縮會被 AssetManager 解開，反而慢）。
            assets.srcDir("../../data")
        }
        // 手機上跑同一批 Swift 標準答案（Android 的 regex／BreakIterator 是 ICU，跟電腦 JVM 不同）
        getByName("androidTest") { assets.srcDir("../core/src/test/resources/golden") }
    }
    androidResources { noCompress += "dat" }
    androidResources { noCompress += "txt" }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation(project(":core"))
    implementation("com.google.mlkit:translate:17.0.3")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
    // JVM 測試（雲端辨識的請求形狀；不打真網路）。org.json 執行期由 Android 系統提供，電腦上才另外帶。
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
}

// B4：ZhHansCompletenessTest 直接從磁碟讀 res/values*/strings.xml，這兩個檔案不在
// unit test task 的輸入裡——只改字串時 Gradle 會判 UP-TO-DATE 直接跳過，檢查等於沒有跑。
// 明列成 input，改動字串必定重跑。
tasks.withType<Test>().configureEach {
    inputs.files("src/main/res/values/strings.xml", "src/main/res/values-zh-rCN/strings.xml")
        .withPropertyName("localizedStringResources")
}
