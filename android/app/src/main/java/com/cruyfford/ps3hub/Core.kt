package com.cruyfford.ps3hub

import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/** Arabic / English strings */
object L {
    @Volatile var arabic = true
    fun t(en: String, ar: String) = if (arabic) ar else en
}

val http: OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(6, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    .build()

enum class Platform(val label: String) {
    PS3("PS3"), PS2("PS2"), PS1("PS1"), PSP("PSP"), RETRO("Retro"), VIDEO("Video"), OTHER("Other");

    companion object {
        fun from(path: String): Platform {
            val p = path.uppercase()
            return when {
                "/PS3ISO" in p || "/GAMES/" in p || "/GAMEZ/" in p || "PS3_GAME" in p -> PS3
                "/PS2ISO" in p || "/PS2DISC" in p -> PS2
                "/PSXISO" in p || "/PSXGAMES" in p -> PS1
                "/PSPISO" in p || "/ISO/" in p -> PSP
                "/ROMS" in p -> RETRO
                "/BDISO" in p || "/DVDISO" in p || "/VIDEO" in p -> VIDEO
                else -> OTHER
            }
        }
    }
}

data class Game(val title: String, val path: String, val icon: String?, val titleId: String?, val platform: Platform) {
    val device: String
        get() {
            val d = path.trimStart('/').substringBefore('/')
            return when {
                d.startsWith("dev_hdd") -> "HDD"
                d.startsWith("dev_usb") -> "USB " + d.removePrefix("dev_usb")
                d.startsWith("ntfs") || d.startsWith("dev_ntfs") -> "NTFS"
                d.startsWith("net") -> "NET"
                else -> d
            }
        }

    /** online box art first, the XMB icon from webMAN as last resort */
    fun coverUrls(wm: WebMan): List<String> {
        val out = mutableListOf<String>()
        val id = titleId
        if (id != null) when (platform) {
            Platform.PS3 -> if (!id.contains("-")) listOf("US", "EN", "JA", "FR", "DE").forEach { out += "https://art.gametdb.com/ps3/coverM/$it/$id.jpg" }
            Platform.PS2 -> if (id.contains("-")) out += "https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/$id.jpg"
            Platform.PS1 -> if (id.contains("-")) out += "https://raw.githubusercontent.com/xlenore/psx-covers/main/covers/default/$id.jpg"
            else -> {}
        }
        icon?.let { out += wm.url(it) }
        return out
    }
}

object GameParser {
    private fun entities(s: String) = s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'").replace("&apos;", "'")

    fun decodePath(s: String): String {
        var p = try { URLDecoder.decode(s.replace("+", "%2B"), "UTF-8") } catch (e: Exception) { s }
        p = p.substringBefore('?')
        return entities(p)
    }

    private fun stripExt(n: String): String {
        for (e in listOf(".iso", ".bin", ".cue", ".img", ".mdf", ".zip", ".7z", ".iso.0")) if (n.lowercase().endsWith(e)) return n.dropLast(e.length)
        return n
    }

    fun cleanTitle(t: String): String {
        var s = stripExt(t)
        val r = Regex("\\s*[\\[(][^\\])]*[\\])]\\s*$")
        while (r.containsMatchIn(s)) s = s.replace(r, "")
        return s.trim().ifEmpty { t }
    }

    fun findId(s: String): String? {
        val u = s.uppercase()
        Regex("[A-Z]{4}[0-9]{5}").find(u)?.let { return it.value }
        Regex("[A-Z]{4}[-_][0-9]{3}\\.?[0-9]{2}").find(u)?.let { return it.value.replace("_", "-").replace(".", "") }
        return null
    }

    fun parseXml(s: String): List<Game> {
        val out = mutableListOf<Game>()
        val seen = HashSet<String>()
        var i = 0
        while (true) {
            val a = s.indexOf("<T key=", i); if (a < 0) break
            val b = s.indexOf("</T>", a); if (b < 0) break
            val item = s.substring(a, b); i = b + 4
            val pairs = HashMap<String, String>()
            var j = 0
            while (true) {
                val k = item.indexOf("<P key=\"", j); if (k < 0) break
                val ke = item.indexOf('"', k + 8); if (ke < 0) break
                val vs = item.indexOf("<>", ke); val ve = if (vs >= 0) item.indexOf("</>", vs) else -1
                if (vs < 0 || ve < 0) break
                pairs[item.substring(k + 8, ke)] = item.substring(vs + 2, ve)
                j = ve + 3
            }
            val action = pairs["module_action"] ?: continue
            val m = action.indexOf("/mount_ps3"); if (m < 0) continue
            val path = decodePath(action.substring(m + 10))
            if (path.isEmpty() || path == "/unmount" || !seen.add(path)) continue
            val title = entities(pairs["title"] ?: path.substringAfterLast('/'))
            out += Game(cleanTitle(title), path, pairs["icon"], findId((pairs["info"] ?: "") + " " + path + " " + title), Platform.from(path))
        }
        return out
    }

    fun parseIndex(s: String): List<Game> {
        val out = mutableListOf<Game>()
        val seen = HashSet<String>()
        var i = 0
        while (true) {
            val r = s.indexOf("href=\"/mount.ps3", i); if (r < 0) break
            val e = s.indexOf('"', r + 16); if (e < 0) break
            val path = decodePath(s.substring(r + 16, e)); i = e
            if (path.isEmpty() || path.startsWith("/unmount") || !seen.add(path)) continue
            val win = s.substring(e, minOf(s.length, e + 600))
            val src = win.indexOf("src=\"")
            val icon = if (src >= 0) win.indexOf('"', src + 5).let { if (it > 0) decodePath(win.substring(src + 5, it)) else null } else null
            val name = path.substringAfterLast('/')
            out += Game(cleanTitle(name), path, icon, findId(path), Platform.from(path))
        }
        return out
    }
}

/** webMAN MOD web commands */
class WebMan(val host: String, val port: Int, val password: String) {
    private val base get() = if (port == 80) "http://$host" else "http://$host:$port"

    fun url(path: String): String {
        val sb = StringBuilder()
        for (ch in path) {
            if (ch.isLetterOrDigit() && ch.code < 128 || ch in "/-._~?=&$!:") sb.append(ch)
            else for (b in ch.toString().toByteArray()) sb.append("%%%02X".format(b.toInt() and 0xFF))
        }
        return base + sb
    }

    fun text(path: String, timeout: Long = 8): String {
        val c = http.newBuilder().readTimeout(timeout, TimeUnit.SECONDS).callTimeout(timeout + 4, TimeUnit.SECONDS).build()
        c.newCall(Request.Builder().url(url(path)).build()).execute().use { r ->
            if (r.code >= 400) throw Exception("HTTP ${r.code}")
            return r.body?.string() ?: ""
        }
    }

    data class Status(val cpu: Int? = null, val rsx: Int? = null, val fan: Int? = null, val uptime: String? = null, val firmware: String? = null)

    private fun firstInt(key: String, t: String): Int? {
        val i = t.indexOf(key); if (i < 0) return null
        return Regex("\\d+").find(t.substring(i + key.length, minOf(t.length, i + key.length + 16)))?.value?.toIntOrNull()
    }

    fun ping(): Boolean = try { val t = text("/cpursx.ps3", 3); t.contains("CPU", true) || t.contains("webMAN", true) } catch (e: Exception) { false }

    fun status(): Status {
        val t = text("/cpursx.ps3")
        val up = (t.indexOf("Startup:").takeIf { it >= 0 }?.let { it + 8 } ?: t.indexOf("Play:").takeIf { it >= 0 }?.let { it + 5 })
            ?.let { t.substring(it, minOf(t.length, it + 24)).split('<', '\n').first().trim() }
        val fw = t.indexOf("Firmware").takeIf { it >= 0 }?.let { t.substring(it + 8, minOf(t.length, it + 48)).split('<', '\n').first().trim(' ', ':') }
        return Status(firstInt("CPU:", t), firstInt("RSX:", t), firstInt("FAN:", t), up, fw)
    }

    fun games(): List<Game> {
        try { val l = GameParser.parseXml(text("/dev_hdd0/xmlhost/game_plugin/mygames.xml", 12)); if (l.isNotEmpty()) return l } catch (_: Exception) {}
        return GameParser.parseIndex(text("/index.ps3", 25))
    }

    private val pwd get() = if (password.isEmpty()) "" else "?pwd=$password"
    fun refreshGames() { try { text("/refresh.ps3", 60) } catch (_: Exception) {} }
    fun play(g: Game) = text("/play.ps3" + g.path, 20)
    fun mount(g: Game) = text("/mount_ps3" + g.path, 20)
    fun unmount() = text("/mount_ps3/unmount")
    fun pad(b: String) { try { text("/pad.ps3?$b", 3) } catch (_: Exception) {} }
    fun popup(m: String) = text("/popup.ps3?$m")
    fun eject() = text("/eject.ps3")
    fun insert() = text("/insert.ps3")
    fun restart() = text("/restart.ps3$pwd")
    fun shutdown() = text("/shutdown.ps3$pwd")
    fun quitGame() = text("/xmb.ps3\$exit")
    fun installUrl(u: String) = text("/install.ps3?url=$u", 20)
    fun installPath(p: String) = text("/install.ps3$p", 20)
    fun screenshot() = text("/browser.ps3\$screenshot_xmb", 15)
}

fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")
