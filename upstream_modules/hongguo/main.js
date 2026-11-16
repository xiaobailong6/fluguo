const siteBaseUrl = "https://hongguoduanju.com";
const appBaseUrl = "https://api5-normal-sinfonlineb.fqnovel.com";
const appUserAgent = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)";
const webUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1";
const deviceRegisterUrl = "https://log.snssdk.com/service/2/device_register/";
const mediaReferer = "https://novel.snssdk.com/";
const responseLimit = 20 * 1024 * 1024;
const cencScheme = "hongguo-cenc://";
const audioScheme = "hongguo-audio://";
const bookPrefix = "book-";
const legacySeriesPrefix = "hg-series-v1:";
const tagPrefix = "tag:";
const tagPattern = /^tag:cate_[0-9]{1,9}$/;
const numericIdPattern = /^[0-9]{1,32}$/;
const rankingMetricPattern = /^[0-9]+(?:\.[0-9]+)?[万亿]?热度$/;
const seasonSuffixPattern = /第\s*([0-9零〇一二两兩三四五六七八九十百]+)\s*([季部])[\p{P}\s]*$/u;
const secondMs = 1000;
const minuteMs = 60 * secondMs;
const danmakuMaxDurationMs = 24 * 60 * minuteMs;
const defaultMaxPages = 50;
const deviceRotations = 3;
const registerPauseMs = 10 * minuteMs;
const appRequestTimeoutMs = 20 * secondMs;
const searchTimeoutMs = 40 * secondMs;
const searchPageTimeoutMs = 12 * secondMs;
const searchSeasonTimeoutMs = 25 * secondMs;
const audioSearchTimeoutMs = 10 * secondMs;
const suggestionTimeoutMs = 5 * secondMs;
const seasonTimeoutMs = 25 * secondMs;
const rankingTimeoutMs = 18 * secondMs;
const searchPageSize = 10;
const searchNameCount = 50;
const suggestionLimit = 10;
const seasonLimit = 200;
const searchSeasonQueries = 32;
const seriesSeasonLimit = 60;
const tagPageSize = 12;
const cellPageSize = 6;
const audioSearchSize = 10;
const doubleColumnShowType = "506";
const searchSeriesTab = "29";
const audioSearchTab = "2";
const tagPanelCategory = "5000";

const paths = {
  videoDetail: "/novel/player/video_detail/v1/",
  videoModel: "/novel/player/video_model/v1/",
  landpage: "/reading/distribution/category/landpage/v/",
  seriesPack: "/reading/distribution/book_pack_fields/inner_feed_detail/v1/",
  searchTab: "/reading/bookapi/search/tab/v/",
  tagLanding: "/reading/bookapi/new_category/landing/v/",
  bookmallTab: "/reading/bookapi/bookmall/tab/v1/",
  bookmallCellChange: "/reading/bookapi/bookmall/cell/change/v1/",
  audioDetail: "/reading/bookapi/detail/v1/",
  audioTone: "/reading/bookapi/audio/toneinfo/",
  audioDirectory: "/reading/bookapi/directory/all_items/v1/",
  audioPlayInfo: "/reading/reader/audio/playinfo/",
  audioSearch: "/reading/bookapi/search/tab/v1/",
};

const genres = [
  { key: "short_play", scene: "default", name: "真人剧" },
  { key: "comic_series", scene: "comic_series", name: "漫剧" },
  { key: "ai_series", scene: "ai_series", name: "AI剧" },
];

const audioCategories = [
  { key: "listen", tab: "5", name: "听书" },
  { key: "novel", tab: "2", name: "小说" },
];

const recommendationFeeds = [
  { key: "home_feed", tabType: "16", bottomTab: "7" },
  { key: "find_drama", tabType: "8", bottomTab: "" },
];

const rankingBoards = {
  "hongguo-hot": { path: "hot-drama", upstreamKey: "hongguo" },
  "hongguo-real": { path: "hot-real-drama", upstreamKey: "real" },
  "hongguo-comic": { path: "hot-comic-drama", upstreamKey: "comic" },
  "hongguo-ai": { path: "hot-ai-drama", upstreamKey: "ai" },
};

function failure(text, flags) {
  const error = new Error(text);
  if (flags) {
    Object.assign(error, flags);
  }
  return error;
}

function message(error) {
  return error !== null && typeof error === "object" && error.message !== undefined ? String(error.message) : String(error);
}

function joinErrors(...errors) {
  return new Error(errors.filter((error) => error).map(message).join("\n"));
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isEmptyRecord(value) {
  return !isRecord(value) || Object.keys(value).length === 0;
}

function numericId(value) {
  return typeof value === "string" && numericIdPattern.test(value);
}

function mapString(row, ...keys) {
  if (!isRecord(row)) {
    return "";
  }
  for (const key of keys) {
    const value = row[key];
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (trimmed !== "") {
        return trimmed;
      }
    } else if (typeof value === "boolean" || typeof value === "number") {
      return String(value);
    }
  }
  return "";
}

function mapStringList(row, ...keys) {
  const found = [];
  const add = (value) => {
    value = value.trim();
    if (value !== "" && !found.includes(value)) {
      found.push(value);
    }
  };
  if (!isRecord(row)) {
    return found;
  }
  for (const key of keys) {
    const value = row[key];
    if (typeof value === "string") {
      value.split(/[,/，、]/).forEach(add);
    } else if (Array.isArray(value)) {
      for (const item of value) {
        if (isRecord(item)) {
          add(mapString(item, "name", "title", "label", "tag"));
        } else if (item !== null && item !== undefined) {
          add(String(item));
        }
      }
    }
  }
  return found;
}

function firstNonEmpty(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim() !== "") {
      return value.trim();
    }
  }
  return "";
}

function nested(value, ...keys) {
  let current = isRecord(value) ? value : null;
  for (const key of keys) {
    if (current === null) {
      break;
    }
    current = isRecord(current[key]) ? current[key] : null;
  }
  return current === null ? {} : current;
}

function anyList(value) {
  if (Array.isArray(value)) {
    return value;
  }
  if (isRecord(value)) {
    for (const key of ["list", "items", "data"]) {
      const found = anyList(value[key]);
      if (found.length > 0) {
        return found;
      }
    }
  }
  return [];
}

function parseInteger(text) {
  return typeof text === "string" && /^[+-]?\d+$/.test(text) ? parseInt(text, 10) : NaN;
}

function parseNumber(text) {
  return typeof text === "string" && /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(text) ? Number(text) : NaN;
}

function runeCount(text) {
  return Array.from(text).length;
}

function truncate(text, limit) {
  const trimmed = text.trim();
  const characters = Array.from(trimmed);
  return characters.length <= limit ? trimmed : characters.slice(0, limit).join("") + "...";
}

function displayTitle(drama) {
  if (typeof drama.title === "string" && drama.title.trim() !== "") {
    return drama.title;
  }
  if (typeof drama.name === "string" && drama.name.trim() !== "") {
    return drama.name;
  }
  return "短剧";
}

function stableSort(list, less) {
  return list
    .map((value, index) => ({ value, index }))
    .sort((left, right) => (less(left.value, right.value) ? -1 : less(right.value, left.value) ? 1 : left.index - right.index))
    .map((entry) => entry.value);
}

function cacheRead(key) {
  const raw = host.cacheGet(key);
  return raw === null ? null : JSON.parse(raw);
}

function cacheWrite(key, value, ttlMs) {
  host.cacheSet(key, JSON.stringify(value), ttlMs);
}

function parseJson(text) {
  return JSON.parse(host.preserveIntegers(text));
}

function pad2(value) {
  return value < 10 ? "0" + value : String(value);
}

function chinaDate(ms) {
  const date = new Date(ms + 8 * 60 * minuteMs);
  return date.getUTCFullYear() + "-" + pad2(date.getUTCMonth() + 1) + "-" + pad2(date.getUTCDate());
}

function timestampDate(value) {
  let stamp = parseInteger(String(value).trim());
  if (!(stamp > 0)) {
    return "";
  }
  if (stamp > 100000000000) {
    stamp = Math.trunc(stamp / 1000);
  }
  const date = chinaDate(stamp * secondMs);
  const year = parseInt(date.slice(0, 4), 10);
  return year < 2000 || year > 2100 ? "" : date;
}

function validDate(year, month, day) {
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
}

function normalizeDate(text) {
  const matches = String(text).trim().match(/\d{4}-\d{1,2}-\d{1,2}/g) || [];
  for (const match of matches) {
    const [year, month, day] = match.split("-").map((part) => parseInt(part, 10));
    if (year >= 2000 && year <= 2100 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      return year + "-" + pad2(month) + "-" + pad2(day);
    }
  }
  return "";
}

function parseTime(text) {
  return typeof text === "string" ? Date.parse(text.replace(/(\.\d{3})\d+/, "$1")) : NaN;
}

function releaseStatusFromRemark(remark) {
  if (remark.includes("未完结") || remark.includes("更新至") || remark.includes("连载")) {
    return "ongoing";
  }
  if (/(?:全\s*\d+\s*集|\d+\s*集全|已完结|大结局)/.test(remark) || remark.includes("完结")) {
    return "finished";
  }
  return "unknown";
}

function nativeScore(score) {
  const trimmed = String(score || "").trim().replace(/^评分/, "").replace(/分$/, "").trim();
  const value = parseNumber(trimmed);
  return value > 0 && value <= 10 ? value.toFixed(1) : "";
}

function parseAddress(raw) {
  try {
    return host.parseUrl(raw);
  } catch (error) {
    return null;
  }
}

function httpAddress(raw) {
  const parsed = parseAddress(String(raw).trim());
  return parsed !== null && (parsed.scheme === "http" || parsed.scheme === "https") && parsed.hostname !== "" && !parsed.userInfo;
}

function coverAddress(...values) {
  for (let value of values) {
    value = typeof value === "string" ? value.trim() : "";
    if (value === "" || value.length > 8192) {
      continue;
    }
    if (value.startsWith("//")) {
      value = "https:" + value;
    }
    if (httpAddress(value)) {
      return value;
    }
  }
  return "";
}

function coverPathFromAny(value) {
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (trimmed === "") {
      return "";
    }
    if (trimmed.startsWith("//")) {
      return "https:" + trimmed;
    }
    if (trimmed.startsWith("/api/ui/image")) {
      const parsed = parseAddress(trimmed);
      const nestedUrl = parsed === null ? "" : queryValue(parsed.query, "url").trim();
      if (nestedUrl !== "") {
        return nestedUrl;
      }
    }
    const parsed = parseAddress(trimmed);
    if (parsed !== null && parsed.scheme !== "") {
      return trimmed;
    }
    return trimmed.replace(/^\/+/, "");
  }
  if (isRecord(value)) {
    for (const key of ["url", "src", "path", "cover", "coverUrl", "cover_url", "image", "pic", "poster"]) {
      const found = coverPathFromAny(value[key]);
      if (found !== "") {
        return found;
      }
    }
  } else if (Array.isArray(value)) {
    for (const entry of value) {
      const found = coverPathFromAny(entry);
      if (found !== "") {
        return found;
      }
    }
  }
  return "";
}

function decodeQueryComponent(text) {
  try {
    return decodeURIComponent(text.replace(/\+/g, " "));
  } catch (error) {
    return null;
  }
}

function queryValue(query, name) {
  for (const part of String(query || "").split("&")) {
    if (part === "") {
      continue;
    }
    const separator = part.indexOf("=");
    const key = decodeQueryComponent(separator < 0 ? part : part.slice(0, separator));
    if (key === name) {
      const value = decodeQueryComponent(separator < 0 ? "" : part.slice(separator + 1));
      return value === null ? "" : value;
    }
  }
  return "";
}

function queryEscape(text) {
  return encodeURIComponent(text)
    .replace(/[!'()*]/g, (character) => "%" + character.charCodeAt(0).toString(16).toUpperCase())
    .replace(/%20/g, "+");
}

function encodeQuery(params) {
  return Object.keys(params)
    .sort()
    .map((key) => queryEscape(key) + "=" + queryEscape(String(params[key])))
    .join("&");
}

function htmlUnescape(text) {
  const named = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0" };
  return text.replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (entity, body) => {
    if (body[0] === "#") {
      const code = body[1] === "x" || body[1] === "X" ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity;
    }
    return Object.prototype.hasOwnProperty.call(named, body) ? named[body] : entity;
  });
}

function extractAttr(block, name) {
  const match = new RegExp("\\b" + name.replace(/[.*+?^${}()|[\]\\-]/g, "\\$&") + "\\s*=\\s*[\"']([^\"']+)[\"']", "i").exec(block);
  return match ? htmlUnescape(match[1]).trim() : "";
}

function searchText(text) {
  const normalized = text.normalize("NFKC").replace(/[\s\p{P}]/gu, "").toLowerCase();
  return normalized === "" ? text.trim().toLowerCase() : normalized;
}

function searchKeyword(keyword) {
  keyword = String(keyword).trim().normalize("NFKC");
  if (keyword === "" || runeCount(keyword) > 80 || /\p{Cc}/u.test(keyword)) {
    throw new Error("请输入 1 至 80 个字符的搜索词");
  }
  return keyword;
}

function splitDramaId(id) {
  const trimmed = String(id || "").trim();
  const separator = trimmed.indexOf(":");
  if (separator < 0) {
    return ["", ""];
  }
  return [trimmed.slice(0, separator).trim().toLowerCase(), trimmed.slice(separator + 1).trim()];
}

function concatBytes(...parts) {
  let length = 0;
  for (const part of parts) {
    length += part.length;
  }
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    for (let index = 0; index < part.length; index++) {
      out[offset++] = part[index];
    }
  }
  return out;
}

function pad16(data) {
  const padding = 16 - (data.length % 16);
  const out = new Uint8Array(data.length + padding);
  for (let index = 0; index < out.length; index++) {
    out[index] = index < data.length ? data[index] : padding;
  }
  return out;
}

function sliceBytes(data, start, end) {
  const out = [];
  for (let index = start; index < end; index++) {
    out.push(data[index]);
  }
  return out;
}

function appendUvarint(out, value) {
  while (value >= 128) {
    out.push((value % 128) | 128);
    value = Math.floor(value / 128);
  }
  out.push(value);
}

function varintField(out, field, value) {
  appendUvarint(out, field * 8);
  appendUvarint(out, value);
}

function bytesField(out, field, value) {
  appendUvarint(out, field * 8 + 2);
  appendUvarint(out, value.length);
  for (let index = 0; index < value.length; index++) {
    out.push(value[index]);
  }
}

