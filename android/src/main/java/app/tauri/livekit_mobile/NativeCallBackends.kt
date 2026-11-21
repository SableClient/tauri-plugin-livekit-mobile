package app.tauri.livekit_mobile

internal data class NativeCallBackend(
    val id: String,
    val url: String,
    val token: String,
)

internal fun isValidBackendSet(publisherId: String, backends: List<NativeCallBackend>): Boolean =
    backends.all { it.id.isNotBlank() && it.url.isNotBlank() && it.token.isNotBlank() } &&
        backends.map { it.id }.toSet().size == backends.size &&
        backends.any { it.id == publisherId }
