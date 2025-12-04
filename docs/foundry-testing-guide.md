# Foundry Testing Best Practices

## Test Organization

### File Structure
```
test/
├── MyContract.t.sol           # Unit tests
├── MyContract.integration.t.sol # Integration tests
└── helpers/
    └── TestUtils.sol          # Shared fixtures
```

### Naming Conventions
- Test files: `MyContract.t.sol`
- Test functions:
  - `test_Description` - standard tests
  - `testFuzz_Description` - fuzz tests
  - `test_RevertWhen_Condition` - revert tests
  - `testFork_Description` - fork tests
  - `invariant_Description` - invariant tests

## Unit Testing Patterns

### Arrange-Act-Assert (AAA)
```solidity
function test_Transfer() public {
    // Arrange
    uint256 amount = 100;
    address recipient = address(0x1);

    // Act
    token.transfer(recipient, amount);

    // Assert
    assertEq(token.balanceOf(recipient), amount);
}
```

### setUp Pattern
```solidity
contract MyContractTest is Test {
    MyContract public target;
    address public admin = address(1);
    address public user = address(2);

    function setUp() public {
        target = new MyContract();
        target.initialize(admin);
    }

    // Verify setup is correct
    function test_SetUpState() public view {
        assertTrue(target.hasRole(target.DEFAULT_ADMIN_ROLE(), admin));
    }
}
```

## VM Cheatcodes

### Common Cheatcodes
```solidity
// Set msg.sender for next call
vm.prank(user);

// Set msg.sender for multiple calls
vm.startPrank(user);
// ... calls ...
vm.stopPrank();

// Set block.timestamp
vm.warp(block.timestamp + 1 days);

// Set block.number
vm.roll(block.number + 100);

// Give ETH to address
vm.deal(user, 10 ether);

// Set storage slot
vm.store(address(target), bytes32(slot), bytes32(value));

// Read storage slot
bytes32 value = vm.load(address(target), bytes32(slot));

// Label address for traces
vm.label(user, "User");
```

### Testing Reverts
```solidity
// Expect specific custom error
vm.expectRevert(abi.encodeWithSelector(MyContract.TokenNotAccepted.selector, tokenAddress));
target.pay(...);

// Expect any revert
vm.expectRevert();
target.doSomething();

// Expect revert with message
vm.expectRevert("Ownable: caller is not the owner");
target.adminFunction();
```

### Testing Events
```solidity
function test_EmitsPayment() public {
    // Set up expectations (checkTopic1, checkTopic2, checkTopic3, checkData)
    vm.expectEmit(true, true, true, true);

    // Emit expected event
    emit Payment(recipient, from, sourceToken, amount, paymentToken, paymentAmount, reference);

    // Trigger actual call
    target.pay(...);
}
```

## Mocking

### Mock Calls
```solidity
// Mock a specific call
vm.mockCall(
    address(token),
    abi.encodeWithSelector(IERC20.balanceOf.selector, user),
    abi.encode(1000)
);

// Clear all mocks after test
vm.clearMockedCalls();
```

### Mock Contracts
```solidity
contract ERC20Mock is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
```

## Fuzz Testing

### Basic Fuzz Test
```solidity
function testFuzz_Transfer(uint256 amount) public {
    // Bound inputs to valid ranges
    amount = bound(amount, 1, token.balanceOf(address(this)));

    token.transfer(recipient, amount);
    assertEq(token.balanceOf(recipient), amount);
}
```

### Input Constraints
```solidity
function testFuzz_Deposit(uint96 amount) public {
    // Use smaller types to match on-chain limits
    // uint96 max ~= 79 billion ETH

    // Or use vm.assume to skip invalid inputs
    vm.assume(amount > 0);
    vm.assume(amount < type(uint96).max);

    // Or use bound()
    amount = bound(amount, 1, 1000 ether);
}
```

### Fuzz Configuration (foundry.toml)
```toml
[fuzz]
runs = 1000              # Number of fuzz runs
max_test_rejects = 65536 # Max invalid inputs before failing
seed = "0x1234"          # Pin seed for reproducibility
```

## Invariant Testing

