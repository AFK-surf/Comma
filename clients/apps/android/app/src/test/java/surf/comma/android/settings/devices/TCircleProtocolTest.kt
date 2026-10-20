package surf.comma.android.settings.devices

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

// All identifiers, names, addresses and credentials below are invented test data.
class TCircleProtocolTest {
    private fun bytes(json: String) = json.toByteArray()

    private val credentials = DeviceCredentials(
        deviceId = "dev_test_1",
        connectorToken = "salix_conn_test",
        connectUrl = "wss://connect.example.test/v1/connect",
        voiceKeyId = "gak_test",
        voiceKey = "salix_vk_test",
        server = "https://voice.example.test",
        groupId = "grp1_test",
    )

    @Test fun uuidsFollowTheContract() {
        assertEquals("f2d20001-eb8e-4a64-9ec7-ab0cbb8107c8", TCircleGatt.SERVICE.toString())
        assertEquals("f2d20004-eb8e-4a64-9ec7-ab0cbb8107c8", TCircleGatt.CREDENTIALS.toString())
        assertEquals("f2d20006-eb8e-4a64-9ec7-ab0cbb8107c8", TCircleGatt.INFO.toString())
    }

    @Test fun scanPagesAreJoinedInOrderWithoutDuplicates() {
        val collector = WifiScanCollector()
        assertEquals(WifiScanCollector.Result.Pending, collector.accept(bytes(
            """{"page":1,"pages":2,"aps":[{"ssid":"Lab","rssi":-70,"secure":true},{"ssid":"Cafe","rssi":-80,"secure":false}]}""")))
        val done = collector.accept(bytes(
            """{"page":0,"pages":2,"aps":[{"ssid":"Home","rssi":-40,"secure":true},{"ssid":"Lab","rssi":-55,"secure":true}]}"""))
        assertEquals(WifiScanCollector.Result.Done(listOf(
            WifiNetwork("Home", -40, true), WifiNetwork("Lab", -55, true), WifiNetwork("Cafe", -80, false))), done)
    }

    @Test fun aNewScanStartsOver() {
        val collector = WifiScanCollector()
        collector.accept(bytes("""{"page":0,"pages":3,"aps":[{"ssid":"Old","rssi":-40,"secure":true}]}"""))
        val done = collector.accept(bytes("""{"page":0,"pages":1,"aps":[{"ssid":"New","rssi":-50,"secure":true}]}"""))
        assertEquals(WifiScanCollector.Result.Done(listOf(WifiNetwork("New", -50, true))), done)
    }

    @Test fun scanErrorsAndJunk() {
        val collector = WifiScanCollector()
        assertEquals(WifiScanCollector.Result.Failed(busy = true), collector.accept(bytes("""{"page":0,"pages":1,"error":"busy","aps":[]}""")))
        assertEquals(WifiScanCollector.Result.Failed(busy = false), collector.accept(bytes("""{"error":"failed","aps":[]}""")))
        assertEquals(WifiScanCollector.Result.Pending, collector.accept(bytes("not json")))
        assertEquals(WifiScanCollector.Result.Pending, collector.accept(bytes("""{"page":2,"pages":1,"aps":[]}""")))
        // A network without a name is left out; one without "secure" is treated as secured.
        assertEquals(WifiScanCollector.Result.Done(listOf(WifiNetwork("Unicode 网络", -60, true))),
            collector.accept(bytes("""{"page":0,"pages":1,"aps":[{"ssid":"","rssi":-30},{"ssid":"Unicode 网络","rssi":-60}]}""")))
    }

    @Test fun statusAndInfo() {
        val failed = TCircleStatus.parse(bytes("""{"state":"wifi_failed","ssid":"Home","error":"wrong_password","provisioned":false}"""))!!
        assertEquals(WifiFailure.WRONG_PASSWORD, failed.wifiFailure)
        assertEquals(WifiFailure.NOT_FOUND, TCircleStatus.parse(bytes("""{"state":"wifi_failed","error":"not_found"}"""))!!.wifiFailure)
        assertEquals(WifiFailure.FAILED, TCircleStatus.parse(bytes("""{"state":"wifi_failed","error":"new_reason"}"""))!!.wifiFailure)
        assertTrue(TCircleStatus.parse(bytes("""{"state":"wifi_up","error":"save_failed"}"""))!!.saveFailed)
        assertFalse(TCircleStatus.parse(bytes("""{"state":"wifi_up","ip":"192.0.2.1","extra":1}"""))!!.saveFailed)
        assertNull(TCircleStatus.parse(bytes("""{"ssid":"Home"}""")))
        assertEquals(TCircleInfo("98:00:00:00:5d:28", "Comma-5D28", "1.0", false),
            TCircleInfo.parse(bytes("""{"fw_version":"1.0","mac":"98:00:00:00:5d:28","model":"t-circle-s3","name":"Comma-5D28","provisioned":false}""")))
    }

