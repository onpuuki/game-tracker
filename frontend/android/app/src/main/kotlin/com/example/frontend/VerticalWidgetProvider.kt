package com.example.frontend

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

class VerticalWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_vertical)

            val widgetDataPlugin = HomeWidgetPlugin.getData(context)
            val jsonString = widgetDataPlugin.getString("widget_top5_events", "[]")

            val containers = intArrayOf(R.id.event_1_container, R.id.event_2_container, R.id.event_3_container, R.id.event_4_container)
            val titleViews = intArrayOf(R.id.event_1_title, R.id.event_2_title, R.id.event_3_title, R.id.event_4_title)
            val deadlineViews = intArrayOf(R.id.event_1_deadline, R.id.event_2_deadline, R.id.event_3_deadline, R.id.event_4_deadline)

            var eventList = JSONArray()
            try {
                eventList = JSONArray(jsonString)
            } catch (e: JSONException) {
                e.printStackTrace()
            }

            for (i in 0 until 4) {
                if (i < eventList.length()) {
                    val eventObj = eventList.optJSONObject(i)
                    val title = eventObj?.optString("title", "") ?: ""
                    val deadline = eventObj?.optString("deadline", "") ?: ""

                    val safeTitle = if (title.length > 6) title.take(5) + "︙" else title
                    val verticalTitle = safeTitle.map { it.toString() }.joinToString("\n")
                    val verticalDeadline = deadline.map { it.toString() }.joinToString("\n")

                    views.setViewVisibility(containers[i], View.VISIBLE)
                    views.setTextViewText(titleViews[i], verticalTitle)
                    views.setTextViewText(deadlineViews[i], verticalDeadline)
                } else {
                    views.setViewVisibility(containers[i], View.GONE)
                }
            }

            // Click intent
            val clickIntentTemplate = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
            }
            val pendingIntentTemplate = PendingIntent.getActivity(
                context, 0, clickIntentTemplate, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.clock, pendingIntentTemplate)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
