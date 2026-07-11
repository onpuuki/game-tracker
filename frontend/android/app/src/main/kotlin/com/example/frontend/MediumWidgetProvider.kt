package com.example.frontend

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

class MediumWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_medium)
            val taskCount = widgetData.getString("widget_task_count", "0")
            val alert = widgetData.getString("widget_alert", "")

            views.setTextViewText(R.id.task_count_text, "未完了タスク: $taskCount")
            views.setTextViewText(R.id.alert_text, alert)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}