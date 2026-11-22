package com.cruyfford.ps3hub

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object Th {
    val bg = Color(0xFF0D0F24)
    val bg2 = Color(0xFF1A1440)
    val panel = Color(0x14FFFFFF)
    val edge = Color(0x22FFFFFF)
    val accent = Color(0xFF4F78FF)
    val accent2 = Color(0xFF8A46FF)
    val warm = Color(0xFFFF8A46)
    val ok = Color(0xFF3CDC96)
    val bad = Color(0xFFFF5A64)
    val text = Color(0xFFF0F2FF)
    val dim = Color(0xFFA0A8CD)
    val grad get() = Brush.linearGradient(listOf(accent, accent2))
}

class MainActivity : ComponentActivity() {
    private val vm: HubVM by viewModels()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { App(vm) }
    }
}

private data class Tab(val en: String, val ar: String, val icon: ImageVector)
private val tabs = listOf(
    Tab("Home", "الرئيسية", Icons.Rounded.Home), Tab("Games", "الألعاب", Icons.Rounded.SportsEsports),
    Tab("Controller", "اليد", Icons.Rounded.Gamepad), Tab("Files", "الملفات", Icons.Rounded.Folder),
    Tab("Settings", "الإعدادات", Icons.Rounded.Settings),
)

@Composable
fun App(vm: HubVM) {
    var tab by rememberSaveable { mutableIntStateOf(if (vm.configured) 0 else 4) }
    val dir = if (vm.arabic) LayoutDirection.Rtl else LayoutDirection.Ltr
    MaterialTheme(colorScheme = darkColorScheme(primary = Th.accent, secondary = Th.accent2, background = Th.bg, surface = Th.bg2, onSurface = Th.text)) {
        CompositionLocalProvider(LocalLayoutDirection provides dir) {
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Th.bg, Th.bg2))).systemBarsPadding()) {
                Column(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f).fillMaxWidth()) {
                        when (tab) {
                            0 -> HomeScreen(vm) { tab = it }
                            1 -> GamesScreen(vm)
                            2 -> PadScreen(vm)
                            3 -> FilesScreen(vm)
                            else -> SettingsScreen(vm)
                        }
                    }
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp).clip(RoundedCornerShape(24.dp)).background(Th.panel).padding(vertical = 6.dp),
                        horizontalArrangement = Arrangement.SpaceEvenly
                    ) {
                        tabs.forEachIndexed { i, t ->
                            val on = i == tab
                            Column(
                                Modifier.clip(RoundedCornerShape(16.dp)).clickable { tab = i }.padding(horizontal = 10.dp, vertical = 4.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Icon(t.icon, null, tint = if (on) Th.accent else Th.dim, modifier = Modifier.size(24.dp))
                                Text(L.t(t.en, t.ar), color = if (on) Th.text else Th.dim, fontSize = 11.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal)
                            }
                        }
                    }
                }
                AnimatedVisibility(vm.toast != null, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.align(Alignment.TopCenter).padding(top = 16.dp)) {
                    Text(vm.toast ?: "", color = Th.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clip(RoundedCornerShape(20.dp)).background(Color(0xEE2A2E5A)).padding(horizontal = 18.dp, vertical = 10.dp))
                }
            }
        }
    }
}

@Composable
fun Title(t: String, trailing: @Composable RowScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 12.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(t, color = Th.text, fontSize = 28.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.weight(1f))
        trailing()
    }
}

@Composable
fun Glass(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.clip(RoundedCornerShape(18.dp)).background(Th.panel).padding(14.dp), content = content)
}

@Composable
fun Pill(text: String, icon: ImageVector? = null, color: Color = Th.accent, onClick: () -> Unit) {
    Row(
        Modifier.clip(RoundedCornerShape(20.dp)).background(color.copy(alpha = 0.85f)).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (icon != null) { Icon(icon, null, tint = Color.White, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)) }
        Text(text, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun Chip(text: String, on: Boolean, onClick: () -> Unit) {
    Text(text, color = if (on) Color.White else Th.text, fontSize = 13.sp, fontWeight = FontWeight.Bold,
        modifier = Modifier.clip(RoundedCornerShape(16.dp)).background(if (on) Th.accent.copy(alpha = 0.85f) else Color(0x12FFFFFF)).clickable(onClick = onClick).padding(horizontal = 13.dp, vertical = 7.dp))
}

fun fmtSize(b: Long): String {
    if (b < 0) return ""
    val u = listOf("B", "KB", "MB", "GB", "TB"); var v = b.toDouble(); var i = 0
    while (v >= 1024 && i < u.size - 1) { v /= 1024; i++ }
    return if (i == 0) "$b B" else "%.1f %s".format(v, u[i])
}
