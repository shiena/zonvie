// Windows Jump List integration for Zonvie.
//
// Registers taskbar right-click menu items (Jump List "Tasks" category)
// using the ICustomDestinationList COM API.
//
// Currently adds:
//   - "New Session" — launches a new zonvie.exe instance

const std = @import("std");
const c = @import("win32.zig").c;
const applog = @import("app.zig").applog;

// ============================================================
// COM extern declarations (ole32.dll / shell32.dll)
// ============================================================

const GUID = extern struct {
    Data1: c.ULONG,
    Data2: c.USHORT,
    Data3: c.USHORT,
    Data4: [8]u8,
};

const HRESULT = c.LONG;
const S_OK: HRESULT = 0;
const COINIT_APARTMENTTHREADED: c.DWORD = 0x2;
const COINIT_DISABLE_OLE1DDE: c.DWORD = 0x4;
const CLSCTX_INPROC_SERVER: c.DWORD = 0x1;

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: c.DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*anyopaque, dwClsContext: c.DWORD, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT;

// ============================================================
// COM GUIDs
// ============================================================

// {77f10cf0-3db5-4966-b520-b7c54fd35ed6}
const CLSID_DestinationList = GUID{
    .Data1 = 0x77f10cf0,
    .Data2 = 0x3db5,
    .Data3 = 0x4966,
    .Data4 = .{ 0xb5, 0x20, 0xb7, 0xc5, 0x4f, 0xd3, 0x5e, 0xd6 },
};

// {2d3468c1-36a7-43b6-ac24-d3f02fd9607a}
const CLSID_EnumerableObjectCollection = GUID{
    .Data1 = 0x2d3468c1,
    .Data2 = 0x36a7,
    .Data3 = 0x43b6,
    .Data4 = .{ 0xac, 0x24, 0xd3, 0xf0, 0x2f, 0xd9, 0x60, 0x7a },
};

// {00021401-0000-0000-C000-000000000046}
const CLSID_ShellLink = GUID{
    .Data1 = 0x00021401,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

// {000214F9-0000-0000-C000-000000000046}
const IID_IShellLinkW = GUID{
    .Data1 = 0x000214F9,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

// {886d8eeb-8cf2-4446-8d02-cdba1dbdcf99}
const IID_IPropertyStore = GUID{
    .Data1 = 0x886d8eeb,
    .Data2 = 0x8cf2,
    .Data3 = 0x4446,
    .Data4 = .{ 0x8d, 0x02, 0xcd, 0xba, 0x1d, 0xbd, 0xcf, 0x99 },
};

// {b63ea76d-1f85-456f-a19c-48159efa858b}
const IID_ICustomDestinationList = GUID{
    .Data1 = 0xb63ea76d,
    .Data2 = 0x1f85,
    .Data3 = 0x456f,
    .Data4 = .{ 0xa1, 0x9c, 0x48, 0x15, 0x9e, 0xfa, 0x85, 0x8b },
};

// {5632b1a4-e38a-400a-928a-d4cd63230295}
const IID_IObjectCollection = GUID{
    .Data1 = 0x5632b1a4,
    .Data2 = 0xe38a,
    .Data3 = 0x400a,
    .Data4 = .{ 0x92, 0x8a, 0xd4, 0xcd, 0x63, 0x23, 0x02, 0x95 },
};

// {92CA9DCD-5622-4BBA-A805-5E9F541BD8C9}
const IID_IObjectArray = GUID{
    .Data1 = 0x92CA9DCD,
    .Data2 = 0x5622,
    .Data3 = 0x4BBA,
    .Data4 = .{ 0xA8, 0x05, 0x5E, 0x9F, 0x54, 0x1B, 0xD8, 0xC9 },
};

// ============================================================
// PROPVARIANT (minimal definition for string values)
// ============================================================

const PROPVARIANT = extern struct {
    vt: c.USHORT,
    wReserved1: c.USHORT = 0,
    wReserved2: c.USHORT = 0,
    wReserved3: c.USHORT = 0,
    pwszVal: ?[*:0]const u16 = null,
    _pad: usize = 0, // second union member alignment
};

const VT_LPWSTR: c.USHORT = 31;

// PKEY_Title = {F29F85E0-4FF9-1068-AB91-08002B27B3D9}, pid=2
const PKEY_Title_fmtid = GUID{
    .Data1 = 0xF29F85E0,
    .Data2 = 0x4FF9,
    .Data3 = 0x1068,
    .Data4 = .{ 0xAB, 0x91, 0x08, 0x00, 0x2B, 0x27, 0xB3, 0xD9 },
};
const PKEY_Title_pid: c.DWORD = 2;

const PROPERTYKEY = extern struct {
    fmtid: GUID,
    pid: c.DWORD,
};

const PKEY_Title = PROPERTYKEY{
    .fmtid = PKEY_Title_fmtid,
    .pid = PKEY_Title_pid,
};

// ============================================================
// COM vtable definitions (C-style, matching CINTERFACE layout)
// ============================================================

const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
};

const IShellLinkWVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    // IShellLinkW
    GetPath: *const anyopaque,
    GetIDList: *const anyopaque,
    SetIDList: *const anyopaque,
    GetDescription: *const anyopaque,
    SetDescription: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
    GetWorkingDirectory: *const anyopaque,
    SetWorkingDirectory: *const anyopaque,
    GetArguments: *const anyopaque,
    SetArguments: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
    GetHotkey: *const anyopaque,
    SetHotkey: *const anyopaque,
    GetShowCmd: *const anyopaque,
    SetShowCmd: *const anyopaque,
    GetIconLocation: *const anyopaque,
    SetIconLocation: *const fn (*anyopaque, [*:0]const u16, c.INT) callconv(.winapi) HRESULT,
    GetRelativePath: *const anyopaque,
    SetRelativePath: *const anyopaque,
    Resolve: *const anyopaque,
    SetPath: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
};

const IPropertyStoreVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    // IPropertyStore
    GetCount: *const anyopaque,
    GetAt: *const anyopaque,
    GetValue: *const anyopaque,
    SetValue: *const fn (*anyopaque, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) HRESULT,
    Commit: *const fn (*anyopaque) callconv(.winapi) HRESULT,
};

const IObjectArrayVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    // IObjectArray
    GetCount: *const anyopaque,
    GetAt: *const anyopaque,
};

const IObjectCollectionVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    // IObjectArray
    GetCount: *const anyopaque,
    GetAt: *const anyopaque,
    // IObjectCollection
    AddObject: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
    AddFromArray: *const anyopaque,
    RemoveObjectAt: *const anyopaque,
    Clear: *const anyopaque,
};

const ICustomDestinationListVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    // ICustomDestinationList
    SetAppID: *const anyopaque,
    BeginList: *const fn (*anyopaque, *c.UINT, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AppendCategory: *const anyopaque,
    AppendKnownCategory: *const anyopaque,
    AddUserTasks: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
    DeleteList: *const anyopaque,
    AbortList: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    CommitList: *const fn (*anyopaque) callconv(.winapi) HRESULT,
};

// COM object wrappers: CINTERFACE layout is { lpVtbl: *const Vtbl }

fn comVtbl(comptime Vtbl: type, obj: *anyopaque) *const Vtbl {
    const ptr: *const *const Vtbl = @ptrCast(@alignCast(obj));
    return ptr.*;
}

fn comRelease(obj: *anyopaque) void {
    const vtbl: *const IUnknownVtbl = comVtbl(IUnknownVtbl, obj);
    _ = vtbl.Release(obj);
}

fn comQueryInterface(obj: *anyopaque, iid: *const GUID) ?*anyopaque {
    const vtbl: *const IUnknownVtbl = comVtbl(IUnknownVtbl, obj);
    var result: ?*anyopaque = null;
    const hr = vtbl.QueryInterface(obj, iid, &result);
    if (hr != S_OK) return null;
    return result;
}

// ============================================================
// Public API
// ============================================================

