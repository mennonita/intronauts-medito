package meditofoundation.medito

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.WindowManager
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

internal object TimerDeviceChannel {
    private const val CHANNEL_NAME = "intronauts/timer_device"
    private const val MAX_SHORTCUTS = 4
    private const val BELL_PULSE_MS = 400L
    private const val BELL_GAP_MS = 600L

    fun register(messenger: BinaryMessenger, activity: Activity) {
        MethodChannel(messenger, CHANNEL_NAME).setMethodCallHandler { call, result ->
            activity.runOnUiThread {
                try {
                    when (call.method) {
                        "keepScreenOn" -> {
                            val on = requireNotNull(call.argument<Boolean>("on"))
                            val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                            if (on) activity.window.addFlags(flag) else activity.window.clearFlags(flag)
                            result.success(null)
                        }
                        "mediaVolume" -> {
                            val audio = checkNotNull(activity.getSystemService(AudioManager::class.java))
                            result.success(
                                mapOf(
                                    "current" to audio.getStreamVolume(AudioManager.STREAM_MUSIC),
                                    "max" to audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                                )
                            )
                        }
                        "setShortcuts" -> {
                            val shortcuts = requireNotNull(call.argument<List<Map<String, String>>>("shortcuts"))
                            setShortcuts(activity.applicationContext, shortcuts)
                            result.success(null)
                        }
                        "vibrateBell" -> {
                            val repeats = requireNotNull(call.argument<Int>("repeats"))
                            vibrateBell(activity.applicationContext, repeats)
                            result.success(null)
                        }
                        "timeZoneId" -> result.success(TimeZone.getDefault().id)
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("TIMER_DEVICE", error.message, null)
                }
            }
        }
    }

    private fun setShortcuts(context: Context, specs: List<Map<String, String>>) {
        // El lanzador muestra los atajos debajo del alias del ícono activo.
        val launcherIntent = Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .setPackage(context.packageName)
        val launcherAlias = context.packageManager.queryIntentActivities(launcherIntent, 0)
            .firstOrNull { it.activityInfo.targetActivity == MainActivity::class.java.name }
            ?.activityInfo
            ?.let { ComponentName(it.packageName, it.name) }
        val shortcuts = specs.take(MAX_SHORTCUTS).map { spec ->
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(spec.getValue("uri")))
                .setPackage(context.packageName)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            ShortcutInfoCompat.Builder(context, spec.getValue("id"))
                .setShortLabel(spec.getValue("shortLabel"))
                .setLongLabel(spec.getValue("longLabel"))
                .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
                .setIntent(intent)
                .apply { launcherAlias?.let { setActivity(it) } }
                .build()
        }
        check(ShortcutManagerCompat.setDynamicShortcuts(context, shortcuts)) {
            "No se pudieron actualizar los atajos del temporizador."
        }
    }

    private fun vibrateBell(context: Context, repeats: Int) {
        require(repeats > 0)
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            context.getSystemService(Vibrator::class.java)
        }
        if (vibrator == null || !vibrator.hasVibrator()) return

        // El primer valor es la espera inicial. Después se alternan pulso y pausa.
        val timings = LongArray(Math.multiplyExact(repeats, 2)) { index ->
            when {
                index == 0 -> 0L
                index % 2 == 1 -> BELL_PULSE_MS
                else -> BELL_GAP_MS
            }
        }
        val effect = VibrationEffect.createWaveform(timings, -1)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            vibrator.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(effect, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
        }
    }
}
