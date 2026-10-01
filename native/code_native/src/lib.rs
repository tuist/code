// WAL encode/decode NIF.
//
// The one-line summary: `Code.Wal.V1.Index` and `Code.Wal.V1.Entry` are the
// two protobuf messages the project encodes and decodes on every push and
// every replica serve. The pure-Elixir implementation is correct and uses
// the generated structs directly, but it allocates sub-binaries aggressively
// and spends between 10 μs (small repo) and 15 ms (busy monorepo) per call.
// This NIF runs the same proto schema through `prost` and returns the exact
// same Elixir struct, which keeps the Elixir side oblivious.
//
// Boundary rules:
//   * We never buffer anything bigger than the message itself. Protobuf
//     messages are small by construction: `V1.Index` tops out at tens of MB
//     for the busiest monorepo imagined; `V1.Entry` is bounded by one push.
//     Packfile bytes do not pass through here, so the "never buffer a pack"
//     invariant is untouched.
//   * Large messages are scheduled on `DirtyCpu` so they do not block a
//     scheduler. The threshold is a byte-size estimate the Elixir caller
//     computes once; see `Code.Native`.
//   * Panics abort (Cargo.toml); unwinding across the NIF boundary would
//     tear a scheduler down halfway through a decode.

use std::collections::HashMap;

use prost::Message;
use rustler::{Atom, Binary, Encoder, Env, NewBinary, NifResult, NifStruct, Term};

pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/code.wal.v1.rs"));
}

rustler::atoms! {
    ok,
    error,
    malformed_index,
    malformed_entry,

    // Returned when the NIF decoded a value whose re-encoding is shorter than
    // the input — meaning the input carried fields prost does not know about.
    // Rather than silently drop them (which would violate the WAL's
    // forward-compatibility invariant during a mixed-version rollout), the
    // Elixir caller falls back to the pure-Elixir decoder, which preserves
    // unknown wire fields in `__unknown_fields__`.
    fallback_elixir,

    // Enum values for `code.wal.v1.EntryType`. The atom names match the
    // elixir-protobuf generated identifiers exactly; the function names are
    // lowercase for Rust style, mapped to the SCREAMING_SNAKE_CASE atom
    // strings here.
    entry_type_unspecified = "ENTRY_TYPE_UNSPECIFIED",
    entry_type_push = "ENTRY_TYPE_PUSH",
    entry_type_symref = "ENTRY_TYPE_SYMREF",
    entry_type_create = "ENTRY_TYPE_CREATE",
}

// A proto enum field as it sits in an Elixir struct.
//
// elixir-protobuf's decoder emits the atom for a known value and the raw
// integer for anything else — that is how it stays forward-compatible when
// a future node writes an enum value this one does not know about. We mirror
// that: an `EnumValue` holds the wire integer, and encodes back to the atom
// when it is known, to the integer when it is not.
#[derive(Clone, Copy, Debug)]
pub struct EnumValue(i32);

impl EnumValue {
    #[inline]
    fn from_atom(a: Atom) -> Option<Self> {
        if a == entry_type_push() {
            Some(EnumValue(1))
        } else if a == entry_type_symref() {
            Some(EnumValue(2))
        } else if a == entry_type_create() {
            Some(EnumValue(3))
        } else if a == entry_type_unspecified() {
            Some(EnumValue(0))
        } else {
            None
        }
    }

    #[inline]
    fn as_atom(self) -> Option<Atom> {
        match self.0 {
            0 => Some(entry_type_unspecified()),
            1 => Some(entry_type_push()),
            2 => Some(entry_type_symref()),
            3 => Some(entry_type_create()),
            _ => None,
        }
    }
}

impl From<i32> for EnumValue {
    #[inline]
    fn from(v: i32) -> Self {
        EnumValue(v)
    }
}
impl From<EnumValue> for i32 {
    #[inline]
    fn from(v: EnumValue) -> i32 {
        v.0
    }
}

impl<'a> rustler::Decoder<'a> for EnumValue {
    fn decode(term: Term<'a>) -> rustler::NifResult<Self> {
        if let Ok(a) = term.decode::<Atom>() {
            EnumValue::from_atom(a).ok_or(rustler::Error::BadArg)
        } else if let Ok(i) = term.decode::<i32>() {
            Ok(EnumValue(i))
        } else {
            Err(rustler::Error::BadArg)
        }
    }
}

impl rustler::Encoder for EnumValue {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self.as_atom() {
            Some(a) => rustler::Encoder::encode(&a, env),
            None => rustler::Encoder::encode(&self.0, env),
        }
    }
}

// ---------------------------------------------------------------------------
// Mirror structs for the Elixir side.
//
// Field names match the elixir-protobuf-generated struct one for one. The
// `module = "..."` attribute tags each struct with its Elixir module so a
// term produced here is the same struct the pure-Elixir code produces.

