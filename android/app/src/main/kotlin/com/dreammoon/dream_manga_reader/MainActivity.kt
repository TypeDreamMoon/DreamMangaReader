package com.dreammoon.dream_manga_reader

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 阅读器音量键翻页:阅读器打开且开启该设置时,拦截音量上/下键,转成翻页事件发给 Dart,
 * 并消费按键(不触发系统音量调节/音量条 UI)。其余情况一律放行,音量键照常工作。
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var volumeKeyPaging = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "setVolumeKeyPaging" -> {
                        volumeKeyPaging = call.arguments as? Boolean ?: false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (volumeKeyPaging && isVolumeKey(keyCode)) {
            // 首次按下才翻页(忽略长按重复),下一页/上一页 = 音量下/上。
            if (event.repeatCount == 0) {
                channel?.invokeMethod(
                    "volumeKey",
                    if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) "down" else "up"
                )
            }
            return true // 消费:不调音量、不弹音量条
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        // 抬起也一并消费,彻底压掉系统音量 UI。
        if (volumeKeyPaging && isVolumeKey(keyCode)) return true
        return super.onKeyUp(keyCode, event)
    }

    private fun isVolumeKey(keyCode: Int): Boolean =
        keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP

    companion object {
        private const val CHANNEL = "dream_manga_reader/reader_keys"
    }
}
