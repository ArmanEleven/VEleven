# VELEVEN: V2Ray engine integration

## Goal

Keep Defyx as the application and preserve its existing DXcore/Flowline path. Add a separate Xray-backed V2Ray path inside the same Android application and Flutter UI.

The two server collections and their credentials/configuration must remain independent:
- DX: fetched and managed by the existing Defyx Flowline implementation.
- V2Ray: user-added profiles/subscriptions, stored separately from DX data.

Only one tunnel engine may own the Android VPN interface at a time. Switching engines must stop the currently active core before starting the selected core. Neither server collection is deleted or replaced when switching.

## Findings from the current source

### Defyx / VELEVEN

- Flutter communicates with Android through the existing `com.defyx.vpn` MethodChannel in `lib/modules/core/vpn_bridge.dart`.
- `DefyxVpnService` is the existing Android `VpnService`.
- `DefyxVpnService.startVpn()` creates the VPN interface with `Builder.establish()`, retains its `ParcelFileDescriptor`, and passes its file descriptor to DXcore using `Android.startTunnel(fd)`.
- The current disconnect path closes the VPN interface and stops DXcore. This path must become engine-aware before Xray can be started safely.
- DXcore is loaded from the existing `android/app/libs/DXcore.aar`. Do not replace or rename it as part of the Xray work.

### V2Eleven / Xray

- V2Eleven's `CoreVpnService` independently calls `Builder.establish()`. Copying that service into VELEVEN would create a second VPN owner and is not the integration design.
- The reusable Xray boundary is `CoreNativeManager` / `libv2ray`: initialize the Go runtime, create a `CoreController`, call `startLoop(configJson, tunFd)`, then `stopLoop()`.
- V2Eleven's `CoreServiceManager` passes the VPN descriptor's file descriptor to `CoreController.startLoop`.
- V2Eleven obtains `libv2ray.aar` from a pinned AndroidLibXrayLite release during its Android build. The AAR is not committed in that repository.
- V2Eleven currently uses AGP 9.4.1, Kotlin 2.4.21, JDK 21 and NDK 30. VELEVEN/Defyx currently uses AGP 9.0.1, Kotlin 2.3.20 and NDK 29. Do not blindly copy V2Eleven's Gradle versions or its whole app module.

## Integration architecture

```
Flutter UI
  ├── DX servers (existing Flowline data)
  └── V2Ray servers (new isolated profile store)
          |
     Connection coordinator
          |
     DefyxVpnService (single Android VPN owner)
          |
     Existing TUN file descriptor
       ├── DXcore engine
       └── Xray CoreController
```

The shared VPN service owns permission, foreground lifetime, TUN creation and closure. Each engine owns only its own core lifecycle. The Xray path must not start a second `VpnService` or establish another TUN interface.

## Safety invariants for implementation

1. Existing DX Flowline fetch/decode/cache behavior remains unchanged.
2. V2Ray profile data is stored under separate keys/files and never written into DX Flowline storage.
3. Every connection records the active engine explicitly.
4. Stop only the active engine's core; do not call DXcore stop functions when Xray is active, or Xray stop functions when DX is active.
5. Stop the active core successfully before closing the shared TUN descriptor or starting the other engine.
6. On failure, close resources owned by the attempted engine and return to a disconnected state without deleting either server collection.
7. Validate and protect Xray outbound sockets against VPN routing loops before enabling the Xray connection path. This must be verified, not assumed from merely passing the TUN file descriptor.
8. Keep the first implementation Android-only. Do not imply iOS support from the Android Kotlin integration.

## Implementation sequence

- [x] Create an isolated integration branch.
- [x] Inspect the existing Defyx VPN bridge, Android service, manifest and Gradle setup.
- [x] Inspect V2Eleven's Xray controller boundary and build-time AAR dependency.
- [ ] Add a dedicated Xray runtime wrapper that consumes the existing Defyx TUN descriptor.
- [ ] Add a separately persisted V2Ray profile model and import/validation path.
- [ ] Add engine-aware start/stop coordination without changing DXcore behavior.
- [ ] Expose the V2Ray server section through the existing Flutter UI.
- [ ] Add pinned Xray AAR acquisition to Android CI and build/test the APK.
- [ ] Verify connect, disconnect, switch DX-to-Xray, switch Xray-to-DX, failed-start recovery and preservation of both server lists.

## Important open technical check

The Xray path must have a verified Android socket-protection strategy so its outbound sockets do not get routed back into the VPN interface. The integration must not be marked complete until this is confirmed and tested on a device.
