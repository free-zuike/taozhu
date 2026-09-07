android {
    signingConfigs {
        create("release") {
            storeFile = file("taozhu-release.keystore")
            storePassword = System.getenv("ANDROID_KEYSTORE_STORE_PASS")
            keyAlias = System.getenv("ANDROID_KEYSTORE_ALIAS")
            keyPassword = System.getenv("ANDROID_KEYSTORE_KEY_PASS")
        }
    }
    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
            // 关闭 R8/资源压缩：规避 release 闪退（功能型小应用无混淆收益）
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}