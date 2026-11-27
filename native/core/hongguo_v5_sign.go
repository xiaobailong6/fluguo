// SPDX-License-Identifier: GPL-3.0-only
// Adapted from guoapp-modules/hongguo 49bf731d49c8506f946a28d2d4efc2442c14c67e.
// Device envelope updated from N3urda/hongguoTV 615b0c5b5e3fc5202512da6c279ba4498736bbea.
package core

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math"
	"math/bits"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const hongguoPlaybackBaseURL = "https://api5-normal-sinfonlinea.fqnovel.com"

// Medusa 字段 21 使用 zigzag 编码（312 -> 624），随完整设备信封一起对齐。
// 单改旧值 377 不足以修复本项目的空响应；字段的 SDK 内部含义未知。
const hongguoV5Field21 int64 = 312

var hongguoPlaybackUserAgent = "com.phoenix.read/" + hongguoAppVersionCodeText + " (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)"

func hongguoPlaybackQuery(deviceID, installID string) url.Values {
	return url.Values{
		"aid": {"8662"}, "app_name": {"novelread"}, "version_code": {hongguoAppVersionCodeText}, "version_name": {hongguoAppVersionName},
		"channel": {"vivo_8662_64"}, "device_platform": {"android"}, "device_type": {"PGT-AN10"}, "os_version": {"12"},
		"update_version_code": {hongguoAppVersionCodeText}, "iid": {installID}, "cdid": {uuidLike()}, "device_id": {deviceID},
	}
}

type hongguoV5Session struct {
	nonce   string
	started int64
}

var hongguoV5Process struct {
	sync.Mutex
	session hongguoV5Session
}

func signHongguoV5Request(request *http.Request, body []byte, now time.Time) error {
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return errors.New("无法准备红果 v5 播放签名")
	}
	hongguoV5Process.Lock()
	if hongguoV5Process.session.nonce == "" {
		var nonce [18]byte
		if _, err := rand.Read(nonce[:]); err != nil {
			hongguoV5Process.Unlock()
			return errors.New("无法准备红果 v5 进程标识")
		}
		hongguoV5Process.session = hongguoV5Session{base64.RawURLEncoding.EncodeToString(nonce[:]), now.UnixMilli()}
	}
	session := hongguoV5Process.session
	hongguoV5Process.Unlock()
	return hongguoV5Sign(request, body, now, session, random)
}

// 签名与实际发送的 query 共用同一份字节；只推进毫秒 ticket，不推进秒时间戳。
// 即使 ticket 搜索跨秒，Khronos/Medusa/Helios 仍使用开始签名时的秒数。
func hongguoV5Sign(request *http.Request, body []byte, now time.Time, session hongguoV5Session, random [16]byte) error {
	params := request.URL.Query()
	for _, name := range []string{"device_id", "version_name", "os_version", "device_type", "channel"} {
		if params.Get(name) == "" {
			return errors.New("红果 v5 播放签名缺少设备字段：" + name)
		}
	}
	stamp := uint32(now.Unix())
	var bodyHash [16]byte
	if body != nil {
		bodyHash = md5.Sum(body)
	}
	for offset := int64(0); offset < 1024; offset++ {
		if err := request.Context().Err(); err != nil {
			return err
		}
		params.Set("_rticket", strconv.FormatInt(now.UnixMilli()+offset, 10))
		query := params.Encode()
		queryHash := hongguoSM3([]byte(query))
		if hongguoV5IV(queryHash[:], bodyHash[:], stamp)&15 != 12 {
			continue
		}
		f13, err := hongguoV5Hash(queryHash[:], bodyHash[:], stamp)
		if err != nil {
			return err
		}
		medusa, err := hongguoV5Medusa(queryHash[:], f13, stamp, now.UnixMilli(), params, session, random[4:])
		if err != nil {
			return err
		}
		request.URL.RawQuery = query
		request.Header.Set("X-Khronos", strconv.FormatUint(uint64(stamp), 10))
		request.Header.Set("X-Helios", hongguoV5Helios(stamp, random[:4]))
		request.Header.Set("X-Medusa", medusa)
		if body != nil {
			request.Header.Set("X-SS-STUB", strings.ToUpper(hex.EncodeToString(bodyHash[:])))
			request.Header.Set("Content-Type", "application/json; charset=utf-8")
		}
		return nil
	}
	return errors.New("无法在 1024 次 ticket 尝试内生成红果 v5 播放签名")
}

// v5 的数值字段使用 zigzag；旧 Argus 的 protobuf 编码不能直接复用。
type hongguoV5Field struct {
	tag   uint64
	value any
}

