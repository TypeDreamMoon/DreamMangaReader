package com.dreammoon.dream_manga_reader.update

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class UpdateDownloadPlanTest {
    @Test
    fun parsesDirectAndChunkedPlans() {
        val direct = UpdateDownloadPlan.parse(base().put("url", "https://example.com/app.apk"))
        assertEquals("app.apk", direct.direct?.fileName)

        val parts = JSONArray()
            .put(remote("app.apk.part001", 1, SHA_A))
            .put(remote("app.apk.part002", 2, SHA_B))
        val chunked = UpdateDownloadPlan.parse(base().put("parts", parts))
        assertEquals(2, chunked.parts.size)
    }

    @Test
    fun rejectsTraversalHttpAndMismatchedPartTotals() {
        assertThrows(IllegalArgumentException::class.java) {
            UpdateDownloadPlan.parse(
                base().put("fileName", "../app.apk")
                    .put("url", "https://example.com/app.apk"),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            UpdateDownloadPlan.parse(base().put("url", "http://example.com/app.apk"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            UpdateDownloadPlan.parse(
                base().put("parts", JSONArray().put(remote("part001", 1, SHA_A))),
            )
        }
    }

    private fun base() = JSONObject()
        .put("schemaVersion", 1)
        .put("taskKey", "$SHA_A:1.7.0")
        .put("versionName", "1.7.0")
        .put("fileName", "app.apk")
        .put("sizeBytes", 3)
        .put("sha256", SHA_A)

    private fun remote(fileName: String, size: Int, sha256: String) = JSONObject()
        .put("fileName", fileName)
        .put("url", "https://example.com/$fileName")
        .put("sizeBytes", size)
        .put("sha256", sha256)

    companion object {
        private const val SHA_A =
            "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81"
        private const val SHA_B =
            "ae4b3280e56e2faf83f414a6e3dabe9d5fbe18976544c05fed121accb85b53fc"
    }
}
