package surf.comma.android.settings.devices

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.settings.devices.AddDeviceEffect as Effect
import surf.comma.android.settings.devices.AddDeviceEvent as Event

// All identifiers, names and credentials below are invented test data.
class AddDeviceFlowTest {
    @Test fun `offer selects the exact BLE name and uses it as the setup name`() {
        val offerFlow = AddDeviceFlow("Comma-5D28")
        offerFlow.start()
        offerFlow.handle(Event.Found(device.copy(name = "Comma-FFFF")))
        assertTrue(offerFlow.step is AddDeviceStep.Scanning)
        val selected = device.copy(address = "another-random-address")
        val effects = offerFlow.handle(Event.Found(selected))
        assertEquals(Effect.Connect(selected), effects.filterIsInstance<Effect.Connect>().single())
        assertTrue(effects.contains(Effect.StopScan))
        offerFlow.handle(Event.Connected)
        offerFlow.handle(Event.Paired(TCircleInfo("98:00:00:00:5d:28", "Kitchen", "1.0", false)))
        assertEquals("Comma-5D28", (offerFlow.step as AddDeviceStep.ChoosingWifi).name)
        assertTrue(!(offerFlow.step as AddDeviceStep.ChoosingWifi).nameEditable)
        offerFlow.handle(Event.Rename("Kitchen"))
        assertEquals("Comma-5D28", (offerFlow.step as AddDeviceStep.ChoosingWifi).name)
    }

    @Test fun `missing offered device falls back to the normal list after the usual timeout`() {
        val offerFlow = AddDeviceFlow("Comma-5D28")
        val timer = offerFlow.start().filterIsInstance<Effect.Arm>().single()
        val other = device.copy(name = "Comma-FFFF")
        offerFlow.handle(Event.Found(other))
        offerFlow.handle(Event.TimedOut(timer.timer, timer.generation))
        assertEquals(AddDeviceStep.Scanning(listOf(other), quiet = true), offerFlow.step)
        offerFlow.handle(Event.Found(device))
        assertTrue(offerFlow.step is AddDeviceStep.Scanning)
        assertTrue(offerFlow.handle(Event.Pick(other)).contains(Effect.Connect(other)))
    }
    private val flow = AddDeviceFlow()
    private val device = FoundDevice("C0:00:00:00:00:01", "Comma-5D28", -50)
    private val home = WifiNetwork("Home", -45, secure = true)
    private val credentials = DeviceCredentials("dev_test_1", "salix_conn_test", "wss://connect.example.test/v1/connect",
        "gak_test", "salix_vk_test", "https://voice.example.test", "grp1_test")

    private fun status(state: String, ssid: String? = "Home", error: String? = null) =
        Event.Status(TCircleStatus(state, ssid, error, provisioned = false))

    private inline fun <reified T : Effect> List<Effect>.has() = any { it is T }
    private fun List<Effect>.arm(): Effect.Arm = filterIsInstance<Effect.Arm>().single()

    /** Drives the flow to the Wi-Fi step with [home] listed. */
    private fun toWifi() {
        flow.start()
        flow.handle(Event.Found(device))
        flow.handle(Event.Pick(device))
        flow.handle(Event.Connected)
        flow.handle(Event.Paired(TCircleInfo("98:00:00:00:5d:28", "Comma-5D28", "1.0", false)))
        flow.handle(Event.WifiScanned(listOf(home)))
    }

    /** Drives the flow to the point where the credentials were written. */
    private fun toSaving(): List<Effect> {
        toWifi()
        flow.handle(Event.Join(home, "correct horse"))
        flow.handle(status(TCircleStatus.WIFI_UP))
        flow.handle(Event.Minted(credentials, 1))
        return flow.handle(Event.Remembered(1))
    }

