// SuiGrpcClientTests.swift
//
// XCTests for SuiGrpcClient (Cohort 3 sub-plans 3.4–3.10; covered here
// per plans 3.9 + 4.8).
//
// SuiGrpcClient itself is gated @available(iOS 18.0, *) because grpc-swift
// v2 transports require iOS 18. The app's deployment target is iOS 17, so
// every test below:
//   - has @available(iOS 18.0, *) on the test method (or guards inline)
//   - calls XCTSkipUnless / a runtime #available so iOS 17 simulators skip
//     cleanly rather than fail.
//
// These tests hit live mainnet (fullnode.mainnet.sui.io:443). They are
// integration-style: a flake means the network or fullnode is unhappy,
// not that the client is broken. Tolerate that via generous timeouts and
// by also accepting RPCError responses where a not-found / invalid input
// is semantically acceptable (e.g. invalid address).

import XCTest
import GRPCCore
@testable import SuiGrpcKit

final class SuiGrpcClientTests: XCTestCase {

    // 8s per call + 1 retry + slop. SuiGrpcClient's per-request budget is
    // 8s; one retry doubles that ceiling.
    private let liveCallTimeout: TimeInterval = 20

    override func setUp() async throws {
        try await super.setUp()
        // Skip whole class on pre-iOS-18 sims/devices — SuiGrpcClient
        // simply doesn't exist there.
        if #available(iOS 18.0, *) {
            // ok
        } else {
            throw XCTSkip("SuiGrpcClient requires iOS 18+; current OS is older. Skipping live gRPC tests.")
        }
    }

    // MARK: - getLatestEpoch

    func testGetLatestEpoch_returnsCurrentEpoch() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Requires iOS 18.")
        }
        let epoch = try await SuiGrpcClient.shared.getLatestEpoch()
        // Mainnet has been past epoch 1 for years; >0 is the meaningful
        // assertion. (As of late 2026 mainnet is ~epoch 700.)
        XCTAssertGreaterThan(epoch.epoch, 0, "Mainnet epoch should be > 0; got \(epoch.epoch)")
        XCTAssertGreaterThan(epoch.referenceGasPrice, 0,
            "Reference gas price should be > 0; got \(epoch.referenceGasPrice)")
    }

    // MARK: - getReferenceGasPrice

    func testGetReferenceGasPrice_returnsPositive() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Requires iOS 18.")
        }
        let gas = try await SuiGrpcClient.shared.getReferenceGasPrice()
        XCTAssertGreaterThan(gas, 0, "RGP should be > 0; got \(gas)")
        // Sanity bound: mainnet RGP has historically been in the
        // hundreds to low thousands of MIST. Allow a wide ceiling so a
        // legitimate validator vote upshift doesn't flake the test.
        XCTAssertLessThan(gas, 1_000_000, "RGP looks unreasonably high: \(gas)")
    }

    // MARK: - getBalance

    /// 0x0...0005 is the SuiSystemState object id. It's not an EOA and
    /// doesn't own SUI in the normal sense — but GetBalance over an
    /// address-shaped string should still return a Balance struct with
    /// balance == "0" (or, at worst, succeed with whatever the node
    /// returns). Either way the call must not throw.
    func testGetBalance_systemStateObject_zero() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Requires iOS 18.")
        }
        let addr = "0x0000000000000000000000000000000000000000000000000000000000000005"
        let balance = try await SuiGrpcClient.shared.getBalance(
            address: addr,
            coinType: "0x2::sui::SUI"
        )
        // The response is a Sui_Rpc_V2_Balance; whatever it carries, the
        // call should have succeeded. coinType should round-trip.
        XCTAssertFalse(balance.coinType.isEmpty,
            "Returned Balance should carry a coinType")
    }

    /// A garbage address should be rejected by the fullnode with an
    /// RPCError (typically INVALID_ARGUMENT). We don't assert a specific
    /// code — different fullnode versions map this differently — only
    /// that *some* RPCError surfaces (i.e. it doesn't succeed silently).
    func testGetBalance_invalidAddress_throws() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Requires iOS 18.")
        }
        do {
            _ = try await SuiGrpcClient.shared.getBalance(
                address: "not-an-address",
                coinType: "0x2::sui::SUI"
            )
            XCTFail("Expected RPCError for malformed address, but call succeeded.")
        } catch let err as RPCError {
            // Good — surfaced as a typed gRPC error. Any RPCError thrown
            // by the call is sufficient evidence the malformed address
            // didn't silently succeed. We deliberately don't lock to a
            // specific code (fullnode versions map this differently:
            // INVALID_ARGUMENT, NOT_FOUND, INTERNAL, …).
            //
            // Print the code so a CI failure has context.
            print("[SuiGrpcClientTests] invalid-address RPCError code=\(err.code) message=\(err.message)")
        } catch {
            XCTFail("Expected RPCError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Retry / telemetry smoke test

    /// We don't intercept NSLog (fiddly on Darwin); instead we verify the
    /// end-to-end call completes well under our retry+timeout ceiling.
    /// If the telemetry path were wedging the call, this would time out.
    func testRetryAndTelemetry_completesWithinBudget() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Requires iOS 18.")
        }
        let start = Date()
        _ = try await SuiGrpcClient.shared.getReferenceGasPrice()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, liveCallTimeout,
            "getReferenceGasPrice should complete in <\(liveCallTimeout)s; took \(elapsed)s")
    }
}
