package com.cruyfford.ps3hub

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.view.MotionEvent
import android.widget.ImageView
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInteropFilter
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.nio.ByteBuffer

/** native PREMO client (Core/premo.c + rp_player.c with FFmpeg) */
object RP {
    val ok: Boolean = runCatching { System.loadLibrary("rp") }.isSuccess
    @JvmStatic external fun start(host: String, id: String, key: String, mac: String, nick: String, bitrate: Int): Long
    @JvmStatic external fun stop(h: Long)
    @JvmStatic external fun state(h: Long): Int
    @JvmStatic external fun status(h: Long): String
    @JvmStatic external fun video(h: Long, buf: ByteBuffer, info: IntArray): Int
    @JvmStatic external fun audio(h: Long, out: FloatArray, frames: Int)
    @JvmStatic external fun button(h: Long, code: Int, down: Boolean)
    @JvmStatic external fun axis(h: Long, off: Int, v: Int)
    @JvmStatic external fun home(h: Long)

    const val STREAMING = 2; const val ENDED = 3; const val FAILED = 4
    const val SELECT = 0x0501; const val L3 = 0x0502; const val R3 = 0x0504; const val START = 0x0508
    const val UP = 0x0510; const val RIGHT = 0x0520; const val DOWN = 0x0540; const val LEFT = 0x0580
    const val R2 = 0x0701; const val L2 = 0x0702; const val L1 = 0x0704; const val R1 = 0x0708
    const val TRI = 0x0710; const val CIR = 0x0720; const val CRO = 0x0740; const val SQU = 0x0780
    const val RX = 0x08; const val RY = 0x0a; const val LX = 0x0c; const val LY = 0x0e
}

private fun hexBytes(s: String): Int? {
    val c = s.filter { it !in ": -\n\t\r" }
    if (c.isEmpty() || c.length % 2 != 0 || c.any { !it.isLetterOrDigit() || it.lowercaseChar() > 'f' }) return null
    return c.length / 2
}

class RpSettings(ctx: Context) {
    private val p = ctx.getSharedPreferences("rp", Context.MODE_PRIVATE)
    var id by mutableStateOf(p.getString("id", "") ?: "")
    var key by mutableStateOf(p.getString("key", "") ?: "")
    var mac by mutableStateOf(p.getString("mac", "") ?: "")
    var nick by mutableStateOf(p.getString("nick", "Android") ?: "Android")
    var bitrate by mutableIntStateOf(p.getInt("br", 1024000))
    fun save() { p.edit().putString("id", id.trim()).putString("key", key.trim()).putString("mac", mac.trim()).putString("nick", nick).putInt("br", bitrate).apply() }
    fun problem(host: String): String? = when {
        host.isBlank() -> L.t("Enter the PS3 IP in Settings.", "أدخل عنوان الجهاز في الإعدادات.")
        hexBytes(id) != 16 -> L.t("Device ID must be 32 hex digits.", "رقم الجهاز يجب أن يكون 32 خانة hex.")
        hexBytes(key) != 16 -> L.t("Key must be 32 hex digits.", "المفتاح يجب أن يكون 32 خانة hex.")
        hexBytes(mac) != 6 -> L.t("MAC must be 12 hex digits.", "الـ MAC يجب أن يكون 12 خانة hex.")
        else -> null
    }
    /** ps3rp.json from tools/ps3rp.py */
    fun import(text: String, vm: HubVM): Boolean = runCatching {
        val o = JSONObject(text); var f = false
        o.optString("psp_id").takeIf { it.isNotEmpty() }?.let { id = it; f = true }
        o.optString("pkey").takeIf { it.isNotEmpty() }?.let { key = it; f = true }
        o.optString("psp_mac").takeIf { it.isNotEmpty() }?.let { mac = it; f = true }
        o.optString("nickname").takeIf { it.isNotEmpty() }?.let { nick = it }
        o.optString("ps3_ip").takeIf { it.isNotEmpty() && vm.host.isBlank() }?.let { vm.host = it; vm.saveSettings() }
        if (f) save(); f
    }.getOrDefault(false)
}

