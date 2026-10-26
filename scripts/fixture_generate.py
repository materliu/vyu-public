#!/usr/bin/env python3
"""Generate synthetic VYu test media. This is a development-only dependency."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / "fixtures" / "media"


def run(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *map(str, args)], check=True)


def video_options(size="640:360"):
    return ["-vf", f"scale={size}", "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "main", "-level", "3.0", "-pix_fmt", "yuv420p", "-g", "48", "-keyint_min", "48", "-sc_threshold", "0"]


def generate_export_failures():
    """Complete HTTP bodies that must still fail portable-file validation."""
    folder = MEDIA / "hls-export-invalid"
    folder.mkdir(exist_ok=True)
    source = MEDIA / "hls-fmp4-separate" / "video" / "360p"
    lines = (source / "index.m3u8").read_text().splitlines()
    indices = [index for index, line in enumerate(lines) if line and not line.startswith("#")]
    truncated = lines.copy()
    truncated[indices[0]] = "/media/hls-export-invalid/truncated.m4s"
    (folder / "truncated.m4s").write_bytes((source / "segment-000.m4s").read_bytes()[:-17])
    (folder / "truncated.m3u8").write_text("\n".join(truncated) + "\n")
    repeated = lines.copy()
    repeated[indices[1]] = lines[indices[0]]
    (folder / "repeated.m3u8").write_text("\n".join(repeated) + "\n")


def generate_missing_inline_audio():
    folder = MEDIA / "hls-export-invalid"
    folder.mkdir(exist_ok=True)
    # The master promises audio embedded in the variant (no MEDIA URI), while
    # the referenced synthetic rendition deliberately contains video only.
    (folder / "missing-inline-audio.m3u8").write_text(
        '#EXTM3U\n#EXT-X-VERSION:7\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="embedded",NAME="Expected embedded audio",DEFAULT=YES,AUTOSELECT=YES\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360,AUDIO="embedded"\n'
        '/media/hls-fmp4-separate/video/360p/index.m3u8\n')


def generate_timing_fixtures():
    """Valid decode/presentation timelines that must survive portable export."""
    for name, rate, bframes, selection, offset in [
        ("2fps", 2, 3, None, None),
        ("1fps", 1, 2, None, None),
        ("vfr", 24, 3, r"select=if(lt(t\,4)\,not(mod(n\,3))\,not(mod(n\,12)))", None),
        ("offset", 24, 3, None, "12.166"),
        ("offset-no-edit", 24, 3, None, "12.166"),
        ("metadata-duration", 24, 3, None, "12.166"),
    ]:
        target = MEDIA / "hls-timing" / name
        target.mkdir(parents=True, exist_ok=True)
        options = ["-f", "lavfi", "-i", f"testsrc2=size=320x180:rate={rate}",
                   "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                   "-t", "12.166", "-c:v", "libx264", "-preset", "veryfast",
                   "-profile:v", "main", "-pix_fmt", "yuv420p", "-g", str(rate * 2),
                   "-keyint_min", str(rate * 2), "-sc_threshold", "0", "-bf", str(bframes),
                   "-c:a", "aac", "-b:a", "96k"]
        if selection:
            options += ["-vf", selection, "-fps_mode", "passthrough"]
        if offset:
            options += ["-output_ts_offset", offset]
        run(*options, "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod",
            "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
            "-hls_segment_filename", target / "segment-%03d.m4s", target / "index.m3u8")
        if name in ("offset-no-edit", "metadata-duration"):
            # Some fMP4 sources carry an absolute tfdt without an explicit elst
            # describing its leading gap. AVFoundation may then report the full
            # absolute endpoint as a nonempty track duration.
            init = target / "init.mp4"
            init.write_bytes(without_mp4_edits(init.read_bytes(),
                header_duration=12.083 if name == "metadata-duration" else None))
        prefix = "/media/" + target.relative_to(MEDIA).as_posix() + "/"
        lines = []
        for line in (target / "index.m3u8").read_text().splitlines():
            if line.startswith('#EXT-X-MAP:URI="'):
                line = line.replace('URI="', 'URI="' + prefix, 1)
            elif line and not line.startswith("#"):
                line = prefix + line
            lines.append(line)
        (target / "index.m3u8").write_text("\n".join(lines) + "\n")
        if name == "2fps":
            # Preserve the final timestamp and EXTINF total, but replace a real
            # middle interval with the first interval. Timing compatibility must
            # not make this genuinely incomplete timeline look complete.
            indices = [index for index, line in enumerate(lines) if line and not line.startswith("#")]
            repeated = lines.copy()
            repeated[indices[2]] = lines[indices[0]]
            (MEDIA / "hls-export-invalid" / "low-framerate-repeated.m3u8").write_text("\n".join(repeated) + "\n")


def without_mp4_edits(data, header_duration=None):
    """Remove generated edit lists; optionally retain a redundant header duration."""
    output = bytearray()
    offset = 0
    while offset < len(data):
        if len(data) - offset < 8:
            raise ValueError("Truncated generated MP4 atom")
        length = int.from_bytes(data[offset:offset + 4], "big")
        kind = data[offset + 4:offset + 8]
        if length < 8 or length > len(data) - offset:
            raise ValueError("Unsupported generated MP4 atom size")
        payload = data[offset + 8:offset + length]
        if kind in (b"moov", b"trak", b"mdia"):
            payload = without_mp4_edits(payload, header_duration)
        elif header_duration is not None and kind in (b"mvhd", b"mdhd", b"tkhd"):
            # FFmpeg generates v0 headers and a 1000 Hz movie timescale here.
            if not payload or payload[0] != 0:
                raise ValueError("Unexpected generated MP4 timing header")
            payload = bytearray(payload)
            if kind == b"tkhd":
                payload[20:24] = round(header_duration * 1000).to_bytes(4, "big")
            else:
                timescale = int.from_bytes(payload[12:16], "big")
                payload[16:20] = round(header_duration * timescale).to_bytes(4, "big")
        if kind != b"edts":
            output += (len(payload) + 8).to_bytes(4, "big") + kind + payload
        offset += length
    return bytes(output)


def generate_missing_edge_fragments():
    """Complete fMP4 containers whose declared first/last half second is absent."""
    target = MEDIA / "hls-timing" / "edge-base"
    target.mkdir(parents=True, exist_ok=True)
    run("-i", MEDIA / "direct.mp4", "-an", "-c:v", "libx264", "-preset", "veryfast",
        "-profile:v", "main", "-pix_fmt", "yuv420p", "-g", "12", "-keyint_min", "12",
        "-sc_threshold", "0", "-f", "hls", "-hls_time", "0.5", "-hls_playlist_type", "vod",
        "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
        "-hls_segment_filename", target / "segment-%03d.m4s", target / "index.m3u8")

    def boxes(data):
        offset = 0
        while offset < len(data):
            length = int.from_bytes(data[offset:offset + 4], "big")
            if length < 8 or length > len(data) - offset:
                raise ValueError("Invalid generated fragment atom")
            yield data[offset + 4:offset + 8], data[offset + 8:offset + length]
            offset += length

    def atom(kind, payload):
        return (len(payload) + 8).to_bytes(4, "big") + kind + payload

    def empty_fragment(data):
        moof = dict(boxes(dict(boxes(data))[b"moof"]))
        traf = dict(boxes(moof[b"traf"]))
        tfhd = bytearray(traf[b"tfhd"])
        # duration-is-empty; retain the original track ID and decode timestamp.
        tfhd[:4] = (int.from_bytes(tfhd[:4], "big") | 0x010000).to_bytes(4, "big")
        track = atom(b"tfhd", tfhd) + atom(b"tfdt", traf[b"tfdt"]) + atom(b"trun", bytes(8))
        return atom(b"moof", atom(b"mfhd", moof[b"mfhd"]) + atom(b"traf", track)) + atom(b"mdat", b"")

    prefix = "/media/" + target.relative_to(MEDIA).as_posix() + "/"
    lines = []
    for line in (target / "index.m3u8").read_text().splitlines():
        if line.startswith('#EXT-X-MAP:URI="'):
            line = line.replace('URI="', 'URI="' + prefix, 1)
        elif line and not line.startswith("#"):
            line = prefix + line
        lines.append(line)
    (target / "index.m3u8").write_text("\n".join(lines) + "\n")
    indices = [index for index, line in enumerate(lines) if line and not line.startswith("#")]
    for name, index in [("missing-prefix", indices[0]), ("missing-suffix", indices[-1])]:
        empty = MEDIA / "hls-export-invalid" / (name + "-empty.m4s")
        empty.write_bytes(empty_fragment((target / Path(lines[index]).name).read_bytes()))
        missing = lines.copy()
        missing[index] = "/media/hls-export-invalid/" + empty.name
        (empty.parent / (name + ".m3u8")).write_text("\n".join(missing) + "\n")


def generate():
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise SystemExit("Install ffmpeg (including ffprobe) to generate development fixtures.")
    MEDIA.mkdir(parents=True, exist_ok=True)
    run("-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "8", *video_options(), "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", MEDIA / "direct.mp4")
    run("-i", MEDIA / "direct.mp4", "-an", "-c:v", "copy", "-movflags", "+faststart", MEDIA / "silent.mp4")
    run("-i", MEDIA / "direct.mp4", "-c", "copy", "-movflags", "+frag_keyframe+empty_moov+default_base_moof", MEDIA / "mse.mp4")
    for family, separate in [("hls", False), ("hls-separate", True)]:
        folder = MEDIA / family
        for label, size in [("360p", "640:360"), ("180p", "320:180")]:
            target = folder / label
            target.mkdir(parents=True, exist_ok=True)
            audio = ["-an"] if separate else ["-c:a", "aac", "-b:a", "96k"]
            run("-i", MEDIA / "direct.mp4", *video_options(size), *audio, "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_flags", "independent_segments", "-hls_segment_filename", target / "segment-%03d.ts", target / "index.m3u8")
        if separate:
            audio_dir = folder / "audio"
            audio_dir.mkdir(exist_ok=True)
            run("-i", MEDIA / "direct.mp4", "-vn", "-c:a", "aac", "-b:a", "96k", "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_filename", audio_dir / "segment-%03d.ts", audio_dir / "index.m3u8")
        audio_tag = '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="测试音轨",LANGUAGE="zh",DEFAULT=YES,AUTOSELECT=YES,URI="audio/index.m3u8"\n' if separate else ""
        audio_attr = ',AUDIO="sound"' if separate else ""
        (folder / "master.m3u8").write_text('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-INDEPENDENT-SEGMENTS\n' + audio_tag + f'#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"{audio_attr}\n360p/index.m3u8\n' + f'#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=320x180,CODECS="avc1.4d401e,mp4a.40.2"{audio_attr}\n180p/index.m3u8\n', encoding="utf-8")
    # One fragmented MP4 contains both the initialization range (EXT-X-MAP)
    # and each media range (EXT-X-BYTERANGE), exercising real HTTP 206 reads.
    fmp4 = MEDIA / "hls-fmp4"
    fmp4.mkdir(exist_ok=True)
    run("-i", MEDIA / "direct.mp4", "-c", "copy", "-f", "hls", "-hls_time", "2",
        "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4",
        "-hls_flags", "single_file+independent_segments", "-hls_segment_filename", fmp4 / "stream.mp4",
        fmp4 / "index.m3u8")
    # Public Twitter playlists use separate fMP4 initialization/segment objects,
    # video-only CODECS values and distinct audio groups per rendition. Keep all
    # media synthetic while reproducing that topology and root-relative URIs.
    twitter = MEDIA / "hls-fmp4-separate"
    master = ['#EXTM3U', '#EXT-X-VERSION:6', '#EXT-X-INDEPENDENT-SEGMENTS']
    for bitrate in (32000, 64000, 128000):
        target = twitter / "audio" / str(bitrate)
        target.mkdir(parents=True, exist_ok=True)
        run("-i", MEDIA / "direct.mp4", "-vn", "-c:a", "aac", "-b:a", str(bitrate),
            "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4",
            "-hls_fmp4_init_filename", "init.mp4", "-hls_segment_filename", target / "segment-%03d.m4s", target / "index.m3u8")
        master.append(f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-{bitrate}",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="/media/hls-fmp4-separate/audio/{bitrate}/index.m3u8"')
    for label, size, bitrate, bandwidth in [("180p", "320:180", 32000, 500000), ("360p", "640:360", 128000, 1000000)]:
        target = twitter / "video" / label
        target.mkdir(parents=True, exist_ok=True)
        run("-i", MEDIA / "direct.mp4", *video_options(size), "-an", "-f", "hls", "-hls_time", "2",
            "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4", "-hls_flags", "independent_segments",
            "-hls_fmp4_init_filename", "init.mp4", "-hls_segment_filename", target / "segment-%03d.m4s", target / "index.m3u8")
        master.append(f'#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},RESOLUTION={size.replace(":", "x")},CODECS="avc1.4d401e",AUDIO="audio-{bitrate}"')
        master.append(f'/media/hls-fmp4-separate/video/{label}/index.m3u8')
    for playlist in twitter.rglob("index.m3u8"):
        prefix = "/media/" + playlist.parent.relative_to(MEDIA).as_posix() + "/"
        lines = []
        for line in playlist.read_text().splitlines():
            if line.startswith('#EXT-X-MAP:URI="'):
                line = line.replace('URI="', 'URI="' + prefix, 1)
            elif line and not line.startswith('#'):
                line = prefix + line
            lines.append(line)
        playlist.write_text("\n".join(lines) + "\n")
    (twitter / "master.m3u8").write_text("\n".join(master) + "\n")
    generate_export_failures()
    generate_missing_inline_audio()
    generate_timing_fixtures()
    generate_missing_edge_fragments()
    dash = MEDIA / "dash"
    dash.mkdir(exist_ok=True)
    run("-i", MEDIA / "direct.mp4", "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-f", "dash", "-seg_duration", "2", "-use_template", "1", "-use_timeline", "1", "-adaptation_sets", "id=0,streams=v id=1,streams=a", dash / "manifest.mpd")
    (MEDIA / "corrupt.mp4").write_bytes(b"VYu deliberately invalid media; this must never be marked downloaded.\n")
    (MEDIA / "blob-source.json").write_text(json.dumps({"url": "/media/direct.mp4"}), encoding="utf-8")
    (MEDIA / "mse-source.json").write_text(json.dumps({"url": "/media/mse.mp4", "mime": 'video/mp4; codecs="avc1.4d401e,mp4a.40.2"'}), encoding="utf-8")
    protected = MEDIA / "protected"
    protected.mkdir(exist_ok=True)
    (protected / "index.m3u8").write_text('#EXTM3U\n#EXT-X-VERSION:5\n#EXT-X-TARGETDURATION:8\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://vyu-fixture-no-license",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"\n#EXTINF:8.0,\n../hls/360p/segment-000.ts\n#EXT-X-ENDLIST\n', encoding="utf-8")
    files = []
    for file in sorted(MEDIA.rglob("*")):
        if file.is_file() and file.name != "inventory.json":
            files.append({"path": str(file.relative_to(MEDIA)), "bytes": file.stat().st_size, "sha256": hashlib.sha256(file.read_bytes()).hexdigest()})
    probe = subprocess.check_output(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(MEDIA / "direct.mp4")], text=True)
    inventory = {"source": "FFmpeg testsrc2 and 440 Hz sine, generated locally", "duration_seconds": 8, "direct_probe": json.loads(probe), "files": files}
    (MEDIA / "inventory.json").write_text(json.dumps(inventory, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"media_root": str(MEDIA), "files": len(files), "bytes": sum(f["bytes"] for f in files), "duration_seconds": 8}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    generate()
