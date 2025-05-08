// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// revised from https://github.com/storyicon/base58-solidity

library RippleBase58 {
    bytes constant ALPHABET =
        "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz";

    function decode(bytes memory data_) internal pure returns (bytes memory) {
        unchecked {
            uint256 zero = 49;
            uint256 b58sz = data_.length;
            uint256 zcount = 0;
            for (uint256 i = 0; i < b58sz && uint8(data_[i]) == zero; i++) {
                zcount++;
            }
            uint256 t;
            uint256 c;
            bool f;
            bytes memory binu = new bytes(2 * (((b58sz * 8351) / 6115) + 1));
            uint32[] memory outi = new uint32[]((b58sz + 3) / 4);
            for (uint256 i = 0; i < data_.length; i++) {
                bytes1 r = data_[i];
                (c, f) = indexOf(ALPHABET, r);
                require(f, "invalid base58 digit");
                for (int256 k = int256(outi.length) - 1; k >= 0; k--) {
                    t = uint64(outi[uint256(k)]) * 58 + c;
                    c = t >> 32;
                    outi[uint256(k)] = uint32(t & 0xffffffff);
                }
            }
            uint64 mask = uint64(b58sz % 4) * 8;
            if (mask == 0) {
                mask = 32;
            }
            mask -= 8;
            uint256 outLen = 0;
            for (uint256 j = 0; j < outi.length; j++) {
                while (mask < 32) {
                    binu[outLen] = bytes1(uint8(outi[j] >> mask));
                    outLen++;
                    if (mask < 8) {
                        break;
                    }
                    mask -= 8;
                }
                mask = 24;
            }
            for (uint256 msb = zcount; msb < binu.length; msb++) {
                if (binu[msb] > 0) {
                    return slice(binu, msb - zcount, outLen);
                }
            }

            return slice(binu, 0, outLen);
        }
    }

    function decodeFromRippleAddress(bytes memory data)
        internal
        pure
        returns (address)
    {
        uint160 result;
        bytes memory a = decode(data);
        for (uint256 i = 0; i + 4 < a.length; i++) {
            result = result * 256 + uint8(a[i]);
        }
        return address(result);
    }

    /**
     * @notice slice is used to slice the given byte, returns the bytes in the range of [start_, end_)
     * @param data_ raw data, passed in as bytes.
     * @param start_ start index.
     * @param end_ end index.
     * @return slice data
     */
    function slice(
        bytes memory data_,
        uint256 start_,
        uint256 end_
    ) internal pure returns (bytes memory) {
        unchecked {
            bytes memory ret = new bytes(end_ - start_);
            for (uint256 i = 0; i < end_ - start_; i++) {
                ret[i] = data_[i + start_];
            }
            return ret;
        }
    }

    /**
     * @notice indexOf is used to find where char_ appears in data_.
     * @param data_ raw data, passed in as bytes.
     * @param char_ target byte.
     * @return index, and whether the search was successful.
     */
    function indexOf(bytes memory data_, bytes1 char_)
        internal
        pure
        returns (uint256, bool)
    {
        unchecked {
            for (uint256 i = 0; i < data_.length; i++) {
                if (data_[i] == char_) {
                    return (i, true);
                }
            }
            return (0, false);
        }
    }
}
