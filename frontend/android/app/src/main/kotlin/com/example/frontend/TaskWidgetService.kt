package com.example.frontend

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

class TaskWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return TaskRemoteViewsFactory(this.applicationContext)
    }
}

class TaskRemoteViewsFactory(private val context: Context) : RemoteViewsService.RemoteViewsFactory {
    private var taskList: JSONArray = JSONArray()

    override fun onCreate() {
        loadData()
    }

    override fun onDataSetChanged() {
        loadData()
    }

    private fun loadData() {
        val widgetData = HomeWidgetPlugin.getData(context)
        val jsonString = widgetData.getString("widget_task_list", "[]")
        try {
            taskList = JSONArray(jsonString)
        } catch (e: JSONException) {
            e.printStackTrace()
            taskList = JSONArray()
        }
    }

    override fun onDestroy() {
        taskList = JSONArray()
    }

    override fun getCount(): Int {
        return taskList.length()
    }

    override fun getViewAt(position: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_list_item)
        try {
            val taskObj: JSONObject = taskList.getJSONObject(position)
            val title = taskObj.optString("title", "No Title")
            val id = taskObj.optString("id", "")

            views.setTextViewText(R.id.item_text, title)

            // Set up the fill-in intent for click handling via Deep Link
            val fillInIntent = Intent().apply {
                data = Uri.parse("multigame://event/$id")
            }
            views.setOnClickFillInIntent(R.id.item_text, fillInIntent)

        } catch (e: JSONException) {
            e.printStackTrace()
        }
        return views
    }

    override fun getLoadingView(): RemoteViews? {
        return null
    }

    override fun getViewTypeCount(): Int {
        return 1
    }

    override fun getItemId(position: Int): Long {
        return position.toLong()
    }

    override fun hasStableIds(): Boolean {
        return true
    }
}