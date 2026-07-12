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

class CompactWidgetProvider : HomeWidgetProvider() {

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
        val views = RemoteViews(context.packageName, R.layout.widget_compact)

        val widgetDataPlugin = HomeWidgetPlugin.getData(context)
        val jsonString = widgetDataPlugin.getString("widget_top5_events", "[]")

        val options = appWidgetManager.getAppWidgetOptions(appWidgetId)
        val minHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 100)

        // Calculate max items based on height. Roughly 1 item per 30dp after a baseline of ~40dp for clock/padding
        val availableHeightForRows = maxOf(0, minHeight - 40)
        val calculatedMaxItems = maxOf(3, availableHeightForRows / 30)
        val maxItemsToDisplay = minOf(20, calculatedMaxItems)

        val rowLayouts = intArrayOf(
            R.id.row_1, R.id.row_2, R.id.row_3, R.id.row_4, R.id.row_5, R.id.row_6, R.id.row_7, R.id.row_8, R.id.row_9, R.id.row_10,
            R.id.row_11, R.id.row_12, R.id.row_13, R.id.row_14, R.id.row_15, R.id.row_16, R.id.row_17, R.id.row_18, R.id.row_19, R.id.row_20
        )
        val titleViews = intArrayOf(
            R.id.row_1_title, R.id.row_2_title, R.id.row_3_title, R.id.row_4_title, R.id.row_5_title, R.id.row_6_title, R.id.row_7_title, R.id.row_8_title, R.id.row_9_title, R.id.row_10_title,
            R.id.row_11_title, R.id.row_12_title, R.id.row_13_title, R.id.row_14_title, R.id.row_15_title, R.id.row_16_title, R.id.row_17_title, R.id.row_18_title, R.id.row_19_title, R.id.row_20_title
        )
        val timeViews = intArrayOf(
            R.id.row_1_time, R.id.row_2_time, R.id.row_3_time, R.id.row_4_time, R.id.row_5_time, R.id.row_6_time, R.id.row_7_time, R.id.row_8_time, R.id.row_9_time, R.id.row_10_time,
            R.id.row_11_time, R.id.row_12_time, R.id.row_13_time, R.id.row_14_time, R.id.row_15_time, R.id.row_16_time, R.id.row_17_time, R.id.row_18_time, R.id.row_19_time, R.id.row_20_time
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

                views.setViewVisibility(rowLayouts[i], View.VISIBLE)
                views.setTextViewText(titleViews[i], title)
                views.setTextViewText(timeViews[i], deadline)
            } else {
                views.setViewVisibility(rowLayouts[i], View.GONE)
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
