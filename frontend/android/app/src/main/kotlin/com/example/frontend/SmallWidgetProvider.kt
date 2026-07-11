package com.example.frontend

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

class SmallWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_small)
            val taskCount = widgetData.getString("widget_task_count", "0")
            views.setTextViewText(R.id.task_count_text, "未完了: $taskCount")

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}