    @Test fun writeRejections() {
        assertEquals(WriteRejection.NOT_PAIRED, WriteRejection.of(0x05))
        assertEquals(WriteRejection.NOT_PAIRED, WriteRejection.of(0x0F))
        assertEquals(WriteRejection.TOO_LONG, WriteRejection.of(0x0D))
        assertEquals(WriteRejection.INVALID, WriteRejection.of(128))
        assertEquals(WriteRejection.INVALID, WriteRejection.of(0x82))
    }

    @Test fun wifiRules() {
        val secured = WifiNetwork("Home", -40, true)
        val open = WifiNetwork("Cafe", -40, false)
        assertFalse(TCircleRules.passwordValid(secured, "1234567"))
        assertTrue(TCircleRules.passwordValid(secured, "12345678"))
        assertFalse(TCircleRules.passwordValid(secured, "x".repeat(65)))
        assertTrue(TCircleRules.passwordValid(open, ""))
        assertFalse(TCircleRules.passwordValid(open, "12345678"))
        val wifi = JSONObject(String(TCircleRules.wifiJson("Home", "12345678")))
        assertEquals("Home", wifi.getString("ssid"))
        assertEquals("12345678", wifi.getString("password"))
        assertThrows(IllegalArgumentException::class.java) { TCircleRules.wifiJson("x".repeat(33), "") }
        assertThrows(IllegalArgumentException::class.java) { TCircleRules.wifiJson("Home", "short") }
    }

    @Test fun credentialsCarryTheConnectUrlAsGiven() {
        val json = JSONObject(String(TCircleRules.credentialsJson(credentials, "wsp_test", "  Kitchen ")))
        assertEquals("wss://connect.example.test/v1/connect", json.getString("connect_url"))
        assertEquals("https://voice.example.test", json.getString("server"))
        assertEquals("wsp_test", json.getString("workspace_id"))
        assertEquals("grp1_test", json.getString("group_id"))
        assertEquals("salix_conn_test", json.getString("connector_token"))
        assertEquals("salix_vk_test", json.getString("voice_key"))
        assertEquals("Kitchen", json.getString("device_name"))
        assertFalse(json.has("connector_server"))
        assertEquals(7, json.length())
    }

    @Test fun credentialsTheDeviceWouldRefuseAreNotSent() {
        fun with(connectUrl: String = credentials.connectUrl, token: String = credentials.connectorToken,
                 key: String = credentials.voiceKey, server: String = credentials.server) =
            DeviceCredentials("dev_test_1", token, connectUrl, "gak_test", key, server, "grp1_test")
        val refused = listOf(
            with(connectUrl = "https://connect.example.test/v1/connect"),
            with(connectUrl = "wss://" + "a".repeat(160)),
            with(token = "conn_test"),
            with(key = "vk_test"),
            with(server = "wss://voice.example.test"),
        )
        refused.forEach { bad ->
            assertThrows(IllegalArgumentException::class.java) { TCircleRules.credentialsJson(bad, "wsp_test", "Kitchen") }
        }
        assertThrows(IllegalArgumentException::class.java) { TCircleRules.credentialsJson(credentials, "wsp_test", " ") }
        assertThrows(IllegalArgumentException::class.java) { TCircleRules.credentialsJson(credentials, "wsp_test", "é".repeat(32)) }
        // A local dev backend is plain ws/http.
        TCircleRules.credentialsJson(with(connectUrl = "ws://10.0.2.2:4000/v1/connect", server = "http://10.0.2.2:4000"), "wsp_test", "Dev")
    }

    @Test fun credentialsMustFitOneWrite() {
        val long = DeviceCredentials("dev_test_1", "salix_conn_" + "t".repeat(140), "wss://" + "c".repeat(140),
            "gak_test", "salix_vk_" + "k".repeat(140), "https://" + "v".repeat(110), "g".repeat(90))
        assertThrows(IllegalArgumentException::class.java) { TCircleRules.credentialsJson(long, "w".repeat(90), "n".repeat(60)) }
    }

    @Test fun secretsStayOutOfStrings() {
        assertFalse(credentials.toString().contains("salix_"))
        assertFalse(AddDeviceEffect.JoinWifi("Home", "hunter22").toString().contains("hunter22"))
        assertFalse(AddDeviceEffect.WriteCredentials(credentials, "Kitchen").toString().contains("salix_"))
    }
}
