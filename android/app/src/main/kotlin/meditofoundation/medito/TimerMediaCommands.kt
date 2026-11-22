package meditofoundation.medito

import androidx.media3.common.Player

internal object TimerMediaCommands {
    val extraTime = setOf(
        Player.COMMAND_PLAY_PAUSE,
        Player.COMMAND_STOP,
        Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
        Player.COMMAND_GET_TIMELINE,
        Player.COMMAND_GET_METADATA,
        Player.COMMAND_GET_AUDIO_ATTRIBUTES,
        Player.COMMAND_GET_VOLUME,
        Player.COMMAND_GET_DEVICE_VOLUME,
        Player.COMMAND_GET_TEXT,
        Player.COMMAND_GET_TRACKS
    )

    fun allows(hasExtraTime: Boolean, command: Int): Boolean =
        !hasExtraTime || command in extraTime
}
