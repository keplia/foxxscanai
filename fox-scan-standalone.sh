#!/usr/bin/env bash
# fox-scan.sh — SELF-CONTAINED single file. Cukup kirim file ini ke server.
#   bash fox-scan.sh -m all
#   bash fox-scan.sh -m hunt -s https://lazu.ai,https://orcarouter.ai
#   bash fox-scan.sh -m probe -b https://api.orcarouter.ai/v1 -k sk-xxx
# Python 3 stdlib only — tanpa pip install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"
export FOX_ROOT="${FOX_ROOT:-$SCRIPT_DIR}"
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY="python"
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "[fox] python3 tidak ditemukan. install: sudo apt install -y python3" >&2
  exit 2
fi

TMP="${TMPDIR:-/tmp}/foxscan_$$_$(date +%s).py"
cat >"$TMP" <<'FOX_PY_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse, concurrent.futures, csv, glob, io, json, os, re, socket, ssl, sys, time
import urllib.parse, urllib.request, urllib.error, zipfile

ROOT = os.environ.get("FOX_ROOT") or os.path.expanduser("~/.config/opencode/foxxscanai")
REPORTS = os.path.join(ROOT, "reports")
CACHE = os.path.join(ROOT, "cache", "tmp")
LOGSDIR = os.path.join(ROOT, "logs")
for d in (REPORTS, CACHE, LOGSDIR):
    try:
        os.makedirs(d, exist_ok=True)
    except Exception:
        pass

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")

SEEDS = """
gptgod.cloud api1.zhtec.xyz chienapi.top 35.aigcbest.top new.xjai.cc api.bltcy.ai gptapi.us xeduapi.com
api.tomchat.fun api.v3.cm api.ephone.ai api.nekoapi.com go.sbgpt.site ggwk1.online api.openai-ch.top
oneapi.paintbot.top api.chatfire.cn fastapi.aabao.vip api.aabao.top opus.gptuu.com open.api.gu28.top
api.yuegle.com cnapi.kksj.org api.gptoai.cc kfcv50.link api.nio.gs api.gueai.com openai-labs.com
azapi.com.cn chatapi.onechats.top apipro.maynor1024.live api.996444.cn new.yunai.link open.xiaojingai.com
mnapi.com yunwu.ai zen-ai.top new.gptgod.cloud api.52pay.com ppio.com api.oaipro.com api.chatanywhere.tech
aihubmix.com api2d.com deepbricks.ai dmnode.com siliconflow.cn gpt.ge ablai.top b3n.fun 132999.xyz
minekuai.cn zhiyunapi.cc zhiyunapi.org yuqing-suluokk.com tcbmc.cc beijixingxing.com
lazu.ai newapi.sohym.com api.bowlslastore.online ai.0316666.xyz ai.shuixingyun.com api.icloud99.cn
api.hust.xx.kg api.maisi-ai.net api.hiapi.ai ai.ivtin.cn api.sunwenda.com apinext.net api.wodobuddy.vip
callanyai.com code2cc.pages.dev cloudcore.icu cf-ai.mnxai.top aqcompu.aisec365.com ccai123.top
datang.zhongnianfu.com megaviews.top infapi.cc new.xcodexs.com newapi.pmcstation.com
newapicq.freedom.nyc.mn newapi.tsingzhancloud.com newai.cmiteam.cn panel.trust-api.ru plan.popsmart.cn
zhenx.ai 5208.ai olinkdata.cn api.open.xiaojingai.com api.zhenx.ai ultrarouter.ai orcarouter.ai
linkapi.ai getunikey.ai openlux.ai packyapi.ai cctq.ai
""".split()

URLSCAN_RELAY = ['page.title:"New API"', 'page.title:"One API"', 'page.title:"Done Hub"',
                 'page.title:"NewAPI"', 'page.title:"AI API"',
                 'filename:"deepseek-v4.1-flash"', 'filename:"deepseek-flash"',
                 'filename:"deepseek-v4.1-flash-1017"']
URLSCAN_AI = ['page.title:"New API" AND page.domain:ai', 'page.title:"One API" AND page.domain:ai',
              'page.title:"AI API" AND page.domain:ai', 'filename:"deepseek-flash" AND page.domain:ai']
BAIDU_Q = ["deepseek-v4.1-flash 免费 api", "deepseek v4.1 flash 公益站", "newapi 公益站 免费",
           "api 中转站 免费额度 deepseek", "deepseek api 中转 注册送", "oneapi 站点 免费 key"]

