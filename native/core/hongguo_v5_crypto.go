// SPDX-License-Identifier: GPL-3.0-only
// Adapted from guoapp-modules/hongguo 49bf731d49c8506f946a28d2d4efc2442c14c67e.
// Upstream credits N3urda/hongguoTV Signer/AesV3/V5Constants and drpys 22261ad.
package core

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math/bits"
)

var hongguoV5Magic = hongguoV5Hex("2d4b4fca49750d433fb5ae2c226dcc56")
var hongguoV5SignKey = hongguoV5Hex("b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d")
var hongguoV5Sbox = hongguoV5Hex(
	"53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0d" +
		"f37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a" +
		"80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1d" +
		"d12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe1274002485912" +
		"38922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65" +
		"b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe" +
		"1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c8" +
		"94545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dcc" +
		"d759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8d" +
		"e0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e" +
		"47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd28" +
		"8fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5" +
		"d09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac9" +
		"1fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443f" +
		"d830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f4459168" +
		"1335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e")

var hongguoV5HashTable = [...]uint32{
	0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
	0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
	0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
	0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
	0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
	0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
	0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
	0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586,
}

// 仅用于编译期已知的协议常量，不接收站源输入。
func hongguoV5Hex(value string) []byte {
	decoded, err := hex.DecodeString(value)
	if err != nil {
		panic(err)
	}
	return decoded
}

func hongguoV5LE32(value uint32) []byte {
	return binary.LittleEndian.AppendUint32(nil, value)
}

func hongguoV5IV(queryHash, bodyHash []byte, stamp uint32) uint32 {
	value := uint32(0x20230928)
	for _, data := range [][]byte{queryHash, bodyHash, hongguoV5LE32(stamp)} {
		for index, b := range data {
			if index&1 == 0 {
				value = value>>4 ^ value ^ value<<6 ^ uint32(b)
			} else {
				value = ^(value>>7 ^ value ^ (uint32(b) | value<<12))
			}
		}
	}
	return value
}

// 上游只实现分支 12，调用方通过调整 _rticket 选择该分支，而不是伪造其他分支。
func hongguoV5Hash(queryHash, bodyHash []byte, stamp uint32) ([]byte, error) {
	if len(queryHash) != 32 || len(bodyHash) != 16 {
		return nil, errors.New("红果 v5 哈希长度无效")
	}
	if hongguoV5IV(queryHash, bodyHash, stamp)&15 != 12 {
		return nil, errors.New("红果 v5 哈希分支不支持")
	}
	const iv uint32 = 0x9d4a97c2
	count := iv + stamp
	var table [64]uint32
	for i, value := range hongguoV5HashTable {
		table[i] = bits.RotateLeft32(value, -int((count+1)&255))
	}
	data := append(append(append([]byte(nil), queryHash...), bodyHash...), hongguoV5LE32(stamp)...)
	for _, b := range []byte{0xfa, 0x45, 0x61, 0xd7} {
		data = append(data, byte((uint32(b)|uint32(b)<<8)>>((count+2)&7)))
	}
	data = append(data, 0, 0, 0, 0, 0, 0, 1, 0xa0)
	var words [128]uint32
	for i := 0; i < 16; i++ {
		words[i] = binary.BigEndian.Uint32(data[i*4:])
	}
	for i := 0; i < 112; i++ {
		x, y := words[i+1], words[i+14]
		words[i+16] = words[i] + words[i+9] + (bits.RotateLeft32(x, 14) ^ bits.RotateLeft32(x, 25) ^ x>>3) + (bits.RotateLeft32(y, 13) ^ bits.RotateLeft32(y, 15) ^ y>>10)
	}
	initial := [8]uint32{0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f, 984304912, 3005047866, 2874125293, 2152413264}
	for i := range initial {
		initial[i] = bits.RotateLeft32(initial[i], -int(count&31))
	}
	state := initial
	for i := uint32(0); i < 96; i++ {
		base := iv + i
		choose := ((state[4] ^ state[0]) & state[1]) ^ state[4]
		sigma1 := bits.RotateLeft32(state[1], 26) ^ bits.RotateLeft32(state[1], 21) ^ bits.RotateLeft32(state[1], 7)
		mixed := words[base&127] + choose + sigma1 + table[base&63] + state[6]
		sigma0 := bits.RotateLeft32(state[3], 30) ^ bits.RotateLeft32(state[3], 19) ^ bits.RotateLeft32(state[3], 10)
		majority := (state[3] & state[5]) | ((state[3] | state[5]) & state[2])
		old := state[7]
		copy(state[1:], state[:7])
		state[7], state[0] = sigma0+majority+mixed, old+mixed
	}
	var digest [32]byte
	for i := range state {
		binary.BigEndian.PutUint32(digest[i*4:], state[i]+initial[i])
	}
	folded := make([]byte, 16, 20)
	for i := range folded {
		folded[i] = digest[i] ^ digest[i+16]
	}
	check := uint32(0x20220420)
	for i := 0; i < 12; i++ {
		if i&1 == 0 {
			check = uint32(folded[i]) ^ check<<7 ^ check>>3 ^ check
		} else {
			check = ^(uint32(folded[i]) | check<<11) ^ check>>5 ^ check
		}
	}
	return binary.LittleEndian.AppendUint32(folded, ((check|4)^0x1000000)|0x20), nil
}

