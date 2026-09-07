/*
 * Shared preferences for Zen Drop.
 *
 * Loaded by BOTH windows - the panel and the settings dialog - because they are
 * separate CEP extensions with separate CEF contexts. They share nothing except
 * this file and the JSON on disk, so all schema knowledge lives here.
 *
 * The bridge executable (bridge/ZenDropSend.exe) reads the SAME settings.json
 * to learn the port, so the port never has to be typed in two places.
 */

var Prefs = (function () {
    var nodeRequire = (typeof window !== "undefined" && typeof window.cep_node !== "undefined")
        ? window.cep_node.require : require;
    var fs = nodeRequire("fs");
    var nodePath = nodeRequire("path");
    var os = nodeRequire("os");

    var VERSION = 1;
    var VENDOR = "Zengane";
    var PRODUCT = "Zen Drop";

    /** CSEvent type both windows agree on. */
    var CHANGED_EVENT = "com.zengane.zendrop.settingsChanged";
    var SETTINGS_EXTENSION_ID = "com.zengane.zendrop.settings";

    var MODES = ["timeline", "source"];
    /* What to do when no existing track has room at the playhead. */
    var FALLBACKS = ["newtrack", "abort"];

    function dir() {
        var base = process.env.APPDATA || process.env.XDG_CONFIG_HOME || os.homedir();
        return nodePath.join(base, VENDOR, PRODUCT);
    }

    function file() { return nodePath.join(dir(), "settings.json"); }

    function defaults() {
        return {
            version: VERSION,

            /* Local listener the bridge exe talks to. Loopback only. */
            port: 47821,

            /* Bin every dropped file lands in. Created if missing. */
            bin: "Listary Imports",

            /* "timeline" places straight away. "source" loads the Source
               Monitor so in/out can be trimmed first, then the panel's
               Place button drops it. */
            mode: "timeline",

            /* No free track at the playhead -> add one, or refuse. */
            fallback: "newtrack",

            /* Video files usually carry audio, and Premiere lays that audio on
               the audio track of the same index. When true, a video track only
               counts as free if its matching audio track is free too. Turn off
               if most of your footage is silent. */
            checkAudio: true,

            /* Never place on a locked track, even if it looks empty. */
            skipLocked: true,

            /* Bring Premiere to the front after a drop. Wanted for Source
               Monitor mode, optional for straight timeline drops. */
            focusPremiere: true,

            /* Lines kept in the panel log. */
            logLines: 60
        };
    }

    function clampInt(v, lo, hi, dflt) {
        var n = parseInt(v, 10);
        if (isNaN(n)) { return dflt; }
        if (n < lo) { return lo; }
        if (n > hi) { return hi; }
        return n;
    }

    function normalize(raw) {
        var d = defaults();
        var out = d;
        if (raw && typeof raw === "object") {
            for (var k in d) {
                if (d.hasOwnProperty(k) && raw.hasOwnProperty(k)) { out[k] = raw[k]; }
            }
        }
        out.version = VERSION;
        out.port = clampInt(out.port, 1024, 65535, d.port);
        out.logLines = clampInt(out.logLines, 10, 500, d.logLines);
        if (typeof out.bin !== "string" || out.bin.replace(/\s/g, "") === "") { out.bin = d.bin; }
        if (MODES.indexOf(out.mode) < 0) { out.mode = d.mode; }
        if (FALLBACKS.indexOf(out.fallback) < 0) { out.fallback = d.fallback; }
        out.checkAudio = !!out.checkAudio;
        out.skipLocked = !!out.skipLocked;
        out.focusPremiere = !!out.focusPremiere;
        return out;
    }

    function load() {
        try {
            var txt = fs.readFileSync(file(), "utf8");
            return normalize(JSON.parse(txt));
        } catch (e) {
            return defaults();
        }
    }

    function save(obj) {
        var clean = normalize(obj);
        try { fs.mkdirSync(dir(), { recursive: true }); } catch (e) {}
        fs.writeFileSync(file(), JSON.stringify(clean, null, 2), "utf8");
        return clean;
    }

    function mtime() {
        try { return fs.statSync(file()).mtimeMs; } catch (e) { return 0; }
    }

    return {
        VERSION: VERSION,
        MODES: MODES,
        FALLBACKS: FALLBACKS,
        CHANGED_EVENT: CHANGED_EVENT,
        SETTINGS_EXTENSION_ID: SETTINGS_EXTENSION_ID,
        dir: dir,
        file: file,
        defaults: defaults,
        load: load,
        save: save,
        mtime: mtime
    };
})();
