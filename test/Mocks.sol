// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockToken {
    uint8 public immutable decimals;
    mapping(address => uint256) internal balances;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public oraclePaused;
    bool public paused;
    bool public pauseReverts;
    mapping(address => bool) public blocked;
    uint256 public balanceMode;
    uint256 public transferMode;
    uint256 public balanceWork;
    uint256 public transferWork;
    address public callback;
    bytes public callbackData;
    bool public callbackSucceeded;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balances[from] -= amount;
    }

    function setOraclePaused(bool v) external {
        oraclePaused = v;
    }

    function setPaused(bool v) external {
        paused = v;
    }

    function setBlocked(address to, bool v) external {
        blocked[to] = v;
    }

    function setModes(uint256 b, uint256 t) external {
        balanceMode = b;
        transferMode = t;
    }

    function setWork(uint256 b, uint256 t) external {
        balanceWork = b;
        transferWork = t;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function approve(address to, uint256 amount) external returns (bool) {
        allowance[msg.sender][to] = amount;
        return true;
    }

    function _work(uint256 gasToUse) internal view {
        uint256 start = gasleft();
        while (start - gasleft() < gasToUse) {
            assembly ("memory-safe") { pop(keccak256(0, 32)) }
        }
    }

    function balanceOf(address who) external view returns (uint256) {
        _work(balanceWork);
        uint256 mode = balanceMode;
        if (mode == 1) revert("blocked read");
        if (mode == 2) {
            assembly ("memory-safe") { invalid() }
        }
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, 0)
                return(0, 1)
            }
        }
        uint256 bal = balances[who];
        if (mode == 4) {
            assembly ("memory-safe") {
                let p := mload(0x40)
                mstore(p, bal)
                return(p, 32768)
            }
        }
        return bal;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] -= amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        _work(transferWork);
        require(!paused && !blocked[from] && !blocked[to], "paused/blocked");
        uint256 mode = transferMode;
        if (mode == 1) revert("upgraded revert");
        if (mode == 2) {
            assembly ("memory-safe") { invalid() }
        }
        if (callback != address(0)) (callbackSucceeded,) = callback.call(callbackData);
        uint256 debit = mode == 7 ? amount + 1 : amount;
        balances[from] -= debit;
        balances[to] += mode == 6 ? amount - 1 : amount;
        if (mode == 3) return false;
        if (mode == 4) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == 5) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (mode == 8) {
            assembly ("memory-safe") {
                let p := mload(0x40)
                mstore(p, 1)
                return(p, 32768)
            }
        }
        if (mode == 9) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 1)
            }
        }
        return true;
    }
}

contract MockFeed {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public mode;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 time) external {
        answer = a;
        updatedAt = time;
    }

    function setMode(uint256 value) external {
        mode = value;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (mode == 1) revert("feed unavailable");
        if (mode == 2) {
            assembly ("memory-safe") { invalid() }
        }
        if (mode == 3) {
            assembly ("memory-safe") { return(0, 32) }
        }
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockPool {
    address public token0;
    address public token1;
    int56 public tickDelta;
    uint160 public liquidityDelta;
    uint256 public mode;
    int56 public tickStart;
    uint160 public liquidityStart;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        liquidityDelta = uint160((uint256(1800) << 128) / 1e12);
    }

    function set(int56 dt, uint160 dl) external {
        tickDelta = dt;
        liquidityDelta = dl;
    }

    function setStarts(int56 t, uint160 l) external {
        tickStart = t;
        liquidityStart = l;
    }

    function setMode(uint256 value) external {
        mode = value;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory t, uint160[] memory l) {
        require(secondsAgos.length == 2 && secondsAgos[1] == 0, "window");
        if (mode == 1) revert("observe unavailable");
        if (mode == 2) {
            assembly ("memory-safe") { invalid() }
        }
        if (mode == 3) {
            assembly ("memory-safe") { return(0, 32) }
        }
        t = new int56[](2);
        l = new uint160[](2);
        t[0] = tickStart;
        l[0] = liquidityStart;
        unchecked {
            t[1] = tickStart + tickDelta;
            l[1] = liquidityStart + liquidityDelta;
        }
    }
}

contract NoPauseToken {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
