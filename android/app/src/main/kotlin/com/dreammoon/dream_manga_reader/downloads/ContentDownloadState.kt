package com.dreammoon.dream_manga_reader.downloads

import kotlin.math.roundToInt

data class ContentDownloadState(
    val taskCount: Int,
    val completedBytes: Long,
    val totalBytes: Long,
    val indeterminate: Boolean,
    val currentTitle: String,
    val currentItemTitle: String,
) {
    val percent: Int
        get() = if (indeterminate || totalBytes <= 0L) {
            0
        } else {
            (completedBytes * 100.0 / totalBytes).roundToInt().coerceIn(0, 100)
        }

    companion object {
        fun fromMap(value: Map<*, *>): ContentDownloadState {
            val taskCount = (value["taskCount"] as? Number)?.toInt()
                ?: throw IllegalArgumentException("Missing taskCount")
            require(taskCount > 0) { "taskCount must be positive" }
            val total = ((value["totalBytes"] as? Number)?.toLong() ?: 0L).coerceAtLeast(0L)
            val completed = ((value["completedBytes"] as? Number)?.toLong() ?: 0L)
                .coerceIn(0L, if (total > 0L) total else Long.MAX_VALUE)
            return ContentDownloadState(
                taskCount = taskCount,
                completedBytes = completed,
                totalBytes = total,
                indeterminate = value["indeterminate"] as? Boolean ?: total <= 0L,
                currentTitle = displayText(value["currentTitle"]),
                currentItemTitle = displayText(value["currentItemTitle"]),
            )
        }

        private fun displayText(value: Any?): String =
            (value as? String).orEmpty().trim().take(MAX_DISPLAY_TEXT)

        private const val MAX_DISPLAY_TEXT = 80
    }
}
