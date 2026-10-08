// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {BaskTypes as T} from "./BaskTypes.sol";
import {BaskOracle as O} from "./libraries/BaskOracle.sol";
import {FullMath} from "./libraries/FullMath.sol";

/// @notice Basket's ERC-20 share and custody vault for Stock Tokens.
contract BaskVault {
    string public constant name = "Basket";
    string public constant symbol = "BASK";
    uint8 public constant decimals = 18;
    // An immutable keeps the standard event topic in PUSH data instead of a pooled
    // trailing constant table, which the deployment bytecode scanner treats as code.
    bytes32 private immutable transferTopic = keccak256("Transfer(address,address,uint256)");
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;
    address public pendingOwner;
    address public guardian;
    address public feeRecipient;
    bool public genesisFinalized;
    bool public depositsPaused;
    uint256 public NAV_CAP = 1_000_000e18;
    uint256 public constant MAX_NAV_CAP = 10_000_000_000e18;
    uint256 public constant MINIMUM_SHARES = 1e15;
    uint256 private entered = 1;
    T.Settings private config;
    address[] public assetTokens;
    mapping(address => T.Asset) private assets;
    mapping(address => uint256) private index;
    mapping(address => address) private feedAsset;
    mapping(address => uint256) public managed;
    // Cache nonzero holdings so idle assets do not consume cold storage reads in redeem.
    uint256 private heldCount;
    mapping(uint256 => uint256) private heldBitmap;
    mapping(address => mapping(address => uint256)) public owed;
    mapping(address => uint256) public totalOwed;

    struct Deficit {
        uint256 amount;
        uint256 since;
    }
    mapping(address => Deficit) public deficits;
    mapping(uint256 => T.Proposal) private proposals;
    uint256 public proposalCount;
    mapping(address => uint256) private epoch;
    mapping(address => uint256) private closeVersion;
    uint256 private capVersion;

    error Unauthorized();
    error Reentrancy();
    error InvalidAddress();
    error InvalidInput();
    error InvalidAsset();
    error InvalidSetting();
    error InvalidProposal();
    error TooEarly();
    error Expired();
    error DepositUnavailable(T.Reason reason, address token);
    error TransferFailed();
    error Slippage();
    error CapExceeded();
    error ZeroNAV();
    error InsufficientBalance();

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed account, address indexed spender, uint256 amount);
    event OwnershipTransferStarted(address indexed owner, address indexed nextOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianChanged(address indexed guardian);
    event FeeRecipientChanged(address indexed recipient);
    event GenesisFinalized();
    event AssetListed(address indexed token, address indexed feed, address pool);
    event AssetChanged(address indexed token, T.Action action);
    event AssetClosed(address indexed token);
    event AssetRemoved(address indexed token);
    event DepositsPaused(bool paused);
    event NavCapChanged(uint256 cap);
    event SettingChanged(T.Setting setting, uint256 value);
    event Proposed(uint256 indexed id, T.Action action, address indexed token, bytes data, uint256 readyAt);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id);
    event Deposit(address indexed caller, address indexed receiver, uint256 value, uint256 shares, uint256 fee);
    event Redeem(address indexed caller, address indexed receiver, uint256 shares, uint256 fee);
    event Claimed(address indexed caller, address indexed to, address indexed token, uint256 amount);
    event DeficitFlagged(address indexed token, uint256 amount, uint256 since);
    event LossRecognized(address indexed token, uint256 amount);
    event Resynced(address indexed token, uint256 amount);

    modifier nonReentrant() {
        if (entered != 1) revert Reentrancy();
        entered = 2;
        _;
        entered = 1;
    }
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier onlyRole() {
        if (msg.sender != owner && msg.sender != guardian) revert Unauthorized();
        _;
    }

    constructor(address owner_, address guardian_) {
        if (owner_ == address(0) || guardian_ == address(0) || owner_ == guardian_) revert InvalidAddress();
        owner = owner_;
        guardian = guardian_;
        config = T.Settings(
            4, 80 hours, 26 hours, 0, 4, 0, 0, 1800, 300, 100_000, 100_000, 150_000, 50_000, 250_000, 250, 50
        );
        emit OwnershipTransferred(address(0), owner_);
        emit GuardianChanged(guardian_);
    }

    function approve(address spender, uint256 amount) external nonReentrant returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external nonReentrant returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external nonReentrant returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (amount > allowed) revert InsufficientBalance();
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        _emitTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) private {
        balanceOf[to] += amount;
        totalSupply += amount;
        _emitTransfer(address(0), to, amount);
    }

    function _emitTransfer(address from, address to, uint256 amount) private {
        bytes32 topic = transferTopic;
        assembly ("memory-safe") {
            mstore(0, amount)
            log3(
                0,
                32,
                topic,
                and(from, 0xffffffffffffffffffffffffffffffffffffffff),
                and(to, 0xffffffffffffffffffffffffffffffffffffffff)
            )
        }
    }

    function transferOwnership(address nextOwner) external onlyOwner nonReentrant {
        if (nextOwner == address(0) || nextOwner == guardian) revert InvalidAddress();
        pendingOwner = nextOwner;
        emit OwnershipTransferStarted(owner, nextOwner);
    }

    function acceptOwnership() external nonReentrant {
        if (msg.sender != pendingOwner || msg.sender == guardian) revert Unauthorized();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }

    function pauseDeposits() external onlyRole nonReentrant {
        depositsPaused = true;
        emit DepositsPaused(true);
    }

    function unpauseDeposits() external onlyOwner nonReentrant {
        depositsPaused = false;
        emit DepositsPaused(false);
    }

    function close(address token) external onlyRole nonReentrant {
        _listed(token);
        assets[token].open = false;
        ++closeVersion[token];
        emit AssetClosed(token);
    }

    function lowerNavCap(uint256 cap) external onlyOwner nonReentrant {
        if (cap >= NAV_CAP) revert InvalidInput();
        NAV_CAP = cap;
        ++capVersion;
        emit NavCapChanged(cap);
    }

    function genesisList(address token, address feed, address pool, address quoteFeed, uint128 minLiquidity)
        external
        onlyOwner
        nonReentrant
    {
        if (genesisFinalized) revert InvalidInput();
        _list(token, feed, pool, quoteFeed, minLiquidity);
    }

    function finalizeGenesis() external onlyOwner nonReentrant {
        if (genesisFinalized || assetTokens.length < 3) revert InvalidInput();
        genesisFinalized = true;
        emit GenesisFinalized();
    }

    function _listed(address token) private view {
        if (index[token] == 0) revert InvalidAsset();
    }

    function _checkFeed(address token, address feed) private view returns (uint8 d, uint256 answer) {
        address used = feedAsset[feed];
        if (used != address(0) && used != token) revert InvalidAsset();
        d = O.decimals(feed, config.feedGas);
        bool ok;
        (ok, answer,) = O.feed(feed, config.feedGas, config.maxAge);
        if (!ok) revert O.InvalidOracle();
    }

    function _poolConfig(T.Asset memory a, address pool, address quoteFeed, uint128 minLiquidity)
        private
        view
        returns (T.Asset memory)
    {
        a.pool = pool;
        a.quoteFeed = quoteFeed;
        a.minLiquidity = minLiquidity;
        a.quoteDecimals = 0;
        a.quoteFeedDecimals = 0;
        a.tokenIs0 = false;
        if (pool == address(0)) {
            if (quoteFeed != address(0) || minLiquidity != 0) revert InvalidInput();
            return a;
        }
        (bool ok0, uint256 t0) = O.word(pool, abi.encodeWithSignature("token0()"), config.poolGas);
        (bool ok1, uint256 t1) = O.word(pool, abi.encodeWithSignature("token1()"), config.poolGas);
        if (
            !ok0 || !ok1 || t0 == 0 || t0 >= t1 || t1 > type(uint160).max
                || (t0 != uint160(a.token) && t1 != uint160(a.token))
        ) revert InvalidAsset();
        a.tokenIs0 = t0 == uint160(a.token);
        a.quoteDecimals = O.decimals(address(uint160(a.tokenIs0 ? t1 : t0)), config.feedGas);
        a.quoteFeedDecimals = O.decimals(quoteFeed, config.feedGas);
        return a;
    }

    function _newAsset(address token, address feed, address pool, address quoteFeed, uint128 minLiquidity)
        private
        view
        returns (T.Asset memory a)
    {
        if (index[token] != 0 || assetTokens.length >= config.maxAssets) revert InvalidAsset();
        a.token = token;
        a.feed = feed;
        a.tokenDecimals = O.decimals(token, config.feedGas);
        (a.feedDecimals, a.centre) = _checkFeed(token, feed);
        a.open = true;
        (bool ok, uint256 paused) = O.word(token, abi.encodeWithSignature("oraclePaused()"), config.pauseGas);
        a.hasPause = ok && paused <= 1;
        return _poolConfig(a, pool, quoteFeed, minLiquidity);
    }

    function _list(address token, address feed, address pool, address quoteFeed, uint128 minLiquidity) private {
        assets[token] = _newAsset(token, feed, pool, quoteFeed, minLiquidity);
        assetTokens.push(token);
        index[token] = assetTokens.length;
        feedAsset[feed] = token;
        emit AssetListed(token, feed, pool);
    }

    /// @notice Action payload encodings are documented in README.md.
    function propose(T.Action action, address token, bytes calldata data)
        external
        onlyOwner
        nonReentrant
        returns (uint256 id)
    {
        _validate(action, token, data);
        id = ++proposalCount;
        uint256 version = action == T.Action.Reopen ? closeVersion[token] : capVersion;
        proposals[id] = T.Proposal(action, token, data, block.timestamp + 2 days, epoch[token], version, false);
        emit Proposed(id, action, token, data, block.timestamp + 2 days);
    }

    function _validate(T.Action action, address token, bytes memory data) private view {
        if (action <= T.Action.Resync && action != T.Action.List) {
            _listed(token);
            if (assets[token].retired && action != T.Action.Resync) revert InvalidAsset();
        }
        if (action == T.Action.List) {
            (address f, address p, address q, uint128 l) = abi.decode(data, (address, address, address, uint128));
            _newAsset(token, f, p, q, l);
        } else if (action == T.Action.Feed) {
            _checkFeed(token, abi.decode(data, (address)));
        } else if (action == T.Action.Retire) {
            if (assets[token].open) revert InvalidAsset();
        } else if (action == T.Action.Pool) {
            (address p, address q, uint128 l) = abi.decode(data, (address, address, uint128));
            _poolConfig(assets[token], p, q, l);
        } else if (action == T.Action.Guardian) {
            address next = abi.decode(data, (address));
            if (next == address(0) || next == owner) revert InvalidAddress();
        } else if (action == T.Action.NavCap) {
            uint256 cap = abi.decode(data, (uint256));
            if (cap <= NAV_CAP || cap > MAX_NAV_CAP) revert InvalidInput();
        } else if (action == T.Action.FeeRecipient) {
            address next = abi.decode(data, (address));
            if (next == address(0) || next == address(this)) revert InvalidAddress();
        } else if (action == T.Action.Setting) {
            (T.Setting key, uint256 value) = abi.decode(data, (T.Setting, uint256));
            _changedSettings(key, value);
        }
    }

    function proposalValid(uint256 id) public view returns (bool) {
        T.Proposal storage p = proposals[id];
        return p.readyAt != 0 && !p.done && block.timestamp <= p.readyAt + 7 days && p.epoch == epoch[p.token]
            && (p.action != T.Action.Reopen || p.version == closeVersion[p.token])
            && (p.action != T.Action.NavCap || p.version == capVersion);
    }

    function cancel(uint256 id) external onlyRole nonReentrant {
        T.Proposal storage p = proposals[id];
        if (p.readyAt == 0 || p.done) revert InvalidProposal();
        if (msg.sender == guardian && p.action == T.Action.Guardian) revert Unauthorized();
        p.done = true;
        emit ProposalCancelled(id);
    }

    function execute(uint256 id) external onlyOwner nonReentrant {
        if (!proposalValid(id)) revert InvalidProposal();
        T.Proposal storage p = proposals[id];
        if (block.timestamp < p.readyAt) revert TooEarly();
        _validate(p.action, p.token, p.data);
        p.done = true;
        address token = p.token;
        T.Asset storage a = assets[token];
        if (p.action == T.Action.List) {
            (address f, address pool, address q, uint128 l) = abi.decode(p.data, (address, address, address, uint128));
            _list(token, f, pool, q, l);
        } else if (p.action == T.Action.Feed) {
            delete feedAsset[a.feed];
            a.feed = abi.decode(p.data, (address));
            (a.feedDecimals, a.centre) = _checkFeed(token, a.feed);
            feedAsset[a.feed] = token;
        } else if (p.action == T.Action.Centre) {
            (bool ok, uint256 answer,) = O.feed(a.feed, config.feedGas, config.maxAge);
            if (!ok) revert O.InvalidOracle();
            a.centre = answer;
        } else if (p.action == T.Action.Reopen) {
            a.open = true;
        } else if (p.action == T.Action.Retire) {
            a.retired = true;
            delete feedAsset[a.feed];
            ++epoch[token];
        } else if (p.action == T.Action.Pool) {
            (address pool, address q, uint128 l) = abi.decode(p.data, (address, address, uint128));
            assets[token] = _poolConfig(a, pool, q, l);
        } else if (p.action == T.Action.Resync) {
            (bool ok, uint256 bal) = O.balance(token, config.balanceGas);
            if (!ok) revert TransferFailed();
            uint256 available = bal > totalOwed[token] ? bal - totalOwed[token] : 0;
            uint256 extra = available > managed[token] ? available - managed[token] : 0;
            _setManaged(token, managed[token] + extra);
            emit Resynced(token, extra);
        } else if (p.action == T.Action.Guardian) {
            guardian = abi.decode(p.data, (address));
            emit GuardianChanged(guardian);
        } else if (p.action == T.Action.NavCap) {
            NAV_CAP = abi.decode(p.data, (uint256));
            emit NavCapChanged(NAV_CAP);
        } else if (p.action == T.Action.FeeRecipient) {
            feeRecipient = abi.decode(p.data, (address));
            emit FeeRecipientChanged(feeRecipient);
        } else {
            (T.Setting key, uint256 value) = abi.decode(p.data, (T.Setting, uint256));
            config = _changedSettings(key, value);
            emit SettingChanged(key, value);
        }
        if (p.action <= T.Action.Resync) emit AssetChanged(token, p.action);
        emit ProposalExecuted(id);
    }

    function _changedSettings(T.Setting key, uint256 value) private view returns (T.Settings memory s) {
        s = config;
        if (key == T.Setting.Band) {
            _bound(value, 2, 100);
            s.band = value;
        } else if (key == T.Setting.MaxAge) {
            _bound(value, 1 hours, 30 days);
            s.maxAge = value;
        } else if (key == T.Setting.NoPoolAge) {
            _bound(value, 1 hours, 30 days);
            s.noPoolAge = value;
        } else if (key == T.Setting.FreshCount) {
            _bound(value, 0, 10);
            s.freshCount = value;
        } else if (key == T.Setting.FreshHours) {
            _bound(value, 1, 48);
            s.freshHours = value;
        } else if (key == T.Setting.Hours) {
            s.hoursFrom = value >> 32;
            s.hoursTo = uint32(value);
            if (value != 0 && (s.hoursFrom >= s.hoursTo || s.hoursTo > 1 days)) revert InvalidSetting();
        } else if (key == T.Setting.PoolWindow) {
            _bound(value, 300, 86400);
            s.poolWindow = value;
        } else if (key == T.Setting.PoolDeviation) {
            _bound(value, 50, 2000);
            s.poolDeviation = value;
        } else if (key == T.Setting.MaxAssets) {
            s.maxAssets = value;
        } else if (key == T.Setting.DirectLimit) {
            s.directLimit = value;
        } else {
            _bound(value, 20_000, 500_000);
            if (key == T.Setting.FeedGas) s.feedGas = value;
            else if (key == T.Setting.PauseGas) s.pauseGas = value;
            else if (key == T.Setting.PoolGas) s.poolGas = value;
            else if (key == T.Setting.BalanceGas) s.balanceGas = value;
            else s.payGas = value;
        }
        // Division avoids overflowing on a proposed arbitrary limit.
        if (
            s.maxAssets < assetTokens.length || s.maxAssets > 28_000_000 / (s.balanceGas + 60_000)
                || s.directLimit > 28_000_000 / (s.balanceGas + s.payGas + 70_000)
        ) revert InvalidSetting();
    }

    function _bound(uint256 value, uint256 low, uint256 high) private pure {
        if (value < low || value > high) revert InvalidSetting();
    }

    function removeRetired(address token) external nonReentrant {
        _listed(token);
        if (!assets[token].retired || managed[token] != 0 || totalOwed[token] != 0) revert InvalidAsset();
        uint256 i = index[token] - 1;
        address last = assetTokens[assetTokens.length - 1];
        if (managed[last] != 0) {
            uint256 lastIndex = assetTokens.length - 1;
            heldBitmap[lastIndex >> 8] &= ~(uint256(1) << (lastIndex & 255));
            heldBitmap[i >> 8] |= uint256(1) << (i & 255);
        }
        assetTokens[i] = last;
        index[last] = i + 1;
        assetTokens.pop();
        delete index[token];
        delete assets[token];
        delete deficits[token];
        ++epoch[token];
        emit AssetRemoved(token);
    }

    function _insideHours() private view returns (bool) {
        if (config.hoursFrom == 0 && config.hoursTo == 0) return true;
        uint256 time = block.timestamp % 1 days;
        return (block.timestamp / 1 days + 3) % 7 < 5 && time >= config.hoursFrom && time < config.hoursTo;
    }

    function _snapshot(address[] calldata tokens)
        private
        view
        returns (T.Reason reason, address fault, uint256 nav, uint256[] memory answers)
    {
        answers = new uint256[](assetTokens.length);
        if (!genesisFinalized) return (T.Reason.Genesis, address(0), 0, answers);
        if (depositsPaused) return (T.Reason.Paused, address(0), 0, answers);
        if (!_insideHours()) return (T.Reason.Hours, address(0), 0, answers);
        bool[] memory wanted = new bool[](assetTokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 ix = index[token];
            if (ix == 0) return (T.Reason.Unlisted, token, 0, answers);
            if (!assets[token].open || assets[token].retired) return (T.Reason.Closed, token, 0, answers);
            if (wanted[ix - 1]) return (T.Reason.Duplicate, token, 0, answers);
            wanted[ix - 1] = true;
        }
        uint256 fresh;
        for (uint256 i; i < assetTokens.length; ++i) {
            address token = assetTokens[i];
            T.Asset memory a = assets[token];
            if (a.retired) continue;
            (bool readable, uint256 bal) = O.balance(token, config.balanceGas);
            if (!readable) return (T.Reason.BalanceUnreadable, token, 0, answers);
            uint256 debt = totalOwed[token];
            uint256 m = managed[token];
            uint256 available = bal > debt ? bal - debt : 0;
            if ((wanted[i] && bal < debt) || available < m) return (T.Reason.Deficit, token, 0, answers);
            uint256 updatedAt;
            if (m != 0 || wanted[i]) {
                (reason, answers[i], updatedAt,) = O.price(a, config);
                if (reason != T.Reason.OK) return (reason, token, 0, answers);
                nav += O.value(m, answers[i], a.tokenDecimals, a.feedDecimals);
                if (block.timestamp - updatedAt <= config.freshHours * 1 hours) ++fresh;
            } else if (config.freshCount != 0) {
                (bool ok,,) = O.feed(a.feed, config.feedGas, config.freshHours * 1 hours);
                if (ok) ++fresh;
            }
        }
        if (fresh < config.freshCount) reason = T.Reason.Freshness;
    }

    function _quoteDeposit(address[] calldata tokens, uint256[] calldata amounts)
        private
        view
        returns (uint256 received, uint256 fee, uint256 v, uint256 gross)
    {
        if (tokens.length == 0 || tokens.length != amounts.length) revert InvalidInput();
        (T.Reason reason, address fault, uint256 nav, uint256[] memory answers) = _snapshot(tokens);
        if (reason != T.Reason.OK) revert DepositUnavailable(reason, fault);
        for (uint256 i; i < tokens.length; ++i) {
            if (amounts[i] == 0) revert InvalidInput();
            T.Asset storage a = assets[tokens[i]];
            v += O.value(amounts[i], answers[index[tokens[i]] - 1], a.tokenDecimals, a.feedDecimals);
        }
        if (nav > NAV_CAP || v > NAV_CAP - nav) revert CapExceeded();
        uint256 supply = totalSupply;
        if (supply != 0 && nav == 0) revert ZeroNAV();
        gross = supply == 0 ? v : FullMath.mulDiv(v, supply, nav);
        fee = _fee(gross);
        received = gross - fee;
        if (supply == 0) {
            if (received <= MINIMUM_SHARES) revert Slippage();
            received -= MINIMUM_SHARES;
        }
        if (received == 0) revert Slippage();
    }

    function _fee(uint256 shares) private view returns (uint256) {
        return feeRecipient == address(0) ? 0 : shares / 200 + (shares % 200 == 0 ? 0 : 1);
    }

    function deposit(
        address[] calldata tokens,
        uint256[] calldata amounts,
        address receiver,
        uint256 minSharesOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 received) {
        if (block.timestamp > deadline) revert Expired();
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
        uint256 fee;
        uint256 v;
        (received, fee, v,) = _quoteDeposit(tokens, amounts);
        if (received < minSharesOut) revert Slippage();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            (bool ok, uint256 beforeBalance) = O.balance(token, config.balanceGas);
            if (!ok) revert TransferFailed();
            _tokenCall(
                token,
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amounts[i])
            );
            uint256 afterBalance;
            (ok, afterBalance) = O.balance(token, config.balanceGas);
            if (!ok || afterBalance < beforeBalance || afterBalance - beforeBalance != amounts[i]) {
                revert TransferFailed();
            }
            _setManaged(token, managed[token] + amounts[i]);
        }
        for (uint256 i; i < assetTokens.length; ++i) {
            address token = assetTokens[i];
            if (!assets[token].retired && deficits[token].amount != 0) {
                delete deficits[token];
                emit DeficitFlagged(token, 0, 0);
            }
        }
        if (totalSupply == 0) _mint(address(0xdEaD), MINIMUM_SHARES);
        if (fee != 0) _mint(feeRecipient, fee);
        _mint(receiver, received);
        emit Deposit(msg.sender, receiver, v, received, fee);
    }

    function _tokenCall(address token, bytes memory input) private {
        bool ok;
        uint256 size;
        uint256 result;
        assembly ("memory-safe") {
            let out := mload(0x40)
            mstore(out, 0)
            ok := call(gas(), token, 0, add(input, 32), mload(input), out, 32)
            size := returndatasize()
            result := mload(out)
        }
        if (!ok || (size != 0 && (size < 32 || result != 1))) revert TransferFailed();
    }

    /// @dev The self-call is an atomic sandbox: failure rolls back a token transfer and is caught by redeem/claim.
    /// The outer user entry point holds the reentrancy guard; this function is callable only by the vault.
    function pay(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert Unauthorized();
        (bool ok, uint256 beforeBalance) = O.balance(token, gasleft());
        if (!ok) revert TransferFailed();
        _tokenCall(token, abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        uint256 afterBalance;
        (ok, afterBalance) = O.balance(token, gasleft());
        if (!ok || afterBalance > beforeBalance || beforeBalance - afterBalance != amount) revert TransferFailed();
    }

    /// @dev All managed changes keep the count and the asset-index bitmap in sync.
    function _setManaged(address token, uint256 amount) private {
        uint256 previous = managed[token];
        if ((previous == 0) != (amount == 0)) {
            uint256 i = index[token] - 1;
            uint256 mask = uint256(1) << (i & 255);
            if (amount == 0) {
                --heldCount;
                heldBitmap[i >> 8] &= ~mask;
            } else {
                ++heldCount;
                heldBitmap[i >> 8] |= mask;
            }
        }
        managed[token] = amount;
    }

    function _available(address token, uint256 m) private view returns (bool readable, uint256 available) {
        uint256 bal;
        (readable, bal) = O.balance(token, config.balanceGas);
        uint256 debt = totalOwed[token];
        available = readable ? (bal > debt ? bal - debt : 0) : m;
    }

    function redeem(uint256 shares, address receiver, uint256[] calldata minAmountsOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (block.timestamp > deadline) revert Expired();
        if (receiver == address(0)) revert InvalidAddress();
        if (shares == 0 || balanceOf[msg.sender] < shares) revert InsufficientBalance();
        uint256 supply = totalSupply;
        uint256 fee = _fee(shares);
        uint256 net = shares - fee;
        if (fee != 0) _transfer(msg.sender, feeRecipient, fee);
        balanceOf[msg.sender] -= net;
        totalSupply -= net;
        _emitTransfer(msg.sender, address(0), net);
        uint256 length = assetTokens.length;
        bool direct = heldCount <= config.directLimit;
        uint256 payGas = config.payGas;
        amounts = new uint256[](length);
        uint256 bits;
        for (uint256 i; i < length; ++i) {
            if (i & 255 == 0) bits = heldBitmap[i >> 8];
            if (bits & (uint256(1) << (i & 255)) == 0) {
                if (i < minAmountsOut.length && minAmountsOut[i] != 0) revert Slippage();
                continue;
            }
            address token = assetTokens[i];
            uint256 m = managed[token];
            uint256 leg;
            if (m != 0) {
                (, uint256 available) = _available(token, m);
                leg = FullMath.mulDiv(m < available ? m : available, net, supply);
            }
            if (i < minAmountsOut.length && leg < minAmountsOut[i]) revert Slippage();
            amounts[i] = leg;
            if (leg == 0) continue;
            _setManaged(token, m - leg);
            bool paid;
            if (direct) {
                // Do not copy arbitrary revert data from a hostile token.
                bytes memory input = abi.encodeCall(this.pay, (token, receiver, leg));
                assembly ("memory-safe") { paid := call(payGas, address(), 0, add(input, 32), mload(input), 0, 0) }
            }
            if (!paid) {
                owed[receiver][token] += leg;
                totalOwed[token] += leg;
            }
        }
        emit Redeem(msg.sender, receiver, shares, fee);
    }

    function claim(address[] calldata tokens, address to) external nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 debt = owed[msg.sender][token];
            if (debt == 0) continue;
            (bool ok, uint256 bal) = O.balance(token, gasleft());
            if (!ok) continue;
            uint256 amount = debt < bal ? debt : bal;
            if (amount == 0) continue;
            owed[msg.sender][token] = debt - amount;
            totalOwed[token] -= amount;
            bytes memory input = abi.encodeCall(this.pay, (token, to, amount));
            assembly ("memory-safe") { ok := call(gas(), address(), 0, add(input, 32), mload(input), 0, 0) }
            if (!ok) {
                owed[msg.sender][token] = debt;
                totalOwed[token] += amount;
            }
            emit Claimed(msg.sender, to, token, ok ? amount : 0);
        }
    }

    function flagDeficit(address token) external nonReentrant {
        _listed(token);
        uint256 m = managed[token];
        (bool readable, uint256 available) = _available(token, m);
        if (!readable) revert TransferFailed();
        uint256 shortfall = available < m ? m - available : 0;
        Deficit storage d = deficits[token];
        if (shortfall == 0) {
            delete deficits[token];
        } else if (shortfall > d.amount) {
            d.amount = shortfall;
            d.since = block.timestamp;
        }
        emit DeficitFlagged(token, deficits[token].amount, deficits[token].since);
    }

    function recognizeLoss(address token) external nonReentrant {
        _listed(token);
        Deficit memory d = deficits[token];
        if (d.amount == 0 || block.timestamp < d.since + 7 days) revert TooEarly();
        uint256 m = managed[token];
        (bool readable, uint256 available) = _available(token, m);
        if (!readable) revert TransferFailed();
        uint256 shortfall = available < m ? m - available : 0;
        uint256 loss = d.amount < shortfall ? d.amount : shortfall;
        _setManaged(token, m - loss);
        delete deficits[token];
        emit LossRecognized(token, loss);
    }

    function settings() external view returns (T.Settings memory) {
        return config;
    }

    function assetCount() external view returns (uint256) {
        return assetTokens.length;
    }

    function asset(address token) external view returns (T.Asset memory) {
        return assets[token];
    }

    function proposal(uint256 id) external view returns (T.Proposal memory) {
        return proposals[id];
    }

    function pendingProposals(uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory ids, T.Proposal[] memory items)
    {
        if (start == 0) start = 1;
        uint256 end = start > proposalCount
            ? start
            : start + (limit < proposalCount - start + 1 ? limit : proposalCount - start + 1);
        uint256 count;
        for (uint256 i = start; i < end; ++i) {
            if (proposalValid(i)) ++count;
        }
        ids = new uint256[](count);
        items = new T.Proposal[](count);
        count = 0;
        for (uint256 i = start; i < end; ++i) {
            if (proposalValid(i)) {
                ids[count] = i;
                items[count++] = proposals[i];
            }
        }
    }

    function depositStatus(address[] calldata tokens) external view returns (T.Reason reason, address fault) {
        (reason, fault,,) = _snapshot(tokens);
    }

    function previewDeposit(address[] calldata tokens, uint256[] calldata amounts)
        external
        view
        returns (uint256 shares, uint256 fee, uint256 value)
    {
        (shares, fee, value,) = _quoteDeposit(tokens, amounts);
    }

    function previewRedeem(uint256 shares) external view returns (uint256[] memory amounts, uint256 fee) {
        if (shares > totalSupply) revert InvalidInput();
        fee = _fee(shares);
        amounts = new uint256[](assetTokens.length);
        if (totalSupply == 0) return (amounts, fee);
        for (uint256 i; i < assetTokens.length; ++i) {
            address token = assetTokens[i];
            uint256 m = managed[token];
            if (m == 0) continue;
            (, uint256 available) = _available(token, m);
            amounts[i] = FullMath.mulDiv(m < available ? m : available, shares - fee, totalSupply);
        }
    }

    function allAssets() external view returns (T.AssetView[] memory result) {
        result = new T.AssetView[](assetTokens.length);
        for (uint256 i; i < assetTokens.length; ++i) {
            address token = assetTokens[i];
            T.AssetView memory v;
            v.config = assets[token];
            v.managed = managed[token];
            v.totalOwed = totalOwed[token];
            uint256 available;
            (v.readable, available) = _available(token, v.managed);
            v.short = available < v.managed;
            (v.reason, v.answer, v.updatedAt, v.poolPrice) = O.price(v.config, config);
            result[i] = v;
        }
    }
}
