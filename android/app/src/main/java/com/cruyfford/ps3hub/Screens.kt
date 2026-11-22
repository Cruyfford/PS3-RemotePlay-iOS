package com.cruyfford.ps3hub

import android.view.HapticFeedbackConstants
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage

private fun platColor(p: Platform) = when (p) {
    Platform.PS3 -> Color(0xFF4F78FF); Platform.PS2 -> Color(0xFF3C5ADC); Platform.PS1 -> Color(0xFF9696AA)
    Platform.PSP -> Color(0xFFB45AFF); else -> Color(0xFF3CC896)
}

@Composable
fun Cover(g: Game, wm: WebMan, modifier: Modifier = Modifier) {
    val urls = remember(g.path, wm.host) { g.coverUrls(wm) }
    var idx by remember(urls) { mutableIntStateOf(0) }
    Box(modifier.clip(RoundedCornerShape(12.dp)).background(Brush.verticalGradient(listOf(platColor(g.platform), Color(0xFF141232))))) {
        Text(g.title, color = Th.text, fontSize = 11.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center, maxLines = 3,
            modifier = Modifier.align(Alignment.Center).padding(8.dp))
        if (idx < urls.size) AsyncImage(model = urls[idx], contentDescription = g.title, contentScale = ContentScale.Crop,
            modifier = Modifier.matchParentSize(), onError = { idx++ })
        Text(g.platform.label, color = Color.White, fontSize = 9.sp, fontWeight = FontWeight.Bold,
            modifier = Modifier.align(Alignment.TopEnd).padding(5.dp).clip(RoundedCornerShape(7.dp)).background(platColor(g.platform)).padding(horizontal = 6.dp, vertical = 2.dp))
    }
}

