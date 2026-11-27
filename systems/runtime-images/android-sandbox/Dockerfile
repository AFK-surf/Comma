# A Linux Android device sandbox. The coding image supplies the Station runtime.
ARG CODING_SANDBOX_IMAGE=comma-coding-sandbox:amd64
FROM ${CODING_SANDBOX_IMAGE}
ARG PACKAGE_SNAPSHOT
ARG ANDROID_CMDLINE_VERSION=15859902
USER root
WORKDIR /
ENV HOME=/root

RUN --mount=type=bind,source=systems/runtime-images/station/apt-package-recovery.mjs,target=/tmp/apt-package-recovery.mjs \
    set -eu; \
    apt-get update \
    && node /tmp/apt-package-recovery.mjs "$PACKAGE_SNAPSHOT" install -y --no-install-recommends \
       udev openjdk-21-jre-headless libasound2t64 libdbus-1-3 libfontconfig1 libgl1 libnss3 libpulse0 \
       libx11-6 libx11-xcb1 libxcb1 libxcb-cursor0 libxcb-image0 libxcb-keysyms1 libxcb-randr0 \
       libxcb-render-util0 libxcb-render0 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 \
       libxcb-icccm4 libxcb-sync1 libxcb-xkb1 libxcomposite1 libxcursor1 libxi6 \
       libxinerama1 libxkbcommon0 libxkbcommon-x11-0 libxkbfile1 libxrandr2 libxtst6 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --force kvm

ENV ANDROID_HOME=/opt/android-sdk ANDROID_SDK_ROOT=/opt/android-sdk
RUN set -eu; \
    curl --fail --location --silent --show-error --retry 4 --retry-all-errors --retry-delay 2 --connect-timeout 30 \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_VERSION}_latest.zip" \
      --output /tmp/android-tools.zip \
    && mkdir -p "$ANDROID_HOME/cmdline-tools" /tmp/android-tools \
    && unzip -q /tmp/android-tools.zip -d /tmp/android-tools \
    && mv /tmp/android-tools/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest" \
    && rm -rf /tmp/android-tools.zip /tmp/android-tools
ENV PATH=/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:/opt/android-sdk/cmdline-tools/latest/bin:$PATH
# The official manager resolves stable revisions at build time. The image keeps them.
RUN set -eu; \
    yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null \
    && sdkmanager --sdk_root="$ANDROID_HOME" --channel=0 --install \
       "platform-tools" "emulator" "system-images;android-30;google_apis;x86_64" \
    && sdkmanager --sdk_root="$ANDROID_HOME" --list_installed \
    && rm -rf /root/.android \
    && chmod -R a-w "$ANDROID_HOME"

COPY systems/runtime-images/android-sandbox/android-env /usr/local/lib/comma-android-env
COPY systems/runtime-images/android-sandbox/comma-android-init /usr/local/bin/comma-android-init
COPY systems/runtime-images/android-sandbox/comma-android-station /usr/local/bin/comma-android-station
COPY systems/runtime-images/android-sandbox/comma-android-station.service /etc/systemd/system/comma-android-station.service
COPY systems/runtime-images/android-sandbox/65-comma-kvm.rules /etc/udev/rules.d/65-comma-kvm.rules
RUN set -eu; \
    chmod 0755 /usr/local/bin/comma-android-init /usr/local/bin/comma-android-station \
    && ln -s /usr/local/lib/comma-android-env /etc/profile.d/comma-android.sh \
    && systemctl disable comma-station.service \
    && systemctl enable comma-android-station.service