function u32le(data, offset) {
  return (data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
}

function rotl32(value, bits) {
  bits &= 31;
  return bits === 0 ? value >>> 0 : ((value << bits) | (value >>> (32 - bits))) >>> 0;
}

const mask64 = (1n << 64n) - 1n;

function readU64(data, offset) {
  return BigInt(u32le(data, offset)) | (BigInt(u32le(data, offset + 4)) << 32n);
}

function writeU64(data, offset, value) {
  const low = Number(value & 0xffffffffn);
  const high = Number(value >> 32n);
  for (let index = 0; index < 4; index++) {
    data[offset + index] = (low >>> (8 * index)) & 255;
    data[offset + 4 + index] = (high >>> (8 * index)) & 255;
  }
}

function rotl64(value, bits) {
  const shift = ((bits % 64) + 64) % 64;
  return shift === 0 ? value : ((value << BigInt(shift)) | (value >> BigInt(64 - shift))) & mask64;
}

function rotl8(value, bits) {
  return ((value << bits) | (value >>> (8 - bits))) & 255;
}

function reverse8(value) {
  let out = 0;
  for (let bit = 0; bit < 8; bit++) {
    out = (out << 1) | ((value >>> bit) & 1);
  }
  return out;
}

function popCount(value) {
  let count = 0;
  for (; value > 0; value >>>= 1) {
    count += value & 1;
  }
  return count;
}

function sm3(input) {
  const length = input.length;
  const blocks = Math.ceil((length + 9) / 64);
  const data = new Uint8Array(blocks * 64);
  for (let index = 0; index < length; index++) {
    data[index] = input[index];
  }
  data[length] = 0x80;
  const bits = length * 8;
  const high = Math.floor(bits / 0x100000000);
  const low = bits >>> 0;
  for (let index = 0; index < 4; index++) {
    data[data.length - 8 + index] = (high >>> (24 - 8 * index)) & 255;
    data[data.length - 4 + index] = (low >>> (24 - 8 * index)) & 255;
  }
  const state = [0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e];
  const words = new Array(68);
  for (let offset = 0; offset < data.length; offset += 64) {
    for (let index = 0; index < 16; index++) {
      const at = offset + index * 4;
      words[index] = ((data[at] << 24) | (data[at + 1] << 16) | (data[at + 2] << 8) | data[at + 3]) >>> 0;
    }
    for (let index = 16; index < 68; index++) {
      const value = (words[index - 16] ^ words[index - 9] ^ rotl32(words[index - 3], 15)) >>> 0;
      words[index] = (value ^ rotl32(value, 15) ^ rotl32(value, 23) ^ rotl32(words[index - 13], 7) ^ words[index - 6]) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = state;
    for (let index = 0; index < 64; index++) {
      const early = index < 16;
      const constant = early ? 0x79cc4519 : 0x7a879d8a;
      const ff = (early ? a ^ b ^ c : (a & b) | (a & c) | (b & c)) >>> 0;
      const gg = (early ? e ^ f ^ g : (e & f) | (~e & g)) >>> 0;
      const rotated = rotl32(a, 12);
      const ss1 = rotl32((rotated + e + rotl32(constant, index)) >>> 0, 7);
      const tt1 = (ff + d + ((ss1 ^ rotated) >>> 0) + ((words[index] ^ words[index + 4]) >>> 0)) >>> 0;
      const tt2 = (gg + h + ss1 + words[index]) >>> 0;
      d = c;
      c = rotl32(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = rotl32(f, 19);
      f = e;
      e = (tt2 ^ rotl32(tt2, 9) ^ rotl32(tt2, 17)) >>> 0;
    }
    [a, b, c, d, e, f, g, h].forEach((value, index) => {
      state[index] = (state[index] ^ value) >>> 0;
    });
  }
  const out = new Uint8Array(32);
  state.forEach((value, index) => {
    for (let shift = 0; shift < 4; shift++) {
      out[index * 4 + shift] = (value >>> (24 - 8 * shift)) & 255;
    }
  });
  return out;
}

let argusMaterial = null;

function argusSetup() {
  if (argusMaterial !== null) {
    return argusMaterial;
  }
  const key = host.hexDecode("ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c");
  const derived = sm3(concatBytes(key, [0x3c, 0xcc, 0x56, 0x7b], key));
  const rounds = [];
  for (let index = 0; index < 4; index++) {
    rounds.push(readU64(derived, index * 8));
  }
  for (let index = 4; index < 72; index++) {
    let mixed = rotl64(rounds[index - 1], -3) ^ rounds[index - 3];
    mixed ^= rotl64(mixed, -1);
    rounds.push((~rounds[index - 4] & mask64) ^ mixed ^ ((0x3dc94c3a046d678bn >> BigInt((index - 4) % 62)) & 1n) ^ 3n);
  }
  argusMaterial = { rounds, aesKey: host.md5(sliceBytes(key, 0, 16)), iv: host.md5(sliceBytes(key, 16, 32)) };
  return argusMaterial;
}

function argusSeal(message) {
  const { rounds, aesKey, iv } = argusSetup();
  const data = pad16(message);
  for (let offset = 0; offset < data.length; offset += 16) {
    let left = readU64(data, offset);
    let right = readU64(data, offset + 8);
    for (const round of rounds) {
      const next = left ^ (rotl64(right, 1) & rotl64(right, 8)) ^ rotl64(right, 2) ^ round;
      left = right;
      right = next;
    }
    writeU64(data, offset, left);
    writeU64(data, offset + 8, right);
  }
  const xor = [0xd0, 0x4f, 0xfd, 0xff, 0xd0, 0x4f, 0xfd, 0xff];
  for (let index = 0; index < data.length; index++) {
    data[index] ^= xor[index % 8];
  }
  const reversed = Array.from(concatBytes(xor, data)).reverse();
  const container = pad16(concatBytes([0xa6, 0xe7, 0x83, 0xee, 0x70, 0x01, 0x10, 0x09, 0x18], reversed, [0x56, 0x7b]));
  return host.base64Encode(concatBytes([0x3c, 0xcc], host.aesCbcEncrypt(aesKey, iv, container)));
}

function playerArgus(query, body, timestamp, deviceId, nonce) {
  const bodyHash = body === null ? sm3(new Uint8Array(16)) : sm3(host.md5(body));
  const queryHash = sm3(host.utf8Encode(query));
  const counters = [];
  varintField(counters, 1, 1);
  varintField(counters, 2, 1);
  varintField(counters, 3, 1);
  varintField(counters, 7, 3348294860);
  const environment = [];
  bytesField(environment, 1, host.utf8Encode("25053RT47C"));
  bytesField(environment, 2, host.utf8Encode("16"));
  bytesField(environment, 3, host.utf8Encode("update_64"));
  varintField(environment, 4, 2147483648);
  const message = [];
  varintField(message, 1, 0x20200929 * 2);
  varintField(message, 2, 2);
  varintField(message, 3, u32le(nonce, 6) & 0x7fffffff);
  bytesField(message, 4, host.utf8Encode("8662"));
  bytesField(message, 5, host.utf8Encode(deviceId));
  bytesField(message, 6, host.utf8Encode("1611921764"));
  bytesField(message, 7, host.utf8Encode("7.3.5.32"));
  bytesField(message, 8, host.utf8Encode("v04.07.01-ml-android"));
  varintField(message, 9, 135135744);
  bytesField(message, 10, new Uint8Array(8));
  varintField(message, 11, 0);
  varintField(message, 12, timestamp * 2);
  bytesField(message, 13, sliceBytes(bodyHash, 0, 6));
  bytesField(message, 14, sliceBytes(queryHash, 0, 6));
  bytesField(message, 15, counters);
  bytesField(message, 16, []);
  bytesField(message, 20, host.utf8Encode("none"));
  varintField(message, 21, 738);
  bytesField(message, 23, environment);
  varintField(message, 25, 2);
  return argusSeal(message);
}

function commentArgus(query, timestamp, nonce) {
  const message = [];
  varintField(message, 1, 0x20200929 * 2);
  varintField(message, 2, 2);
  varintField(message, 3, u32le(nonce, 6));
  bytesField(message, 4, host.utf8Encode("3019"));
  bytesField(message, 6, host.utf8Encode("1611921764"));
  bytesField(message, 7, host.utf8Encode("6.8.1.32"));
  bytesField(message, 8, host.utf8Encode("v04.07.01-ml-android"));
  varintField(message, 9, 135135744);
  bytesField(message, 10, new Uint8Array(8));
  varintField(message, 12, timestamp * 2);
  bytesField(message, 13, sliceBytes(sm3(new Uint8Array(16)), 0, 6));
  bytesField(message, 14, sliceBytes(sm3(host.utf8Encode(query)), 0, 6));
  const counters = [8, 2 + (nonce[10] % 49) * 2];
  for (const field of [2, 3, 4]) {
    appendUvarint(counters, field * 8);
    appendUvarint(counters, 1388734);
  }
  bytesField(message, 15, counters);
  bytesField(message, 20, host.utf8Encode("none"));
  varintField(message, 21, 738);
  return argusSeal(message);
}

function ladon(aid, timestamp, prefix, suffix) {
  const digest = host.utf8Encode(host.hexEncode(host.md5(concatBytes(prefix, host.utf8Encode(aid)))));
  let left = readU64(digest, 0);
  let right = readU64(digest, 8);
  const queue = [readU64(digest, 16), readU64(digest, 24)];
  const keys = [];
  for (let index = 0; index < 34; index++) {
    keys.push(left);
    const mixed = ((rotl64(right, -8) + left) & mask64) ^ BigInt(index);
    queue.push(mixed);
    left = mixed ^ rotl64(left, 3);
    right = queue.shift();
  }
  const data = pad16(host.utf8Encode(timestamp + "-1611921764-" + suffix));
  for (let offset = 0; offset < data.length; offset += 16) {
    let blockLeft = readU64(data, offset);
    let blockRight = readU64(data, offset + 8);
    for (const key of keys) {
      blockRight = key ^ ((blockLeft + rotl64(blockRight, -8)) & mask64);
      blockLeft = blockRight ^ rotl64(blockLeft, 3);
    }
    writeU64(data, offset, blockLeft);
    writeU64(data, offset + 8, blockRight);
  }
  return host.base64Encode(concatBytes(prefix, data));
}

function putUint32BE(data, offset, value) {
  for (let index = 0; index < 4; index++) {
    data[offset + index] = (value >>> (24 - 8 * index)) & 255;
  }
}

function signPlayer(rawQuery, body, aid, deviceId, nowMs, nonce) {
  const stamp = Math.floor(nowMs / secondMs) >>> 0;
  const headers = {};
  const queryHash = host.md5(rawQuery);
  const payload = new Array(20).fill(0);
  for (let index = 0; index < 4; index++) {
    payload[index] = queryHash[index];
  }
  if (body !== null) {
    const bodyHash = host.md5(body);
    for (let index = 0; index < 4; index++) {
      payload[4 + index] = bodyHash[index];
    }
    headers["X-SS-STUB"] = host.hexEncode(bodyHash).toUpperCase();
  }
  [0, 6, 11, 28].forEach((value, index) => {
    payload[12 + index] = value;
  });
  putUint32BE(payload, 16, stamp);
  const key = [0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc, 0xa4, 0x93, 0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4, 0xa4, 0x96, 0x93, 0x8f];
  for (let index = 0; index < 20; index++) {
    payload[index] ^= key[index];
  }
  for (let index = 0; index < 20; index++) {
    const mixed = rotl8(payload[index], 4) ^ payload[(index + 1) % 20];
    payload[index] = reverse8(mixed) ^ 0xff ^ 20;
  }
  headers["X-Khronos"] = String(stamp);
  headers["X-Gorgon"] = host.hexEncode([0x84, 0x04, 0x40, 0x1c, 0, 0].concat(payload));
  headers["X-SS-Req-Ticket"] = String(nowMs);
  headers["X-Argus"] = playerArgus(rawQuery, body, stamp, deviceId, nonce);
  headers["X-Ladon"] = ladon(aid, stamp, sliceBytes(nonce, 2, 6), aid);
  return headers;
}

function signComment(rawQuery, aid, nowMs, nonce) {
  const stamp = Math.floor(nowMs / secondMs) >>> 0;
  const head2 = ((nonce[0] % 7) + 1) << 5;
  const head3 = 0xe0 | (nonce[1] & 15);
  const seed = new Array(20).fill(0);
  const hash = host.md5(rawQuery);
  for (let index = 0; index < 4; index++) {
    seed[index] = hash[index];
  }
  [0, 1, 7, 4].forEach((value, index) => {
    seed[12 + index] = value;
  });
  putUint32BE(seed, 16, stamp);
  const key = [0x4a, 0, 0x16, head3, 0x47, 0x6c, 0, head2];
  const box = [];
  for (let index = 0; index < 256; index++) {
    box.push(index);
  }
  let j = 0;
  for (let index = 0; index < 256; index++) {
    j = (j + box[index] + key[index & 7]) & 255;
    box[index] = box[j];
  }
  j = 0;
  for (let offset = 0; offset < 20; offset++) {
    const index = (offset + 1) & 255;
    j = (j + box[index]) & 255;
    box[index] = box[j];
    seed[offset] ^= box[(box[index] + box[j]) & 255];
  }
  for (let index = 0; index < 20; index++) {
    seed[index] = reverse8(rotl8(seed[index], 4) ^ seed[(index + 1) % 20]) ^ 0xeb;
  }
  return {
    "X-Gorgon": host.hexEncode([0x84, 4, head2, head3, 0, 0].concat(seed)),
    "X-Khronos": String(stamp),
    "X-SS-Req-Ticket": String(nowMs),
    "X-SS-STUB": "",
    "X-Argus": commentArgus(rawQuery, stamp, nonce),
    "X-Ladon": ladon(aid, stamp, sliceBytes(nonce, 2, 6), "3019"),
  };
}

function contentKey(value) {
  if (value.length > 1024) {
    throw new Error("红果媒体密钥数据过长");
  }
  let raw;
  try {
    raw = host.base64Decode(value);
  } catch (error) {
    raw = null;
  }
  if (raw === null || raw.length < 3) {
    throw new Error("红果媒体密钥编码无效");
  }
  const tagLength = (raw[0] ^ raw[1] ^ raw[2]) - 48;
  const contentLength = raw.length - tagLength - 1;
  if (tagLength < 1 || contentLength < 33 || contentLength >= raw.length) {
    throw new Error("红果媒体密钥结构无效");
  }
  const seed = raw[raw.length - tagLength - 2] ^ raw[raw.length - tagLength - 1];
  let tag = "";
  for (let index = 0; index < tagLength; index++) {
    tag += String.fromCharCode(raw[raw.length - tagLength + index] ^ seed);
  }
  if (tag === "app_v2" || tag === "web_v2") {
    throw new Error("红果媒体密钥版本暂不支持");
  }
  const decoded = [];
  let previousEven = 250;
  let previousOdd = 85;
  for (let index = 0; index < contentLength; index++) {
    const current = raw[1 + index];
    let previous = previousEven;
    if (index % 2 === 0) {
      previousEven = current;
    } else {
      previous = previousOdd;
      previousOdd = current;
    }
    decoded.push(((previous ^ current) - 21 - popCount(index)) & 255);
  }
  const paddingCharacter = String.fromCharCode(decoded[0]);
  const padding = /^[0-9a-zA-Z]$/.test(paddingCharacter) ? parseInt(paddingCharacter, 36) : NaN;
  if (Number.isNaN(padding) || contentLength - padding - 1 !== 32) {
    throw new Error("红果媒体密钥内容无效");
  }
  const hex = String.fromCharCode.apply(null, decoded.slice(1, 33));
  let key;
  try {
    key = /^[0-9a-fA-F]{32}$/.test(hex) ? host.hexDecode(hex) : null;
  } catch (error) {
    key = null;
  }
  if (key === null || key.length !== 16) {
    throw new Error("红果媒体密钥不是有效的 AES-128 密钥");
  }
  return host.base64Encode(key);
}

function decodeBase64Text(value) {
  try {
    return host.utf8Decode(host.base64Decode(value)).trim();
  } catch (error) {
    return null;
  }
}

function mediaAddresses(info) {
  const addresses = [];
  const add = (value) => {
    if (typeof value === "string") {
      let address = value.trim();
      if (address.length > 8192) {
        return;
      }
      if (!httpAddress(address)) {
        address = decodeBase64Text(address);
        if (address === null) {
          return;
        }
      }
      if (httpAddress(address) && !addresses.includes(address)) {
        addresses.push(address);
      }
    } else if (Array.isArray(value)) {
      value.forEach(add);
    }
  };
  if (isRecord(info)) {
    for (const key of ["main_url", "backup_url", "backup_url_1", "backup_url_2", "backup_urls", "url_list"]) {
      add(info[key]);
    }
  }
  return addresses;
}

function randomHex(size) {
  return host.hexEncode(host.randomBytes(size));
}

function uuidLike() {
  const raw = randomHex(16);
  return raw.slice(0, 8) + "-" + raw.slice(8, 12) + "-" + raw.slice(12, 16) + "-" + raw.slice(16, 20) + "-" + raw.slice(20);
}

function newDeviceId() {
  let value = 0n;
  for (const byte of host.randomBytes(8)) {
    value = (value << 8n) | BigInt(byte);
  }
  return (1000000000000000000n + (value % 8000000000000000000n)).toString();
}

function emptyCursor() {
  return { offset: 0, sessionId: "", lastId: "", pageSignature: "", initialized: false, exhausted: false, updatedAt: "0001-01-01T00:00:00Z" };
}

function freshState() {
  return {
    version: 1,
    deviceId: newDeviceId(),
    installId: newDeviceId(),
    helperDeviceId: newDeviceId(),
    helperInstallId: newDeviceId(),
    feeds: {},
  };
}

function readState() {
  return cacheRead("state");
}

function writeState(state) {
  cacheWrite("state", state, 0);
  return state;
}

function currentState() {
  return readState() || host.exclusive(() => readState() || writeState(freshState()));
}

function updateState(change) {
  return host.exclusive(() => {
    const state = readState() || freshState();
    change(state);
    return writeState(state);
  });
}

function deviceOf(state, helper) {
  if (helper) {
    return [state.helperDeviceId || "", state.helperInstallId || "", state.helperRegistered === true];
  }
  return [state.deviceId || "", state.installId || "", state.registered === true];
}

function appQuery(deviceId, installId) {
  return {
    aid: "8662", app_name: "novelread", version_code: "73532", version_name: "7.3.5.32",
    manifest_version_code: "73532", update_version_code: "73532", channel: "update_64",
    device_platform: "android", os: "android", ssmix: "a", device_type: "25053RT47C",
    device_brand: "Redmi", language: "zh", os_api: "36", os_version: "16",
    resolution: "1280*2772", dpi: "520", ac: "wifi", device_id: deviceId, iid: installId,
  };
}

function registerDevice() {
  const header = {
    display_name: "红果免费短剧", aid: 8662, app_version: "7.3.5.32", version_code: 73532,
    manifest_version_code: 73532, update_version_code: 73532, channel: "update_64", package: "com.phoenix.read",
    app_language: "zh", os: "Android", os_version: "16", os_api: 36, device_model: "25053RT47C",
    device_brand: "Redmi", device_manufacturer: "Xiaomi", cpu_abi: "arm64-v8a", density_dpi: 520,
    display_density: "xxhdpi", resolution: "2772x1280", language: "zh", timezone: 8, access: "wifi",
    openudid: randomHex(8), clientudid: uuidLike(), cdid: uuidLike(),
    region: "CN", tz_name: "Asia/Shanghai", tz_offset: 28800, sim_region: "cn", device_platform: "android",
    not_request_sender: 0, is_system_app: 0, sdk_flavor: "china", rom: "OS2.0", rom_version: "BP2A.250605.031.A3",
  };
  const body = JSON.stringify({ magic_tag: "ss_app_log", header, _gen_time: Date.now() });
  const query = appQuery("", "");
  delete query.device_id;
  delete query.iid;
  query.req_id = uuidLike();
  const ticket = host.reserve({ url: deviceRegisterUrl });
  query._rticket = String(Date.now());
  const response = host.fetch({
    method: "POST", url: deviceRegisterUrl + "?" + encodeQuery(query), body, ticket,
    limit: 64 * 1024, timeoutMs: appRequestTimeoutMs, followRedirects: true, anyStatus: true,
    headers: { "User-Agent": appUserAgent, Accept: "application/json", "Content-Type": "application/json; charset=utf-8" },
  });
  if (response.status >= 500) {
    throw new Error("红果设备注册 HTTP " + response.status);
  }
  let result;
  try {
    result = parseJson(response.body);
  } catch (error) {
    result = undefined;
  }
  if (result === undefined) {
    throw new Error("红果设备注册收到的不是接口数据（HTTP " + response.status + "）");
  }
  if (response.status !== 200) {
    throw failure("红果设备注册 HTTP " + response.status, { rejection: true });
  }
  const deviceId = mapString(result, "device_id_str", "device_id");
  const installId = mapString(result, "install_id_str", "install_id");
  if (!numericId(deviceId) || !numericId(installId) || deviceId === "0" || installId === "0") {
    throw failure("红果设备注册未返回设备号", { rejection: true });
  }
  return { deviceId, installId };
}

function ensureDevice(helper, rejected) {
  const settled = (state) => {
    const [current, , registered] = deviceOf(state, helper);
    return rejected === "" ? registered : rejected !== current;
  };
  if (settled(currentState())) {
    return;
  }
  host.exclusive(() => {
    const state = readState() || freshState();
    if (settled(state)) {
      return;
    }
    const paused = host.cacheGet("registerPause");
    if (paused !== null) {
      throw new Error("红果设备注册暂不可用：" + paused);
    }
    let registered;
    try {
      registered = registerDevice();
    } catch (error) {
      if (error.rejection) {
        host.cacheSet("registerPause", message(error), registerPauseMs);
      }
      throw error;
    }
    if (helper) {
      state.helperDeviceId = registered.deviceId;
      state.helperInstallId = registered.installId;
      state.helperRegistered = true;
    } else {
      state.deviceId = registered.deviceId;
      state.installId = registered.installId;
      state.registered = true;
    }
    writeState(state);
  });
}

function remainingMs(deadline) {
  return deadline === undefined ? Infinity : deadline - Date.now();
}

function timeoutError() {
  return failure("红果请求超时", { timeout: true });
}

function appRequest(method, path, extra, payload, options) {
  options = options || {};
  const comment = options.comment === true;
  const helper = options.helper === true;
  const deadline = options.deadline;
  const signed = !comment && path !== paths.bookmallTab;
  let lane = "";
  let registerError = null;
  if (signed) {
    try {
      ensureDevice(helper, "");
    } catch (error) {
      registerError = error;
    }
  }
  let [deviceId, installId] = deviceOf(currentState(), helper);
  if (helper) {
    if (deviceId === "" || !signed) {
      throw new Error("红果辅助设备不可用");
    }
    lane = "hongguo-helper";
  }
  const query = Object.assign(appQuery(deviceId, installId), extra || {});
  const body = payload === null || payload === undefined ? null : typeof payload === "string" ? payload : JSON.stringify(payload);
  const attempts = Math.min(Math.max(host.retries(), 1), 3);
  let lastError = null;
  let rotations = 0;
  for (let attempt = 0; attempt < attempts; attempt++) {
    if (attempt > 0) {
      if (remainingMs(deadline) <= attempt * secondMs) {
        throw lastError || timeoutError();
      }
      host.sleep(attempt * secondMs);
    }
    if (remainingMs(deadline) <= 0) {
      throw lastError || timeoutError();
    }
    const address = appBaseUrl + path;
    const nonce = comment ? host.randomBytes(11) : null;
    let ticket;
    try {
      ticket = host.reserve({ url: address, lane, background: options.background === true });
    } catch (error) {
      lastError = error;
      if (error.backoff) {
        throw error;
      }
      continue;
    }
    const now = Date.now();
    query._rticket = String(now);
    const rawQuery = encodeQuery(query);
    const headers = { "User-Agent": appUserAgent, Accept: "application/json", "X-XS-From-Web": "0", "Sdk-Version": "2" };
    if (comment) {
      headers["Comment-Source"] = "601";
      headers["Server-Channel"] = "1000";
      Object.assign(headers, signComment(rawQuery, query.aid, now, nonce));
    } else if (signed) {
      Object.assign(headers, signPlayer(rawQuery, body, query.aid, query.device_id, now, host.randomBytes(11)));
    }
    if (body !== null) {
      headers["Content-Type"] = "application/json; charset=utf-8";
    }
    let response;
    try {
      response = host.fetch({
        method, url: address + "?" + rawQuery, headers, body: body === null ? "" : body, ticket,
        limit: responseLimit, timeoutMs: Math.min(appRequestTimeoutMs, remainingMs(deadline)),
        followRedirects: true, anyStatus: true, background: options.background === true,
      });
    } catch (error) {
      if (error.oversized) {
        throw new Error("红果 App 接口未返回有效数据");
      }
      lastError = error;
      if (error.backoff) {
        throw error;
      }
      continue;
    }
    if (response.status !== 200) {
      lastError = new Error("红果 App 接口 HTTP " + response.status);
      if (response.status >= 400 && response.status < 500) {
        throw lastError;
      }
      continue;
    }
    if (response.body.length === 0) {
      lastError = new Error("红果 App 接口未返回有效数据");
      if (signed && rotations < deviceRotations) {
        try {
          ensureDevice(helper, deviceId);
          registerError = null;
          rotations++;
          [deviceId, installId] = deviceOf(currentState(), helper);
          query.device_id = deviceId;
          query.iid = installId;
          attempt--;
        } catch (error) {
          registerError = error;
        }
      }
      if (registerError !== null) {
        lastError = new Error("红果 App 接口未返回有效数据（设备注册失败：" + message(registerError) + "）");
      }
      continue;
    }
    let result;
    try {
      result = parseJson(response.body);
    } catch (error) {
      result = null;
    }
    if (!isRecord(result)) {
      throw new Error("红果 App 接口返回格式异常");
    }
    const code = firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nested(result, "BaseResp"), "StatusCode"));
    if (code !== "" && code !== "0") {
      throw new Error("红果 App 接口暂不可用（" + truncate(code, 20) + "）");
    }
    return result;
  }
  throw lastError || new Error("红果 App 接口未返回有效数据");
}

function fetchSiteText(address, noCache) {
  return host.fetchText({ url: address, referer: siteBaseUrl + "/", noCache: noCache === true }).body;
}

function leadingJson(text, start) {
  const end = text.indexOf("</script>", start);
  if (end > start) {
    try {
      const value = parseJson(text.slice(start, end).replace(/[\s;]+$/, ""));
      return isRecord(value) ? value : null;
    } catch (error) {}
  }
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < text.length; index++) {
    const code = text.charCodeAt(index);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (code === 92) {
        escaped = true;
      } else if (code === 34) {
        inString = false;
      }
      continue;
    }
    if (code === 34) {
      inString = true;
    } else if (code === 123 || code === 91) {
      depth++;
    } else if (code === 125 || code === 93) {
      depth--;
      if (depth === 0) {
        try {
          const value = parseJson(text.slice(start, index + 1));
          return isRecord(value) ? value : null;
        } catch (error) {
          return null;
        }
      }
    } else if (depth === 0 && code > 32) {
      return null;
    }
  }
  return null;
}

