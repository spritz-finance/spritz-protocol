# SpritzRouter Design

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Payment Flows                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Direct Payment:                                                     │
│  User → Router (pull to Core) → Core → Recipient                    │
│                                    ↓                                 │
│                               (emit event)                           │
│                                                                      │
│  Swap Payment:                                                       │
│  User → Router (pull to SwapModule) → SwapModule → Core → Recipient │
│                                           ↓           ↓              │
│                                        (swap)    (emit event)        │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Contracts

### SpritzPayCore (Stable)
- **Purpose**: Stable event emitter, token/recipient registry
- **Indexed by**: Backend systems
- **Upgradeability**: None (deployed via CREATE3 for deterministic address)
- **Owner**: Admin multisig

**Responsibilities:**
- Maintain accepted payment tokens and their recipients
- Receive payment tokens, forward to recipient
- Emit `Payment` event (the source of truth for backend)
- Sweep function for stuck tokens

**Key invariant**: `Payment` event only emits if tokens successfully transferred to recipient.

### SpritzRouter (Swappable)
- **Purpose**: User-facing entry point for payments
- **Upgradeability**: None (deploy new routers as needed)
- **Owner**: Admin multisig (for pause and sweep)
- **Immutables**: `core` (SpritzPayCore address)
- **Configurable**: `swapModule` (owner can update)

**Responsibilities:**
- Pull tokens from users (approve or permit)
- Route to SwapModule for swaps
- Call Core.pay() to complete payment
- Handle native ETH payments
- Sweep function for accidentally sent tokens

### SwapModule (Swappable)
- **Purpose**: Execute swaps via DEX aggregators
- **Upgradeability**: None (deploy new modules as needed)
- **Holds**: Infinite approvals to DEX routers

**Responsibilities:**
- Execute swaps (exact input or exact output)
- Send output tokens to specified recipient (Core)
- Refund excess input tokens to user
- Handle native ETH wrapping/unwrapping

---

## Token Flow Details

### Direct Payment (No Swap)

```
payWithToken(token, amount, reference)
payWithPermit(token, amount, reference, permitData)
payWithPermit2(token, amount, reference, permit2Data)
```

1. Router pulls tokens from User → Core (single transferFrom)
2. Router calls `Core.pay()`
3. Core transfers tokens to Recipient
4. Core emits `Payment` event

**Transfers**: 2 (User→Core, Core→Recipient)

### Swap Payment (Exact Output)

```
payWithSwap(sourceToken, maxInput, exactOutput, reference, deadline, swapData)
payWithSwapPermit(...)
payWithSwapPermit2(...)
```

1. Router pulls source tokens from User → SwapModule
2. Router calls `SwapModule.exactOutputSwap()`
3. SwapModule executes swap, sends exact output to Core
4. SwapModule refunds excess input to User
5. Router calls `Core.pay()`
6. Core transfers tokens to Recipient
7. Core emits `Payment` event

**Transfers**: 4 (User→SwapModule, SwapModule→Core, Core→Recipient, SwapModule→User refund)

### Swap Payment (Exact Input)

```
payWithSwapExactInput(sourceToken, exactInput, minOutput, reference, deadline, swapData)
```

1. Router pulls source tokens from User → SwapModule
2. Router calls `SwapModule.exactInputSwap()`
3. SwapModule executes swap, sends all output to Core
4. Router calls `Core.pay()`
5. Core transfers tokens to Recipient
6. Core emits `Payment` event

**Transfers**: 3 (User→SwapModule, SwapModule→Core, Core→Recipient)

### Native ETH Payment

```
payWithNativeSwap{value: msg.value}(exactOutput, reference, deadline, swapData)
```

1. Router receives ETH, forwards to SwapModule
2. SwapModule wraps ETH → WETH
3. SwapModule executes swap, sends output to Core
4. SwapModule refunds excess ETH to User
5. Router calls `Core.pay()`
6. Core transfers tokens to Recipient
7. Core emits `Payment` event

---

## Interfaces

### ISpritzPayCore

