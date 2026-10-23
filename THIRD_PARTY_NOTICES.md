# Third-Party Notices

## Genshin Impact / Genius Invokation TCG artwork

The game card images under `Assets/portraits/` and character names are used as
local visual-recognition references. Game artwork and trademarks belong to
miHoYo / HoYoverse and their respective owners; they are not covered by this
repository's MIT source-code license. Keep this attribution with builds. This
is an independent community utility, not an official HoYoverse product.

`Assets/controls/replay-gear.png` is an isolated game settings icon used only
for offline replay-control matching. It contains no player/account text or
surrounding screenshot and is subject to the same game-artwork attribution.

Reference archive sources (downloaded September 2026):

- [Playable character card textures, extracted by Mysticus](https://www.spriters-resource.com/pc_computer/genshinimpact/asset/599016/)
- [Monster card textures, extracted by Mysticus](https://www.spriters-resource.com/pc_computer/genshinimpact/asset/598986/)
- [Chinese card names, Yatta API](https://gi.yatta.moe/api/v2/chs/gcg)
- Incremental new-card images: `https://gi.yatta.moe/assets/UI/gcg/<card-icon>.png`,
  resolved from that public character-card catalog. Existing references are
  retained. Updates are user-initiated or optionally checked daily and do not upload user data.

`scripts/prepare_assets.py` selects the higher-resolution standard art from
each archive, bounds its height to 640 pixels, and keeps only named character
cards. It does not scrape private account information.

## Bundled software

- [OpenCV](https://github.com/opencv/opencv/blob/4.x/LICENSE): Apache License 2.0.
- [opencv-python packaging](https://github.com/opencv/opencv-python/blob/4.x/LICENSE.txt): MIT.
- [NumPy](https://github.com/numpy/numpy/blob/main/LICENSE.txt): BSD-3-Clause and included third-party notices.
- [Certifi](https://github.com/certifi/python-certifi/blob/master/LICENSE): Mozilla Public License 2.0; public CA certificates for explicit reference updates, not host-specific trust stores.
- [CPython](https://docs.python.org/3/license.html): Python Software Foundation License and included third-party notices.
- [PyInstaller](https://pyinstaller.org/en/stable/license.html): GPL 2.0 with an exception allowing packaged applications to be distributed under their own license.

The recognition worker is bundled with its Python runtime. Distribution metadata
and dependency licenses are retained by the build process under its bundle.
ScreenCaptureKit, Vision, AppKit and SwiftUI are system frameworks supplied by
Apple. No Apple example source is copied into this project.
