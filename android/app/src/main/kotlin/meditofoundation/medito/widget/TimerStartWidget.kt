package meditofoundation.medito.widget

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import meditofoundation.medito.R

class TimerStartWidget : GlanceAppWidget() {
    override val stateDefinition = null

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent { TimerContent(context) }
    }

    @Composable
    private fun TimerContent(context: Context) {
        val palette = WidgetPalette.resolve(context, "system")
        val contentWidth = LocalSize.current.width - 8.dp
        val minutesWidth = (contentWidth - 4.dp) / 3

        Column(
            modifier = GlanceModifier.fillMaxSize().background(palette.background).padding(4.dp),
            horizontalAlignment = Alignment.Horizontal.CenterHorizontally,
        ) {
            WidgetText(
                text = context.getString(R.string.timer_widget_title),
                fontSize = 12f,
                weight = WidgetWeight.Bold,
                color = palette.foreground,
                maxWidth = contentWidth,
                centered = true,
            )
            Spacer(GlanceModifier.height(2.dp))
            Row(modifier = GlanceModifier.fillMaxWidth().defaultWeight()) {
                for (minutes in listOf(5, 10, 20)) {
                    if (minutes != 5) Spacer(GlanceModifier.width(2.dp))
                    TimerButton(
                        context = context,
                        label = context.getString(R.string.timer_widget_minutes, minutes),
                        query = "minutes=$minutes",
                        background = palette.accent,
                        foreground = palette.onAccent,
                        maxWidth = minutesWidth,
                        modifier = GlanceModifier.defaultWeight().fillMaxHeight(),
                    )
                }
            }
            Spacer(GlanceModifier.height(2.dp))
            TimerButton(
                context = context,
                label = context.getString(R.string.timer_widget_repeat),
                query = "last=1",
                background = palette.inactive,
                foreground = palette.foreground,
                maxWidth = contentWidth,
                modifier = GlanceModifier.fillMaxWidth().defaultWeight(),
            )
        }
    }

    @Composable
    private fun TimerButton(
        context: Context,
        label: String,
        query: String,
        background: Color,
        foreground: Color,
        maxWidth: Dp,
        modifier: GlanceModifier,
    ) {
        val uri = Uri.parse("org.meditofoundation://medito/timer/start?$query&source=home_widget&widget=timer")
        val intent = Intent(Intent.ACTION_VIEW, uri)
            .setPackage(context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        Box(
            modifier = modifier.background(background).clickable(actionStartActivity(intent)),
            contentAlignment = Alignment.Center,
        ) {
            WidgetText(
                text = label,
                fontSize = 10f,
                weight = WidgetWeight.SemiBold,
                color = foreground,
                maxWidth = maxWidth,
                centered = true,
            )
        }
    }
}
