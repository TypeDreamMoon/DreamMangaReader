package com.dreammoon.dream_manga_reader.update

import android.content.Context
import org.json.JSONObject

data class UpdateDownloadState(
    val status: String,
    val taskKey: String? = null,
    val versionName: String? = null,
    val downloadedBytes: Long = 0L,
    val totalBytes: Long = 0L,
    val percent: Double = 0.0,
    val message: String? = null,
    val errorCode: String? = null,
    val apkPath: String? = null,
    val retryAttempt: Int? = null,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("status", status)
        .put("downloadedBytes", downloadedBytes)
        .put("totalBytes", totalBytes)
        .put("percent", percent)
        .also { json ->
            taskKey?.let { json.put("taskKey", it) }
            versionName?.let { json.put("versionName", it) }
            message?.let { json.put("message", it) }
            errorCode?.let { json.put("errorCode", it) }
            apkPath?.let { json.put("apkPath", it) }
            retryAttempt?.let { json.put("retryAttempt", it) }
        }

    /** 还在推进中的阶段(对应 Flutter 侧 UpdateTransferState.busy)。 */
    val busy: Boolean
        get() = status == "downloading" ||
            status == "retrying" ||
            status == "verifying" ||
            status == "assembling"

    companion object {
        val IDLE = UpdateDownloadState(status = "idle")

        fun fromJson(json: JSONObject): UpdateDownloadState = UpdateDownloadState(
            status = json.getString("status"),
            taskKey = json.optString("taskKey").takeIf { it.isNotBlank() },
            versionName = json.optString("versionName").takeIf { it.isNotBlank() },
            downloadedBytes = json.optLong("downloadedBytes"),
            totalBytes = json.optLong("totalBytes"),
            percent = json.optDouble("percent"),
            message = json.optString("message").takeIf { it.isNotBlank() },
            errorCode = json.optString("errorCode").takeIf { it.isNotBlank() },
            apkPath = json.optString("apkPath").takeIf { it.isNotBlank() },
            retryAttempt = json.optInt("retryAttempt").takeIf { it > 0 },
        )
    }
}

internal object UpdateStateStore {
    private const val PREFERENCES = "background_update_download"
    private const val STATE = "state"
    private const val PLAN = "plan"

    fun readState(context: Context): UpdateDownloadState {
        val raw = preferences(context).getString(STATE, null) ?: return UpdateDownloadState.IDLE
        return runCatching { UpdateDownloadState.fromJson(JSONObject(raw)) }
            .getOrDefault(UpdateDownloadState.IDLE)
    }

    fun writeState(context: Context, state: UpdateDownloadState) {
        preferences(context).edit().putString(STATE, state.toJson().toString()).apply()
    }

    fun readPlan(context: Context): UpdateDownloadPlan? {
        val raw = preferences(context).getString(PLAN, null) ?: return null
        return runCatching { UpdateDownloadPlan.parse(JSONObject(raw)) }.getOrNull()
    }

    fun writePlan(context: Context, plan: UpdateDownloadPlan) {
        preferences(context).edit().putString(PLAN, plan.toJson().toString()).apply()
    }

    fun clear(context: Context) {
        preferences(context).edit().clear().apply()
    }

    private fun preferences(context: Context) =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
}
