# Hongguo v5 offline fixtures

Source: guoapp-modules/hongguo v1.0.2, commit
`49bf731d49c8506f946a28d2d4efc2442c14c67e`.
https://github.com/guoapp-modules/hongguo/commit/49bf731d49c8506f946a28d2d4efc2442c14c67e

The v5 reference identifies its algorithm as GPL-3.0-only and credits
N3urda/hongguoTV Signer/AesV3/V5Constants and drpys `22261ad`.
See the repository's `THIRD_PARTY_NOTICES.md`.

- `signing-v5-f13.json`: 32 independent synthetic digest vectors, unchanged
  from upstream `test/fixtures/signing-v5-f13.json`.
  SHA-256: `cc6863401ab7904b035940310612403b859e09703332c86450f7a20cd2a1c7bd`.
- `signing-v5-carrier.json`: all four timestamp-dependent carrier variants,
  unchanged from upstream `test/fixtures/signing-v5-carrier.json`.
  SHA-256: `850b53855444fa94b0bd3bcf6fa8a21254c585926080267b5ea2ffa177fe68a7`.
- `signing-v5-headers.json`: deterministic complete signatures generated offline
  with that commit's `main.js` (`SHA-256:
  8b05f083fbf0d941b4fec2faec60874c9a7989851f6f63fcfa47432a15547324`).
  For each row, set `playbackV5Process` to `{nonce, started}`, make
  `host.randomBytes(n)` consume the row's `random` bytes sequentially, and call
  `signPlaybackV5("https://example.invalid/model", values,
  body === null ? null : UTF8(body), now)`. The expected query and all returned
  headers are stored without real credentials. The random stream is consumed
  in four 4-byte chunks: Helios prefix, protobuf field 3, Medusa nonce, carrier
  prefix. Vectors cover all four carrier branches, absent/empty/JSON/UTF-8
  bodies, query escaping, and millisecond ticket search across a second.

Go tests consume only JSON and standard-library code. Node was used only to
produce reference data outside the project; no JavaScript runtime is needed
for the application or its Go tests. All device fields and URLs in these
fixtures are synthetic. No request to a real source is performed.
