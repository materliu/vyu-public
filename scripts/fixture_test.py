#!/usr/bin/env python3
"""Test the controlled HTTP fixtures, including partial download and offline mode."""
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / "fixtures" / "media"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class FixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.port = free_port()
        cls.peer = free_port()
        while cls.peer == cls.port:
            cls.peer = free_port()
        cls.base = f"http://127.0.0.1:{cls.port}"
        cls.process = subprocess.Popen([sys.executable, str(ROOT / "fixtures/server.py"), "--port", str(cls.port), "--peer-port", str(cls.peer)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            try:
                with urlopen(cls.base + "/__health", timeout=0.2) as response:
                    if json.load(response)["ready"]:
                        return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("fixture server did not start")

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)

    def request(self, path, headers=None, method=None, data=None):
        return urlopen(Request(self.base + path, headers=headers or {}, method=method, data=data), timeout=5)

    def test_01_direct_media_has_expected_content(self):
        with self.request("/media/direct.mp4") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Content-Type"], "video/mp4")
            actual = response.read()
        self.assertEqual(hashlib.sha256(actual).digest(), hashlib.sha256((MEDIA / "direct.mp4").read_bytes()).digest())

    def test_02_pages_have_no_download_links(self):
        for path in ("/direct", "/iframe", "/cross-frame", "/dynamic", "/multiple-videos", "/head-denied", "/head-unsupported", "/browser-session", "/context-required", "/context-frame", "/hls", "/hls-separate", "/blob", "/mse", "/dash", "/expired", "/forbidden", "/silent", "/corrupt", "/slow", "/protected"):
            with self.subTest(path=path), self.request(path) as response:
                html = response.read().decode()
                self.assertIn("<!doctype html>", html)
                self.assertNotIn(" download=", html)
                self.assertNotIn(">下载<", html)

    def test_03_cross_origin_frame(self):
        with self.request("/cross-frame") as response:
            self.assertIn(f":{self.peer}/direct", response.read().decode())
        with urlopen(f"http://127.0.0.1:{self.peer}/direct", timeout=2) as response:
            self.assertEqual(response.status, 200)

    def test_04_range_and_suffix(self):
        source = (MEDIA / "direct.mp4").read_bytes()
        with self.request("/media/direct.mp4", {"Range": "bytes=13-71"}) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.headers["Content-Range"], f"bytes 13-71/{len(source)}")
            self.assertEqual(response.read(), source[13:72])
        with self.request("/media/direct.mp4", {"Range": "bytes=-20"}) as response:
            self.assertEqual(response.read(), source[-20:])

    def test_05_invalid_range(self):
        for value in ("bytes=999999999-", "bytes=20-10", "bytes=-0", "bytes=abc", "bytes=0-1,3-5"):
            with self.subTest(value=value), self.assertRaises(HTTPError) as error:
                self.request("/media/direct.mp4", {"Range": value})
            self.assertEqual(error.exception.code, 416)

    def test_06_cancel_and_resume_produces_exact_file(self):
        with self.request("/slow.mp4") as response:
            prefix = response.read(32 * 1024)
            etag = response.headers["ETag"]
        with self.request("/media/direct.mp4", {"Range": f"bytes={len(prefix)}-", "If-Range": etag}) as response:
            self.assertEqual(response.status, 206)
            restored = prefix + response.read()
        self.assertEqual(hashlib.sha256(restored).digest(), hashlib.sha256((MEDIA / "direct.mp4").read_bytes()).digest())

    def test_07_changed_etag_restarts(self):
        with self.request("/media/direct.mp4", {"Range": "bytes=100-", "If-Range": '"old-entity"'}) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(len(response.read()), (MEDIA / "direct.mp4").stat().st_size)

    def test_08_rejections_are_distinct(self):
        for path, code in (("/expired.mp4?expires=1", 410), ("/forbidden.mp4", 403), ("/media/missing.mp4", 404), ("/media/../../project.yml", 404)):
            with self.subTest(path=path), self.assertRaises(HTTPError) as error:
                self.request(path)
            self.assertEqual(error.exception.code, code)
        with self.request(f"/expired.mp4?expires={int(time.time())+30}") as response:
            self.assertEqual(response.status, 200)

    def test_09_offline_media_fails_and_recovers(self):
        try:
            with self.request("/__control", {"Content-Type": "application/json"}, "POST", b'{"offline":true}') as response:
                self.assertTrue(json.load(response)["offline"])
            with self.request("/__health") as response:
                self.assertTrue(json.load(response)["offline"])
            with self.assertRaises(HTTPError) as error:
                self.request("/media/direct.mp4")
            self.assertEqual(error.exception.code, 503)
        finally:
            with self.request("/__control", {"Content-Type": "application/json"}, "POST", b'{"offline":false}') as response:
                self.assertFalse(json.load(response)["offline"])
        with self.request("/media/direct.mp4", method="HEAD") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), b"")

    def probe(self, path):
        return json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(MEDIA / path)], text=True))

    def test_10_generated_media_duration_and_tracks(self):
        for path in ("direct.mp4", "mse.mp4", "hls/master.m3u8", "hls-separate/master.m3u8"):
            with self.subTest(path=path):
                probe = self.probe(path)
                self.assertAlmostEqual(float(probe["format"]["duration"]), 8.0, delta=0.15)
                kinds = {s["codec_type"] for s in probe["streams"]}
                self.assertIn("audio", kinds)
                self.assertIn("video", kinds)
        self.assertEqual({s["codec_type"] for s in self.probe("silent.mp4")["streams"]}, {"video"})

    def test_11_hls_variants_and_relative_links(self):
        for family in ("hls", "hls-separate"):
            manifest = (MEDIA / family / "master.m3u8").read_text()
            self.assertEqual(manifest.count("#EXT-X-STREAM-INF:"), 2)
            for variant in ("180p", "360p"):
                playlist = (MEDIA / family / variant / "index.m3u8").read_text()
                self.assertIn("#EXT-X-ENDLIST", playlist)
                self.assertEqual(playlist.count("#EXTINF:"), 4)
                for line in playlist.splitlines():
                    if line and not line.startswith("#"):
                        self.assertTrue((MEDIA / family / variant / line).is_file())
        self.assertIn('AUDIO="sound"', (MEDIA / "hls-separate/master.m3u8").read_text())

    def test_12_corruption_and_protection_are_not_success_media(self):
        result = subprocess.run(["ffprobe", "-v", "quiet", str(MEDIA / "corrupt.mp4")], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        manifest = (MEDIA / "protected/index.m3u8").read_text()
        self.assertIn('KEYFORMAT="com.apple.streamingkeydelivery"', manifest)
        self.assertIn("skd://", manifest)

    def test_13_inventory_matches_files(self):
        inventory = json.loads((MEDIA / "inventory.json").read_text())
        for item in inventory["files"]:
            content = (MEDIA / item["path"]).read_bytes()
            self.assertEqual(len(content), item["bytes"])
            self.assertEqual(hashlib.sha256(content).hexdigest(), item["sha256"])

    def test_14_invalid_control_input(self):
        for payload in (b'{"offline":"true"}', b"not json", b"[]"):
            with self.subTest(payload=payload), self.assertRaises(HTTPError) as error:
                self.request("/__control", {"Content-Type": "application/json"}, "POST", payload)
            self.assertEqual(error.exception.code, 400)

    def test_15_dash_separate_tracks_are_complete(self):
        # Homebrew FFmpeg need not include the XML-based DASH demuxer. Validate
        # the generated MPD and each complete init+fragment stream separately.
        tree = ET.parse(MEDIA / "dash/manifest.mpd")
        self.assertEqual(tree.getroot().attrib["mediaPresentationDuration"], "PT8.0S")
        ns = {"d": "urn:mpeg:dash:schema:mpd:2011"}
        sets = tree.findall(".//d:AdaptationSet", ns)
        self.assertEqual({s.attrib["contentType"] for s in sets}, {"audio", "video"})
        with tempfile.TemporaryDirectory(prefix="vyu-dash-") as folder:
            for index, kind in ((0, "video"), (1, "audio")):
                parts = [MEDIA / f"dash/init-stream{index}.m4s", *sorted((MEDIA / "dash").glob(f"chunk-stream{index}-*.m4s"))]
                target = Path(folder) / f"track-{index}.mp4"
                target.write_bytes(b"".join(path.read_bytes() for path in parts))
                probe = self.probe(target)
                self.assertEqual({s["codec_type"] for s in probe["streams"]}, {kind})
                self.assertAlmostEqual(float(probe["format"]["duration"]), 8.0, delta=0.15)

    def test_16_head_rejection_and_get_authorization_are_independent(self):
        with self.assertRaises(HTTPError) as error:
            self.request("/head-denied.mp4", method="HEAD")
        self.assertEqual(error.exception.code, 403)
        source = (MEDIA / "direct.mp4").read_bytes()
        with self.request("/head-denied.mp4", {"Range": "bytes=0-0"}) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.headers["Content-Range"], f"bytes 0-0/{len(source)}")
            self.assertEqual(response.read(), source[:1])
        with self.request("/head-denied.mp4") as response:
            self.assertEqual(response.read(), source)
        for method, status in (("HEAD", 405), ("GET", 403)):
            with self.subTest(method=method), self.assertRaises(HTTPError) as error:
                self.request("/head-unsupported.mp4", method=method)
            self.assertEqual(error.exception.code, status)

    def test_17_player_context_requires_frame_referer_webkit_and_cookie(self):
        with self.request("/context-frame") as response:
            self.assertIn("vyu_fixture_session=ready", response.headers["Set-Cookie"])
            self.assertIn("HttpOnly", response.headers["Set-Cookie"])
            self.assertIn("/context-required.mp4", response.read().decode())
        headers = {"Referer": self.base + "/context-frame", "User-Agent": "Fixture AppleWebKit/605.1.15", "Cookie": "vyu_fixture_session=ready"}
        for missing in headers:
            incomplete = {key: value for key, value in headers.items() if key != missing}
            with self.subTest(missing=missing), self.assertRaises(HTTPError) as error:
                self.request("/context-required.mp4", incomplete)
            self.assertEqual(error.exception.code, 403)
        wrong_frame = {**headers, "Referer": self.base + "/context-required"}
        with self.assertRaises(HTTPError) as error:
            self.request("/context-required.mp4", wrong_frame)
        self.assertEqual(error.exception.code, 403)
        with self.request("/context-required.mp4", headers) as response:
            self.assertEqual(response.read(), (MEDIA / "direct.mp4").read_bytes())
        with self.request("/context-required.mp4", headers, method="HEAD") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), b"")

    def test_18_multiple_video_fixture_keeps_sources_distinct(self):
        with self.request("/multiple-videos") as response:
            html = response.read().decode()
        self.assertEqual(html.count("<video "), 2)
        self.assertIn('id="first-video"', html)
        self.assertIn('src="/forbidden.mp4"', html)
        self.assertIn('id="second-video"', html)
        self.assertIn('src="/media/direct.mp4?second=1"', html)

    def test_19_browser_retry_fixture_distinguishes_probe_and_download(self):
        for method, headers in (("HEAD", {}), ("GET", {"Range": "bytes=0-0"})):
            with self.subTest(method=method), self.assertRaises(HTTPError) as error:
                self.request("/browser-session.mp4", headers, method=method)
            self.assertEqual(error.exception.code, 403)
        with self.request("/browser-session.mp4") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), (MEDIA / "direct.mp4").read_bytes())
        with self.request("/browser-session.mp4", {"Range": "bytes=0-1"}) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.read(), (MEDIA / "direct.mp4").read_bytes()[:2])

    def test_20_hls_alternative_failure_is_independent_of_usable_rendition(self):
        with self.request("/media/hls-failures/partial.m3u8") as response:
            manifest = response.read().decode()
        self.assertIn("/media/hls-failures/denied.m3u8", manifest)
        self.assertIn("/media/hls/180p/index.m3u8", manifest)
        with self.assertRaises(HTTPError) as error:
            self.request("/media/hls-failures/denied.m3u8")
        self.assertEqual(error.exception.code, 403)
        with self.request("/media/hls/180p/index.m3u8") as response:
            self.assertIn("#EXT-X-ENDLIST", response.read().decode())
        for path in ("main-denied.m3u8", "denied.m3u8?second=1"):
            with self.subTest(path=path), self.assertRaises(HTTPError) as error:
                self.request("/media/hls-failures/" + path)
            self.assertEqual(error.exception.code, 403)
        with self.request("/media/hls-failures/all-denied.m3u8") as response:
            self.assertEqual(response.read().decode().count("/media/hls-failures/denied.m3u8"), 2)

    def test_21_hls_required_audio_can_fail_without_mutating_video(self):
        with self.request("/media/hls-failures/audio-denied.m3u8") as response:
            manifest = response.read().decode()
        self.assertIn('URI="/media/hls-failures/denied.m3u8"', manifest)
        self.assertIn('AUDIO="sound"', manifest)
        for rendition in ("180p", "360p"):
            self.assertIn(f"/media/hls-separate/{rendition}/index.m3u8", manifest)
            with self.request(f"/media/hls-separate/{rendition}/index.m3u8") as response:
                self.assertIn("#EXT-X-ENDLIST", response.read().decode())

    def test_22_separate_fmp4_has_audio_groups_initialization_and_mp4_segment_mime(self):
        with self.request("/media/hls-fmp4-separate/master.m3u8") as response:
            manifest = response.read().decode()
        self.assertEqual(manifest.count("#EXT-X-MEDIA:"), 3)
        self.assertIn('CODECS="avc1.4d401e",AUDIO="audio-128000"', manifest)
        for family in ("video/180p", "video/360p", "audio/32000", "audio/64000", "audio/128000"):
            prefix = "/media/hls-fmp4-separate/" + family + "/"
            with self.request(prefix + "index.m3u8") as response:
                playlist = response.read().decode()
            self.assertIn('#EXT-X-MAP:URI="' + prefix + 'init.mp4"', playlist)
            self.assertIn("#EXT-X-ENDLIST", playlist)
            with self.request(prefix + "segment-000.m4s") as response:
                self.assertEqual(response.headers["Content-Type"], "video/mp4")
                self.assertGreater(len(response.read()), 0)


if __name__ == "__main__":
    if not (MEDIA / "inventory.json").exists():
        raise SystemExit("Run python3 scripts/fixture_generate.py first.")
    started = time.time()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(FixtureTests))
    report = {"tests": result.testsRun, "failures": len(result.failures), "errors": len(result.errors), "passed": result.wasSuccessful(), "elapsed_seconds": round(time.time() - started, 3), "scope": "Controlled HTTP fixtures and generated media; this does not verify the iOS app."}
    (ROOT / "work").mkdir(exist_ok=True)
    (ROOT / "work/fixture-test-report.json").write_text(json.dumps(report, indent=2) + "\n")
    raise SystemExit(0 if result.wasSuccessful() else 1)
