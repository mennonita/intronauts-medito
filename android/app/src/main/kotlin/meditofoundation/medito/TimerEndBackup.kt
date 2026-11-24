package meditofoundation.medito

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/** Datos del aviso de respaldo; los textos vienen de Dart (ya traducidos). */
internal data class TimerBackupRequest(
    val runId: String,
    val title: String?,
    val body: String?,
    val output: String?,
    val channelName: String?,
    val silentChannelName: String?
)

/** Alarmas del sistema (AlarmManager real o una falsa en pruebas). */
internal interface AlarmBackend {
    fun canScheduleExact(): Boolean
    fun setExact(triggerAtElapsedMs: Long, request: TimerBackupRequest)
    fun setInexact(triggerAtElapsedMs: Long, request: TimerBackupRequest)
    fun cancel()
}

/** Reloj desde el arranque del teléfono: un cambio de hora no lo mueve (R60). */
internal fun interface ElapsedClock {
    fun elapsedRealtime(): Long
}

/**
 * Programa UNA alarma de respaldo por sesión de cuenta regresiva (§4.7): si la
 * campana final no llegó a sonar (proceso muerto), el aviso «Terminó tu
 * meditación» sale 10 s después del final planeado.
 */
internal class TimerEndBackupScheduler(
    private val alarm: AlarmBackend,
    private val clock: ElapsedClock
) {
    companion object {
        const val GRACE_MS = 10_000L
    }

    /** Devuelve el momento programado (reloj desde el arranque) o null si no hace falta. */
    fun schedule(
        request: TimerBackupRequest,
        prepMs: Long,
        plannedMs: Long,
        extraTime: Boolean,
        isStopwatch: Boolean,
        positionMs: Long,
        endPassed: Boolean
    ): Long? {
        // Cronómetro: sin alarma. Tiempo extra: hasta el fin planeado, como la cuenta
        // regresiva (R105). Después del final: nunca (R79).
        if (isStopwatch || endPassed) {
            alarm.cancel()
            return null
        }
        val remaining = prepMs + plannedMs - positionMs
        if (remaining <= 0L) {
            alarm.cancel()
            return null
        }
        val trigger = clock.elapsedRealtime() + remaining + GRACE_MS
        if (alarm.canScheduleExact()) alarm.setExact(trigger, request) else alarm.setInexact(trigger, request)
        return trigger
    }

    fun cancel() {
        alarm.cancel()
    }
}

/** Qué hace el receptor cuando suena la alarma. */
internal enum class TimerBackupAction {
    /** La sesión sigue viva: nada que avisar; se reprograma desde el reproductor. */
    RESCHEDULE_LIVE,
    /** La sesión ya terminó o es otra: no hacer nada. */
    IGNORE,
    /** Sesión muerta sin permiso de notificaciones: sólo restaurar «No molestar». */
    RESTORE_ONLY,
    /** Sesión muerta: restaurar «No molestar» (si es suyo) y avisar. */
    POST
}

internal object TimerEndBackupDecision {
    fun decide(
        runId: String?,
        serviceActive: Boolean,
        serviceRunId: String?,
        storedRunId: String?,
        storedEnded: Boolean,
        canNotify: Boolean
    ): TimerBackupAction {
        if (runId == null) return TimerBackupAction.IGNORE
        // Primero: ¿la sesión sigue viva en este mismo proceso?
        if (serviceActive && serviceRunId == runId) return TimerBackupAction.RESCHEDULE_LIVE
        if (storedRunId != runId || storedEnded) return TimerBackupAction.IGNORE
        return if (canNotify) TimerBackupAction.POST else TimerBackupAction.RESTORE_ONLY
    }

    fun shouldRestoreDnd(dndOwner: String?, runId: String): Boolean = dndOwner == runId

    /** Un canal por salida: Android guarda sonido y vibración por canal (R110). */
    fun channelId(output: String?): String = when (output) {
        "vibration" -> TimerEndBackup.SILENT_CHANNEL_ID
        "soundAndVibration" -> TimerEndBackup.SOUND_VIBRATION_CHANNEL_ID
        else -> TimerEndBackup.CHANNEL_ID
    }