### Basic Invariant
```solidity
contract InvariantTest is Test {
    MyContract target;

    function setUp() public {
        target = new MyContract();
    }

    // This runs after each fuzzed call sequence
    function invariant_TotalSupplyConstant() public view {
        assertEq(target.totalSupply(), INITIAL_SUPPLY);
    }

    // Runs after entire campaign
    function afterInvariant() public {
        // Final assertions or logging
    }
}
```

### Handler Pattern
```solidity
contract Handler is Test {
    MyContract target;

    constructor(MyContract _target) {
        target = _target;
    }

    function deposit(uint256 amount) public {
        amount = bound(amount, 0, 100 ether);
        target.deposit{value: amount}();
    }
}

contract InvariantTest is Test {
    Handler handler;

    function setUp() public {
        MyContract target = new MyContract();
        handler = new Handler(target);
        targetContract(address(handler));
    }
}
```

### Invariant Configuration (foundry.toml)
```toml
[invariant]
runs = 256           # Number of call sequences
depth = 15           # Calls per sequence
fail_on_revert = false
```

## Fork Testing

### Basic Fork
```solidity
function setUp() public {
    // Fork mainnet at specific block
    vm.createSelectFork("mainnet", 18_000_000);
}

function testFork_SwapOnUniswap() public {
    // Test against real mainnet state
}
```

### Configuration (foundry.toml)
```toml
[rpc_endpoints]
mainnet = "${MAINNET_RPC_URL}"
polygon = "${POLYGON_RPC_URL}"
arbitrum = "${ARBITRUM_RPC_URL}"
```

### Multiple Forks
```solidity
uint256 mainnetFork = vm.createFork("mainnet");
uint256 polygonFork = vm.createFork("polygon");

vm.selectFork(mainnetFork);
// ... test on mainnet

vm.selectFork(polygonFork);
// ... test on polygon
```

## Gas Testing

### Gas Reports
```bash
forge test --gas-report
```

### Gas Snapshots
```solidity
function test_GasUsage() public {
    vm.startSnapshotGas("deposit");
    target.deposit{value: 1 ether}();
    uint256 gasUsed = vm.stopSnapshotGas();

    assertLt(gasUsed, 50000, "Deposit too expensive");
}
```

### Compare Gas Snapshots
```bash
forge snapshot
forge snapshot --diff
```

## Testing Internal Functions

### Harness Pattern
```solidity
contract MyContractHarness is MyContract {
    function exposed_internalFunction(uint256 x) public returns (uint256) {
        return _internalFunction(x);
    }
}

contract MyContractTest is Test {
    MyContractHarness target;

    function setUp() public {
        target = new MyContractHarness();
    }

    function test_InternalFunction() public {
        assertEq(target.exposed_internalFunction(5), 10);
    }
}
```

## Coverage

```bash
# Generate coverage report
forge coverage

# Generate LCOV report for IDE integration
forge coverage --report lcov
```

## Common Pitfalls

1. **Forgetting vm.stopPrank()** - use vm.prank() for single calls when possible
2. **Not bounding fuzz inputs** - always use bound() or vm.assume()
3. **Testing mocks instead of real behavior** - prefer fork tests over mocks
4. **Flaky tests from timestamp/block dependencies** - use vm.warp()/vm.roll() explicitly
5. **Cross-test state pollution** - each test gets fresh setUp(), but watch static variables
6. **Expecting events in wrong order** - vm.expectEmit must be called before the action

## Useful Commands

```bash
# Run all tests
forge test

# Run specific test
forge test --match-test test_Transfer

# Run tests in specific file
forge test --match-path test/MyContract.t.sol

# Verbose output (show logs)
forge test -vvv

# Very verbose (show traces)
forge test -vvvv

# Watch mode
forge test --watch

# Run only failing tests
forge test --rerun
```

## References

- [Foundry Book - Writing Tests](https://getfoundry.sh/guides/best-practices/writing-tests)
- [Foundry Book - Fuzz Testing](https://getfoundry.sh/forge/fuzz-testing)
- [Foundry Book - Invariant Testing](https://getfoundry.sh/forge/advanced-testing/invariant-testing)
- [Foundry Book - Cheatcodes](https://getfoundry.sh/forge/tests/cheatcodes)
