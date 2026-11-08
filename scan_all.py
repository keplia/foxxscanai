#!/usr/bin/env python3
# scan_all.py — GLOBAL orchestrator: discover (urlscan paging + crt.sh + tranco + seeds)
#               -> probe /api/pricing -> merge all previous JSON -> global ranked target list
import glob, json, re, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import urlparse
import requests

requests.packages.urllib3.disable_warnings()
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36",
      "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"}
import os
ROOT = os.environ.get("FOX_ROOT") or os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
REP = os.path.join(ROOT, "reports")
CACHE_TRANCO = os.path.join(ROOT, "cache", "tmp", "opencode", "tranco.zip")
os.makedirs(REP, exist_ok=True)
os.makedirs(os.path.dirname(CACHE_TRANCO), exist_ok=True)

SEEDS = set("""
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
datang.zhongnianfu.com megaviews.top infapi.cc new.xcodexs.com newapi.pmcstation.com newapicq.freedom.nyc.mn
newapi.tsingzhancloud.com newai.cmiteam.cn panel.trust-api.ru plan.popsmart.cn zhenx.ai 5208.ai
olinkdata.cn api.open.xiaojingai.com api.zhenx.ai ultrarouter.ai orcarouter.ai linkapi.ai getunikey.ai
openlux.ai packyapi.ai cctq.ai
""".split())

URLSCAN_Q = ['page.title:"New API"', 'page.title:"One API"', 'page.title:"Done Hub"',
             'page.title:"NewAPI"', 'page.title:"AI API"', 'filename:"deepseek-v4.1-flash"',
             'filename:"deepseek-flash"', 'filename:"deepseek-v4.1-flash-1017"',
             'page.title:"New API" AND page.domain:ai', 'page.title:"One API" AND page.domain:ai']

CRT_Q = ["%25newapi%25", "%25one-api%25", "%25oneapi%25", "%25deepseek%25"]

def norm_host(u):
    if not u:
        return ""
    if "://" not in u:
        u = "https://" + u
    h = (urlparse(u).hostname or "").lower()
    return h[4:] if h.startswith("www.") else h

def urlscan_all():
    out = set()
    for q in URLSCAN_Q:
        after = None
        for page in range(4):
            params = {"q": q, "size": 100}
            if after:
                params["search_after"] = json.dumps(after)
            try:
                r = requests.get("https://urlscan.io/api/v1/search/", params=params, headers=UA,
                                 timeout=30, verify=False)
                if r.status_code != 200:
                    break
                j = r.json(); res = j.get("results", [])
                if not res:
                    break
                for x in res:
                    h = norm_host((x.get("page") or {}).get("url"))
                    if h and "." in h:
                        out.add(h)
                after = res[-1].get("sort")
            except Exception:
                break
        print(f"  [urlscan] {q} -> total {len(out)}", flush=True)
    return out

def crt_all():
    out = set()
    for q in CRT_Q:
        for attempt in range(2):
            try:
                r = requests.get("https://crt.sh/", params={"q": q, "output": "json"},
                                 headers=UA, timeout=45, verify=False)
                if r.status_code == 200 and r.text.strip().startswith("["):
                    for e in r.json():
                        for n in (e.get("name_value") or "").split("\n"):
                            n = n.strip().lower().lstrip("*.")
                            if "." in n and len(n) < 70:
                                out.add(n)
                    print(f"  [crt] {q} -> total {len(out)}", flush=True)
                    break
                else:
                    print(f"  [crt] {q} -> HTTP {r.status_code}", flush=True)
            except Exception as e:
                print(f"  [crt] {q} -> ERR {str(e)[:50]}", flush=True)
            time.sleep(3)
    return out

def tranco_ai():
    try:
        import zipfile, io, csv
        z = zipfile.ZipFile(CACHE_TRANCO)
        name = z.namelist()[0]
        out = {row[1].lower() for row in csv.reader(io.TextIOWrapper(z.open(name), encoding="utf-8"))
               if len(row) > 1 and row[1].endswith(".ai")}
        print(f"  [tranco] .ai {len(out)}", flush=True)
        return out
    except Exception as e:
        print("  [tranco] skip", e, flush=True)
        return set()