function parseRouterData(raw) {
  const match = /(?:window\.)?_ROUTER_DATA\s*=\s*/.exec(raw);
  return match ? leadingJson(raw, match.index + match[0].length) : null;
}

function routerLoaderMap(data, ...names) {
  const loader = nested(data, "loaderData");
  for (const name of names) {
    if (!isEmptyRecord(loader[name])) {
      return loader[name];
    }
  }
  for (const key of Object.keys(loader)) {
    for (const name of names) {
      const prefix = name.replace(/\$$/, "");
      if (prefix !== "" && key.startsWith(prefix) && !isEmptyRecord(loader[key])) {
        return loader[key];
      }
    }
  }
  return null;
}

function heat(row) {
  const hot = nested(row, "hot_score_data");
  const score = firstNonEmpty(mapString(hot, "score"), mapString(row, "hot_score"));
  if (score !== "") {
    const value = parseNumber(score);
    if (value >= 0 && Number.isFinite(value)) {
      return score;
    }
  }
  return mapString(hot, "text");
}

function onlineDate(row, now) {
  const date = timestampDate(mapString(row, "first_visible_time"));
  if (date !== "") {
    return date;
  }
  for (const value of anyList(row.sub_title_list)) {
    const label = mapString(nested(value), "content");
    if (label === "今日上新") {
      return chinaDate(now);
    }
    if (label === "昨日上新") {
      return chinaDate(now - 24 * 60 * minuteMs);
    }
    if (label.endsWith("上新")) {
      const found = normalizeDate(label);
      if (found !== "") {
        const [year, month, day] = found.split("-").map((part) => parseInt(part, 10));
        if (validDate(year, month, day)) {
          return found;
        }
      }
    }
  }
  return "";
}

function dramaFromRow(value, category) {
  if (!isRecord(value)) {
    return null;
  }
  const row = isEmptyRecord(value.video_data) ? value : value.video_data;
  const sourceId = firstNonEmpty(
    mapString(row, "series_id_str", "series_id"),
    mapString(value, "series_id_str", "series_id"),
    mapString(row, "keyword"),
    mapString(value, "keyword"),
  );
  if (!numericId(sourceId)) {
    return null;
  }
  const title = firstNonEmpty(mapString(row, "series_title", "series_name", "title"), mapString(value, "series_name", "name"), sourceId);
  const cover = firstNonEmpty(mapString(row, "series_cover", "cover"), mapString(value, "series_cover"));
  const intro = firstNonEmpty(mapString(row, "series_intro", "video_desc"), mapString(value, "series_intro"));
  const count = firstNonEmpty(mapString(row, "episode_cnt"), mapString(value, "episode_cnt"));
  let remark = firstNonEmpty(mapString(row, "episode_right_text"), mapString(value, "episode_right_text"));
  let releaseStatus = releaseStatusFromRemark(remark);
  const status = mapString(row, "series_status");
  if (status === "1") {
    releaseStatus = "finished";
  } else if (status === "0") {
    releaseStatus = "ongoing";
  }
  if (remark === "" && count !== "") {
    remark = "共" + count + "集";
  }
  const tags = mapStringList(row, "tags");
  for (const item of anyList(row.category_list)) {
    const name = mapString(item, "name");
    if (name !== "" && !tags.includes(name)) {
      tags.push(name);
    }
  }
  try {
    const schema = JSON.parse(mapString(row, "category_schema"));
    if (Array.isArray(schema)) {
      for (const item of schema) {
        if (isRecord(item) && typeof item.name === "string" && item.name !== "" && !tags.includes(item.name)) {
          tags.push(item.name);
        }
      }
    }
  } catch (error) {}
  let genre = mapString(row, "category_name", "categoryName", "category");
  if (genre === "" && tags.length > 0) {
    genre = tags[0];
  }
  return {
    id: host.dramaId(sourceId), source: host.source, sourceId, title, name: title, desc: intro, intro,
    cover, coverUrl: cover, categoryName: firstNonEmpty(genre, category), channelName: "红果", remark,
    totalEpisode: count, episodeCount: count, tags, releaseStatus, score: mapString(row, "score"),
    views: mapString(row, "series_play_cnt", "play_cnt"), heat: heat(row), onlineDate: onlineDate(row, Date.now()),
  };
}

function valueEmpty(value) {
  if (value === null || value === undefined) {
    return true;
  }
  const text = String(value).trim();
  return text === "" || text === "0";
}

function blank(value) {
  return typeof value !== "string" || value.trim() === "";
}

function mergeDramaMetadata(base, extra) {
  const merged = Object.assign({}, base);
  if ((merged.vip === null || merged.vip === undefined) && extra.vip !== null && extra.vip !== undefined) {
    merged.vip = extra.vip;
  }
  for (const key of ["id", "source", "sourceId", "title", "name", "desc", "intro", "channelName", "score", "views", "heat", "onlineDate"]) {
    if (blank(merged[key])) {
      merged[key] = extra[key];
    }
  }
  for (const key of ["cover", "coverUrl"]) {
    if (coverPathFromAny(merged[key]) === "") {
      merged[key] = extra[key];
    }
  }
  for (const key of ["totalEpisode", "episodeCount"]) {
    if (valueEmpty(merged[key])) {
      merged[key] = extra[key];
    }
  }
  if (blank(merged.categoryName) || (merged.categoryName === "首页" && !blank(extra.categoryName))) {
    merged.categoryName = extra.categoryName;
  }
  if (blank(merged.remark) || merged.remark === "在线观看") {
    merged.remark = extra.remark;
  }
  if (!Array.isArray(merged.tags) || merged.tags.length === 0) {
    merged.tags = extra.tags;
  }
  if (!merged.releaseStatus || merged.releaseStatus === "unknown") {
    merged.releaseStatus = extra.releaseStatus;
  }
  return merged;
}

function validCategory(category) {
  return genres.some((genre) => genre.key === category) || audioCategories.some((item) => item.key === category) || tagPattern.test(category);
}

function categories(force) {
  const base = genres.map((genre) => ({ id: genre.key, name: genre.name })).concat(audioCategories.map((item) => ({ id: item.key, name: item.name })));
  let tags;
  try {
    tags = fetchTagCategories();
  } catch (error) {
    return { items: base, incomplete: true };
  }
  return base.concat(tags);
}

