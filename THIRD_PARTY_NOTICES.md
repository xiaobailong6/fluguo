# Third-party notices

## Douyin request signature

`lib/live_douyin_sign.dart` is adapted from the Pure Live reference source at
`live/lib/shared/platforms/douyin/abogus.dart`. The reference file has no separate
per-file author notice. Its repository license is GNU Affero General Public
License version 3 (AGPL-3.0); the complete text is preserved in `live/LICENSE`.

The standalone adaptation preserves the reference signature layout and uses a
standalone SM3 implementation with published test vectors. It does not import
the Pure Live UI, account state, or `dart_sm` package.

When distributing a combined work that includes this component, retain its
source notices and satisfy applicable GPLv3/AGPLv3 corresponding-source and
license requirements. This notice does not replace the complete license text
or change the existing project `LICENSE`.

## Hongguo native playback v5 protocol

`native/core/hongguo_v5_crypto.go`, `native/core/hongguo_v5_sign.go` and the new
multi-video playback request/response adaptation in `provider_hongguo*.go` are
adapted from guoapp-modules/hongguo v1.0.2, commit
`49bf731d49c8506f946a28d2d4efc2442c14c67e`:
https://github.com/guoapp-modules/hongguo/commit/49bf731d49c8506f946a28d2d4efc2442c14c67e

The upstream v5 implementation credits N3urda/hongguoTV
`Signer/AesV3/V5Constants` and drpys commit `22261ad`, with the per-file notice
`SPDX-License-Identifier: GPL-3.0-only`. Preserve these notices and satisfy
applicable GPLv3 corresponding-source and license requirements when distributing
the adapted code. This notice does not change the project `LICENSE`.

`native/core/testdata/hongguo/` contains synthetic, offline signing vectors from
that same commit's `test/fixtures/signing-v5-{carrier,f13}.json`, plus deterministic
full-header vectors generated from its `main.js` using synthetic device fields.
No real device credentials, cookies or media URLs are included.

The November 27, 2026 Medusa device-envelope repair in
`native/core/hongguo_v5_sign.go` and its offline fixture generator also adapt
`kotlin-tv/core/src/main/kotlin/com/hongguotv/core/Signer.kt` from
N3urda/hongguoTV commit `615b0c5b5e3fc5202512da6c279ba4498736bbea`
(SPDX-License-Identifier: GPL-3.0-only):
https://github.com/N3urda/hongguoTV/commit/615b0c5b5e3fc5202512da6c279ba4498736bbea
The protocol uses synthetic process state and the application's own anonymous
registered identity; no official APK, native SDK, account session or remote
signing service is bundled or required.

The request device tier follows the v1.0.3 compatibility fix in
guoapp-modules/hongguo commit `2ed8963cdda569a752e3606631342037d7a26e05`:
https://github.com/guoapp-modules/hongguo/commit/2ed8963cdda569a752e3606631342037d7a26e05

## Incremental playback stability adaptations

Pause/resume resource-management and Android Surface seek guards reference
Xanerix/guoapp commits `9d27a54bde22321052eeb69c24fb0b13d41f6349` and
`4c7aab6a87a12e1aaf6b1d08fa31d3844148650c`. Cached-cover first-frame display
references `ca98ddf9c44736f17a8678c5f35fd733e375b469`. The adaptations retain
this application's authorization, cache-maintenance and playback-generation
checks rather than replacing upstream files wholesale. Existing media_kit
per-file MIT notices are retained in the local plugin patches. Windows keeps
the existing ANGLE and libmpv dependencies; no D3D11 backend is imported here.

Manual season selection and Android UV correction reference Xanerix/guoapp
commits `fafb3d01cf253877fd5802aad72ce98c83f249fc` and
`2aa0f743f7c71195816106b7b8a164ac6c851eb3`. Short-drama input/orientation
locking references `4c7aab6a87a12e1aaf6b1d08fa31d3844148650c` and
`017b96178fec993ba88720ce5903d483b452d62c`, adapted to this application's
existing controls, official-season authorization and serialized orientation
commands. The repository's existing GPL license and source obligations remain
unchanged; no upstream UI tree is copied wholesale.

## Native MissAV and Hanime1 providers

`native/core/provider_missav.go` and `native/core/provider_hanime1.go` adapt
the request shapes and parsers from the public guoapp-modules repositories:

- https://github.com/guoapp-modules/missav/tree/v1.0.1
- https://github.com/guoapp-modules/hanime1/tree/v1.0.1

The downloaded `main.js` and `manifest.json` were checked against the published
module index SHA-256 hashes. These repositories declare GPL-3.0 licensing;
retain their attribution and applicable corresponding-source obligations when
distributing the adaptation. No remote JavaScript is executed by the native
providers. Tests use synthetic offline markup and media responses, not copied
site content or user credentials.

## Local interaction motion adaptations

