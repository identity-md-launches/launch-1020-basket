# Vendored sources

All dependencies are ordinary source files, with no submodules or build-time downloads.

| Files | Source/version | License |
| --- | --- | --- |
| `lib/forge-std/src/` | [foundry-rs/forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7/src) | MIT / Apache-2.0; included in `lib/forge-std/` |
| `src/libraries/FullMath.sol` | [Uniswap/v3-core v1.0.0](https://github.com/Uniswap/v3-core/blob/v1.0.0/contracts/libraries/FullMath.sol) | MIT; original Remco Bloemen attribution retained |
| `src/libraries/TickMath.sol` | [Uniswap/v3-core v1.0.0](https://github.com/Uniswap/v3-core/blob/v1.0.0/contracts/libraries/TickMath.sol) | GPL-2.0-or-later; license included |
| Consult and quote arithmetic in `src/libraries/BaskOracle.sol` | [Uniswap/v3-periphery OracleLibrary](https://github.com/Uniswap/v3-periphery/blob/v1.3.0/contracts/libraries/OracleLibrary.sol) | GPL-2.0-or-later; license included |

The Solidity 0.8.26 port of FullMath places modular operations in `unchecked`, uses a valid unsigned expression for two's-complement negation, replaces `require` with `MathOverflow`, and marks memory-safe assembly. TickMath retains only `getSqrtRatioAtTick` and its constants and uses `InvalidTick`. BaskOracle applies consult's wrapping differences, negative tick rounding, and harmonic liquidity equation to a fixed-size, gas-bounded observation read. Its quote is normalized to retain fractional whole quote tokens before USD conversion.

FullMath's arithmetic is credited by upstream to Remco Bloemen under the MIT license: <https://xn--2-umb.com/21/muldiv>.
