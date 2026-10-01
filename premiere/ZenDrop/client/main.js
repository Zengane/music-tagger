/*
 * Zen Drop - panel logic.
 *
 * The panel owns a loopback HTTP listener. Listary (through the small bridge
 * exe) hits that listener with a file path, and the panel forwards it to
 * ExtendScript. Nothing is polled: evalScript runs on Premiere's main thread,
 * so a timer that calls it every second makes the whole app stutter. The only
 * evalScript calls here are the ones a drop or a button press actually needs.
 */

(function () {
    "use strict";

    var nodeRequire = (typeof window.cep_node !== "undefined") ? window.cep_node.require : require;
    var http = nodeRequire("http");
    var fs = nodeRequire("fs");
    var url = nodeRequire("url");

    var cs = new CSInterface();
    var prefs = Prefs.load();

    var server = null;
    var serverPort = 0;
    var queue = [];
    var busy = false;

    /* What happened to each drop that came with a job id, so the sender can
       ask (GET /status?job=<id>) instead of taking "queued" for "placed".
       Only the last few are kept. */
    var jobs = {};
    var jobOrder = [];

    function setJob(id, state, message) {
        if (!id) { return; }
        if (!jobs.hasOwnProperty(id)) {
            jobOrder.push(id);
            if (jobOrder.length > 64) { delete jobs[jobOrder.shift()]; }
        }
        jobs[id] = { state: state, message: message || "" };
    }

    var el = {
        log: document.getElementById("log"),
        status: document.getElementById("status"),
        listenerText: document.getElementById("listenerText"),
        dot: document.getElementById("dot"),
        gear: document.getElementById("gear"),
        place: document.getElementById("place"),
        modeTimeline: document.getElementById("modeTimeline"),
        modeSource: document.getElementById("modeSource")
    };

    /* ---------- log ---------- */

    function log(msg, cls) {
        var line = document.createElement("div");
        if (cls) { line.className = cls; }
        var t = new Date();
        var hh = ("0" + t.getHours()).slice(-2), mm = ("0" + t.getMinutes()).slice(-2), ss = ("0" + t.getSeconds()).slice(-2);
        line.textContent = hh + ":" + mm + ":" + ss + "  " + msg;
        el.log.appendChild(line);
        while (el.log.childNodes.length > prefs.logLines) { el.log.removeChild(el.log.firstChild); }
        el.log.scrollTop = el.log.scrollHeight;
    }

    /* ---------- ExtendScript ---------- */

    function esArg(v) {
        if (typeof v === "boolean") { return v ? "true" : "false"; }
        var s = String(v).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
        return '"' + s + '"';
    }

    /*
     * timeoutMs guards against evalScript never calling back. That happens when
     * Premiere is stuck behind a modal dialog or is still conforming media: the
     * panel would otherwise sit on a "drop:" line forever with the queue wedged
     * and no way to tell whether anything is happening.
     */
    function call(fn, args, cb, timeoutMs) {
        var parts = [], done = false, timer = null;
        for (var i = 0; i < args.length; i++) { parts.push(esArg(args[i])); }

        function finish(res) {
            if (done) { return; }
            done = true;
            if (timer) { clearTimeout(timer); }
            cb(res);
        }

        if (timeoutMs) {
            timer = setTimeout(function () {
                finish({
                    ok: false,
                    error: "Premiere did not answer within " + Math.round(timeoutMs / 1000) +
                           "s. Check for a dialog waiting behind the app, or media still conforming."
                });
            }, timeoutMs);
        }

        cs.evalScript(fn + "(" + parts.join(", ") + ")", function (raw) {
            var res;
            try { res = JSON.parse(raw); } catch (e) { res = { ok: false, error: "Host script returned: " + raw }; }
            finish(res);
        });
    }

    /* ---------- drop queue ---------- */

    function enqueue(job) {
        queue.push(job);
        pump();
    }

    function pump() {
        if (busy || queue.length === 0) { return; }
        busy = true;
        var job = queue.shift();

        var base = job.path.replace(/^.*[\\\/]/, "");
        var range = (job.in >= 0 && job.out > job.in)
            ? " " + job.in.toFixed(2) + "-" + job.out.toFixed(2) + "s" : "";
        log("drop: " + base + range + " (" + job.mode + ")", "dim");

        setJob(job.id, "running");
        call("zdDrop", [job.path, job.mode, prefs.bin, prefs.fallback, prefs.checkAudio, prefs.skipLocked,
                        job.in, job.out, job.mark, job.dur], function (res) {
            busy = false;
            var said;
            if (!res.ok) {
                said = res.error;
                log("FAILED " + base + " - " + res.error, "err");
                setJob(job.id, "failed", res.error);
            } else if (res.staged) {
                said = "loaded in Source Monitor: " + res.name + " - set in/out, then Place";
                log(said, "ok");
                setJob(job.id, "done", said);
            } else {
                said = "placed " + res.name + " on " + res.track +
                    (res.addedTrack ? " (new track)" : "") +
                    (res.marked ? " + marker" : "");
                log(said, "ok");
                setJob(job.id, "done", said);
            }
            refreshStatus();
            pump();
        }, 180000);
    }

    /* ---------- HTTP listener ---------- */

    function stopServer() {
        if (server) {
            try { server.close(); } catch (e) {}
            server = null;
        }
        serverPort = 0;
    }

    function setListener(up, text) {
        el.dot.className = up ? "dot up" : "dot";
        el.listenerText.textContent = text;
    }

    function startServer() {
        stopServer();
        var port = prefs.port;
        server = http.createServer(function (req, res) {
            var parsed = url.parse(req.url, true);
            res.setHeader("Content-Type", "text/plain; charset=utf-8");

            if (parsed.pathname === "/ping") {
                res.writeHead(200); res.end("zendrop"); return;
            }

            /* "queued", "running", "done <message>", "failed <message>",
               or 404 for a job this panel never saw. */
            if (parsed.pathname === "/status") {
                var j = jobs[String(parsed.query.job || "")];
                if (!j) { res.writeHead(404); res.end("unknown"); return; }
                res.writeHead(200);
                res.end(j.state + (j.message ? " " + j.message : ""));
                return;
            }

            /* A drag from another app has landed: trim what Premiere just
               placed down to the part that was actually wanted. */
            if (parsed.pathname === "/trim") {
                var tq = parsed.query;
                var tp = tq.path || "";
                if (!tp) { res.writeHead(400); res.end("missing path"); return; }
                res.writeHead(200); res.end("ok");
                doTrim(tp, Number(tq["in"]), Number(tq.out), Number(tq.mark));
                return;
            }

            /* A placeholder of the right length has landed: put the real
               file in its place, trimmed to the selection. */
            if (parsed.pathname === "/swap") {
                var sq = parsed.query;
                if (!sq.placeholder || !sq.path) {
                    res.writeHead(400); res.end("missing placeholder or path"); return;
                }
                res.writeHead(200); res.end("ok");
                doSwap(String(sq.placeholder), String(sq.path),
                       Number(sq["in"]), Number(sq.out), Number(sq.mark));
                return;
            }

            if (parsed.pathname === "/place") {
                res.writeHead(200); res.end("ok");
                doPlaceFromSource();
                return;
            }

            if (parsed.pathname === "/drop") {
                var p = parsed.query.path || "";
                var mode = parsed.query.mode || prefs.mode;
                if (mode !== "timeline" && mode !== "source") { mode = prefs.mode; }
                if (!p) { res.writeHead(400); res.end("missing path"); return; }
                if (!fs.existsSync(p)) { res.writeHead(404); res.end("no such file: " + p); return; }
                /* An optional span of the source, in seconds, and an
                   optional sync point inside it. Absent means the whole file,
                   which is what Listary sends. */
                var q = parsed.query;
                var inSec = (q["in"] === undefined) ? -1 : Number(q["in"]);
                var outSec = (q.out === undefined) ? -1 : Number(q.out);
                var mark = (q.mark === undefined) ? -1 : Number(q.mark);
                if (!isFinite(inSec)) { inSec = -1; }
                if (!isFinite(outSec)) { outSec = -1; }
                if (!isFinite(mark)) { mark = -1; }
                /* The file's length, when the sender knows it, for placing a
                   whole file whose length Premiere does not report. */
                var dur = (q.dur === undefined) ? -1 : Number(q.dur);
                if (!isFinite(dur)) { dur = -1; }
                var id = String(q.job || "");

                res.writeHead(200); res.end("queued");
                setJob(id, "queued");
                enqueue({ path: p, mode: mode, in: inSec, out: outSec, mark: mark, dur: dur, id: id });
                return;
            }

            res.writeHead(404); res.end("unknown");
        });

        server.on("error", function (e) {
            setListener(false, "port " + port + " unavailable - " + e.code);
            log("listener error on port " + port + ": " + e.message, "err");
            server = null;
        });

        /* Loopback only. Nothing outside this machine can reach it. */
        server.listen(port, "127.0.0.1", function () {
            serverPort = port;
            setListener(true, "listening on 127.0.0.1:" + port);
            log("listener up on port " + port, "dim");
        });
    }

    /* ---------- actions ---------- */

    function doPlaceFromSource() {
        el.place.disabled = true;
        call("zdPlaceFromSource", [prefs.fallback, prefs.checkAudio, prefs.skipLocked], function (res) {
            el.place.disabled = false;
            if (!res.ok) {
                log("FAILED - " + res.error, "err");
            } else {
                log("placed " + res.name + " on " + res.track + (res.addedTrack ? " (new track)" : ""), "ok");
            }
            refreshStatus();
        }, 120000);
    }

    function doTrim(path, inSec, outSec, mark) {
        var base = path.replace(/^.*[\\\/]/, "");
        if (!isFinite(mark)) { mark = -1; }
        log("trim: " + base + " " + inSec.toFixed(2) + "-" + outSec.toFixed(2) + "s", "dim");

        call("zdTrimDropped", [path, inSec, outSec, mark], function (res) {
            if (!res.ok) {
                log("could not trim " + base + " - " + res.error, "err");
            } else {
                log("trimmed " + res.name + " to " + res.durationSeconds.toFixed(2) + "s" +
                    (res.marked ? " + marker" : ""), "ok");
            }
        }, 60000);
    }

    function doSwap(placeholder, path, inSec, outSec, mark) {
        var base = path.replace(/^.*[\\\/]/, "");
        if (!isFinite(mark)) { mark = -1; }
        log("swap: " + base + " " + inSec.toFixed(2) + "-" + outSec.toFixed(2) + "s", "dim");

        call("zdSwapPlaceholder", [placeholder, path, inSec, outSec, mark, prefs.bin],
             function (res) {
                 if (!res.ok) {
                     log("kept the rendered clip - " + res.error, "err");
                 } else {
                     log("placed " + res.name + " on " + res.track + " (" +
                         res.durationSeconds.toFixed(2) + "s)" +
                         (res.marked ? " + marker" : ""), "ok");
                 }
             }, 120000);
    }

    function refreshStatus() {
        call("zdStatus", [], function (res) {
            if (!res.ok) { el.status.textContent = res.error; return; }
            if (!res.sequence) {
                el.status.textContent = res.project ? (res.project + " - no active sequence") : "no project open";
                return;
            }
            el.status.textContent = res.sequence + "  -  " + res.videoTracks + "V / " + res.audioTracks + "A";
        });
    }

    function paintMode() {
        el.modeTimeline.className = (prefs.mode === "timeline") ? "on" : "";
        el.modeSource.className = (prefs.mode === "source") ? "on" : "";
    }

    function setMode(m) {
        prefs.mode = m;
        prefs = Prefs.save(prefs);
        paintMode();
    }

    /* ---------- settings sync ---------- */

    function reloadPrefs() {
        var oldPort = prefs.port;
        prefs = Prefs.load();
        paintMode();
        if (prefs.port !== oldPort || !server) { startServer(); }
    }

    cs.addEventListener(Prefs.CHANGED_EVENT, function () { reloadPrefs(); });

    /* Belt and braces: the CSEvent can be missed if the panel reloads mid-save.
       fs.watch is filesystem-driven, so it costs nothing while idle. */
    try {
        fs.mkdirSync(Prefs.dir(), { recursive: true });
        fs.watch(Prefs.dir(), function (evt, name) {
            if (name && name.indexOf("settings.json") === 0) { reloadPrefs(); }
        });
    } catch (e) {}

    /* ---------- wire up ---------- */

    el.gear.addEventListener("click", function () {
        cs.requestOpenExtension(Prefs.SETTINGS_EXTENSION_ID, "");
    });
    el.place.addEventListener("click", doPlaceFromSource);
    el.modeTimeline.addEventListener("click", function () { setMode("timeline"); });
    el.modeSource.addEventListener("click", function () { setMode("source"); });
    el.status.addEventListener("click", refreshStatus);

    window.addEventListener("beforeunload", stopServer);

    paintMode();
    startServer();
    refreshStatus();
    log("ready. Send files from Listary with ZenDropSend.exe", "dim");
})();
