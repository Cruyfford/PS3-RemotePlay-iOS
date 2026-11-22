package com.cruyfford.ps3hub

import android.app.Application
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

class HubVM(app: Application) : AndroidViewModel(app) {
    private val p = app.getSharedPreferences("hub", Context.MODE_PRIVATE)

    var host by mutableStateOf(p.getString("host", "") ?: "")
    var httpPort by mutableStateOf(p.getInt("http", 80))
    var ftpPort by mutableStateOf(p.getInt("ftp", 21))
    var password by mutableStateOf(p.getString("pwd", "") ?: "")
    var arabic by mutableStateOf(p.getBoolean("arabic", true))

    var games by mutableStateOf<List<Game>>(emptyList())
    val favorites = mutableStateListOf<String>().apply { addAll(p.getStringSet("favs", emptySet()) ?: emptySet()) }
    var recents by mutableStateOf<List<String>>(p.getString("recents", "")!!.split('\n').filter { it.isNotEmpty() })
    var online by mutableStateOf<Boolean?>(null)
    var status by mutableStateOf(WebMan.Status())
    var loading by mutableStateOf(false)
    var toast by mutableStateOf<String?>(null)

    val client get() = WebMan(host.trim(), httpPort, password)
    val configured get() = host.isNotBlank()

    init {
        L.arabic = arabic
        p.getString("games", null)?.let { s ->
            runCatching {
                val a = JSONArray(s)
                games = (0 until a.length()).map { val o = a.getJSONObject(it); Game(o.getString("t"), o.getString("p"), o.optString("i").ifEmpty { null }, o.optString("id").ifEmpty { null }, Platform.valueOf(o.getString("pl"))) }
            }
        }
        startPolling()
    }

    fun saveSettings() {
        p.edit().putString("host", host.trim()).putInt("http", httpPort).putInt("ftp", ftpPort).putString("pwd", password).putBoolean("arabic", arabic).apply()
        L.arabic = arabic
        fs?.close(); fs = null; fsHost = ""
    }

    fun show(m: String) {
        toast = m
        viewModelScope.launch { delay(2400); if (toast == m) toast = null }
    }

    private var poller: Job? = null
    fun startPolling() {
        poller?.cancel()
        poller = viewModelScope.launch {
            while (isActive) {
                if (configured) {
                    val c = client
                    val st = withContext(Dispatchers.IO) { runCatching { c.status() }.getOrNull() }
                    online = st != null
                    if (st != null) status = st
                }
                delay(5000)
            }
        }
    }

    fun loadGames(rescan: Boolean = false) {
        if (!configured || loading) return
        loading = true
        val c = client
        viewModelScope.launch {
            val r = withContext(Dispatchers.IO) { runCatching { if (rescan) c.refreshGames(); c.games() } }
            loading = false
            r.onSuccess { l ->
                games = l.sortedBy { it.title.lowercase() }
                val a = JSONArray()
                games.forEach { a.put(JSONObject().put("t", it.title).put("p", it.path).put("i", it.icon ?: "").put("id", it.titleId ?: "").put("pl", it.platform.name)) }
                p.edit().putString("games", a.toString()).apply()
            }.onFailure { show(L.t("Couldn't reach webMAN", "تعذر الوصول إلى webMAN")) }
        }
    }

    fun run(label: String, op: suspend () -> Unit) {
        viewModelScope.launch {
            val r = withContext(Dispatchers.IO) { runCatching { op() } }
            show(if (r.isSuccess) label else L.t("Failed: ", "فشل: ") + (r.exceptionOrNull()?.message ?: ""))
        }
    }

    fun play(g: Game) {
        recents = (listOf(g.path) + recents.filter { it != g.path }).take(12)
        p.edit().putString("recents", recents.joinToString("\n")).apply()
        val c = client
        run(L.t("Starting ", "جارٍ تشغيل ") + g.title) { c.play(g) }
    }

    fun pad(b: String) { val c = client; viewModelScope.launch(Dispatchers.IO) { c.pad(b) } }

    fun toggleFav(g: Game) {
        if (!favorites.remove(g.path)) favorites.add(g.path)
        p.edit().putStringSet("favs", favorites.toSet()).apply()
    }

    fun game(path: String) = games.firstOrNull { it.path == path }

    // ---------------------------------------------------------------- files
    var fs: RemoteFs? = null
    private var fsHost = ""
    var fm by mutableStateOf<FmClient?>(null)
    var volumes by mutableStateOf<List<Volume>>(emptyList())
    var path by mutableStateOf("/dev_hdd0")
    var entries by mutableStateOf<List<Entry>>(emptyList())
    var filesBusy by mutableStateOf(false)
    var filesError by mutableStateOf<String?>(null)
    var transfer by mutableStateOf<Triple<String, Long, Long>?>(null)
    var psTask by mutableStateOf<PsTask?>(null)
    private var taskPoll: Job? = null