// ============================================================ home
@Composable
fun HomeScreen(vm: HubVM, goTab: (Int) -> Unit) {
    LaunchedEffect(vm.host) { if (vm.configured && vm.games.isEmpty()) vm.loadGames() }
    val wm = vm.client
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Title("PS3 Hub")
        if (!vm.configured) {
            Glass(Modifier.padding(18.dp).fillMaxWidth()) {
                Text(L.t("Enter your PS3's IP address to start.", "أدخل عنوان IP لجهازك للبدء."), color = Th.text)
                Spacer(Modifier.height(10.dp)); Pill(L.t("Open settings", "افتح الإعدادات"), Icons.Rounded.Settings) { goTab(5) }
            }
            return@Column
        }
        Glass(Modifier.padding(horizontal = 18.dp).fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(10.dp).clip(CircleShape).background(when (vm.online) { true -> Th.ok; false -> Th.bad; null -> Th.dim }))
                Spacer(Modifier.width(8.dp))
                Text(when (vm.online) { true -> L.t("Connected", "متصل"); false -> L.t("Offline", "غير متصل"); null -> "…" } + "  ·  " + vm.host, color = Th.text, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Stat("CPU", vm.status.cpu?.let { "$it°" } ?: "—", Modifier.weight(1f))
                Stat("RSX", vm.status.rsx?.let { "$it°" } ?: "—", Modifier.weight(1f))
                Stat(L.t("Fan", "المروحة"), vm.status.fan?.let { "$it%" } ?: "—", Modifier.weight(1f))
            }
            vm.status.firmware?.let { Spacer(Modifier.height(8.dp)); Text(it, color = Th.dim, fontSize = 12.sp) }
        }
        val recent = vm.recents.mapNotNull { vm.game(it) }
        if (recent.isNotEmpty()) {
            Text(L.t("Recently played", "لعبت مؤخراً"), color = Th.text, fontWeight = FontWeight.Bold, fontSize = 17.sp, modifier = Modifier.padding(start = 18.dp, top = 18.dp, bottom = 8.dp))
            LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                items(recent, key = { it.path }) { g -> Cover(g, wm, Modifier.width(110.dp).height(150.dp).clickable { vm.play(g) }) }
            }
        }
        Text(L.t("Quick actions", "اختصارات"), color = Th.text, fontWeight = FontWeight.Bold, fontSize = 17.sp, modifier = Modifier.padding(start = 18.dp, top = 18.dp, bottom = 8.dp))
        val acts = listOf(
            Triple(L.t("Quit game", "إغلاق اللعبة"), Icons.Rounded.ExitToApp) { vm.run(L.t("Back to XMB", "رجوع للـ XMB")) { wm.quitGame() } },
            Triple(L.t("Unmount", "إلغاء التحميل"), Icons.Rounded.Eject) { vm.run(L.t("Unmounted", "تم إلغاء التحميل")) { wm.unmount() } },
            Triple(L.t("Eject disc", "إخراج القرص"), Icons.Rounded.Album) { vm.run(L.t("Ejected", "تم الإخراج")) { wm.eject() } },
            Triple(L.t("Rescan games", "تحديث الألعاب"), Icons.Rounded.Refresh) { vm.loadGames(true) },
            Triple(L.t("Screenshot", "لقطة شاشة"), Icons.Rounded.PhotoCamera) { vm.run(L.t("Screenshot saved on the PS3", "حُفظت اللقطة على الجهاز")) { wm.screenshot() } },
            Triple(L.t("Restart", "إعادة تشغيل"), Icons.Rounded.RestartAlt) { vm.run(L.t("Restarting", "جارٍ إعادة التشغيل")) { wm.restart() } },
            Triple(L.t("Turn off", "إطفاء"), Icons.Rounded.PowerSettingsNew) { vm.run(L.t("Turning off", "جارٍ الإطفاء")) { wm.shutdown() } },
        )
        Column(Modifier.padding(horizontal = 18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            acts.chunked(2).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    row.forEach { (t, ic, f) ->
                        Row(Modifier.weight(1f).clip(RoundedCornerShape(16.dp)).background(Th.panel).clickable { f() }.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(ic, null, tint = if (ic == Icons.Rounded.PowerSettingsNew) Th.bad else Th.accent)
                            Spacer(Modifier.width(10.dp)); Text(t, color = Th.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
        Spacer(Modifier.height(20.dp))
    }
}

@Composable
private fun Stat(label: String, v: String, modifier: Modifier) {
    Column(modifier.clip(RoundedCornerShape(14.dp)).background(Color(0x10FFFFFF)).padding(12.dp)) {
        Text(label, color = Th.dim, fontSize = 12.sp)
        Text(v, color = Th.text, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold)
    }
}

// ============================================================ games
@Composable
fun GamesScreen(vm: HubVM) {
    var q by remember { mutableStateOf("") }
    var plat by remember { mutableStateOf<Platform?>(null) }
    var favOnly by remember { mutableStateOf(false) }
    var picked by remember { mutableStateOf<Game?>(null) }
    LaunchedEffect(Unit) { if (vm.games.isEmpty()) vm.loadGames() }
    val wm = vm.client
    val list = vm.games.filter { (plat == null || it.platform == plat) && (!favOnly || it.path in vm.favorites) && (q.isBlank() || it.title.contains(q, true)) }
    Column(Modifier.fillMaxSize()) {
        Title(L.t("Games", "الألعاب")) {
            if (vm.loading) CircularProgressIndicator(Modifier.size(22.dp), color = Th.text, strokeWidth = 2.dp)
            else IconButton(onClick = { vm.loadGames(true) }) { Icon(Icons.Rounded.Refresh, null, tint = Th.text) }
        }
        OutlinedTextField(q, { q = it }, placeholder = { Text(L.t("Search", "بحث")) }, singleLine = true, leadingIcon = { Icon(Icons.Rounded.Search, null) },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp), shape = RoundedCornerShape(16.dp))
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 18.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip(L.t("All", "الكل"), plat == null && !favOnly) { plat = null; favOnly = false }
            Chip("★", favOnly) { favOnly = !favOnly }
            Platform.values().filter { p -> vm.games.any { it.platform == p } }.forEach { p -> Chip(p.label, plat == p) { plat = if (plat == p) null else p } }
        }
        if (list.isEmpty()) Text(if (vm.loading) L.t("Loading…", "جارٍ التحميل…") else L.t("No games found", "لا توجد ألعاب"), color = Th.dim, modifier = Modifier.padding(24.dp))
        LazyVerticalGrid(GridCells.Adaptive(108.dp), contentPadding = PaddingValues(18.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            items(list, key = { it.path }) { g ->
                Column(Modifier.clickable { picked = g }) {
                    Box { Cover(g, wm, Modifier.fillMaxWidth().aspectRatio(0.72f)); if (g.path in vm.favorites) Icon(Icons.Rounded.Star, null, tint = Color(0xFFFFC83C), modifier = Modifier.align(Alignment.TopStart).padding(4.dp).size(18.dp)) }
                    Text(g.title, color = Th.text, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 5.dp))
                }
            }
        }
    }
    picked?.let { g ->
        AlertDialog(onDismissRequest = { picked = null }, containerColor = Th.bg2,
            title = { Text(g.title, color = Th.text) },
            text = { Column { Text("${g.platform.label} · ${g.device}", color = Th.dim); g.titleId?.let { Text(it, color = Th.dim) }; Text(g.path, color = Th.dim, fontSize = 11.sp, fontFamily = FontFamily.Monospace) } },
            confirmButton = { Pill(L.t("Play", "تشغيل"), Icons.Rounded.PlayArrow) { vm.play(g); picked = null } },
            dismissButton = {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Pill(L.t("Mount", "تحميل"), Icons.Rounded.Album, Th.accent2) { vm.run(L.t("Mounted", "تم التحميل")) { wm.mount(g) }; picked = null }
                    Pill(if (g.path in vm.favorites) "★" else "☆", null, Th.warm) { vm.toggleFav(g) }
                }
            })
    }
}

