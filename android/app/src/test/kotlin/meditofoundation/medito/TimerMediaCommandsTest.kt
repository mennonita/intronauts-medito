package meditofoundation.medito

import androidx.media3.common.Player
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TimerMediaCommandsTest {
    private val seekAndSkip = setOf(
        Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
        Player.COMMAND_SEEK_TO_DEFAULT_POSITION,
        Player.COMMAND_SEEK_TO_PREVIOUS,
        Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
        Player.COMMAND_SEEK_TO_NEXT,
        Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
        Player.COMMAND_SEEK_TO_MEDIA_ITEM,
        Player.COMMAND_SEEK_BACK,
        Player.COMMAND_SEEK_FORWARD
    )

    @Test fun extraTimePublishesPlayPauseStopAndReadCommands() {
        assertTrue(Player.COMMAND_PLAY_PAUSE in TimerMediaCommands.extraTime)
        assertTrue(Player.COMMAND_STOP in TimerMediaCommands.extraTime)
        assertTrue(Player.COMMAND_GET_CURRENT_MEDIA_ITEM in TimerMediaCommands.extraTime)
        assertTrue(Player.COMMAND_GET_METADATA in TimerMediaCommands.extraTime)
    }

    @Test fun extraTimeRejectsSeekSkipSpeedAndPlaylistChanges() {
        val blocked = seekAndSkip + setOf(
            Player.COMMAND_SET_SPEED_AND_PITCH,
            Player.COMMAND_SET_REPEAT_MODE,
            Player.COMMAND_SET_SHUFFLE_MODE,
            Player.COMMAND_SET_MEDIA_ITEM,
            Player.COMMAND_CHANGE_MEDIA_ITEMS
        )
        for (command in blocked) {
            assertFalse(command in TimerMediaCommands.extraTime)
            assertFalse(TimerMediaCommands.allows(hasExtraTime = true, command = command))
        }
    }

    @Test fun regularPlaybackKeepsSeekAndSkipCommands() {
        for (command in seekAndSkip) {
            assertTrue(TimerMediaCommands.allows(hasExtraTime = false, command = command))
        }
    }
}