    private fun connectFs(): RemoteFs {
        val h = host.trim()
        fs?.let { if (fsHost == h) return it }
        fsHost = h
        if (FmClient.probe(h)) {
            val c = FmClient(h)
            fm = c
            volumes = runCatching { c.volumes() }.getOrDefault(emptyList())
            taskPoll?.cancel()
            taskPoll = viewModelScope.launch {
                while (isActive) { psTask = withContext(Dispatchers.IO) { runCatching { c.status() }.getOrNull() }; delay(2000) }
            }
            fs = c
        } else {
            fm = null; volumes = emptyList()
            fs = FtpFs(h, ftpPort)
        }
        return fs!!
    }

    fun load(target: String = path) {
        if (!configured) return
        filesBusy = true; filesError = null
        viewModelScope.launch {
            val r = withContext(Dispatchers.IO) {
                runCatching { connectFs().list(target) }.recoverCatching { fs?.close(); fs = null; fsHost = ""; connectFs().list(target) }
            }
            filesBusy = false
            r.onSuccess { entries = it; path = target }.onFailure { filesError = it.message ?: "error" }
        }
    }

    fun join(name: String) = if (path.endsWith("/")) path + name else "$path/$name"

    val parent: String?
        get() {
            if (path == "/") return null
            if (fm != null && volumes.any { it.root == path || it.root == "$path/" }) return null
            var x = path.trimEnd('/')
            val i = x.lastIndexOf('/'); if (i < 0) return null
            x = x.substring(0, i)
            if (x.endsWith(":")) x += "/"
            return x.ifEmpty { "/" }
        }

    fun fsOp(label: String, op: (RemoteFs) -> Unit) {
        viewModelScope.launch {
            val r = withContext(Dispatchers.IO) { runCatching { op(connectFs()) } }
            show(if (r.isSuccess) label else L.t("Failed: ", "فشل: ") + (r.exceptionOrNull()?.message ?: ""))
            load()
        }
    }

    fun install(e: Entry) {
        val pth = join(e.name)
        val f = fm
        if (f != null) run(L.t("Installing on the PS3", "جارٍ التثبيت على الجهاز")) { f.install(pth) }
        else { val c = client; run(L.t("Installing on the PS3", "جارٍ التثبيت على الجهاز")) { c.installPath(pth) } }
    }

    fun download(e: Entry, dest: Uri) {
        val cr = getApplication<Application>().contentResolver
        val remote = join(e.name)
        transfer = Triple(e.name, 0L, e.size)
        viewModelScope.launch {
            val r = withContext(Dispatchers.IO) {
                runCatching {
                    cr.openOutputStream(dest)!!.use { out -> connectFs().download(remote, out) { n -> transfer = Triple(e.name, n, e.size) } }
                }
            }
            transfer = null
            show(if (r.isSuccess) L.t("Saved", "تم الحفظ") else L.t("Download failed", "فشل التحميل"))
        }
    }

    fun upload(uris: List<Uri>) {
        val cr = getApplication<Application>().contentResolver
        viewModelScope.launch {
            for (u in uris) {
                var name = "file"; var size = -1L
                cr.query(u, null, null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME); if (ni >= 0) name = c.getString(ni) ?: name
                        val si = c.getColumnIndex(OpenableColumns.SIZE); if (si >= 0) size = c.getLong(si)
                    }
                }
                val isPkg = name.lowercase().endsWith(".pkg")
                val dir = if (fm == null && isPkg && !path.startsWith("/dev_hdd0/packages")) "/dev_hdd0/packages" else path
                val remote = if (dir.endsWith("/")) dir + name else "$dir/$name"
                transfer = Triple(name, 0L, size)
                val r = withContext(Dispatchers.IO) {
                    runCatching { cr.openInputStream(u)!!.use { ins -> connectFs().upload(ins, size, remote) { n -> transfer = Triple(name, n, size) } } }
                }
                transfer = null
                if (r.isSuccess && isPkg && fm != null) {
                    val f = fm!!
                    withContext(Dispatchers.IO) { runCatching { f.install(remote) } }
                    show(L.t("PKG sent — installing on the PS3", "أُرسل الـ PKG — جارٍ التثبيت على الجهاز"))
                } else show(if (r.isSuccess) L.t("Uploaded", "تم الرفع") else L.t("Upload failed: ", "فشل الرفع: ") + (r.exceptionOrNull()?.message ?: ""))
            }
            load()
        }
    }
}