// ============================================================ controller
@Composable
fun PadScreen(vm: HubVM) {
    val view = LocalView.current
    val wm = vm.client
    fun send(b: String) { view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY); vm.pad(b) }
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
        Column(Modifier.fillMaxSize()) {
            Title(L.t("Controller", "اليد"))
            if (!vm.configured) { Text(L.t("Set the PS3 address in Settings first.", "أدخل عنوان الجهاز في الإعدادات أولاً."), color = Th.dim, modifier = Modifier.padding(24.dp)); return@Column }
            Spacer(Modifier.height(8.dp))
            Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { Shoulder("L2") { send("l2") }; Shoulder("L1") { send("l1") } }
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { Shoulder("R2") { send("r2") }; Shoulder("R1") { send("r1") } }
            }
            Spacer(Modifier.height(24.dp))
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Cross(150.dp, listOf("up" to Icons.Rounded.KeyboardArrowUp, "left" to Icons.Rounded.KeyboardArrowLeft, "right" to Icons.Rounded.KeyboardArrowRight, "down" to Icons.Rounded.KeyboardArrowDown)) { send(it) }
                Face(160.dp) { send(it) }
            }
            Spacer(Modifier.height(28.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Small("SELECT") { send("select") }
                Spacer(Modifier.width(18.dp))
                Box(Modifier.size(60.dp).clip(CircleShape).background(Th.grad).clickable { send("psbtn") }, contentAlignment = Alignment.Center) { Text("PS", color = Color.White, fontWeight = FontWeight.ExtraBold, fontSize = 18.sp) }
                Spacer(Modifier.width(18.dp))
                Small("START") { send("start") }
            }
            Spacer(Modifier.height(16.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterHorizontally)) {
                Small("L3") { send("l3") }; Small(L.t("Back", "رجوع")) { send("cancel") }; Small(L.t("OK", "موافق")) { send("accept") }; Small("R3") { send("r3") }
            }
        }
    }
}

@Composable private fun Shoulder(t: String, f: () -> Unit) =
    Text(t, color = Th.text, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center,
        modifier = Modifier.width(96.dp).clip(RoundedCornerShape(14.dp)).background(Th.panel).clickable(onClick = f).padding(vertical = 10.dp))

@Composable private fun Small(t: String, f: () -> Unit) =
    Text(t, color = Th.text, fontSize = 12.sp, fontWeight = FontWeight.Bold,
        modifier = Modifier.clip(RoundedCornerShape(14.dp)).background(Th.panel).clickable(onClick = f).padding(horizontal = 14.dp, vertical = 9.dp))

