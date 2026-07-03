import argparse
import concurrent.futures
import json
import re
import sys
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote, urljoin, urlparse

import requests
from lxml import html


PLUGIN_INDEX_URLS = [
    "https://raw.githubusercontent.com/Predidit/KazumiRules/refs/heads/main/index.json",
    "https://cdn.gh-proxy.org/https://raw.githubusercontent.com/Predidit/KazumiRules/refs/heads/main/index.json",
]
PLUGIN_BASE_URLS = [
    "https://raw.githubusercontent.com/Predidit/KazumiRules/refs/heads/main/",
    "https://cdn.gh-proxy.org/https://raw.githubusercontent.com/Predidit/KazumiRules/refs/heads/main/",
]
BANGUMI_SUBJECT_URL = "https://api.bgm.tv/v0/subjects/{subject_id}"
BANGUMI_EPISODES_URL = (
    "https://api.bgm.tv/v0/episodes?subject_id={subject_id}&type=0&limit=100&offset=0"
)

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/126.0.0.0 Safari/537.36"
)


@dataclass
class SearchItem:
    name: str
    url: str


@dataclass
class EpisodeEntry:
    title: str
    url: str


def request_text(session: requests.Session, method: str, url: str, *, timeout: float) -> tuple[int, str, str]:
    headers = {
        "user-agent": UA,
        "accept-language": "zh-CN,zh;q=0.9,en;q=0.8",
        "connection": "keep-alive",
    }
    if method == "POST":
        parsed = urlparse(url)
        data = dict(pair.split("=", 1) if "=" in pair else (pair, "") for pair in parsed.query.split("&") if pair)
        post_url = parsed._replace(query="").geturl()
        response = session.post(post_url, headers=headers, data=data, timeout=timeout)
    else:
        response = session.get(url, headers=headers, timeout=timeout)
    response.raise_for_status()
    if not response.encoding or response.encoding.lower() in {"iso-8859-1", "ascii"}:
        response.encoding = response.apparent_encoding
    return response.status_code, response.text or "", response.url


def normalize_text(value: str) -> str:
    return re.sub(r"\s+", "", value or "").lower()


def score_candidate(title: str, subject_names: list[str]) -> dict[str, Any]:
    normalized_title = normalize_text(title)
    normalized_names = [normalize_text(name) for name in subject_names if name]
    reasons: list[str] = []
    confidence = "none"

    if any(name and name in normalized_title for name in normalized_names):
        confidence = "medium"
        reasons.append("title_contains_subject_name")
    elif normalized_title:
        confidence = "low"
        reasons.append("title_not_exact_subject")

    ambiguous_patterns = [
        r"合集",
        r"全[集季]",
        r"\d+\s*[-~]\s*\d+\s*季",
        r"[123456789一二三四五六七八九十]+季",
        r"剧场版",
        r"ova",
        r"movie",
    ]
    if any(re.search(pattern, title, re.I) for pattern in ambiguous_patterns):
        reasons.append("ambiguous_collection")
        if confidence != "none":
            confidence = "low"

    return {
        "confidence": confidence,
        "reasons": reasons,
    }


def classify_episode_url(url: str) -> str:
    if not url:
        return "episode_missing"
    if not url.startswith(("http://", "https://")):
        return "episode_non_http"
    return "episode_http"


def score_episode_mapping(
    *,
    requested_episode: int,
    road_episode_titles: list[str],
) -> dict[str, Any]:
    if requested_episode <= 0:
        return {
            "status": "episode_invalid",
            "confidence": "none",
            "reasons": ["invalid_requested_episode"],
        }
    if len(road_episode_titles) < requested_episode:
        return {
            "status": "episode_missing",
            "confidence": "none",
            "reasons": ["road_shorter_than_requested_episode"],
        }

    reasons: list[str] = ["position_mapping"]
    confidence = "medium"
    if len(road_episode_titles) > 40:
        reasons.append("collection_sized_road")
        confidence = "low"

    target_title = road_episode_titles[requested_episode - 1]
    if target_title and not re.search(r"\d|第|话|集|ep", target_title, re.I):
        reasons.append("target_title_not_episode_like")
        confidence = "low"

    return {
        "status": "mapped",
        "confidence": confidence,
        "reasons": reasons,
        "target_title": target_title,
    }


def infobox_aliases(subject: dict[str, Any]) -> list[str]:
    aliases: list[str] = []
    for item in subject.get("infobox") or []:
        if item.get("key") != "别名":
            continue
        value = item.get("value")
        if isinstance(value, str):
            aliases.append(value)
        elif isinstance(value, list):
            for entry in value:
                if isinstance(entry, dict) and entry.get("v"):
                    aliases.append(str(entry["v"]))
                elif isinstance(entry, str):
                    aliases.append(entry)
    return aliases


