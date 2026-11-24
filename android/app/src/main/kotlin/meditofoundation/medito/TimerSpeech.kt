package meditofoundation.medito

import android.content.Context
import android.media.AudioAttributes
import android.speech.tts.TextToSpeech
import android.util.Log
import java.util.Locale

/**
 * Avisos hablados del temporizador («Quedan 5 minutos»). El motor se crea sólo
 * cuando hace falta; si no arranca, se registra y se omite el aviso.
 */
internal class TimerSpeech(private val context: Context) {
    companion object {
        private const val TAG = "TimerSpeech"
    }

    private var engine: TextToSpeech? = null
    private var ready = false
    private var failed = false
    private var pendingText: String? = null
    private var languageTag: String? = null
    private var utterance = 0

    fun setLanguage(tag: String?) {
        languageTag = tag
        if (ready) applyLanguage()
    }

    fun speak(text: String) {
        if (text.isBlank() || failed) return
        if (ready) {
            say(text)
            return
        }
        pendingText = text
        if (engine == null) create()
    }

    private fun create() {
        try {
            engine = TextToSpeech(context.applicationContext) { status ->
                if (status != TextToSpeech.SUCCESS) {
                    Log.e(TAG, "No arrancó la voz del temporizador (estado $status)")
                    failed = true
                    pendingText = null
                    release()
                    return@TextToSpeech
                }
                ready = true
                engine?.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                applyLanguage()
                pendingText?.let(::say)
                pendingText = null
            }
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo crear la voz del temporizador", error)
            failed = true
        }
    }

    private fun applyLanguage() {
        val tts = engine ?: return
        try {
            val locale = languageTag?.takeIf { it.isNotBlank() }?.let(Locale::forLanguageTag)
            val result = locale?.let(tts::setLanguage)
            if (locale == null || result == null ||
                result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                tts.setLanguage(Locale.getDefault())
            }
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo elegir el idioma de la voz", error)
        }
    }

    private fun say(text: String) {
        try {
            engine?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "timer-${++utterance}")
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo decir el aviso", error)
        }
    }

    fun stop() {
        pendingText = null
        try {
            engine?.stop()
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo callar la voz", error)
        }
    }

    fun release() {
        pendingText = null
        val tts = engine
        engine = null
        ready = false
        try {
            tts?.shutdown()
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo liberar la voz", error)
        }
    }
}
