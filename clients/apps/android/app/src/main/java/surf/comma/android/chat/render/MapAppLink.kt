package surf.comma.android.chat.render

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * An AMap web link (`uri.amap.com`) as the AMap app's own link. Opened in a browser, the web link loads AMap's page and
 * asks again before it hands over to the app; the app link opens the route or place at once. Any other link, a web link
 * without the coordinates the app needs, or a phone without AMap opens the link as before.
 */
object MapAppLink {
    private const val AMAP_PACKAGE = "com.autonavi.minimap"

    /** Opens [url] in the AMap app when it is an AMap web link and the app is installed; false otherwise. */
    fun open(context: Context, url: String): Boolean {
        val app = amapApp(url) ?: return false
        return try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(app)).setPackage(AMAP_PACKAGE))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    /** The AMap app link for [url], or null when [url] is not an AMap web link the app can open. */
    fun amapApp(url: String): String? {
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        if (uri.scheme !in setOf("https", "http") || uri.host?.lowercase() != "uri.amap.com") return null
        val query = (uri.rawQuery ?: return null).split('&').mapNotNull { pair ->
            val name = pair.substringBefore('=')
            if (name.isEmpty()) null else name to URLDecoder.decode(pair.substringAfter('=', ""), "UTF-8")
        }.toMap()
        val parameters = mutableListOf("sourceApplication" to "Comma")
        val dev = coordinateSystem(query["coordinate"])
        val target = when (uri.path) {
            "/navigation" -> {
                val to = query["to"]?.let(::point) ?: return null
                // Without a start the app starts from where the person is.
                query["from"]?.let(::point)?.let { from ->
                    parameters += listOf("slat" to from.lat, "slon" to from.lon)
                    from.name?.let { parameters += "sname" to it }
                }
                parameters += listOf("dlat" to to.lat, "dlon" to to.lon)
                to.name?.let { parameters += "dname" to it }
                parameters += listOf("dev" to dev, "t" to travelMode(query["mode"]))
                "amapuri://route/plan/"
            }
            "/marker" -> {
                val at = query["position"]?.let(::point) ?: return null
                parameters += listOf(
                    "poiname" to (query["name"] ?: at.name ?: ""),
                    "lat" to at.lat,
                    "lon" to at.lon,
                    "dev" to dev,
                )
                "androidamap://viewMap"
            }
            else -> return null
        }
        return target + "?" + parameters.joinToString("&") { (name, value) ->
            name + "=" + URLEncoder.encode(value, "UTF-8").replace("+", "%20")
        }
    }

    /** The web link's `mode` as the app's `t`: car 0, bus 1, walk 2, ride 3. */
    private fun travelMode(mode: String?) = when (mode) {
        "bus" -> "1"
        "walk" -> "2"
        "ride" -> "3"
        else -> "0"
    }

    /** The web link's `coordinate` as the app's `dev`: `wgs84` (GPS) is 1, AMap's own GCJ-02 (`gaode`, the default) 0. */
    private fun coordinateSystem(coordinate: String?) = if (coordinate.equals("wgs84", ignoreCase = true)) "1" else "0"

    /** `lon,lat[,name]`, the web link's order, in the system its `coordinate` names. */
    private data class Point(val lon: String, val lat: String, val name: String?)

    private fun point(value: String): Point? {
        val parts = value.split(',', limit = 3)
        if (parts.size < 2 || parts[0].toDoubleOrNull() == null || parts[1].toDoubleOrNull() == null) return null
        return Point(parts[0], parts[1], parts.getOrNull(2)?.takeIf { it.isNotEmpty() })
    }
}
