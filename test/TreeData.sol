// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AUTO-GENERATED from @openzeppelin/merkle-tree (the same library tools/build-list.mjs uses).
// Wallets: 0xA1 = alice, 0xB0b = bob, 0xC4 = carol.
library TreeData {
    bytes32 constant DEX_ROOT = 0xb37437a32750d38e7538feaf7d4e9463d72b0c4bbc124ff12cf967084e240bfd;
    bytes32 constant KAOLA_ROOT = 0xed14e95148c0eb1a838e721fd56a1885f3e423c726ce5fe265642ca5f6c1b61b;

    function dexAlice() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = 0xb892acb12142f0744635268acc5926543344781a485254ddceb36f91d9d3eb43;
        p[1] = 0xd55ff2ca1698446a6ff21d58bc95aeb848f663fe28066ac7fce77d7a43862faf;
    }

    function dexBob() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = 0x1d737d92e6a2931157e16e6021c74c1bb84e4f751fc22941a6faeabf4dde3fbb;
        p[1] = 0xd55ff2ca1698446a6ff21d58bc95aeb848f663fe28066ac7fce77d7a43862faf;
    }

    function dexCarol() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = 0x0921db1bf5f98a1024c686a9a98c3775dbb7e85ab9904d42b436554d08714d46;
    }

    function kaolaAlice1() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = 0x0dc627832c124d2765b7d0c1723517bffd7682b976f333d199ef4ed83f0b0b1e;
        p[1] = 0xfdbdb933157d2c517b0ae1724a7e8d3d46c6beb2849d3774231777660e9ab3f5;
    }

    function kaolaBob2() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = 0x75e7c910f880f008a60f5727b184854f03f1f5d251b56b40ba9ca691cc74903e;
    }

    function kaolaCarol3() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = 0xe0885c5bb4f13c6d7b7686bfaa660f1962fb129889f37cb020a8e19549fc16f9;
        p[1] = 0xfdbdb933157d2c517b0ae1724a7e8d3d46c6beb2849d3774231777660e9ab3f5;
    }
}
