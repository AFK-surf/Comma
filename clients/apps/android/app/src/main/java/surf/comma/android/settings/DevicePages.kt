package surf.comma.android.settings

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.text.InputType
import android.text.method.PasswordTransformationMethod
import android.text.format.DateUtils
import android.view.Gravity
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.settings.devices.AccessProblem
import surf.comma.android.settings.devices.AddDeviceEvent
import surf.comma.android.settings.devices.AddDeviceProblem
import surf.comma.android.settings.devices.AddDeviceSession
import surf.comma.android.settings.devices.AddDeviceStep
import surf.comma.android.settings.devices.FoundDevice
import surf.comma.android.settings.devices.SetupPhase
import surf.comma.android.settings.devices.TCircleRules
import surf.comma.android.settings.devices.WifiFailure
import surf.comma.android.settings.devices.WifiNetwork
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.ui.TaskStatusIconView
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level

/** Whether the phone can look for devices: Bluetooth permission first, then Bluetooth itself. */
internal enum class BluetoothReadiness { NEEDS_PERMISSION, OFF, READY }

internal fun Activity.bluetoothReadiness(): BluetoothReadiness {
    val granted = BLUETOOTH_PERMISSIONS.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    return when {
        !granted -> BluetoothReadiness.NEEDS_PERMISSION
        getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled != true -> BluetoothReadiness.OFF
        else -> BluetoothReadiness.READY
    }
}

internal val BLUETOOTH_PERMISSIONS = arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)

/**
 * Sets up a Comma device over Bluetooth in five steps on one page: find it, pair (a device with a
 * screen shows a code; one without pairs on its own), choose Wi-Fi, set it up, done. Leaving the
 * page cancels the setup.
 */