    @Test fun theWholeWayThrough() {
        val start = flow.start()
        assertTrue(start.has<Effect.StartScan>())
        assertEquals(FlowTimer.QUIET, start.arm().timer)

        flow.handle(Event.Found(device))
        assertEquals(AddDeviceStep.Scanning(listOf(device), quiet = false), flow.step)

        val pick = flow.handle(Event.Pick(device))
        assertTrue(pick.has<Effect.StopScan>())
        assertEquals(Effect.Connect(device), pick.single { it is Effect.Connect })
        assertEquals(AddDeviceStep.Pairing(device, connected = false), flow.step)

        assertTrue(flow.handle(Event.Connected).has<Effect.Pair>())
        assertEquals(AddDeviceStep.Pairing(device, connected = true), flow.step)

        val paired = flow.handle(Event.Paired(TCircleInfo("98:00:00:00:5d:28", "Comma-5D28", "1.0", false)))
        assertTrue(paired.has<Effect.ScanWifi>())
        flow.handle(Event.WifiScanned(listOf(home)))
        flow.handle(Event.Rename("Kitchen"))
        val wifi = flow.step as AddDeviceStep.ChoosingWifi
        assertEquals("Kitchen", wifi.name)
        assertEquals(listOf(home), wifi.networks)

        val join = flow.handle(Event.Join(home, "correct horse"))
        assertEquals(Effect.JoinWifi("Home", "correct horse"), join.single { it is Effect.JoinWifi })
        assertTrue(flow.handle(status(TCircleStatus.WIFI_CONNECTING)).isEmpty())

        // Credentials are minted only once the device is on the network.
        val up = flow.handle(status(TCircleStatus.WIFI_UP))
        assertEquals(Effect.Mint("Kitchen", 1), up.single())
        assertEquals(SetupPhase.MINTING, (flow.step as AddDeviceStep.Setup).phase)

        // Stored first, so that they can be revoked later; only then written to the device.
        assertEquals(listOf(Effect.Remember(credentials, "Kitchen", 1)), flow.handle(Event.Minted(credentials, 1)))
        assertEquals(SetupPhase.MINTING, (flow.step as AddDeviceStep.Setup).phase)
        assertTrue(flow.handle(Event.Remembered(1)).has<Effect.WriteCredentials>())
        assertEquals(SetupPhase.SAVING, (flow.step as AddDeviceStep.Setup).phase)

        assertTrue(flow.handle(Event.CredentialsWritten).isEmpty())
        val saved = flow.handle(status(TCircleStatus.SAVED))
        // Saved is not connected: only coming online confirms the credentials.
        assertTrue(!saved.has<Effect.Confirm>() && !saved.has<Effect.Revoke>())
        assertEquals(Effect.WatchOnline("dev_test_1"), saved.single { it is Effect.WatchOnline })
        // The link stays up after `saved` so a refused token is still heard.
        assertTrue(!saved.has<Effect.Disconnect>())
        flow.handle(status("connector_connecting"))
        flow.handle(Event.LinkLost)

        val online = flow.handle(Event.Online)
        assertEquals(AddDeviceStep.Done("Kitchen", "dev_test_1", online = true), flow.step)
        assertEquals(Effect.Rename("dev_test_1", "Kitchen"), online.single { it is Effect.Rename })
        assertTrue(online.has<Effect.Disconnect>())
        assertEquals(Effect.Confirm("dev_test_1"), online.single { it is Effect.Confirm })
        assertTrue(!online.has<Effect.Revoke>())
    }

    @Test fun aWrongPasswordGoesBackToWifiWithoutMinting() {
        toWifi()
        flow.handle(Event.Join(home, "wrong password"))
        val failed = flow.handle(status(TCircleStatus.WIFI_FAILED, error = "wrong_password"))
        assertTrue(!failed.has<Effect.Mint>())
        val step = flow.step as AddDeviceStep.ChoosingWifi
        assertEquals(WifiFailure.WRONG_PASSWORD, step.failure)
        assertEquals("Home", step.failedSsid)
        assertEquals(listOf(home), step.networks)
        // And the next try goes ahead.
        flow.handle(Event.Join(home, "correct horse"))
        assertEquals(Effect.Mint("Comma-5D28", 1), flow.handle(status(TCircleStatus.WIFI_UP)).single())
    }

    @Test fun anInvalidPasswordIsNotSent() {
        toWifi()
        assertTrue(flow.handle(Event.Join(home, "short")).isEmpty())
        assertTrue(flow.step is AddDeviceStep.ChoosingWifi)
    }

    @Test fun theStoredNetworkOfAProvisionedDeviceIsNotTakenForTheNewOne() {
        toWifi()
        flow.handle(Event.Join(home, "correct horse"))
        assertTrue(flow.handle(status(TCircleStatus.WIFI_UP, ssid = "Office")).isEmpty())
        assertEquals(SetupPhase.JOINING_WIFI, (flow.step as AddDeviceStep.Setup).phase)
    }

