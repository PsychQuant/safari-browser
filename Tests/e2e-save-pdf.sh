#!/bin/bash
# e2e-save-pdf.sh — live-Safari test for `save-pdf` (#338).
#
# What only a real Safari can show: `fetch(..., {cache: 'only-if-cached'})` reads a `no-store` PDF
# from memory and sends nothing. A local server logs every request, so "no request" is measured.
#
# It opens a Safari window of its own, which takes the foreground, and then brings Finder to the
# front and leaves it there, so nothing here touches Safari unless you set E2E_SAVE_PDF_OK=1. Set it yourself, when that is
# fine (not during a call), with a window of the profile you want in front: the new window takes that
# one's profile. After that every step addresses the fixture's URL or the new window's id, never a
# window's position, and the only thing it closes is that window.
#
# Not here: running without Full Disk Access. sandbox-exec gives the same EPERM as TCC, but Safari refuses
# Apple events from a sandboxed process (-10004) even when the sandbox denies nothing, so the command stops
# long before it writes. `make test-save-pdf-webkit` runs that case against a fake page.
#
# The service-worker cases (#390) register two service workers on this test's own origin (127.0.0.1 and
# the port) in the profile of the new window, and unregister every registration of that origin before the
# window closes, also when the run stops early. The new window opens in the profile of the window in front
# (#383), so the run stops before anything else when that window is not in E2E_SAVE_PDF_PROFILE (default 個人).
#
# Exit 77 (automake skip) when the guard is not set or Safari is not running.

set -u
if [[ "${E2E_SAVE_PDF_OK:-}" != "1" ]]; then
    echo "This test opens a Safari window in the foreground. Set E2E_SAVE_PDF_OK=1 to run it."
    exit 77
fi
pgrep -x Safari >/dev/null || { echo "Safari is not running; skipping"; exit 77; }

SB="${SAFARI_BROWSER_BIN:-.build/debug/safari-browser}"
WANT_PROFILE="${E2E_SAVE_PDF_PROFILE:-個人}"
PORT="${E2E_SAVE_PDF_PORT:-38339}"
WORK="$(mktemp -d)"
SERVER_PID=""
WINDOW=""
WORKERS_REGISTERED=""
passed=0
failed=0

pass() { passed=$((passed + 1)); echo "  ✓ $1"; }
fail() { failed=$((failed + 1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }
note() { echo "  - $1"; }

fixture_window() {
    osascript -e "tell application \"Safari\"
        repeat with w in windows
            try
                if URL of current tab of w starts with \"http://127.0.0.1:$PORT/\" then return id of w
            end try
        end repeat
    end tell" 2>/dev/null
}

cleanup() {
    [[ -z "$WINDOW" ]] && WINDOW="$(fixture_window)"
    [[ -n "$WORKERS_REGISTERED" && -n "$WINDOW" ]] && unregister_workers
    [[ -n "$WINDOW" ]] && osascript -e "tell application \"Safari\" to close window id $WINDOW" >/dev/null 2>&1
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/www/ranged" "$WORK/www/slow" "$WORK/www/sw-pass" "$WORK/www/sw-net"
python3 -I - "$WORK/www" <<'PY'
import os, sys
root = sys.argv[1]
def pdf(padding):
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>",
            b"<< /Length %d >>\nstream\n" % padding + os.urandom(padding) + b"\nendstream"]
    out = b"%PDF-1.4\n"; offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(out)); out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    x = len(out); out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offs)
    return out + b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
sizes = {"nostore.pdf": 250_000, "background.pdf": 250_000, "notheld.pdf": 250_000, "landed.pdf": 250_000,
         "error404.pdf": 250_000, "csp.pdf": 250_000, "changing-a.pdf": 250_000, "changing-b.pdf": 300_000,
         "slow/drip.pdf": 2_000_000, "nostore50.pdf": 50 * 1024 * 1024,
         "sw-pass/doc.pdf": 250_000, "sw-net/doc.pdf": 250_000}
for name, size in sizes.items():
    open(os.path.join(root, name), "wb").write(pdf(size))
