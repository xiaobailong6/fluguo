// SPDX-License-Identifier: GPL-3.0-only
// Offline oracle: the bundled upstream JavaScript crypto plus the Medusa envelope
// in N3urda/hongguoTV 615b0c5b5e3fc5202512da6c279ba4498736bbea / Signer.kt.
// Run with Node from any directory; never executes Go or performs network I/O.
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const reference = fs.readFileSync(path.resolve(__dirname, "../../../../upstream_modules/hongguo/main.js"), "utf8").replace(/\r\n/g, "\n");
assert.equal(crypto.createHash("sha256").update(reference).digest("hex"),
  "457f75b556cb0fb6f103b91fd9831f173ecbfdb266fa0bfe16f292d88a0a7b24");

// Keep upstream crypto, query encoding and header construction intact. Replace
// only its obsolete device envelope; fixed32 fields are explicitly zero floats.
const envelope = `
  const flags = new Uint8Array([0x44, 0x80, 0, 0, 0, 0, 0, 0]);
  const token = "A" + playbackV5Process.nonce;
  const random = host.randomBytes(4);
  const deviceInfo = concatBytes(
    playbackV5Proto([
      [1, 1], [2, 2], [3, "8662"], [4, who.device_id], [5, token],
      [6, "!noperm!"], [7, -888888], [8, -888888], [9, 3], [10, -888888],
      [11, "!notset!"], [12, "Asia/Shanghai,8"], [13, "zh_CN"], [14, 4]
    ]),
    ...[16,17,18,19,20,21].map(tag => {
      const out = []; appendUvarint(out, tag * 8 + 5);
      return concatBytes(out, [0,0,0,0]);
    }),
    playbackV5Proto([
      [22, who.os_version], [23, 41], [24, 36],
      [25, playbackV5Process.started], [26, playbackV5Process.started],
      [27, playbackV5Process.started], [28, nowMs], [29, -1],
      [30, who.device_type], [31, who.device_brand], [32, who.device_type],
      [33, who.device_type], [34, who.device_brand], [35, who.device_brand],
      [36, who.device_brand], [38, 31]
    ])
  );
  const env = playbackV5Proto([
    [1, 100 + random[0] % 21], [2, 247235599], [3, 247235596], [5, 7],
    [6, "v04.10.03.04-bugfix"], [7, 10001 + (random[2] + random[3] * 256) % 2000],
    [8, who.channel], [12, deviceInfo],
    [13, playbackV5Proto([[1, ts], [2, -2], [4, 200]])], [14, who.version_name]
  ]);
  const message = playbackV5Proto([
    [1, playbackV5Magic], [2, 5], [3, u32le(random, 0)], [4, "8662"],
    [5, who.device_id], [6, "646637794"], [7, who.version_name], [8, "v04.10.03-ml-android"],
    [9, 0x040a0300], [10, flags], [12, ts], [13, f13], [14, sliceBytes(queryHash, 0, 6)],
    [15, playbackV5Proto([[1, 305], [2, 4], [3, 694367], [5, 1621072674]])],
    [16, token], [17, ts], [20, "none"], [21, 312], [23, env],
    [24, '{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}']
  ]);
`;
const start = reference.indexOf("  const flags = new Uint8Array(8);", reference.indexOf("function playbackV5Medusa("));
const end = reference.indexOf("  const nonce = u32le(host.randomBytes(4), 0);", start);
assert(start > 0 && end > start);
const source = reference.slice(0, start) + envelope + reference.slice(end);
const file = path.join(__dirname, "signing-v5-headers.json");
const rows = JSON.parse(fs.readFileSync(file, "utf8"));
for (const row of rows) {
  const random = Buffer.from(row.random, "hex");
  let position = 0;
  const host = {
    utf8Encode: value => Uint8Array.from(Buffer.from(value)),
    utf8Decode: value => Buffer.from(value).toString("utf8"),
    hexEncode: value => Buffer.from(value).toString("hex"),
    hexDecode: value => Uint8Array.from(Buffer.from(value, "hex")),
    base64Encode: value => Buffer.from(value).toString("base64"),
    md5: value => Uint8Array.from(crypto.createHash("md5").update(Buffer.from(value)).digest()),
    randomBytes: size => {
      assert(position + size <= random.length);
      const bytes = Uint8Array.from(random.subarray(position, position + size));
      position += size;
      return bytes;
    },
  };
  const context = vm.createContext({host, module: {exports: {}}, row});
  vm.runInContext(source + `
    playbackV5Process = {nonce: row.nonce, started: row.started};
    result = signPlaybackV5("https://example.invalid/model", row.values,
      row.body === null ? null : host.utf8Encode(row.body), row.now);
  `, context);
  assert.equal(position, 16);
  assert.equal(context.result.url.split("?")[1], row.query, "the query/digest must not change");
  row.headers = {...context.result.headers};
}
const output = JSON.stringify(rows, null, 2) + "\n";
if (process.argv.includes("--check")) {
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), rows);
  console.log("All four complete signature vectors match the independent JavaScript oracle.");
} else {
  fs.writeFileSync(file, output);
}
