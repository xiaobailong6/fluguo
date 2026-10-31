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