def probe(host):
    r = {"host": host, "url": None, "price": None, "free": False, "models": [], "has1017": False}
    for scheme in ("https", "http"):
        base = f"{scheme}://{host}"
        try:
            resp = requests.get(base + "/api/pricing", headers=UA, timeout=5, verify=False)
            if resp.status_code != 200 or not resp.text.lstrip().startswith("{"):
                continue
            data = (resp.json().get("data") or [])
            if isinstance(data, dict):
                data = data.get("models") or []
            hits, ratios, free = [], [], False
            for m in data:
                mn = str(m.get("model_name", "")); low = mn.lower()
                if "deepseek" in low and ("4.1" in low or "flash" in low):
                    hits.append(mn)
                    if "1017" in low:
                        r["has1017"] = True
                    try:
                        mr = float(m.get("model_ratio") or 0); mp = float(m.get("model_price") or 0)
                        if mr > 0:
                            ratios.append(mr * 2.0)
                        if mr == 0 and mp == 0 and "free" in low or (mr == 0 and mp == 0):
                            free = True
                    except Exception:
                        pass
            if hits:
                r.update(url=base, models=hits[:8], free=free,
                         price=round(min(ratios), 4) if ratios else None)
                return r
        except Exception:
            continue
    return r

def load_prev():
    hits = {}
    for f in glob.glob(REP + "/relay_discovery_*.json") + glob.glob(REP + "/ai_tld_discovery_*.json"):
        try:
            j = json.load(open(f, encoding="utf-8"))
            arr = j.get("results") or j.get("all") or []
            for x in arr:
                h = norm_host(x.get("url") or x.get("host"))
                if h and x.get("models"):
                    hits.setdefault(h, x)
        except Exception:
            pass
    print(f"  [prev] merged {len(hits)} hosts", flush=True)
    return hits

def main():
    t0 = time.time()
    print("[1] discovery", flush=True)
    d = set(SEEDS) | urlscan_all() | crt_all() | tranco_ai()
    print(f"    candidates: {len(d)}", flush=True)
    print("[2] probe", flush=True)
    fresh = {}
    with ThreadPoolExecutor(max_workers=100) as ex:
        futs = {ex.submit(probe, h): h for h in list(d)[:4000]}
        for f in as_completed(futs):
            x = f.result()
            if x["models"]:
                fresh[x["host"]] = x
    print(f"    fresh hits: {len(fresh)}", flush=True)
    prev = load_prev()
    prev.update(fresh)
    rows = []
    for h, x in prev.items():
        rows.append({"host": h, "url": x.get("url") or f"https://{h}",
                     "price": x.get("price"), "free": bool(x.get("free")),
                     "has1017": bool(x.get("has1017")), "models": x.get("models", [])})
    rows.sort(key=lambda r: (not r["free"], r["price"] if r["price"] is not None else 999, r["host"]))
    ts = time.strftime("%Y%m%d_%H%M%S")
    jf = f"{REP}/global_deepseek_targets_{ts}.json"
    json.dump({"generated": ts, "total": len(rows), "free": sum(r["free"] for r in rows),
               "rows": rows}, open(jf, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    mf = f"{REP}/global_deepseek_targets_{ts}.md"
    with open(mf, "w", encoding="utf-8") as f:
        f.write("# GLOBAL DEEPSEEK V4.1-FLASH TARGET LIST\n")
        f.write(f"> generated {ts} · total {len(rows)} · free {sum(r['free'] for r in rows)}\n\n")
        f.write("| # | host | free | $/M | 1017 | models |\n|---|---|---|---|---|---|\n")
        for i, r in enumerate(rows[:120], 1):
            f.write(f"| {i} | {r['url']} | {'✅' if r['free'] else ''} | {r['price']} | "
                    f"{'✅' if r['has1017'] else ''} | {', '.join(r['models'][:3])} |\n")
    print(f"\nDONE {time.time()-t0:.0f}s total={len(rows)} free={sum(r['free'] for r in rows)}", flush=True)
    print("free:", flush=True)
    for r in rows:
        if r["free"]:
            print("  ", r["url"], r["models"][:3], flush=True)
    print("saved:", mf, flush=True)

if __name__ == "__main__":
    main()
