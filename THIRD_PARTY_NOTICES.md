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
