# Android sandbox image

This layer uses an existing `comma-coding-sandbox:amd64` image and its Station release.
Build from the repository root:

```sh
systems/runtime-images/android-sandbox/build.sh /tmp/android-sandbox-image
```

An optional second argument selects another local coding image.
The shared exporter produces the existing L4ES `image.json` and content-addressed image format.
Publish and deploy through the normal mainline release flow.

The build fixes command-line tools at `15859902`.
Official `sdkmanager` selects stable Emulator, platform-tools, and API 30 Google APIs x86_64 package revisions during the build.
The completed image keeps those revisions.
The build log and SDK package metadata show them. Later builds can resolve newer package revisions.

Use an ordinary keep sandbox.
Create each sandbox with login `comma`, 2 vCPUs, 8 GiB RAM, a 32 GiB disk, `semi_persistent=true`, and `keep=true`.
Use labels for nodes with working guest KVM. Confirm KVM and real Emulator execution during deployment.
Use separate sandboxes named `android-nothing` and `android-n2`.

After `sbx-firstboot` creates the login user, initialize the AVD and enroll each Station with its own one-time token:

```sh
sudo -u comma -H comma-android-init
sudo -u comma -H comma-android-station enroll https://YOUR-COMMA-SERVER ONE_TIME_TOKEN --provider comma
```

Each guest uses `/home/comma/.comma/android-station` for its new Device identity and `/home/comma/.android` for Android data.
The image contains no enrollment token or previous Device state.
The Station screen controls start and close `api30-phone`. Its initial Android RAM is 2 GiB and its renderer is SwiftShader.
Station restarts leave the Emulator running. Guest shutdown ends it.