// elixir-protobuf 0.13's generated structs include two meta fields:
// `__unknown_fields__` holds unknown wire fields across a roundtrip, and
// `__protobuf__` tags the module as protobuf-defined. Nothing in the project
// reads either, but we populate them anyway so a struct returned from the
// NIF compares equal to one produced by `V1.X.decode/1` under `==`. The
// unknown-fields list is always empty here because prost drops unknown
// fields rather than preserving them.
type UnknownFields = Vec<i64>;

#[derive(NifStruct, Clone, Debug, Default)]
#[module = "Code.Wal.V1.Pack"]
pub struct ElPack {
    pub key: String,
    pub size: u64,
    pub digest: String,
    pub __unknown_fields__: UnknownFields,
    pub __protobuf__: bool,
}

#[derive(NifStruct, Clone, Debug, Default)]
#[module = "Code.Wal.V1.RefCommand"]
pub struct ElRefCommand {
    // `ref` is a Rust keyword; the raw identifier form keeps the atom name
    // intact after NifStruct's stringify.
    pub r#ref: String,
    pub old_oid: String,
    pub new_oid: String,
    pub __unknown_fields__: UnknownFields,
    pub __protobuf__: bool,
}

#[derive(NifStruct, Clone, Debug, Default)]
#[module = "Code.Wal.V1.Actor"]
pub struct ElActor {
    pub account: String,
    pub subject: String,
    pub node: String,
    pub remote_addr: String,
    pub __unknown_fields__: UnknownFields,
    pub __protobuf__: bool,
}

#[derive(NifStruct, Clone, Debug)]
#[module = "Code.Wal.V1.Entry"]
pub struct ElEntry {
    pub r#type: EnumValue,
    pub commands: Vec<ElRefCommand>,
    pub packs: Vec<ElPack>,
    pub symrefs: HashMap<String, String>,
    pub actor: Option<ElActor>,
    pub at_ms: i64,
    pub __unknown_fields__: UnknownFields,
    pub __protobuf__: bool,
}

#[derive(NifStruct, Clone, Debug)]
#[module = "Code.Wal.V1.EntryPointer"]
pub struct ElEntryPointer {
    pub seq: u64,
    pub key: String,
    pub r#type: EnumValue,
    pub digest: String,
    pub size: u64,
    pub at_ms: i64,
    pub packs: Vec<ElPack>,
    pub __unknown_fields__: UnknownFields,
    pub __protobuf__: bool,
}

#[derive(NifStruct, Clone, Debug)]
#[module = "Code.Wal.V1.Base"]
pub struct ElBase {
    pub packs: Vec<ElPack>,
    pub refs: HashMap<String, String>,
    pub symrefs: HashMap<String, String>,
    pub seq: u64,
    pub at_ms: i64,
    pub history_key: String,
    pub __unknown_fields__: UnknownFields,
    pub __protobuf__: bool,
}

#[derive(NifStruct, Clone, Debug)]
#[module = "Code.Wal.V1.Index"]
pub struct ElIndex {
    pub repo_id: String,
    pub epoch: u64,
    pub seq: u64,
    pub base: Option<ElBase>,
    pub entries: Vec<ElEntryPointer>,
    pub replicas: u32,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub updated_by: String,
    pub default_branch: String,
    pub refs: HashMap<String, String>,
    pub incarnation: String,
    pub deleted_at_ms: i64,
    pub history_retention_days: i64,
    pub recovering: bool,
    pub storage_generation: String,
    pub __unknown_fields__: UnknownFields,
    pub __protobuf__: bool,
}

// ---------------------------------------------------------------------------
// Conversions between the Elixir mirror and prost's generated types.
//
// prost emits one struct per proto message under `self::proto`, with scalar
// fields as owned Rust types and messages as `Option<T>`. The Elixir side
// represents a nil message the same way, so the mapping is mechanical.

impl From<ElPack> for proto::Pack {
    fn from(p: ElPack) -> Self {
        proto::Pack {
            key: p.key,
            size: p.size,
            digest: p.digest,
        }
    }
}
impl From<proto::Pack> for ElPack {
    fn from(p: proto::Pack) -> Self {
        ElPack {
            key: p.key,
            size: p.size,
            digest: p.digest,
            __unknown_fields__: vec![],
            __protobuf__: true,
        }
    }
}

impl From<ElRefCommand> for proto::RefCommand {
    fn from(c: ElRefCommand) -> Self {
        proto::RefCommand {
            r#ref: c.r#ref,
            old_oid: c.old_oid,
            new_oid: c.new_oid,
        }
    }
}
impl From<proto::RefCommand> for ElRefCommand {
    fn from(c: proto::RefCommand) -> Self {
        ElRefCommand {
            r#ref: c.r#ref,
            old_oid: c.old_oid,
            new_oid: c.new_oid,
            __unknown_fields__: vec![],
            __protobuf__: true,
        }
    }
}