internal class AddDevicePage(private val ctx: SettingsContext,
    private val offer: surf.comma.android.settings.devices.DeviceSetupOffer? = null) : SettingsPage {
    override val key = KEY
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, activity.getString(R.string.devices_add)) { ctx.back() }
    override val view: View = layout

    private val heading = activity.text(Level.TITLE3, R.color.token_text_primary, DesignFonts.semibold).apply {
        id = R.id.devices_add_heading
        isAccessibilityHeading = true
    }
    private val body = activity.text(Level.REGULAR, R.color.token_text_tertiary).apply { id = R.id.devices_add_body }
    private val notice = activity.text(Level.SMALL, R.color.token_text_error_primary).apply { isVisible = false }
    private val listTitle = activity.text(Level.SMALL, R.color.token_text_quaternary, DesignFonts.medium).apply {
        setPadding(activity.dp(16), 0, activity.dp(16), activity.dp(8))
    }
    private val list = SettingsSection(activity, null)
    private val listBox = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        addView(listTitle)
        addView(list)
    }
    private val footnote = activity.text(Level.SMALL, R.color.token_text_quaternary).apply {
        setPadding(activity.dp(16), activity.dp(8), activity.dp(16), 0)
    }
    private val primary = activity.filledButton("", R.color.token_bg_brand_solid, null).apply { id = R.id.devices_add_primary }
    private val secondary = activity.filledButton("", R.color.token_bg_quaternary, R.color.token_text_primary).apply {
        id = R.id.devices_add_secondary
    }

    private var session: AddDeviceSession? = SettingsGraph.addDevice
    private var collecting: Job? = null
    private var shown: Any? = null

    init {
        SettingsGraph.addDeviceOpen.value = true
        surf.comma.android.settings.devices.NearbyDevices.get(activity).refresh()
        layout.section(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(activity.dp(4), activity.dp(8), activity.dp(4), 0)
            addView(heading)
            addView(body, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
            addView(notice, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(12) })
        }, top = 0)
        layout.section(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(listBox)
            addView(footnote)
        })
        layout.section(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(primary, LinearLayout.LayoutParams(-1, activity.dp(48)))
            addView(secondary, LinearLayout.LayoutParams(-1, activity.dp(48)).apply { topMargin = activity.dp(8) })
        })
        ctx.onRender(this, ::render)
    }

    override fun onRemoved() {
        collecting?.cancel()
        session?.let(SettingsGraph::endAddDevice)
        session = null
        SettingsGraph.addDeviceOpen.value = false
    }

    private fun render() {
        val readiness = activity.bluetoothReadiness()
        if (session == null && readiness == BluetoothReadiness.READY) {
            session = SettingsGraph.startAddDevice(activity, offer)
        }
        val session = session
        if (session != null && collecting == null) {
            collecting = activity.lifecycleScope.launch {
                activity.repeatOnLifecycle(Lifecycle.State.STARTED) { session.step.collect { show(it) } }
            }
        }
        if (session == null) showReadiness(readiness)
    }

    private fun showReadiness(readiness: BluetoothReadiness) {
        if (shown == readiness) return
        shown = readiness
        heading.setText(if (readiness == BluetoothReadiness.OFF) R.string.devices_add_bluetooth_title else R.string.devices_add_permission_title)
        body.setText(if (readiness == BluetoothReadiness.OFF) R.string.devices_add_bluetooth_off else R.string.devices_add_bluetooth_permission)
        notice.isVisible = false
        listBox.isVisible = false
        footnote.isVisible = false
        button(primary, if (readiness == BluetoothReadiness.OFF) R.string.devices_add_turn_on_bluetooth else R.string.devices_add_allow_bluetooth) {
            if (readiness == BluetoothReadiness.OFF) ctx.requestBluetoothOn() else ctx.requestBluetoothPermission()
        }
        button(secondary, null) {}
    }

    private fun show(step: AddDeviceStep) {
        if (step == shown) return
        shown = step
        notice.isVisible = false
        footnote.isVisible = false
        listBox.isVisible = false
        list.card.removeAllViews()
        when (step) {
            is AddDeviceStep.Scanning -> showScanning(step)
            is AddDeviceStep.Pairing -> {
                heading.text = activity.getString(if (step.connected) R.string.devices_add_code_title else R.string.devices_add_connecting_title,
                    step.device.name)
                body.text = activity.getString(if (step.connected) R.string.devices_add_code_body else R.string.devices_add_connecting_body,
                    step.device.name)
                button(primary, null) {}
                button(secondary, R.string.settings_cancel) { ctx.back() }
            }
            is AddDeviceStep.ChoosingWifi -> showWifi(step)
            is AddDeviceStep.Setup -> showSetup(step)
            is AddDeviceStep.Done -> {
                heading.setText(if (step.online) R.string.devices_add_done_title else R.string.devices_add_almost_title)
                body.text = activity.getString(if (step.online) R.string.devices_add_done_body else R.string.devices_add_almost_body, step.name)
                listBox.isVisible = true
                listTitle.isVisible = false
                list.add(SettingsRow(activity, R.drawable.ic_settings_comma_device, step.name).detail(activity.getString(
                    if (step.online) R.string.devices_online else R.string.devices_offline)))
                button(primary, R.string.devices_add_finish) { ctx.back() }
                button(secondary, null) {}
            }
            is AddDeviceStep.Failed -> {
                heading.setText(R.string.devices_add_failed_title)
                body.setText(problemText(step.problem))
                button(primary, R.string.devices_add_try_again) { session?.send(AddDeviceEvent.Retry) }
                button(secondary, R.string.settings_cancel) { ctx.back() }
            }
            AddDeviceStep.Cancelled -> Unit
        }
    }

    private fun showScanning(step: AddDeviceStep.Scanning) {
        heading.setText(R.string.devices_add_scan_title)
        body.setText(R.string.devices_add_scan_body)
        listBox.isVisible = step.selectingName == null && step.devices.isNotEmpty()
        listTitle.isVisible = true
        listTitle.setText(R.string.devices_add_found)
        step.devices.forEach { device -> list.add(foundRow(device)) }
        footnote.isVisible = step.selectingName != null || step.devices.isEmpty()
        footnote.setText(if (step.quiet) R.string.devices_add_scan_quiet else R.string.devices_add_scanning)
        button(primary, null) {}
        button(secondary, R.string.settings_cancel) { ctx.back() }
    }

    private fun foundRow(device: FoundDevice) = SettingsRow(activity, R.drawable.ic_settings_comma_device, device.name)
        .value(null, chevron = true)
        .onClick { session?.send(AddDeviceEvent.Pick(device)) }

    private fun showWifi(step: AddDeviceStep.ChoosingWifi) {
        heading.setText(R.string.devices_add_wifi_title)
        body.text = activity.getString(R.string.devices_add_wifi_body, step.name)
        val failure = step.failure
        notice.isVisible = failure != null || step.scanFailed
        notice.text = when {
            failure != null -> activity.getString(wifiFailureText(failure), step.failedSsid.orEmpty())
            else -> activity.getString(R.string.devices_add_wifi_scan_failed)
        }
        listBox.isVisible = true
        listTitle.isVisible = true
        listTitle.setText(R.string.devices_add_wifi_networks)
        list.add(SettingsRow(activity, if (step.nameEditable) R.drawable.ic_settings_edit else R.drawable.ic_settings_comma_device,
            activity.getString(R.string.devices_add_name)).value(step.name, chevron = step.nameEditable).apply {
            if (step.nameEditable) onClick {
                TextFieldDialog(activity, activity.getString(R.string.devices_add_name), activity.getString(R.string.devices_add_name_description),
                    step.name, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_WORDS,
                    activity.getString(R.string.settings_save), TCircleRules::nameValid) { session?.send(AddDeviceEvent.Rename(it)) }.show()
            }
        })
        step.networks.orEmpty().forEach { network -> list.add(networkRow(network)) }
        list.add(SettingsRow(activity, null, activity.getString(
            if (step.scanning) R.string.devices_add_wifi_scanning else R.string.devices_add_wifi_rescan)).apply {
            isEnabled = !step.scanning
            onClick { session?.send(AddDeviceEvent.Rescan) }
        })
        footnote.isVisible = true
        footnote.setText(R.string.devices_add_wifi_band)
        button(primary, null) {}
        button(secondary, R.string.settings_cancel) { ctx.back() }
    }

    private fun networkRow(network: WifiNetwork): SettingsRow {
        val signal = activity.getString(when {
            network.rssi >= -60 -> R.string.devices_add_wifi_strong
            network.rssi >= -72 -> R.string.devices_add_wifi_good
            else -> R.string.devices_add_wifi_weak
        })
        val security = activity.getString(if (network.secure) R.string.devices_add_wifi_secured else R.string.devices_add_wifi_open)
        return SettingsRow(activity, null, network.ssid).detail("$security · $signal").onClick {
            if (!network.secure) {
                session?.send(AddDeviceEvent.Join(network, ""))
                return@onClick
            }
            TextFieldDialog(activity, network.ssid, activity.getString(R.string.devices_add_wifi_password_description), "",
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD, activity.getString(R.string.devices_add_wifi_join),
                { TCircleRules.passwordValid(network, it) }, trim = false) { session?.send(AddDeviceEvent.Join(network, it)) }.show()
        }
    }

    private fun showSetup(step: AddDeviceStep.Setup) {
        heading.text = activity.getString(R.string.devices_add_setup_title, step.name)
        body.setText(R.string.devices_add_setup_body)
        listBox.isVisible = true
        listTitle.isVisible = false
        val phases = listOf(
            SetupPhase.JOINING_WIFI to activity.getString(R.string.devices_add_setup_wifi, step.ssid),
            SetupPhase.MINTING to activity.getString(R.string.devices_add_setup_credentials),
            SetupPhase.SAVING to activity.getString(R.string.devices_add_setup_save),
            SetupPhase.COMING_ONLINE to activity.getString(R.string.devices_add_setup_online),
        )
        phases.forEach { (phase, label) ->
            val done = phase.ordinal < step.phase.ordinal
            val current = phase == step.phase
            list.add(SettingsRow(activity, if (done) R.drawable.ic_composer_check else R.drawable.ic_task_in_progress, label,
                tint = if (done || current) R.color.token_fg_primary else R.color.token_fg_quaternary).apply {
                if (current) spinIcon()
                if (!done && !current) title.setTextColor(activity.color(R.color.token_text_quaternary))
                value(activity.getString(when {
                    done -> R.string.devices_add_setup_done
                    current -> R.string.devices_add_setup_working
                    else -> R.string.devices_add_setup_waiting
                }))
            })
        }
        button(primary, null) {}
        button(secondary, R.string.settings_cancel) { ctx.back() }
    }

    /** Swaps the row's glyph for the task list's turning in-progress glyph. */
    private fun SettingsRow.spinIcon() {
        val spinner = TaskStatusIconView(activity).apply {
            id = R.id.devices_add_working
            setStatus(TaskStatusBucket.IN_PROGRESS, activity.color(R.color.token_fg_primary))
        }
        icon.isVisible = false
        addView(spinner, 0, LinearLayout.LayoutParams(icon.layoutParams as LinearLayout.LayoutParams))
    }

    private fun button(view: TextView, label: Int?, action: () -> Unit) {
        view.isVisible = label != null
        if (label != null) view.setText(label)
        view.setOnClickListener { action() }
    }

    private fun wifiFailureText(failure: WifiFailure) = when (failure) {
        WifiFailure.WRONG_PASSWORD -> R.string.devices_add_wifi_wrong_password
        WifiFailure.NOT_FOUND -> R.string.devices_add_wifi_not_found
        WifiFailure.TIMEOUT -> R.string.devices_add_wifi_timeout
        WifiFailure.FAILED -> R.string.devices_add_wifi_failed
    }

    private fun problemText(problem: AddDeviceProblem) = when (problem) {
        AddDeviceProblem.CONNECT_FAILED -> R.string.devices_problem_connect
        AddDeviceProblem.PAIRING_FAILED -> R.string.devices_problem_pairing
        AddDeviceProblem.DISCONNECTED -> R.string.devices_problem_disconnected
        AddDeviceProblem.TIMEOUT -> R.string.devices_problem_timeout
        AddDeviceProblem.REJECTED -> R.string.devices_problem_rejected
        AddDeviceProblem.SAVE_FAILED -> R.string.devices_problem_save
        AddDeviceProblem.NOT_ONLINE -> R.string.devices_problem_not_online
        AddDeviceProblem.NETWORK -> R.string.devices_problem_network
        AddDeviceProblem.SERVER -> R.string.devices_problem_server
        AddDeviceProblem.FORBIDDEN -> R.string.devices_problem_forbidden
        AddDeviceProblem.LIMIT -> R.string.devices_problem_limit
        AddDeviceProblem.CONNECTOR_REJECTED -> R.string.devices_problem_connector_rejected
        AddDeviceProblem.STORAGE -> R.string.devices_problem_storage
    }

    companion object { const val KEY = "add-device" }
}

