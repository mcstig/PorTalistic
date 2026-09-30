#!/usr/bin/env python3
#
#  bump-version.py
#  PorTalistic
#
#  Decides the version a release goes out as, and writes it into the Xcode project. Called by
#  Scripts/release.sh before it builds anything.
#
#  "Already released" means committed in appcast.xml: a release is published when its entry is
#  pushed, and Sparkle only ever offers a build number higher than the one it has. So if the
#  project's build number is one of those, both numbers go up — the build by one, and the version
#  either to the one asked for or by one in its last part. If it isn't — an earlier run stopped
#  before anything was published, or the numbers were raised by hand — nothing changes, which
#  is what makes running release.sh again after a failure safe.
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

# The app's own settings. The test targets carry "1.0", two parts, and are left alone.
RELEASE_VERSION = re.compile(r"MARKETING_VERSION = (\d+\.\d+\.\d+);")
DEBUG_VERSION = re.compile(r'MARKETING_VERSION = "(\d+\.\d+\.\d+)-dirty";')
BUILD = re.compile(r"CURRENT_PROJECT_VERSION = (\d+);")


def released_builds():
    shown = subprocess.run(["git", "show", "HEAD:appcast.xml"], capture_output=True)
    if shown.returncode != 0:
        return set()

    # Bytes, not text: ElementTree refuses a str that carries its own encoding declaration.
    root = ET.fromstring(shown.stdout)
    return {int(element.text.strip()) for element in root.iter(SPARKLE_VERSION)
            if element.text and element.text.strip().isdigit()}


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
    released = released_builds()

    if released and current_build <= max(released):
        build = max(released) + 1
        if requested:
            version = requested
        else:
            major, minor, patch = (int(part) for part in current_version.split("."))
            version = "%d.%d.%d" % (major, minor, patch + 1)
    else:
        build = current_build
        version = requested or current_version

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
