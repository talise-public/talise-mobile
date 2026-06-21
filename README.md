<div align="center">

# Talise Mobile

**Money that moves like a message.**

The native iOS app for Talise: a gasless US dollar account on Sui that sends by name, settles in under a second, and keeps the amount private.

[Live app](https://app.talise.io) · [Frontend](https://github.com/talise-public/talise-frontend) · [Contracts](https://github.com/talise-public/talise-contracts) · [Docs](https://github.com/talise-public/talise-docs)

</div>

---

## What this is

The Talise iOS client, written in Swift and SwiftUI. It signs in with Google through zkLogin, holds dollars as USDsui, sends to a `name@talise.sui` handle, and runs the private-send flow on device. It talks to Sui over gRPC through the bundled `SuiGrpcKit` package.

## Highlights

- **zkLogin sign in.** Google account to self-custodial Sui wallet, no seed phrase.
- **Gasless sends.** Sponsored transactions, the user never holds a gas token.
- **Send by name.** Pay `name@talise.sui` instead of a 0x address.
- **Private send.** Shielded transfer with the amount hidden on chain.
- **Cheques and streaming.** Claim links and streamed value, native.

## Stack

- Swift and SwiftUI, targeting iOS
- `SuiGrpcKit`, a local Swift package with generated Sui gRPC bindings
- zkLogin for identity, a sponsored-gas station for fees

## Project layout

```
Talise/        App sources (Features/, Auth/, Network/, Resources/)
SuiGrpcKit/    Local Swift package: Sui gRPC client and generated protos
project.yml    XcodeGen spec (the .xcodeproj is generated, not committed)
```

## Build

The Xcode project is generated from `project.yml` with XcodeGen, so the build is reproducible and the generated `.xcodeproj` is not committed.

```bash
brew install xcodegen
cd ios   # if cloned standalone, run from the repo root
xcodegen generate
open Talise.xcodeproj
```

Then select the `Talise` scheme and run on a device or simulator. Signing uses your own Apple developer team.

## Security

- No secrets are committed. API base URLs and identifiers are configuration, not keys.
- Build artifacts (`build/`, DerivedData) and the generated project are gitignored.

## License

MIT. See [LICENSE](./LICENSE).
