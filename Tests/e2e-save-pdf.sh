#!/bin/bash
# e2e-save-pdf.sh — live-Safari test for `save-pdf` (#338).
#
# What only a real Safari can show: `fetch(..., {cache: 'only-if-cached'})` reads a `no-store` PDF
# from memory and sends nothing. A local server logs every request, so "no request" is measured.
#
# It opens a Safari window of its own, which takes the foreground, so nothing here touches Safari
# unless you set E2E_SAVE_PDF_OK=1. Set it yourself, when a new window is fine (not during a call),
# with a window of the profile you want in front: the new window takes that one's profile. After that
# every step addresses the fixture's URL or the new window's id, never a window's position, and the
# only thing it closes is that window.
#
# Exit 77 (automake skip) when the guard is not set or Safari is not running.

set -u
if [[ "${E2E_SAVE_PDF_OK:-}" != "1" ]]; then
    echo "This test opens a Safari window in the foreground. Set E2E_SAVE_PDF_OK=1 to run it."
    exit 77
fi
pgrep -x Safari >/dev/null || { echo "Safari is not running; skipping"; exit 77; }

SB="${SAFARI_BROWSER_BIN:-.build/debug/safari-browser}"
PORT="${E2E_SAVE_PDF_PORT:-38339}"
WORK="$(mktemp -d)"
SERVER_PID=""
WINDOW=""
passed=0
failed=0

pass() { passed=$((passed + 1)); echo "  ✓ $1"; }
fail() { failed=$((failed + 1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

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
    [[ -n "$WINDOW" ]] && osascript -e "tell application \"Safari\" to close window id $WINDOW" >/dev/null 2>&1
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/www/ranged"
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
for name, size in (("nostore.pdf", 250_000), ("background.pdf", 250_000), ("notheld.pdf", 250_000),
                   ("nostore50.pdf", 50 * 1024 * 1024), ("ranged/big.pdf", 50 * 1024 * 1024)):
    open(os.path.join(root, name), "wb").write(pdf(size))
open(os.path.join(root, "plain.html"), "w").write("<!doctype html><title>plain</title><p>not a pdf")
PY
cat > "$WORK/serve.py" <<'PY'
import http.server, re, sys
root, log, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=root, **k)
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        if self.path.startswith("/ranged/"): self.send_header("Accept-Ranges", "bytes")
        super().end_headers()
    def do_GET(self):
        m = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
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
base="http://127.0.0.1:$PORT"
OUT="$WORK/out"; mkdir -p "$OUT"
front_app() { lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null; }
current_url() { osascript -e "tell application \"Safari\" to get URL of current tab of window id $WINDOW" 2>/dev/null; }
# A new tab made this way stays in the background.
open_tab() { osascript -e "tell application \"Safari\" to tell window id $WINDOW to make new tab at end of tabs with properties {URL:\"$base/$1\"}" >/dev/null 2>&1; }
shows() { # shows <path> <content type>: wait until the tab's document has that type
    local i
    for i in $(seq 1 60); do
        [[ "$("$SB" js 'document.contentType' --url "127.0.0.1:$PORT/$1" 2>/dev/null)" == "$2" ]] && { sleep 1; return 0; }
        sleep 0.5
    done
    fail "$1 never showed as $2"; return 1
}
no_new_request() { [[ "$(requests)" == "$1" ]] && pass "no request reached the server" || fail "the server got $(( $(requests) - $1 )) request(s)" "$(tail -3 "$LOG")"; }

echo "Safari has $(osascript -e 'tell application "Safari" to count windows' 2>/dev/null) window(s) open; this test adds one."

echo "=== a no-store PDF ==="
"$SB" open --new-window "$base/nostore.pdf" >/dev/null 2>&1
sleep 1
WINDOW="$(fixture_window)"
[[ -n "$WINDOW" ]] || { fail "the fixture window did not open"; exit 1; }
shows nostore.pdf application/pdf
# Without this every "no request" below passes on a log that records nothing.
grep -q '^GET /nostore.pdf' "$LOG" && pass "the server logged the request that displayed the PDF" \
    || { fail "the log has no GET for the displayed PDF; nothing below would mean anything"; exit 1; }
before=$(requests); front=$(front_app)
json=$("$SB" save-pdf "$OUT/a.pdf" --url "127.0.0.1:$PORT/nostore.pdf" --json 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] && pass "exit 0" || fail "exit $rc"
cmp -s "$OUT/a.pdf" "$WORK/www/nostore.pdf" && pass "bytes are identical" || fail "bytes differ"
no_new_request "$before"
[[ "$(front_app)" == "$front" ]] && pass "the frontmost application did not change" || fail "the frontmost application changed (did you switch?)"
echo "$json" | grep -q '"source" : "tab"' && pass "--json says source tab" || fail "--json: $json"

echo "=== a background tab ==="
open_tab background.pdf
shows background.pdf application/pdf
current_before=$(current_url); before=$(requests); front=$(front_app)
[[ "$current_before" != *background.pdf* ]] && pass "the tab really is in the background" || fail "the new tab became current"
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
[[ $rc -eq 1 && "$msg" == *"No request was sent"* && ! -e "$OUT/n.pdf" ]] && pass "it fails and writes nothing" || fail "rc=$rc: $msg"
no_new_request "$before"

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

echo "=== without access to Safari's cache folder ==="
# sandbox-exec refuses with the EPERM TCC gives without Full Disk Access.
NOFDA="(version 1)(allow default)(deny file-read* (subpath \"$HOME/Library/Containers/com.apple.Safari/Data/Library/Caches\"))"
if sandbox-exec -p "$NOFDA" /usr/bin/true 2>/dev/null; then
    msg=$(sandbox-exec -p "$NOFDA" "$SB" save-pdf "$OUT/f.pdf" --url "127.0.0.1:$PORT/nostore.pdf" 2>&1); rc=$?
    [[ $rc -eq 0 ]] && cmp -s "$OUT/f.pdf" "$WORK/www/nostore.pdf" && pass "saved without reading that folder" || fail "rc=$rc: $msg"
else
    echo "  - sandbox-exec is not usable here; not checked"
fi

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

echo "=== 50 MB from a server that answers byte ranges ==="
# Publishers' CDNs do. Whether WebKit then holds the whole document is what this measures: either the
# file is exact or the command refuses; a partial file is the one wrong answer.
open_tab ranged/big.pdf
shows ranged/big.pdf application/pdf
sleep 3
echo "  (displaying it took $(grep -c 'ranged/big.pdf' "$LOG") request(s), $(grep -c 'ranged/big.pdf bytes=' "$LOG") with a Range header)"
before=$(requests)
msg=$("$SB" save-pdf "$OUT/r.pdf" --url "127.0.0.1:$PORT/ranged/big.pdf" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then
    cmp -s "$OUT/r.pdf" "$WORK/www/ranged/big.pdf" && pass "saved whole" || fail "exit 0 with different bytes"
elif [[ ! -e "$OUT/r.pdf" ]]; then
    pass "refused and wrote nothing: $msg"
else
    fail "exit $rc left a file" "$msg"
fi
no_new_request "$before"

echo ""
echo "passed: $passed  failed: $failed"
[[ $failed -eq 0 ]]