function catalogHasMore(state) {
  return genres.some((genre) => !state || !(state.feeds[genre.key] && state.feeds[genre.key].exhausted));
}

function catalogPage(page, category) {
  if (audioCategories.some((item) => item.key === category)) {
    return audioCatalogPage(page, category);
  }
  if (category.startsWith(tagPrefix)) {
    return tagPage(category, page);
  }
  let items = [];
  let error = null;
  try {
    const result = appCatalog(category);
    items = result.items;
    if (result.failures !== "") {
      error = new Error(result.failures);
    }
  } catch (thrown) {
    error = thrown;
  }
  const state = currentState();
  let hasMore = catalogHasMore(state);
  if (category !== "") {
    const cursor = state.feeds["category:" + category];
    hasMore = !(cursor && cursor.exhausted);
  }
  if (items.length === 0 && error !== null && (category === "" || category === "short_play")) {
    const web = fetchWebCategory("real-drama?page=" + page, "真人剧");
    return { items: web.items, hasMore: page < web.pages };
  }
  if (error !== null && items.length === 0) {
    throw error;
  }
  return { items, hasMore, warning: error === null ? "" : message(error) };
}

function fetchWebCategory(route, category) {
  const body = fetchSiteText(siteBaseUrl + "/category/" + route);
  const page = routerLoaderMap(parseRouterData(body), "category_page", "category_$");
  if (page === null || page.isSuccess === false) {
    throw new Error("红果分类数据不可用，可能是页面结构或访问权限变化");
  }
  const items = anyList(page.recommendList).map((item) => dramaFromRow(item, category)).filter((drama) => drama !== null);
  const pages = parseInteger(mapString(nested(page, "pagination"), "totalPages"));
  return { items, pages: Number.isNaN(pages) ? 0 : pages };
}

function catalogPayload(scene, genre, offset, sessionId, sort, filterIds) {
  return {
    req_scene: scene, offset, limit: 54, req_type: "only_content", need_selector_panel: false,
    client_req_type: offset > 0 ? 2 : 3, session_id: sessionId, filter_ids: filterIds,
    select_items: {
      genre: [genre], sort, gender: [], category_dim_theme: [], category_dim_role: [], category_dim_epoch: [],
      online_time: [], creation_status: [],
    },
  };
}

function appCatalog(category) {
  let selected = genres;
  if (category !== "") {
    selected = genres.filter((genre) => genre.key === category);
    if (selected.length === 0) {
      throw new Error("红果分类无效");
    }
  }
  const feedKey = (key) => (category !== "" ? "category:" + key : key);
  const context = host.catalogContext();
  const state = currentState();
  let pageLimit = host.maxPages();
  if (pageLimit < 1) {
    pageLimit = defaultMaxPages;
  }
  pageLimit = Math.min(pageLimit, 200);
  const headLimit = Math.min(pageLimit, 3);
  if (!context.background) {
    pageLimit = Math.min(pageLimit, Math.max(1, Math.floor(3 / selected.length)));
  }
  const roundLimit = Math.max(pageLimit, headLimit);
  const scans = selected.map((genre) => {
    const cursor = Object.assign(emptyCursor(), state.feeds[feedKey(genre.key)] || {});
    if (!context.more && cursor.initialized) {
      return { cursor: emptyCursor(), tail: cursor, head: true, done: false, pages: 0 };
    }
    return { cursor, tail: emptyCursor(), head: false, done: cursor.exhausted, pages: 0 };
  });
  const seen = new Map();
  let dramas = [];
  const failures = [];
  for (let round = 0; round < roundLimit; round++) {
    let active = false;
    selected.forEach((genre, index) => {
      const scan = scans[index];
      if (scan.done || (!scan.head && scan.pages >= pageLimit)) {
        return;
      }
      active = true;
      const cursor = Object.assign({}, scan.cursor);
      const age = Date.now() - parseTime(cursor.updatedAt);
      if (!(age >= 0 && age <= 30 * minuteMs)) {
        cursor.sessionId = "";
      }
      const payload = catalogPayload(genre.scene, genre.key, cursor.offset, cursor.sessionId, ["online_time"], "");
      let items = [];
      let nextCursor = null;
      let pageError = null;
      let newItems = 0;
      for (let attempt = 0; attempt < 2; attempt++) {
        let result = null;
        let error = null;
        try {
          result = appRequest("POST", paths.landpage, null, payload);
        } catch (thrown) {
          error = thrown;
        }
        const retryable = error === null || cursor.sessionId !== "";
        items = [];
        if (error === null) {
          const parsed = parseCatalogPage(result, cursor, genre.name);
          items = parsed.items;
          nextCursor = parsed.cursor;
          error = parsed.error;
        }
        newItems = 0;
        for (const drama of items) {
          if (!host.isKnown(drama.id)) {
            newItems++;
          }
          if (seen.has(drama.id)) {
            const position = seen.get(drama.id);
            dramas[position] = mergeDramaMetadata(drama, dramas[position]);
          } else {
            seen.set(drama.id, dramas.length);
            dramas.push(drama);
          }
        }
        pageError = error;
        if (error === null) {
          break;
        }
        host.reportProgress(items);
        if (attempt > 0 || !retryable || error.backoff) {
          break;
        }
        payload.session_id = "";
      }
      if (pageError !== null) {
        failures.push(genre.name + ": " + message(pageError));
        scan.done = true;
        return;
      }
      scan.pages++;
      scan.cursor = nextCursor;
      scan.done = nextCursor.exhausted;
      let checkpoint = nextCursor;
      if (scan.head && newItems === 0 && !nextCursor.exhausted) {
        scan.done = true;
        if (scan.tail.exhausted || scan.tail.offset >= nextCursor.offset) {
          checkpoint = scan.tail;
        }
      }
      if (scan.head && (scan.done || scan.pages >= headLimit)) {
        scan.done = true;
      }
      updateState((saved) => {
        saved.feeds[feedKey(genre.key)] = checkpoint;
      });
      host.reportProgress(items);
    });
    if (!active) {
      break;
    }
  }
  dramas = stableSort(dramas, (left, right) => displayTitle(left) < displayTitle(right));
  return { items: dramas, failures: failures.join("\n") };
}

function parseCatalogPage(result, cursor, category) {
  const data = nested(result, "data");
  const rows = data.video_data;
  if (!Array.isArray(rows)) {
    return { items: [], cursor, error: new Error("App 分类数据格式异常") };
  }
  const items = [];
  const ids = [];
  for (const row of rows) {
    const drama = dramaFromRow(row, category);
    if (drama !== null) {
      items.push(drama);
      if (!ids.includes(drama.id)) {
        ids.push(drama.id);
      }
    }
  }
  const fail = (text) => ({ items, cursor, error: new Error(text) });
  if (rows.length > 0 && items.length === 0) {
    return fail("App 分类未返回可识别的剧集");
  }
  let next = parseInteger(mapString(data, "next_offset"));
  const hasMore = data.has_more;
  if (typeof hasMore !== "boolean" || (hasMore && Number.isNaN(next))) {
    return fail("App 分页标记无效，已保留上次位置");
  }
  if (Number.isNaN(next)) {
    next = cursor.offset + rows.length;
  }
  let lastId = "";
  let signature = "";
  if (items.length > 0) {
    lastId = items[items.length - 1].id;
    signature = host.hexEncode(host.sha256(ids.slice().sort().join("\n")));
  }
  if (hasMore && (items.length === 0 || next <= cursor.offset || next > 1000000 || signature === cursor.pageSignature)) {
    return fail("App 分页未前进，已保留上次位置");
  }
  if (!hasMore && (next < cursor.offset || next > 1000000)) {
    next = cursor.offset;
  }
  const session = mapString(data, "session_id");
  if (session.length > 4096 || /[\r\n\x00]/.test(session)) {
    return fail("App 分页会话无效，已保留上次位置");
  }
  const updated = Object.assign({}, cursor, {
    exhausted: !hasMore, initialized: true, offset: next, sessionId: session, lastId, pageSignature: signature,
    updatedAt: new Date().toISOString(),
  });
  return { items, cursor: updated, error: null };
}

function tagQuery(offset, session) {
  const query = {
    genre_type: "130", query_gender: "1", category_type: "5", page_version: "2", source: "detail",
    limit: String(tagPageSize), offset: String(offset), client_req_type: offset > 0 ? "2" : "3",
  };
  if (session !== "") {
    query.session_id = session;
  }
  return query;
}

function fetchTagCategories() {
  const query = Object.assign(tagQuery(0, ""), {
    category_id: tagPanelCategory, selected_item_from_front_page: tagPanelCategory,
    is_merged_landing_page: "true", category_new_page_715: "1",
  });
  const result = appRequest("GET", paths.tagLanding, query, null);
  const found = [];
  const seen = new Set();
  for (const row of anyList(nested(result, "data", "selector").rows)) {
    if (mapString(row, "type") !== "dialog_bottom") {
      continue;
    }
    for (const item of anyList(isRecord(row) ? row.items : null)) {
      const id = tagPrefix + mapString(item, "selector_item_id");
      const name = mapString(item, "show_name");
      if (name === "" || seen.has(id) || !tagPattern.test(id)) {
        continue;
      }
      seen.add(id);
      found.push({ id, name });
    }
  }
  if (found.length === 0) {
    throw new Error("红果题材列表为空");
  }
  return found;
}

function tagPage(category, page) {
  let cursor = cacheRead("tagCursor:" + category) || { page: 0, offset: 0, session: "" };
  if (cursor.page !== page - 1) {
    cursor = { page: page - 1, offset: (page - 1) * tagPageSize, session: "" };
  }
  const query = Object.assign(tagQuery(cursor.offset, cursor.session), {
    category_id: "0", selected_items: category.slice(tagPrefix.length), selected_order: "new_sort_hot",
  });
  const result = appRequest("GET", paths.tagLanding, query, null);
  const data = nested(result, "data");
  const rows = anyList(data.video_info);
  const dramas = rows.map((row) => dramaFromRow(row, "真人剧")).filter((drama) => drama !== null);
  if (rows.length > 0 && dramas.length === 0) {
    throw new Error("红果题材未返回可识别的剧集");
  }
  let more = data.has_more === true;
  let next = parseInteger(mapString(data, "offset"));
  if (Number.isNaN(next) || next <= cursor.offset) {
    next = cursor.offset + rows.length;
    more = more && rows.length > 0;
  }
  cacheWrite("tagCursor:" + category, { page, offset: next, session: mapString(data, "session_id") }, 30 * minuteMs);
  return { items: dramas, hasMore: more };
}

function chapterOf(seriesId, videoId, index) {
  return {
    id: host.chapterId(seriesId, videoId), source: host.source, title: "第" + index + "集",
    videoUrl: cencScheme + videoId, currentEpisode: index,
  };
}

function parseAppDetail(result, seriesId) {
  const detail = nested(result, "data", "video_data");
  if (mapString(detail, "series_id_str", "series_id") !== seriesId) {
    throw new Error("红果 App 未返回所请求的剧集");
  }
  const drama = dramaFromRow(detail, "短剧");
  const seenVideos = new Set();
  const seenEpisodes = new Set();
  let chapters = [];
  for (const video of anyList(detail.video_list)) {
    const videoId = mapString(video, "vid");
    const index = parseInteger(mapString(video, "vid_index"));
    if (Number.isNaN(index) || index < 1 || !numericId(videoId)) {
      throw new Error("红果 App 分集编号或视频 ID 无效");
    }
    const identifier = mapString(video, "series_id");
    if (identifier !== "" && identifier !== seriesId) {
      throw new Error("红果 App 返回了其他剧集的分集");
    }
    if (seenVideos.has(videoId) || seenEpisodes.has(index)) {
      throw new Error("红果 App 返回了重复分集");
    }
    seenVideos.add(videoId);
    seenEpisodes.add(index);
    const chapter = chapterOf(seriesId, videoId, index);
    if (typeof video.vertical === "boolean") {
      chapter.vertical = video.vertical;
    }
    chapters.push(chapter);
  }
  chapters = stableSort(chapters, (left, right) => left.currentEpisode < right.currentEpisode);
  const total = parseInteger(mapString(detail, "episode_cnt"));
  if (chapters.length === 0 || total > chapters.length) {
    throw new Error("红果 App 未返回完整分集，已尝试其他详情入口");
  }
  chapters.forEach((chapter, index) => {
    if (chapter.currentEpisode !== index + 1) {
      throw new Error("红果 App 分集列表不连续");
    }
  });
  return { drama, chapters };
}

function appDetail(seriesId) {
  if (!numericId(seriesId)) {
    throw new Error("红果剧集 ID 无效");
  }
  const cached = cacheRead("detail:" + seriesId);
  if (cached !== null) {
    return cached;
  }
  const result = appRequest("POST", paths.videoDetail, null, { series_id: seriesId });
  const entry = parseAppDetail(result, seriesId);
  cacheWrite("detail:" + seriesId, entry, 5 * minuteMs);
  return entry;
}

function webChapters(sourceId) {
  const body = fetchSiteText(siteBaseUrl + "/detail?series_id=" + queryEscape(sourceId));
  const page = routerLoaderMap(parseRouterData(body), "detail_page", "detail_");
  const detail = nested(page, "seriesDetail");
  if (isEmptyRecord(detail)) {
    throw new Error("hongguo detail is empty");
  }
  const title = firstNonEmpty(mapString(detail, "series_name", "series_title", "name"), sourceId);
  const chapters = [];
  anyList(detail.vid_list).forEach((value, index) => {
    const videoId = value === null || value === undefined ? "" : String(value).trim();
    if (videoId !== "") {
      chapters.push(chapterOf(sourceId, videoId, index + 1));
    }
  });
  if (chapters.length === 0) {
    throw new Error("红果详情没有返回剧集 ID");
  }
  return { title, chapters };
}

function detail(sourceId) {
  if (sourceId.startsWith(bookPrefix)) {
    return audioDetail(sourceId.slice(bookPrefix.length));
  }
  const trimmed = sourceId.trim();
  const seriesId = trimmed.startsWith(legacySeriesPrefix) ? trimmed.slice(legacySeriesPrefix.length) : trimmed;
  if (seriesId === "") {
    throw new Error("empty hongguo sourceID");
  }
  let title;
  let chapters;
  try {
    const entry = appDetail(seriesId);
    title = displayTitle(entry.drama || {});
    chapters = entry.chapters;
  } catch (appError) {
    try {
      const web = webChapters(seriesId);
      title = web.title;
      chapters = web.chapters;
    } catch (webError) {
      throw new Error("App 详情失败: " + message(appError) + "；网页详情失败: " + message(webError));
    }
  }
  let drama = { id: host.dramaId(sourceId), title, source: host.source };
  const fresh = cacheRead("detail:" + splitDramaId(drama.id)[1]);
  if (fresh !== null && fresh.drama) {
    drama = mergeDramaMetadata(fresh.drama, drama);
  }
  return { drama, chapters };
}

function resolveMedia(task) {
  const chapter = task.chapter;
  if (chapter.videoUrl.startsWith(audioScheme)) {
    return resolveAudioMedia(task);
  }
  if (chapter.videoUrl.startsWith(cencScheme)) {
    return resolveVideoMedia(task);
  }
  return host.finishMedia({ url: chapter.videoUrl, referer: firstNonEmpty(chapter.referer, siteBaseUrl + "/") });
}

function resolveVideoMedia(task) {
  const [source, seriesId] = splitDramaId(task.dramaId);
  if (source !== host.source || seriesId === "") {
    throw new Error("红果章节缺少剧 ID，请刷新剧库后重新加入队列");
  }
  const videoId = task.chapter.videoUrl.slice(cencScheme.length);
  if (!numericId(videoId) || !numericId(seriesId)) {
    throw new Error("红果章节 ID 无效，请重新获取章节");
  }
  let nativeError;
  try {
    return appMedia(videoId);
  } catch (error) {
    nativeError = error;
  }
  try {
    return webMedia(seriesId, videoId);
  } catch (pageError) {
    throw new Error("红果 App 取流失败：" + message(nativeError) + "；网页取流失败：" + message(pageError));
  }
}

