/* Zen Drop - settings dialog. Writes the shared settings.json, then tells the
   panel to re-read it. */

(function () {
    "use strict";

    var nodeRequire = (typeof window.cep_node !== "undefined") ? window.cep_node.require : require;
    var nodePath = nodeRequire("path");

    var cs = new CSInterface();
    var current = Prefs.load();

    var f = {
        bin: document.getElementById("bin"),
        mode: document.getElementById("mode"),
        fallback: document.getElementById("fallback"),
        checkAudio: document.getElementById("checkAudio"),
        skipLocked: document.getElementById("skipLocked"),
        focusPremiere: document.getElementById("focusPremiere"),
        port: document.getElementById("port"),
        logLines: document.getElementById("logLines"),
        cmd: document.getElementById("cmd")
    };

    function bridgePath() {
        /* extension root = client/.. */
        var root = nodePath.join(cs.getSystemPath(SystemPath.EXTENSION), "bridge");
        return nodePath.join(root, "ZenDropSend.exe");
    }

    function paintCmd() {
        f.cmd.textContent = '"' + bridgePath() + '" "{path}"';
    }

    function fill(p) {
        f.bin.value = p.bin;
        f.mode.value = p.mode;
        f.fallback.value = p.fallback;
        f.checkAudio.checked = p.checkAudio;
        f.skipLocked.checked = p.skipLocked;
        f.focusPremiere.checked = p.focusPremiere;
        f.port.value = p.port;
        f.logLines.value = p.logLines;
        paintCmd();
    }

    function collect() {
        return {
            version: Prefs.VERSION,
            bin: f.bin.value,
            mode: f.mode.value,
            fallback: f.fallback.value,
            checkAudio: f.checkAudio.checked,
            skipLocked: f.skipLocked.checked,
            focusPremiere: f.focusPremiere.checked,
            port: f.port.value,
            logLines: f.logLines.value
        };
    }

    function announce() {
        var evt = new CSEvent(Prefs.CHANGED_EVENT, "APPLICATION");
        evt.extensionId = Prefs.SETTINGS_EXTENSION_ID;
        cs.dispatchEvent(evt);
    }

    document.getElementById("save").addEventListener("click", function () {
        Prefs.save(collect());
        announce();
        cs.closeExtension();
    });

    document.getElementById("cancel").addEventListener("click", function () {
        cs.closeExtension();
    });

    document.getElementById("reset").addEventListener("click", function () {
        fill(Prefs.defaults());
    });

    fill(current);
})();
