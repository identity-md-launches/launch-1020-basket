// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

library BaskTypes {
    struct Asset {
        address token;
        address feed;
        address pool;
        address quoteFeed;
        uint128 minLiquidity;
        bool open;
        bool retired;
        bool hasPause;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        uint8 quoteDecimals;
        uint8 quoteFeedDecimals;
        bool tokenIs0;
        uint256 centre;
    }

    struct Settings {
        uint256 band;
        uint256 maxAge;
        uint256 noPoolAge;
        uint256 freshCount;
        uint256 freshHours;
        uint256 hoursFrom;
        uint256 hoursTo;
        uint256 poolWindow;
        uint256 poolDeviation;
        uint256 feedGas;
        uint256 pauseGas;
        uint256 poolGas;
        uint256 balanceGas;
        uint256 payGas;
        uint256 maxAssets;
        uint256 directLimit;
    }

    enum Setting {
        Band,
        MaxAge,
        NoPoolAge,
        FreshCount,
        FreshHours,
        Hours,
        PoolWindow,
        PoolDeviation,
        FeedGas,
        PauseGas,
        PoolGas,
        BalanceGas,
        PayGas,
        MaxAssets,
        DirectLimit
    }

    enum Action {
        List,
        Feed,
        Centre,
        Reopen,
        Retire,
        Pool,
        Resync,
        Guardian,
        NavCap,
        FeeRecipient,
        Setting
    }
    enum Reason {
        OK,
        Genesis,
        Paused,
        Hours,
        Unlisted,
        Closed,
        Duplicate,
        BalanceUnreadable,
        Deficit,
        Feed,
        Band,
        OraclePaused,
        Pool,
        Freshness
    }

    struct Proposal {
        Action action;
        address token;
        bytes data;
        uint256 readyAt;
        uint256 epoch;
        uint256 version;
        bool done;
    }

    struct AssetView {
        Asset config;
        uint256 answer;
        uint256 updatedAt;
        uint256 poolPrice;
        uint256 managed;
        bool short;
        bool readable;
        uint256 totalOwed;
        Reason reason;
    }
}