    fun vibrates(output: String?): Boolean = output == "vibration" || output == "soundAndVibration"
}

internal object TimerEndBackup {
    private const val TAG = "TimerEndBackup"
    const val REQUEST_CODE = 7001
    const val NOTIFICATION_ID = 7001
    const val CHANNEL_ID = "timer_end_backup"
    const val SILENT_CHANNEL_ID = "timer_end_backup_silent"
    const val SOUND_VIBRATION_CHANNEL_ID = "timer_end_backup_vibrate"
    const val RUN_PREFS = "intronauts_timer_run"
    private const val KEY_RUN_ID = "runId"
    private const val KEY_ENDED = "ended"
    const val EXTRA_RUN_ID = "runId"
    const val EXTRA_TITLE = "title"
    const val EXTRA_BODY = "body"
    const val EXTRA_OUTPUT = "output"
    const val EXTRA_CHANNEL_NAME = "channelName"
    const val EXTRA_SILENT_CHANNEL_NAME = "silentChannelName"
    private val vibrationPattern = longArrayOf(0, 400, 600, 400, 600, 400)

    fun scheduler(context: Context): TimerEndBackupScheduler =
        TimerEndBackupScheduler(AndroidAlarmBackend(context.applicationContext), ElapsedClock { SystemClock.elapsedRealtime() })

    /** Estado de la sesión que lee el receptor aunque Flutter no esté corriendo. */
    fun writeRunState(context: Context, runId: String?, ended: Boolean) {
        try {
            val saved = context.getSharedPreferences(RUN_PREFS, Context.MODE_PRIVATE).edit()
                .putString(KEY_RUN_ID, runId)
                .putBoolean(KEY_ENDED, ended)
                .commit()
            if (!saved) Log.e(TAG, "No se pudo guardar el estado de la sesión")
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo guardar el estado de la sesión", error)
        }
    }

    /** Marca terminada la sesión [runId] (sólo si sigue siendo la guardada). */
    fun markEnded(context: Context, runId: String?) {
        if (runId == null) return
        val prefs = context.getSharedPreferences(RUN_PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY_RUN_ID, null) != runId) return
        writeRunState(context, runId, ended = true)
    }

    internal fun readRunState(context: Context): Pair<String?, Boolean> {
        val prefs = context.getSharedPreferences(RUN_PREFS, Context.MODE_PRIVATE)
        return prefs.getString(KEY_RUN_ID, null) to prefs.getBoolean(KEY_ENDED, true)
    }

    internal fun pendingIntent(context: Context, request: TimerBackupRequest?, create: Boolean): PendingIntent? {
        val intent = Intent(context, TimerEndBackupReceiver::class.java)
        if (request != null) {
            intent.putExtra(EXTRA_RUN_ID, request.runId)
            intent.putExtra(EXTRA_TITLE, request.title)
            intent.putExtra(EXTRA_BODY, request.body)
            intent.putExtra(EXTRA_OUTPUT, request.output)
            intent.putExtra(EXTRA_CHANNEL_NAME, request.channelName)
            intent.putExtra(EXTRA_SILENT_CHANNEL_NAME, request.silentChannelName)
        }
        val flags = PendingIntent.FLAG_IMMUTABLE or
            (if (create) PendingIntent.FLAG_UPDATE_CURRENT else PendingIntent.FLAG_NO_CREATE)
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }

    fun canNotify(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun alarmAttributes(): AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    /** Crea el canal si falta; sin nombre (null) y sin canal previo no se puede. */
    private fun ensureChannel(context: Context, output: String?, name: String?): String? {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return null
        val id = TimerEndBackupDecision.channelId(output)
        if (manager.getNotificationChannel(id) != null) return id
        if (name.isNullOrBlank()) return null
        val channel = NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH)
        if (id == SILENT_CHANNEL_ID) {
            // «Solo vibración» nunca suena.
            channel.setSound(null, alarmAttributes())
        } else {
            val sound = Uri.parse("android.resource://${context.packageName}/raw/intronauts_bell")
            channel.setSound(sound, alarmAttributes())
        }
        if (TimerEndBackupDecision.vibrates(output)) {
            channel.enableVibration(true)
            channel.vibrationPattern = vibrationPattern
        } else {
            channel.enableVibration(false)
        }
        manager.createNotificationChannel(channel)
        return id
    }

    fun post(context: Context, intent: Intent) {
        val title = intent.getStringExtra(EXTRA_TITLE)
        val body = intent.getStringExtra(EXTRA_BODY)
        if (title == null && body == null) return
        val output = intent.getStringExtra(EXTRA_OUTPUT)
        val name = if (output == "vibration") intent.getStringExtra(EXTRA_SILENT_CHANNEL_NAME)
        else intent.getStringExtra(EXTRA_CHANNEL_NAME)
        val channelId = ensureChannel(context, output, name) ?: return
        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
        if (TimerEndBackupDecision.vibrates(output)) builder.setVibrate(vibrationPattern)
        title?.let(builder::setContentTitle)
        body?.let(builder::setContentText)
        openAppIntent(context)?.let(builder::setContentIntent)
        if (output == "vibration") builder.setSilent(false).setSound(null)
        try {
            context.getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, builder.build())
        } catch (error: SecurityException) {
            Log.e(TAG, "Sin permiso para avisar el fin", error)
        }
    }

    fun openAppIntent(context: Context): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        launch.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        return PendingIntent.getActivity(
            context, 0, launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }
}

