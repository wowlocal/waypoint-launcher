#!/usr/bin/env python3
"""Writes the tip feed: the tip builds' items plus the newest release's.

Tip copies follow only the tip feed. With the release in it too, Sparkle
offers whichever build is newest, so a tip copy moves on to the next
release as soon as it's out, before any tip is built on top of it.

    merge-tip-appcast.py <tip items: appcast file or "-"> <release appcast> <out>
"""
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def items(path):
    if path == "-":
        return []
    return ET.parse(path).getroot().find("channel").findall("item")


def build(item):
    version = item.findtext(f"{{{SPARKLE}}}version") or item.find("enclosure").get(f"{{{SPARKLE}}}version", "0")
    return tuple(int(part) for part in version.split("."))


tips = [item for item in items(sys.argv[1]) if len(build(item)) > 1]
releases = [item for item in items(sys.argv[2]) if len(build(item)) == 1]
if not releases:
    raise SystemExit("the release feed has no release")
chosen = sorted(tips, key=build)[-1:] + [max(releases, key=build)]
rss = ET.Element("rss", {"version": "2.0"})
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Waypoint Tip"
for item in sorted(chosen, key=build, reverse=True):
    channel.append(item)
ET.indent(rss)
ET.ElementTree(rss).write(sys.argv[3], encoding="utf-8", xml_declaration=True)
