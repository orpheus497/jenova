local bit = require("bit")
local rshift, lshift, bnot = bit.rshift, bit.lshift, bit.bnot
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local rrotate = bit.ror

local k = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function str2blk(msg)
  local m = {}
  local len = #msg
  for i = 1, len do
    local b = string.byte(msg, i)
    local idx = math.floor((i-1)/4) + 1
    m[idx] = bor(m[idx] or 0, lshift(b, 24 - 8*((i-1)%4)))
  end
  local b = 0x80
  local idx = math.floor(len/4) + 1
  m[idx] = bor(m[idx] or 0, lshift(b, 24 - 8*(len%4)))
  local total_len = math.floor(len/64)*64 + 64
  if (len % 64) >= 56 then total_len = total_len + 64 end
  local total_words = total_len / 4
  for i = #m + 1, total_words do m[i] = 0 end
  local bit_len = len * 8
  m[total_words-1] = math.floor(bit_len / (2^32))
  m[total_words] = band(bit_len, 0xffffffff)
  return m
end

local function toHex(w)
  return bit.tohex(w, 8)
end

local function sha256(msg)
  local h = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  }
  local m = str2blk(msg)
  local w = {}
  for i = 0, (#m/16 - 1) do
    for j = 1, 16 do w[j] = m[i*16 + j] end
    for j = 17, 64 do
      local s0 = bxor(rrotate(w[j-15], 7), rrotate(w[j-15], 18), rshift(w[j-15], 3))
      local s1 = bxor(rrotate(w[j-2], 17), rrotate(w[j-2], 19), rshift(w[j-2], 10))
      w[j] = band(w[j-16] + s0 + w[j-7] + s1, 0xffffffff)
    end
    local a, b, c, d, e, f, g, h0 = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for j = 1, 64 do
      local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local temp1 = band(h0 + S1 + ch + k[j] + w[j], 0xffffffff)
      local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local temp2 = band(S0 + maj, 0xffffffff)
      h0, g, f, e, d, c, b, a = g, f, e, band(d + temp1, 0xffffffff), c, b, a, band(temp1 + temp2, 0xffffffff)
    end
    h[1] = band(h[1] + a, 0xffffffff)
    h[2] = band(h[2] + b, 0xffffffff)
    h[3] = band(h[3] + c, 0xffffffff)
    h[4] = band(h[4] + d, 0xffffffff)
    h[5] = band(h[5] + e, 0xffffffff)
    h[6] = band(h[6] + f, 0xffffffff)
    h[7] = band(h[7] + g, 0xffffffff)
    h[8] = band(h[8] + h0, 0xffffffff)
  end
  return toHex(h[1]) .. toHex(h[2]) .. toHex(h[3]) .. toHex(h[4]) ..
         toHex(h[5]) .. toHex(h[6]) .. toHex(h[7]) .. toHex(h[8])
end

return { sha256 = sha256 }