func hongguoV5Proto(fields ...hongguoV5Field) []byte {
	var out []byte
	for _, field := range fields {
		var data []byte
		switch value := field.value.(type) {
		case int64:
			out = binary.AppendUvarint(out, field.tag*8)
			out = binary.AppendUvarint(out, uint64(value<<1)^uint64(value>>63))
			continue
		case float32:
			out = binary.AppendUvarint(out, field.tag*8+5)
			out = binary.LittleEndian.AppendUint32(out, math.Float32bits(value))
			continue
		case string:
			data = []byte(value)
		case []byte:
			data = value
		default:
			panic("invalid internal hongguo v5 field")
		}
		if len(data) == 0 {
			continue
		}
		out = binary.AppendUvarint(out, field.tag*8+2)
		out = binary.AppendUvarint(out, uint64(len(data)))
		out = append(out, data...)
	}
	return out
}

func hongguoV5Xmxor(data, key []byte) []byte {
	encoded := make([]byte, len(data))
	for i, value := range data {
		at := (i * 4) & 28
		d0, d1 := key[at], key[at+1]
		mixed := bits.RotateLeft8(value, 4) + d0
		mixed = ^mixed ^ d1
		mixed = bits.RotateLeft8(mixed, 3) + d1
		encoded[len(data)-i-1] = ^(mixed ^ d0)
	}
	lastIndex := len(encoded) - 1
	last, first := encoded[lastIndex]^encoded[lastIndex-1], encoded[0]
	encoded[0] = ^last + first
	encoded[1] += encoded[0] ^ encoded[lastIndex] ^ 254
	encoded[2] += (last - first) ^ bits.RotateLeft8(encoded[1], 3) ^ 2
	for i := 0; i < len(encoded)-4; i++ {
		mixed := bits.RotateLeft8(encoded[i+2], 3) ^ encoded[i+1] ^ byte(i+3)
		encoded[i+3] += ^mixed
	}
	encoded[lastIndex] ^= encoded[lastIndex-1]
	var sum byte
	for _, b := range encoded[1:] {
		sum += b
	}
	encoded[0] = (encoded[0] ^ encoded[1]) + sum
	return encoded
}

func hongguoV5Helios(stamp uint32, prefix []byte) string {
	hash := md5.Sum(append(append([]byte(nil), prefix...), "8662"...))
	ascii := []byte(hex.EncodeToString(hash[:]))
	left, right := binary.LittleEndian.Uint64(ascii), binary.LittleEndian.Uint64(ascii[8:])
	queue := []uint64{binary.LittleEndian.Uint64(ascii[16:]), binary.LittleEndian.Uint64(ascii[24:])}
	var keys [34]uint64
	for i := range keys {
		keys[i] = left
		mixed := (bits.RotateLeft64(right, -8) + left) ^ uint64(i)
		queue = append(queue, mixed)
		left = mixed ^ bits.RotateLeft64(left, 3)
		right, queue = queue[0], queue[1:]
	}
	data := hongguoCommentPad([]byte(strconv.FormatUint(uint64(stamp), 10) + "-646637794-8662"))
	for offset := 0; offset < len(data); offset += 16 {
		a, b := binary.LittleEndian.Uint64(data[offset:]), binary.LittleEndian.Uint64(data[offset+8:])
		for _, key := range keys {
			b = key ^ (a + bits.RotateLeft64(b, -8))
			a = b ^ bits.RotateLeft64(a, 3)
		}
		binary.LittleEndian.PutUint64(data[offset:], a)
		binary.LittleEndian.PutUint64(data[offset+8:], b)
	}
	return base64.StdEncoding.EncodeToString(append(append([]byte(nil), prefix...), data...))
}

