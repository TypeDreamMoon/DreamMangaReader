package com.dreammoon.dream_manga_reader.update

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI

data class UpdateRemoteFile(
    val fileName: String,
    val url: String,
    val sizeBytes: Long,
    val sha256: String,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("fileName", fileName)
        .put("url", url)
        .put("sizeBytes", sizeBytes)
        .put("sha256", sha256)
}

data class UpdateDownloadPlan(
    val taskKey: String,
    val versionName: String,
    val fileName: String,
    val sizeBytes: Long,
    val sha256: String,
    val direct: UpdateRemoteFile?,
    val parts: List<UpdateRemoteFile>,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("schemaVersion", SCHEMA_VERSION)
        .put("taskKey", taskKey)
        .put("versionName", versionName)
        .put("fileName", fileName)
        .put("sizeBytes", sizeBytes)
        .put("sha256", sha256)
        .also { json ->
            if (direct != null) {
                json.put("url", direct.url)
            } else {
                json.put("parts", JSONArray().also { array ->
                    parts.forEach { array.put(it.toJson()) }
                })
            }
        }

    companion object {
        private const val SCHEMA_VERSION = 1
        private val SHA256 = Regex("^[0-9a-fA-F]{64}$")

        fun parse(source: JSONObject): UpdateDownloadPlan {
            require(source.getInt("schemaVersion") == SCHEMA_VERSION)
            val taskKey = source.getString("taskKey")
            val versionName = source.getString("versionName")
            val fileName = source.getString("fileName")
            val sizeBytes = source.getLong("sizeBytes")
            val sha256 = source.getString("sha256").lowercase()
            require(versionName.isNotBlank())
            require(taskKey == "$sha256:$versionName")
            require(sizeBytes > 0L)
            require(SHA256.matches(sha256))
            require(isSafeLeafName(fileName))

            val url = source.optString("url").takeIf { it.isNotBlank() }
            val rawParts = source.optJSONArray("parts")
            require((url != null) xor (rawParts != null && rawParts.length() > 0))
            val parts = if (rawParts == null) {
                emptyList()
            } else {
                List(rawParts.length()) { index -> parseRemote(rawParts.getJSONObject(index)) }
            }
            require(parts.isEmpty() || parts.sumOf { it.sizeBytes } == sizeBytes)
            val direct = url?.let {
                requireHttps(it)
                UpdateRemoteFile(fileName, it, sizeBytes, sha256)
            }
            return UpdateDownloadPlan(
                taskKey = taskKey,
                versionName = versionName,
                fileName = fileName,
                sizeBytes = sizeBytes,
                sha256 = sha256,
                direct = direct,
                parts = parts,
            )
        }

        private fun parseRemote(source: JSONObject): UpdateRemoteFile {
            val fileName = source.getString("fileName")
            val url = source.getString("url")
            val sizeBytes = source.getLong("sizeBytes")
            val sha256 = source.getString("sha256").lowercase()
            require(isSafeLeafName(fileName))
            requireHttps(url)
            require(sizeBytes > 0L)
            require(SHA256.matches(sha256))
            return UpdateRemoteFile(fileName, url, sizeBytes, sha256)
        }

        internal fun isSafeLeafName(value: String): Boolean =
            value.isNotBlank() &&
                !value.contains('/') &&
                !value.contains('\\') &&
                !value.contains("..") &&
                File(value).name == value

        private fun requireHttps(value: String) {
            val uri = URI(value)
            require(uri.scheme.equals("https", ignoreCase = true))
            require(!uri.host.isNullOrBlank())
            require(uri.userInfo == null)
        }
    }
}