The state-icon, local-content and lock-control transitions reference
Xanerix/guoapp at commit `5a7a116530fcf4242bfc6da08209585e267629cb`:
https://github.com/Xanerix/guoapp/tree/5a7a116530fcf4242bfc6da08209585e267629cb

Reference paths include `lib/ui/widgets/motion/motion_widgets.dart`,
`lib/ui/widgets/swipe_switch.dart` and `lib/ui/player/player_lock.dart`.
The adaptations use this application's motion timing, single content tree,
focus/input isolation and existing UI styling. No upstream theme, navigation
tree or Noto Emoji assets are imported. Preserve the repository's existing
GPL license and corresponding-source obligations when distributing.

## System media controls and background playback

The media channel, Android playback service, Apple Now Playing / remote commands and Windows SMTC integration reference Xanerix/guoapp at `3b16654c1e`, including `012de5f` and `5a54956`. The letterbox danmaku and page-key behavior reference `67624ed` and `ab85a76`. Retain the project's GPL license and applicable source notices when distributing these adaptations.

## Noto Emoji danmaku assets

`assets/danmaku_emoji/` contains 49 PNG images from Noto Emoji by Google LLC
(https://github.com/googlefonts/noto-emoji), taken as 64px renders from
`emoji-datasource-google` 15.1.2 (https://github.com/iamcal/emoji-data).
They are licensed under the Apache License 2.0; the complete text is kept in
`assets/danmaku_emoji/LICENSE` and is also registered in the in-app license
page via `lib/danmaku_emoji.dart`. The alias dictionary and the parser shape
are adapted from Xanerix/guoapp commit
`5a7a116530fcf4242bfc6da08209585e267629cb` (`lib/danmaku_emoji.dart`,
`assets/danmaku_emoji/`). This adaptation keeps the original token text so a
missing or broken asset falls back to the bracketed text, applies the existing
danmaku opacity to images, and measures and paints with one `TextScaler`. No
upstream overlay, settings page or theme file is copied.

## Live playback stability adaptations

The live-only cache policy, source refresh, keyboard lifecycle and Huya quality
identity changes reference liuchuancong/pure_live commits `98f20b5339`,
`784b00da3f`, `523f849210`, `c7cf5463ef`, `a4ee80b29b`, `ff98cd046d` and
`3f1a464e98`, reviewed at `de278833d9048d0bc51bc11c57021167b86d83d1`:
https://github.com/liuchuancong/pure_live/tree/de278833d9048d0bc51bc11c57021167b86d83d1

These are lightweight adaptations to this application's page ownership,
pause/visibility intent and platform interfaces, not a wholesale import of the
upstream player or GetX architecture. Preserve applicable AGPL-3.0 source and
license obligations described above. The standalone `live_flv_format.dart`
and `live_flv_relay.dart` implementation and synthetic fixtures were written
independently for this project; they do not copy the upstream relay source.

## guoapp 2026-11-21 feature adaptations

The Android chroma shader, source-group proxy routing, follow-finger tab paging,
and Windows mini-window edge controller reference Xanerix/guoapp, reviewed at
`a1c222418e13ade6106e0b5e3221e9df397ee870`:
https://github.com/Xanerix/guoapp/tree/a1c222418e13ade6106e0b5e3221e9df397ee870

Relevant commits are `0bd98a3e` (chroma correction), `c9ffb5ef` (source proxy),
`e29bb189` (paging), and `3288345f`, `5fa4cb0c`, `dd6b0099`, `79998fea`,
`a1c22241` (Windows edge hiding and snapping). These are incremental adaptations
to this application's native Go providers, bounded request/cache ownership,
existing theme, and playback intent safeguards, not a wholesale replacement.
The Hongguo helper-device retry policy also references the existing local
`upstream_modules/hongguo` 1.0.7 snapshot. Preserve the GPL-3.0 license and
applicable source notices when distributing these adaptations.

## guoapp loopback listener recovery

`native/core/app_stream_listener.go` and the per-session origin adaptation
reference Xanerix/guoapp commit `fb6103b1a7bee6ab016dcf40a128cb7a9cbe0ff7`
by feomao, reviewed at `6d4516e691d64f91992f6dc04fdd498b383e46ef`:
https://github.com/Xanerix/guoapp/commit/fb6103b1a7bee6ab016dcf40a128cb7a9cbe0ff7

The adaptation retains local session ownership, bounded media caches and the
existing diagnostic opt-in policy. It does not import LAN casting or iOS PiP.
Preserve the GPL-3.0 license and applicable source notices when distributing.

## Android direct hardware decoding

The `hardwareDirect` preference and paired `mediacodec` / `mediacodec_embed`
configuration reference Xanerix/guoapp commit
`4d3e726cf374bd647b413f5f5dfd95b4311ddb1b`:
https://github.com/Xanerix/guoapp/commit/4d3e726cf374bd647b413f5f5dfd95b4311ddb1b

The adaptation extends the pairing to this application's three-player window,
theater handoff and immutable per-player settings. Existing media_kit notices
and the project's GPL-3.0 license/source obligations remain unchanged.
