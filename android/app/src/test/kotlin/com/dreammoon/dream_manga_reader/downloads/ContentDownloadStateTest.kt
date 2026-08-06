package com.dreammoon.dream_manga_reader.downloads

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ContentDownloadStateTest {
    @Test
    fun parsesAndClampsProgress() {
        val state = ContentDownloadState.fromMap(
            mapOf(
                "taskCount" to 2,
                "completedBytes" to 150L,
                "totalBytes" to 100L,
                "indeterminate" to false,
                "currentTitle" to "番剧",
                "currentItemTitle" to "第一集",
            ),
        )

        assertEquals(2, state.taskCount)
        assertEquals(100L, state.completedBytes)
        assertEquals(100L, state.totalBytes)
        assertEquals(100, state.percent)
    }

    @Test
    fun rejectsEmptyTaskCountAndLimitsDisplayText() {
        assertThrows(IllegalArgumentException::class.java) {
            ContentDownloadState.fromMap(
                mapOf(
                    "taskCount" to 0,
                    "completedBytes" to 0,
                    "totalBytes" to 0,
                    "indeterminate" to true,
                    "currentTitle" to "",
                    "currentItemTitle" to "",
                ),
            )
        }
        val longTitle = "x".repeat(200)
        val state = ContentDownloadState.fromMap(
            mapOf(
                "taskCount" to 1,
                "completedBytes" to -10L,
                "totalBytes" to 0L,
                "indeterminate" to true,
                "currentTitle" to longTitle,
                "currentItemTitle" to longTitle,
            ),
        )
        assertEquals(0L, state.completedBytes)
        assertEquals(80, state.currentTitle.length)
        assertEquals(80, state.currentItemTitle.length)
    }
}
