package surf.comma.android.chat.render

import java.net.URI
import java.net.URLDecoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MapAppLinkTest {
    private fun query(link: String?): Map<String, String> =
        URI(link!!).rawQuery.split('&').associate {
            it.substringBefore('=') to URLDecoder.decode(it.substringAfter('='), "UTF-8")
        }

    @Test
    fun navigationOpensTheRouteInTheApp() {
        val app = MapAppLink.amapApp(
            "https://uri.amap.com/navigation?from=113.615568,22.352055,%E6%88%91&to=113.558421,22.278333," +
                "%E7%9B%92%E9%A9%AC&mode=walk&policy=1&src=comma&coordinate=gaode&callnative=1",
        )
        assertEquals("amapuri://route/plan/", app!!.substringBefore('?'))
        assertEquals(
            mapOf(
                "sourceApplication" to "Comma", "slat" to "22.352055", "slon" to "113.615568", "sname" to "我",
                "dlat" to "22.278333", "dlon" to "113.558421", "dname" to "盒马", "dev" to "0", "t" to "2",
            ),
            query(app),
        )
    }

    @Test
    fun navigationWithoutAStartStartsWhereThePersonIs() {
        val app = query(MapAppLink.amapApp("https://uri.amap.com/navigation?to=113.558421,22.278333&mode=car"))
        assertNull(app["slat"])
        assertEquals("22.278333", app["dlat"])
        assertEquals("0", app["t"])
    }

    @Test
    fun gpsCoordinatesAreMarkedForTheAppToConvert() {
        val app = query(MapAppLink.amapApp("https://uri.amap.com/navigation?to=113.558421,22.278333&coordinate=wgs84"))
        assertEquals("1", app["dev"])
        val marker = query(MapAppLink.amapApp("https://uri.amap.com/marker?position=113.558421,22.278333&coordinate=wgs84"))
        assertEquals("1", marker["dev"])
    }

    @Test
    fun markerOpensThePlace() {
        val app = MapAppLink.amapApp("https://uri.amap.com/marker?position=113.558421,22.278333&name=%E7%9B%92%E9%A9%AC")
        assertEquals("androidamap://viewMap", app!!.substringBefore('?'))
        assertEquals("盒马", query(app)["poiname"])
        assertEquals("113.558421", query(app)["lon"])
    }

    @Test
    fun otherLinksOpenAsBefore() {
        assertNull(MapAppLink.amapApp("https://www.amap.com/search?query=x"))
        assertNull(MapAppLink.amapApp("https://uri.amap.com/navigation?to=not,a-point"))
        assertNull(MapAppLink.amapApp("https://www.google.com/maps/dir/?api=1&destination=x"))
    }
}