def many_pages(count, each):
    # Pages that are really referenced, so that qpdf --linearize keeps them.
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [%s] /Count %d >>" % (b" ".join(b"%d 0 R" % (3 + 2 * i) for i in range(count)), count)]
    content = b"q Q\n" * (each // 4)
    for i in range(count):
        objs.append(b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents %d 0 R >>" % (4 + 2 * i))
        objs.append(b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream")
    out = b"%PDF-1.4\n"; offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(out)); out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    x = len(out); out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offs)
    return out + b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
open(os.path.join(root, "plain-big.pdf"), "wb").write(many_pages(200, 100_000))
open(os.path.join(root, "plain.html"), "w").write("<!doctype html><title>plain</title><p>not a pdf")
# #390: each service worker reports every fetch event it receives to /sw-saw, so its seeing a read shows in the log.
answers = {"pass": "fetch(e.request)", "net": 'fetch(e.request.url, { cache: "no-store" })'}
for scope, answer in answers.items():
    open(os.path.join(root, "sw-%s/sw.js" % scope), "w").write(
        'self.addEventListener("install", function (e) { self.skipWaiting(); });\n'
        'self.addEventListener("activate", function (e) { e.waitUntil(self.clients.claim()); });\n'
        'self.addEventListener("fetch", function (e) {\n'
        '  fetch("/sw-saw?scope=%s&mode=" + e.request.mode + "&u=" + encodeURIComponent(new URL(e.request.url).pathname));\n'
        '  e.respondWith(%s);\n'
        '});\n' % (scope, answer))
    open(os.path.join(root, "sw-%s/index.html" % scope), "w").write(
        "<!doctype html><title>sw</title><p id=s>registering</p><script>"
        "navigator.serviceWorker.register('sw.js', { scope: './' })"
        ".then(function () { return navigator.serviceWorker.ready; })"
        ".then(function () { document.getElementById('s').textContent = 'ready'; },"
        " function (e) { document.getElementById('s').textContent = 'failed ' + e; });</script>")
open(os.path.join(root, "sw-cleanup.html"), "w").write(
    "<!doctype html><title>clean</title><p id=s>cleaning</p><script>"
    "navigator.serviceWorker.getRegistrations()"
    ".then(function (rs) { return Promise.all(rs.map(function (r) { return r.unregister(); })); })"
    ".then(function () { return navigator.serviceWorker.getRegistrations(); })"
    ".then(function (rs) { document.getElementById('s').textContent = 'left:' + rs.length; });</script>")
PY
# WebKit asks for byte ranges only for a linearized PDF, so the ranged case needs one.
if command -v qpdf >/dev/null; then
    qpdf --linearize --compress-streams=n --object-streams=disable --warning-exit-0 "$WORK/www/plain-big.pdf" "$WORK/www/ranged/big.pdf" 2>/dev/null
fi
cat > "$WORK/serve.py" <<'PY'
import http.server, re, sys, time
root, log, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
changing = [0]
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=root, **k)
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        if self.path.startswith("/ranged/"): self.send_header("Accept-Ranges", "bytes")
        if self.path == "/csp.pdf":
            self.send_header("Content-Security-Policy", "connect-src 'none'; report-uri /report")
        super().end_headers()
    def body(self, name, status=200):
        data = open(self.translate_path("/" + name), "rb").read()
        self.send_response(status)
        self.send_header("Content-Type", "application/pdf")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        return data
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(204); self.end_headers()
    def do_GET(self):
        if self.path.startswith("/sw-saw"):
            self.send_response(204); self.send_header("Content-Length", "0"); self.end_headers(); return
        if self.path == "/redirect.pdf":
            self.send_response(302); self.send_header("Location", "/landed.pdf"); self.end_headers(); return
        if self.path == "/error404.pdf":
            self.wfile.write(self.body("error404.pdf", 404)); return
        if self.path == "/changing.pdf":
            changing[0] += 1
            self.wfile.write(self.body("changing-a.pdf" if changing[0] == 1 else "changing-b.pdf")); return
        if self.path == "/slow/drip.pdf":
            data = self.body("slow/drip.pdf"); step = len(data) // 8 + 1
            for i in range(0, len(data), step):
                self.wfile.write(data[i:i + step]); self.wfile.flush(); time.sleep(1)
            return
        m = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        if self.path.startswith("/ranged/") and not m:
            # Slowly, as over a real network: that is when the viewer asks for ranges of its own.
            data = self.body(self.path.lstrip("/")); step = len(data) // 20 + 1
            try:
                for i in range(0, len(data), step):
                    self.wfile.write(data[i:i + step]); self.wfile.flush(); time.sleep(0.25)
            except OSError: pass
            return
        if not (m and self.path.startswith("/ranged/")): return super().do_GET()
        data = open(self.translate_path(self.path), "rb").read()
        start, end = int(m[1]), min(int(m[2]) if m[2] else len(data) - 1, len(data) - 1)
        self.send_response(206)
        self.send_header("Content-Type", "application/pdf")
        self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, len(data)))
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self.wfile.write(data[start:end + 1])
    def log_message(self, fmt, *args):
        open(log, "a").write(self.command + " " + self.path + " " + self.headers.get("Range", "") + "\n")
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
LOG="$WORK/requests.log"; : > "$LOG"
python3 -I "$WORK/serve.py" "$WORK/www" "$LOG" "$PORT" &
SERVER_PID=$!
sleep 1

