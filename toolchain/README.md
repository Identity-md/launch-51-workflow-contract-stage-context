# Offline compiler cache

Official Linux x86-64 Solidity 0.8.26+commit.8a97fa7a compiler, downloaded by Foundry.
Source: https://binaries.soliditylang.org/linux-amd64/solc-linux-amd64-v0.8.26+commit.8a97fa7a
SHA-256: `d5f23436f443edb85d8e76906d12f0a86ce0490e7663a9e608efeb7a93f149ef` (verified against the official release index).
Source code: https://github.com/ethereum/solidity/tree/v0.8.26
License: GPL-3.0, see LICENSE-solidity.txt.

Set `XDG_DATA_HOME="$PWD/toolchain"` before running Foundry to select this ordinary
SVM compiler cache on a fresh machine. foundry.toml selects version 0.8.26,
not an executable override. Requires Linux x86-64. If ~/.svm already exists,
Foundry may prefer that cache; it must contain the same compiler version.