func hongguoV5Medusa(queryHash, f13 []byte, stamp uint32, nowMillis int64, who url.Values, session hongguoV5Session, random []byte) (string, error) {
	// 进程令牌在外层和设备信息中一致；显式保留负值、fixed32 零值及毫秒时间。
	// 缺字段的旧信封仍能本地生成签名，却被播放服务以 HTTP 200 空正文拒绝。
	flags := []byte{0x44, 0x80, 0, 0, 0, 0, 0, 0}
	token := "A" + session.nonce
	brand := who.Get("device_brand")
	if brand == "" {
		brand = "HONOR"
	}
	device := hongguoV5Proto(
		hongguoV5Field{1, int64(1)}, hongguoV5Field{2, int64(2)}, hongguoV5Field{3, "8662"}, hongguoV5Field{4, who.Get("device_id")}, hongguoV5Field{5, token},
		hongguoV5Field{6, "!noperm!"}, hongguoV5Field{7, int64(-888888)}, hongguoV5Field{8, int64(-888888)}, hongguoV5Field{9, int64(3)}, hongguoV5Field{10, int64(-888888)},
		hongguoV5Field{11, "!notset!"}, hongguoV5Field{12, "Asia/Shanghai,8"}, hongguoV5Field{13, "zh_CN"}, hongguoV5Field{14, int64(4)},
		hongguoV5Field{16, float32(0)}, hongguoV5Field{17, float32(0)}, hongguoV5Field{18, float32(0)}, hongguoV5Field{19, float32(0)}, hongguoV5Field{20, float32(0)}, hongguoV5Field{21, float32(0)},
		hongguoV5Field{22, who.Get("os_version")}, hongguoV5Field{23, int64(41)}, hongguoV5Field{24, int64(36)},
		hongguoV5Field{25, session.started}, hongguoV5Field{26, session.started}, hongguoV5Field{27, session.started}, hongguoV5Field{28, nowMillis},
		hongguoV5Field{29, int64(-1)}, hongguoV5Field{30, who.Get("device_type")}, hongguoV5Field{31, brand}, hongguoV5Field{32, who.Get("device_type")}, hongguoV5Field{33, who.Get("device_type")},
		hongguoV5Field{34, brand}, hongguoV5Field{35, brand}, hongguoV5Field{36, brand}, hongguoV5Field{38, int64(31)})
	env := hongguoV5Proto(
		hongguoV5Field{1, int64(100) + int64(random[0])%21}, hongguoV5Field{2, int64(247235599)}, hongguoV5Field{3, int64(247235596)},
		hongguoV5Field{5, int64(7)}, hongguoV5Field{6, "v04.10.03.04-bugfix"}, hongguoV5Field{7, int64(10001) + int64(binary.LittleEndian.Uint16(random[2:4]))%2000},
		hongguoV5Field{8, who.Get("channel")}, hongguoV5Field{12, device},
		hongguoV5Field{13, hongguoV5Proto(hongguoV5Field{1, int64(stamp)}, hongguoV5Field{2, int64(-2)}, hongguoV5Field{4, int64(200)})}, hongguoV5Field{14, who.Get("version_name")})
	message := hongguoV5Proto(
		hongguoV5Field{1, hongguoV5Magic}, hongguoV5Field{2, int64(5)}, hongguoV5Field{3, int64(binary.LittleEndian.Uint32(random))}, hongguoV5Field{4, "8662"},
		hongguoV5Field{5, who.Get("device_id")}, hongguoV5Field{6, "646637794"}, hongguoV5Field{7, who.Get("version_name")}, hongguoV5Field{8, "v04.10.03-ml-android"},
		hongguoV5Field{9, int64(0x040a0300)}, hongguoV5Field{10, flags}, hongguoV5Field{12, int64(stamp)}, hongguoV5Field{13, f13}, hongguoV5Field{14, queryHash[:6]},
		hongguoV5Field{15, hongguoV5Proto(hongguoV5Field{1, int64(305)}, hongguoV5Field{2, int64(4)}, hongguoV5Field{3, int64(694367)}, hongguoV5Field{5, int64(1621072674)})}, hongguoV5Field{16, token},
		hongguoV5Field{17, int64(stamp)}, hongguoV5Field{20, "none"}, hongguoV5Field{21, hongguoV5Field21}, hongguoV5Field{23, env},
		hongguoV5Field{24, `{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}`})
	nonce := binary.LittleEndian.Uint32(random[4:])
	hash := hongguoSM3(append(append(append([]byte(nil), hongguoV5SignKey...), hongguoV5LE32(nonce)...), hongguoV5SignKey...))
	high := (nonce >> 16) & 255
	seed := hongguoV5LE32(^(((high << 11) | (nonce >> 24)) ^ (high >> 5) ^ high))
	transformed := append(flags, hongguoV5Xmxor(message, hash[:])...)
	for l, r := 0, len(transformed)-1; l < r; l, r = l+1, r-1 {
		transformed[l], transformed[r] = transformed[r], transformed[l]
	}
	for i := range transformed {
		transformed[i] ^= seed[(^i)&3]
	}
	check := uint32(0x18000001) | uint32(queryHash[0]&63)<<14 | uint32(f13[0]&63)<<8
	packed := append([]byte{0xca}, random[8:12]...)
	packed = append(packed, hongguoV5LE32(check)...)
	packed = append(packed, transformed...)
	packed = append(packed, byte(nonce>>16), byte(nonce>>24))
	key, iv := md5.Sum(hongguoV5SignKey[:16]), md5.Sum(hongguoV5SignKey[16:])
	encrypted, err := hongguoV5Carrier(key[:], iv[:], packed, stamp)
	if err != nil {
		return "", err
	}
	prefix := append(hongguoV5LE32(5), hongguoV5Magic...)
	stampBytes := hongguoV5LE32(stamp)
	for i := range prefix {
		prefix[i] ^= stampBytes[i&3]
	}
	prefix = append(prefix, byte(nonce), byte(nonce>>8), 0, 1)
	return base64.StdEncoding.EncodeToString(append(prefix, encrypted...)), nil
}