# Only what the test asked for counts: Safari fetches icons on its own schedule.
requests() { grep -cE ' /[^ ]*\.(pdf|html) ' "$LOG" | tr -d ' '; }
settled_requests() { # the PDF viewer can still be asking for ranges in the background
    local a b
    a=$(requests); sleep 2; b=$(requests)
    while [[ "$a" != "$b" ]]; do a=$b; sleep 2; b=$(requests); done
    echo "$b"
}
base="http://127.0.0.1:$PORT"
OUT="$WORK/out"; mkdir -p "$OUT"
front_app() { lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null; }
current_url() { osascript -e "tell application \"Safari\" to get URL of current tab of window id $WINDOW" 2>/dev/null; }
# A new tab made this way stays in the background.
open_tab() { osascript -e "tell application \"Safari\" to tell window id $WINDOW to make new tab at end of tabs with properties {URL:\"$base/$1\"}" >/dev/null 2>&1; }
shows() { # shows <path> <content type>: wait until the tab's document has that type
    local i
    for i in $(seq 1 80); do
        [[ "$("$SB" js 'document.contentType' --url "127.0.0.1:$PORT/$1" 2>/dev/null)" == "$2" ]] && { sleep 1; return 0; }
        sleep 0.5
    done
    fail "$1 never showed as $2"; return 1
}
no_new_request() { [[ "$(requests)" == "$1" ]] && pass "no request reached the server" || fail "the server got $(( $(requests) - $1 )) request(s)" "$(tail -3 "$LOG")"; }
# Unregisters every service worker of this origin, from a page of the origin outside both workers' scopes.
# Each call opens its own address, so a second call (from the EXIT trap) never matches the first call's tab.
CLEANUPS=0
unregister_workers() {
    local i state="" page
    CLEANUPS=$((CLEANUPS + 1)); page="sw-cleanup.html?run=$CLEANUPS-$$"
    open_tab "$page"
    for i in $(seq 1 40); do
        state=$("$SB" js "document.getElementById('s') ? document.getElementById('s').textContent : ''" --url "127.0.0.1:$PORT/$page" 2>/dev/null)
        [[ "$state" == left:* ]] && break
        sleep 0.5
    done
    if [[ "$state" == "left:0" ]]; then WORKERS_REGISTERED=""; echo "  - service workers of 127.0.0.1:$PORT unregistered"
    else echo "  ! could not confirm the service workers of 127.0.0.1:$PORT were unregistered ($state); remove them in Safari's settings"; fi
}

# An absence in the log means nothing until something that would come after it has come. The tab fetches a
# sentinel the service worker reports; once its report and its request are in the log, a report of the read
# sent before it would be there too. The sentinel is a .txt, so requests() does not count it.
SENTINELS=0
flush_through_worker() { # flush_through_worker <scope> <tab path>
    local i name
    SENTINELS=$((SENTINELS + 1)); name="sentinel-$SENTINELS.txt"
    "$SB" js "fetch('/sw-$1/$name').then(function () {}, function () {}); 1" --url "127.0.0.1:$PORT/$2" >/dev/null 2>&1
    for i in $(seq 1 40); do
        grep -q "u=%2Fsw-$1%2F$name" "$LOG" && grep -q "^GET /sw-$1/$name" "$LOG" && return 0
        sleep 0.25
    done
    fail "$1: the service worker never reported $name, so the count below says nothing"; return 1
}
# The fixture window is in the wanted profile when its tabs are among that profile's documents.
window_in_profile() {
    "$SB" documents --json --profile "$WANT_PROFILE" 2>/dev/null \
        | python3 -I -c 'import json, sys; print(any(str(d.get("window_id")) == sys.argv[1] for d in json.load(sys.stdin)))' "$WINDOW" 2>/dev/null
}

