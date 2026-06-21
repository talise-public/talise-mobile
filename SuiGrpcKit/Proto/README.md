# Sui gRPC Protobuf Definitions (iOS)

Vendored copy of the Sui `sui.rpc.v2` protobuf definitions plus the Google
`protobuf` / `rpc` imports they depend on. This tree is intentionally a
byte-identical duplicate of `web/lib/sui-proto/proto/` so the iOS SDK can
regenerate Swift clients without depending on the web package layout.

## Source

- Upstream repo: `https://github.com/MystenLabs/sui-rust-sdk`
- Upstream path: `crates/sui-rpc/vendored/proto/`
- Pinned revision: `5b41bc701525f1b94f1fe63008d4841bc6fb1065`
  (61 commits past tag `sui-rpc-0.3.1`)
- Matching Sui core release: `mainnet-v1.72.2`
  (the `Cargo.toml` of that release pins `sui-rpc` to this exact rev)
- Matching TS SDK shipped to web: `@mysten/sui@2.16.3`

Historical note: in earlier Sui releases these definitions lived at
`crates/sui-rpc-api/proto/sui/rpc/v2/*.proto` inside `MystenLabs/sui`.
They were extracted into `MystenLabs/sui-rust-sdk`; the canonical source
is now that repo.

## Layout

```
proto/
  google/
    protobuf/{any,duration,empty,field_mask,struct,timestamp}.proto
    rpc/{error_details,status}.proto
  sui/
    rpc/v2/*.proto    # 29 service + message files
```

Total: 39 `.proto` files, ~256 KB on disk.

## Regenerating clients

A `scripts/regen-proto.sh` will be added in the next phase. It will invoke
`protoc` with the `swift` and `grpc-swift` plugins to emit Swift sources
under `ios/Talise/Network/SuiProto/Generated/`.

Expected toolchain:

- `protoc` (>= 25.0)
- `protoc-gen-swift` and `protoc-gen-grpc-swift` from
  `https://github.com/grpc/grpc-swift` (matching the SwiftPM dependency
  version pinned in the Xcode project once the SDK target lands).

## Updating

1. Pick the new Sui core release tag.
2. Look up the `sui-rpc` git rev in that tag's root `Cargo.toml`.
3. Clone `MystenLabs/sui-rust-sdk` at that rev.
4. Replace the contents of `proto/` from `crates/sui-rpc/vendored/proto/`.
5. Update the "Pinned revision" and "Matching Sui core release" lines above.
6. Re-run `scripts/regen-proto.sh`.

Do not edit files under `proto/` by hand.