@Composable
private fun Cross(size: androidx.compose.ui.unit.Dp, keys: List<Pair<String, ImageVector>>, f: (String) -> Unit) {
    val b = size / 3
    Box(Modifier.size(size)) {
        val pos = listOf(Alignment.TopCenter, Alignment.CenterStart, Alignment.CenterEnd, Alignment.BottomCenter)
        keys.forEachIndexed { i, (k, ic) ->
            Box(Modifier.align(pos[i]).size(b).clip(RoundedCornerShape(12.dp)).background(Th.panel).clickable { f(k) }, contentAlignment = Alignment.Center) { Icon(ic, null, tint = Th.text, modifier = Modifier.size(30.dp)) }
        }
    }
}

@Composable
private fun Face(size: androidx.compose.ui.unit.Dp, f: (String) -> Unit) {
    val b = size / 3
    Box(Modifier.size(size)) {
        listOf(Triple("triangle", "△", Alignment.TopCenter) to Color(0xFF3CDC96), Triple("square", "□", Alignment.CenterStart) to Color(0xFFE66EC8),
            Triple("circle", "○", Alignment.CenterEnd) to Color(0xFFFF5A64), Triple("cross", "✕", Alignment.BottomCenter) to Color(0xFF6E9BFF)).forEach { (t, c) ->
            Box(Modifier.align(t.third).size(b).clip(CircleShape).background(Th.panel).clickable { f(t.first) }, contentAlignment = Alignment.Center) {
                Text(t.second, color = c, fontSize = 24.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

// ============================================================ files
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FilesScreen(vm: HubVM) {
    var newFolder by remember { mutableStateOf(false) }
    var renameE by remember { mutableStateOf<Entry?>(null) }
    var menuE by remember { mutableStateOf<Entry?>(null) }
    var pendingDl by remember { mutableStateOf<Entry?>(null) }
    var text by remember { mutableStateOf("") }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { if (it.isNotEmpty()) vm.upload(it) }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { u -> val e = pendingDl; if (u != null && e != null) vm.download(e, u); pendingDl = null }
    LaunchedEffect(vm.host) { if (vm.configured && vm.entries.isEmpty()) vm.load("/dev_hdd0") }

    val shortcuts = if (vm.fm != null) vm.volumes.map { it.label to it.root } + ("packages" to "/dev_hdd0/packages")
    else listOf("HDD" to "/dev_hdd0", "USB 0" to "/dev_usb000", "USB 1" to "/dev_usb001", "packages" to "/dev_hdd0/packages", "GAMES" to "/dev_hdd0/GAMES", "PS3ISO" to "/dev_hdd0/PS3ISO", "game" to "/dev_hdd0/game")

    Column(Modifier.fillMaxSize()) {
        Title(L.t("Files", "الملفات")) {
            IconButton(onClick = { pick.launch(arrayOf("*/*")) }) { Icon(Icons.Rounded.Upload, null, tint = Th.text) }
            IconButton(onClick = { text = ""; newFolder = true }) { Icon(Icons.Rounded.CreateNewFolder, null, tint = Th.text) }
            IconButton(onClick = { vm.load() }) { Icon(Icons.Rounded.Refresh, null, tint = Th.text) }
        }
        if (vm.fm != null) Row(Modifier.padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Link, null, tint = Th.accent2, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(6.dp))
            Text(L.t("Connected to File Manager — all drives (NTFS / exFAT too)", "متصل بـ File Manager — كل الأقراص (NTFS و exFAT أيضاً)"), color = Th.dim, fontSize = 12.sp, maxLines = 1)
        }
        vm.psTask?.let { t ->
            Glass(Modifier.padding(horizontal = 18.dp, vertical = 6.dp).fillMaxWidth()) {
                Text((if (t.task == "install") L.t("PS3 installing: ", "الجهاز يثبّت: ") else L.t("PS3 copying: ", "الجهاز ينسخ: ")) + t.name, color = Th.text, fontSize = 13.sp, maxLines = 1)
                LinearProgressIndicator(progress = { if (t.total > 0) t.done.toFloat() / t.total else 0f }, modifier = Modifier.fillMaxWidth().padding(top = 6.dp), color = Th.accent)
                if (t.queue > 0) Text(L.t("${t.queue} waiting", "${t.queue} بالانتظار"), color = Th.dim, fontSize = 11.sp)
            }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 18.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            shortcuts.forEach { (l, p) -> Chip(l, vm.path.startsWith(p)) { vm.load(p) } }
        }
        Row(Modifier.padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
            vm.parent?.let { up -> IconButton(onClick = { vm.load(up) }) { Icon(Icons.Rounded.ArrowBack, null, tint = Th.text) } }
            Text(vm.path, color = Th.dim, fontSize = 12.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            if (vm.filesBusy) CircularProgressIndicator(Modifier.size(18.dp), color = Th.text, strokeWidth = 2.dp)
        }
        vm.transfer?.let { (n, d, t) ->
            Glass(Modifier.padding(horizontal = 18.dp, vertical = 6.dp).fillMaxWidth()) {
                Text(n, color = Th.text, fontSize = 13.sp, maxLines = 1)
                LinearProgressIndicator(progress = { if (t > 0) d.toFloat() / t else 0f }, modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp), color = Th.accent2)
                Text(fmtSize(d) + if (t > 0) " / " + fmtSize(t) else "", color = Th.dim, fontSize = 11.sp)
            }
        }
        val err = vm.filesError
        if (err != null) {
            Glass(Modifier.padding(18.dp).fillMaxWidth()) {
                Icon(Icons.Rounded.WifiOff, null, tint = Th.warm)
                Text(err, color = Th.text)
                Text(L.t("Open File Manager on the PS3 and turn on FTP in its settings (also enables the phone link), or use webMAN's FTP on port 21.",
                    "افتح File Manager على الجهاز وشغّل FTP من إعداداته (يشغّل الربط مع الجوال أيضاً)، أو استخدم FTP الخاص بـ webMAN على المنفذ 21."), color = Th.dim, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp)); Pill(L.t("Retry", "إعادة المحاولة"), Icons.Rounded.Refresh) { vm.load() }
            }
        } else LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)) {
            items(vm.entries, key = { it.name }) { e ->
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).combinedClickable(
                    onClick = { if (e.dir) vm.load(vm.join(e.name)) else { pendingDl = e; save.launch(e.name) } },
                    onLongClick = { menuE = e }).padding(horizontal = 6.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    val n = e.name.lowercase()
                    val ic = when { e.dir -> Icons.Rounded.Folder; n.endsWith(".pkg") -> Icons.Rounded.Inventory2; n.endsWith(".iso") || n.endsWith(".bin") -> Icons.Rounded.Album
                        n.endsWith(".mp4") || n.endsWith(".mkv") || n.endsWith(".avi") -> Icons.Rounded.Movie; n.endsWith(".png") || n.endsWith(".jpg") -> Icons.Rounded.Image; else -> Icons.Rounded.Description }
                    Box(Modifier.size(38.dp).clip(RoundedCornerShape(10.dp)).background(Color(0x10FFFFFF)), contentAlignment = Alignment.Center) { Icon(ic, null, tint = if (e.dir) Th.accent else Th.accent2) }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(e.name, color = Th.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (!e.dir) Text(fmtSize(e.size), color = Th.dim, fontSize = 11.sp)
                    }
                    if (n.endsWith(".pkg")) Pill(L.t("Install", "تثبيت"), null, Th.accent2) { vm.install(e) }
                }
            }
        }
    }
    menuE?.let { e ->
        AlertDialog(onDismissRequest = { menuE = null }, containerColor = Th.bg2, title = { Text(e.name, color = Th.text) },
            confirmButton = { Pill(L.t("Rename", "تسمية"), Icons.Rounded.Edit) { text = e.name; renameE = e; menuE = null } },
            dismissButton = { Pill(L.t("Delete", "حذف"), Icons.Rounded.Delete, Th.bad) { val p = vm.join(e.name); vm.fsOp(L.t("Deleted", "تم الحذف")) { it.delete(p, e.dir) }; menuE = null } })
    }
    if (newFolder) NameDialog(L.t("New folder", "مجلد جديد"), text, { text = it }, { newFolder = false }) { val p = vm.join(text); vm.fsOp(L.t("Created", "تم الإنشاء")) { it.mkdir(p) }; newFolder = false }
    renameE?.let { e -> NameDialog(L.t("Rename", "إعادة تسمية"), text, { text = it }, { renameE = null }) { val a = vm.join(e.name); val b = vm.join(text); vm.fsOp(L.t("Renamed", "تمت إعادة التسمية")) { it.rename(a, b) }; renameE = null } }
}

