// Compile the WAL protobuf schema with prost at NIF build time.
//
// The schema lives at `priv/proto/code/wal/v1/wal.proto` in the Elixir
// project; it is the same file `scripts/generate-proto.sh` feeds to
// protoc-gen-elixir, so the Rust and Elixir sides share one source of truth.
// If a tag or type changes there, both regenerate.

use std::path::PathBuf;

fn main() -> std::io::Result<()> {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // `native/code_native/` is two levels under the Elixir project root.
    let project_root = crate_dir.parent().unwrap().parent().unwrap();
    let proto_dir = project_root.join("priv/proto");
    let proto_file = proto_dir.join("code/wal/v1/wal.proto");

    println!("cargo:rerun-if-changed={}", proto_file.display());

    prost_build::compile_protos(&[&proto_file], &[&proto_dir])
}