/// Initialize COM for the calling thread (STA).
/// Call once from main() before any COM usage.
pub fn initCom() void {
    const hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (hr != S_OK and hr != 1) { // 1 = S_FALSE (already initialized)
        if (applog.isEnabled()) applog.appLog("[win] CoInitializeEx failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
    }
}

/// Register Jump List tasks on the Windows taskbar.
/// Should be called once after window creation.
pub fn initJumpList() void {
    // Get our exe path
    var exe_path_buf: [260]u16 = undefined;
    const exe_len = c.GetModuleFileNameW(null, &exe_path_buf, 260);
    if (exe_len == 0 or exe_len >= 260) {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: GetModuleFileNameW failed\n", .{});
        return;
    }
    const exe_path: [*:0]const u16 = @ptrCast(exe_path_buf[0..exe_len :0]);

    // Create ICustomDestinationList
    var dest_list_raw: ?*anyopaque = null;
    var hr = CoCreateInstance(&CLSID_DestinationList, null, CLSCTX_INPROC_SERVER, &IID_ICustomDestinationList, &dest_list_raw);
    if (hr != S_OK or dest_list_raw == null) {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: CoCreateInstance(DestinationList) failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        return;
    }
    const dest_list = dest_list_raw.?;
    defer comRelease(dest_list);

    const dest_vtbl = comVtbl(ICustomDestinationListVtbl, dest_list);

    // BeginList
    var removed_raw: ?*anyopaque = null;
    var max_slots: c.UINT = 0;
    hr = dest_vtbl.BeginList(dest_list, &max_slots, &IID_IObjectArray, &removed_raw);
    if (hr != S_OK) {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: BeginList failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        return;
    }
    if (removed_raw) |removed| comRelease(removed);

    // Create task collection
    var collection_raw: ?*anyopaque = null;
    hr = CoCreateInstance(&CLSID_EnumerableObjectCollection, null, CLSCTX_INPROC_SERVER, &IID_IObjectCollection, &collection_raw);
    if (hr != S_OK or collection_raw == null) {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: CoCreateInstance(ObjectCollection) failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        _ = dest_vtbl.AbortList(dest_list);
        return;
    }
    const collection = collection_raw.?;
    defer comRelease(collection);

    // Create "New Session" shell link
    if (createShellLink(exe_path, std.unicode.utf8ToUtf16LeStringLiteral("--nofork"), std.unicode.utf8ToUtf16LeStringLiteral("New Session"))) |link| {
        const coll_vtbl = comVtbl(IObjectCollectionVtbl, collection);
        _ = coll_vtbl.AddObject(collection, link);
        comRelease(link);
    }

    // Get IObjectArray from collection for AddUserTasks
    if (comQueryInterface(collection, &IID_IObjectArray)) |array| {
        _ = dest_vtbl.AddUserTasks(dest_list, array);
        comRelease(array);
    }

    // Commit
    hr = dest_vtbl.CommitList(dest_list);
    if (hr != S_OK) {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: CommitList failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
    } else {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: registered successfully\n", .{});
    }
}

/// Create an IShellLinkW with a title (via IPropertyStore).
/// Returns the IShellLinkW pointer (caller must Release), or null on failure.
fn createShellLink(exe_path: [*:0]const u16, args: [*:0]const u16, title: [*:0]const u16) ?*anyopaque {
    var link_raw: ?*anyopaque = null;
    const hr = CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &link_raw);
    if (hr != S_OK or link_raw == null) return null;
    const link = link_raw.?;

    const link_vtbl = comVtbl(IShellLinkWVtbl, link);

    // Set path and arguments
    _ = link_vtbl.SetPath(link, exe_path);
    _ = link_vtbl.SetArguments(link, args);

    // Set icon to our own exe (resource index 0 = app icon)
    _ = link_vtbl.SetIconLocation(link, exe_path, 0);

    // Set the display title via IPropertyStore
    if (comQueryInterface(link, &IID_IPropertyStore)) |ps_raw| {
        const ps_vtbl = comVtbl(IPropertyStoreVtbl, ps_raw);
        var pv = PROPVARIANT{ .vt = VT_LPWSTR, .pwszVal = title };
        _ = ps_vtbl.SetValue(ps_raw, &PKEY_Title, &pv);
        _ = ps_vtbl.Commit(ps_raw);
        comRelease(ps_raw);
    }

    return link;
}