/**
 * One Connector device: its state, whether Comma may act through it, and for a Comma device,
 * removing it.
 */
internal class HomeDevicePage(private val ctx: SettingsContext, private val device: HomeDevice) : SettingsPage {
    override val key = KEY
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, device.name) { ctx.back() }
    override val view: View = layout
    private val status = SettingsRow(activity, null, activity.getString(R.string.devices_status))
    private val remove = SettingsRow(activity, R.drawable.ic_settings_trash, activity.getString(R.string.devices_remove),
        tint = R.color.token_text_error_primary)
    private val accessSwitch = SettingsSwitch(activity)
    private val access = SettingsRow(activity, null, activity.getString(R.string.devices_access)).apply {
        id = R.id.devices_access
        detail(activity.getString(R.string.devices_access_description))
        trailing(accessSwitch)
        onClick { toggleAccess() }
        accessibilityDelegate = object : View.AccessibilityDelegate() {
            override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
                super.onInitializeAccessibilityNodeInfo(host, info)
                info.className = Switch::class.java.name
                info.isCheckable = true
                info.isChecked = accessSwitch.checked
            }
        }
    }
    private val accessNotice = activity.text(Level.SMALL, R.color.token_text_quaternary).apply {
        id = R.id.devices_access_notice
        setPadding(activity.dp(16), activity.dp(8), activity.dp(16), 0)
        isVisible = false
    }
    private var seen = false
    private var rendered = false

    init {
        val kind = SettingsRow(activity, null, activity.getString(R.string.devices_kind)).value(activity.getString(
            if (device.isCommaDevice) R.string.devices_kind_comma else R.string.devices_kind_computer))
        layout.section(SettingsSection(activity, null).add(status).add(kind), top = 0)
        layout.section(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(SettingsSection(activity, null).add(access))
            addView(accessNotice)
        })
        if (device.isCommaDevice) {
            remove.id = R.id.devices_remove
            remove.icon.imageTintList = ColorStateList.valueOf(activity.color(R.color.token_fg_error))
            remove.detail(activity.getString(R.string.devices_remove_description))
            remove.onClick { confirmRemove() }
            layout.section(SettingsSection(activity, null).add(remove))
        }
        ctx.onRender(this, ::render)
        ctx.devices.refresh(device.id)
    }

    private fun shown(): HomeDevice = ctx.devices.state.value.devices?.firstOrNull { it.id == device.id } ?: device

    /** Turning operations on is confirmed first; turning them off is not. */
    private fun toggleAccess() {
        val state = ctx.devices.state.value
        val current = shown()
        if (!current.online || device.id in state.accessPending) return
        if (state.allowsOperations(current)) {
            ctx.devices.setAccess(current, false)
            return
        }
        ConfirmDialog(activity, activity.getString(R.string.devices_access_confirm_title),
            activity.getString(R.string.devices_access_confirm_message), activity.getString(R.string.devices_access_allow),
            destructive = false) { ctx.devices.setAccess(shown(), true) }.show()
    }

    private fun confirmRemove() {
        val message = activity.getString(R.string.devices_remove_message, device.name) +
            if (ctx.devices.setUpHere(device.id)) "" else "\n\n" + activity.getString(R.string.devices_remove_elsewhere)
        ConfirmDialog(activity, activity.getString(R.string.devices_remove_title, device.name), message,
            activity.getString(R.string.devices_remove), destructive = true) { ctx.devices.remove(device) }.show()
    }

    private fun render() {
        val state = ctx.devices.state.value
        val current = state.devices?.firstOrNull { it.id == device.id }
        if (current != null) seen = true
        // Removed: back to the list, which shows the outcome.
        if (seen && current == null && device.id !in state.removing && state.devices != null) {
            seen = false
            ctx.back()
            return
        }
        val shown = current ?: device
        status.value(activity.getString(if (shown.online) R.string.devices_online else R.string.devices_offline))
        status.detail(if (shown.online) null else lastSeen(shown))
        remove.isEnabled = device.id !in state.removing
        accessSwitch.set(state.allowsOperations(shown), animate = rendered)
        rendered = true
        access.isEnabled = shown.online
        val problem = state.accessProblems[device.id]
        accessNotice.isVisible = !shown.online || problem != null
        accessNotice.setTextColor(activity.color(
            if (problem != null && problem != AccessProblem.OFFLINE) R.color.token_text_error_primary else R.color.token_text_quaternary))
        accessNotice.text = when {
            problem != null -> activity.getString(accessProblemText(problem))
            !shown.online -> activity.getString(R.string.devices_access_offline)
            else -> null
        }
        remove.value(if (device.id in state.removing) activity.getString(R.string.devices_removing) else null)
    }

    private fun accessProblemText(problem: AccessProblem) = when (problem) {
        AccessProblem.UNCONFIRMED -> R.string.devices_access_unconfirmed
        AccessProblem.OFFLINE -> R.string.devices_access_offline
        AccessProblem.TIMEOUT -> R.string.devices_access_timeout
        AccessProblem.FORBIDDEN -> R.string.devices_access_forbidden
        AccessProblem.NOT_FOUND -> R.string.devices_access_not_found
        AccessProblem.NETWORK -> R.string.devices_problem_network
        AccessProblem.SERVER -> R.string.devices_access_server
    }

    private fun lastSeen(device: HomeDevice): String? {
        val seconds = device.disconnectedAt ?: return null
        val relative = DateUtils.getRelativeTimeSpanString(seconds * 1000, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
        return activity.getString(R.string.settings_devices_last_active, relative)
    }

    companion object { const val KEY = "home-device" }
}