function appMedia(videoId) {
  if (!numericId(videoId)) {
    throw new Error("红果视频 ID 无效");
  }
  let lastError;
  for (const helper of [false, true]) {
    try {
      return fetchAppMedia(videoId, helper);
    } catch (error) {
      if (!error.noCompatibleMedia) {
        throw error;
      }
      lastError = error;
    }
  }
  const [rejected] = deviceOf(currentState(), true);
  try {
    ensureDevice(true, rejected);
  } catch (rotateError) {
    throw new Error(message(lastError) + "；更换辅助设备也没有成功：" + message(rotateError));
  }
  return fetchAppMedia(videoId, true);
}

function fetchAppMedia(videoId, helper) {
  const payload = { video_id: videoId, content_type: 1, biz_param: { need_all_video_definition: true, video_platform: 3 } };
  const result = appRequest("POST", paths.videoModel, null, payload, { helper });
  const data = nested(result, "data");
  let model = isRecord(data.video_model) ? data.video_model : null;
  if (typeof data.video_model === "string" && data.video_model !== "") {
    let encoded = data.video_model;
    const decoded = decodeBase64Text(encoded);
    if (decoded !== null && decoded !== "") {
      encoded = decoded;
    }
    try {
      model = parseJson(encoded);
    } catch (error) {
      model = undefined;
    }
    if (!isRecord(model) && model !== null) {
      throw new Error("红果 App 播放信息格式异常");
    }
  }
  if (isEmptyRecord(model) && anyList(data.video_list).length > 0) {
    model = { video_list: data.video_list, video_duration: data.video_duration, duration: data.duration };
  }
  return selectAppMedia(model || {});
}

function selectAppMedia(model) {
  let variants = anyList(model.video_list);
  if (isRecord(model.video_list) && variants.length === 0) {
    variants = Object.keys(model.video_list).sort().map((key) => model.video_list[key]);
  }
  const duration = parseNumber(mapString(model, "video_duration", "duration"));
  const durationMs = Number.isFinite(duration) ? Math.trunc(duration * secondMs) : 0;
  let keyError = null;
  let unsupported = 0;
  let unaddressed = 0;
  let choices = [];
  for (const variant of variants) {
    const meta = nested(variant, "video_meta");
    const codec = mapString(meta, "codec_type").toLowerCase();
    if (codec === "bytevc2" || mapString(variant, "gear_des_key").toLowerCase().includes("bytevc2")) {
      unsupported++;
      continue;
    }
    const addresses = mediaAddresses(variant);
    if (addresses.length === 0) {
      unaddressed++;
      continue;
    }
    const media = { referer: mediaReferer, durationMs };
    const encryption = nested(variant, "encrypt_info");
    const spade = mapString(encryption, "spade_a");
    if (spade !== "" || encryption.encrypt === true || mapString(encryption, "encryption_method") === "cenc-aes-ctr") {
      try {
        media.cencKey = contentKey(spade);
      } catch (error) {
        keyError = error;
        continue;
      }
    }
    let height = parseInteger(mapString(meta, "vheight"));
    if (Number.isNaN(height)) {
      height = 0;
    }
    const definitionMatch = mapString(meta, "definition").match(/[0-9]+/);
    const definition = definitionMatch ? parseInteger(definitionMatch[0]) : NaN;
    const width = parseInteger(mapString(meta, "vwidth"));
    if (definition > 0) {
      height = definition;
    } else if (width > 0 && (height === 0 || width < height)) {
      height = width;
    }
    media.quality = height;
    const score = height * 10 + (codec === "h264" || codec === "avc1" ? 1 : 0);
    for (const address of addresses) {
      choices.push({ media: Object.assign({}, media, { url: address }), score });
    }
  }
  if (choices.length > 0) {
    choices = stableSort(choices, (left, right) => left.score > right.score);
    return Object.assign({}, choices[0].media, { variants: choices.map((choice) => choice.media) });
  }
  if (keyError !== null) {
    throw new Error("红果 App 媒体密钥不可用: " + message(keyError));
  }
  const noMedia = (detail) => failure("红果 App 未返回兼容的媒体：" + detail, { noCompatibleMedia: true });
  if (variants.length === 0) {
    throw noMedia("没有返回任何线路");
  }
  if (unsupported === 0) {
    throw noMedia("返回的线路都没有播放地址");
  }
  if (unaddressed === 0) {
    throw noMedia("已跳过不支持的编码");
  }
  throw noMedia("已跳过不支持的编码，其余线路没有播放地址");
}

function webMedia(seriesId, videoId) {
  const body = fetchSiteText(siteBaseUrl + "/player/" + encodeURIComponent(seriesId) + "/" + encodeURIComponent(videoId));
  const page = routerLoaderMap(parseRouterData(body), "player_", "player_page");
  if (mapString(page, "vid") !== videoId || mapString(page, "series_id") !== seriesId) {
    throw new Error("红果未返回所请求的剧集，可能仅允许网页试看；请在站点确认该集的访问权限");
  }
  const info = nested(page, "video_player_info");
  const addresses = mediaAddresses(info);
  if (addresses.length === 0) {
    throw new Error("红果该集未提供公开播放地址，可能需要登录或 App 授权；不会将试看集冒充该集下载");
  }
  const duration = parseNumber(mapString(info, "duration"));
  const durationMs = Number.isFinite(duration) ? Math.trunc(duration * secondMs) : 0;
  const referer = siteBaseUrl + "/";
  return {
    url: addresses[0], referer, durationMs,
    variants: addresses.map((address) => ({ url: address, referer, durationMs })),
  };
}

function fetchSuggestionRecords(query, count, deadline) {
  const timeout = Math.min(suggestionTimeoutMs, remainingMs(deadline));
  if (timeout <= 0) {
    throw timeoutError();
  }
  let response;
  try {
    response = host.fetch({
      method: "GET",
      url: siteBaseUrl + "/incent_resource/suggestion?" + encodeQuery({ app_id: "8662", query, count: String(count) }),
      limit: 256 * 1024, timeoutMs: timeout, followRedirects: true,
      headers: { "User-Agent": webUserAgent, Referer: siteBaseUrl + "/", Accept: "application/json", "Accept-Language": "zh-CN,zh;q=0.9" },
    });
  } catch (error) {
    if (error.oversized) {
      throw new Error("红果搜索联想响应过大");
    }
    throw error;
  }
  let result;
  try {
    result = parseJson(response.body);
  } catch (error) {
    result = null;
  }
  if (!isRecord(result)) {
    throw new Error("红果搜索联想未返回有效数据");
  }
  const items = Array.isArray(result.suggest_list) ? result.suggest_list : nested(result, "data").suggest_list;
  if (!Array.isArray(items)) {
    throw new Error("红果搜索联想未返回有效数据");
  }
  return items.filter(isRecord);
}

function fetchSearchNames(keyword, deadline) {
  const dramas = [];
  for (const record of fetchSuggestionRecords(keyword, searchNameCount, deadline)) {
    const videoData = isRecord(record.video_data) ? record.video_data : null;
    if (record.word_type !== "short_play_name" || !numericId(mapString(videoData, "series_id_str", "series_id"))) {
      continue;
    }
    const drama = dramaFromRow({ video_data: videoData, name: record.name, keyword: record.keyword }, "短剧");
    if (drama !== null && displayTitle(drama) !== drama.sourceId) {
      dramas.push(drama);
    }
  }
  return dramas;
}

function fetchSearchPage(keyword, page, deadline) {
  const offset = String((page - 1) * searchPageSize);
  const query = { query: keyword, offset, count: String(searchPageSize), tab_type: searchSeriesTab };
  if (page > 1) {
    query.passback = offset;
    const searchId = host.cacheGet("searchId:" + keyword);
    if (searchId !== null) {
      query.search_id = searchId;
    }
  }
  const result = appRequest("GET", paths.searchTab, query, null, { deadline });
  let tab = null;
  for (const item of anyList(result.search_tabs)) {
    if (mapString(item, "tab_type") === searchSeriesTab) {
      tab = item;
    }
  }
  if (tab === null) {
    throw new Error("红果搜索未返回有效结果");
  }
  const searchId = mapString(tab, "search_id");
  if (page === 1 && searchId !== "") {
    host.cacheSet("searchId:" + keyword, searchId, 30 * minuteMs);
  }
  const cells = anyList(tab.data);
  const items = [];
  const seen = new Set();
  for (const cell of cells) {
    for (const video of anyList(isRecord(cell) ? cell.video_data : null)) {
      const drama = dramaFromRow({ video_data: video }, "短剧");
      if (drama !== null && !seen.has(drama.id)) {
        seen.add(drama.id);
        items.push(drama);
      }
    }
  }
  if (cells.length > 0 && items.length === 0) {
    throw new Error("红果搜索结果中没有可识别的剧集");
  }
  return { items, hasMore: tab.has_more === true };
}

function mergeSearchDramas(dramas, batch) {
  const positions = new Map();
  dramas.forEach((drama, index) => positions.set(drama.id, index));
  for (const drama of batch) {
    if (!drama.id) {
      continue;
    }
    if (positions.has(drama.id)) {
      const index = positions.get(drama.id);
      dramas[index] = mergeDramaMetadata(dramas[index], drama);
    } else {
      positions.set(drama.id, dramas.length);
      dramas.push(drama);
    }
  }
  return dramas;
}

function titleSearchRank(title, query) {
  const words = query.normalize("NFKC").split(/[\s\p{P}]+/u).filter((word) => word !== "");
  query = searchText(query);
  title = searchText(title);
  if (title === query) {
    return 0;
  }
  if (title.startsWith(query)) {
    return 1;
  }
  if (title.includes(query)) {
    return 2;
  }
  const matches = words.filter((word) => title.includes(searchText(word))).length;
  return words.length > 0 && matches === words.length ? 3 : 4;
}