def unique_nonempty(values: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        value = (value or "").strip()
        if not value or value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def build_subject_context(subject: dict[str, Any], episode: dict[str, Any] | None) -> dict[str, Any]:
    names = unique_nonempty(
        [
            subject.get("name_cn") or "",
            subject.get("name") or "",
            *infobox_aliases(subject),
        ]
    )
    context: dict[str, Any] = {
        "subject_id": subject.get("id"),
        "name": subject.get("name"),
        "name_cn": subject.get("name_cn"),
        "names": names,
        "keyword": subject.get("name_cn") or subject.get("name") or (names[0] if names else ""),
    }
    if episode is not None:
        context["episode"] = {
            "id": episode.get("id"),
            "ep": episode.get("ep"),
            "sort": episode.get("sort"),
            "name": episode.get("name"),
            "name_cn": episode.get("name_cn"),
        }
    return context


def build_candidate_match_names(
    *,
    subject_context: dict[str, Any] | None,
    explicit_subject_names: list[str],
    keyword: str,
) -> list[str]:
    if subject_context is not None:
        return unique_nonempty(
            [
                *(subject_context.get("names") or []),
                *explicit_subject_names,
            ]
        )
    return unique_nonempty([*explicit_subject_names, keyword])


def classify_plugin_target_status(
    *,
    target_path_count: int,
    playback_statuses: list[str],
    media_probe_results: list[str],
) -> str:
    if target_path_count == 0:
        return "search_ok_no_target_episode_path"
    if any(result.startswith("media_ok:") for result in media_probe_results):
        return "target_media_ok"
    if media_probe_results:
        return "target_media_failed"
    if any(status == "episode_page_ok_needs_webview" for status in playback_statuses):
        return "target_needs_webview"
    if playback_statuses:
        return "target_probe_terminal"
    return "target_probe_inconclusive"


def load_bangumi_subject_context(
    session: requests.Session,
    *,
    subject_id: int,
    episode_index: int,
    timeout: float,
) -> dict[str, Any]:
    subject = fetch_json_from_any(
        session,
        [BANGUMI_SUBJECT_URL.format(subject_id=subject_id)],
        timeout=timeout,
    )
    subject["id"] = subject_id
    episodes_payload = fetch_json_from_any(
        session,
        [BANGUMI_EPISODES_URL.format(subject_id=subject_id)],
        timeout=timeout,
    )
    episodes = episodes_payload.get("data") or []
    episode = next(
        (
            item
            for item in episodes
            if item.get("ep") == episode_index or item.get("sort") == episode_index
        ),
        None,
    )
    return build_subject_context(subject, episode)


def fetch_json_from_any(session: requests.Session, urls: list[str], *, timeout: float) -> Any:
    last_error: Exception | None = None
    for url in urls:
        try:
            _, text, _ = request_text(session, "GET", url, timeout=timeout)
            return json.loads(text)
        except Exception as exc:  # noqa: BLE001 - diagnostic tool
            last_error = exc
    raise RuntimeError(f"failed to fetch JSON: {last_error}")


def load_remote_plugins(session: requests.Session, *, timeout: float, limit: int | None) -> list[dict[str, Any]]:
    index = fetch_json_from_any(session, PLUGIN_INDEX_URLS, timeout=timeout)
    names = [item["name"] for item in index if item.get("name")]
    if limit is not None:
        names = names[:limit]
    plugins: list[dict[str, Any]] = []
    for name in names:
        urls = [base + quote(name) + ".json" for base in PLUGIN_BASE_URLS]
        try:
            plugins.append(fetch_json_from_any(session, urls, timeout=timeout))
        except Exception as exc:  # noqa: BLE001 - keep going across rules
            plugins.append({"name": name, "_load_error": str(exc)})
    return plugins


def xpath_first_text(node: Any, xpath: str) -> str:
    if not xpath:
        return ""
    try:
        result = node.xpath(scoped_xpath(xpath))
    except Exception:
        return ""
    if not result:
        return ""
    first = result[0]
    if isinstance(first, str):
        return first.strip()
    return (first.text_content() or "").strip()


def xpath_first_href(node: Any, xpath: str) -> str:
    if not xpath:
        return ""
    try:
        result = node.xpath(scoped_xpath(xpath))
    except Exception:
        return ""
    if not result:
        return ""
    first = result[0]
    if isinstance(first, str):
        return first.strip()
    return first.get("href") or ""


def parse_search_items(plugin: dict[str, Any], text: str) -> list[SearchItem]:
    doc = html.fromstring(text)
    items: list[SearchItem] = []
    for node in doc.xpath(plugin.get("searchList") or ""):
        name = xpath_first_text(node, plugin.get("searchName") or "")
        href = xpath_first_href(node, plugin.get("searchResult") or "")
        if name or href:
            items.append(SearchItem(name=name, url=normalize_url(plugin, href)))
    return items


def scoped_xpath(xpath: str) -> str:
    if xpath.startswith("//"):
        return "." + xpath
    return xpath


def parse_roads(plugin: dict[str, Any], text: str) -> list[list[EpisodeEntry]]:
    chapter_roads = plugin.get("chapterRoads") or ""
    chapter_result = plugin.get("chapterResult") or ""
    if not chapter_roads or not chapter_result:
        return []
    doc = html.fromstring(text)
    roads: list[list[EpisodeEntry]] = []
    for road_node in doc.xpath(chapter_roads):
        episodes: list[EpisodeEntry] = []
        for ep_node in road_node.xpath(scoped_xpath(chapter_result)):
            href = ep_node.get("href") if hasattr(ep_node, "get") else ""
            if href:
                title = ep_node.text_content().strip() if hasattr(ep_node, "text_content") else ""
                episodes.append(EpisodeEntry(title=title, url=normalize_url(plugin, href)))
        if episodes:
            roads.append(episodes)
    return roads


def normalize_url(plugin: dict[str, Any], value: str) -> str:
    value = (value or "").strip()
    if not value:
        return ""
    if value.startswith(("javascript:", "mailto:", "#")):
        return value
    base_url = plugin.get("baseURL") or plugin.get("baseUrl") or ""
    return urljoin(base_url, value)


def looks_like_media(text: str) -> list[str]:
    matches = set(re.findall(r"https?://[^'\"<>\s]+?\.(?:m3u8|mp4)(?:\?[^'\"<>\s]*)?", text, re.I))
    matches.update(re.findall(r"(?:(?:/|\.{1,2}/)[^'\"<>\s]+?\.(?:m3u8|mp4)(?:\?[^'\"<>\s]*)?)", text, re.I))
    return sorted(normalize_media_url(match) for match in matches)


def normalize_media_url(url: str) -> str:
    return url.replace("\\/", "/")


def probe_media(session: requests.Session, url: str, *, timeout: float) -> str:
    try:
        response = session.get(url, headers={"user-agent": UA}, timeout=timeout, stream=True)
        response.raise_for_status()
        sample = next(response.iter_content(chunk_size=256), b"")
        if sample:
            return f"media_ok:{response.status_code}:{len(sample)}b"
        return f"media_empty:{response.status_code}"
    except requests.Timeout:
        return "media_timeout"
    except Exception as exc:  # noqa: BLE001
        return f"media_error:{type(exc).__name__}"


def probe_episode_page(
    session: requests.Session,
    episode_url: str,
    *,
    timeout: float,
) -> dict[str, Any]:
    url_status = classify_episode_url(episode_url)
    if url_status != "episode_http":
        return {"status": url_status}

    started = time.monotonic()
    _, ep_html, final_ep_url = request_text(session, "GET", episode_url, timeout=timeout)
    media_urls = looks_like_media(ep_html)
    result: dict[str, Any] = {
        "status": "episode_page_ok_needs_webview",
        "episode_final_url": final_ep_url,
        "episode_bytes": len(ep_html),
        "episode_ms": int((time.monotonic() - started) * 1000),
        "static_media_count": len(media_urls),
        "static_media": media_urls[:3],
    }
    if not media_urls:
        return result

    media_url = urljoin(final_ep_url, media_urls[0])
    result["media_probe"] = probe_media(session, media_url, timeout=timeout)
    result["status"] = "media_probe_done"
    return result


def probe_plugin(
    plugin: dict[str, Any],
    keyword: str,
    subject_names: list[str],
    subject_context: dict[str, Any] | None,
    episode_index: int,
    timeout: float,
    max_items: int,
    max_roads: int,
) -> dict[str, Any]:
    name = plugin.get("name") or "<unknown>"
    result: dict[str, Any] = {
        "name": name,
        "keyword": keyword,
        "subject": subject_context,
        "requested_episode": episode_index,
    }
    if plugin.get("_load_error"):
        result["status"] = "plugin_load_error"
        result["error"] = plugin["_load_error"]
        return result

    with requests.Session() as session:
        try:
            search_url = (plugin.get("searchURL") or "").replace("@keyword", quote(keyword))
            _, search_html, final_search_url = request_text(
                session, "POST" if plugin.get("usePost") else "GET", search_url, timeout=timeout
            )
            result["search_url"] = final_search_url
            result["search_bytes"] = len(search_html)
            items = parse_search_items(plugin, search_html)
            result["search_count"] = len(items)
            result["items"] = [{"name": item.name, "url": item.url} for item in items[:max_items]]
            if not items:
                result["status"] = "no_search_result"
                return result

            candidate_results = []
            target_path_count = 0
            playback_statuses: list[str] = []
            media_probe_results: list[str] = []
            for candidate_index, item in enumerate(items[:max_items]):
                candidate: dict[str, Any] = {
                    "candidate_index": candidate_index,
                    "title": item.name,
                    "url": item.url,
                    "match": score_candidate(item.name, subject_names or [keyword]),
                }
                try:
                    _, detail_html, detail_url = request_text(session, "GET", item.url, timeout=timeout)
                    candidate["detail_url"] = detail_url
                    roads = parse_roads(plugin, detail_html)
                    candidate["road_count"] = len(roads)
                    candidate["roads"] = []
                    for road_index, road in enumerate(roads[:max_roads]):
                        road_titles = [entry.title for entry in road]
                        road_result: dict[str, Any] = {
                            "road_index": road_index,
                            "episode_count": len(road),
                            "first_titles": road_titles[:5],
                            "mapping": score_episode_mapping(
                                requested_episode=episode_index,
                                road_episode_titles=road_titles,
                            ),
                        }
                        if len(road) >= episode_index:
                            target_entry = road[episode_index - 1]
                            target_path_count += 1
                            road_result["target_episode"] = {
                                "title": target_entry.title,
                                "url": target_entry.url,
                            }
                            try:
                                playback = probe_episode_page(
                                    session,
                                    target_entry.url,
                                    timeout=timeout,
                                )
                            except requests.Timeout:
                                playback = {"status": "episode_page_timeout"}
                            except Exception as exc:  # noqa: BLE001
                                playback = {
                                    "status": "episode_page_error",
                                    "error": f"{type(exc).__name__}: {exc}",
                                }
                            road_result["playback"] = playback
                            playback_statuses.append(playback["status"])
                            if playback.get("media_probe"):
                                media_probe_results.append(playback["media_probe"])
                        candidate["roads"].append(road_result)
                    if not roads:
                        candidate["status"] = "no_roads"
                    else:
                        candidate["status"] = "roads_parsed"
                except requests.Timeout:
                    candidate["status"] = "detail_timeout"
                except Exception as exc:  # noqa: BLE001
                    candidate["status"] = "detail_error"
                    candidate["error"] = f"{type(exc).__name__}: {exc}"
                candidate_results.append(candidate)

            result["candidates"] = candidate_results
            result["target_path_count"] = target_path_count
            result["target_statuses"] = sorted(set(playback_statuses))
            result["media_probe_results"] = sorted(set(media_probe_results))
            result["status"] = classify_plugin_target_status(
                target_path_count=target_path_count,
                playback_statuses=playback_statuses,
                media_probe_results=media_probe_results,
            )
            return result
        except requests.Timeout:
            result["status"] = "timeout"
            return result
        except Exception as exc:  # noqa: BLE001
            result["status"] = "error"
            result["error"] = f"{type(exc).__name__}: {exc}"
            return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("keyword", nargs="?")
    parser.add_argument("--subject-id", type=int)
    parser.add_argument(
        "--subject-name",
        action="append",
        default=[],
        help="Subject name or alias used only for candidate confidence scoring.",
    )
    parser.add_argument("--episode", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=12)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--max-items", type=int, default=3)
    parser.add_argument("--max-roads", type=int, default=3)
    parser.add_argument("--output")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    with requests.Session() as session:
        subject_context = None
        if args.subject_id is not None:
            subject_context = load_bangumi_subject_context(
                session,
                subject_id=args.subject_id,
                episode_index=args.episode,
                timeout=args.timeout,
            )
        keyword = args.keyword or (
            subject_context["keyword"] if subject_context is not None else None
        )
        if not keyword:
            parser.error("keyword is required when --subject-id is not provided or has no title")
        subject_names = build_candidate_match_names(
            subject_context=subject_context,
            explicit_subject_names=args.subject_name,
            keyword=keyword,
        )
        plugins = load_remote_plugins(session, timeout=args.timeout, limit=args.limit)

    output_handle = open(args.output, "w", encoding="utf-8") if args.output else None
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = [
            executor.submit(
                probe_plugin,
                plugin,
                keyword,
                subject_names,
                subject_context,
                args.episode,
                args.timeout,
                args.max_items,
                args.max_roads,
            )
            for plugin in plugins
        ]
        for future in concurrent.futures.as_completed(futures):
            line = json.dumps(future.result(), ensure_ascii=False)
            if not args.quiet:
                print(line, flush=True)
            if output_handle:
                output_handle.write(line + "\n")
                output_handle.flush()
    if output_handle:
        output_handle.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
