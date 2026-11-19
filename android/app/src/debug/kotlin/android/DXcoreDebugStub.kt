package android

/**
 * Debug-only DXcore stand-in.
 *
 * The production DXcore AAR is still linked into release builds. This class
 * exists only so the debug APK can compile alongside Xray's gomobile runtime,
 * which ships a different libgojni.so and cannot safely coexist with DXcore.
 * Automatic-mode native networking is intentionally unavailable in this APK.
 */
interface SocketProtector {
    fun protect(fileDescriptor: Int): Boolean
}

interface ProgressListener {
    fun onProgress(msg: String?)
}

interface CrashListener {
    fun onCrash(functionName: String, errorMessage: String, stackTrace: String)
}

object Android {
    @JvmStatic fun setSocketProtector(protector: SocketProtector?) {}
    @JvmStatic fun setSplitTunnel(mode: String, rules: String, apps: String) {}
    @JvmStatic fun startTunnel(fd: Long): Boolean = false
    @JvmStatic fun stopVPN() {}
    @JvmStatic fun stopTunnel() {}
    @JvmStatic fun measurePing(): Long = 0L
    @JvmStatic fun startVPN(cacheDir: String, flowLine: String, pattern: String, deepScan: Boolean, healthCheck: Boolean) {}
    @JvmStatic fun getFlag(): String = ""
    @JvmStatic fun setAsnName() {}
    @JvmStatic fun setTimeZone(timezone: Float) {}
    @JvmStatic fun getFlowLine(isTest: Boolean, token: String): String = ""
    @JvmStatic fun getCachedFlowLine(): String = ""
    @JvmStatic fun decodeAndVerifyFlowline(flowLine: String): String = ""
    @JvmStatic fun log(message: String) {}
    @JvmStatic fun setCacheDir(cacheDir: String) {}
    @JvmStatic fun login(email: String, password: String): String = ""
    @JvmStatic fun loginByCode(code: String): String = ""
    @JvmStatic fun setProgressListener(listener: ProgressListener?) {}
    @JvmStatic fun setCrashCallback(listener: CrashListener?) {}
}
