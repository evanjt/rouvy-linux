// Load Rouvy's WCL Bluetooth plugin outside Unity and report what the
// manager says about the radio. Build with winegcc, run under wine.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

static unsigned stream_seconds = 15, cycles = 1;
static ULONGLONG target_address;
static BOOL scan_during_stream;

typedef void (WINAPI *status_cb)(void *sender, int status);
typedef void (WINAPI *notify_cb)(void *sender);
typedef void (WINAPI *set_apc_sync_fn)(void);
typedef unsigned (WINAPI *wait_fn)(HANDLE *handles, unsigned cnt, unsigned timeout);
/* APCs and advertisements can wake WCLWait early. Count elapsed time, not calls. */
static void pump_for(wait_fn wait, HANDLE idle, unsigned milliseconds)
{
    ULONGLONG end = GetTickCount64() + milliseconds, now;
    while ((now = GetTickCount64()) < end)
        wait(&idle, 1, (unsigned)min(end - now, 500));
}
typedef void *(WINAPI *manager_create_fn)(status_cb init, status_cb changed, notify_cb before_close);
typedef int (WINAPI *manager_int_fn)(void *mgr);
typedef void *(WINAPI *manager_ptr_fn)(void *mgr);
typedef void (WINAPI *adv_info_cb)(void *sender, INT64 address, INT64 timestamp, INT8 rssi, const WCHAR *name,
                                   UINT32 packet_type, UINT8 flags);
typedef void (WINAPI *adv_uuid_cb)(void *sender, INT64 address, INT64 timestamp, INT8 rssi, GUID uuid);
typedef void (WINAPI *adv_manf_cb)(void *sender, INT64 address, INT64 timestamp, INT8 rssi, UINT16 company,
                                   UINT16 size, const BYTE *payload);
typedef void *(WINAPI *watcher_create_fn)(adv_info_cb info, notify_cb started, notify_cb stopped, adv_uuid_cb uuid,
                                          adv_manf_cb manf);
typedef int (WINAPI *watcher_start_fn)(void *watcher, void *radio);
typedef int (WINAPI *watcher_stop_fn)(void *watcher);
typedef void (WINAPI *watcher_destroy_fn)(void *watcher);

static void WINAPI on_adv_info(void *sender, INT64 address, INT64 timestamp, INT8 rssi, const WCHAR *name,
                               UINT32 packet_type, UINT8 flags)
{
    char utf8_name[256] = "";
    if (target_address && (ULONGLONG)address != target_address) return;
    if (name) WideCharToMultiByte(CP_UTF8, 0, name, -1, utf8_name, sizeof(utf8_name), NULL, NULL);
    printf("advertisement: %012llx signal=%d dBm name=%s\n", (unsigned long long)address, rssi, utf8_name);
}

static void WINAPI on_adv_uuid(void *sender, INT64 address, INT64 timestamp, INT8 rssi, GUID uuid)
{
    if (target_address) return;
    printf("adv uuid: %012llx rssi=%d uuid=%08x-%04x-%04x\n", (unsigned long long)address, rssi, uuid.Data1,
           uuid.Data2, uuid.Data3);
}

static void WINAPI on_adv_manf(void *sender, INT64 address, INT64 timestamp, INT8 rssi, UINT16 company, UINT16 size,
                               const BYTE *payload)
{
    if (target_address) return;
    printf("adv manf: %012llx rssi=%d company=%#x size=%u\n", (unsigned long long)address, rssi, company, size);
}

#pragma pack(push, 1)
struct gatt_uuid { BOOL is_short; UINT16 short_uuid; GUID long_uuid; };
struct gatt_service { struct gatt_uuid uuid; UINT16 handle; };
struct gatt_services { UINT8 count; struct gatt_service services[255]; };
struct gatt_char
{
    UINT16 service_handle; struct gatt_uuid uuid; UINT16 handle; UINT16 value_handle;
    BOOL broadcastable, readable, writable, writable_no_rsp, signed_writable, notifiable, indicatable, has_extended;
};
struct gatt_chars { UINT8 count; struct gatt_char chars[255]; };
#pragma pack(pop)

