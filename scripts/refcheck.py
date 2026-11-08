#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
paper-citation-guard — 论文引用防伪核验（跨平台版）

只用 Python 标准库，macOS / Linux / Windows 都能直接跑。
与 refcheck.ps1 共用同一份 providers.json / config.json / cache/。

硬规则：先有页面，才有引用。抓不到页面就不许引用，更不许补字段。
"""

import argparse
import html as html_mod
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "providers.json"
CONFIG = ROOT / "config.json"
CACHE_DIR = ROOT / "cache"

UA = "paper-citation-guard/1.0 (DSH skill)"
TIMEOUT = 25
LAST_NET_ERROR = None
LAST_DOI_REASON = None   # ok / not_found / network

# 由命令行设置
SINCE = 0
UNTIL = 0
WITH_ABS = False

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


# ------------------------------------------------------------------ 基础工具

def q(s):
    return urllib.parse.quote(str(s), safe="")


def http_get(url, timeout=None, headers=None):
    """返回文本；失败返回 None，并把原因记进 LAST_NET_ERROR。"""
    global LAST_NET_ERROR
    h = {
        "User-Agent": UA,
        "Accept": "application/json, text/html, application/xml;q=0.9, */*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    }
    if headers:
        h.update(headers)
    try:
        req = urllib.request.Request(url, headers=h)
        with urllib.request.urlopen(req, timeout=timeout or TIMEOUT) as r:
            raw = r.read()
            cs = r.headers.get_content_charset() or "utf-8"
            try:
                return raw.decode(cs, errors="replace")
            except LookupError:
                return raw.decode("utf-8", errors="replace")
    except Exception as e:
        LAST_NET_ERROR = f"{type(e).__name__}: {e}"
        return None


def http_json(url, timeout=None, headers=None, retry=True):
    t = http_get(url, timeout=timeout, headers=headers)
    if not t and retry:
        time.sleep(0.9)
        t = http_get(url, timeout=timeout, headers=headers)
    if not t:
        return None
    try:
        return json.loads(t)
    except Exception:
        return None


def load_config():
    if CONFIG.exists():
        try:
            return json.loads(CONFIG.read_text("utf-8"))
        except Exception:
            pass
    return {"email": "", "providers": {}}


def cfg_value(key):
    if not key:
        return ""
    cfg = load_config()
    if key == "email":
        return str(cfg.get("email") or "")
    parts = key.split(".")
    if len(parts) != 2:
        return ""
    sec = cfg.get("providers", {}) or {}
    return str((sec.get(parts[0], {}) or {}).get(parts[1], "") or "")


def load_registry():
    if not REGISTRY.exists():
        return []
    try:
        return json.loads(REGISTRY.read_text("utf-8")).get("providers", [])
    except Exception:
        return []


def plain(s):
    return re.sub(r"[^\w]", "", (s or "").lower())


def bigrams(s):
    p = plain(s)
    if len(p) < 2:
        return {p} if p else set()
    return {p[i:i + 2] for i in range(len(p) - 1)}


def sim(a, b):
    A, B = bigrams(a), bigrams(b)
    if not A or not B:
        return 0.0
    return round(2.0 * len(A & B) / (len(A) + len(B)), 3)


def join_pages(first, last):
    if not first:
        return None
    if last and str(last) != str(first):
        return f"{first}-{last}"
    return str(first)


def clean_doi(d):
    if not d:
        return None
    return re.sub(r"^https?://(dx\.)?doi\.org/", "", str(d).strip())


def make_item(source, title, authors=None, year=None, venue=None, volume=None, issue=None,
              pages=None, doi=None, url=None, type_="journal-article", abstract="",
              note="", status="", score=0.0, oa=""):
    return {
        "source": source, "title": title or "", "authors": authors or "",
        "year": year, "venue": venue, "volume": volume, "issue": issue,
        "pages": pages, "doi": clean_doi(doi), "url": url, "type": type_,
        "abstract": abstract or "", "note": note, "status": status,
        "score": score, "oa": oa, "citation": "",
    }


def year_filter_openalex():
    f = []
    if SINCE:
        f.append(f"from_publication_date:{SINCE}-01-01")
    if UNTIL:
        f.append(f"to_publication_date:{UNTIL}-12-31")
    return f


def year_filter_crossref():
    f = []
    if SINCE:
        f.append(f"from-pub-date:{SINCE}-01-01")
    if UNTIL:
        f.append(f"until-pub-date:{UNTIL}-12-31")
    return f


# ------------------------------------------------------------------ 各库适配器

def p_openalex(query, n):
    sel = "id,doi,display_name,publication_year,type,authorships,primary_location,biblio"
    if WITH_ABS:
        sel += ",abstract_inverted_index"
    url = f"https://api.openalex.org/works?search={q(query)}&per-page={n}&select={sel}"
    f = year_filter_openalex()
    if f:
        url += "&filter=" + urllib.parse.quote(",".join(f), safe=":,-")
    j = http_json(url)
    if not j:
        return []
    out = []
    for w in j.get("results", []) or []:
        if not w.get("display_name"):
            continue
        pl = w.get("primary_location") or {}
        src = pl.get("source") or {}
        bib = w.get("biblio") or {}
        authors = ", ".join(a["author"]["display_name"] for a in (w.get("authorships") or [])
                            if a.get("author", {}).get("display_name"))
        abstract = ""
        inv = w.get("abstract_inverted_index")
        if inv:
            pos = {}
            for word, idxs in inv.items():
                for i in idxs:
                    pos[i] = word
            abstract = " ".join(pos[k] for k in sorted(pos))
        url2 = w.get("doi") or pl.get("landing_page_url")
        out.append(make_item("OpenAlex", w["display_name"], authors, w.get("publication_year"),
                             src.get("display_name"), bib.get("volume"), bib.get("issue"),
                             join_pages(bib.get("first_page"), bib.get("last_page")),
                             w.get("doi"), url2, w.get("type", "work"), abstract))
    return out


def p_crossref(query, n):
    sel = "DOI,title,author,issued,container-title,page,volume,issue,type"
    url = f"https://api.crossref.org/works?query.bibliographic={q(query)}&rows={n}&select={sel}"
    f = year_filter_crossref()
    if f:
        url += "&filter=" + urllib.parse.quote(",".join(f), safe=":,-")
    j = http_json(url)
    if not j:
        return []
    out = []
    for it in (j.get("message", {}) or {}).get("items", []) or []:
        title = " ".join(it.get("title") or [])
        if not title:
            continue
        names = []
        for a in it.get("author") or []:
            fam, giv = a.get("family", ""), a.get("given", "")
            if fam and giv and re.search(r"[\u4e00-\u9fff]", fam + giv):
                names.append(f"{fam}{giv}")
            elif fam or giv:
                names.append(f"{giv} {fam}".strip())
            elif a.get("name"):
                names.append(a["name"])
        year = None
        dp = (it.get("issued") or {}).get("date-parts")
        if dp and dp[0]:
            year = dp[0][0]
        doi = it.get("DOI")
        out.append(make_item("CrossRef", title, ", ".join(names), year,
                             " ".join(it.get("container-title") or []), it.get("volume"),
                             it.get("issue"), it.get("page"), doi,
                             f"https://doi.org/{doi}" if doi else None, it.get("type", "journal-article")))
    return out


def p_arxiv(query, n):
    url = f"https://export.arxiv.org/api/query?search_query=all:{q(query)}&max_results={n}"
    t = http_get(url)
    if not t:
        return []
    out = []
    try:
        ns = {"a": "http://www.w3.org/2005/Atom"}
        root = ET.fromstring(t)
        for e in root.findall("a:entry", ns):
            title = re.sub(r"\s+", " ", (e.findtext("a:title", "", ns) or "")).strip()
            if not title:
                continue
            authors = ", ".join(x.findtext("a:name", "", ns) for x in e.findall("a:author", ns))
            pub = e.findtext("a:published", "", ns)
            year = int(pub[:4]) if pub[:4].isdigit() else None
            link = e.findtext("a:id", "", ns)
            m = re.search(r"abs/([^/]+)$", link or "")
            doi = f"10.48550/arXiv.{m.group(1)}" if m else None
            out.append(make_item("arXiv", title, authors, year, "arXiv preprint",
                                 doi=doi, url=link, type_="preprint"))
    except Exception:
        pass
    return out


def p_europepmc(query, n):
    url = (f"https://www.ebi.ac.uk/europepmc/webservices/rest/search?query={q(query)}"
           f"&format=json&pageSize={n}&resultType=core")
    j = http_json(url)
    if not j:
        return []
    out = []
    for x in (j.get("resultList", {}) or {}).get("result", []) or []:
        if not x.get("title"):
            continue
        doi = x.get("doi")
        link = f"https://doi.org/{doi}" if doi else f"https://europepmc.org/article/{x.get('source')}/{x.get('id')}"
        out.append(make_item("EuropePMC", x["title"], x.get("authorString"), x.get("pubYear"),
                             x.get("journalTitle"), x.get("journalVolume"), x.get("issue"),
                             x.get("pageInfo"), doi, link, "journal-article"))
    return out


def p_doaj(query, n):
    url = f"https://doaj.org/api/search/articles/{q(query)}?pageSize={n}"
    j = http_json(url)
    if not j:
        return []
    out = []
    for r in j.get("results", []) or []:
        b = r.get("bibjson") or {}
        if not b.get("title"):
            continue
        doi = None
        for ident in b.get("identifier") or []:
            if ident.get("type") == "doi":
                doi = clean_doi(ident.get("id"))
                break
        jr = b.get("journal") or {}
        names = ", ".join(a.get("name", "") for a in (b.get("author") or []))
        link = f"https://doi.org/{doi}" if doi else (
            f"https://doaj.org/article/{r.get('id')}" if r.get("id") else None)
        out.append(make_item("DOAJ", b["title"], names, b.get("year"), jr.get("title"),
                             jr.get("volume"), jr.get("number"),
                             join_pages(jr.get("start_page"), jr.get("end_page")),
                             doi, link, "journal-article"))
    return out


def p_datacite(query, n):
    url = f"https://api.datacite.org/dois?query={q(query)}&page[size]={n}"
    j = http_json(url)
    if not j:
        return []
    out = []
    for d in j.get("data", []) or []:
        a = d.get("attributes") or {}
        titles = a.get("titles") or []
        title = titles[0].get("title") if titles else None
        if not title:
            continue
        if len(title) > 300:
            title = title[:300] + "…"
        out.append(make_item("DataCite", title, None, a.get("publicationYear"), a.get("publisher"),
                             doi=a.get("doi"), url=f"https://doi.org/{a.get('doi')}", type_="dataset"))
    return out


def p_semanticscholar(query, n):
    h = {}
    key = cfg_value("semanticscholar.apiKey")
    if key:
        h["x-api-key"] = key
    url = (f"https://api.semanticscholar.org/graph/v1/paper/search?query={q(query)}"
           f"&limit={n}&fields=title,year,venue,externalIds,authors,abstract")
    j = http_json(url, headers=h, retry=False)
    if not j:
        return []
    out = []
    for p in j.get("data", []) or []:
        if not p.get("title"):
            continue
        doi = (p.get("externalIds") or {}).get("DOI")
        names = ", ".join(a.get("name", "") for a in (p.get("authors") or []))
        link = f"https://doi.org/{doi}" if doi else (
            f"https://www.semanticscholar.org/paper/{p.get('paperId')}" if p.get("paperId") else None)
        out.append(make_item("SemanticScholar", p["title"], names, p.get("year"), p.get("venue"),
                             doi=doi, url=link, abstract=p.get("abstract") or ""))
    return out


def p_core(query, n):
    key = cfg_value("core.apiKey")
    if not key:
        return []
    url = f"https://api.core.ac.uk/v3/search/works?q={q(query)}&limit={n}"
    j = http_json(url, headers={"Authorization": f"Bearer {key}"}, retry=False)
    if not j:
        return []
    out = []
    for w in j.get("results", []) or []:
        if not w.get("title"):
            continue
        doi = w.get("doi")
        link = f"https://doi.org/{doi}" if doi else w.get("downloadUrl")
        out.append(make_item("CORE", w["title"], ", ".join(w.get("authors") or []),
                             w.get("yearPublished"), w.get("publisher"), doi=doi, url=link,
                             type_="work", abstract=w.get("abstract") or ""))
    return out


def p_pubmed(query, n):
    key = cfg_value("pubmed.apiKey")
    kq = f"&api_key={key}" if key else ""
    s = http_json(f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed"
                  f"&term={q(query)}&retmode=json&retmax={n}{kq}")
    if not s:
        return []
    ids = (s.get("esearchresult", {}) or {}).get("idlist") or []
    if not ids:
        return []
    d = http_json(f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed"
                  f"&id={','.join(ids)}&retmode=json{kq}")
    if not d:
        return []
    out = []
    for pid in ids:
        r = (d.get("result", {}) or {}).get(pid)
        if not r:
            continue
        doi = None
        for a in r.get("articleids") or []:
            if a.get("idtype") == "doi":
                doi = a.get("value")
                break
        link = f"https://doi.org/{doi}" if doi else f"https://pubmed.ncbi.nlm.nih.gov/{pid}/"
        out.append(make_item("PubMed", r.get("title", "").rstrip("."),
                             ", ".join(a.get("name", "") for a in (r.get("authors") or [])),
                             (r.get("pubdate") or "")[:4] or None, r.get("fulljournalname"),
                             r.get("volume"), r.get("issue"), r.get("pages"), doi, link))
    return out


def p_openaire(query, n):
    url = f"https://api.openaire.eu/graph/v1/researchProducts?search={q(query)}&type=publication&pageSize={n}"
    j = http_json(url)
    if not j:
        return []
    out = []
    for x in j.get("results", []) or []:
        if not x.get("mainTitle"):
            continue
        doi = None
        for pid in x.get("pids") or []:
            if pid.get("scheme") == "doi":
                doi = pid.get("value")
                break
        c = x.get("container") or {}
        names = ", ".join(a.get("fullName") or f"{a.get('name', '')} {a.get('surname', '')}".strip()
                          for a in (x.get("authors") or []))
        pub = str(x.get("publicationDate") or "")
        year = int(pub[:4]) if pub[:4].isdigit() else None
        link = f"https://doi.org/{doi}" if doi else (
            f"https://explore.openaire.eu/search/publication?articleId={x.get('id')}" if x.get("id") else None)
        out.append(make_item("OpenAIRE", x["mainTitle"], names, year, c.get("name"),
                             c.get("vol"), c.get("iss"), join_pages(c.get("sp"), c.get("ep")),
                             doi, link, "publication"))
    return out


def p_scopus(query, n):
    key = cfg_value("scopus.apiKey")
    if not key:
        return []
    url = f"https://api.elsevier.com/content/search/scopus?query=TITLE-ABS-KEY({q(query)})&count={n}"
    j = http_json(url, headers={"X-ELS-APIKey": key, "Accept": "application/json"}, retry=False)
    if not j:
        return []
    out = []
    for e in (j.get("search-results", {}) or {}).get("entry", []) or []:
        title = e.get("dc:title")
        if not title:
            continue
        doi = e.get("prism:doi")
        cd = str(e.get("prism:coverDate") or "")
        out.append(make_item("Scopus", title, e.get("dc:creator"),
                             int(cd[:4]) if cd[:4].isdigit() else None,
                             e.get("prism:publicationName"), e.get("prism:volume"),
                             e.get("prism:issueIdentifier"), e.get("prism:pageRange"), doi,
                             f"https://doi.org/{doi}" if doi else None))
    return out


def p_sciencedirect(query, n):
    key = cfg_value("sciencedirect.apiKey")
    if not key:
        return []
    url = f"https://api.elsevier.com/content/search/sciencedirect?query={q(query)}&count={n}"
    j = http_json(url, headers={"X-ELS-APIKey": key, "Accept": "application/json"}, retry=False)
    if not j:
        return []
    out = []
    for e in (j.get("search-results", {}) or {}).get("entry", []) or []:
        title = e.get("dc:title")
        if not title:
            continue
        doi = e.get("prism:doi")
        cd = str(e.get("prism:coverDate") or "")
        out.append(make_item("ScienceDirect", title,
                             int(cd[:4]) if cd[:4].isdigit() else None,
                             e.get("prism:publicationName"), e.get("prism:volume"),
                             None, e.get("prism:pageRange"), doi,
                             f"https://doi.org/{doi}" if doi else None))
    return out


def p_springer(query, n):
    key = cfg_value("springer.apiKey")
    if not key:
        return []
    url = f"https://api.springernature.com/meta/v2/json?q={q(query)}&p={n}&api_key={key}"
    j = http_json(url, retry=False)
    if not j:
        return []
    out = []
    for r in j.get("records", []) or []:
        if not r.get("title"):
            continue
        names = ", ".join(c.get("creator", "") for c in (r.get("creators") or []))
        pd = str(r.get("publicationDate") or "")
        doi = r.get("doi")
        out.append(make_item("Springer", r["title"], names,
                             int(pd[:4]) if pd[:4].isdigit() else None,
                             r.get("publicationName"), r.get("volume"), r.get("number"),
                             join_pages(r.get("startingPage"), r.get("endingPage")), doi,
                             f"https://doi.org/{doi}" if doi else None))
    return out


def p_wos(query, n):
    key = cfg_value("wos.apiKey")
    if not key:
        return []
    url = (f"https://api.clarivate.com/apis/wos-starter/v1/documents?q={q(query)}"
           f"&db=WOS&limit={n}&page=1")
    j = http_json(url, headers={"X-ApiKey": key, "Accept": "application/json"}, retry=False)
    if not j:
        return []
    out = []
    for d in j.get("hits", []) or []:
        if not d.get("title"):
            continue
        src = d.get("source") or {}
        ids = d.get("identifiers") or {}
        doi = ids.get("doi")
        names = ", ".join(a.get("displayName", "") for a in ((d.get("names") or {}).get("authors") or []))
        out.append(make_item("WoS", d["title"], names, d.get("publishYear"), src.get("title"),
                             src.get("volume"), src.get("issue"),
                             join_pages(src.get("pageStart"), src.get("pageEnd")), doi,
                             f"https://doi.org/{doi}" if doi else None))
    return out


ADAPTERS = {
    "openalex": p_openalex, "crossref": p_crossref, "arxiv": p_arxiv,
    "europepmc": p_europepmc, "doaj": p_doaj, "datacite": p_datacite,
    "semanticscholar": p_semanticscholar, "core": p_core, "pubmed": p_pubmed,
    "openaire": p_openaire, "scopus": p_scopus, "sciencedirect": p_sciencedirect,
    "springer": p_springer, "wos": p_wos,
}

NO_SEARCH_API = {"ieee", "jstor", "wanfang", "cqvip", "ncpssd", "biorxiv", "unpaywall"}


# ------------------------------------------------------------------ 中文网页检索

def p_cnweb(query, n):
    """百度优先，360 兜底。返回的是线索，不是证据。"""
    academic = re.compile(r"cnki\.com\.cn|cnki\.net|wanfangdata|cqvip|doi\.org")
    out = []
    h = http_get(f"https://www.baidu.com/s?wd={q(query)}&ie=utf-8")
    if h and len(h) > 20000:
        for blk in re.findall(r'<div[^>]*class="[^"]*c-container[^"]*"[\s\S]{0,6000}?</div>\s*</div>', h):
            m = re.search(r'mu="([^"]+)"', blk)
            if not m:
                continue
            link = m.group(1)
            if not academic.search(link):
                continue
            text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", blk)).strip()[:200]
            out.append(make_item("Baidu", text, url=link, type_="lead"))
    if len(out) < n:
        h2 = http_get(f"https://www.so.com/s?q={q(query)}")
        if (not h2 or len(h2) < 20000):
            h2 = http_get(f"https://www.so.com/s?q={q('site:cnki.com.cn ' + query)}")
        if h2 and len(h2) > 20000:
            for tag in re.findall(r"<a[^>]*>[\s\S]{0,600}?</a>", h2):
                m = re.search(r'data-mdurl="([^"]+)"', tag)
                if not m:
                    continue
                link = m.group(1)
                if not academic.search(link):
                    continue
                text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", tag)).strip()[:200]
                out.append(make_item("360", text, url=link, type_="lead"))
    seen, uniq = set(), []
    for it in out:
        k = (it["url"] or "").lower()
        if k in seen:
            continue
        seen.add(k)
        uniq.append(it)
    return uniq[:n]


# ------------------------------------------------------------------ 页面解析

def meta_map(html_text):
    m = {}
    authors = []
    for tag in re.findall(r"<meta\s[^>]*>", html_text, re.I):
        nm = re.search(r'(?:name|property)\s*=\s*["\']([^"\']+)["\']', tag, re.I)
        ct = re.search(r'content\s*=\s*["\']([^"\']*)["\']', tag, re.I)
        if not (nm and ct):
            continue
        k = nm.group(1).lower()
        v = html_mod.unescape(ct.group(1))
        if k in ("citation_author", "dc.creator"):
            authors.append(v)
        if k not in m:
            m[k] = v
    return m, authors


def cnki_meta(html_text):
    title = venue = None
    year = issue = None
    authors = None
    abstract = ""

    t = re.search(r"<title>([\s\S]*?)</title>", html_text, re.I)
    if t:
        raw = re.sub(r"\s+", " ", html_mod.unescape(t.group(1)))
        parts = raw.split("--")
        title = parts[0].strip()
        if len(parts) > 1:
            j = re.search(r"《([^》]+)》\s*(\d{4})年\s*(\d{1,2})期", parts[1])
            if j:
                venue, year, issue = j.group(1), int(j.group(2)), int(j.group(3))

    plain_text = re.sub(r"(?s)<script.*?</script>", " ", html_text)
    plain_text = re.sub(r"(?s)<style.*?</style>", " ", plain_text)
    plain_text = html_mod.unescape(re.sub(r"<[^>]+>", "\n", plain_text))
    lines = [l.strip() for l in plain_text.split("\n") if l.strip()]

    idx = next((i for i, l in enumerate(lines) if l == "论文排版"), -1)
    if idx >= 0:
        names = []
        for k in range(idx + 2, min(idx + 10, len(lines))):
            ln = lines[k]
            if re.match(r"^(开通知|【摘要】|摘要|下载|关键词)", ln):
                break
            if len(ln) <= 20 and re.search(r"[A-Za-z\u4e00-\u9fff]", ln) and not re.search(r"[，。；：、,.?！!？]", ln):
                names.append(ln)
            else:
                break
        if names:
            authors = ", ".join(names)

    ai = next((i for i, l in enumerate(lines) if l.startswith("【摘要】")), -1)
    if ai >= 0:
        buf = re.sub(r"^【摘要】[：:]?", "", lines[ai])
        for k in range(ai + 1, min(ai + 14, len(lines))):
            ln = lines[k]
            if re.match(r"^(下载App|下载全文|关键词|【关键词】|更多同类)", ln):
                break
            buf += ln
        abstract = re.sub(r"\s+", " ", buf).strip()[:600]

    return title, authors, venue, year, issue, abstract


def get_page_meta(link):
    h = http_get(link)
    if not h:
        return None
    host = ""
    try:
        host = urllib.parse.urlparse(link).hostname or ""
    except Exception:
        pass

    if "cnki.com.cn" in host or "cnki.net" in host:
        title, authors, venue, year, issue, abstract = cnki_meta(h)
        if title:
            return make_item("CNKI", title, authors, year, venue, issue=issue,
                             url=link, type_="journal-article", abstract=abstract,
                             note="知网页面未显示页码：引用时省略页码，不要自行补全")

    m, authors = meta_map(h)
    title = m.get("citation_title") or m.get("dc.title") or m.get("og:title")
    if not title:
        t = re.search(r"<title>([\s\S]*?)</title>", h, re.I)
        if t:
            title = re.sub(r"\s+", " ", html_mod.unescape(t.group(1))).strip()
    if not title:
        return None

    year = None
    for k in ("citation_publication_date", "citation_date", "citation_year", "dc.date"):
        if m.get(k):
            y = re.search(r"(\d{4})", m[k])
            if y:
                year = int(y.group(1))
                break

    doi = m.get("citation_doi") or m.get("dc.identifier") or m.get("prism.doi")
    venue = m.get("citation_journal_title") or m.get("citation_conference_title")
    type_ = "journal-article" if venue else "webpage"
    if "arxiv.org" in host:
        venue = venue or "arXiv preprint"
        type_ = "preprint"
        if not doi:
            am = re.search(r"abs/([^/?#]+)", link)
            if am:
                doi = f"10.48550/arXiv.{am.group(1)}"

    return make_item("Web", title, ", ".join(dict.fromkeys(authors)), year, venue,
                     m.get("citation_volume"), m.get("citation_issue"),
                     join_pages(m.get("citation_firstpage"), m.get("citation_lastpage")),
                     doi, link, type_)


# ------------------------------------------------------------------ DOI 核验

def http_status_json(url, headers=None, timeout=None):
    """返回 (http_status, dict|None)。
    status=404 是"明确没有"，不是网络故障——这两件事必须分开。"""
    global LAST_NET_ERROR
    h = {"User-Agent": UA, "Accept": "application/json"}
    if headers:
        h.update(headers)
    try:
        req = urllib.request.Request(url, headers=h)
        with urllib.request.urlopen(req, timeout=timeout or TIMEOUT) as r:
            body = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(body)
            except Exception:
                return r.status, None
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode("utf-8", "replace")
            return e.code, json.loads(body)
        except Exception:
            return e.code, None
    except Exception as e:
        LAST_NET_ERROR = f"{type(e).__name__}: {e}"
        return None, None


def confirm_doi(doi):
    global LAST_DOI_REASON
    url = f"https://doi.org/{doi}"

    st, j = http_status_json(f"https://api.crossref.org/works/{doi}")
    if j and isinstance(j, dict) and j.get("message"):
        msg = j["message"]
        title = " ".join(msg.get("title") or [])
        names = []
        for a in msg.get("author") or []:
            fam, giv = a.get("family", ""), a.get("given", "")
            if fam and giv and re.search(r"[\u4e00-\u9fff]", fam + giv):
                names.append(f"{fam}{giv}")
            elif fam or giv:
                names.append(f"{giv} {fam}".strip())
            elif a.get("name"):
                names.append(a["name"])
        dp = (msg.get("issued") or {}).get("date-parts")
        year = dp[0][0] if dp and dp[0] else None
        item = make_item("CrossRef", title, ", ".join(names), year,
                         " ".join(msg.get("container-title") or []), msg.get("volume"),
                         msg.get("issue"), msg.get("page"), doi, url, msg.get("type", "journal-article"))
        oa = oa_location(doi)
        if oa and oa.get("url"):
            item["oa"] = oa["url"]
        LAST_DOI_REASON = "ok"
        return item

    st2, hd = http_status_json(f"https://doi.org/api/handles/{doi}")
    if hd and hd.get("responseCode") == 1:
        target = None
        for v in hd.get("values") or []:
            if v.get("type") == "URL":
                target = (v.get("data") or {}).get("value")
                break
        if target and "doi.org" not in target:
            item = get_page_meta(target)
            if item and item.get("title"):
                item["doi"] = doi
                item["url"] = url
                LAST_DOI_REASON = "ok"
                return item
        LAST_DOI_REASON = "ok"
        return make_item("DOI", "(仅查到 DOI 解析记录，题名未取到)", doi=doi, url=url,
                         type_="record", note=f"解析目标: {target}")

    # 404 = 这个 DOI 根本不存在，是明确答案
    if st == 404 or st2 == 404:
        LAST_DOI_REASON = "not_found"
    elif LAST_NET_ERROR:
        LAST_DOI_REASON = "network"
    else:
        LAST_DOI_REASON = "not_found"
    return None


def oa_location(doi):
    email = cfg_value("email")
    if not email or not doi:
        return None
    j = http_json(f"https://api.unpaywall.org/v2/{doi}?email={q(email)}", retry=False)
    if not j:
        return None
    best = j.get("best_oa_location") or {}
    return {"is_oa": bool(j.get("is_oa")),
            "url": best.get("url_for_pdf") or best.get("url")}


# ------------------------------------------------------------------ 引用格式

CJK = re.compile(r"[\u4e00-\u9fff]")


def gbt_author(name):
    name = name.strip()
    if not name or CJK.search(name):
        return name
    parts = [p for p in name.split() if p]
    if len(parts) < 2:
        return name
    fam, giv = parts[-1], parts[:-1]
    ini = [p.lstrip("(")[:1].upper() for p in giv if p]
    return " ".join([fam] + ini)


def apa_author(name):
    name = name.strip()
    if not name or CJK.search(name):
        return name
    if re.match(r"^(.+?)\s+([A-Z][A-Z.\s]*)$", name):
        m = re.match(r"^(.+?)\s+([A-Z][A-Z.\s]*)$", name)
        fam, giv = m.group(1), m.group(2)
    else:
        parts = [p for p in name.split() if p]
        if len(parts) < 2:
            return name
        fam, giv = parts[-1], " ".join(parts[:-1])
    ini = " ".join(p[:1].upper() + "." for p in giv.split() if p)
    return f"{fam}, {ini}"


def format_gbt(it):
    t = (it.get("type") or "").lower()
    tag = "[J]"
    if "preprint" in t or "arxiv" in t:
        tag = "[EB/OL]"
    elif "conference" in t or "proceedings" in t:
        tag = "[C]"
    elif "book" in t or "monograph" in t:
        tag = "[M]"
    elif "dataset" in t:
        tag = "[DS]"
    elif not it.get("venue"):
        tag = "[EB/OL]"

    authors = ", ".join(gbt_author(a) for a in re.split(r"\s*,\s*", it["authors"] or "") if a.strip())
    s = (authors + ". ") if authors else ""
    s += f"{it['title']}{tag}. "
    if it.get("venue"):
        s += it["venue"]
    if it.get("year"):
        s += (", " if it.get("venue") else "") + str(it["year"])
    if tag != "[EB/OL]":
        if it.get("volume"):
            s += f", {it['volume']}"
        if it.get("issue"):
            s += f"({it['issue']})"
        if it.get("pages"):
            s += f": {it['pages']}"
    s = s.rstrip() + "."
    if it.get("doi"):
        s += f" https://doi.org/{it['doi']}."
    elif it.get("url"):
        s += f" {it['url']}."
    return re.sub(r"\s+", " ", s).replace("..", ".")


def format_apa(it):
    names = [a for a in re.split(r"\s*,\s*", it["authors"] or "") if a.strip()]
    conv = [apa_author(a) for a in names]
    if len(conv) == 1:
        a = conv[0]
    elif len(conv) == 2:
        a = f"{conv[0]}, & {conv[1]}"
    elif len(conv) > 2:
        a = ", ".join(conv[:-1]) + ", & " + conv[-1]
    else:
        a = ""
    s = (a + " ") if a else ""
    s += f"({it['year']}). " if it.get("year") else "(n.d.). "
    s += f"{it['title']}. "
    if it.get("venue"):
        s += it["venue"]
    if it.get("volume"):
        s += f", {it['volume']}"
    if it.get("issue"):
        s += f"({it['issue']})"
    if it.get("pages"):
        s += f", {it['pages']}"
    s = s.rstrip() + "."
    if it.get("doi"):
        s += f" https://doi.org/{it['doi']}"
    elif it.get("url"):
        s += f" {it['url']}"
    return re.sub(r"\s+", " ", s)


# ------------------------------------------------------------------ 知网目录（TOC）

JOURNALS = {
    "外语界": "WYJY", "外语电化教学": "WYDH", "现代外语": "XDWY",
    "解放军外国语学院学报": "JFJW", "齐鲁师范学院学报": "SDJX", "成都师范学院学报": "SJXB",
}

TOC_DELAY = 1.1


def resolve_journal(j):
    if not j:
        return None
    j = j.strip()
    return JOURNALS.get(j, j.upper())


# PowerShell 版写缓存用 PascalCase（Seq/Title/...），这里统一成小写读，
# 写回时仍用 PascalCase，保证两个实现能共用同一份 cache/
def norm_row(r):
    return {
        "seq": r.get("seq", r.get("Seq")),
        "title": r.get("title", r.get("Title")),
        "authors": r.get("authors", r.get("Authors")),
        "venue": r.get("venue", r.get("Venue")),
        "year": r.get("year", r.get("Year")),
        "issue": r.get("issue", r.get("Issue")),
        "url": r.get("url", r.get("Url")),
    }


def ps_row(r):
    return {"Seq": r["seq"], "Title": r["title"], "Authors": r.get("authors"),
            "Venue": r.get("venue"), "Year": r.get("year"), "Issue": r.get("issue"),
            "Url": r["url"]}


def cnki_html(article_id):
    """返回文本 / 'MISS'（404，号段到头） / None（网络或限流失败）"""
    global TOC_DELAY
    url = f"https://www.cnki.com.cn/Article/CJFDTotal-{article_id}.htm"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return "MISS"
        if e.code == 403:
            time.sleep(5)
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=20) as r:
                    return r.read().decode("utf-8", errors="replace")
            except Exception:
                return None
        return None
    except Exception:
        return None


def cnki_toc(code, year, issue, max_seq=28, no_cache=False):
    """返回 (items, failed)"""
    global TOC_DELAY
    CACHE_DIR.mkdir(exist_ok=True)
    cache_file = CACHE_DIR / f"{code}-{year}-{issue:02d}.json"

    if not no_cache and cache_file.exists():
        try:
            age_days = (time.time() - cache_file.stat().st_mtime) / 86400
            if age_days < 30:
                cached = json.loads(cache_file.read_text("utf-8"))
                if cached:
                    return [norm_row(x) for x in cached], False
        except Exception:
            pass

    items, miss, hard = [], 0, 0
    for seq in range(1, max_seq + 1):
        aid = f"{code}{year}{issue:02d}{seq:03d}"
        body = cnki_html(aid)
        if body == "MISS":
            miss += 1
            if miss >= 3:
                break
            time.sleep(1.6)
            continue
        if body is None:
            hard += 1
            TOC_DELAY = min(4.0, TOC_DELAY * 1.8)
            miss += 1
            if miss >= 4:
                break
            time.sleep(6)
            continue
        title, authors, venue, y, iss, abstract = cnki_meta(body)
        if not title:
            # 200 空壳页：这一期不存在
            miss += 1
            if miss >= 3:
                break
            time.sleep(0.8)
            continue
        miss = 0
        items.append({"seq": seq, "title": title, "authors": authors, "venue": venue,
                      "year": y, "issue": iss,
                      "url": f"https://www.cnki.com.cn/Article/CJFDTotal-{aid}.htm"})
        time.sleep(TOC_DELAY)

    if items and hard == 0 and not no_cache:
        try:
            cache_file.write_text(json.dumps([ps_row(x) for x in items], ensure_ascii=False, indent=1), "utf-8")
        except Exception:
            pass
    if hard:
        print(f"  ⚠ 第 {issue} 期有 {hard} 次抓取失败（限流），结果不完整且未缓存，稍后重跑即可")
    elif len(items) >= max_seq:
        print(f"  ⚠ 第 {issue} 期探到序号上限 {max_seq}，可能还有后续条目，用 --max-seq 加大")
    return items, hard > 0


# ------------------------------------------------------------------ 展示

C_VERIFIED, C_WARN, C_DIM, C_LINK, C_RESET = "", "", "", "", ""
if sys.stdout.isatty() and os.name != "nt":
    C_VERIFIED, C_WARN, C_DIM, C_LINK, C_RESET = "\033[32m", "\033[33m", "\033[90m", "\033[36m", "\033[0m"


def show_item(it, idx):
    mark = {"VERIFIED": "✔", "LEAD": "→", "WEAK": "?", "MISMATCH": "≠",
            "UNREACHABLE": "!", "NOT_FOUND": "✘"}.get(it.get("status"), "✘")
    color = C_VERIFIED if it.get("status") == "VERIFIED" else C_WARN
    print("\n" + "─" * 78)
    head = f"[{idx}] {mark} {it.get('status','')}"
    if it.get("score"):
        head += f"  sim={it['score']}"
    if it.get("source"):
        head += f"  · {it['source']}"
    print(color + head + C_RESET)
    if it.get("title"):
        print(f"  题名  {it['title']}")
    if it.get("authors"):
        print(f"  作者  {it['authors']}")
    bits = [str(x) for x in (it.get("venue"), it.get("year"),
                             f"第 {it['volume']} 卷" if it.get("volume") else None,
                             f"第 {it['issue']} 期" if it.get("issue") else None,
                             it.get("pages")) if x]
    if bits:
        print("  来源  " + " · ".join(bits))
    if it.get("url"):
        print(C_LINK + f"  链接  {it['url']}" + C_RESET)
    if it.get("oa"):
        print(C_VERIFIED + f"  免费全文  {it['oa']}" + C_RESET)
    if it.get("abstract"):
        ab = it["abstract"]
        print(C_DIM + f"  摘要  {ab[:240] + ('…' if len(ab) > 240 else '')}" + C_RESET)
    if it.get("note"):
        print(C_DIM + f"  备注  {it['note']}" + C_RESET)
    if it.get("citation"):
        print(C_DIM + f"  引用  {it['citation']}" + C_RESET)


# ------------------------------------------------------------------ doctor

def cmd_doctor(args):
    reg = load_registry()
    if not reg:
        print(f"❌ 找不到 {REGISTRY}", file=sys.stderr)
        return 2
    if args.init_config:
        write_config_template()
        print(f"已生成模板：{CONFIG}")

    print("\n论文引用核验 · 数据源自检")
    print(f"注册表：{REGISTRY}")
    print(f"配置文件：{CONFIG}{'（已存在）' if CONFIG.exists() else '（尚未创建）'}\n")

    print(f"{'数据源':<24}{'状态':<10}{'耗时':>8}  说明")
    print("─" * 100)
    ok, need = 0, []
    for p in reg:
        status, ms, hint = probe(p)
        if status == "可连接":
            ok += 1
            if p["id"] in NO_SEARCH_API:
                hint = ("无公开检索接口 · " + hint).strip(" ·")
        if status in ("缺 API key", "需鉴权"):
            need.append(p)
        print(f"{p['name']:<24}{status:<10}{(str(ms) + 'ms') if ms else '-':>8}  {hint}")

    print(f"\n可连接 {ok} / {len(reg)}")
    if need:
        print("\n需要在 config.json 里补的：")
        for p in need:
            print(f"  {p.get('configKey',''):<22}{p.get('note','')}")
    return 0


def probe(p):
    global LAST_NET_ERROR
    if not p.get("enabled"):
        return "未启用", 0, p.get("note", "")
    auth = p.get("auth")
    if auth == "key" and not cfg_value(p.get("configKey")):
        return "缺 API key", 0, f"在 config.json 填 {p.get('configKey')}"
    if auth == "email" and not cfg_value(p.get("configKey")):
        return "缺 email", 0, f"在 config.json 填 {p.get('configKey')}"

    url = p.get("probe", "")
    if "{email}" in url:
        url = url.replace("{email}", q(cfg_value("email")))

    headers = {}
    pid = p.get("id")
    if pid == "core" and cfg_value("core.apiKey"):
        headers["Authorization"] = "Bearer " + cfg_value("core.apiKey")
    if pid == "semanticscholar" and cfg_value("semanticscholar.apiKey"):
        headers["x-api-key"] = cfg_value("semanticscholar.apiKey")

    t0 = time.time()
    LAST_NET_ERROR = None
    try:
        req = urllib.request.Request(url, headers={**{"User-Agent": UA}, **headers})
        with urllib.request.urlopen(req, timeout=12) as r:
            r.read(1)
        ms = int((time.time() - t0) * 1000)
        hint = ""
        if p.get("auth") == "email-optional" and not cfg_value("email"):
            hint = "填 email 可进 polite pool，更稳"
        return "可连接", ms, hint
    except Exception as e:
        ms = int((time.time() - t0) * 1000)
        msg = f"{type(e).__name__}: {e}"
        status = "连不上"
        if "429" in msg:
            status = "限流"
        elif "SSL" in msg or "CERTIFICATE" in msg.upper():
            status = "网络不通"
        elif "401" in msg or "403" in msg:
            status = "需鉴权"
        elif "404" in msg:
            status = "接口变更"
        return status, ms, msg[:60]


def write_config_template():
    tpl = {"_说明": "email 填你的邮箱（CrossRef/Unpaywall 用）；providers 下面按需填 apiKey，留空即不使用该库",
           "email": "", "providers": {}}
    for p in load_registry():
        ck = p.get("configKey")
        if ck and ck != "email":
            tpl["providers"][p["id"]] = {"apiKey": ""}
    CONFIG.write_text(json.dumps(tpl, ensure_ascii=False, indent=2), "utf-8")


# ------------------------------------------------------------------ search

DEFAULT_SOURCES = ["openalex", "crossref", "europepmc", "doaj", "arxiv"]


def cmd_search(args):
    if not args.query:
        print("search 需要查询词", file=sys.stderr)
        return 2

    if args.in_journal:
        return search_in_journal(args)

    sources = args.sources.split(",") if isinstance(args.sources, str) else (args.sources or [])
    sources = [s.strip() for s in sources if s.strip()]
    if not sources:
        sources = list(DEFAULT_SOURCES)
        if args.cn:
            sources.append("cnki")

    reg = {p["id"]: p for p in load_registry()}
    all_items, tried, failed = [], [], []

    for sid in sources:
        p = reg.get(sid)
        if not p:
            failed.append(f"{sid}（未注册）")
            continue
        if sid in NO_SEARCH_API:
            failed.append(f"{p['name']}（无公开检索接口）")
            continue
        if p.get("auth") == "key" and not cfg_value(p.get("configKey")):
            failed.append(f"{p['name']}（缺 key）")
            continue

        global LAST_NET_ERROR
        LAST_NET_ERROR = None
        try:
            if sid == "cnki":
                got = p_cnweb(args.query, max(3, args.limit))
            else:
                got = ADAPTERS[sid](args.query, args.limit)
            if not got and LAST_NET_ERROR:
                failed.append(f"{p['name']}（网络失败）")
            else:
                all_items.extend(got)
                tried.append(p["name"])
        except Exception as e:
            failed.append(f"{p['name']}（报错）")

    results, seen = [], set()
    for it in all_items:
        key = (it.get("doi") or "").lower() or plain(it.get("title"))
        if not key or key in seen:
            continue
        seen.add(key)
        it["score"] = sim(args.query, it.get("title"))
        if it.get("source") in ("Baidu", "360"):
            it["status"] = "LEAD"
        elif it["score"] >= args.threshold:
            it["status"] = "VERIFIED"
        else:
            it["status"] = "WEAK"
        it["citation"] = fmt(it, args.style)
        results.append(it)

    leads = [x for x in results if x.get("source") in ("Baidu", "360")]
    api = sorted([x for x in results if x.get("source") not in ("Baidu", "360")],
                 key=lambda x: x["score"], reverse=True)[:args.limit]
    results = api + leads[:max(3, args.limit)]
    return emit(results, args, tried, failed)


# ------------------------------------------------------------------ 在某刊某年里找

def search_in_journal(args):
    code = resolve_journal(args.in_journal)
    from_year = args.since or (date.today().year - 4)
    to_year = args.until or date.today().year
    stop = {"或", "和", "与", "及", "、", "and", "or", "AND", "OR"}
    terms = [t for t in re.split(r"[\s、]+", args.query) if t and t not in stop]
    if not terms:
        return 2

    print(f"  在《{args.in_journal}》({code}) {from_year}–{to_year} 年目录中找：{' / '.join(terms)}")
    found, failed_issues = [], 0
    for y in range(from_year, to_year + 1):
        empty_run = 0
        for iss in range(1, 13):
            rows, failed = cnki_toc(code, y, iss,
                                 getattr(args, "max_seq", 28), getattr(args, "no_cache", False))
            if failed:
                failed_issues += 1
                print(f"  ⚠ {y} 年第 {iss} 期抓取失败（限流），已跳过，结果可能不全")
                continue
            if not rows:
                empty_run += 1
                if empty_run >= 2:
                    break
                continue
            empty_run = 0
            for r in rows:
                hay = f"{r['title']} {r.get('authors') or ''}"
                if any(t in hay for t in terms):
                    found.append(r)
        if found:
            print(f"    {y} 年累计命中 {len(found)} 篇")

    if failed_issues:
        print(f"  ⚠ 共 {failed_issues} 期没抓到，上面结果不完整；过几分钟重跑，已缓存的期不会重复抓")

    results = []
    for r in found:
        it = make_item("CNKI-TOC", r["title"], r.get("authors"), r.get("year"),
                       r.get("venue"), issue=r.get("issue"), url=r["url"],
                       type_="journal-article", note="知网目录关键词命中（题名/作者），已核到页面")
        it["status"] = "VERIFIED"
        it["citation"] = fmt(it, args.style)
        results.append(it)
    return emit(results, args, [f"《{args.in_journal}》目录（知网）"], [])


# ------------------------------------------------------------------ verify / page / cite

def cmd_verify(args):
    global LAST_NET_ERROR
    results = []
    if args.doi:
        LAST_NET_ERROR = None
        it = confirm_doi(args.doi)
        if it:
            it["status"] = "VERIFIED"
            if args.query:
                it["score"] = sim(args.query, it["title"])
                if it["score"] < args.threshold and "仅查到 DOI" not in it["title"]:
                    it["status"] = "MISMATCH"
            it["citation"] = fmt(it, args.style)
            results.append(it)
        else:
            st = "UNREACHABLE" if LAST_DOI_REASON == "network" else "NOT_FOUND"
            title = "(网络不通，未能核验)" if st == "UNREACHABLE" else "(DOI 无法解析，该 DOI 不存在)"
            results.append(make_item("DOI", title, doi=args.doi, url=f"https://doi.org/{args.doi}",
                                     type_="unknown", status=st,
                                     note=(LAST_NET_ERROR or "") if st == "UNREACHABLE" else ""))
    elif args.url:
        it = get_page_meta(args.url)
        if it:
            it["status"] = "VERIFIED"
            if args.query:
                it["score"] = sim(args.query, it["title"])
                if it["score"] < args.threshold:
                    it["status"] = "MISMATCH"
            it["citation"] = fmt(it, args.style)
            results.append(it)
        else:
            results.append(make_item("Web", "(网络不通或取不到题名)", url=args.url,
                                     type_="unknown", status="UNREACHABLE",
                                     note=LAST_NET_ERROR or ""))
    elif args.query:
        cand = []
        cand += p_openalex(args.query, 5)
        cand += p_crossref(args.query, 5)
        cand += p_arxiv(args.query, 3)
        if args.cn:
            cand += p_cnweb(args.query, 5)
        best, best_score = None, 0.0
        for c in cand:
            s = sim(args.query, c.get("title"))
            if s > best_score:
                best, best_score = c, s
        if best and best_score >= args.threshold:
            if best.get("doi"):
                c = confirm_doi(best["doi"])
                if c and c.get("title") and "仅查到 DOI" not in c["title"]:
                    best = c
            best["status"] = "VERIFIED"
            best["score"] = best_score
            best["citation"] = fmt(best, args.style)
            results.append(best)
        else:
            results.append(make_item("-", "(未检索到匹配文献)", type_="unknown",
                                     status="NOT_FOUND", score=best_score,
                                     note=f"最高相似度 {best_score} < 阈值 {args.threshold}"))
    else:
        print("verify 需要 --doi / --url / --query 之一", file=sys.stderr)
        return 2
    return emit(results, args, [], [])


def cmd_page(args):
    it = get_page_meta(args.url)
    if not it:
        print(f"取不到页面元数据：{args.url}", file=sys.stderr)
        return 2
    it["status"] = "VERIFIED"
    it["citation"] = fmt(it, args.style)
    return emit([it], args, [], [])


def cmd_cite(args):
    it = confirm_doi(args.doi) if args.doi else get_page_meta(args.url)
    if not it:
        print("无法解析该 DOI/URL", file=sys.stderr)
        return 2
    it["status"] = "VERIFIED"
    if args.style == "both":
        it["citation"] = "GB/T: " + format_gbt(it) + "\n        APA:  " + format_apa(it)
    else:
        it["citation"] = fmt(it, args.style)
    return emit([it], args, [], [])


def cmd_toc(args):
    code = resolve_journal(args.journal)
    if not code:
        print("toc 需要 -Journal（刊号如 WYJY，或刊名如 外语界）", file=sys.stderr)
        return 2
    year = args.year or date.today().year
    issues = [args.issue] if args.issue else range(1, 13)

    all_rows, empty_run = [], 0
    for iss in issues:
        rows, failed = cnki_toc(code, year, iss, args.max_seq, args.no_cache)
        if not rows:
            empty_run += 1
            if not args.issue and empty_run >= 2:
                break
            continue
        empty_run = 0
        for r in rows:
            r["issue"] = iss
            all_rows.append(r)
        if not args.issue:
            print(f"  {year} 年第 {iss} 期：{len(rows)} 篇")

    if args.match:
        all_rows = [r for r in all_rows
                    if re.search(args.match, r["title"]) or re.search(args.match, r.get("authors") or "")]

    if not all_rows:
        print(f"没有枚举到内容，确认刊号对不对：{code}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(all_rows, ensure_ascii=False, indent=1))
        return 0

    venue = all_rows[0].get("venue") or code
    print(f"\n《{venue}》{year} 年 · 共 {len(all_rows)} 篇")
    print("─" * 92)
    for r in all_rows:
        print(f"[第{r['issue']}期-{r['seq']:>2}] {r['title']}")
        print(f"             {r.get('authors') or '（作者未取到）'}")
        print(f"             {r['url']}")
    print(f"\n共 {len(all_rows)} 条，题名与作者均取自知网页面，可直接引用")
    return 0


# ------------------------------------------------------------------ 输出

def fmt(it, style):
    if style == "apa":
        return format_apa(it)
    if style == "both":
        return "GB/T: " + format_gbt(it) + "\n        APA:  " + format_apa(it)
    return format_gbt(it)


def emit(results, args, tried, failed):
    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=1))
    else:
        for i, r in enumerate(results, 1):
            show_item(r, i)
        ok = sum(1 for r in results if r.get("status") == "VERIFIED")
        print("\n" + "─" * 78)
        print(f"SUMMARY: verified={ok}  未核到={len(results) - ok}")
        if ok == 0:
            print("提示：没有一条达到阈值。不要凭记忆补一篇——要么换关键词，要么如实说\"查不到\"。")
        if tried or failed:
            cov = "覆盖："
            parts = []
            if tried:
                parts.append("已查 " + "、".join(tried))
            if failed:
                parts.append("未查 " + "、".join(failed))
            print(cov + "；".join(parts))
        if ok == 0 and LAST_NET_ERROR:
            print("⚠ 本次有网络错误，结果不可信；先跑 doctor 确认连通性，不要据此判断文献不存在。")
            print(f"  最近错误：{LAST_NET_ERROR}")
    return 0 if any(r.get("status") == "VERIFIED" for r in results) else 2


# ------------------------------------------------------------------ 入口

def build_parser():
    p = argparse.ArgumentParser(prog="refcheck", description="论文引用防伪核验")
    sub = p.add_subparsers(dest="cmd")

    def common(sp):
        sp.add_argument("-Style", "--style", default="gbt", choices=["gbt", "apa", "both"])
        sp.add_argument("-Json", "--json", action="store_true")
        sp.add_argument("-Since", "--since", type=int, default=0)
        sp.add_argument("-Until", "--until", type=int, default=0)

    sp = sub.add_parser("doctor", help="数据源自检")
    sp.add_argument("-InitConfig", "--init-config", action="store_true")

    sp = sub.add_parser("search", help="多源检索")
    sp.add_argument("query", nargs="?", default="")
    sp.add_argument("-Limit", "--limit", type=int, default=5)
    sp.add_argument("-Sources", "--sources", default="")
    sp.add_argument("-Cn", "--cn", action="store_true")
    sp.add_argument("-In", "--in-journal", dest="in_journal", default="")
    sp.add_argument("-Threshold", "--threshold", type=float, default=0.8)
    common(sp)

    sp = sub.add_parser("verify", help="核验一条")
    sp.add_argument("-Query", "--query", default="")
    sp.add_argument("-Doi", "--doi", default="")
    sp.add_argument("-Url", "--url", default="")
    sp.add_argument("-Threshold", "--threshold", type=float, default=0.8)
    sp.add_argument("-Cn", "--cn", action="store_true")
    common(sp)

    sp = sub.add_parser("page", help="抓页面取元数据")
    sp.add_argument("-Url", "--url", required=True)
    common(sp)

    sp = sub.add_parser("cite", help="生成规范引用")
    sp.add_argument("-Doi", "--doi", default="")
    sp.add_argument("-Url", "--url", default="")
    common(sp)

    sp = sub.add_parser("toc", help="枚举某刊目录")
    sp.add_argument("-Journal", "--journal", required=True)
    sp.add_argument("-Year", "--year", type=int, default=0)
    sp.add_argument("-Issue", "--issue", type=int, default=0)
    sp.add_argument("-Match", "--match", default="")
    sp.add_argument("-MaxSeq", "--max-seq", type=int, default=28)
    sp.add_argument("-NoCache", "--no-cache", action="store_true")
    sp.add_argument("-Json", "--json", action="store_true")
    return p


def main(argv=None):
    global SINCE, UNTIL, WITH_ABS, TIMEOUT
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.cmd:
        parser.print_help()
        return 0

    SINCE = getattr(args, "since", 0)
    UNTIL = getattr(args, "until", 0)
    WITH_ABS = getattr(args, "with_abstract", False)

    handlers = {"doctor": cmd_doctor, "search": cmd_search, "verify": cmd_verify,
                "page": cmd_page, "cite": cmd_cite, "toc": cmd_toc}
    return handlers[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())