private class AndroidAlarmBackend(private val context: Context) : AlarmBackend {
    private val manager = context.getSystemService(AlarmManager::class.java)

    override fun canScheduleExact(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || manager?.canScheduleExactAlarms() == true

    override fun setExact(triggerAtElapsedMs: Long, request: TimerBackupRequest) {
        val intent = TimerEndBackup.pendingIntent(context, request, create = true) ?: return
        try {
            manager?.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAtElapsedMs, intent)
        } catch (error: SecurityException) {
            // Se retiró el permiso de alarmas exactas entre la revisión y la llamada.
            manager?.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAtElapsedMs, intent)
        }
    }

    override fun setInexact(triggerAtElapsedMs: Long, request: TimerBackupRequest) {
        val intent = TimerEndBackup.pendingIntent(context, request, create = true) ?: return
        manager?.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAtElapsedMs, intent)
    }

    override fun cancel() {
        val intent = TimerEndBackup.pendingIntent(context, null, create = false) ?: return
        manager?.cancel(intent)
        intent.cancel()
    }
}

/** Recibe la alarma de respaldo; funciona sin Flutter corriendo. */
class TimerEndBackupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val runId = intent.getStringExtra(TimerEndBackup.EXTRA_RUN_ID)
        val (storedRunId, storedEnded) = TimerEndBackup.readRunState(context)
        val action = TimerEndBackupDecision.decide(
            runId = runId,
            serviceActive = AudioPlayerService.isActive,
            serviceRunId = AudioPlayerService.currentRunId,
            storedRunId = storedRunId,
            storedEnded = storedEnded,
            canNotify = TimerEndBackup.canNotify(context)
        )
        Log.d("TimerEndBackup", "Alarma de respaldo: $action")
        when (action) {
            TimerBackupAction.IGNORE -> Unit
            TimerBackupAction.RESCHEDULE_LIVE -> {
                // Mismo proceso: el servicio recalcula desde el tiempo que le queda al reproductor.
                Handler(Looper.getMainLooper()).post { AudioPlayerService.backupRescheduleHook?.invoke() }
            }
            TimerBackupAction.RESTORE_ONLY, TimerBackupAction.POST -> {
                val id = runId ?: return
                if (TimerEndBackupDecision.shouldRestoreDnd(DndGuard.activeOwner(context), id)) {
                    DndGuard.restore(context)
                }
                TimerEndBackup.markEnded(context, id)
                if (action == TimerBackupAction.POST) TimerEndBackup.post(context, intent)
            }
        }
    }
}