typedef void (WINAPI *gatt_connect_cb)(void *sender, int error);
typedef void (WINAPI *gatt_disconnect_cb)(void *sender, int reason);
typedef void (WINAPI *gatt_changed_cb)(void *sender, UINT16 handle, const BYTE *value, UINT32 len);
typedef void *(WINAPI *gatt_create_fn)(gatt_connect_cb on_connect, gatt_disconnect_cb on_disconnect, gatt_changed_cb on_changed);
typedef int (WINAPI *gatt_connect_fn)(void *client, void *radio, INT64 address);
typedef int (WINAPI *gatt_int_fn)(void *client);
typedef void (WINAPI *gatt_void_fn)(void *client);
typedef int (WINAPI *gatt_get_services_fn)(void *client, struct gatt_services *services);
typedef int (WINAPI *gatt_get_chars_fn)(void *client, const struct gatt_service *service, struct gatt_chars *chars);
typedef int (WINAPI *gatt_subscribe_fn)(void *client, const struct gatt_char *chr);
typedef int (WINAPI *gatt_read_fn)(void *client, const struct gatt_char *chr, BYTE **value, UINT32 *size);

static int gatt_connect_error = -1;
static ULONGLONG connect_start, stream_start;
static BOOL unexpected_disconnect, disconnect_requested;
static struct stream_stats
{
    UINT16 handle, uuid;
    unsigned count;
    ULONGLONG first, last, max_gap;
} streams[255];
static unsigned stream_count;

static void WINAPI on_gatt_connect(void *sender, int error)
{
    gatt_connect_error = error;
    printf("gatt connect: error=%d (0x%x) elapsed=%llums\n", error, error, (unsigned long long)(GetTickCount64() - connect_start));
}
static void WINAPI on_gatt_disconnect(void *sender, int reason)
{
    if (!disconnect_requested) unexpected_disconnect = TRUE;
    printf("gatt disconnect: reason=%d (0x%x) requested=%d\n", reason, reason, disconnect_requested);
}
static void WINAPI on_gatt_changed(void *sender, UINT16 handle, const BYTE *value, UINT32 len)
{
    ULONGLONG now = GetTickCount64();
    UINT16 uuid = 0;
    for (unsigned i = 0; i < stream_count; i++)
    {
        struct stream_stats *s = &streams[i];
        if (s->handle != handle) continue;
        uuid = s->uuid;
        if (!s->count) s->first = now;
        else if (now - s->last > s->max_gap) s->max_gap = now - s->last;
        s->last = now;
        s->count++;
    }
    printf("gatt changed: elapsed=%llums handle=%#x len=%u:", (unsigned long long)(now - connect_start), handle, len);
    if (uuid == 0x2a63 && len >= 4)
        printf(" power=%d W |", (INT16)(value[2] | value[3] << 8));
    for (UINT32 i = 0; i < len && i < 20; i++) printf(" %02x", value[i]);
    printf("\n");
}

static void print_uuid_aligned(const struct gatt_uuid *u)
{
    if (u->is_short) printf("%04x", u->short_uuid);
    else printf("%08x-%04x-%04x", u->long_uuid.Data1, u->long_uuid.Data2, u->long_uuid.Data3);
}

static void print_uuid(const struct gatt_uuid *u)
{
    if (u->is_short) printf("%04x", u->short_uuid);
    else printf("%08x-%04x-%04x", u->long_uuid.Data1, u->long_uuid.Data2, u->long_uuid.Data3);
}