impl From<ElActor> for proto::Actor {
    fn from(a: ElActor) -> Self {
        proto::Actor {
            account: a.account,
            subject: a.subject,
            node: a.node,
            remote_addr: a.remote_addr,
        }
    }
}
impl From<proto::Actor> for ElActor {
    fn from(a: proto::Actor) -> Self {
        ElActor {
            account: a.account,
            subject: a.subject,
            node: a.node,
            remote_addr: a.remote_addr,
            __unknown_fields__: vec![],
            __protobuf__: true,
        }
    }
}

impl From<ElEntry> for proto::Entry {
    fn from(e: ElEntry) -> Self {
        proto::Entry {
            r#type: e.r#type.into(),
            commands: e.commands.into_iter().map(Into::into).collect(),
            packs: e.packs.into_iter().map(Into::into).collect(),
            symrefs: e.symrefs,
            actor: e.actor.map(Into::into),
            at_ms: e.at_ms,
        }
    }
}
impl From<proto::Entry> for ElEntry {
    fn from(e: proto::Entry) -> Self {
        ElEntry {
            r#type: EnumValue::from(e.r#type),
            commands: e.commands.into_iter().map(Into::into).collect(),
            packs: e.packs.into_iter().map(Into::into).collect(),
            symrefs: e.symrefs,
            actor: e.actor.map(Into::into),
            at_ms: e.at_ms,
            __unknown_fields__: vec![],
            __protobuf__: true,
        }
    }
}

impl From<ElEntryPointer> for proto::EntryPointer {
    fn from(p: ElEntryPointer) -> Self {
        proto::EntryPointer {
            seq: p.seq,
            key: p.key,
            r#type: p.r#type.into(),
            digest: p.digest,
            size: p.size,
            at_ms: p.at_ms,
            packs: p.packs.into_iter().map(Into::into).collect(),
        }
    }
}
impl From<proto::EntryPointer> for ElEntryPointer {
    fn from(p: proto::EntryPointer) -> Self {
        ElEntryPointer {
            seq: p.seq,
            key: p.key,
            r#type: EnumValue::from(p.r#type),
            digest: p.digest,
            size: p.size,
            at_ms: p.at_ms,
            packs: p.packs.into_iter().map(Into::into).collect(),
            __unknown_fields__: vec![],
            __protobuf__: true,
        }
    }
}

impl From<ElBase> for proto::Base {
    fn from(b: ElBase) -> Self {
        proto::Base {
            packs: b.packs.into_iter().map(Into::into).collect(),
            refs: b.refs,
            symrefs: b.symrefs,
            seq: b.seq,
            at_ms: b.at_ms,
            history_key: b.history_key,
        }
    }
}
impl From<proto::Base> for ElBase {
    fn from(b: proto::Base) -> Self {
        ElBase {
            packs: b.packs.into_iter().map(Into::into).collect(),
            refs: b.refs,
            symrefs: b.symrefs,
            seq: b.seq,
            at_ms: b.at_ms,
            history_key: b.history_key,
            __unknown_fields__: vec![],
            __protobuf__: true,
        }
    }
}

impl From<ElIndex> for proto::Index {
    fn from(i: ElIndex) -> Self {
        proto::Index {
            repo_id: i.repo_id,
            epoch: i.epoch,
            seq: i.seq,
            base: i.base.map(Into::into),
            entries: i.entries.into_iter().map(Into::into).collect(),
            replicas: i.replicas,
            created_at_ms: i.created_at_ms,
            updated_at_ms: i.updated_at_ms,
            updated_by: i.updated_by,
            default_branch: i.default_branch,
            refs: i.refs,
            incarnation: i.incarnation,
            deleted_at_ms: i.deleted_at_ms,
            history_retention_days: i.history_retention_days,
            recovering: i.recovering,
            storage_generation: i.storage_generation,
        }
    }
}
impl From<proto::Index> for ElIndex {
    fn from(i: proto::Index) -> Self {
        ElIndex {
            repo_id: i.repo_id,
            epoch: i.epoch,
            seq: i.seq,
            base: i.base.map(Into::into),
            entries: i.entries.into_iter().map(Into::into).collect(),
            replicas: i.replicas,
            created_at_ms: i.created_at_ms,
            updated_at_ms: i.updated_at_ms,
            updated_by: i.updated_by,
            default_branch: i.default_branch,
            refs: i.refs,
            incarnation: i.incarnation,
            deleted_at_ms: i.deleted_at_ms,
            history_retention_days: i.history_retention_days,
            recovering: i.recovering,
            storage_generation: i.storage_generation,
            __unknown_fields__: vec![],
            __protobuf__: true,
        }
    }
}