// carrier 只改写前 248 字节的指定比特，其余 protobuf 密文原样保留。
func hongguoV5Carrier(key, iv, source []byte, stamp uint32) ([]byte, error) {
	if len(key) != 16 || len(iv) != 16 || len(source) < 248 {
		return nil, errors.New("红果 v5 carrier 长度无效")
	}
	variant := stamp & 3
	box := hongguoV5Sbox[variant*256 : (variant+1)*256]
	con := [4][4]int{{2, 0, 3, 1}, {1, 3, 2, 0}, {3, 2, 1, 0}, {2, 3, 1, 0}}[variant]
	order := [4][16]int{
		{0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11},
		{0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7},
		{0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7},
		{0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7},
	}[variant]
	initial := [4]uint32{0xbbb5de72, 0xd4638d5b, 0x92a5f73b, 0x89f8a1c9}[variant]
	initialBytes := hongguoV5LE32(initial)
	var expanded [48]byte
	for i := 0; i < 16; i++ {
		expanded[i] = initialBytes[i&3] ^ key[i]
	}
	rounds := uint(8)
	for i := 4; i < 12; i++ {
		at := 4 * (i - 1)
		a, b, c, d := expanded[at], expanded[at+1], expanded[at+2], expanded[at+3]
		if i&3 == 0 {
			a, b, c, d = byte(initial>>(rounds&24))^box[b], box[c], box[d], box[a]
		}
		rounds += 2
		expanded[at+4], expanded[at+5], expanded[at+6], expanded[at+7] = a^expanded[at-12], b^expanded[at-11], c^expanded[at-10], d^expanded[at-9]
	}
	xt := func(value byte) byte {
		if value&128 != 0 {
			return value<<1 ^ 0x1b
		}
		return value << 1
	}
	block := func(value [16]byte) [16]byte {
		rows := value
		addCon := func(offset int) {
			for i := 0; i < 4; i++ {
				for j := 0; j < 4; j++ {
					rows[i*4+j] ^= expanded[(offset+i)*4+con[j]]
				}
			}
		}
		addCon(0)
		for round := 1; round <= 2; round++ {
			for i := range rows {
				rows[i] = box[rows[i]]
			}
			before := rows
			for i := 0; i < 4; i++ {
				copy(rows[i*4:(i+1)*4], before[con[i]*4:(con[i]+1)*4])
			}
			flat := rows
			for i := range rows {
				rows[i] = flat[order[i]]
			}
			if round == 1 {
				before = rows
				for i := 0; i < 4; i++ {
					for j := 0; j < 4; j++ {
						rows[i*4+j] = before[i*4+con[j]]
					}
				}
				for i := 0; i < 4; i++ {
					mixed, first := rows[i]^rows[4+i]^rows[8+i]^rows[12+i], rows[i]
					rows[i] ^= mixed ^ xt(rows[i]^rows[4+i])
					rows[4+i] ^= mixed ^ xt(rows[4+i]^rows[8+i])
					rows[8+i] ^= mixed ^ xt(rows[8+i]^rows[12+i])
					rows[12+i] ^= mixed ^ xt(rows[12+i]^first)
				}
			}
			addCon(round * 4)
		}
		for i := range rows {
			rows[i] ^= expanded[16+i]
		}
		return rows
	}
	wire, compact := [8]uint{6, 5, 3, 4, 2, 7, 1, 0}, [8]uint{1, 7, 3, 6, 2, 0, 4, 5}
	var plaintext [32]byte
	for i := 0; i < 31; i++ {
		for j := 0; j < 8; j++ {
			plaintext[i] |= ((source[i*8+j] >> wire[j]) & 1) << compact[j]
		}
	}
	plaintext[31] = 1
	var input [16]byte
	for i := range input {
		input[i] = plaintext[i] ^ iv[i]
	}
	first := block(input)
	for i := range input {
		input[i] = plaintext[i+16] ^ first[i]
	}
	second := block(input)
	carrier := append(first[:], second[:]...)
	out := append([]byte{carrier[31]}, source...)
	for i := 0; i < 31; i++ {
		for j := 0; j < 8; j++ {
			at := 1 + i*8 + j
			out[at] = (out[at] &^ (1 << wire[j])) | (((carrier[i] >> compact[j]) & 1) << wire[j])
		}
	}
	return out, nil
}
