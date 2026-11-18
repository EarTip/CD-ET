package com.example.eartips

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

class SoundWidgetProvider : AppWidgetProvider() {

    companion object {
        // home_widget 플러그인의 saveWidgetData가 쓰는 SharedPreferences 이름
        const val PREFS_NAME = "HomeWidgetPreferences"
        const val KEY_IS_LISTENING = "is_listening"

        fun updateWidget(context: Context, manager: AppWidgetManager, widgetId: Int) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val isListening = prefs.getBoolean(KEY_IS_LISTENING, false)

            val views = RemoteViews(context.packageName, R.layout.sound_widget_layout)
            views.setTextViewText(R.id.widget_mic_icon, if (isListening) "🔊" else "🎤")
            views.setTextViewText(
                R.id.widget_status_text,
                if (isListening) "감지 중" else "감지 꺼짐"
            )

            // 탭 → 중계 Activity (앱 화면은 열리지 않음)
            val intent = Intent(context, WidgetTrampolineActivity::class.java)
            val pendingIntent = PendingIntent.getActivity(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_container, pendingIntent)

            manager.updateAppWidget(widgetId, views)
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (id in appWidgetIds) updateWidget(context, appWidgetManager, id)
    }
}
