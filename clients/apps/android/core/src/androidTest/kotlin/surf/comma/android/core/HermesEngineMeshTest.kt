package surf.comma.android.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * The engine answers the core's `mesh.*` operations with the iroh linked into it (clients/packages/mesh/native): on
 * the phone, through the same JNI and threads the app's core has. The app is never asked them.
 */
class HermesEngineMeshTest {
    @Test fun anEndpointIsBoundAndClosedByTheEngineItself() {
        val said = LinkedBlockingQueue<String>()
        val asked = LinkedBlockingQueue<String>()
        val host = object : EngineHost {
            override fun call(id: Long, op: String, json: ByteArray, bytes: ByteArray?) { asked.add(op) }
            override fun callSync(op: String, json: ByteArray) = ByteArray(0)
            override fun emit(json: ByteArray) { said.add(String(json)) }
            override fun fatal(reason: ByteArray) { said.add("fatal " + String(reason)) }
        }
        val script = """
            globalThis.commaCore = {
              start() {
                commaNative.emit(JSON.stringify({ mesh: commaNative.mesh === true }));
                commaNative.call(1, "mesh.bind", JSON.stringify({ relayUrls: [], salixRelay: true }), new Uint8Array(32).fill(1).buffer);
              },
              complete(id, json, error) {
                commaNative.emit(JSON.stringify({ id, json, error }));
                if (id === 1 && json) commaNative.call(2, "mesh.endpointClose", JSON.stringify({ id: JSON.parse(json).id }), undefined);
              },
            };
        """.trimIndent()
        val engine = HermesEngine(script.toByteArray(), "{}", host)
        try {
            assertEquals("""{"mesh":true}""", said.poll(30, TimeUnit.SECONDS))
            val bound = JSONObject(said.poll(30, TimeUnit.SECONDS)!!)
            assertEquals(1, bound.getInt("id"))
            assertTrue(bound.optString("error"), bound.isNull("error"))
            assertTrue(Regex("[0-9a-f]{64}").matches(JSONObject(bound.getString("json")).getString("endpoint")))
            val closed = JSONObject(said.poll(30, TimeUnit.SECONDS)!!)
            assertEquals(2, closed.getInt("id"))
            assertTrue(closed.optString("error"), closed.isNull("error"))
            assertTrue(asked.isEmpty())
        } finally {
            engine.close()
        }
    }
}
