#!/usr/bin/env python3
#
#  update-appcast.py
#  PorTalistic
#
#  Adds one release to appcast.xml, the feed Sparkle reads to find updates. Called by
#  Scripts/release.sh once the zip is notarised, stapled and signed with Sparkle's key.
#
#  It only writes the file. Publishing is two steps in a fixed order, which release.sh prints:
#  the zip goes up on the GitHub release first, and appcast.xml is pushed after. The other way
#  round, every copy of the app is offered a download that 404s.

import argparse
import email.utils
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def sparkle(tag):
    return "{%s}%s" % (SPARKLE, tag)


def main():
    parser = argparse.ArgumentParser(description="Add a release to appcast.xml")
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString, what people see")
    parser.add_argument("--build", required=True, help="CFBundleVersion, what Sparkle compares")
    parser.add_argument("--minimum-system", required=True, help="LSMinimumSystemVersion")
    parser.add_argument("--url", required=True, help="where the zip will be downloaded from")
    parser.add_argument("--signature", required=True, help="sign_update's output, verbatim")
    parser.add_argument("--notes", help="a Markdown file of release notes, if there is one")
    args = parser.parse_args()

    match = re.search(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', args.signature)
    if not match:
        sys.exit("sign_update's output isn't what was expected: %r" % args.signature)
    signature, length = match.groups()

    if not re.fullmatch(r"\d+", args.build):
        sys.exit("The build number %r isn't a whole number. Sparkle compares build numbers, so "
                 "they have to go up in a way it can follow." % args.build)

    path = pathlib.Path(args.appcast)
    tree = ET.parse(path)
    channel = tree.getroot().find("channel")
    if channel is None:
        sys.exit("%s has no <channel>." % path)

    # Sparkle offers the highest build number. A release that doesn't raise it is never offered
    # to anybody, and nothing says so — so refuse it here, where somebody is looking.
    for item in channel.findall("item"):
        existing = (item.findtext(sparkle("version")) or "").strip()
        if existing.isdigit() and int(existing) >= int(args.build):
            sys.exit("appcast.xml already has build %s (%s). Raise CURRENT_PROJECT_VERSION in the "
                     "project before releasing again — Sparkle only ever offers a higher build. If "
                     "that entry was never published (an earlier run of release.sh), put appcast.xml "
                     "back with `git checkout appcast.xml` and run again."
                     % (existing, (item.findtext("title") or "").strip()))

    notes_path = pathlib.Path(args.notes) if args.notes else None
    if notes_path and notes_path.is_file():
        notes = notes_path.read_text(encoding="utf-8").strip()
    else:
        notes = "PorTalistic %s." % args.version

    item = ET.Element("item")
    ET.SubElement(item, "title").text = "PorTalistic %s" % args.version
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system
    ET.SubElement(item, "description", {sparkle("format"): "markdown"}).text = notes
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": length,
        "type": "application/octet-stream",
        sparkle("edSignature"): signature,
    })

    # Newest first, after the channel's own title and description.
    children = list(channel)
    first_item = next((index for index, child in enumerate(children) if child.tag == "item"), len(children))
    channel.insert(first_item, item)

    ET.indent(tree, space="    ")
    tree.write(path, encoding="utf-8", xml_declaration=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n")

    print("appcast.xml: added %s (build %s)" % (args.version, args.build))


if __name__ == "__main__":
    main()
