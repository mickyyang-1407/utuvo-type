#!/usr/bin/env python3
"""Sign a notarized release ZIP and appcast. Never exports the Keychain key.

Publish the exact ZIP to its GitHub release BEFORE pushing docs/appcast.xml.
After signing, do not reformat the XML: its signature covers the exact bytes.
"""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEED = "https://mickyyang-1407.github.io/utuvo-type/appcast.xml"


def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/appcast.xml")
    parser.add_argument("--account", default="com.utuvo.type.updates")
    parser.add_argument("--notes", required=True, help="Plain text, no external release notes")
    args = parser.parse_args()
    archive = args.archive.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="utuvo-appcast-") as temporary:
        run("ditto", "-x", "-k", archive, temporary)
        app = Path(temporary) / "UTUVO Type.app"
        run("codesign", "--verify", "--deep", "--strict", app)
        run("xcrun", "stapler", "validate", app)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    assert re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version), "Invalid version"
    assert build.isdigit(), "Build must increase monotonically"
    assert info["CFBundleIdentifier"] == "com.utuvo.type"
    assert info["SUFeedURL"] == FEED
    assert info["SURequireSignedFeed"] and info["SUVerifyUpdateBeforeExtraction"]
    public_key = run(SPARKLE / "generate_keys", "--account", args.account, "-p")
    assert info["SUPublicEDKey"] == public_key, "Wrong signing account for this app"
    assert archive.name == f"UTUVO-Type-{version}-macOS-arm64.zip", "Use the release's exact asset name"
    signature = run(SPARKLE / "sign_update", "--account", args.account, "-p", archive)
    run(SPARKLE / "sign_update", "--account", args.account, "--verify", archive, signature)
    ET.register_namespace("sparkle", NAMESPACE)
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "UTUVO Type Updates"
    ET.SubElement(channel, "link").text = "https://mickyyang-1407.github.io/utuvo-type/"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"UTUVO Type {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    for key, value in [("version", build), ("shortVersionString", version),
                       ("minimumSystemVersion", "14.0.0"), ("hardwareRequirements", "arm64")]:
        ET.SubElement(item, f"{{{NAMESPACE}}}{key}").text = value
    ET.SubElement(item, "description", {f"{{{NAMESPACE}}}format": "plain-text"}).text = args.notes
    url = f"https://github.com/mickyyang-1407/utuvo-type/releases/download/v{version}/{archive.name}"
    ET.SubElement(item, "enclosure", {"url": url, "length": str(archive.stat().st_size),
                  "type": "application/octet-stream", f"{{{NAMESPACE}}}edSignature": signature})
    ET.indent(root)
    # Only replace the published file after both signatures have verified.
    with tempfile.TemporaryDirectory(prefix="utuvo-signed-feed-") as temporary:
        candidate = Path(temporary) / "appcast.xml"
        ET.ElementTree(root).write(candidate, encoding="utf-8", xml_declaration=True)
        run(SPARKLE / "sign_update", "--account", args.account, candidate)
        run(SPARKLE / "sign_update", "--account", args.account, "--verify", candidate)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(candidate.read_bytes())
    print(f"Signed {version} ({build}), {archive.stat().st_size} bytes -> {args.output}")
    print(f"Upload archive first: {url}")


if __name__ == "__main__":
    main()
