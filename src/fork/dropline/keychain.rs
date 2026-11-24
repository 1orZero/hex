//! The bearer in the login Keychain, as one generic password: service
//! `anomaly.hex.fork.dropline-private`, account the data folder's path.

use std::ffi::{CString, c_void};

const SERVICE: &str = "anomaly.hex.fork.dropline-private";
const NOT_FOUND: i32 = -25300;
const UTF8: u32 = 0x0800_0100;

type CfRef = *const c_void;

#[repr(C)]
struct DictionaryCallbacks {
    _private: [u8; 0],
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeDictionaryKeyCallBacks: DictionaryCallbacks;
    static kCFTypeDictionaryValueCallBacks: DictionaryCallbacks;
    static kCFBooleanTrue: CfRef;
    fn CFStringCreateWithCString(allocator: CfRef, text: *const i8, encoding: u32) -> CfRef;
    fn CFDataCreate(allocator: CfRef, bytes: *const u8, length: isize) -> CfRef;
    fn CFDataGetBytePtr(data: CfRef) -> *const u8;
    fn CFDataGetLength(data: CfRef) -> isize;
    fn CFDictionaryCreate(
        allocator: CfRef,
        keys: *const CfRef,
        values: *const CfRef,
        count: isize,
        key_callbacks: *const DictionaryCallbacks,
        value_callbacks: *const DictionaryCallbacks,
    ) -> CfRef;
    fn CFRelease(object: CfRef);
}

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    static kSecClass: CfRef;
    static kSecClassGenericPassword: CfRef;
    static kSecAttrService: CfRef;
    static kSecAttrAccount: CfRef;
    static kSecValueData: CfRef;
    static kSecReturnData: CfRef;
    static kSecMatchLimit: CfRef;
    static kSecMatchLimitOne: CfRef;
    fn SecItemAdd(attributes: CfRef, result: *mut CfRef) -> i32;
    fn SecItemCopyMatching(query: CfRef, result: *mut CfRef) -> i32;
    fn SecItemUpdate(query: CfRef, attributes: CfRef) -> i32;
    fn SecItemDelete(query: CfRef) -> i32;
}

/// A Core Foundation object this module created, released when dropped.
struct Owned(CfRef);

impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: each `Owned` holds one reference from a Create or Copy call.
            unsafe { CFRelease(self.0) };
        }
    }
}

fn string(text: &str) -> Result<Owned, String> {
    let text = CString::new(text).map_err(|_| "鑰匙圈的名稱含 NUL".to_owned())?;
    // SAFETY: `text` is a valid NUL-terminated UTF-8 string for the call.
    let string = unsafe { CFStringCreateWithCString(std::ptr::null(), text.as_ptr(), UTF8) };
    (!string.is_null())
        .then_some(Owned(string))
        .ok_or_else(|| "無法建立字串".into())
}

fn dictionary(pairs: &[(CfRef, CfRef)]) -> Owned {
    let keys: Vec<CfRef> = pairs.iter().map(|(key, _)| *key).collect();
    let values: Vec<CfRef> = pairs.iter().map(|(_, value)| *value).collect();
    // SAFETY: `keys` and `values` hold `pairs.len()` live CF objects, retained
    // by the dictionary through the CFType callbacks.
    Owned(unsafe {
        CFDictionaryCreate(
            std::ptr::null(),
            keys.as_ptr(),
            values.as_ptr(),
            pairs.len() as isize,
            &raw const kCFTypeDictionaryKeyCallBacks,
            &raw const kCFTypeDictionaryValueCallBacks,
        )
    })
}

/// Runs `work` with the item's identifying attributes (class, service,
/// account) and `extra` ones.
fn with_query<R>(
    account: &str,
    extra: &[(CfRef, CfRef)],
    work: impl FnOnce(CfRef) -> R,
) -> Result<R, String> {
    let service = string(SERVICE)?;
    let account = string(account)?;
    // SAFETY: the Security constants are immutable framework statics.
    let mut pairs = unsafe {
        vec![
            (kSecClass, kSecClassGenericPassword),
            (kSecAttrService, service.0),
            (kSecAttrAccount, account.0),
        ]
    };
    pairs.extend_from_slice(extra);
    let query = dictionary(&pairs);
    Ok(work(query.0))
}

pub(super) fn read(account: &str) -> Result<Option<String>, String> {
    // SAFETY: immutable framework statics.
    let extra = unsafe {
        [
            (kSecReturnData, kCFBooleanTrue),
            (kSecMatchLimit, kSecMatchLimitOne),
        ]
    };
    let mut result: CfRef = std::ptr::null();
    // SAFETY: `query` is a live dictionary; `result` receives a retained CFData.
    let status = with_query(account, &extra, |query| unsafe {
        SecItemCopyMatching(query, &raw mut result)
    })?;
    let data = Owned(result);
    match status {
        0 if !data.0.is_null() => {}
        NOT_FOUND => return Ok(None),
        status => return Err(format!("SecItemCopyMatching {status}")),
    }
    // SAFETY: `data` is the CFData the query returned, alive while read.
    let (pointer, length) = unsafe { (CFDataGetBytePtr(data.0), CFDataGetLength(data.0)) };
    if pointer.is_null() || length <= 0 {
        return Ok(None);
    }
    // SAFETY: `pointer` holds `length` bytes owned by `data`.
    let bytes = unsafe { std::slice::from_raw_parts(pointer, length as usize) };
    String::from_utf8(bytes.to_vec())
        .map(Some)
        .map_err(|_| "鑰匙圈的 token 不是 UTF-8".into())
}

/// Replaces the item's secret in place, or adds the item when it is missing,
/// so a failure never leaves the account without its old bearer.
pub(super) fn write(account: &str, secret: &str) -> Result<(), String> {
    // SAFETY: `secret` is valid for its length during the call.
    let data =
        Owned(unsafe { CFDataCreate(std::ptr::null(), secret.as_ptr(), secret.len() as isize) });
    if data.0.is_null() {
        return Err("無法建立鑰匙圈資料".into());
    }
    // SAFETY: immutable framework static.
    let value = [(unsafe { kSecValueData }, data.0)];
    let changes = dictionary(&value);
    // SAFETY: `query` and `changes` are live dictionaries.
    let status = with_query(account, &[], |query| unsafe {
        SecItemUpdate(query, changes.0)
    })?;
    let status = match status {
        // SAFETY: `query` is a live dictionary; no result is asked for.
        NOT_FOUND => with_query(account, &value, |query| unsafe {
            SecItemAdd(query, std::ptr::null_mut())
        })?,
        status => status,
    };
    match status {
        0 => Ok(()),
        status => Err(format!("無法存進鑰匙圈（{status}）")),
    }
}

pub(super) fn delete(account: &str) -> Result<(), String> {
    // SAFETY: `query` is a live dictionary.
    let status = with_query(account, &[], |query| unsafe { SecItemDelete(query) })?;
    match status {
        0 | NOT_FOUND => Ok(()),
        status => Err(format!("無法從鑰匙圈刪除（{status}）")),
    }
}