/**
 * One line of text with a title and a short description; the action stays off until [valid].
 * A password field is masked, with a button to show it.
 */
internal class TextFieldDialog(
    private val activity: Activity,
    title: CharSequence,
    description: CharSequence,
    current: String,
    inputType: Int,
    action: CharSequence,
    valid: (String) -> Boolean,
    private val trim: Boolean = true,
    onDone: (String) -> Unit,
) : SettingsDialog(activity, keyboard = true) {
    private val password = inputType and InputType.TYPE_MASK_VARIATION == InputType.TYPE_TEXT_VARIATION_PASSWORD
    private val input = EditText(activity).apply {
        id = R.id.devices_text_input
        // Single line first: it sets its own transformation, which would undo the password mask.
        isSingleLine = true
        this.inputType = inputType
        setText(current)
        setSelection(text.length)
        DesignTypography.applyTo(this, Level.REGULAR)
        setTextColor(activity.color(R.color.token_text_primary))
        setHintTextColor(activity.color(R.color.token_text_placeholder))
        imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        background = roundRect(activity.color(R.color.token_bg_quaternary), activity.dp(10).toFloat())
        setPadding(activity.dp(14), activity.dp(12), activity.dp(if (password) 48 else 14), activity.dp(12))
    }
    private val reveal = ImageView(activity).apply {
        id = R.id.devices_text_reveal
        imageTintList = ColorStateList.valueOf(activity.color(R.color.token_fg_quaternary))
        scaleType = ImageView.ScaleType.CENTER
        setOnClickListener { showPassword(input.transformationMethod != null) }
    }

    init {
        card.addView(title(title))
        card.addView(message(description).apply { DesignTypography.applyTo(this, Level.SMALL) },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(6) })
        val field = FrameLayout(activity).apply {
            addView(input, FrameLayout.LayoutParams(-1, -2))
            if (password) addView(reveal, FrameLayout.LayoutParams(activity.dp(44), -1, Gravity.END or Gravity.CENTER_VERTICAL))
        }
        if (password) showPassword(false)
        card.addView(field, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(16) })
        val row = buttons(action, destructive = false) { onDone(value()) }
        val confirm = row.findViewById<TextView>(R.id.settings_dialog_confirm)
        card.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
        fun validate() {
            val enabled = valid(value())
            confirm.isEnabled = enabled
            confirm.alpha = if (enabled) 1f else 0.4f
        }
        input.doAfterTextChanged { validate() }
        input.setOnEditorActionListener { _, id, _ ->
            if (id == EditorInfo.IME_ACTION_DONE && confirm.isEnabled) { confirm.performClick(); true } else false
        }
        validate()
        // The window asks for the keyboard when it gains focus; the field has to hold focus by then.
        input.requestFocus()
    }

    private fun showPassword(show: Boolean) {
        val selection = input.selectionStart to input.selectionEnd
        input.transformationMethod = if (show) null else PasswordTransformationMethod.getInstance()
        if (selection.first >= 0) input.setSelection(selection.first, selection.second)
        reveal.setImageResource(if (show) R.drawable.ic_settings_hide else R.drawable.ic_settings_show)
        reveal.contentDescription = activity.getString(if (show) R.string.devices_password_hide else R.string.devices_password_show)
    }

    private fun value() = input.text.toString().let { if (trim) it.trim() else it }

    override fun onClosing() {
        activity.getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(input.windowToken, 0)
    }
}