    @Test fun aMintFailureEndsWithoutAnythingToRevoke() {
        toWifi()
        flow.handle(Event.Join(home, "correct horse"))
        flow.handle(status(TCircleStatus.WIFI_UP))
        val failed = flow.handle(Event.MintFailed(AddDeviceProblem.NETWORK, 1))
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.NETWORK), flow.step)
        assertTrue(failed.has<Effect.Disconnect>())
        assertTrue(!failed.has<Effect.Revoke>())
    }

    @Test fun credentialsMintedAfterTheLinkDroppedAreRevoked() {
        toWifi()
        flow.handle(Event.Join(home, "correct horse"))
        flow.handle(status(TCircleStatus.WIFI_UP))
        flow.handle(Event.LinkLost)
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.DISCONNECTED), flow.step)
        assertEquals(listOf(Effect.Revoke(credentials)), flow.handle(Event.Minted(credentials, 1)))
    }

    @Test fun credentialsMintedAfterCancellingAreRevoked() {
        toWifi()
        flow.handle(Event.Join(home, "correct horse"))
        flow.handle(status(TCircleStatus.WIFI_UP))
        flow.handle(Event.Cancel)
        assertEquals(AddDeviceStep.Cancelled, flow.step)
        assertEquals(listOf(Effect.Revoke(credentials)), flow.handle(Event.Minted(credentials, 1)))
    }

    @Test fun refusedCredentialsAreRevoked() {
        toSaving()
        val refused = flow.handle(Event.WriteFailed(WriteRejection.INVALID))
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.REJECTED), flow.step)
        assertEquals(Effect.Revoke(credentials), refused.single { it is Effect.Revoke })
    }

    @Test fun aFailedSaveIsRevoked() {
        toSaving()
        val failed = flow.handle(status(TCircleStatus.WIFI_UP, error = "save_failed"))
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.SAVE_FAILED), flow.step)
        assertTrue(failed.has<Effect.Revoke>())
    }

    @Test fun cancellingBeforeTheDeviceSavedRevokes() {
        toSaving()
        val cancel = flow.handle(Event.Cancel)
        assertTrue(cancel.has<Effect.Revoke>())
        assertTrue(cancel.has<Effect.Disconnect>())
    }

    @Test fun aLinkLostAfterWritingWaitsForTheDeviceToShowUp() {
        toSaving()
        flow.handle(Event.CredentialsWritten)
        val lost = flow.handle(Event.LinkLost)
        assertTrue(!lost.has<Effect.Revoke>())
        assertTrue(!lost.has<Effect.Confirm>())
        assertEquals(Effect.WatchOnline("dev_test_1"), lost.single { it is Effect.WatchOnline })
        assertEquals(FlowTimer.ONLINE, lost.arm().timer)
        // It did save them: online confirms the credentials.
        val online = flow.handle(Event.Online)
        assertEquals(Effect.Confirm("dev_test_1"), online.single { it is Effect.Confirm })
        assertEquals(AddDeviceStep.Done("Comma-5D28", "dev_test_1", online = true), flow.step)
    }

    @Test fun anUncertainSaveThatNeverComesOnlineIsRevoked() {
        toSaving()
        val lost = flow.handle(Event.LinkLost)
        val timeout = flow.handle(Event.TimedOut(FlowTimer.ONLINE, lost.arm().generation))
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.NOT_ONLINE), flow.step)
        assertTrue(timeout.has<Effect.Revoke>())
    }

    @Test fun aSaveTimeoutIsTreatedLikeALostLink() {
        val minted = toSaving()
        val timeout = flow.handle(Event.TimedOut(FlowTimer.SAVE, minted.arm().generation))
        assertTrue(timeout.has<Effect.WatchOnline>())
        assertEquals(SetupPhase.COMING_ONLINE, (flow.step as AddDeviceStep.Setup).phase)
    }

    @Test fun aSavedDeviceThatIsSlowToComeOnlineKeepsItsCredentials() {
        toSaving()
        val saved = flow.handle(status(TCircleStatus.SAVED))
        val timeout = flow.handle(Event.TimedOut(FlowTimer.ONLINE, saved.arm().generation))
        assertEquals(AddDeviceStep.Done("Comma-5D28", "dev_test_1", online = false), flow.step)
        assertTrue(!timeout.has<Effect.Revoke>())
        // Left unconfirmed, so that pending-setup reconciliation revokes them if it never connects.
        assertTrue(!saved.has<Effect.Confirm>() && !timeout.has<Effect.Confirm>())
        assertTrue(timeout.has<Effect.Disconnect>())
        // Cancelling (leaving the page) afterwards changes nothing.
        assertTrue(flow.handle(Event.Cancel).isEmpty())
    }

    @Test fun aRefusedConnectorTokenIsRevokedEvenAfterSaving() {
        toSaving()
        flow.handle(status(TCircleStatus.SAVED))
        val refused = flow.handle(status(TCircleStatus.CONNECTOR_FAILED))
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.CONNECTOR_REJECTED), flow.step)
        assertEquals(Effect.Revoke(credentials), refused.single { it is Effect.Revoke })
    }

    @Test fun leavingWhileASavedDeviceComesOnlineDoesNotRevoke() {
        toSaving()
        flow.handle(status(TCircleStatus.SAVED))
        val cancel = flow.handle(Event.Cancel)
        assertTrue(!cancel.has<Effect.Revoke>())
        assertTrue(cancel.has<Effect.StopWatching>())
    }

    @Test fun leavingWhileAnUncertainDeviceComesOnlineLeavesItToReconciliation() {
        toSaving()
        flow.handle(Event.LinkLost)
        assertTrue(!flow.handle(Event.Cancel).has<Effect.Revoke>())
    }

    @Test fun disconnectsBeforeMintingFailWithNothingToRevoke() {
        toWifi()
        val lost = flow.handle(Event.LinkLost)
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.DISCONNECTED), flow.step)
        assertTrue(!lost.has<Effect.Revoke>())
    }

    @Test fun reconnectingAfterADropSendsWifiAgainEvenIfTheDeviceWasOnIt() {
        // The device reached the new network, then the link dropped: it forgets that network.
        toWifi()
        flow.handle(Event.Join(home, "correct horse"))
        flow.handle(status(TCircleStatus.WIFI_UP))
        val lost = flow.handle(Event.LinkLost)
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.DISCONNECTED), flow.step)
        assertTrue(lost.has<Effect.Disconnect>())

        flow.handle(Event.Retry)
        flow.handle(Event.Pick(device))
        flow.handle(Event.Connected)
        flow.handle(Event.Paired(TCircleInfo("98:00:00:00:5d:28", "Comma-5D28", "1.0", true)))
        assertTrue(flow.step is AddDeviceStep.ChoosingWifi)
        // An up network before Wi-Fi is sent again (the stored one) starts nothing.
        assertTrue(flow.handle(status(TCircleStatus.WIFI_UP)).isEmpty())
        assertTrue(flow.step is AddDeviceStep.ChoosingWifi)

        val join = flow.handle(Event.Join(home, "correct horse"))
        assertTrue(join.any { it is Effect.JoinWifi && it.ssid == "Home" })
        assertTrue(!join.has<Effect.Mint>() && !join.has<Effect.WriteCredentials>())
        assertTrue(flow.handle(status(TCircleStatus.WIFI_UP)).has<Effect.Mint>())
    }

    @Test fun resultsOfAnEarlierMintingDoNotReachTheRetry() {
        toWifi()
        flow.handle(Event.Join(home, "correct horse"))
        assertEquals(Effect.Mint("Comma-5D28", 1), flow.handle(status(TCircleStatus.WIFI_UP)).single())
        flow.handle(Event.LinkLost)

        flow.handle(Event.Retry)
        flow.handle(Event.Pick(device))
        flow.handle(Event.Connected)
        flow.handle(Event.Paired(TCircleInfo("98:00:00:00:5d:28", "Comma-5D28", "1.0", false)))
        flow.handle(Event.WifiScanned(listOf(home)))
        flow.handle(Event.Join(home, "correct horse"))
        assertEquals(Effect.Mint("Comma-5D28", 2), flow.handle(status(TCircleStatus.WIFI_UP)).single())
        val minting = flow.step

        // The first attempt answers late: its failure does not end this one, its credentials are
        // taken back instead of going to the device on the new link.
        assertTrue(flow.handle(Event.MintFailed(AddDeviceProblem.NETWORK, 1)).isEmpty())
        assertEquals(listOf(Effect.Revoke(credentials)), flow.handle(Event.Minted(credentials, 1)))
        assertEquals(minting, flow.step)

        val second = DeviceCredentials("dev_test_2", "salix_conn_test2", "wss://connect.example.test/v1/connect",
            "gak_test2", "salix_vk_test2", "https://voice.example.test", "grp1_test")
        flow.handle(Event.Minted(second, 2))
        assertTrue(flow.handle(Event.Remembered(2)).any { it is Effect.WriteCredentials && it.credentials === second })
    }

    @Test fun credentialsThatCannotBeStoredAreRevokedWithoutReachingTheDevice() {
        toWifi()
        flow.handle(Event.Join(home, "correct horse"))
        flow.handle(status(TCircleStatus.WIFI_UP))
        flow.handle(Event.Minted(credentials, 1))

        val failed = flow.handle(Event.RememberFailed(1))
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.STORAGE), flow.step)
        assertTrue(failed.contains(Effect.Revoke(credentials)))
        assertTrue(!failed.has<Effect.WriteCredentials>())
        // A late answer of the store changes nothing.
        assertTrue(flow.handle(Event.Remembered(1)).isEmpty())
    }

    @Test fun pairingProblems() {
        flow.start()
        flow.handle(Event.Pick(device))
        flow.handle(Event.ConnectFailed)
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.CONNECT_FAILED), flow.step)

        val retry = flow.handle(Event.Retry)
        assertTrue(retry.has<Effect.StartScan>())
        assertEquals(AddDeviceStep.Scanning(emptyList(), quiet = false), flow.step)
        flow.handle(Event.Pick(device))
        val connected = flow.handle(Event.Connected)
        flow.handle(Event.PairingFailed)
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.PAIRING_FAILED), flow.step)

        flow.handle(Event.Retry)
        flow.handle(Event.Pick(device))
        val waiting = flow.handle(Event.Connected).arm()
        assertEquals(FlowTimer.PAIR, waiting.timer)
        // The previous attempt's timer no longer counts.
        assertTrue(flow.handle(Event.TimedOut(FlowTimer.PAIR, connected.arm().generation)).isEmpty())
        flow.handle(Event.TimedOut(FlowTimer.PAIR, waiting.generation))
        assertEquals(AddDeviceStep.Failed(AddDeviceProblem.TIMEOUT), flow.step)
    }

    @Test fun scanningGoesQuietAndShowsEachNameOnce() {
        val quiet = flow.start().arm()
        flow.handle(Event.Found(device))
        // The same device back from a new pairing session with a new address.
        val again = device.copy(address = "C0:00:00:00:00:02", rssi = -40)
        flow.handle(Event.Found(again))
        flow.handle(Event.TimedOut(FlowTimer.QUIET, quiet.generation))
        assertEquals(AddDeviceStep.Scanning(listOf(again), quiet = true), flow.step)
    }

    @Test fun wifiScanFailuresAndRescans() {
        flow.start()
        flow.handle(Event.Pick(device))
        flow.handle(Event.Connected)
        val scan = flow.handle(Event.Paired(TCircleInfo("98:00:00:00:5d:28", "Comma-5D28", null, false))).arm()
        flow.handle(Event.TimedOut(FlowTimer.WIFI_SCAN, scan.generation))
        assertTrue((flow.step as AddDeviceStep.ChoosingWifi).scanFailed)
        assertTrue(flow.handle(Event.Rescan).has<Effect.ScanWifi>())
        // A second rescan while one runs is ignored.
        assertTrue(flow.handle(Event.Rescan).isEmpty())
        flow.handle(Event.WifiScanFailed(busy = true))
        val step = flow.step as AddDeviceStep.ChoosingWifi
        assertTrue(step.scanFailed && !step.scanning)
        assertEquals(null, step.networks)
    }

    @Test fun invalidNamesAreIgnored() {
        toWifi()
        flow.handle(Event.Rename("   "))
        flow.handle(Event.Rename("n".repeat(64)))
        assertEquals("Comma-5D28", (flow.step as AddDeviceStep.ChoosingWifi).name)
    }
}