def http(url, data=None, timeout=8, headers=None):
    h = {"User-Agent": UA, "Accept": "application/json,text/html,*/*",
         "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=data, headers=h,
                                 method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception:
            return e.code, ""
    except Exception:
        return 0, ""

def norm_host(u):
    if not u:
        return ""
    if "://" not in u:
        u = "https://" + u
    try:
        h = urllib.parse.urlparse(u).hostname or ""
    except Exception:
        return ""
    h = h.lower()
    return h[4:] if h.startswith("www.") else h

def urlscan(queries, pages=3):
    out = set()
    for q in queries:
        after = None
        for _ in range(pages):
            params = {"q": q, "size": 100}
            if after:
                params["search_after"] = json.dumps(after)
            st, body = http("https://urlscan.io/api/v1/search?" + urllib.parse.urlencode(params), timeout=25)
            if st != 200:
                break
            try:
                j = json.loads(body)
            except Exception:
                break
            res = j.get("results") or []
            if not res:
                break
            for x in res:
                h = norm_host((x.get("page") or {}).get("url"))
                if h and "." in h:
                    out.add(h)
            after = res[-1].get("sort")
        print("  [urlscan] %s -> total %d" % (q, len(out)), flush=True)
    return out

def baidu():
    out = set()
    for q in BAIDU_Q:
        st, body = http("https://www.baidu.com/s?" + urllib.parse.urlencode({"wd": q}), timeout=15)
        if st != 200 or "验证码" in body:
            print("  [baidu] blocked: %s" % q, flush=True)
            continue
        for m in re.findall(r"https?://([a-zA-Z0-9\-\.]+)", body):
            m = m.lower()
            if "." in m and len(m) < 60 and not re.search(
                    r"(baidu|qq\.com|zhihu|csdn|bilibili|weibo|sohu|163\.com|toutiao|douyin|"
                    r"github|wikipedia|youtube|twitter|cloudflare|google|microsoft|apple|amazon|"
                    r"aliyun|tencent|huawei|sina|ifeng|cnblogs|juejin|oschina|51cto|runoob|php\.cn)", m):
                out.add(m)
        print("  [baidu] %s -> total %d" % (q, len(out)), flush=True)
        time.sleep(1.5)
    return out

def tranco_ai():
    path = os.path.join(CACHE, "tranco.zip")
    try:
        if not os.path.exists(path) or os.path.getsize(path) < 100000:
            req = urllib.request.Request("https://tranco-list.eu/top-1m.csv.zip", headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=120, context=CTX) as r:
                open(path, "wb").write(r.read())
        z = zipfile.ZipFile(path)
        name = z.namelist()[0]
        out = set()
        for row in csv.reader(io.TextIOWrapper(z.open(name), encoding="utf-8")):
            if len(row) > 1 and row[1].endswith(".ai"):
                out.add(row[1].lower())
        print("  [tranco] .ai %d" % len(out), flush=True)
        return out
    except Exception as e:
        print("  [tranco] skip: %s" % e, flush=True)
        return set()

def probe(host, timeout=6):
    r = {"host": host, "url": None, "price": None, "free": False,
         "models": [], "has1017": False}
    for scheme in ("https", "http"):
        base = "%s://%s" % (scheme, host)
        st, body = http(base + "/api/pricing", timeout=timeout)
        if st != 200 or not body.lstrip().startswith("{"):
            continue
        try:
            j = json.loads(body)
        except Exception:
            continue
        data = j.get("data") or []
        if isinstance(data, dict):
            data = data.get("models") or []
        hits, ratios, free = [], [], False
        for m in data:
            mn = str(m.get("model_name", ""))
            low = mn.lower()
            if "deepseek" not in low or not ("4.1" in low or "flash" in low):
                continue
            hits.append(mn)
            if "1017" in low:
                r["has1017"] = True
            try:
                mr = float(m.get("model_ratio") or 0)
                mp = float(m.get("model_price") or 0)
                if mr > 0:
                    ratios.append(mr * 2.0)
                if mr == 0 and mp == 0:
                    free = True
            except Exception:
                pass
        if hits:
            r.update(url=base, models=hits[:8], free=free,
                     price=round(min(ratios), 4) if ratios else None)
            return r
    return r

def load_prev():
    hits = {}
    for f in (glob.glob(os.path.join(REPORTS, "relay_discovery_*.json")) +
              glob.glob(os.path.join(REPORTS, "ai_tld_discovery_*.json")) +
              glob.glob(os.path.join(REPORTS, "global_deepseek_targets_*.json"))):
        try:
            j = json.load(open(f, encoding="utf-8"))
            arr = j.get("results") or j.get("all") or j.get("rows") or []
            for x in arr:
                h = norm_host(x.get("url") or x.get("host"))
                if h and x.get("models"):
                    hits.setdefault(h, x)
        except Exception:
            pass
    return hits

def save_rank(rows):
    ts = time.strftime("%Y%m%d_%H%M%S")
    jf = os.path.join(REPORTS, "global_deepseek_targets_%s.json" % ts)
    mf = os.path.join(REPORTS, "global_deepseek_targets_%s.md" % ts)
    json.dump({"generated": ts, "total": len(rows), "free": sum(1 for r in rows if r["free"]),
               "rows": rows}, open(jf, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    with open(mf, "w", encoding="utf-8") as f:
        f.write("# GLOBAL DEEPSEEK V4.1-FLASH TARGETS\n> %s | total %d | free %d\n\n" %
                (ts, len(rows), sum(1 for r in rows if r["free"])))
        f.write("| # | host | free | $/M | 1017 | models |\n|---|---|---|---|---|---|\n")
        for i, r in enumerate(rows[:150], 1):
            f.write("| %d | %s | %s | %s | %s | %s |\n" % (
                i, r["url"], "YES" if r["free"] else "", r["price"],
                "YES" if r["has1017"] else "", ", ".join(r["models"][:3])))
    return jf, mf

def scan(hosts, workers=100):
    hits = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(probe, h): h for h in hosts}
        done = 0
        for f in concurrent.futures.as_completed(futs):
            done += 1
            x = f.result()
            if x["models"]:
                hits[x["host"]] = x
                print("  HIT %s free=%s $%s %s" % (x["url"], x["free"], x["price"], x["models"][:2]), flush=True)
            if done % 500 == 0:
                print("  ... %d/%d probed (hits %d)" % (done, len(hosts), len(hits)), flush=True)
    return hits

def rows_from(hits):
    rows = []
    for h, x in hits.items():
        rows.append({"host": h, "url": x.get("url") or ("https://" + h),
                     "price": x.get("price"), "free": bool(x.get("free")),
                     "has1017": bool(x.get("has1017")), "models": x.get("models") or []})
    rows.sort(key=lambda r: (not r["free"], r["price"] if r["price"] is not None else 999, r["host"]))
    return rows

def print_rows(rows, n=30):
    print("\n%-5s %-8s %-38s %s" % ("FREE", "$/M", "HOST", "MODELS"))
    for r in rows[:n]:
        print("%-5s %-8s %-38s %s" % ("YES" if r["free"] else "", r["price"], r["url"],
                                      ", ".join(r["models"][:3])))

def do_all(args):
    d = set(SEEDS)
    if args.baidu:
        d |= baidu()
    d |= urlscan(URLSCAN_RELAY, args.pages)
    if args.ai:
        t = tranco_ai()
        d |= t
        d |= urlscan(URLSCAN_AI, args.pages)
    print("[probe] %d kandidat" % len(d), flush=True)
    hits = scan(list(d)[:args.limit], args.workers)
    prev = load_prev()
    prev.update(hits)
    rows = rows_from(prev)
    jf, mf = save_rank(rows)
    print("\nDONE total=%d free=%d" % (len(rows), sum(1 for r in rows if r["free"])))
    print_rows(rows)
    print("saved: %s" % mf)

def do_ai(args):
    d = urlscan(URLSCAN_AI, args.pages) | tranco_ai()
    d |= {h for h in SEEDS if h.endswith(".ai")}
    print("[probe] %d host .ai" % len(d), flush=True)
    hits = scan(sorted(d)[:args.limit], args.workers)
    rows = rows_from(hits)
    jf, mf = save_rank(rows)
    print("\nDONE .ai total=%d free=%d" % (len(rows), sum(1 for r in rows if r["free"])))
    print_rows(rows)
    print("saved: %s" % mf)

def do_hunt(args):
    sites = []
    for s in args.sites or []:
        for part in str(s).split(","):
            part = part.strip()
            if part:
                sites.append(part if "://" in part else "https://" + part)
    if not sites:
        print("butuh -s url1,url2", file=sys.stderr)
        return
    for u in sites:
        base = u.rstrip("/")
        st, body = http(base + "/api/pricing", timeout=10)
        print("=== %s (HTTP %s)" % (base, st))
        if st == 200 and body.lstrip().startswith("{"):
            try:
                data = json.loads(body).get("data") or []
            except Exception:
                data = []
            if isinstance(data, dict):
                data = data.get("models") or []
            found = 0
            for m in data:
                n = str(m.get("model_name", ""))
                low = n.lower()
                if "deepseek" in low and ("4.1" in low or "flash" in low):
                    found += 1
                    mr = m.get("model_ratio")
                    mp = m.get("model_price")
                    price = ("%.4f" % (float(mr) * 2)) if mr not in (None, 0) else ("free" if mp in (None, 0) else "per-call")
                    print("   %-45s ratio=%-8s price=%-8s $/M=%s" % (n, mr, mp, price))
            if not found:
                print("   (tidak ada model deepseek v4.1/flash)")
        # notice / hint
        for ep in ("/api/notice", "/api/status"):
            s2, b2 = http(base + ep, timeout=6)
            if s2 == 200 and b2.strip() and b2.strip() not in ("{}", ""):
                txt = re.sub(r"\s+", " ", b2)[:200]
                if ep.endswith("notice") and ('""' in txt or "data\":\"\"" in txt):
                    continue
                print("   [%s] %s" % (ep, txt))

def do_probe(args):
    base = args.base.rstrip("/")
    key = args.key or ""
    model = args.model or "deepseek-v4.1-flash-1017"
    print("[+] base=%s model=%s" % (base, model))
    st, body = http(base + "/models", timeout=20, headers={"Authorization": "Bearer " + key})
    print("[1] /models -> %s" % st)
    if st == 200:
        try:
            ids = [m.get("id") for m in json.loads(body).get("data", [])]
            print("    %d models | deepseek: %s" % (len(ids), [i for i in ids if "deepseek" in str(i).lower()][:8]))
        except Exception:
            print("    " + body[:200])
    payload = json.dumps({"model": model,
                          "messages": [{"role": "user", "content": "State your exact model name and vendor in max 12 words."}],
                          "temperature": 0, "max_tokens": 40}).encode()
    t0 = time.time()
    st, body = http(base + "/chat/completions", data=payload, timeout=60,
                    headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    dt = time.time() - t0
    print("[2] chat -> %s (%.2fs)" % (st, dt))
    if st == 200:
        try:
            j = json.loads(body)
            print("    answer: " + j["choices"][0]["message"]["content"].strip().replace("\n", " ")[:120])
            print("    usage : %s" % j.get("usage"))
        except Exception:
            print("    " + body[:300])
    else:
        print("    " + body[:300])
    payload = json.dumps({"model": model,
                          "messages": [{"role": "user", "content": "Compute exactly 7823*19. Reply number only."}],
                          "temperature": 0, "max_tokens": 20}).encode()
    st, body = http(base + "/chat/completions", data=payload, timeout=60,
                    headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    ok = ""
    if st == 200:
        try:
            out = json.loads(body)["choices"][0]["message"]["content"].strip()
            ok = "OK" if "148637" in out.replace(",", "").replace(" ", "") else "MISMATCH"
            print("[3] math -> %s answer=%s" % (ok, out[:30]))
        except Exception:
            print("[3] math parse fail")
    print("[4] latency x3:")
    for i in range(3):
        t0 = time.time()
        s3, _ = http(base + "/chat/completions",
                     data=json.dumps({"model": model, "messages": [{"role": "user", "content": "hi"}],
                                      "max_tokens": 5}).encode(),
                     timeout=30, headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
        print("    #%d status=%s %.2fs" % (i + 1, s3, time.time() - t0))

def do_top(args):
    files = sorted(glob.glob(os.path.join(REPORTS, "global_deepseek_targets_*.json")))
    if not files:
        print("belum ada hasil. jalankan: bash fox-scan.sh -m all", file=sys.stderr)
        return
    j = json.load(open(files[-1], encoding="utf-8"))
    print("== %s | total=%s free=%s" % (os.path.basename(files[-1]), j.get("total"), j.get("free")))
    print_rows(j.get("rows") or [], 40)

def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("-m", "--mode", default="all",
                    choices=["all", "relays", "ai", "hunt", "probe", "top"])
    ap.add_argument("-s", "--sites", nargs="*", default=[])
    ap.add_argument("-b", "--base", default="")
    ap.add_argument("-k", "--key", default="")
    ap.add_argument("--model", default="deepseek-v4.1-flash-1017")
    ap.add_argument("--pages", type=int, default=3)
    ap.add_argument("--limit", type=int, default=4000)
    ap.add_argument("--workers", type=int, default=100)
    ap.add_argument("--baidu", action="store_true")
    ap.add_argument("--ai", action="store_true", help="mode all: ikut scan .ai")
    args = ap.parse_args()
    print("[fox] root=%s mode=%s" % (ROOT, args.mode), flush=True)
    if args.mode == "all":
        args.ai = True
        do_all(args)
    elif args.mode == "relays":
        args.ai = False
        do_all(args)
    elif args.mode == "ai":
        do_ai(args)
    elif args.mode == "hunt":
        do_hunt(args)
    elif args.mode == "probe":
        do_probe(args)
    elif args.mode == "top":
        do_top(args)

if __name__ == "__main__":
    main()
FOX_PY_EOF

"$PY" -u "$TMP" "$@"
rc=$?
rm -f "$TMP"
exit $rc
