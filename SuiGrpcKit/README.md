# SuiGrpcKit

## What it is

SuiGrpcKit is a Swift package that wraps Sui's gRPC API (`sui.rpc.v2.*`)
with a multi-endpoint fallback chain. It was extracted from the
[Talise](https://talise.io) iOS wallet, but it is intentionally generic
— drop it into any iOS 18+ Sui project that needs a fast, typed,
long-lived connection to a Sui fullnode.

The package bundles:

- **`SuiGrpcClient`** — a `@MainActor` gRPC client over HTTP/2 + TLS.
  Reuses one connection for the lifetime of the process. Each RPC has
  an 8s per-request deadline, one automatic retry on
  `UNAVAILABLE`/`DEADLINE_EXCEEDED`, and a one-line `NSLog` telemetry
  record (`[SuiGrpc] <method> ms=<n> result=<ok|error:<code>>`).
- **`SuiEndpoints`** — an ordered registry of mainnet gRPC providers
  (Mysten fullnode + archive, Shinami, Dwellir, QuickNode) and a
  `withFallback` helper that walks the list on transient failures.
- **Pre-generated Swift bindings** for 39 vendored `.proto` files
  pinned to a known-good Sui rev. **Consumers do NOT need `protoc`
  installed** — the generated `.pb.swift` and `.grpc.swift` files are
  committed.

## Requirements

- iOS 18+ (grpc-swift v2 transports require it)
- Xcode 16+
- Swift 5.10+

## Installation

Add SuiGrpcKit to your `Package.swift` dependencies:

```swift
// TODO: replace with the canonical URL once this package is pushed.
.package(url: "https://github.com/SeventhOdyssey71/sui-grpc-kit", from: "0.1.0"),
```

…and add `"SuiGrpcKit"` to your target's `dependencies`. SwiftPM will
pull in the four transitive deps (`grpc-swift-2`,
`grpc-swift-nio-transport`, `grpc-swift-protobuf`, `swift-protobuf`)
automatically.

For an Xcode app target, add the package via **File ▸ Add Package
Dependencies…** and select the `SuiGrpcKit` product.

## Quickstart

```swift
import SuiGrpcKit

// Direct call — uses the shared mainnet client.
let epoch = try await SuiGrpcClient.shared.getLatestEpoch()
print("epoch=\(epoch.epoch) rgp=\(epoch.referenceGasPrice)")

// Or with the multi-endpoint fallback wrapper:
let rgp = try await SuiEndpoints.withFallback { client in
    try await client.getReferenceGasPrice()
}

// Fetch a balance.
let bal = try await SuiGrpcClient.shared.getBalance(
    address: "0x…",
    coinType: "0x2::sui::SUI"
)

// Submit a signed transaction. `transactionBcs` is the BCS-encoded
// TransactionData; `signatures` are BCS-encoded user signatures
// (flag||sig||pubkey for ed25519, or the multisig/zkLogin envelope).
let resp = try await SuiGrpcClient.shared.executeTransaction(
    transactionBcs: txBcs,
    signatures: [sigBcs]
)
```

## API reference

`SuiGrpcClient` (singleton via `.shared`, all methods are
`@MainActor`-isolated):

| Method | Returns | Notes |
| --- | --- | --- |
| `getLatestEpoch()` | `Sui_Rpc_V2_Epoch` | Full Epoch struct (epoch number, RGP, committee, system_state). |
| `getReferenceGasPrice()` | `UInt64` | Convenience wrapper over `getLatestEpoch`. |
| `getBalance(address:coinType:)` | `Sui_Rpc_V2_Balance` | Total balance of one coin type for one owner. |
| `executeTransaction(transactionBcs:signatures:)` | `Sui_Rpc_V2_ExecuteTransactionResponse` | Submits a signed transaction; returns effects + events. |

Every call goes through a `withRetry(_:_:)` helper that applies:

- **Timeout**: 8s per attempt (`CallOptions.timeout = .seconds(8)`).
- **Retry**: exactly one retry on `RPCError.code == .deadlineExceeded`
  or `.unavailable`. Non-transient errors propagate immediately.
- **Telemetry**: one `NSLog` line per call with method, elapsed
  milliseconds, and result (`ok`, `retry:<code>`, or `error:<code>`).

The connection is opened lazily on the first call and lives for the
process lifetime — there is no public shutdown hook.

## Endpoint fallback chain

`SuiEndpoints.mainnetGrpcEndpoints` is the ordered registry. It is
biased toward (a) free + already-default first, then (b) paid
providers where a key may be present:

1. `https://fullnode.mainnet.sui.io:443` — Mysten, free, default.
2. `https://archive.mainnet.sui.io:443` — Mysten archive, free.
3. `https://api.us1.shinami.com/sui/node/v1` — Shinami (requires
   `X-Api-Key` from Keychain item `talise.sui.shinami.apiKey`).
4. `https://api-sui-mainnet-full.n.dwellir.com:443` — Dwellir
   (requires `x-api-key` from `talise.sui.dwellir.apiKey`).
5. QuickNode — token baked into the URL; the full URL is stored in
   Keychain item `talise.sui.quicknode.url`.

`SuiEndpoints.withFallback { client in … }` walks the list, skipping
auth-required endpoints whose Keychain key is missing. On a
fallback-eligible error (`isFallbackEligible(_:)` matches
`UNAVAILABLE`, `DEADLINE_EXCEEDED`, or transport-layer 502/503/504
messages) it moves to the next endpoint. The first success returns;
otherwise the last error is thrown.

> **Note**: today the wrapper always routes to `SuiGrpcClient.shared`
> because the initializer is `private`. Widening it to accept a
> per-endpoint URL + header bag is a small follow-up — the registry
> scaffolding is ready.

## Regenerating proto bindings

The 40 generated Swift files under `Sources/SuiGrpcKit/Generated/`
are committed so consumers don't need `protoc`. To refresh them
against a newer Sui release:

```sh
brew install protobuf protoc-gen-grpc-swift
cd ios/SuiGrpcKit
./Scripts/regen-proto.sh
```

The script:

1. Builds a pinned `protoc-gen-swift` (1.31.2) from source on first run
   into `.toolchain/` (the latest swift-protobuf emits Swift 6.2 syntax
   incompatible with Xcode 16.2).
2. Wipes `Sources/SuiGrpcKit/Generated/` and regenerates from
   `Proto/sui/rpc/v2/*.proto` plus `Proto/google/rpc/*.proto`. The
   `google/protobuf/*` well-known types are *not* regenerated — they
   ship inside the SwiftProtobuf runtime.

See `Proto/README.md` for the upstream pin (Sui core release rev) and
the procedure for bumping it.

## Testing

```sh
cd ios/SuiGrpcKit
swift test
```

Caveats:

- The tests are **integration-style** and hit live mainnet
  (`fullnode.mainnet.sui.io:443`). A flake usually means the network
  or fullnode is unhappy, not that the client is broken.
- `swift test` from the command line uses the host platform's Swift
  toolchain; for true on-device execution run via `xcodebuild test
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.x'`.
- Pre-iOS-18 simulators are skipped automatically via `XCTSkip`.

## License

[Apache License 2.0](./LICENSE). See `LICENSE` for the full text.

## Acknowledgements

- **MystenLabs** for the upstream `.proto` definitions
  ([sui-rust-sdk](https://github.com/MystenLabs/sui-rust-sdk)) — the
  vendored files under `Proto/` are byte-identical copies, kept here
  for reproducible regeneration.
- **Apple grpc-swift v2** for the Swift gRPC runtime + codegen plugins.
- **Talise** for being the host project this was extracted from.