static int gatt_test(HMODULE m, wait_fn wait, void *radio, INT64 address)
{
    gatt_create_fn create = (void *)GetProcAddress(m, "WCLGattClientCreate");
    gatt_connect_fn connect = (void *)GetProcAddress(m, "WCLGattClientConnect");
    gatt_int_fn disconnect = (void *)GetProcAddress(m, "WCLGattClientDisconnect");
    gatt_int_fn get_state = (void *)GetProcAddress(m, "WCLGattClientGetState");
    gatt_void_fn destroy = (void *)GetProcAddress(m, "WCLGattClientDestroy");
    gatt_get_services_fn get_services = (void *)GetProcAddress(m, "WCLGattClientGetServices");
    gatt_get_chars_fn get_chars = (void *)GetProcAddress(m, "WCLGattClientGetCharacteristics");
    gatt_subscribe_fn subscribe = (void *)GetProcAddress(m, "WCLGattClientSubscribeCharacteristic");
    HANDLE idle = CreateEventW(NULL, TRUE, FALSE, NULL);
    static struct gatt_services services;
    static struct gatt_chars chars;
    void *client;
    int r, failed = 0;
    ULONGLONG deadline, now;

    gatt_connect_error = -1;
    stream_count = 0;
    memset(streams, 0, sizeof(streams));
    unexpected_disconnect = disconnect_requested = FALSE;
    client = create(on_gatt_connect, on_gatt_disconnect, on_gatt_changed);
    if (!client || !idle) return 1;
    printf("sizeof gatt_char=%u\n", (unsigned)sizeof(struct gatt_char));
    printf("WCLGattClientCreate -> %p\n", client);
    connect_start = GetTickCount64();
    r = connect(client, radio, address);
    printf("WCLGattClientConnect(%012llx) -> %d (0x%x)\n", (unsigned long long)address, r, r);
    deadline = connect_start + 60000;
    while (!r && gatt_connect_error == -1 && (now = GetTickCount64()) < deadline)
        wait(&idle, 1, (unsigned)min(deadline - now, 500));
    printf("state -> %d, connect error %d\n", get_state(client), gatt_connect_error);
    if (gatt_connect_error == 0)
    {
        r = get_services(client, &services);
        printf("WCLGattClientGetServices -> %d (0x%x), %u services\n", r, r, services.count);
        if (r) failed = 1;
        for (int i = 0; !r && i < services.count; i++)
        {
            printf("  service "); print_uuid(&services.services[i].uuid); printf(" handle %#x\n", services.services[i].handle);
            memset(&chars, 0, sizeof(chars));
            r = get_chars(client, &services.services[i], &chars);
            printf("  WCLGattClientGetCharacteristics -> %d, %u chars\n", r, chars.count);
            if (r) { failed = 1; break; }
            for (int j = 0; j < chars.count; j++)
            {
                struct gatt_char *c = &chars.chars[j];
                printf("    char "); print_uuid_aligned(&c->uuid);
                printf(" handle %#x value %#x r=%d w=%d n=%d i=%d\n", c->handle, c->value_handle, c->readable, c->writable, c->notifiable, c->indicatable);
                if (c->notifiable && c->uuid.is_short && (c->uuid.short_uuid == 0x2a37 || c->uuid.short_uuid == 0x2ad2 || c->uuid.short_uuid == 0x2a63))
                {
                    if (stream_count == 255) { failed = 1; continue; }
                    streams[stream_count].handle = c->handle;
                    streams[stream_count++].uuid = c->uuid.short_uuid;
                    r = subscribe(client, c);
                    printf("    WCLGattClientSubscribeCharacteristic -> %d (0x%x)\n", r, r);
                    if (r) failed = 1;
                }
            }
        }
        stream_start = GetTickCount64();
        deadline = stream_start + (ULONGLONG)stream_seconds * 1000;
        while (!unexpected_disconnect && (now = GetTickCount64()) < deadline)
            wait(&idle, 1, (unsigned)min(deadline - now, 500));
        now = GetTickCount64();
        printf("stream summary: observed=%llums streams=%u unexpected_disconnect=%d\n",
               (unsigned long long)(now - stream_start), stream_count, unexpected_disconnect);
        if (!stream_count || unexpected_disconnect) failed = 1;
        for (unsigned i = 0; i < stream_count; i++)
        {
            struct stream_stats *s = &streams[i];
            printf("  uuid=%04x handle=%#x packets=%u first_after_connect=%llums max_gap=%llums tail_silence=%llums\n",
                   s->uuid, s->handle, s->count, (unsigned long long)(s->count ? s->first - connect_start : 0),
                   (unsigned long long)s->max_gap, (unsigned long long)(s->count ? now - s->last : now - stream_start));
            if (!s->count) failed = 1;
        }
    }
    else failed = 1;
    disconnect_requested = TRUE;
    printf("WCLGattClientDisconnect -> %d\n", disconnect(client));
    pump_for(wait, idle, 2000);
    printf("calling WCLGattClientDestroy\n");
    destroy(client);
    printf("WCLGattClientDestroy returned\n");
    CloseHandle(idle);
    return failed;
}

static void WINAPI on_watcher_started(void *sender) { printf("watcher started\n"); }
static void WINAPI on_watcher_stopped(void *sender) { printf("watcher stopped\n"); }

static const char *status_name(int s)
{
    static const char *names[] = { "HardwareNotFound", "UnsupportedRadio", "RadioOff", "RadioOn", "Unknown" };
    return (s >= 0 && s < 5) ? names[s] : "?";
}

static void WINAPI on_init(void *sender, int status)
{
    printf("callback init: status=%d (%s)\n", status, status_name(status));
}

static void WINAPI on_changed(void *sender, int status)
{
    printf("callback changed: status=%d (%s)\n", status, status_name(status));
}

