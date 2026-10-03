// Pair with an LE sensor through the WinRT DeviceInformation.Pairing API and
// report what the GATT layer allowed before and after. Build with winegcc,
// run under wine. No Rouvy plugin is involved, so it runs against the mock.
//
//   pairprobe.exe <address-no-colons> [pin]
//
// The pin answers a ProvidePin request. Confirm and display requests are
// accepted as they come. Exit status is non-zero when the pairing fails.
// Build with -fshort-wchar and keep to kernel32 string calls: the C library
// linked here is the host's and expects four byte wchar_t.
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <roapi.h>
#include <winstring.h>
#include <stdio.h>
#include <stdlib.h>

#define WIDL_using_Windows_Foundation
#define WIDL_using_Windows_Foundation_Collections
#define WIDL_using_Windows_Devices_Enumeration
#define WIDL_using_Windows_Devices_Bluetooth
#define WIDL_using_Windows_Devices_Bluetooth_GenericAttributeProfile
#include <windows.foundation.h>
#include <windows.devices.enumeration.h>
#include <windows.devices.bluetooth.h>
#include <windows.devices.bluetooth.genericattributeprofile.h>

static const WCHAR *pin_answer;
static unsigned requests;

static const GUID HEART_RATE_SERVICE = { 0x0000180d, 0x0000, 0x1000, { 0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb } };
static const GUID HEART_RATE_MEASUREMENT = { 0x00002a37, 0x0000, 0x1000, { 0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb } };

static void fail(const char *what, HRESULT hr)
{
    fprintf(stderr, "%s failed: %#x\n", what, (unsigned)hr);
    exit(2);
}

static void wait_async(IInspectable *op)
{
    IAsyncInfo *info;
    AsyncStatus status = Started;
    ULONGLONG deadline = GetTickCount64() + 90000;

    if (FAILED(IInspectable_QueryInterface(op, &IID_IAsyncInfo, (void **)&info))) fail("IAsyncInfo", E_NOINTERFACE);
    while (GetTickCount64() < deadline)
    {
        IAsyncInfo_get_Status(info, &status);
        if (status != Started) break;
        Sleep(50);
    }
    IAsyncInfo_Release(info);
    if (status == Started) fail("async wait", HRESULT_FROM_WIN32(ERROR_TIMEOUT));
    if (status != Completed) fail("async operation", status);
}

// The PairingRequested handler accepts whatever ceremony the sensor asks for.
typedef struct
{
    ITypedEventHandler_DeviceInformationCustomPairing_DevicePairingRequestedEventArgs iface;
} request_handler;