@Composable
private fun NameDialog(title: String, v: String, set: (String) -> Unit, dismiss: () -> Unit, ok: () -> Unit) {
    AlertDialog(onDismissRequest = dismiss, containerColor = Th.bg2, title = { Text(title, color = Th.text) },
        text = { OutlinedTextField(v, set, singleLine = true) },
        confirmButton = { Pill(L.t("OK", "موافق")) { if (v.isNotBlank() && '/' !in v) ok() } },
        dismissButton = { TextButton(onClick = dismiss) { Text(L.t("Cancel", "إلغاء")) } })
}

// ============================================================ settings
@Composable
fun SettingsScreen(vm: HubVM) {
    var host by remember { mutableStateOf(vm.host) }
    var http by remember { mutableStateOf(vm.httpPort.toString()) }
    var ftp by remember { mutableStateOf(vm.ftpPort.toString()) }
    var pwd by remember { mutableStateOf(vm.password) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 20.dp)) {
        Title(L.t("Settings", "الإعدادات"))
        Glass(Modifier.padding(horizontal = 18.dp).fillMaxWidth()) {
            Text(L.t("PS3", "الجهاز"), color = Th.dim, fontSize = 12.sp)
            OutlinedTextField(host, { host = it }, label = { Text(L.t("IP address", "عنوان IP")) }, placeholder = { Text("192.168.1.20") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth())
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(http, { http = it.filter(Char::isDigit) }, label = { Text("webMAN HTTP") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.weight(1f))
                OutlinedTextField(ftp, { ftp = it.filter(Char::isDigit) }, label = { Text("FTP") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.weight(1f))
            }
            OutlinedTextField(pwd, { pwd = it }, label = { Text(L.t("webMAN password (optional)", "كلمة مرور webMAN (اختياري)")) }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Pill(L.t("Save", "حفظ"), Icons.Rounded.Check) {
                    vm.host = host.trim(); vm.httpPort = http.toIntOrNull() ?: 80; vm.ftpPort = ftp.toIntOrNull() ?: 21; vm.password = pwd
                    vm.saveSettings(); vm.show(L.t("Saved", "تم الحفظ")); vm.loadGames()
                }
                Pill(L.t("Test", "اختبار"), Icons.Rounded.NetworkCheck, Th.accent2) {
                    val c = WebMan(host.trim(), http.toIntOrNull() ?: 80, pwd)
                    vm.run(L.t("webMAN is reachable", "webMAN يعمل")) { if (!c.ping()) throw Exception(L.t("no answer", "لا يوجد رد")) }
                }
            }
        }
        Glass(Modifier.padding(18.dp).fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(L.t("Arabic interface", "الواجهة بالعربية"), color = Th.text, modifier = Modifier.weight(1f))
                Switch(vm.arabic, { vm.arabic = it; vm.saveSettings() })
            }
        }
        Glass(Modifier.padding(horizontal = 18.dp).fillMaxWidth()) {
            Text("PS3 Hub 0.3.0 · CRUYFFORD", color = Th.text, fontWeight = FontWeight.Bold)
            Text(L.t("Needs webMAN MOD on the PS3. The Files tab also works with File Manager's phone link (port 8080).",
                "يحتاج webMAN MOD على الجهاز. تبويب الملفات يعمل أيضاً مع ربط File Manager (المنفذ 8080)."), color = Th.dim, fontSize = 12.sp)
        }
    }
}