static void WINAPI on_before_close(void *sender)
{
    printf("callback before_close\n");
}

int main(int argc, char **argv)
{
    int failed = 0;
    char *end;
    if (argc > 5) goto usage;
    if (argc > 1)
    {
        errno = 0;
        target_address = strtoull(argv[1], &end, 16);
        if (errno || !*argv[1] || *end || !target_address || target_address > 0xffffffffffffULL) goto usage;
    }
    for (int i = 2; i < argc && i < 4; i++)
    {
        unsigned long value;
        errno = 0;
        value = strtoul(argv[i], &end, 10);
        if (errno || !*argv[i] || *end || !value || value > (i == 2 ? 3600 : 100)) goto usage;
        if (i == 2) stream_seconds = value;
        else cycles = value;
    }
    if (argc == 5)
    {
        if (strcmp(argv[4], "--keep-scanning")) goto usage;
        scan_during_stream = TRUE;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *dir = "C:\\Program Files\\VirtualTraining\\Rouvy\\Rouvy_Data\\Plugins\\x86_64";
    SetDllDirectoryA(dir);
    HMODULE m = LoadLibraryA("WclBlePluginCPP.dll");
    printf("LoadLibrary -> %p (err %u)\n", m, GetLastError());
    if (!m) return 1;

    set_apc_sync_fn set_apc_sync = (void *)GetProcAddress(m, "WCLSetApcSync");
    wait_fn wait = (void *)GetProcAddress(m, "WCLWait");
    manager_create_fn create = (void *)GetProcAddress(m, "WCLManagerCreate");
    manager_int_fn open = (void *)GetProcAddress(m, "WCLManagerOpen");
    manager_int_fn close = (void *)GetProcAddress(m, "WCLManagerClose");
    manager_int_fn active = (void *)GetProcAddress(m, "WCLManagerGetActive");
    manager_ptr_fn get_radio = (void *)GetProcAddress(m, "WCLManagerGetRadio");

    set_apc_sync();
    void *mgr = create(on_init, on_changed, on_before_close);
    printf("WCLManagerCreate -> %p\n", mgr);
    int r = open(mgr);
    printf("WCLManagerOpen -> %d (0x%08x)\n", r, r);
    HANDLE idle = CreateEventW(NULL, TRUE, FALSE, NULL);
    pump_for(wait, idle, 2500);
    printf("WCLManagerGetActive -> %d\n", active(mgr));
    void *radio = get_radio(mgr);
    printf("WCLManagerGetRadio -> %p\n", radio);

    if (radio)
    {
        watcher_create_fn watcher_create = (void *)GetProcAddress(m, "WCLWatcherCreate");
        watcher_start_fn watcher_start = (void *)GetProcAddress(m, "WCLWatcherStart");
        watcher_stop_fn watcher_stop = (void *)GetProcAddress(m, "WCLWatcherStop");
        watcher_destroy_fn watcher_destroy = (void *)GetProcAddress(m, "WCLWatcherDestroy");
        void *watcher = watcher_create(on_adv_info, on_watcher_started, on_watcher_stopped, on_adv_uuid, on_adv_manf);
        printf("WCLWatcherCreate -> %p\n", watcher);
        printf("calling WCLWatcherStart\n");
        r = watcher_start(watcher, radio);
        printf("WCLWatcherStart -> %d (0x%08x)\n", r, r);
        pump_for(wait, idle, 15000);
        if (!scan_during_stream)
        {
            printf("calling WCLWatcherStop\n");
            printf("WCLWatcherStop -> %d\n", watcher_stop(watcher));
            pump_for(wait, idle, 2000);
        }
        if (argc > 1)
        {
            for (unsigned i = 0; i < cycles; i++)
            {
                printf("cycle %u/%u scan_during_stream=%d\n", i + 1, cycles, scan_during_stream);
                failed |= gatt_test(m, wait, radio, target_address);
            }
        }
        if (scan_during_stream)
        {
            printf("calling WCLWatcherStop\n");
            printf("WCLWatcherStop -> %d\n", watcher_stop(watcher));
        }
        printf("calling WCLWatcherDestroy\n");
        watcher_destroy(watcher);
    }
    else failed = 1;
    printf("calling WCLManagerClose\n");
    printf("WCLManagerClose -> %d\n", close(mgr));
    CloseHandle(idle);
    return failed;
usage:
    fprintf(stderr, "Usage: %s [address-hex [seconds:1-3600 [cycles:1-100 [--keep-scanning]]]]\n", argv[0]);
    return 2;
}
