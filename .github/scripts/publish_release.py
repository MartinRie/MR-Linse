"""Publish complete builds. Never replace downloads of a published version."""
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request

FILES = ('MR-Linse-macOS-arm64.zip', 'MR-Linse-C3-Firmware.zip', 'MR-Linse-Bedienungsanleitung.pdf')


def api(path):
    request = urllib.request.Request(
        'https://api.github.com/repos/' + os.environ['GH_REPO'] + '/' + path,
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                 'Accept': 'application/vnd.github+json', 'User-Agent': 'MR-Linse-release'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def gh(*args):
    subprocess.run(['gh', 'release', *args], check=True)


def publish(version, sha, dist):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('VERSION muss x.y.z enthalten')
    tag = 'v' + version
    files = [str(dist / name) for name in FILES]
    if not all(Path(path).is_file() and Path(path).stat().st_size > 0 for path in files):
        raise ValueError('App, Firmware oder PDF fehlen')
    release = api('releases/tags/' + tag)
    if release and not release['draft']:
        names = {asset['name'] for asset in release['assets'] if asset['size'] > 0}
        if not set(FILES).issubset(names):
            raise ValueError(tag + ' ist bereits unvollständig veröffentlicht. VERSION erhöhen, committen und pushen.')
        print(tag + ' ist schon veröffentlicht und bleibt unverändert. Für neue Downloads VERSION erhöhen.')
        return
    reference = api('git/ref/tags/' + tag)
    target = reference['object'] if reference else None
    # Annotated tags may point to tag objects rather than directly to a commit.
    for _ in range(8):
        if not target or target['type'] != 'tag':
            break
        tag_object = api('git/tags/' + target['sha'])
        if not tag_object:
            raise ValueError('Tag-Objekt fehlt')
        target = tag_object['object']
    if target and (target['type'] != 'commit' or target['sha'] != sha):
        raise ValueError(tag + ' gehört zu einem anderen Commit. VERSION erhöhen, committen und pushen.')
    if release:
        if not target and release['target_commitish'] != sha:
            raise ValueError('Vorhandener Entwurf gehört zu einem anderen Stand. VERSION erhöhen.')
        gh('upload', tag, *files, '--clobber')
        gh('edit', tag, '--draft=false')
    else:
        gh('create', tag, *files, '--target', sha, '--title', 'MR-Linse ' + tag,
           '--notes-file', 'RELEASE_NOTES.md')
    print('Veröffentlicht: ' + tag)


if __name__ == '__main__':
    project = Path('SoulearLupe') if Path('SoulearLupe/VERSION').exists() else Path('.')
    publish((project / 'VERSION').read_text().strip(), os.environ['GITHUB_SHA'], Path('dist'))