```solidity
interface ISpritzPayCore {
    event Payment(
        address to,
        address indexed from,
        address indexed sourceToken,
        uint256 sourceTokenAmount,
        address paymentToken,
        uint256 paymentTokenAmount,
        bytes32 indexed paymentReference
    );

    /// @notice Process payment - transfer tokens to recipient and emit event
    /// @param caller The original payment sender (for event)
    /// @param paymentToken The token being paid
    /// @param paymentAmount Amount of payment token
    /// @param sourceToken Original token user paid with (may differ if swapped)
    /// @param sourceTokenSpent Amount of source token spent
    /// @param paymentReference Unique payment identifier
    function pay(
        address caller,
        address paymentToken,
        uint256 paymentAmount,
        address sourceToken,
        uint256 sourceTokenSpent,
        bytes32 paymentReference
    ) external;

    /// @notice Check if token is accepted for payments
    function isAcceptedToken(address token) external view returns (bool);

    /// @notice Get recipient address for a payment token
    function paymentRecipient(address token) external view returns (address);
}
```

### ISwapModule

```solidity
interface ISwapModule {
    enum SwapType {
        ExactInput,
        ExactOutput
    }

    struct SwapParams {
        SwapType swapType;
        address to;              // Where to send output tokens (Core)
        address refundTo;        // Where to send excess input (User) - only for ExactOutput
        uint256 inputAmount;     // Exact input OR max input (depending on swapType)
        uint256 outputAmount;    // Min output OR exact output (depending on swapType)
        uint256 deadline;
        bytes swapData;
    }

    struct SwapResult {
        uint256 inputAmountSpent;
        uint256 outputAmountReceived;
    }

    /// @notice Execute swap
    function swap(SwapParams calldata params) external returns (SwapResult memory);

    /// @notice Execute swap with native ETH input
    function swapNative(SwapParams calldata params) external payable returns (SwapResult memory);

    /// @notice Decode swap data to get input/output tokens
    function decodeSwapData(bytes calldata swapData)
        external pure returns (address inputToken, address outputToken);
}
```

### ISpritzRouter

```solidity
interface ISpritzRouter {
    enum SwapType {
        ExactInput,  // User specifies exact input, accepts variable output
        ExactOutput  // User specifies exact output, provides max input
    }

    struct SwapParams {
        SwapType swapType;
        address sourceToken;
        uint256 sourceAmount;     // Exact input OR max input (depending on swapType)
        uint256 paymentAmount;    // Min output OR exact output (depending on swapType)
        uint256 deadline;
        bytes swapData;
    }

    struct PermitData {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // ============ State ============

    function core() external view returns (address);       // immutable
    function swapModule() external view returns (address); // configurable

    // ============ Admin ============

    function setSwapModule(address newSwapModule) external;

    // ============ Direct Payments ============

    /// @notice Pay with pre-approved tokens
    function payWithToken(
        address token,
        uint256 amount,
        bytes32 paymentReference
    ) external;

    /// @notice Pay using EIP-2612 permit
    function payWithPermit(
        address token,
        uint256 amount,
        bytes32 paymentReference,
        PermitData calldata permit
    ) external;

    // ============ Swap Payments ============

    /// @notice Pay with swap (pre-approved tokens)
    function payWithSwap(
        SwapParams calldata swap,
        bytes32 paymentReference
    ) external;

    /// @notice Pay with swap using permit
    function payWithSwapPermit(
        SwapParams calldata swap,
        bytes32 paymentReference,
        PermitData calldata permit
    ) external;

    /// @notice Pay with native ETH swap
    function payWithNativeSwap(
        SwapParams calldata swap,
        bytes32 paymentReference
    ) external payable;

    /// @notice Sweep accidentally sent tokens
    function sweep(address token, address to) external;
}
```

---

## Security Considerations

### SpritzPayCore
- `pay()` is open (anyone can call) - this is intentional for router flexibility
- Safety comes from: transfer succeeds → event emits (atomic)
- Only owner can modify token/recipient config

### SpritzRouter
- Pausable by owner
- Non-custodial (never holds tokens between transactions)
- All token approvals from users, not to router
- Deadline enforcement on all swaps

### SwapModule
- Holds infinite approvals to DEX routers only
- Non-custodial (refunds excess immediately)
- Validates swap outputs match expectations
- DEX router address validation (e.g., Paraswap registry)

---

## Deferred Features

- **Permit2**: Adds complexity, most stablecoins support native permit. Add later if needed.
- **Delegated payments**: Not needed for current use cases.
- **Protocol fees**: Not planned. Can add at router level later if needed.


---

## Implementation Order

1. `ISpritzPayCore` interface (extract from existing)
2. `ISwapModule` interface (add exact input methods)
3. `SpritzRouter` contract
4. Update existing `ParaswapModule` for new interface
5. Tests
6. Deployment scripts (CREATE3 for Core)
