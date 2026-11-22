package com.cruyfford.ps3hub

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink
import org.apache.commons.net.ftp.FTP
import org.apache.commons.net.ftp.FTPClient
import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.TimeUnit

data class Entry(val name: String, val dir: Boolean, val size: Long)
data class Volume(val label: String, val root: String, val fs: String, val writable: Boolean, val free: Long)
data class PsTask(val task: String, val name: String, val done: Long, val total: Long, val queue: Int)

interface RemoteFs {
    fun list(path: String): List<Entry>
    fun mkdir(path: String)
    fun rename(from: String, to: String)
    fun delete(path: String, dir: Boolean)
    fun download(path: String, out: OutputStream, progress: (Long) -> Unit)
    fun upload(input: InputStream, size: Long, path: String, progress: (Long) -> Unit)
    fun close() {}
}

private fun sortEntries(l: List<Entry>) = l.sortedWith(compareBy<Entry>({ !it.dir }, { it.name.lowercase() }))

/** File Manager (CRPK00001) phone link: HTTP/JSON on port 8080, every drive incl. NTFS / exFAT */
class FmClient(host: String) : RemoteFs {
    private val base = "http://$host:8080"
    private val longHttp = http.newBuilder().readTimeout(0, TimeUnit.SECONDS).writeTimeout(0, TimeUnit.SECONDS).build()

    private fun call(method: String, path: String, q: String = ""): String {
        val b = Request.Builder().url("$base/$path${if (q.isEmpty()) "" else "?$q"}")
        if (method == "POST") b.post(ByteArray(0).toRequestBody(null)) else b.get()
        http.newCall(b.build()).execute().use { r ->
            val body = r.body?.string() ?: ""
            if (r.code != 200) throw Exception(runCatching { JSONObject(body).optString("error") }.getOrNull()?.ifEmpty { null } ?: "HTTP ${r.code}")
            return body
        }
    }

    fun volumes(): List<Volume> {
        val a = JSONObject(call("GET", "api/volumes")).getJSONArray("volumes")
        return (0 until a.length()).map { val o = a.getJSONObject(it); Volume(o.getString("label"), o.getString("root"), o.getString("fs"), o.optBoolean("writable"), o.optLong("free")) }
    }

    fun status(): PsTask? {
        val o = JSONObject(call("GET", "api/status"))
        if (!o.optBoolean("busy")) return null
        return PsTask(o.optString("task"), o.optString("name"), o.optLong("done"), o.optLong("total"), o.optInt("queue"))
    }

    fun install(path: String) { call("POST", "api/install", "path=" + enc(path)) }

    override fun list(path: String): List<Entry> {
        val a = JSONObject(call("GET", "api/list", "path=" + enc(path))).getJSONArray("entries")
        return sortEntries((0 until a.length()).map { val o = a.getJSONObject(it); Entry(o.getString("name"), o.getBoolean("dir"), o.optLong("size")) })
    }
    override fun mkdir(path: String) { call("POST", "api/mkdir", "path=" + enc(path)) }
    override fun rename(from: String, to: String) { call("POST", "api/rename", "from=" + enc(from) + "&to=" + enc(to)) }
    override fun delete(path: String, dir: Boolean) { call("POST", "api/delete", "path=" + enc(path)) }

    override fun download(path: String, out: OutputStream, progress: (Long) -> Unit) {
        longHttp.newCall(Request.Builder().url("$base/api/file?path=" + enc(path)).build()).execute().use { r ->
            if (r.code != 200) throw Exception("HTTP ${r.code}")
            val ins = r.body!!.byteStream()
            val buf = ByteArray(256 * 1024); var total = 0L
            while (true) { val n = ins.read(buf); if (n < 0) break; out.write(buf, 0, n); total += n; progress(total) }
        }
    }

    override fun upload(input: InputStream, size: Long, path: String, progress: (Long) -> Unit) {
        val body = object : RequestBody() {
            override fun contentType() = "application/octet-stream".toMediaType()
            override fun contentLength() = size
            override fun writeTo(sink: BufferedSink) {
                val buf = ByteArray(256 * 1024); var total = 0L
                while (true) { val n = input.read(buf); if (n < 0) break; sink.write(buf, 0, n); total += n; progress(total) }
            }
        }
        longHttp.newCall(Request.Builder().url("$base/api/file?path=" + enc(path)).put(body).build()).execute().use { r ->
            if (r.code != 200) throw Exception(runCatching { JSONObject(r.body?.string() ?: "").optString("error") }.getOrNull()?.ifEmpty { null } ?: "HTTP ${r.code}")
        }
    }

    companion object {
        fun probe(host: String): Boolean = try {
            val c = http.newBuilder().callTimeout(3, TimeUnit.SECONDS).build()
            c.newCall(Request.Builder().url("http://$host:8080/api/info").build()).execute().use { it.code == 200 && (it.body?.string() ?: "").contains("CRPK00001") }
        } catch (e: Exception) { false }
    }
}

/** webMAN / File Manager FTP */
class FtpFs(private val host: String, private val port: Int) : RemoteFs {
    private var c: FTPClient? = null

    @Synchronized private fun client(): FTPClient {
        c?.let { if (it.isConnected) return it }
        val f = FTPClient()
        f.connectTimeout = 6000
        f.controlEncoding = "UTF-8"
        f.connect(host, port)
        f.login("anonymous", "ps3hub")
        f.enterLocalPassiveMode()
        f.setFileType(FTP.BINARY_FILE_TYPE)
        f.bufferSize = 256 * 1024
        c = f
        return f
    }

    @Synchronized override fun list(path: String): List<Entry> {
        val f = client()
        val l = f.listFiles(path) ?: emptyArray()
        return sortEntries(l.filter { it.name != "." && it.name != ".." }.map { Entry(it.name, it.isDirectory, it.size) })
    }
    @Synchronized override fun mkdir(path: String) { client().makeDirectory(path) }
    @Synchronized override fun rename(from: String, to: String) { client().rename(from, to) }
    @Synchronized override fun delete(path: String, dir: Boolean) { val f = client(); if (dir) f.removeDirectory(path) else f.deleteFile(path) }
    @Synchronized override fun download(path: String, out: OutputStream, progress: (Long) -> Unit) {
        val ins = client().retrieveFileStream(path) ?: throw Exception("FTP")
        val buf = ByteArray(256 * 1024); var total = 0L
        ins.use { while (true) { val n = it.read(buf); if (n < 0) break; out.write(buf, 0, n); total += n; progress(total) } }
        client().completePendingCommand()
    }
    @Synchronized override fun upload(input: InputStream, size: Long, path: String, progress: (Long) -> Unit) {
        val os = client().storeFileStream(path) ?: throw Exception("FTP")
        val buf = ByteArray(256 * 1024); var total = 0L
        os.use { while (true) { val n = input.read(buf); if (n < 0) break; it.write(buf, 0, n); total += n; progress(total) } }
        if (!client().completePendingCommand()) throw Exception("FTP")
    }
    override fun close() { try { c?.disconnect() } catch (_: Exception) {}; c = null }
}