function parseSeason(title) {
  title = title.trim().normalize("NFKC");
  const match = seasonSuffixPattern.exec(title);
  if (!match) {
    return null;
  }
  const base = title.slice(0, match.index).replace(/[\s\p{P}]+$/u, "");
  const label = match[1];
  const unit = match[2];
  let number;
  if (/^[0-9]+$/.test(label)) {
    number = parseInt(label, 10);
  } else {
    const digits = { 零: 0, 〇: 0, 一: 1, 二: 2, 两: 2, 兩: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
    number = 0;
    if (!/[十百]/.test(label)) {
      for (const character of label) {
        if (!(character in digits)) {
          return null;
        }
        number = number * 10 + digits[character];
        if (number > seasonLimit) {
          return null;
        }
      }
    } else {
      let digit = 0;
      let previous = 1000;
      for (const character of label) {
        if (character in digits) {
          digit = digit * 10 + digits[character];
          continue;
        }
        const value = character === "百" ? 100 : 10;
        if (value >= previous || digit > 9) {
          return null;
        }
        number += Math.max(digit, 1) * value;
        digit = 0;
        previous = value;
      }
      number += digit;
    }
  }
  if (base === "" || number < 1 || number > seasonLimit) {
    return null;
  }
  return { base, number, unit, label };
}

function chineseSeason(number) {
  const digits = Array.from("零一二三四五六七八九");
  if (number < 10) {
    return digits[number];
  }
  if (number < 100) {
    let prefix = number >= 20 ? digits[Math.floor(number / 10)] : "";
    prefix += "十";
    if (number % 10 !== 0) {
      prefix += digits[number % 10];
    }
    return prefix;
  }
  let prefix = digits[Math.floor(number / 100)] + "百";
  const rest = number % 100;
  if (rest === 0) {
    return prefix;
  }
  if (rest < 10) {
    prefix += "零";
  } else if (rest < 20) {
    prefix += "一";
  }
  return prefix + chineseSeason(rest);
}

function addToSeries(series, drama) {
  const parsed = parseSeason(displayTitle(drama));
  let season = parsed === null ? 0 : parsed.number;
  if (season === 0 && searchText(displayTitle(drama)) === series.key) {
    season = 1;
  } else if (season === 0 || parsed.unit !== series.unit || searchText(parsed.base) !== series.key) {
    return false;
  }
  series.known.add(season);
  series.maximum = Math.max(series.maximum, season);
  if (parsed !== null && parsed.label !== "") {
    series.labels.set(season, parsed.label);
  }
  return true;
}

function seriesGroups(keyword, dramas) {
  if (parseSeason(keyword) !== null) {
    return [];
  }
  const query = searchText(keyword);
  const groups = [];
  const byKey = new Map();
  for (const drama of dramas) {
    const parsed = parseSeason(displayTitle(drama));
    if (parsed === null) {
      continue;
    }
    const key = searchText(parsed.base);
    if (!key.includes(query)) {
      continue;
    }
    const groupKey = key + ":" + parsed.unit;
    if (!byKey.has(groupKey)) {
      const series = { title: parsed.base, key, unit: parsed.unit, maximum: 0, known: new Set(), labels: new Map() };
      byKey.set(groupKey, series);
      groups.push(series);
    }
  }
  let incomplete = [];
  for (const group of groups) {
    for (const drama of dramas) {
      addToSeries(group, drama);
    }
    if (group.known.size >= 2 && group.known.size < group.maximum) {
      incomplete.push(group);
    }
  }
  incomplete = stableSort(incomplete, (left, right) => {
    const leftRank = titleSearchRank(left.title, query);
    const rightRank = titleSearchRank(right.title, query);
    return leftRank !== rightRank ? leftRank < rightRank : left.known.size > right.known.size;
  });
  return incomplete;
}

function nextSeriesQuery(series, attempted) {
  for (let season = 1; season <= series.maximum; season++) {
    if (series.known.has(season)) {
      continue;
    }
    let nearest = 0;
    let distance = seasonLimit + 1;
    for (let known = 1; known <= series.maximum; known++) {
      const delta = Math.abs(known - season);
      if (series.labels.get(known) && delta < distance) {
        nearest = known;
        distance = delta;
      }
    }
    let labels = [chineseSeason(season), String(season)];
    if (/^[+-]?\d+$/.test(series.labels.get(nearest) || "")) {
      labels = [labels[1], labels[0]];
    }
    const queries = season === 1 ? [series.title] : [];
    for (const label of labels) {
      queries.push(series.title + "第" + label + series.unit);
    }
    for (const query of queries) {
      let valid = true;
      try {
        searchKeyword(query);
      } catch (error) {
        valid = false;
      }
      if (valid && !attempted.has(query)) {
        return query;
      }
    }
  }
  return "";
}

function completeSearchSeasons(keyword, entry, deadline) {
  const groups = seriesGroups(keyword, entry.items);
  if (groups.length === 0) {
    return false;
  }
  const budget = Math.min(searchSeasonTimeoutMs, remainingMs(deadline) - 100);
  if (budget <= 0) {
    return true;
  }
  const seasonDeadline = Date.now() + budget;
  const attempted = new Set([keyword]);
  let requests = 0;
  for (const group of groups) {
    while (requests < searchSeasonQueries) {
      const query = nextSeriesQuery(group, attempted);
      if (query === "") {
        break;
      }
      attempted.add(query);
      requests++;
      let names;
      try {
        names = fetchSearchNames(query, seasonDeadline);
      } catch (error) {
        return true;
      }
      const matches = names.filter((drama) => addToSeries(group, drama));
      if (matches.length > 0) {
        entry.items = mergeSearchDramas(entry.items, matches);
      }
    }
  }
  return groups.some((group) => group.known.size < group.maximum);
}

function fetchVideoSearch(keyword) {
  const deadline = Date.now() + searchTimeoutMs;
  let names = [];
  let namesError = null;
  try {
    names = fetchSearchNames(keyword, deadline);
  } catch (error) {
    namesError = error;
  }
  if (remainingMs(deadline) <= 0) {
    if (names.length > 0) {
      return { items: names, hasMore: false, warning: "搜索已到时限，已保留名称匹配结果，可重试" };
    }
    throw namesError || timeoutError();
  }
  let page = { items: [], hasMore: false };
  let pageError = null;
  try {
    page = fetchSearchPage(keyword, 1, Math.min(deadline, Date.now() + searchPageTimeoutMs));
  } catch (error) {
    pageError = error;
  }
  if ((pageError !== null && namesError !== null) || (page.items.length + names.length === 0 && (pageError !== null || namesError !== null))) {
    throw joinErrors(pageError, namesError);
  }
  const entry = { items: mergeSearchDramas(mergeSearchDramas([], page.items), names), hasMore: page.hasMore, warning: "" };
  const seasonsLimited = completeSearchSeasons(keyword, entry, deadline) || remainingMs(deadline) <= 0;
  entry.items = stableSort(entry.items, (left, right) => {
    const leftTitle = displayTitle(left);
    const rightTitle = displayTitle(right);
    const leftRank = titleSearchRank(leftTitle, keyword);
    const rightRank = titleSearchRank(rightTitle, keyword);
    if (leftRank !== rightRank) {
      return leftRank < rightRank;
    }
    const leftSeason = parseSeason(leftTitle);
    const rightSeason = parseSeason(rightTitle);
    if (leftSeason !== null && rightSeason !== null && leftSeason.unit === rightSeason.unit && searchText(leftSeason.base) === searchText(rightSeason.base)) {
      return leftSeason.number < rightSeason.number;
    }
    return false;
  });
  if (pageError !== null) {
    entry.warning = "红果综合搜索暂不可用，已保留名称匹配结果，可重试";
  } else if (namesError !== null) {
    entry.warning = "红果名称检索暂不可用，结果可能缺少部分剧集，可重试";
  }
  if (seasonsLimited) {
    entry.warning += (entry.warning !== "" ? "；" : "") + "部分季数暂未补齐，已保留当前结果，可重试";
  }
  return entry;
}

function searchVideo(page, keyword) {
  if (page > 1) {
    return Object.assign(fetchSearchPage(keyword, page), { warning: "" });
  }
  const cached = cacheRead("search:" + keyword);
  if (cached !== null) {
    return cached;
  }
  const entry = fetchVideoSearch(keyword);
  if (entry.warning === "") {
    cacheWrite("search:" + keyword, entry, 5 * minuteMs);
  }
  return entry;
}

function search(page, query) {
  page = Math.max(page, 1);
  const keyword = searchKeyword(query);
  let audio = null;
  let audioError = null;
  try {
    audio = searchAudio(page, query, Date.now() + audioSearchTimeoutMs);
  } catch (error) {
    audioError = error;
  }
  let video = null;
  let videoError = null;
  try {
    video = searchVideo(page, keyword);
  } catch (error) {
    videoError = error;
  }
  if (video === null && audio === null) {
    throw videoError;
  }
  const warnings = [];
  if (video !== null && video.warning !== "") {
    warnings.push(video.warning);
  }
  if (videoError !== null) {
    warnings.push("红果短剧搜索暂不可用：" + message(videoError));
  }
  if (audioError !== null) {
    warnings.push("红果听书搜索暂不可用：" + message(audioError));
  }
  return {
    items: (video === null ? [] : video.items).concat(audio === null ? [] : audio.items),
    hasMore: (video !== null && video.hasMore) || (audio !== null && audio.hasMore),
    warning: warnings.join("；"),
  };
}

function suggestions(query) {
  const keyword = searchKeyword(query);
  const cached = cacheRead("suggest:" + keyword);
  if (cached !== null) {
    return cached;
  }
  const names = [];
  const seen = new Set();
  for (const item of fetchSuggestionRecords(keyword, suggestionLimit, Date.now() + suggestionTimeoutMs)) {
    let name;
    try {
      name = searchKeyword(typeof item.name === "string" ? item.name : "");
    } catch (error) {
      continue;
    }
    const key = name.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    names.push(name);
    if (names.length === suggestionLimit) {
      break;
    }
  }
  cacheWrite("suggest:" + keyword, names, 2 * minuteMs);
  return names;
}

function searchScore(dramaId, title) {
  let keyword;
  try {
    keyword = searchKeyword(title);
  } catch (error) {
    return "";
  }
  try {
    const page = fetchSearchPage(keyword, 1, Date.now() + searchPageTimeoutMs);
    const found = page.items.find((drama) => drama.id === dramaId);
    return found ? found.score : "";
  } catch (error) {
    return "";
  }
}

function seasonPackBody(ids, fields) {
  return '{"book_pack_channel":"inner_feed_detail","req_ids":[' + ids.join(",") + '],"req_fields":' + JSON.stringify(fields) + "}";
}

function seasonDrama(sourceId, deadline) {
  let entry;
  try {
    entry = appDetail(sourceId);
  } catch (error) {
    return null;
  }
  const drama = Object.assign({}, entry.drama);
  if (!drama.onlineDate && remainingMs(deadline) > 0) {
    try {
      drama.onlineDate = parseSortDetail(fetchSiteText(siteBaseUrl + "/detail?series_id=" + queryEscape(sourceId)), sourceId).onlineDate;
    } catch (error) {}
  }
  return drama;
}

function seasonPack(ids) {
  let result;
  try {
    result = appRequest("POST", paths.seriesPack, null, seasonPackBody(ids, [
      "series_id", "series_title", "series_cover", "series_intro", "episode_cnt", "series_status", "category_schema", "series_play_cnt", "publish_time",
    ]));
  } catch (error) {
    return {};
  }
  const dramas = {};
  for (const id of ids) {
    const row = nested(result, "data", id);
    const base = nested(row, "base_info");
    if (mapString(base, "series_id") !== id || mapString(base, "series_title") === "") {
      continue;
    }
    const fields = Object.assign({}, base, { series_play_cnt: nested(row, "stat_info").series_play_cnt });
    const drama = dramaFromRow(fields, "短剧");
    if (drama !== null) {
      drama.onlineDate = timestampDate(mapString(base, "publish_time"));
      dramas[id] = drama;
    }
  }
  return dramas;
}

function seasons(sourceId) {
  if (sourceId.startsWith(bookPrefix)) {
    return [];
  }
  if (!numericId(sourceId) || BigInt(sourceId) > 9223372036854775807n) {
    throw new Error("红果剧集 ID 无效");
  }
  const cached = cacheRead("seasons:" + sourceId);
  if (cached !== null) {
    return cached;
  }
  const deadline = Date.now() + seasonTimeoutMs;
  const result = appRequest("POST", paths.seriesPack, null, seasonPackBody([sourceId], [
    "album_id", "album_title", "album_serial_count", "series_in_album_order", "album_series_ids",
  ]), { deadline });
  const ids = [];
  for (const value of anyList(nested(result, "data", sourceId, "album_info").album_series_ids)) {
    const id = typeof value === "number" && Number.isInteger(value) ? String(value) : value;
    if (numericId(id)) {
      ids.push(id);
    }
  }
  if (ids.length < 2 || ids.length > seriesSeasonLimit) {
    return [];
  }
  const packed = seasonPack(ids);
  const found = [];
  ids.forEach((id, index) => {
    let drama = packed[id] || null;
    if (drama === null && remainingMs(deadline) > 0) {
      drama = seasonDrama(id, deadline);
    }
    if (drama !== null) {
      found.push({ number: index + 1, drama });
    }
  });
  if (found.length < 2) {
    return [];
  }
  if (found.length === ids.length) {
    for (const season of found) {
      cacheWrite("seasons:" + season.drama.sourceId, found, 30 * minuteMs);
    }
  }
  return found;
}

function recommendationError() {
  return new Error("推荐分类或分页参数无效，请重新获取");
}

function validateRecommendation(query) {
  const known = genres.some((genre) => genre.key === query.genre) || recommendationFeeds.some((feed) => feed.key === query.genre);
  if (!known || query.offset < 0 || query.offset > 1000000 || query.sessionId.length > 4096 || /[\r\n\x00]/.test(query.sessionId) || query.seen.length > 540 ||
    (query.cellId !== "" && !numericId(query.cellId)) || (query.showType !== "" && !numericId(query.showType))) {
    throw recommendationError();
  }
  for (const id of query.seen) {
    if (!numericId(id.replace(/^hongguo:/, ""))) {
      throw new Error("推荐分页含无效剧集 ID");
    }
  }
}

function recommendationQuery(genre, cursor, seen) {
  const query = { genre, offset: 0, sessionId: "", cellId: "", showType: "", seen: [] };
  if (cursor !== null && cursor !== undefined) {
    if (!isRecord(cursor)) {
      throw recommendationError();
    }
    query.genre = "";
    for (const key of ["genre", "sessionId", "cellId", "showType"]) {
      if (cursor[key] !== undefined && cursor[key] !== null) {
        if (typeof cursor[key] !== "string") {
          throw recommendationError();
        }
        query[key] = cursor[key];
      }
    }
    if (cursor.offset !== undefined && cursor.offset !== null) {
      if (!Number.isInteger(cursor.offset)) {
        throw recommendationError();
      }
      query.offset = cursor.offset;
    }
    if (cursor.seen !== undefined && cursor.seen !== null) {
      if (!Array.isArray(cursor.seen) || cursor.seen.some((id) => typeof id !== "string")) {
        throw recommendationError();
      }
      query.seen = cursor.seen;
    }
    if (query.genre !== genre) {
      throw recommendationError();
    }
  }
  if (Array.isArray(seen)) {
    query.seen = seen;
  }
  validateRecommendation(query);
  return query;
}

function validRecommendation(genre, cursor) {
  recommendationQuery(genre, cursor, null);
  return null;
}

function recommendations(genre, cursor, seen) {
  const query = recommendationQuery(genre, cursor, seen);
  const page = fetchRecommendations(query);
  return {
    items: page.items,
    cursor: { genre, offset: page.nextOffset, sessionId: page.sessionId || query.sessionId, cellId: page.cellId || "", showType: page.showType || "", seen: null },
    hasMore: page.hasMore,
  };
}

function fetchRecommendations(query) {
  const feed = recommendationFeeds.find((item) => item.key === query.genre);
  if (feed) {
    return feedRecommendations(query, feed.tabType, feed.bottomTab);
  }
  const genre = genres.find((item) => item.key === query.genre);
  const seen = new Set();
  const filterIds = [];
  for (const raw of query.seen) {
    const id = raw.replace(/^hongguo:/, "");
    if (!seen.has(id)) {
      filterIds.push(id);
      seen.add(id);
    }
  }
  const payload = catalogPayload(genre.scene, query.genre, query.offset, query.sessionId, [], filterIds.join(","));
  const result = appRequest("POST", paths.landpage, null, payload);
  const data = nested(result, "data");
  const rows = data.video_data;
  const hasMore = data.has_more;
  const next = parseInteger(mapString(data, "next_offset"));
  if (!Array.isArray(rows) || typeof hasMore !== "boolean" || (hasMore && Number.isNaN(next))) {
    throw new Error("红果推荐数据格式异常，已保留上次位置");
  }
  const items = [];
  let validRows = 0;
  for (const row of rows) {
    const drama = dramaFromRow(row, genre.name);
    if (drama === null) {
      continue;
    }
    validRows++;
    if (!seen.has(drama.sourceId)) {
      seen.add(drama.sourceId);
      items.push(drama);
    }
  }
  if (rows.length > 0 && validRows === 0) {
    throw new Error("红果推荐未返回可识别的剧集");
  }
  if (hasMore && (next <= query.offset || next > 1000000 || items.length === 0)) {
    throw new Error("红果推荐分页未前进，可重试或重新获取");
  }
  let nextOffset = Number.isNaN(next) ? 0 : next;
  if (!hasMore && (nextOffset < query.offset || nextOffset > 1000000)) {
    nextOffset = query.offset;
  }
  const sessionId = mapString(data, "session_id");
  if (sessionId.length > 4096 || /[\r\n\x00]/.test(sessionId)) {
    throw new Error("红果推荐分页标记无效");
  }
  return { items, nextOffset, hasMore, sessionId, cellId: "", showType: "" };
}

function fetchCellPage(page, tabType, offset, helper) {
  const extra = {
    cell_id: page.cellId, change_type: "0", offset: String(offset), limit: "10", session_id: page.sessionId,
    tab_type: tabType, client_req_type: "2", show_type: page.showType,
  };
  const result = appRequest("GET", paths.bookmallCellChange, extra, null, { helper });
  const data = nested(result, "data");
  const hasMore = data.has_more;
  const next = parseInteger(mapString(data, "next_offset"));
  if (typeof hasMore !== "boolean" || (hasMore && (Number.isNaN(next) || next <= offset))) {
    throw new Error("红果推荐数据格式异常，已保留上次位置");
  }
  return { cards: anyList(nested(data, "cell_view").cell_data), next, hasMore, session: mapString(data, "session_id") };
}

function feedRecommendations(query, tabType, bottomTab) {
  const seen = new Set(query.seen.map((id) => id.replace(/^hongguo:/, "")));
  const page = { items: [], nextOffset: query.offset, sessionId: query.sessionId, cellId: query.cellId, showType: query.showType, hasMore: true };
  let validRows = 0;
  for (let attempt = 0; attempt < 3 && page.items.length === 0 && page.hasMore; attempt++) {
    let cards = [];
    if (page.cellId !== "") {
      const helperOffset = page.nextOffset + cellPageSize;
      const before = Object.assign({}, page);
      const primary = fetchCellPage(before, tabType, before.nextOffset, false);
      cards = primary.cards;
      page.hasMore = primary.hasMore;
      page.sessionId = firstNonEmpty(primary.session, page.sessionId);
      if (primary.hasMore) {
        page.nextOffset = primary.next;
      }
      if (primary.hasMore && primary.next === helperOffset) {
        let helperPage = null;
        try {
          helperPage = fetchCellPage(before, tabType, helperOffset, true);
        } catch (error) {}
        if (helperPage !== null) {
          cards = cards.concat(helperPage.cards);
          page.hasMore = helperPage.hasMore;
          if (helperPage.hasMore) {
            page.nextOffset = helperPage.next;
          }
        }
      }
    } else {
      const extra = { tab_type: tabType, offset: String(page.nextOffset), client_req_type: "1" };
      if (bottomTab !== "") {
        extra.bottom_tab_type = bottomTab;
        extra.landing_bottom_tab_type = bottomTab;
      }
      if (page.sessionId !== "") {
        extra.session_id = page.sessionId;
        extra.client_req_type = "2";
      }
      const result = appRequest("GET", paths.bookmallTab, extra, null);
      let tab = null;
      for (const item of anyList(nested(result, "data").tab_item)) {
        if (mapString(item, "tab_type") === tabType) {
          tab = item;
        }
      }
      if (tab === null) {
        throw new Error("红果推荐数据格式异常，已保留上次位置");
      }
      if (page.sessionId === "") {
        page.sessionId = mapString(tab, "session_id");
      }
      page.nextOffset++;
      for (const cell of anyList(tab.cell_data)) {
        cards = cards.concat(anyList(isRecord(cell) ? cell.cell_data : null));
        const id = mapString(cell, "cell_id");
        const offset = parseInteger(mapString(cell, "next_offset"));
        if (offset > 0 && mapString(cell, "show_type") === doubleColumnShowType && numericId(id)) {
          page.cellId = id;
          page.showType = doubleColumnShowType;
          page.nextOffset = offset;
        }
      }
    }
    for (const card of cards) {
      for (const video of anyList(isRecord(card) ? card.video_data : null)) {
        const row = isRecord(video) && !isEmptyRecord(video.video_detail) ? video.video_detail : video;
        const drama = dramaFromRow(row, "");
        if (drama === null) {
          continue;
        }
        validRows++;
        if (!seen.has(drama.sourceId)) {
          seen.add(drama.sourceId);
          page.items.push(drama);
        }
      }
    }
  }
  if (page.sessionId.length > 4096 || /[\r\n\x00]/.test(page.sessionId)) {
    throw new Error("红果推荐分页标记无效");
  }
  if (!page.hasMore) {
    return page;
  }
  if (validRows === 0) {
    throw new Error("红果推荐未返回可识别的剧集");
  }
  if (page.items.length === 0 || page.nextOffset > 1000000) {
    throw new Error("红果推荐分页未前进，可重试或重新获取");
  }
  return page;
}

function danmakuIds(task) {
  const [source, seriesId] = splitDramaId(task.dramaId);
  const chapter = task.chapter || {};
  if (source !== host.source || chapter.source !== host.source || typeof chapter.videoUrl !== "string" || !chapter.videoUrl.startsWith(cencScheme)) {
    return null;
  }
  const videoId = chapter.videoUrl.slice(cencScheme.length);
  return numericId(seriesId) && numericId(videoId) ? { series: seriesId, video: videoId } : null;
}

function danmaku(seriesId, videoId, start, duration) {
  if (!numericId(seriesId) || !numericId(videoId) || start < 0 || duration <= start || duration > danmakuMaxDurationMs) {
    throw new Error("弹幕请求参数无效");
  }
  const key = "danmaku:" + seriesId + ":" + videoId + ":" + start + ":" + duration;
  const cached = cacheRead(key);
  if (cached !== null) {
    if (cached.error) {
      throw new Error(cached.error);
    }
    return cached.page;
  }
  const body = {
    comment_source: 601, server_channel: 1000, group_id: videoId, group_type: 30,
    comment_type: 20, sort: 1, count: 90, cursor: "", aid: 8662, compliance_status: 0,
    business_param: { book_id: seriesId, start_offset_time: start, playlet_item_duration: duration, need_danmaku_guide_type: [1, 3, 4, 2] },
  };
  let page;
  try {
    const result = appRequest("POST", "/novel/commentapi/comment/list/" + videoId + "/v1/", null, body, { comment: true, background: true });
    page = parseDanmaku(result, videoId, start, duration);
  } catch (error) {
    cacheWrite(key, { error: message(error) }, 15 * secondMs);
    throw error;
  }
  cacheWrite(key, { page }, 5 * minuteMs);
  return page;
}

function parseDanmaku(result, videoId, start, duration) {
  const data = nested(result, "data");
  const rows = data.data_list;
  const next = parseInteger(mapString(nested(data, "extra"), "next_query_danmaku_list_time"));
  if (!Array.isArray(rows) || Number.isNaN(next) || next <= start || next > danmakuMaxDurationMs) {
    throw new Error("红果弹幕时间段格式无效");
  }
  const page = { episodeId: videoId, items: [], startMs: start, nextMs: Math.min(next, duration), total: 0 };
  const rawCursor = mapString(nested(data, "common_list_info"), "cursor");
  if (rawCursor.length <= 8192) {
    try {
      const cursor = JSON.parse(rawCursor);
      if (isRecord(cursor) && Number.isInteger(cursor.danmaku_count) && cursor.danmaku_count >= 0) {
        page.total = cursor.danmaku_count;
      }
    } catch (error) {}
  }
  const seen = new Set();
  for (const row of rows) {
    const comment = nested(row, "comment");
    const common = nested(comment, "common");
    if (mapString(common, "group_id") !== videoId || mapString(common, "status") !== "1") {
      continue;
    }
    const position = parseInteger(mapString(nested(comment, "expand"), "offset_time"));
    let text = mapString(nested(common, "content"), "text").replace(/[\p{Cc}\u2028\u2029]/gu, " ").trim();
    const id = mapString(comment, "comment_id");
    if (Number.isNaN(position) || position < start || position >= page.nextMs || text === "" || id === "" || id.length > 120 || seen.has(id)) {
      continue;
    }
    const characters = Array.from(text);
    if (characters.length > 180) {
      text = characters.slice(0, 180).join("") + "…";
    }
    seen.add(id);
    page.items.push({ id, text, timeMs: position });
    if (page.items.length === 90) {
      break;
    }
  }
  page.items = stableSort(page.items, (left, right) => left.timeMs < right.timeMs);
  return page;
}

function devices(register) {
  if (register) {
    host.cacheSet("registerPause", null, 0);
    for (const helper of [false, true]) {
      ensureDevice(helper, "");
    }
  }
  const state = currentState();
  return deviceOf(state, false)[2] && deviceOf(state, true)[2];
}

function rankingIncomplete() {
  return failure("红果榜单数据尚未完整返回，请稍后重试", { incomplete: true });
}

function rankingFormat() {
  return new Error("红果榜单格式或分页已变化，请稍后重试");
}

function siteHost(parsed) {
  return parsed.host === "" || parsed.hostname === "hongguoduanju.com" || parsed.hostname === "www.hongguoduanju.com";
}

function rankingUrlPage(address, board) {
  const parsed = parseAddress(address);
  if (parsed === null || parsed.userInfo || parsed.path.replace(/\/+$/, "") !== "/rank/" + board.path || !siteHost(parsed)) {
    return 0;
  }
  const value = queryValue(parsed.query, "page");
  if (value === "") {
    return 1;
  }
  const page = parseInteger(value);
  return page >= 1 && page <= 500 ? page : 0;
}

function rankingDramaId(address) {
  const parsed = parseAddress(address);
  if (parsed === null || parsed.userInfo || parsed.path !== "/detail" || !siteHost(parsed)) {
    return "";
  }
  const id = queryValue(parsed.query, "series_id");
  return numericId(id) ? id : "";
}

function stringField(value) {
  return value === undefined || value === null ? "" : typeof value === "string" ? value : undefined;
}

function integerField(value) {
  return value === undefined || value === null ? 0 : Number.isInteger(value) ? value : undefined;
}

function rankingContent(value) {
  const empty = { success: false, rows: null, page: 0, totalPages: 0 };
  if (value === null || value === undefined) {
    return empty;
  }
  if (!isRecord(value)) {
    return null;
  }
  if (value.isSuccess !== undefined && value.isSuccess !== null && typeof value.isSuccess !== "boolean") {
    return null;
  }
  const content = { success: value.isSuccess === true, rows: null, page: 0, totalPages: 0 };
  if (value.rankList !== undefined && value.rankList !== null) {
    if (!Array.isArray(value.rankList)) {
      return null;
    }
    content.rows = [];
    for (const raw of value.rankList) {
      const row = raw === null ? {} : raw;
      if (!isRecord(row)) {
        return null;
      }
      const parsed = {
        id: stringField(row.id), seriesId: stringField(row.seriesId), rank: integerField(row.rank), title: stringField(row.title),
        heat: stringField(row.heatText), score: stringField(row.scoreText), description: stringField(row.description),
        episodeCount: integerField(row.episodeCount), cover: row.cover, tags: null,
      };
      if (Object.keys(parsed).some((key) => parsed[key] === undefined && key !== "cover")) {
        return null;
      }
      if (row.tags !== undefined && row.tags !== null) {
        if (!Array.isArray(row.tags) || row.tags.some((tag) => tag !== null && typeof tag !== "string")) {
          return null;
        }
        parsed.tags = row.tags.map((tag) => (tag === null ? "" : tag));
      }
      content.rows.push(parsed);
    }
  }
  if (value.pagination !== undefined && value.pagination !== null) {
    if (!isRecord(value.pagination)) {
      return null;
    }
    content.page = integerField(value.pagination.pageNum);
    content.totalPages = integerField(value.pagination.totalPages);
    if (content.page === undefined || content.totalPages === undefined) {
      return null;
    }
  }
  return content;
}

function scriptTags(body) {
  return body.match(/<script\b[^>]*>/gi) || [];
}

function parseMergeLoader(body, loaderKey) {
  for (const tag of scriptTags(body)) {
    if (extractAttr(tag, "data-fn-name") !== "mergeLoaderData" || extractAttr(tag, "data-script-src") !== "modern-run-window-fn") {
      continue;
    }
    let args;
    try {
      args = JSON.parse(extractAttr(tag, "data-fn-args"));
    } catch (error) {
      continue;
    }
    if (!Array.isArray(args) || args.length !== 2 || args[0] !== loaderKey || !Array.isArray(args[1]) || args[1].some((field) => field !== null && !isRecord(field))) {
      continue;
    }
    for (const field of args[1]) {
      if (!isRecord(field) || field.key !== "content" || field.routerDataFnName !== "p") {
        continue;
      }
      const fieldArgs = field.routerDataFnArgs;
      if (!Array.isArray(fieldArgs) || fieldArgs.length !== 1 || typeof fieldArgs[0] !== "string") {
        return { content: rankingContent(null), found: true };
      }
      let content;
      try {
        content = rankingContent(parseJson(fieldArgs[0]));
      } catch (error) {
        content = null;
      }
      return { content: content || rankingContent(null), found: true };
    }
  }
  return { content: null, found: false };
}

function parseRanking(body, board, page) {
  const loaderKey = "rank_" + board.path + "/page";
  const loader = nested(parseRouterData(body), "loaderData", loaderKey);
  if (!isEmptyRecord(loader) && (mapString(loader, "rankKey") !== board.upstreamKey || mapString(loader, "pageNum") !== String(page))) {
    throw rankingFormat();
  }
  let content = null;
  if (!isEmptyRecord(loader.content)) {
    content = rankingContent(loader.content);
    if (content === null) {
      throw rankingFormat();
    }
  } else {
    const merged = parseMergeLoader(body, loaderKey);
    if (merged.found) {
      content = merged.content;
    } else {
      for (const tag of scriptTags(body)) {
        if (extractAttr(tag, "data-fn-name") !== "r" || extractAttr(tag, "data-script-src") !== "modern-run-router-data-fn") {
          continue;
        }
        let args;
        try {
          args = parseJson(extractAttr(tag, "data-fn-args"));
        } catch (error) {
          continue;
        }
        if (!Array.isArray(args) || args.length !== 3 || args[0] !== loaderKey || args[1] !== "content") {
          continue;
        }
        content = rankingContent(args[2]);
        if (content === null) {
          throw rankingFormat();
        }
        break;
      }
    }
  }
  if (content === null || !content.success || content.rows === null) {
    return parseRankingDocument(body, board, page, loader);
  }
  if (content.page !== page || content.totalPages < page || content.totalPages > 500) {
    throw rankingFormat();
  }
  const result = { items: [], totalPages: content.totalPages, hasMore: page < content.totalPages, updatedText: mapString(loader, "updatedText") };
  const seen = new Set();
  let previous = (page - 1) * 20;
  for (const row of content.rows) {
    const id = firstNonEmpty(row.seriesId, row.id);
    if (!numericId(id) || (row.id !== "" && row.seriesId !== "" && row.id !== row.seriesId) || row.title.trim() === "" || row.rank <= previous || row.rank > page * 20 || seen.has(id)) {
      throw rankingFormat();
    }
    seen.add(id);
    previous = row.rank;
    const drama = {
      id: host.dramaId(id), source: host.source, sourceId: id, title: row.title, name: row.title, desc: row.description, intro: row.description,
      tags: row.tags, heat: row.heat, score: row.score.replace(/^评分/, ""), channelName: "红果",
    };
    const cover = coverAddress(coverPathFromAny(row.cover));
    if (cover !== "") {
      drama.cover = cover;
      drama.coverUrl = cover;
    }
    if (row.tags !== null && row.tags.length > 0) {
      drama.categoryName = row.tags[0];
    }
    if (row.episodeCount > 0) {
      drama.totalEpisode = row.episodeCount;
      drama.episodeCount = row.episodeCount;
    }
    result.items.push({ rank: row.rank, drama, metric: row.heat });
  }
  if (result.items.length === 0 && result.hasMore) {
    throw rankingFormat();
  }
  return result;
}

function htmlTree(body) {
  const root = host.parseHtml(body);
  const pending = [root];
  while (pending.length > 0) {
    const node = pending.pop();
    for (const child of node.children || []) {
      child.parent = node;
      pending.push(child);
    }
  }
  return root;
}

function htmlNodes(root, match) {
  const found = [];
  const pending = [root];
  while (pending.length > 0) {
    const node = pending.pop();
    if (match(node)) {
      found.push(node);
    }
    const children = node.children || [];
    for (let index = children.length - 1; index >= 0; index--) {
      pending.push(children[index]);
    }
  }
  return found;
}

function isTextNode(node) {
  return node.tag === undefined && typeof node.text === "string";
}

function htmlAttr(node, name) {
  return node && node.attrs && typeof node.attrs[name] === "string" ? node.attrs[name] : "";
}

function htmlText(root) {
  const parts = [];
  for (const node of htmlNodes(root, isTextNode)) {
    if (node.parent && (node.parent.tag === "script" || node.parent.tag === "style")) {
      continue;
    }
    parts.push(node.text);
  }
  return parts.join(" ").split(/\s+/).filter((part) => part !== "").join(" ");
}

function rankingJsonLd(body, board, page) {
  const pattern = /<script\b[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let match;
  while ((match = pattern.exec(body)) !== null) {
    let value;
    try {
      value = JSON.parse(match[1]);
    } catch (error) {
      continue;
    }
    if (!isRecord(value) || value["@type"] !== "ItemList" || typeof value.url !== "string" || !Array.isArray(value.itemListElement)) {
      continue;
    }
    const rows = value.itemListElement;
    if (rows.some((row) => !isRecord(row) || integerField(row.position) === undefined || stringField(row.name) === undefined || stringField(row.url) === undefined)) {
      continue;
    }
    if (rankingUrlPage(value.url, board) !== page || rows.length === 0 || rows.length > 20) {
      continue;
    }
    return rows.map((row) => {
      const id = rankingDramaId(stringField(row.url));
      const title = stringField(row.name).trim();
      return { rank: integerField(row.position), drama: { id: host.dramaId(id), source: host.source, sourceId: id, title, name: title, channelName: "红果" } };
    });
  }
  return null;
}

function rankingArticle(article) {
  const label = htmlAttr(article, "aria-labelledby");
  const id = label.slice("rank-title-".length);
  if (!numericId(id)) {
    return null;
  }
  const headings = htmlNodes(article, (node) => (node.tag === "h2" || node.tag === "h3") && htmlAttr(node, "id") === label);
  if (headings.length !== 1 || !headings[0].parent || rankingDramaId(htmlAttr(headings[0].parent, "href")) !== id) {
    return null;
  }
  const title = htmlText(headings[0]);
  if (title === "" || runeCount(title) > 200) {
    return null;
  }
  const drama = { id: host.dramaId(id), source: host.source, sourceId: id, title, name: title, channelName: "红果" };
  let rank = 0;
  for (const link of htmlNodes(article, (node) => node.tag === "a" && htmlAttr(node, "aria-label").startsWith("查看"))) {
    if (rankingDramaId(htmlAttr(link, "href")) !== id) {
      return null;
    }
    const value = parseInteger(htmlText(link));
    if (value > 0 && (rank === 0 || rank === value)) {
      rank = value;
    }
    for (const image of htmlNodes(link, (node) => node.tag === "img")) {
      const cover = coverAddress(htmlAttr(image, "src"));
      if (cover !== "") {
        drama.cover = cover;
        drama.coverUrl = cover;
        break;
      }
    }
  }
  for (const node of htmlNodes(article, isTextNode)) {
    const text = node.text.trim();
    if (rankingMetricPattern.test(text)) {
      drama.heat = text;
    }
    if (text.startsWith("评分")) {
      drama.score = text.slice(2).trim();
    }
  }
  for (const paragraph of htmlNodes(article, (node) => node.tag === "p")) {
    const children = paragraph.children || [];
    const tags = [];
    for (const child of children) {
      if (child.tag === "span" && child.children && child.children.length === 1 && isTextNode(child.children[0])) {
        const value = htmlText(child);
        if (value !== "" && runeCount(value) <= 20 && !value.includes("热度")) {
          tags.push(value);
        }
      }
    }
    if (tags.length > 0) {
      drama.tags = tags;
      drama.categoryName = tags[0];
    } else if (children.length === 1 && isTextNode(children[0])) {
      drama.desc = htmlText(paragraph);
      drama.intro = drama.desc;
    }
  }
  return rank > 0 ? { rank, drama, metric: drama.heat || "" } : null;
}

function parseRankingDocument(body, board, page, loader) {
  if (body.length > 4 * 1024 * 1024) {
    throw rankingFormat();
  }
  let document;
  try {
    document = htmlTree(body);
  } catch (error) {
    throw rankingIncomplete();
  }
  let identified = !isEmptyRecord(loader);
  for (const node of htmlNodes(document, (item) => item.tag === "link" && htmlAttr(item, "rel") === "canonical")) {
    if (rankingUrlPage(htmlAttr(node, "href"), board) !== page) {
      throw rankingFormat();
    }
    identified = true;
  }
  if (!identified) {
    throw rankingIncomplete();
  }
  const pagination = htmlNodes(document, (node) => node.tag === "nav" && htmlAttr(node, "aria-label") === "榜单分页");
  if (pagination.length !== 1) {
    throw rankingIncomplete();
  }
  const current = htmlNodes(pagination[0], (node) => htmlAttr(node, "aria-current") === "page");
  if (current.length !== 1 || htmlText(current[0]) !== String(page)) {
    throw rankingFormat();
  }
  const result = { items: [], hasMore: false, totalPages: 0, updatedText: mapString(loader, "updatedText") };
  let maximumPage = page;
  for (const link of htmlNodes(pagination[0], (node) => node.tag === "a")) {
    const actual = rankingUrlPage(htmlAttr(link, "href"), board);
    if (actual === 0) {
      throw rankingFormat();
    }
    maximumPage = Math.max(maximumPage, actual);
    if (htmlAttr(link, "rel") === "next") {
      if (actual !== page + 1) {
        throw rankingFormat();
      }
      result.hasMore = true;
    }
  }
  if (!result.hasMore) {
    if (maximumPage !== page) {
      throw rankingFormat();
    }
    result.totalPages = page;
  }
  const linked = rankingJsonLd(body, board, page);
  if (linked !== null) {
    result.items = linked;
  } else {
    for (const list of htmlNodes(document, (node) => node.tag === "ol" && htmlAttr(node, "aria-label") !== "")) {
      const articles = htmlNodes(list, (node) => node.tag === "article" && htmlAttr(node, "aria-labelledby").startsWith("rank-title-"));
      if (articles.length === 0) {
        continue;
      }
      if (result.items.length !== 0 || articles.length > 20) {
        throw rankingFormat();
      }
      for (const article of articles) {
        const item = rankingArticle(article);
        if (item === null) {
          throw rankingIncomplete();
        }
        result.items.push(item);
      }
    }
  }
  if (result.items.length === 0) {
    throw rankingIncomplete();
  }
  const seen = new Set();
  let previous = (page - 1) * 20;
  for (const item of result.items) {
    if (!numericId(item.drama.sourceId) || item.drama.title === "" || item.rank <= previous || item.rank > page * 20 || seen.has(item.drama.sourceId)) {
      throw rankingFormat();
    }
    seen.add(item.drama.sourceId);
    previous = item.rank;
  }
  if (result.hasMore && result.items.length !== 20) {
    throw rankingIncomplete();
  }
  return result;
}

function rankingPage(boardId, page) {
  const board = rankingBoards[boardId];
  if (!board) {
    throw new Error("未知的红果榜单");
  }
  const deadline = Date.now() + rankingTimeoutMs;
  let lastError = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) {
      const wait = attempt * attempt * 300;
      if (remainingMs(deadline) <= wait) {
        throw lastError;
      }
      host.sleep(wait);
    }
    const address = siteBaseUrl + "/rank/" + board.path + (page > 1 ? "?page=" + page : "");
    const body = fetchSiteText(address, attempt > 0);
    try {
      return parseRanking(body, board, page);
    } catch (error) {
      if (!error.incomplete) {
        throw error;
      }
      lastError = error;
    }
  }
  throw lastError;
}

