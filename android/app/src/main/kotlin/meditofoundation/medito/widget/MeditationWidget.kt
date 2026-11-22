package meditofoundation.medito.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.glance.GlanceId
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.provideContent
import androidx.glance.currentState
import androidx.glance.state.GlanceStateDefinition
import es.antonborri.home_widget.HomeWidgetGlanceState
import es.antonborri.home_widget.HomeWidgetGlanceStateDefinition
import meditofoundation.medito.R
import org.json.JSONObject

class MeditationWidget : GlanceAppWidget() {

    override val stateDefinition: GlanceStateDefinition<*>?
        get() = HomeWidgetGlanceStateDefinition()

    override val sizeMode: SizeMode
        get() = statSizeMode

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            WidgetContent(context)
        }
    }

    @Composable
    private fun WidgetContent(context: Context) {
        val prefs = currentState<HomeWidgetGlanceState>().preferences
        val data = runCatching { JSONObject(prefs.getString("returns_data", "{}") ?: "{}") }
            .getOrDefault(JSONObject())
        val raw = data.optJSONArray("timestamps")
        val timestamps = raw?.let { dates ->
            (0 until dates.length()).mapNotNull { dates.opt(it) as? Number }
                .map { it.toLong() }
        }.orEmpty()
        val offsetHours = data.optInt("offset")
        val today = StreakCalculator.dayOf(System.currentTimeMillis(), offsetHours)
        val activityDays = StreakCalculator.practiceDays(timestamps, offsetHours, today)
        val returns = maxOf(data.optInt("count"), activityDays.size)

        val themePreference = prefs.getString("theme_preference", "system") ?: "system"

        StatWidgetContent(
            context = context,
            value = returns.toString(),
            unit = context.getString(R.string.returns_widget_label),
            doneToday = activityDays.contains(today),
            today = today,
            activityDays = activityDays,
            palette = WidgetPalette.resolve(context, themePreference),
            tapUri = "org.meditofoundation://medito/?source=home_widget&widget=streak",
        )
    }

}
