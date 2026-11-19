package de.unboundtech.defyxvpn

import android.content.Context
import android.provider.Settings
import android.util.Base64
import android.util.Log
import go.Seq
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray

/**
 * Owns only the Xray core lifecycle.
 *
 * The existing DefyxVpnService remains the sole owner of Android's VPN
 * permission and TUN interface. This class borrows the already-established
 * TUN file descriptor and never creates or closes a VPN interface.
 */
internal class XrayEngine private constructor(context: Context) {
    companion object {
        private const val TAG = "VELEVEN-Xray"
        private const val ASSET_DIRECTORY = "xray"

        @Volatile
        private var instance: XrayEngine? = null

        fun getInstance(context: Context): XrayEngine =
            instance ?: synchronized(this) {
                instance ?: XrayEngine(context.applicationContext).also { instance = it }
            }
    }

    private val controller: CoreController

    init {
        val appContext = context.applicationContext
        val assetPath = appContext.getDir(ASSET_DIRECTORY, Context.MODE_PRIVATE).absolutePath
        val deviceKey = createDeviceKey(appContext)

        // AndroidLibXrayLite keeps process-wide Go runtime state.
        Seq.setContext(appContext)
        Libv2ray.initCoreEnv(assetPath, deviceKey)

        controller = Libv2ray.newCoreController(object : CoreCallbackHandler {
            override fun startup(): Long {
                Log.i(TAG, "Xray core started")
                return 0
            }

            override fun shutdown(): Long {
                Log.i(TAG, "Xray core stopped")
                return 0
            }

            override fun onEmitStatus(level: Long, message: String?): Long {
                // Do not log configuration text or credentials.
                Log.d(TAG, "Core status level=$level")
                return 0
            }
        })
    }

    @Synchronized
    fun start(configJson: String, tunFileDescriptor: Int) {
        require(configJson.isNotBlank()) { "Xray configuration is empty" }
        require(tunFileDescriptor > 0) { "VPN interface is not established" }
        check(!controller.isRunning) { "Xray core is already running" }

        controller.startLoop(configJson, tunFileDescriptor)
        check(controller.isRunning) { "Xray core did not start" }
    }

    @Synchronized
    fun stop() {
        if (controller.isRunning) {
            controller.stopLoop()
        }
    }

    @Synchronized
    fun isRunning(): Boolean = controller.isRunning

    private fun createDeviceKey(context: Context): String {
        val androidId = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ANDROID_ID
        ).orEmpty().toByteArray(Charsets.UTF_8)

        val keyBytes = ByteArray(32)
        androidId.copyInto(keyBytes, endIndex = minOf(androidId.size, keyBytes.size))
        return Base64.encodeToString(
            keyBytes,
            Base64.NO_PADDING or Base64.URL_SAFE
        )
    }
}
