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

import android.os.Bundle

class VerticalWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        for (appWidgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onAppWidgetOptionsChanged(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle?) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        updateWidget(context, appWidgetManager, appWidgetId)
    }

    private fun updateWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
        val views = RemoteViews(context.packageName, R.layout.widget_vertical)

        val widgetDataPlugin = HomeWidgetPlugin.getData(context)
        val jsonString = widgetDataPlugin.getString("widget_top5_events", "[]")

        val options = appWidgetManager.getAppWidgetOptions(appWidgetId)
        val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 40)
        val maxItemsToDisplay = (width / 32).coerceIn(4, 20)

        val containers = intArrayOf(
            R.id.event_1_container, R.id.event_2_container, R.id.event_3_container, R.id.event_4_container, R.id.event_5_container, R.id.event_6_container, R.id.event_7_container, R.id.event_8_container, R.id.event_9_container, R.id.event_10_container,
            R.id.event_11_container, R.id.event_12_container, R.id.event_13_container, R.id.event_14_container, R.id.event_15_container, R.id.event_16_container, R.id.event_17_container, R.id.event_18_container, R.id.event_19_container, R.id.event_20_container
        )
        val titleViews = intArrayOf(
            R.id.event_1_title, R.id.event_2_title, R.id.event_3_title, R.id.event_4_title, R.id.event_5_title, R.id.event_6_title, R.id.event_7_title, R.id.event_8_title, R.id.event_9_title, R.id.event_10_title,
            R.id.event_11_title, R.id.event_12_title, R.id.event_13_title, R.id.event_14_title, R.id.event_15_title, R.id.event_16_title, R.id.event_17_title, R.id.event_18_title, R.id.event_19_title, R.id.event_20_title
        )
        val deadlineViews = intArrayOf(
            R.id.event_1_deadline, R.id.event_2_deadline, R.id.event_3_deadline, R.id.event_4_deadline, R.id.event_5_deadline, R.id.event_6_deadline, R.id.event_7_deadline, R.id.event_8_deadline, R.id.event_9_deadline, R.id.event_10_deadline,
            R.id.event_11_deadline, R.id.event_12_deadline, R.id.event_13_deadline, R.id.event_14_deadline, R.id.event_15_deadline, R.id.event_16_deadline, R.id.event_17_deadline, R.id.event_18_deadline, R.id.event_19_deadline, R.id.event_20_deadline
        )

        var eventList = JSONArray()
        try {
            eventList = JSONArray(jsonString)
        } catch (e: JSONException) {
            e.printStackTrace()
        }

        val itemsToShowCount = minOf(maxItemsToDisplay, eventList.length())

        for (i in 0 until 20) {
            if (i < itemsToShowCount) {
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