function parseSortDetail(body, id) {
  const row = nested(routerLoaderMap(parseRouterData(body), "detail_page", "detail_"), "seriesDetail");
  if (mapString(row, "series_id", "series_id_str") !== id || mapString(row, "series_name", "series_title") === "") {
    throw new Error("红果网页详情与请求剧集不符");
  }
  const patch = dramaFromRow(row, "") || {};
  patch.title = mapString(row, "series_name", "series_title");
  patch.name = patch.title;
  patch.onlineDate = timestampDate(mapString(row, "first_visible_time"));
  const cover = coverAddress(mapString(row, "series_cover", "cover"));
  if (cover !== "") {
    patch.cover = cover;
    patch.coverUrl = cover;
  }
  return patch;
}

function coverAddressFor(drama, id) {
  if (!numericId(id)) {
    throw new Error("无效的红果剧集 ID");
  }
  const result = appRequest("POST", paths.videoDetail, null, { series_id: id });
  const row = nested(result, "data", "video_data");
  if (mapString(row, "series_id_str", "series_id") !== id) {
    throw new Error("红果详情与请求剧集不符");
  }
  return coverAddress(mapString(row, "series_cover", "cover"));
}

function needsExtraMetadata(drama) {
  if (String(drama.sourceId || "").startsWith(bookPrefix)) {
    return false;
  }
  return !drama.onlineDate || !drama.score;
}