echo "Safari has $(osascript -e 'tell application "Safari" to count windows' 2>/dev/null) window(s) open; this test adds one."

echo "=== a no-store PDF ==="
"$SB" open --new-window "$base/nostore.pdf" >/dev/null 2>&1
sleep 1
WINDOW="$(fixture_window)"
[[ -n "$WINDOW" ]] || { fail "the fixture window did not open"; exit 1; }
# #383: the window opens in the front window's profile, and the service workers below are registered there.
[[ "$(window_in_profile)" == "True" ]] && pass "the fixture window is in the profile $WANT_PROFILE" \
    || { fail "the fixture window is not in the profile $WANT_PROFILE; bring a window of that profile to the front and run again"; exit 1; }
shows nostore.pdf application/pdf
# Without this every "no request" below passes on a log that records nothing.
grep -q '^GET /nostore.pdf' "$LOG" && pass "the server logged the request that displayed the PDF" \
    || { fail "the log has no GET for the displayed PDF; nothing below would mean anything"; exit 1; }
before=$(requests)
json=$("$SB" save-pdf "$OUT/a.pdf" --url "127.0.0.1:$PORT/nostore.pdf" --json 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] && pass "exit 0" || fail "exit $rc"
cmp -s "$OUT/a.pdf" "$WORK/www/nostore.pdf" && pass "bytes are identical" || fail "bytes differ"
no_new_request "$before"
echo "$json" | grep -q '"source" : "tab"' && pass "--json says source tab" || fail "--json: $json"

echo "=== a background tab, with another app in front ==="
open_tab background.pdf
shows background.pdf application/pdf
current_before=$(current_url); before=$(requests)
[[ "$current_before" != *background.pdf* ]] && pass "the tab really is in the background" || fail "the new tab became current"
# `open --new-window` raised Safari, so comparing while Safari is in front would see nothing.
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
sleep 1
front=$(front_app)
[[ "$front" == *Finder* ]] && pass "Finder is in front for this check" || note "Finder did not come to the front ($front); the comparison below says less"
"$SB" save-pdf "$OUT/b.pdf" --url "127.0.0.1:$PORT/background.pdf" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$OUT/b.pdf" "$WORK/www/background.pdf" && pass "saved from a background tab" || fail "exit $rc or bytes differ"
[[ "$(current_url)" == "$current_before" ]] && pass "the current tab did not change" || fail "the current tab changed"
[[ "$(front_app)" == "$front" ]] && pass "the frontmost application did not change" || fail "the frontmost application changed (did you switch?)"
no_new_request "$before"

echo "=== bytes WebKit does not hold ==="
open_tab notheld.pdf
shows notheld.pdf application/pdf
# The address now names something that was never loaded, so `only-if-cached` has nothing to answer with.
"$SB" js "history.replaceState(null, '', '/never-loaded.pdf')" --url "127.0.0.1:$PORT/notheld.pdf" >/dev/null 2>&1
before=$(requests)
msg=$("$SB" save-pdf "$OUT/n.pdf" --url "127.0.0.1:$PORT/never-loaded.pdf" 2>&1); rc=$?
[[ $rc -eq 1 && "$msg" == *"does not hold the whole document"* && ! -e "$OUT/n.pdf" ]] && pass "it fails, says why, and writes nothing" || fail "rc=$rc: $msg"
no_new_request "$before"

echo "=== a PDF reached through a redirect ==="
# ScienceDirect's tabs arrive this way.
open_tab redirect.pdf
shows landed.pdf application/pdf
before=$(requests)
msg=$("$SB" save-pdf "$OUT/l.pdf" --url "127.0.0.1:$PORT/landed.pdf" 2>&1); rc=$?
[[ $rc -eq 0 ]] && cmp -s "$OUT/l.pdf" "$WORK/www/landed.pdf" && pass "saved" || fail "rc=$rc: $msg"
no_new_request "$before"

