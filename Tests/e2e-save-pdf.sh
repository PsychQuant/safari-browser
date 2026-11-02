#!/bin/bash
# e2e-save-pdf.sh — live-Safari test for `save-pdf` (#338).
#
# What only a real Safari can show: `fetch(..., {cache: 'only-if-cached'})` reads a `no-store` PDF
# from memory and sends nothing. A local server logs every request, so "no request" is measured.
#
# It opens a Safari window of its own, in the foreground, so it does not run by accident: it refuses
# unless E2E_SAVE_PDF_OK=1, and it prints what is open first. Do not run it during a call.
#
# Exit 77 (automake skip) when Safari is not running or the guard is not set.

set -u
SB="${SAFARI_BROWSER_BIN:-.build/debug/safari-browser}"
PORT="${E2E_SAVE_PDF_PORT:-38339}"
WORK="$(mktemp -d)"
SERVER_PID=""
passed=0
failed=0

pass() { passed=$((passed + 1)); echo "  ✓ $1"; }
fail() { failed=$((failed + 1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }

cleanup() {
    for name in nostore.pdf nostore50.pdf background.pdf plain.html; do
        "$SB" close --url "127.0.0.1:$PORT/$name" 2>/dev/null || true
    done
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

pgrep -x Safari >/dev/null || { echo "Safari is not running; skipping"; exit 77; }
echo "=== open in Safari now (scheme and host only) ==="
"$SB" documents 2>/dev/null | sed -E 's#(https?://[^/ ]+).*#\1/…#'
if [[ "${E2E_SAVE_PDF_OK:-}" != "1" ]]; then
    echo "This test opens a Safari window in the foreground. Set E2E_SAVE_PDF_OK=1 to run it."
    exit 77
fi

mkdir -p "$WORK/www"
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
for name, size in (("nostore.pdf", 250_000), ("background.pdf", 250_000), ("nostore50.pdf", 50 * 1024 * 1024)):
    open(os.path.join(root, name), "wb").write(pdf(size))
open(os.path.join(root, "plain.html"), "w").write("<!doctype html><title>plain</title><p>not a pdf")
PY
cat > "$WORK/serve.py" <<'PY'
import http.server, sys
root, log, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=root, **k)
    def end_headers(self):
        self.send_header("Cache-Control", "no-store"); super().end_headers()
    def log_message(self, fmt, *args):
        if "favicon" not in self.path:
            open(log, "a").write(self.command + " " + self.path + "\n")
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
LOG="$WORK/requests.log"; : > "$LOG"
python3 -I "$WORK/serve.py" "$WORK/www" "$LOG" "$PORT" &
SERVER_PID=$!
sleep 1
requests() { wc -l < "$LOG" | tr -d ' '; }
base="http://127.0.0.1:$PORT"
OUT="$WORK/out"; mkdir -p "$OUT"

echo "=== a no-store PDF ==="
"$SB" open --new-window "$base/nostore.pdf" >/dev/null 2>&1
"$SB" wait 2500 >/dev/null 2>&1
before=$(requests)
json=$("$SB" save-pdf "$OUT/a.pdf" --url "127.0.0.1:$PORT/nostore.pdf" --json 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] && pass "exit 0" || fail "exit $rc"
cmp -s "$OUT/a.pdf" "$WORK/www/nostore.pdf" && pass "bytes are identical" || fail "bytes differ"
[[ "$(requests)" == "$before" ]] && pass "no request reached the server" || fail "the server got $(( $(requests) - before )) request(s)"
echo "$json" | grep -q '"source" : "tab"' && pass "--json says source tab" || fail "--json: $json"

echo "=== a background tab ==="
"$SB" open --new-tab "$base/background.pdf" --window 1 >/dev/null 2>&1
"$SB" wait 2500 >/dev/null 2>&1
"$SB" tab 1 --window 1 >/dev/null 2>&1
current_before=$("$SB" get url --window 1 2>/dev/null)
before=$(requests)
"$SB" save-pdf "$OUT/b.pdf" --url "127.0.0.1:$PORT/background.pdf" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$OUT/b.pdf" "$WORK/www/background.pdf" && pass "saved from a background tab" || fail "exit $rc or bytes differ"
[[ "$("$SB" get url --window 1 2>/dev/null)" == "$current_before" ]] && pass "the current tab did not change" || fail "the current tab changed"
[[ "$(requests)" == "$before" ]] && pass "no request" || fail "a request reached the server"

echo "=== refusals ==="
"$SB" open --new-tab "$base/plain.html" --window 1 >/dev/null 2>&1
"$SB" wait 1500 >/dev/null 2>&1
before=$(requests)
msg=$("$SB" save-pdf "$OUT/c.pdf" --url "127.0.0.1:$PORT/plain.html" 2>&1); rc=$?
[[ $rc -eq 1 && "$msg" == *"text/html"* && ! -e "$OUT/c.pdf" ]] && pass "an HTML page is refused" || fail "rc=$rc: $msg"
[[ "$(requests)" == "$before" ]] && pass "no request" || fail "a request reached the server"
echo old > "$OUT/d.pdf"
"$SB" save-pdf "$OUT/d.pdf" --url "127.0.0.1:$PORT/nostore.pdf" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 && "$(cat "$OUT/d.pdf")" == "old" ]] && pass "an existing file is kept" || fail "rc=$rc"

echo "=== 50 MB ==="
"$SB" open --new-tab "$base/nostore50.pdf" --window 1 >/dev/null 2>&1
"$SB" wait 4000 >/dev/null 2>&1
before=$(requests)
start=$(date +%s)
"$SB" save-pdf "$OUT/e.pdf" --url "127.0.0.1:$PORT/nostore50.pdf" >/dev/null 2>&1; rc=$?
echo "  (50 MB took $(( $(date +%s) - start )) s)"
[[ $rc -eq 0 ]] && cmp -s "$OUT/e.pdf" "$WORK/www/nostore50.pdf" && pass "50 MB saved exactly" || fail "exit $rc or bytes differ"
[[ "$(requests)" == "$before" ]] && pass "no request" || fail "a request reached the server"

echo ""
echo "passed: $passed  failed: $failed"
[[ $failed -eq 0 ]]
