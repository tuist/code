//! Bounded Git delta instructions; never allocate from unchecked size fields.
const MAX_BODY: usize = 512 * 1024;
#[derive(Clone, Copy)]
pub(crate) struct Header {
    pub(crate) base: usize,
    pub(crate) result: usize,
    cursor: usize,
}
fn integer(bytes: &[u8], cursor: &mut usize) -> Option<usize> {
    let mut result = 0usize;
    for shift in (0..usize::BITS).step_by(7) {
        let byte = *bytes.get(*cursor)?;
        *cursor += 1;
        let part = usize::from(byte & 127);
        if part > usize::MAX >> shift {
            return None;
        }
        result |= part << shift;
        if byte & 128 == 0 {
            return Some(result);
        }
    }
    None
}
pub(crate) fn header(delta: &[u8], budget: usize) -> Option<Header> {
    let mut cursor = 0;
    let base = integer(delta, &mut cursor)?;
    let result = integer(delta, &mut cursor)?;
    if base > MAX_BODY || result > MAX_BODY || result > budget {
        return None;
    }
    Some(Header {
        base,
        result,
        cursor,
    })
}
pub(crate) fn apply(
    base: &[u8],
    delta: &[u8],
    header: Header,
    active: &impl Fn() -> bool,
) -> Option<Vec<u8>> {
    if base.len() != header.base || !active() {
        return None;
    }
    let mut cursor = header.cursor;
    let mut result = Vec::with_capacity(header.result);
    while cursor < delta.len() {
        if !active() {
            return None;
        }
        let opcode = *delta.get(cursor)?;
        cursor += 1;
        if opcode & 128 != 0 {
            let mut offset = 0usize;
            let mut length = 0usize;
            for bit in 0..7 {
                if opcode & (1 << bit) == 0 {
                    continue;
                }
                let byte = usize::from(*delta.get(cursor)?);
                cursor += 1;
                if bit < 4 {
                    offset |= byte << (bit * 8);
                } else {
                    length |= byte << ((bit - 4) * 8);
                }
            }
            if length == 0 {
                length = 65536;
            }
            if result.len().checked_add(length)? > header.result {
                return None;
            }
            result.extend_from_slice(base.get(offset..offset.checked_add(length)?)?);
        } else {
            let length = usize::from(opcode);
            if length == 0 || result.len().checked_add(length)? > header.result {
                return None;
            }
            result.extend_from_slice(delta.get(cursor..cursor.checked_add(length)?)?);
            cursor += length;
        }
    }
    (result.len() == header.result).then_some(result)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn checked_copy_and_insert() {
        let delta = b"\x03\x04\x90\x03\x01d";
        let hdr = header(delta, MAX_BODY).unwrap();
        assert_eq!(apply(b"abc", delta, hdr, &|| true), Some(b"abcd".to_vec()));
        assert!(apply(b"a", delta, hdr, &|| true).is_none());
        assert!(apply(b"abc", delta, hdr, &|| false).is_none());
        assert!(header(delta, 3).is_none());
    }
    #[test]
    fn corrupt_instructions_and_giant_size_fields_are_rejected() {
        assert!(header(&[0xff; 20], MAX_BODY).is_none());
        // base declares 2^21, while result is tiny. Refuse BEFORE loading base.
        assert!(header(b"\x80\x80\x80\x01\x01", MAX_BODY).is_none());
        for delta in [
            &b"\x03\x04\x00"[..],
            &b"\x03\x01\x90\x04"[..],
            &b"\x03\x01\x01"[..],
            &b"\x03\x01\x91\xff\x01"[..],
        ] {
            if let Some(hdr) = header(delta, MAX_BODY) {
                assert!(apply(b"abc", delta, hdr, &|| true).is_none());
            }
        }
    }
}
