import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import kazumi_source_probe as probe  # noqa: E402


def test_match_score_marks_ambiguous_multi_season_candidate() -> None:
    score = probe.score_candidate(
        "攻壳机动队 STAND ALONE COMPLEX 合集 1-2季 剧场版",
        ["攻壳机动队STAND ALONE COMPLEX"],
    )

    assert score["confidence"] == "low"
    assert "ambiguous_collection" in score["reasons"]


def test_episode_non_http_is_terminal_path_status() -> None:
    assert probe.classify_episode_url("javascript:void(0)") == "episode_non_http"


def test_episode_mapping_warns_when_road_is_shorter_than_target_episode() -> None:
    mapping = probe.score_episode_mapping(
        requested_episode=13,
        road_episode_titles=["01", "02", "03"],
    )

    assert mapping["status"] == "episode_missing"
    assert mapping["confidence"] == "none"


def test_episode_mapping_flags_collection_sized_road_as_ambiguous() -> None:
    mapping = probe.score_episode_mapping(
        requested_episode=13,
        road_episode_titles=[str(i) for i in range(1, 80)],
    )

    assert mapping["status"] == "mapped"
    assert mapping["confidence"] == "low"
    assert "collection_sized_road" in mapping["reasons"]


def test_child_xpath_stays_scoped_to_current_node() -> None:
    plugin = {
        "baseURL": "https://example.test",
        "chapterRoads": "//div[@class='road']",
        "chapterResult": "//a",
    }
    html = """
    <html>
      <body>
        <nav><a href="/wrong">导航</a></nav>
        <div class="road"><a href="/ep1">第01集</a></div>
      </body>
    </html>
    """

    roads = probe.parse_roads(plugin, html)

    assert [[entry.title for entry in road] for road in roads] == [["第01集"]]
    assert roads[0][0].url == "https://example.test/ep1"


def test_subject_context_keeps_unique_subject_and_episode_identity() -> None:
    subject = {
        "id": 324,
        "name": "攻殻機動隊 STAND ALONE COMPLEX",
        "name_cn": "攻壳机动队 STAND ALONE COMPLEX",
        "infobox": [
            {"key": "别名", "value": [{"v": "Ghost in the Shell: Stand Alone Complex"}]},
        ],
    }
    episode = {
        "id": 12236,
        "ep": 13,
        "sort": 13,
        "name": "≠テロリスト NOT EQUAL",
        "name_cn": "恐怖份子 NOT EQUAL",
    }

    context = probe.build_subject_context(subject, episode)

    assert context["subject_id"] == 324
    assert context["episode"]["id"] == 12236
    assert "攻壳机动队 STAND ALONE COMPLEX" in context["names"]
    assert "Ghost in the Shell: Stand Alone Complex" in context["names"]


def test_broad_keyword_does_not_pollute_subject_match_names() -> None:
    context = {
        "names": [
            "攻壳机动队 STAND ALONE COMPLEX",
            "攻殻機動隊 STAND ALONE COMPLEX",
        ]
    }

    names = probe.build_candidate_match_names(
        subject_context=context,
        explicit_subject_names=[],
        keyword="攻壳机动队",
    )

    assert "攻壳机动队" not in names


def test_plugin_status_requires_media_ok_not_just_media_probe_done() -> None:
    assert (
        probe.classify_plugin_target_status(
            target_path_count=1,
            playback_statuses=["media_probe_done"],
            media_probe_results=["media_error:HTTPError"],
        )
        == "target_media_failed"
    )
    assert (
        probe.classify_plugin_target_status(
            target_path_count=1,
            playback_statuses=["media_probe_done"],
            media_probe_results=["media_ok:200:256b"],
        )
        == "target_media_ok"
    )


def test_normalize_media_url_unescapes_javascript_slashes() -> None:
    assert (
        probe.normalize_media_url("/\\/vod3.example.com\\/20220421\\/index.m3u8")
        == "//vod3.example.com/20220421/index.m3u8"
    )
