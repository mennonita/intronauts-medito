package meditofoundation.medito

import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationChannelsTest {
    @Test
    fun playbackAndRemindersUseSeparateNewChannels() {
        assertEquals("intronauts_playback_channel", AudioPlayerService.CHANNEL_ID)
        assertEquals("intronauts_reminders_channel", MainActivity.REMINDER_CHANNEL_ID)
    }
}
