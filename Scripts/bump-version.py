#!/usr/bin/env python3
#
#  bump-version.py
#  PorTalistic
#
#  Decides the version a release goes out as, and writes it into the Xcode project. Called by
#  Scripts/release.sh before it builds anything.
#
#  "Already released" means committed in appcast.xml: a release is published when its entry is
#  pushed. Two things are read from it — the build numbers, which Sparkle compares, and the
#  version names, which people do — and each decides one half of the answer:
#
#  - The version. One that is asked for is taken, unless it is already released or lower than
#    one that is: 1/10/2026, `release.sh 0.6.20` the day after 0.6.20 shipped built, signed and
#    notarised a second 0.6.20, and only the zip's name said so. With no version asked for, the
#    project's own is kept while it is unreleased (an earlier run stopped before publishing),
#    and its last part goes up by one once it is out.
#  - The build. It goes up past every released one when it is one of them, or lower; and a
#    build number belongs to one version, so a version that differs from the project's takes a
#    new number even over an unpublished one. The unpublished build may already be on
#    somebody's Mac — a build copied onto a test machine is exactly that — and Sparkle there
#    never offers a build number it already has: 0.6.2 went onto the test VM as build 70 without
#    being published, and 0.6.20 reusing 70 would have been offered to it as nothing new.
#
#  So running release.sh again after a failed attempt keeps the numbers it chose the first
#  time, and nothing else can produce a release that is offered to nobody or named like one
#  that exists.
#
#  Usage: Scripts/bump-version.py [version]
#  Prints: "<version> <build> <bumped|unchanged>"

import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

PROJECT = pathlib.Path("PorTalistic.xcodeproj/project.pbxproj")
SPARKLE_VERSION = "{http://www.andymatuschak.org/xml-namespaces/sparkle}version"
SPARKLE_SHORT_VERSION = "{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString"

# The app's own settings. The test targets carry "1.0", two parts, and are left alone.
RELEASE_VERSION = re.compile(r"MARKETING_VERSION = (\d+\.\d+\.\d+);")
DEBUG_VERSION = re.compile(r'MARKETING_VERSION = "(\d+\.\d+\.\d+)-dirty";')
BUILD = re.compile(r"CURRENT_PROJECT_VERSION = (\d+);")


def released():
    """The build numbers and version names in the committed appcast."""
    shown = subprocess.run(["git", "show", "HEAD:appcast.xml"], capture_output=True)
    if shown.returncode != 0:
        return set(), set()

    # Bytes, not text: ElementTree refuses a str that carries its own encoding declaration.
    root = ET.fromstring(shown.stdout)
    builds = {int(element.text.strip()) for element in root.iter(SPARKLE_VERSION)
              if element.text and element.text.strip().isdigit()}
    versions = {element.text.strip() for element in root.iter(SPARKLE_SHORT_VERSION)
                if element.text and element.text.strip()}
    return builds, versions


def parts(version):
    return tuple(int(part) for part in version.split("."))


def next_patch(version):
    major, minor, patch = parts(version)
    return "%d.%d.%d" % (major, minor, patch + 1)


def main():
    requested = sys.argv[1].strip() if len(sys.argv) > 1 and sys.argv[1].strip() else None
    if requested and not re.fullmatch(r"\d+\.\d+\.\d+", requested):
        sys.exit("%r isn't a version like 0.6.2." % requested)

    text = PROJECT.read_text(encoding="utf-8")

    release_versions = set(RELEASE_VERSION.findall(text))
    builds = set(BUILD.findall(text))

    if len(release_versions) != 1:
        sys.exit("Expected the app's version once in the project, found %s." % sorted(release_versions))
    if len(builds) != 1:
        sys.exit("The project's configurations disagree on the build number: %s. Make them "
                 "the same in Xcode first." % sorted(builds))

    current_version = release_versions.pop()
    current_build = int(builds.pop())
    released_builds, released_versions = released()

    if requested and requested in released_versions:
        sys.exit("%s is already released (it is in the committed appcast.xml). Run Scripts/release.sh "
                 "with no version for the next one, or name one that hasn't been released." % requested)

    newest = max(released_versions, key=parts) if released_versions else None
    if requested and newest and parts(requested) < parts(newest):
        sys.exit("%s is lower than %s, which is already released." % (requested, newest))

    if requested:
        version = requested
    elif current_version in released_versions:
        version = next_patch(current_version)
    else:
        version = current_version

    # Past every released build when it is one of them or lower; and a build number belongs
    # to one version — see the note at the top.
    if (released_builds and current_build <= max(released_builds)) or version != current_version:
        build = max({current_build} | released_builds) + 1
    else:
        build = current_build

    if (version, build) == (current_version, current_build):
        print("%s %d unchanged" % (version, build))
        return

    text = RELEASE_VERSION.sub("MARKETING_VERSION = %s;" % version, text)
    text = DEBUG_VERSION.sub('MARKETING_VERSION = "%s-dirty";' % version, text)
    text = BUILD.sub("CURRENT_PROJECT_VERSION = %d;" % build, text)
    PROJECT.write_text(text, encoding="utf-8")

    print("%s %d bumped" % (version, build))


if __name__ == "__main__":
    main()