@Composable
fun RemotePlayScreen(vm: HubVM) {
    val ctx = LocalContext.current
    val s = remember { RpSettings(ctx) }
    var playing by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf("") }
    val clip = LocalClipboardManager.current
    val open = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { u ->
        if (u != null) {
            val t = runCatching { ctx.contentResolver.openInputStream(u)!!.use { it.readBytes().decodeToString() } }.getOrDefault("")
            msg = if (s.import(t, vm)) L.t("Keys imported", "تم استيراد المفاتيح") else L.t("Not a ps3rp.json file", "ليس ملف ps3rp.json")
        }
    }
    if (playing) { Player(vm, s) { playing = false }; return }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 20.dp)) {
        Title("Remote Play")
        if (!RP.ok) Text(L.t("Native player failed to load on this device.", "تعذر تحميل المشغل على هذا الجهاز."), color = Th.bad, modifier = Modifier.padding(18.dp))
        Glass(Modifier.padding(horizontal = 18.dp).fillMaxWidth()) {
            Text(L.t("On the PS3 open Network → Remote Play before connecting.", "على الجهاز افتح الشبكة ← Remote Play قبل الاتصال."), color = Th.dim, fontSize = 12.sp)
            Spacer(Modifier.height(6.dp))
            Text(L.t("PS3: ", "الجهاز: ") + vm.host.ifBlank { "—" }, color = Th.text, fontWeight = FontWeight.Bold)
        }
        Glass(Modifier.padding(18.dp).fillMaxWidth()) {
            Text(L.t("Registration keys (from tools/ps3rp.py)", "مفاتيح التسجيل (من tools/ps3rp.py)"), color = Th.dim, fontSize = 12.sp)
            OutlinedTextField(s.id, { s.id = it }, label = { Text(L.t("Device ID (32 hex)", "رقم الجهاز (32 hex)")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(s.key, { s.key = it }, label = { Text(L.t("Key (32 hex)", "المفتاح (32 hex)")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(s.mac, { s.mac = it }, label = { Text("MAC (12 hex)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(s.nick, { s.nick = it }, label = { Text(L.t("Nickname", "الاسم")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Pill(L.t("Import ps3rp.json", "استيراد ps3rp.json"), Icons.Rounded.FileOpen, Th.accent2) { open.launch(arrayOf("*/*")) }
                Pill(L.t("Paste", "لصق"), Icons.Rounded.ContentPaste, Th.accent2) {
                    msg = if (s.import(clip.getText()?.text ?: "", vm)) L.t("Keys imported", "تم استيراد المفاتيح") else L.t("Clipboard has no ps3rp.json", "الحافظة لا تحتوي ps3rp.json")
                }
            }
        }
        Glass(Modifier.padding(horizontal = 18.dp).fillMaxWidth()) {
            Text(L.t("Quality", "الجودة"), color = Th.dim, fontSize = 12.sp)
            Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf(384000, 512000, 768000, 1024000).forEach { b -> Chip("${b / 1000}k", s.bitrate == b) { s.bitrate = b } }
            }
        }
        Spacer(Modifier.height(16.dp))
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Pill(L.t("Connect", "اتصال"), Icons.Rounded.Cast) {
                val pr = s.problem(vm.host)
                if (pr != null) msg = pr else if (!RP.ok) msg = "native" else { s.save(); msg = ""; playing = true }
            }
        }
        if (msg.isNotEmpty()) Text(msg, color = Th.warm, modifier = Modifier.padding(18.dp))
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun Player(vm: HubVM, s: RpSettings, close: () -> Unit) {
    val ctx = LocalContext.current
    val act = ctx as? Activity
    val handle = remember { RP.start(vm.host.trim(), s.id.trim(), s.key.trim(), s.mac.trim(), s.nick, s.bitrate) }
    var status by remember { mutableStateOf(L.t("Connecting…", "جارٍ الاتصال…")) }
    var state by remember { mutableIntStateOf(0) }
    var showPad by remember { mutableStateOf(true) }
    var imageView by remember { mutableStateOf<ImageView?>(null) }

    DisposableEffect(Unit) {
        vm.fullscreen = true
        act?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        act?.window?.let { w ->
            WindowCompat.setDecorFitsSystemWindows(w, false)
            WindowInsetsControllerCompat(w, w.decorView).apply { hide(WindowInsetsCompat.Type.systemBars()); systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE }
        }
        onDispose {
            vm.fullscreen = false
            if (handle != 0L) RP.stop(handle)
            act?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            act?.window?.let { w -> WindowInsetsControllerCompat(w, w.decorView).show(WindowInsetsCompat.Type.systemBars()); WindowCompat.setDecorFitsSystemWindows(w, true) }
        }
    }
    BackHandler { close() }

    // video: poll the newest decoded frame
    LaunchedEffect(handle) {
        if (handle == 0L) { status = L.t("Bad keys", "مفاتيح غير صحيحة"); return@LaunchedEffect }
        val buf = ByteBuffer.allocateDirect(1920 * 1088 * 4)
        val info = IntArray(3)
        var bmp: Bitmap? = null
        var n = 0
        while (isActive) {
            if (RP.video(handle, buf, info) == 1) {
                val w = info[0]; val h = info[1]
                if (bmp == null || bmp.width != w || bmp.height != h) bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                buf.position(0); buf.limit(w * h * 4)
                bmp!!.copyPixelsFromBuffer(buf)
                buf.clear()
                imageView?.setImageBitmap(bmp); imageView?.invalidate()
            }
            if (++n % 15 == 0) { state = RP.state(handle); status = RP.status(handle) }
            delay(12)
        }
    }
    // audio: 48 kHz stereo float
    LaunchedEffect(handle) {
        if (handle == 0L) return@LaunchedEffect
        withContext(Dispatchers.IO) {
            val frames = 960
            val min = AudioTrack.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_FLOAT)
            val t = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
                .setBufferSizeInBytes(maxOf(min, frames * 8 * 4)).setTransferMode(AudioTrack.MODE_STREAM).build()
            val pcm = FloatArray(frames * 2)
            t.play()
            try {
                while (isActive) { RP.audio(handle, pcm, frames); t.write(pcm, 0, pcm.size, AudioTrack.WRITE_BLOCKING) }
            } finally { t.stop(); t.release() }
        }
    }

    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            AndroidView({ c -> ImageView(c).apply { scaleType = ImageView.ScaleType.FIT_CENTER; imageView = this } }, Modifier.fillMaxSize())
            if (state != RP.STREAMING) Text(status, color = Th.text, modifier = Modifier.align(Alignment.Center).clip(RoundedCornerShape(14.dp)).background(Color(0xAA000000)).padding(14.dp))
            if (showPad && handle != 0L) PadOverlay(handle)
            Row(Modifier.align(Alignment.TopCenter).padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SmallBtn(if (showPad) "◎" else "◉") { showPad = !showPad }
                SmallBtn("PS") { if (handle != 0L) RP.home(handle) }
                SmallBtn("✕ " + L.t("Close", "إغلاق")) { close() }
            }
        }
    }
}

@Composable
private fun SmallBtn(t: String, f: () -> Unit) {
    Text(t, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold,
        modifier = Modifier.clip(RoundedCornerShape(14.dp)).background(Color(0x66000000)).pointerTap(f).padding(horizontal = 12.dp, vertical = 7.dp))
}

@OptIn(ExperimentalComposeUiApi::class)
private fun Modifier.pointerTap(f: () -> Unit) = this.pointerInteropFilter { e -> if (e.action == MotionEvent.ACTION_UP) f(); true }

/** hold-to-press buttons + left analog stick */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun BoxScope.PadOverlay(h: Long) {
    @Composable
    fun Btn(t: String, code: Int, size: Dp = 46.dp, mod: Modifier = Modifier) {
        var down by remember { mutableStateOf(false) }
        Box(mod.size(size).clip(CircleShape).background(if (down) Color(0x99FFFFFF) else Color(0x40FFFFFF))
            .pointerInteropFilter { e ->
                when (e.actionMasked) {
                    MotionEvent.ACTION_DOWN -> { down = true; RP.button(h, code, true) }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { down = false; RP.button(h, code, false) }
                }
                true
            }, contentAlignment = Alignment.Center) { Text(t, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 15.sp) }
    }
    // shoulders
    Row(Modifier.align(Alignment.TopStart).padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) { Btn("L2", RP.L2, 44.dp); Btn("L1", RP.L1, 44.dp) }
    Row(Modifier.align(Alignment.TopEnd).padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) { Btn("R1", RP.R1, 44.dp); Btn("R2", RP.R2, 44.dp) }
    // d-pad
    Box(Modifier.align(Alignment.CenterStart).padding(start = 18.dp).size(150.dp)) {
        Btn("▲", RP.UP, mod = Modifier.align(Alignment.TopCenter)); Btn("▼", RP.DOWN, mod = Modifier.align(Alignment.BottomCenter))
        Btn("◀", RP.LEFT, mod = Modifier.align(Alignment.CenterStart)); Btn("▶", RP.RIGHT, mod = Modifier.align(Alignment.CenterEnd))
    }
    // face
    Box(Modifier.align(Alignment.CenterEnd).padding(end = 18.dp).size(150.dp)) {
        Btn("△", RP.TRI, mod = Modifier.align(Alignment.TopCenter)); Btn("✕", RP.CRO, mod = Modifier.align(Alignment.BottomCenter))
        Btn("□", RP.SQU, mod = Modifier.align(Alignment.CenterStart)); Btn("○", RP.CIR, mod = Modifier.align(Alignment.CenterEnd))
    }
    // analog stick (left)
    val px = with(LocalDensity.current) { 100.dp.toPx() }
    var ox by remember { mutableFloatStateOf(0f) }; var oy by remember { mutableFloatStateOf(0f) }
    Box(Modifier.align(Alignment.BottomStart).padding(start = 150.dp, bottom = 14.dp).size(100.dp).clip(CircleShape).background(Color(0x30FFFFFF))
        .pointerInteropFilter { e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> { ox = (e.x / px * 2f - 1f).coerceIn(-1f, 1f); oy = (e.y / px * 2f - 1f).coerceIn(-1f, 1f) }
                else -> { ox = 0f; oy = 0f }
            }
            RP.axis(h, RP.LX, (128 + ox * 127).toInt().coerceIn(0, 255)); RP.axis(h, RP.LY, (128 + oy * 127).toInt().coerceIn(0, 255))
            true
        }, contentAlignment = Alignment.Center) {
        Box(Modifier.offset((ox * 30).dp, (oy * 30).dp).size(40.dp).clip(CircleShape).background(Color(0x80FFFFFF)))
    }
    Row(Modifier.align(Alignment.BottomCenter).padding(bottom = 14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Btn("SEL", RP.SELECT, 44.dp); Btn("L3", RP.L3, 40.dp); Btn("R3", RP.R3, 40.dp); Btn("ST", RP.START, 44.dp)
    }
}