echo "=== a PDF the server sent with status 404 ==="
# The fetch does not show the server's status; documented, so measured.
open_tab error404.pdf
if shows error404.pdf application/pdf; then
    before=$(requests)
    msg=$("$SB" save-pdf "$OUT/x.pdf" --url "127.0.0.1:$PORT/error404.pdf" 2>&1); rc=$?
    [[ $rc -eq 0 ]] && cmp -s "$OUT/x.pdf" "$WORK/www/error404.pdf" && pass "saved like any other, as documented" || fail "rc=$rc: $msg"
    no_new_request "$before"
fi

echo "=== one URL, two tabs, different content ==="
# Whether the answer belongs to the document or to the URL. The server sends the second request other
# bytes; the fragments never reach it and only tell the two tabs apart here.
open_tab 'changing.pdf#a'
shows 'changing.pdf#a' application/pdf
open_tab 'changing.pdf#b'
shows 'changing.pdf#b' application/pdf
[[ "$(grep -c '^GET /changing.pdf' "$LOG")" == "2" ]] && pass "the server sent each tab its own copy" || fail "expected two GETs for the URL" "$(grep changing "$LOG")"
before=$(requests)
msg=$("$SB" save-pdf "$OUT/w1.pdf" --url "127.0.0.1:$PORT/changing.pdf#a" 2>&1); rc1=$?
msg2=$("$SB" save-pdf "$OUT/w2.pdf" --url "127.0.0.1:$PORT/changing.pdf#b" 2>&1); rc2=$?
if [[ $rc1 -eq 0 && $rc2 -eq 0 ]]; then
    if cmp -s "$OUT/w1.pdf" "$WORK/www/changing-a.pdf" && cmp -s "$OUT/w2.pdf" "$WORK/www/changing-b.pdf"; then
        pass "each tab gave what it displays: the answer belongs to the document"
    else
        fail "a tab did not give what it displays ($(wc -c < "$OUT/w1.pdf") and $(wc -c < "$OUT/w2.pdf") bytes)" "the README says it does; correct the README"
    fi
else
    fail "rc=$rc1, $rc2" "$msg $msg2"
fi
no_new_request "$before"

echo "=== a PDF with a content security policy that reports ==="
# The one case where the site can see something: the browser sends the violation report itself.
open_tab csp.pdf
if shows csp.pdf application/pdf; then
    before=$(requests)
    msg=$("$SB" save-pdf "$OUT/p.pdf" --url "127.0.0.1:$PORT/csp.pdf" 2>&1); rc=$?
    sleep 1
    if [[ $rc -eq 0 ]]; then
        cmp -s "$OUT/p.pdf" "$WORK/www/csp.pdf" && pass "not blocked: saved exactly" || fail "exit 0 with different bytes"
    elif [[ "$msg" == *"does not hold the whole document"* && ! -e "$OUT/p.pdf" ]]; then
        pass "blocked: it fails, says why, and writes nothing"
    else
        fail "rc=$rc: $msg"
    fi
    no_new_request "$before"
    note "violation reports the server received: $(grep -c '^POST /report' "$LOG")"
fi

echo "=== refusals ==="
open_tab plain.html
shows plain.html text/html
before=$(requests)
msg=$("$SB" save-pdf "$OUT/c.pdf" --url "127.0.0.1:$PORT/plain.html" 2>&1); rc=$?
[[ $rc -eq 1 && "$msg" == *"text/html"* && ! -e "$OUT/c.pdf" ]] && pass "an HTML page is refused" || fail "rc=$rc: $msg"
no_new_request "$before"
echo old > "$OUT/d.pdf"
"$SB" save-pdf "$OUT/d.pdf" --url "127.0.0.1:$PORT/nostore.pdf" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 && "$(cat "$OUT/d.pdf")" == "old" ]] && pass "an existing file is kept" || fail "rc=$rc"