// ---------------------------------------------------------------------------
// NIF entry points.
//
// Each hot message has two variants: a normal-scheduler one for small
// payloads and a `DirtyCpu` one for the large ones. The Elixir caller picks
// based on a cheap byte-size estimate so we neither block schedulers on a
// 15 ms monorepo decode nor pay dirty-scheduler dispatch overhead on a 10 μs
// small-repo encode.

fn encode_message<'a, M: Message>(env: Env<'a>, m: &M) -> Term<'a> {
    let len = m.encoded_len();
    let mut owned = NewBinary::new(env, len);
    // prost writes directly into the Erlang-owned binary with no intermediate
    // copy. encode_len() is exact, so this neither reallocates nor leaves
    // uninitialised bytes.
    let mut slice: &mut [u8] = owned.as_mut_slice();
    m.encode(&mut slice).expect("encoded_len mismatch");
    Term::from(owned)
}

// Decode `bin` as `M`, and separately check whether re-encoding the decoded
// value would produce the same byte count. If not, the input carried fields
// the Rust schema does not know about and we must not silently drop them.
//
// The length comparison is safe for our schema: every field is either a
// scalar, a nested message, a map, or a repeated message, and prost's
// `encoded_len` is a pure sum of the parts' lengths — map iteration order and
// repeated-field order do not change the total.
enum DecodeOutcome<M> {
    Known(M),
    Unknown,
}

fn decode_or_fallback<M: Message + Default>(
    bin: &[u8],
) -> Result<DecodeOutcome<M>, prost::DecodeError> {
    let decoded = M::decode(bin)?;
    if decoded.encoded_len() == bin.len() {
        Ok(DecodeOutcome::Known(decoded))
    } else {
        Ok(DecodeOutcome::Unknown)
    }
}

#[rustler::nif]
fn index_encode<'a>(env: Env<'a>, index: ElIndex) -> Term<'a> {
    let proto: proto::Index = index.into();
    encode_message(env, &proto)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn index_encode_dirty<'a>(env: Env<'a>, index: ElIndex) -> Term<'a> {
    let proto: proto::Index = index.into();
    encode_message(env, &proto)
}

#[rustler::nif]
fn index_decode<'a>(env: Env<'a>, bin: Binary<'a>) -> NifResult<Term<'a>> {
    match decode_or_fallback::<proto::Index>(bin.as_slice()) {
        Ok(DecodeOutcome::Known(p)) => Ok((ok(), ElIndex::from(p)).encode(env)),
        Ok(DecodeOutcome::Unknown) => Ok(fallback_elixir().encode(env)),
        Err(e) => Ok((error(), (malformed_index(), e.to_string())).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn index_decode_dirty<'a>(env: Env<'a>, bin: Binary<'a>) -> NifResult<Term<'a>> {
    match decode_or_fallback::<proto::Index>(bin.as_slice()) {
        Ok(DecodeOutcome::Known(p)) => Ok((ok(), ElIndex::from(p)).encode(env)),
        Ok(DecodeOutcome::Unknown) => Ok(fallback_elixir().encode(env)),
        Err(e) => Ok((error(), (malformed_index(), e.to_string())).encode(env)),
    }
}

#[rustler::nif]
fn entry_encode<'a>(env: Env<'a>, entry: ElEntry) -> Term<'a> {
    let proto: proto::Entry = entry.into();
    encode_message(env, &proto)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn entry_encode_dirty<'a>(env: Env<'a>, entry: ElEntry) -> Term<'a> {
    let proto: proto::Entry = entry.into();
    encode_message(env, &proto)
}

#[rustler::nif]
fn entry_decode<'a>(env: Env<'a>, bin: Binary<'a>) -> NifResult<Term<'a>> {
    match decode_or_fallback::<proto::Entry>(bin.as_slice()) {
        Ok(DecodeOutcome::Known(p)) => Ok((ok(), ElEntry::from(p)).encode(env)),
        Ok(DecodeOutcome::Unknown) => Ok(fallback_elixir().encode(env)),
        Err(e) => Ok((error(), (malformed_entry(), e.to_string())).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn entry_decode_dirty<'a>(env: Env<'a>, bin: Binary<'a>) -> NifResult<Term<'a>> {
    match decode_or_fallback::<proto::Entry>(bin.as_slice()) {
        Ok(DecodeOutcome::Known(p)) => Ok((ok(), ElEntry::from(p)).encode(env)),
        Ok(DecodeOutcome::Unknown) => Ok(fallback_elixir().encode(env)),
        Err(e) => Ok((error(), (malformed_entry(), e.to_string())).encode(env)),
    }
}

rustler::init!("Elixir.Code.Native");
