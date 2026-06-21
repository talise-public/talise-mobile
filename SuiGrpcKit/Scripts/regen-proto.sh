#!/usr/bin/env bash
# Regenerates Swift bindings for the vendored Sui gRPC protobuf
# definitions under SuiGrpcKit/Proto/.
#
# Outputs to SuiGrpcKit/Sources/SuiGrpcKit/Generated/, mirroring the
# Proto/ directory structure (flattened with `FileNaming=PathToUnderscores`).
#
# Idempotent: running this twice produces byte-identical output. The
# entire Generated/ tree is rewritten on each run so stale files never
# linger.
#
# Pinned toolchain (intentionally older than what `brew` ships):
#
#   - protoc                  brew protobuf >= 25, tested with libprotoc 35.0
#   - protoc-gen-swift        1.31.2 — pinned to a release that predates
#                                       SE-0449 `nonisolated <typedecl>` syntax,
#                                       so the generated code compiles under
#                                       Xcode 16.2 / Swift 6.0.3. Built from
#                                       source on first run into
#                                       `ios/.toolchain/protoc-gen-swift-1.31.2`.
#   - protoc-gen-grpc-swift-2 brew protoc-gen-grpc-swift 2.4.0 — emits gRPC
#                                       v2 client stubs (no nonisolated issue).
#
# Why the from-source pin for protoc-gen-swift?
#   `brew install swift-protobuf` currently provides 1.38.0, whose output
#   uses `public nonisolated struct …` syntax that requires the Swift 6.2
#   compiler. Until Xcode 16.3+ is the project's baseline we generate
#   against 1.31.2 (Swift 5.10–6.0 compatible).

set -euo pipefail

PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_ROOT="$PKG_ROOT/Proto"
OUT_ROOT="$PKG_ROOT/Sources/SuiGrpcKit/Generated"
TOOLCHAIN_ROOT="$PKG_ROOT/.toolchain"

PINNED_SWIFT_PROTOBUF_TAG="1.31.2"
PINNED_SWIFT_PROTOBUF_DIR="$TOOLCHAIN_ROOT/swift-protobuf-${PINNED_SWIFT_PROTOBUF_TAG}"
PINNED_SWIFT_PROTOBUF_BIN="$PINNED_SWIFT_PROTOBUF_DIR/.build/release/protoc-gen-swift"

PROTOC="$(command -v protoc || true)"
PROTOC_GEN_GRPC_SWIFT="$(command -v protoc-gen-grpc-swift-2 || true)"

if [[ -z "$PROTOC" ]]; then
  echo "error: protoc not found. Install with: brew install protobuf" >&2
  exit 1
fi

if [[ -z "$PROTOC_GEN_GRPC_SWIFT" ]]; then
  echo "error: protoc-gen-grpc-swift-2 not found. Install with: brew install protoc-gen-grpc-swift" >&2
  exit 1
fi

# Build the pinned protoc-gen-swift on first run, cache it under
# ios/.toolchain/. Subsequent runs reuse the cached binary; building
# from source is a one-time ~45s cost.
if [[ ! -x "$PINNED_SWIFT_PROTOBUF_BIN" ]]; then
  echo "regen-proto: building protoc-gen-swift ${PINNED_SWIFT_PROTOBUF_TAG} from source (one-time)..."
  mkdir -p "$TOOLCHAIN_ROOT"
  if [[ ! -d "$PINNED_SWIFT_PROTOBUF_DIR" ]]; then
    git clone --quiet --depth 1 --branch "$PINNED_SWIFT_PROTOBUF_TAG" \
      https://github.com/apple/swift-protobuf "$PINNED_SWIFT_PROTOBUF_DIR"
  fi
  (cd "$PINNED_SWIFT_PROTOBUF_DIR" && swift build -c release --product protoc-gen-swift > /dev/null)
fi

if [[ ! -x "$PINNED_SWIFT_PROTOBUF_BIN" ]]; then
  echo "error: failed to produce $PINNED_SWIFT_PROTOBUF_BIN" >&2
  exit 1
fi

PROTOC_GEN_SWIFT="$PINNED_SWIFT_PROTOBUF_BIN"

# Surface the resolved toolchain for the regeneration record.
echo "regen-proto: protoc       = $($PROTOC --version)"
echo "regen-proto: swift plugin = $($PROTOC_GEN_SWIFT --version 2>&1 | head -1) ($PROTOC_GEN_SWIFT)"
echo "regen-proto: grpc plugin  = $($PROTOC_GEN_GRPC_SWIFT --version 2>&1 | head -1) ($PROTOC_GEN_GRPC_SWIFT)"

# Wipe the output dir so removals propagate.
rm -rf "$OUT_ROOT"
mkdir -p "$OUT_ROOT"

# Collect all .proto files under proto/ for codegen, EXCLUDING the
# google/protobuf/ well-known types — those ship inside the SwiftProtobuf
# runtime under names like `SwiftProtobuf.Google_Protobuf_Timestamp` and
# don't need to be regenerated into user code. (The 1.31.2 plugin emits
# them in `bundled-in-the-runtime` mode without an `import SwiftProtobuf`,
# which produces unresolved references.)
# google/rpc/* are *not* well-known and must be generated.
#
# Sort for deterministic invocation order (which protoc honors). bash 3.2
# on macOS lacks mapfile/readarray, so we read the find output into a
# newline-separated string and let word-splitting expand it (safe because
# vendored proto paths never contain whitespace).
PROTO_FILES_LIST="$(cd "$PROTO_ROOT" && find . -name "*.proto" -type f \
  -not -path "./google/protobuf/*" | sort)"

if [[ -z "$PROTO_FILES_LIST" ]]; then
  echo "error: no .proto files found under $PROTO_ROOT" >&2
  exit 1
fi

# Generate message types for every .proto. Visibility=Public so the
# generated types are usable from outside the SuiProto subdirectory.
# FileNaming=PathToUnderscores flattens nested dirs into a single
# Generated/ output (e.g. sui/rpc/v2/foo.proto -> sui_rpc_v2_foo.pb.swift)
# which avoids xcodegen having to recurse into sub-groups.
# shellcheck disable=SC2086
(cd "$PROTO_ROOT" && "$PROTOC" \
  --proto_path=. \
  --plugin="protoc-gen-swift=$PROTOC_GEN_SWIFT" \
  --swift_out="$OUT_ROOT" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=PathToUnderscores \
  $PROTO_FILES_LIST)

# Generate gRPC v2 client stubs only for the sui/rpc/v2 service files.
# google/ deps are message-only — no services there.
SERVICE_FILES_LIST="$(cd "$PROTO_ROOT" && find sui -name "*_service.proto" -type f | sort)"

if [[ -n "$SERVICE_FILES_LIST" ]]; then
  # shellcheck disable=SC2086
  (cd "$PROTO_ROOT" && "$PROTOC" \
    --proto_path=. \
    --plugin="protoc-gen-grpc-swift-2=$PROTOC_GEN_GRPC_SWIFT" \
    --grpc-swift-2_out="$OUT_ROOT" \
    --grpc-swift-2_opt=Visibility=Public \
    --grpc-swift-2_opt=Client=true \
    --grpc-swift-2_opt=Server=false \
    --grpc-swift-2_opt=FileNaming=PathToUnderscores \
    $SERVICE_FILES_LIST)
fi

echo "regen-proto: wrote $(find "$OUT_ROOT" -name "*.swift" | wc -l | tr -d ' ') Swift files to $OUT_ROOT"
