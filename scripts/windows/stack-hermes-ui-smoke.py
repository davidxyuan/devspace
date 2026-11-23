"""Check the installed Hermes UI and its referenced assets without opening a port."""
from hashlib import sha256
from html.parser import HTMLParser
from importlib.metadata import distribution
import json
from pathlib import Path
import sys

from starlette.applications import Starlette
from starlette.testclient import TestClient


class PageAssets(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "script" and "src" in values:
            self.paths.append(values["src"])
        if tag == "link" and values.get("rel") == "stylesheet":
            self.paths.append(values["href"])


def main(source, version, expected_digest):
    sys.path.insert(0, str(Path(source).resolve(strict=True)))
    import ui_api

    wheel = distribution("hermes-gpt")
    assert wheel.version == version
    # Multiple builds share this version. pip records the archive it actually installed.
    archive = json.loads(wheel.read_text("direct_url.json"))["archive_info"]
    digest = archive.get("hashes", {}).get("sha256") or archive["hash"].removeprefix("sha256=")
    assert digest == expected_digest, "Installed Hermes wheel differs from the release manifest"
    files = {p.as_posix(): p for p in wheel.files or ()}
    index = next(p for name, p in files.items() if name.endswith("/hermes-gpt/web/index.html"))
    assets = PageAssets()
    hashes = {}
    app = Starlette(routes=ui_api.ui_routes())
    with TestClient(app, base_url="http://127.0.0.1") as client:
        page = client.get("/ui")
        page.raise_for_status()
        assert page.content == wheel.locate_file(index).read_bytes()
        hashes["/ui"] = sha256(page.content).hexdigest()
        assets.feed(page.text)
        assert {Path(url).suffix for url in assets.paths} >= {".js", ".css"}
        for url in assets.paths:
            assert url.startswith("/ui/assets/") and ".." not in url.split("/")
            entry = files[(index.parent / url.removeprefix("/ui/")).as_posix()]
            response = client.get(url)
            response.raise_for_status()
            assert response.content and response.content == wheel.locate_file(entry).read_bytes()
            hashes[url] = sha256(response.content).hexdigest()
    print(json.dumps({"version": version, "wheelSha256": digest, "sha256": hashes}))


if __name__ == "__main__":
    main(*sys.argv[1:])