echo "=== a PDF still loading ==="
open_tab slow/drip.pdf
sleep 2
before=$(requests)
msg=$("$SB" save-pdf "$OUT/s.pdf" --url "127.0.0.1:$PORT/slow/drip.pdf" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then
    cmp -s "$OUT/s.pdf" "$WORK/www/slow/drip.pdf" && pass "saved whole" || fail "exit 0 with a partial file"
elif [[ "$msg" == *"not running scripts"* && ! -e "$OUT/s.pdf" ]]; then
    pass "it says the tab is not running scripts, and writes nothing"
else
    fail "rc=$rc: the README says it reports a tab that runs no scripts" "$msg"
fi
no_new_request "$before"
shows slow/drip.pdf application/pdf
sleep 8
rm -f "$OUT/s.pdf"
msg=$("$SB" save-pdf "$OUT/s.pdf" --url "127.0.0.1:$PORT/slow/drip.pdf" 2>&1); rc=$?
[[ $rc -eq 0 ]] && cmp -s "$OUT/s.pdf" "$WORK/www/slow/drip.pdf" && pass "saved whole once it had loaded" || fail "rc=$rc: $msg"

echo "=== 50 MB ==="
open_tab nostore50.pdf
shows nostore50.pdf application/pdf
sleep 3
before=$(requests)
start=$(date +%s)
"$SB" save-pdf "$OUT/e.pdf" --url "127.0.0.1:$PORT/nostore50.pdf" >/dev/null 2>&1; rc=$?
echo "  (50 MB took $(( $(date +%s) - start )) s)"
[[ $rc -eq 0 ]] && cmp -s "$OUT/e.pdf" "$WORK/www/nostore50.pdf" && pass "50 MB saved exactly" || fail "exit $rc or bytes differ"
no_new_request "$before"

echo "=== a linearized PDF from a server that answers byte ranges ==="
# Publishers' CDNs do. Either the file is exact or the command refuses; a partial file is the wrong answer.
if [[ -e "$WORK/www/ranged/big.pdf" ]]; then
    open_tab ranged/big.pdf
    shows ranged/big.pdf application/pdf
    before=$(settled_requests)
    ranges=$(grep -c 'ranged/big.pdf bytes=' "$LOG")
    note "displaying it took $ranges range request(s)"
    msg=$("$SB" save-pdf "$OUT/r.pdf" --url "127.0.0.1:$PORT/ranged/big.pdf" 2>&1); rc=$?
    if [[ $rc -eq 0 ]] && ! cmp -s "$OUT/r.pdf" "$WORK/www/ranged/big.pdf"; then
        fail "exit 0 with different bytes"
    elif [[ $rc -ne 0 && -e "$OUT/r.pdf" ]]; then
        fail "exit $rc left a file" "$msg"
    elif [[ "$ranges" -eq 0 ]]; then
        note "Safari asked for no range here, so this case measured nothing about ranges (rc=$rc)"
    elif [[ $rc -eq 0 ]]; then
        pass "saved whole"
    else
        pass "refused and wrote nothing: $msg"
    fi
    no_new_request "$before"
else
    note "qpdf is not installed, so there is no linearized fixture; byte ranges not measured"
fi

echo "=== PDF tabs a service worker controls (#390) ==="
# Without --allow-service-worker a controlled tab is refused before the fetch. With it, the read the service
# worker could see but did not: a PDF document fetching its own URL. Each worker reports every fetch event to
# /sw-saw, and requests() counts the reports of PDF fetches, so a worker that saw a read fails the "no request"
# line. The navigation report is the positive control for that; the replaced address below is the positive
# control for the verdict.
for scope in pass net; do
    WORKERS_REGISTERED=1
    open_tab "sw-$scope/index.html"
    state=""
    for i in $(seq 1 40); do
        state=$("$SB" js "(document.getElementById('s') ? document.getElementById('s').textContent : '') + '|' + !!(navigator.serviceWorker && navigator.serviceWorker.controller)" --url "127.0.0.1:$PORT/sw-$scope/index.html" 2>/dev/null)
        [[ "$state" == "ready|true" ]] && break
        sleep 0.5
    done
    [[ "$state" == "ready|true" ]] || { fail "$scope: the service worker never took control of its page ($state)"; continue; }
    "$SB" js "location.href = '/sw-$scope/doc.pdf'; 1" --url "127.0.0.1:$PORT/sw-$scope/index.html" >/dev/null 2>&1
    shows "sw-$scope/doc.pdf" application/pdf || continue
    controlled=$("$SB" js 'String(!!(navigator.serviceWorker && navigator.serviceWorker.controller))' --url "127.0.0.1:$PORT/sw-$scope/doc.pdf" 2>/dev/null)
    [[ "$controlled" == "true" ]] || { fail "$scope: the PDF tab is not controlled, so this case means nothing"; continue; }
    grep -q "^GET /sw-saw?scope=$scope&mode=navigate" "$LOG" && pass "$scope: the service worker reported the navigation it handled" \
        || { fail "$scope: no report of the navigation, so the reports below mean nothing" "$(grep sw- "$LOG" | tail -3)"; continue; }
    before=$(settled_requests)
    msg=$("$SB" save-pdf "$OUT/sw-$scope-refused.pdf" --url "127.0.0.1:$PORT/sw-$scope/doc.pdf" 2>&1); rc=$?
    [[ $rc -eq 1 && "$msg" == *"A service worker controls this tab"* && ! -e "$OUT/sw-$scope-refused.pdf" ]] \
        && pass "$scope: without the flag it is refused and writes nothing" || fail "$scope: rc=$rc" "$msg"
    flush_through_worker "$scope" "sw-$scope/doc.pdf" && no_new_request "$before"
    json=$("$SB" save-pdf "$OUT/sw-$scope.pdf" --allow-service-worker --url "127.0.0.1:$PORT/sw-$scope/doc.pdf" --json 2>&1); rc=$?
    [[ $rc -eq 0 ]] && cmp -s "$OUT/sw-$scope.pdf" "$WORK/www/sw-$scope/doc.pdf" && pass "$scope: with the flag, saved exactly" || fail "$scope: rc=$rc" "$json"
    echo "$json" | grep -q '"service_worker" : "not-seen"' && pass "$scope: the verdict is not-seen" || fail "$scope: verdict: $json"
    flush_through_worker "$scope" "sw-$scope/doc.pdf" && no_new_request "$before"
    # Only the network worker can answer an address WebKit never loaded: the pass worker forwards only-if-cached.
    [[ "$scope" == net ]] || continue
    "$SB" js "history.replaceState(null, '', '/sw-net/doc.pdf?v=2'); 1" --url "127.0.0.1:$PORT/sw-net/doc.pdf" >/dev/null 2>&1
    before=$(settled_requests)
    msg=$("$SB" save-pdf "$OUT/sw-seen-refused.pdf" --url "127.0.0.1:$PORT/sw-net/doc.pdf?v=2" 2>&1); rc=$?
    [[ $rc -eq 1 && "$msg" == *"A service worker controls this tab"* && ! -e "$OUT/sw-seen-refused.pdf" ]] \
        && pass "net, address never loaded: without the flag it is refused" || fail "net, address never loaded: rc=$rc" "$msg"
    flush_through_worker net "sw-net/doc.pdf?v=2" && { grep -q '^GET /sw-net/doc.pdf?v=2' "$LOG" \
        && fail "net, address never loaded: the server got the read without the flag" || pass "net, address never loaded: no request without the flag"; }
    json=$("$SB" save-pdf "$OUT/sw-seen.pdf" --allow-service-worker --url "127.0.0.1:$PORT/sw-net/doc.pdf?v=2" --json 2>&1); rc=$?
    [[ $rc -eq 0 ]] && cmp -s "$OUT/sw-seen.pdf" "$WORK/www/sw-net/doc.pdf" && pass "net, address never loaded: with the flag, saved what the server sent" || fail "net, address never loaded: rc=$rc" "$json"
    echo "$json" | grep -q '"service_worker" : "seen"' && pass "net, address never loaded: the verdict is seen" || fail "net, address never loaded: verdict: $json"
    grep -q '^GET /sw-net/doc.pdf?v=2' "$LOG" && pass "net, address never loaded: the service worker asked the server" || fail "net, address never loaded: no request reached the server"
done
[[ -n "$WORKERS_REGISTERED" ]] && unregister_workers

echo ""
echo "passed: $passed  failed: $failed"
[[ $failed -eq 0 ]]