function extraMetadata(drama, id) {
  if (!numericId(id)) {
    throw new Error("红果剧集 ID 无效");
  }
  let patch = null;
  if (!drama.onlineDate) {
    const raw = parseSortDetail(fetchSiteText(siteBaseUrl + "/detail?series_id=" + queryEscape(id)), id);
    if (raw.id === drama.id) {
      patch = raw;
    }
  }
  if (!drama.score && !(patch !== null && nativeScore(patch.score) !== "")) {
    const score = searchScore(drama.id, drama.title);
    if (score !== "") {
      patch = patch || { id: drama.id };
      patch.score = score;
    }
  }
  return patch;
}

function catalogState() {
  return currentState();
}

function restoredCursor(raw) {
  if (!isRecord(raw)) {
    return null;
  }
  const cursor = emptyCursor();
  for (const key of ["sessionId", "lastId", "pageSignature", "updatedAt"]) {
    if (raw[key] !== undefined && raw[key] !== null) {
      if (typeof raw[key] !== "string") {
        return null;
      }
      cursor[key] = raw[key];
    }
  }
  for (const key of ["initialized", "exhausted"]) {
    if (raw[key] !== undefined && raw[key] !== null) {
      if (typeof raw[key] !== "boolean") {
        return null;
      }
      cursor[key] = raw[key];
    }
  }
  if (raw.offset !== undefined && raw.offset !== null) {
    if (!Number.isInteger(raw.offset)) {
      return null;
    }
    cursor.offset = raw.offset;
  }
  return cursor;
}

function restoreCatalogState(raw) {
  if (!isRecord(raw) || raw.version !== 1 || !numericId(raw.deviceId) || !numericId(raw.installId)) {
    return null;
  }
  const state = {
    version: 1, deviceId: raw.deviceId, installId: raw.installId, registered: raw.registered === true,
    helperDeviceId: typeof raw.helperDeviceId === "string" ? raw.helperDeviceId : "",
    helperInstallId: typeof raw.helperInstallId === "string" ? raw.helperInstallId : "",
    helperRegistered: raw.helperRegistered === true, feeds: {},
  };
  if (!numericId(state.helperDeviceId) || !numericId(state.helperInstallId)) {
    state.helperDeviceId = newDeviceId();
    state.helperInstallId = newDeviceId();
    state.helperRegistered = false;
  }
  for (const name of Object.keys(isRecord(raw.feeds) ? raw.feeds : {})) {
    const known = genres.some((genre) => name === genre.key || name === "category:" + genre.key);
    const cursor = restoredCursor(raw.feeds[name]);
    if (!known || cursor === null || !cursor.initialized || cursor.offset < 0 || cursor.offset > 1000000 || cursor.sessionId.length > 4096 ||
      cursor.lastId.length > 256 || cursor.pageSignature.length > 64) {
      continue;
    }
    state.feeds[name] = cursor;
  }
  host.exclusive(() => {
    const current = readState();
    if (current === null || Object.keys(current.feeds || {}).length === 0) {
      writeState(state);
    }
  });
  return null;
}

function audioTab(category) {
  const found = audioCategories.find((item) => item.key === category);
  return found ? found.tab : audioCategories[0].tab;
}

function audioBooks(value) {
  const books = [];
  const walk = (node, depth) => {
    if (depth > 8) {
      return;
    }
    if (Array.isArray(node)) {
      node.forEach((item) => walk(item, depth + 1));
    } else if (isRecord(node)) {
      if (Array.isArray(node.book_data)) {
        books.push(...node.book_data.filter(isRecord));
      }
      for (const key of Object.keys(node)) {
        if (key !== "book_data" && (Array.isArray(node[key]) || isRecord(node[key]))) {
          walk(node[key], depth + 1);
        }
      }
    }
  };
  walk(value, 0);
  return books;
}

function audioDrama(book, category) {
  const bookId = mapString(book, "book_id", "bookId");
  if (!numericId(bookId)) {
    return null;
  }
  const sourceId = bookPrefix + bookId;
  const title = mapString(book, "book_name", "bookName", "original_book_name") || bookId;
  const cover = firstNonEmpty(mapString(book, "audio_thumb_url_hd", "audio_thumb_url"), mapString(book, "thumb_url", "horiz_thumb_url"));
  const intro = mapString(book, "abstract", "book_abstract");
  const genre = mapString(book, "category", "genre_name");
  const count = mapString(book, "chapter_number", "serial_count", "chapterNumber");
  const tags = [];
  const kind = mapString(book, "genre");
  if (kind === "4") {
    tags.push("真人录音");
  } else if (kind === "0" || kind === "6") {
    tags.push("AI 朗读");
  }
  tags.push(...mapStringList(book, "tags"));
  return {
    id: host.dramaId(sourceId), source: host.source, sourceId, title, name: title, desc: intro, intro,
    cover, coverUrl: cover, categoryName: firstNonEmpty(genre, category), channelName: "红果听书",
    remark: count !== "" ? "共" + count + "章" : "", totalEpisode: count, episodeCount: count, tags,
  };
}

function audioFeed(tab, first) {
  const extra = { tab_type: tab, offset: "0", client_req_type: first ? "1" : "2" };
  const result = appRequest("GET", paths.bookmallTab, extra, null);
  for (const item of anyList(nested(result, "data").tab_item)) {
    if (mapString(item, "tab_type") === tab) {
      return audioBooks(item);
    }
  }
  throw new Error("红果听书频道数据格式异常");
}

function audioCatalogPage(page, category) {
  page = Math.max(page, 1);
  const attempts = page > 1 ? 3 : 1;
  const items = [];
  const seen = new Set();
  for (let attempt = 0; attempt < attempts && items.length === 0; attempt++) {
    for (const book of audioFeed(audioTab(category), page === 1)) {
      const drama = audioDrama(book, "听书");
      if (drama === null || seen.has(drama.id) || (page > 1 && host.isKnown(drama.id))) {
        continue;
      }
      seen.add(drama.id);
      items.push(drama);
    }
  }
  return { items, hasMore: items.length > 0 && page < 200 };
}

function searchAudio(page, query, deadline) {
  const offset = String((page - 1) * audioSearchSize);
  const extra = { query, offset, count: String(audioSearchSize), tab_type: audioSearchTab };
  if (page > 1) {
    extra.passback = offset;
    const searchId = host.cacheGet("audioSearchId:" + query);
    if (searchId !== null) {
      extra.search_id = searchId;
    }
  }
  const result = appRequest("GET", paths.audioSearch, extra, null, { deadline });
  let tab = null;
  for (const item of anyList(result.search_tabs)) {
    if (mapString(item, "tab_type") === audioSearchTab) {
      tab = item;
    }
  }
  if (tab === null) {
    throw new Error("红果听书搜索未返回有效结果");
  }
  const searchId = mapString(tab, "search_id");
  if (page === 1 && searchId !== "") {
    host.cacheSet("audioSearchId:" + query, searchId, 30 * minuteMs);
  }
  const items = [];
  const seen = new Set();
  for (const cell of anyList(tab.data)) {
    for (const book of anyList(isRecord(cell) ? cell.book_data : null)) {
      const drama = audioDrama(book, "听书");
      if (drama !== null && !seen.has(drama.sourceId)) {
        seen.add(drama.sourceId);
        items.push(drama);
      }
    }
  }
  return { items, hasMore: tab.has_more === true };
}

function audioTone(bookId) {
  const result = appRequest("GET", paths.audioTone, { book_id: bookId }, null);
  for (const item of anyList(nested(result, "data").tts_tones)) {
    const id = parseInteger(mapString(item, "id", "tone_id"));
    if (id > 0) {
      return id;
    }
  }
  return 0;
}

function audioEntry(bookId) {
  if (!numericId(bookId)) {
    throw new Error("红果听书 ID 无效");
  }
  const cached = cacheRead("book:" + bookId);
  if (cached !== null) {
    return cached;
  }
  const result = appRequest("GET", paths.audioDetail, { book_id: bookId }, null);
  const detailData = nested(result, "data");
  if (mapString(detailData, "book_id") !== bookId) {
    throw new Error("红果听书未返回所请求的书籍");
  }
  const drama = audioDrama(detailData, "听书");
  if (drama === null) {
    throw new Error("红果听书详情无效");
  }
  const directory = appRequest("GET", paths.audioDirectory, { book_id: bookId }, null);
  let items = anyList(nested(directory, "data").item_data_list);
  if (items.length === 0) {
    items = anyList(nested(directory, "data").item_list);
  }
  const chapters = [];
  items.forEach((item, index) => {
    const itemId = mapString(item, "item_id", "chapter_id");
    if (!numericId(itemId)) {
      return;
    }
    chapters.push({
      id: host.chapterId(drama.sourceId, itemId), source: host.source, title: mapString(item, "title") || "第" + (index + 1) + "章",
      videoUrl: audioScheme + itemId, currentEpisode: index + 1,
    });
  });
  if (chapters.length === 0) {
    throw new Error("红果听书未返回章节");
  }
  if (drama.totalEpisode === "") {
    drama.totalEpisode = chapters.length;
    drama.episodeCount = chapters.length;
  }
  let tone = 0;
  try {
    tone = audioTone(bookId);
  } catch (error) {}
  const entry = { drama, chapters, tone };
  cacheWrite("book:" + bookId, entry, 5 * minuteMs);
  return entry;
}

function audioDetail(bookId) {
  const entry = audioEntry(bookId);
  return { drama: entry.drama, chapters: entry.chapters };
}

function resolveAudioMedia(task) {
  const [source, sourceId] = splitDramaId(task.dramaId);
  const bookId = sourceId.startsWith(bookPrefix) ? sourceId.slice(bookPrefix.length) : "";
  if (source !== host.source || !numericId(bookId)) {
    throw new Error("红果听书任务无效");
  }
  const chapterId = task.chapter.videoUrl.slice(audioScheme.length);
  if (!numericId(chapterId)) {
    throw new Error("红果听书章节无效");
  }
  const cached = cacheRead("book:" + bookId);
  let tone = cached !== null ? cached.tone : 0;
  if (cached === null) {
    try {
      tone = audioTone(bookId);
    } catch (error) {}
  }
  const extra = { book_id: bookId, item_ids: chapterId, req_type: "0" };
  if (tone > 0) {
    extra.tone_id = String(tone);
  }
  const result = appRequest("GET", paths.audioPlayInfo, extra, null);
  for (const item of anyList(result.data)) {
    const address = mapString(item, "main_url", "backup_url");
    if (address === "") {
      continue;
    }
    const seconds = parseNumber(mapString(item, "duration"));
    const media = { url: address, referer: mediaReferer, durationMs: seconds > 0 ? Math.trunc(seconds * secondMs) : 0 };
    const keyText = mapString(item, "encryption_key");
    if (keyText !== "" || mapString(item, "is_encrypt") === "true") {
      media.cencKey = contentKey(keyText);
    }
    return media;
  }
  throw new Error("红果听书未返回播放地址");
}

module.exports = {
  categories,
  validCategory,
  catalogPage,
  search,
  detail,
  resolveMedia,
  suggestions,
  validRecommendation,
  recommendations,
  danmakuIds,
  danmaku,
  devices,
  rankingPage,
  seasons,
  coverAddress: coverAddressFor,
  needsExtraMetadata,
  extraMetadata,
  catalogState,
  restoreCatalogState,
};
