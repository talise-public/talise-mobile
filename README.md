<div align="center">

# Talise Mobile

**Money that moves like a message.**

The native iOS app for Talise: a gasless US dollar account on Sui that sends by name, settles in under a second, and keeps the amount private.

[Website](https://talise.io) · [iOS app (TestFlight)](https://testflight.apple.com/join/BFNEPYtM) · [Frontend](https://github.com/talise-public/talise-frontend) · [Contracts](https://github.com/talise-public/talise-contracts) · [Docs](https://github.com/talise-public/talise-docs)

</div>

---

## What this is

The Talise iOS client, written in Swift and SwiftUI. It signs in with Google through zkLogin, holds dollars as USDsui, sends to a `name@talise.sui` handle, and runs the private-send flow on device. It talks to Sui over gRPC through the bundled `SuiGrpcKit` package and to the Talise API for sponsored signing.

## What it does

- **zkLogin sign in.** Google account to self-custodial Sui wallet, no seed phrase.
- **Gasless sends.** Sponsored transactions, the user never holds a gas token. Settles in under a second.
- **Send by name.** Pay `name@talise.sui` instead of a 0x address.
- **Private send.** Shielded transfer with the amount hidden on chain.
- **Token bucket.** A swipeable home card opens the tokens you hold besides USDsui (with logos and balances), each with a Send action and a Swap-to-USDsui action.
- **Cheques and streaming.** Claimable links and streamed value, native.
- **Ramps.** Add money and cash out to a bank.

## Architecture

```
Talise/
  App/          App entry, root coordinator, configuration
  Auth/         zkLogin coordinator (ephemeral key, proof cache, sign + submit)
  Features/     Home, Send, Withdraw (incl. private send + token bucket), Scan, Cheques
  Network/      APIClient, models, app attestation
  DesignSystem/ Colors, typography, components (the dark/mint design language)
  Resources/    Assets, entitlements, Info.plist
SuiGrpcKit/     Local Swift package: Sui gRPC client and generated protos
project.yml     XcodeGen spec (the .xcodeproj is generated, not committed)
```

## How it integrates with Sui

- **zkLogin on device:** an ephemeral key signs the transaction intent; the proof and salt assemble the zkLogin signature.
- **Sponsored sends:** the app signs its half and the gas-sponsorship service pays gas, so sends are gasless.
- **gRPC:** `SuiGrpcKit` is the on-device Sui client for reads and submission.
- **SuiNS:** handles resolve to addresses for send-by-name.

## Build

The Xcode project is generated from `project.yml` with XcodeGen, so the build is reproducible and the generated `.xcodeproj` is not committed.

```bash
brew install xcodegen
xcodegen generate
open Talise.xcodeproj
```

Select the `Talise` scheme and run on a device or simulator. Signing uses your own Apple developer team.

## Security

- No secrets are committed. API base URLs and identifiers are configuration, not keys.
- Money-path requests carry App Attest assertions.
- Build artifacts (`build/`, DerivedData) and the generated project are gitignored.

## License

MIT. See [LICENSE](./LICENSE).
