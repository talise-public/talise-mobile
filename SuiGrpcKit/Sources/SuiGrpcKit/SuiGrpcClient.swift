// SuiGrpcClient.swift
//
// gRPC client for Sui fullnode (sui.rpc.v2.*) built on grpc-swift v2.
// Method bodies were filled in by sub-plans 3.4–3.7; retry + timeout +
// telemetry come from sub-plan 3.10.
//
// grpc-swift v2 requires iOS 18+ / macOS 15+. As of sub-plan 5.6 the
// app's deployment target is iOS 18.0, so this type is unconditionally
// available — the legacy JSON-RPC fallback that lived in
// ZkLoginCoordinator has been removed.

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import SwiftProtobuf

@MainActor
public final class SuiGrpcClient {
    // NOTE: this stays on the DIRECT Sui fullnode — do NOT point it at Hayabusa.
    // Hayabusa is a gRPC-WEB proxy (application/grpc-web+proto, grpc-status in
    // headers), but grpc-swift's HTTP2ClientTransport speaks NATIVE gRPC
    // (application/grpc + HTTP/2 trailers) — the two are wire-incompatible, so
    // routing here through Hayabusa would break every call. The web backend
    // already proxies its gRPC-Web reads through Hayabusa, so the app's
    // API-mediated data is accelerated there; only iOS's few DIRECT gRPC reads
    // use this fullnode. (See docs/integrations/hayabusa.md.)
    public static let shared = SuiGrpcClient(host: "fullnode.mainnet.sui.io", port: 443)

    private let host: String
    private let port: Int

    /// Per-request deadline. Matches the JSON-RPC fallback's 8s budget.
    private let perRequestTimeout: Duration = .seconds(8)

    // MARK: - Channel lifecycle (lazy, long-lived)
    //
    // The first call opens an `HTTP2ClientTransport.Posix` to the mainnet
    // fullnode and spawns a detached Task running `client.runConnections()`
    // — that task owns the connection for the rest of the process lifetime.
    // Subsequent calls reuse the same `GRPCClient`. There is no public
    // shutdown hook; the OS reclaims it when the app exits.

    private var grpcClient: GRPCClient<HTTP2ClientTransport.Posix>?
    private var connectionTask: Task<Void, Never>?

    private init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    private func client() throws -> GRPCClient<HTTP2ClientTransport.Posix> {
        if let c = grpcClient { return c }
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: port),
            transportSecurity: .tls
        )
        let c = GRPCClient(transport: transport)
        grpcClient = c
        connectionTask = Task.detached(priority: .utility) {
            // runConnections() returns only on graceful shutdown; we never
            // shut down, so this Task lives for the lifetime of the app.
            try? await c.runConnections()
        }
        return c
    }

    // MARK: - Retry / timeout / telemetry

    /// Single retry on transient failures (DEADLINE_EXCEEDED, UNAVAILABLE)
    /// with an 8s per-attempt timeout. Logs one NSLog line per call:
    ///   `[SuiGrpc] <method> ms=<n> result=<ok|error:<code>>`
    private func withRetry<T>(
        _ method: String,
        _ body: (CallOptions) async throws -> T
    ) async throws -> T {
        var options = CallOptions.defaults
        options.timeout = perRequestTimeout

        let start = DispatchTime.now().uptimeNanoseconds
        func elapsedMs() -> Int {
            Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
        }

        do {
            let result = try await body(options)
            NSLog("[SuiGrpc] %@ ms=%d result=ok", method, elapsedMs())
            return result
        } catch let err as RPCError where err.code == .deadlineExceeded || err.code == .unavailable {
            NSLog("[SuiGrpc] %@ ms=%d result=retry:%@", method, elapsedMs(), String(describing: err.code))
            do {
                let result = try await body(options)
                NSLog("[SuiGrpc] %@ ms=%d result=ok", method, elapsedMs())
                return result
            } catch let err2 as RPCError {
                NSLog("[SuiGrpc] %@ ms=%d result=error:%@", method, elapsedMs(), String(describing: err2.code))
                throw err2
            } catch {
                NSLog("[SuiGrpc] %@ ms=%d result=error:%@", method, elapsedMs(), String(describing: error))
                throw error
            }
        } catch let err as RPCError {
            NSLog("[SuiGrpc] %@ ms=%d result=error:%@", method, elapsedMs(), String(describing: err.code))
            throw err
        } catch {
            NSLog("[SuiGrpc] %@ ms=%d result=error:%@", method, elapsedMs(), String(describing: error))
            throw error
        }
    }

    // MARK: - RPCs

    /// LedgerService.GetEpoch — current epoch (no `epoch` field on request
    /// means "latest"). Returns the full Epoch (includes referenceGasPrice,
    /// committee, system_state, etc.) so 3.5 can reuse the same call.
    /// Implemented by sub-plan 3.4.
    public func getLatestEpoch() async throws -> Sui_Rpc_V2_Epoch {
        let client = try client()
        let ledger = Sui_Rpc_V2_LedgerService.Client(wrapping: client)
        let req = Sui_Rpc_V2_GetEpochRequest()
        return try await withRetry("GetEpoch") { options in
            try await ledger.getEpoch(req, options: options) { response in
                try response.message.epoch
            }
        }
    }

    /// Reference gas price for the current epoch.
    /// Implemented by sub-plan 3.5.
    public func getReferenceGasPrice() async throws -> UInt64 {
        let epoch = try await getLatestEpoch()
        return epoch.referenceGasPrice
    }

    /// StateService.GetBalance — total balance of one coin type for one owner.
    /// Implemented by sub-plan 3.6.
    public func getBalance(address: String, coinType: String) async throws -> Sui_Rpc_V2_Balance {
        let client = try client()
        let state = Sui_Rpc_V2_StateService.Client(wrapping: client)
        var req = Sui_Rpc_V2_GetBalanceRequest()
        req.owner = address
        req.coinType = coinType
        return try await withRetry("GetBalance") { options in
            try await state.getBalance(req, options: options) { response in
                try response.message.balance
            }
        }
    }

    /// TransactionExecutionService.ExecuteTransaction — submit a signed
    /// transaction. `transactionBcs` is the raw BCS-encoded TransactionData;
    /// `signatures` are raw BCS-encoded user signatures (flag||sig||pubkey
    /// for ed25519, or the multisig/zkLogin envelope).
    /// Implemented by sub-plan 3.7.
    public func executeTransaction(
        transactionBcs: Data,
        signatures: [Data]
    ) async throws -> Sui_Rpc_V2_ExecuteTransactionResponse {
        let client = try client()
        let exec = Sui_Rpc_V2_TransactionExecutionService.Client(wrapping: client)

        var txBcs = Sui_Rpc_V2_Bcs()
        txBcs.name = "TransactionData"
        txBcs.value = transactionBcs

        var tx = Sui_Rpc_V2_Transaction()
        tx.bcs = txBcs

        let userSigs: [Sui_Rpc_V2_UserSignature] = signatures.map { sig in
            var bcs = Sui_Rpc_V2_Bcs()
            bcs.name = "UserSignature"
            bcs.value = sig
            var us = Sui_Rpc_V2_UserSignature()
            us.bcs = bcs
            return us
        }

        var req = Sui_Rpc_V2_ExecuteTransactionRequest()
        req.transaction = tx
        req.signatures = userSigs

        return try await withRetry("ExecuteTransaction") { options in
            try await exec.executeTransaction(req, options: options) { response in
                try response.message
            }
        }
    }
}