static HRESULT WINAPI handler_QueryInterface(ITypedEventHandler_DeviceInformationCustomPairing_DevicePairingRequestedEventArgs *iface,
                                             REFIID iid, void **out)
{
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IAgileObject) ||
        IsEqualGUID(iid, &IID_ITypedEventHandler_DeviceInformationCustomPairing_DevicePairingRequestedEventArgs))
    {
        *out = iface;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG WINAPI handler_AddRef(ITypedEventHandler_DeviceInformationCustomPairing_DevicePairingRequestedEventArgs *iface)
{
    return 2;
}

static ULONG WINAPI handler_Release(ITypedEventHandler_DeviceInformationCustomPairing_DevicePairingRequestedEventArgs *iface)
{
    return 1;
}

static HRESULT WINAPI handler_Invoke(ITypedEventHandler_DeviceInformationCustomPairing_DevicePairingRequestedEventArgs *iface,
                                     IDeviceInformationCustomPairing *sender, IDevicePairingRequestedEventArgs *args)
{
    DevicePairingKinds kind;
    HSTRING pin = NULL;
    char digits[32] = "";

    IDevicePairingRequestedEventArgs_get_PairingKind(args, &kind);
    IDevicePairingRequestedEventArgs_get_Pin(args, &pin);
    WideCharToMultiByte(CP_ACP, 0, WindowsGetStringRawBuffer(pin, NULL), -1, digits, sizeof(digits), NULL, NULL);
    printf("pairing requested: kind=%u pin=%s\n", kind, digits);
    fflush(stdout);
    requests++;
    if (kind == DevicePairingKinds_ProvidePin)
    {
        HSTRING answer;
        if (!pin_answer) printf("no pin to provide\n");
        else
        {
            WindowsCreateString(pin_answer, lstrlenW(pin_answer), &answer);
            IDevicePairingRequestedEventArgs_AcceptWithPin(args, answer);
            WindowsDeleteString(answer);
        }
    }
    else IDevicePairingRequestedEventArgs_Accept(args);
    WindowsDeleteString(pin);
    return S_OK;
}

static ITypedEventHandler_DeviceInformationCustomPairing_DevicePairingRequestedEventArgsVtbl handler_vtbl =
{
    handler_QueryInterface,
    handler_AddRef,
    handler_Release,
    handler_Invoke,
};

static request_handler handler = { { &handler_vtbl } };

static IBluetoothLEDevice *open_device(UINT64 address)
{
    IBluetoothLEDeviceStatics *statics;
    IAsyncOperation_BluetoothLEDevice *op;
    IBluetoothLEDevice *device = NULL;
    HSTRING name;
    HRESULT hr;

    WindowsCreateString(RuntimeClass_Windows_Devices_Bluetooth_BluetoothLEDevice,
                        lstrlenW(RuntimeClass_Windows_Devices_Bluetooth_BluetoothLEDevice), &name);
    hr = RoGetActivationFactory(name, &IID_IBluetoothLEDeviceStatics, (void **)&statics);
    WindowsDeleteString(name);
    if (FAILED(hr)) fail("BluetoothLEDevice factory", hr);
    if (FAILED(hr = IBluetoothLEDeviceStatics_FromBluetoothAddressAsync(statics, address, &op))) fail("FromBluetoothAddressAsync", hr);
    wait_async((IInspectable *)op);
    IAsyncOperation_BluetoothLEDevice_GetResults(op, &device);
    IAsyncOperation_BluetoothLEDevice_Release(op);
    IBluetoothLEDeviceStatics_Release(statics);
    if (!device) fail("device lookup", E_FAIL);
    return device;
}

// Subscribe to heart rate measurement and report the GATT status the driver gave.
static int subscribe(IBluetoothLEDevice *device)
{
    IBluetoothLEDevice3 *device3;
    IAsyncOperation_GattDeviceServicesResult *services_op;
    IGattDeviceServicesResult *services;
    IVectorView_GattDeviceService *service_list;
    IGattDeviceService *service;
    IGattDeviceService3 *service3;
    IAsyncOperation_GattCharacteristicsResult *chars_op;
    IGattCharacteristicsResult *chars;
    IVectorView_GattCharacteristic *char_list;
    IGattCharacteristic *characteristic;
    IAsyncOperation_GattCommunicationStatus *status_op;
    GattCommunicationStatus status = GattCommunicationStatus_Unreachable;
    UINT32 count = 0;
    HRESULT hr;

    if (FAILED(hr = IBluetoothLEDevice_QueryInterface(device, &IID_IBluetoothLEDevice3, (void **)&device3))) fail("IBluetoothLEDevice3", hr);
    if (FAILED(hr = IBluetoothLEDevice3_GetGattServicesForUuidAsync(device3, HEART_RATE_SERVICE, &services_op))) fail("GetGattServicesForUuidAsync", hr);
    IBluetoothLEDevice3_Release(device3);
    wait_async((IInspectable *)services_op);
    IAsyncOperation_GattDeviceServicesResult_GetResults(services_op, &services);
    IAsyncOperation_GattDeviceServicesResult_Release(services_op);
    IGattDeviceServicesResult_get_Services(services, &service_list);
    IGattDeviceServicesResult_Release(services);
    IVectorView_GattDeviceService_get_Size(service_list, &count);
    if (!count) fail("heart rate service", E_FAIL);
    IVectorView_GattDeviceService_GetAt(service_list, 0, &service);
    IVectorView_GattDeviceService_Release(service_list);

    if (FAILED(hr = IGattDeviceService_QueryInterface(service, &IID_IGattDeviceService3, (void **)&service3))) fail("IGattDeviceService3", hr);
    if (FAILED(hr = IGattDeviceService3_GetCharacteristicsForUuidAsync(service3, HEART_RATE_MEASUREMENT, &chars_op))) fail("GetCharacteristicsForUuidAsync", hr);
    IGattDeviceService3_Release(service3);
    wait_async((IInspectable *)chars_op);
    IAsyncOperation_GattCharacteristicsResult_GetResults(chars_op, &chars);
    IAsyncOperation_GattCharacteristicsResult_Release(chars_op);
    IGattCharacteristicsResult_get_Characteristics(chars, &char_list);
    IGattCharacteristicsResult_Release(chars);
    IVectorView_GattCharacteristic_get_Size(char_list, &count);
    if (!count) fail("heart rate measurement", E_FAIL);
    IVectorView_GattCharacteristic_GetAt(char_list, 0, &characteristic);
    IVectorView_GattCharacteristic_Release(char_list);

    hr = IGattCharacteristic_WriteClientCharacteristicConfigurationDescriptorAsync(
        characteristic, GattClientCharacteristicConfigurationDescriptorValue_Notify, &status_op);
    if (FAILED(hr)) fail("WriteClientCharacteristicConfigurationDescriptorAsync", hr);
    wait_async((IInspectable *)status_op);
    IAsyncOperation_GattCommunicationStatus_GetResults(status_op, &status);
    IAsyncOperation_GattCommunicationStatus_Release(status_op);
    IGattCharacteristic_Release(characteristic);
    IGattDeviceService_Release(service);
    return status;
}

// The service device node can lag the services result by a few hundred
// milliseconds, so an Unreachable answer is retried before it counts.
static int subscribe_settled(IBluetoothLEDevice *device)
{
    int status, attempts;

    for (attempts = 0; attempts < 20; attempts++)
    {
        if ((status = subscribe(device)) != GattCommunicationStatus_Unreachable) break;
        Sleep(250);
    }
    return status;
}

int main(int argc, char **argv)
{
    IBluetoothLEDevice *device;
    IBluetoothLEDevice2 *device2;
    IDeviceInformation *info;
    IDeviceInformation2 *info2;
    IDeviceInformationPairing *pairing;
    IDeviceInformationPairing2 *pairing2;
    IDeviceInformationCustomPairing *custom;
    IAsyncOperation_DevicePairingResult *pair_op;
    IDevicePairingResult *result;
    DevicePairingResultStatus status;
    DeviceInformationKind kind;
    EventRegistrationToken token;
    boolean paired;
    UINT64 address;
    WCHAR pin[32];
    HRESULT hr;

    if (argc < 2)
    {
        fprintf(stderr, "usage: pairprobe <address-no-colons> [pin]\n");
        return 2;
    }
    address = strtoull(argv[1], NULL, 16);
    if (argc > 2)
    {
        MultiByteToWideChar(CP_ACP, 0, argv[2], -1, pin, ARRAYSIZE(pin));
        pin_answer = pin;
    }
    setvbuf(stdout, NULL, _IONBF, 0);

    if (FAILED(hr = RoInitialize(RO_INIT_MULTITHREADED))) fail("RoInitialize", hr);
    device = open_device(address);
    printf("notify before: %d\n", subscribe_settled(device));

    if (FAILED(hr = IBluetoothLEDevice_QueryInterface(device, &IID_IBluetoothLEDevice2, (void **)&device2))) fail("IBluetoothLEDevice2", hr);
    if (FAILED(hr = IBluetoothLEDevice2_get_DeviceInformation(device2, &info))) fail("DeviceInformation", hr);
    IBluetoothLEDevice2_Release(device2);
    if (FAILED(hr = IDeviceInformation_QueryInterface(info, &IID_IDeviceInformation2, (void **)&info2))) fail("IDeviceInformation2", hr);
    IDeviceInformation2_get_Kind(info2, &kind);
    if (FAILED(hr = IDeviceInformation2_get_Pairing(info2, &pairing))) fail("Pairing", hr);
    IDeviceInformation2_Release(info2);
    IDeviceInformation_Release(info);
    IDeviceInformationPairing_get_IsPaired(pairing, &paired);
    printf("kind: %d paired: %d\n", kind, paired);

    if (FAILED(hr = IDeviceInformationPairing_QueryInterface(pairing, &IID_IDeviceInformationPairing2, (void **)&pairing2))) fail("IDeviceInformationPairing2", hr);
    if (FAILED(hr = IDeviceInformationPairing2_get_Custom(pairing2, &custom))) fail("Custom", hr);
    IDeviceInformationCustomPairing_add_PairingRequested(custom, &handler.iface, &token);
    hr = IDeviceInformationCustomPairing_PairAsync(custom, DevicePairingKinds_ConfirmOnly | DevicePairingKinds_ConfirmPinMatch |
                                                   DevicePairingKinds_DisplayPin | DevicePairingKinds_ProvidePin, &pair_op);
    if (FAILED(hr)) fail("PairAsync", hr);
    wait_async((IInspectable *)pair_op);
    IAsyncOperation_DevicePairingResult_GetResults(pair_op, &result);
    IAsyncOperation_DevicePairingResult_Release(pair_op);
    IDevicePairingResult_get_Status(result, &status);
    IDevicePairingResult_Release(result);
    IDeviceInformationCustomPairing_remove_PairingRequested(custom, token);
    IDeviceInformationCustomPairing_Release(custom);
    IDeviceInformationPairing2_Release(pairing2);
    IDeviceInformationPairing_get_IsPaired(pairing, &paired);
    IDeviceInformationPairing_Release(pairing);
    printf("pair status: %d requests: %u paired: %d\n", status, requests, paired);

    printf("notify after: %d\n", subscribe_settled(device));
    IBluetoothLEDevice_Release(device);
    RoUninitialize();
    return status == DevicePairingResultStatus_Paired ? 0 : 1;
}
