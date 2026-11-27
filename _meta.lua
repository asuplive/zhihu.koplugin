local _ = require("gettext")
return {
    fullname = _("Zhihu Reader"),
    description = _([[Browse Zhihu with QR code login, recommended feed, and e-ink friendly pagination.

Features:
- QR code login (scan URL with Zhihu app)
- Recommended feed with refresh button (requires login); batch size is a
  setting (6 / 12 / 18 / 24 / 30 / 36 items, 12 by default)
- Read question answers with page turn
- Article images (optional, viewable in image viewer)
- Answerer avatars (optional, off by default)
- Adjustable font size
- Font family applied to the feed list and to article text; Latin-only faces
  are labelled and swapped for their CJK sibling so Chinese text really changes
- "Chinese fonts on device" lists the families that can draw Chinese, and
  "Font diagnostics" shows what the article is really laid out with
- Menu is grouped: Recommended Feed, Reading, Layout & Refresh,
  Cache & Export, and Settings (feed batch size, current settings summary,
  About)]]),
}