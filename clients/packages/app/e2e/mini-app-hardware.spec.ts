import { test, expect, type CDPSession } from "@playwright/test";
import { build } from "esbuild";
import { startE2eTestServer, type E2eTestServer } from "./test-server";
import { mkdtemp, rm } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { browserNetworkArgs } from "../../../../scripts/test-network-browser.mjs";

test.use({
  launchOptions: {
    args: [
      ...browserNetworkArgs(),
      "--autoplay-policy=no-user-gesture-required",
      // Drive Web Audio without a system sound device (CI runs in Mac VMs).
      "--disable-audio-output",
    ],
  },
});

// The shipped document and CSP, opaque frame and MessageChannel. CDP supplies hardware, not a replacement Web API.
let server: E2eTestServer;
let directory: string;
let origin: string;
let emulated: CDPSession | undefined;
test.afterEach(async () => {
  if (emulated) {
    await emulated.send("BluetoothEmulation.disable");
    await emulated.detach();
    emulated = undefined;
  }
});

const application = `<!doctype html><body>
<button id="usb">Choose USB</button><button id="bluetooth">Choose Bluetooth</button>
<button id="disconnect">Disconnect</button><output id="result"></output>
<script>
const output = (value) => document.querySelector('output').textContent = value;
document.querySelector('#usb').onclick = async () => {
  try { await navigator.usb.requestDevice({ filters: [] }); output('usb:selected'); }
  catch (error) { output('usb:' + error.name); }
};
let device;
document.querySelector('#bluetooth').onclick = async () => {
  try {
    output('bluetooth:choosing');
    device = await navigator.bluetooth.requestDevice({filters: [{services: ['battery_service']}]});
    device.addEventListener('gattserverdisconnected', () => output('bluetooth:disconnected'));
    output('bluetooth:connecting');
    const gatt = await device.gatt.connect();
    output('bluetooth:discovering');
    const service = await gatt.getPrimaryService('battery_service');
    const characteristic = await service.getCharacteristic('battery_level');
    output('bluetooth:reading');
    const value = await characteristic.readValue();
    await characteristic.writeValueWithResponse(new Uint8Array([42]));
    output('bluetooth:read:' + value.getUint8(0) + ':wrote:42');
  } catch (error) { output('bluetooth:' + error.name + ':' + error.message); }
};
document.querySelector('#disconnect').onclick = () => device.gatt.disconnect();
</script></body>`;

// A stereo Web Audio source replaces physical capture. The host graph, port transfer, runtime and SDK remain real.
const audioApplication = `<!doctype html><body><button id="record">Record channels</button><output></output><script>
document.querySelector('#record').onclick = async () => {
  try {
    const devices = await comma.microphone.devices();
    let recording;
    let finished = false;
    recording = await comma.microphone.startChannels({deviceId:'fixture',channelCount:2,channels:[1,0]}, async samples => {
      if (!recording || finished || samples.length !== 2) return;
      const values = samples.map(channel => channel[channel.length - 1]);
      if (Math.abs(values[0] - 0.5) > 0.001 || Math.abs(values[1] - 0.125) > 0.001) return;
      finished = true;
      await recording.stop();
      document.querySelector('output').textContent = JSON.stringify({devices, values, channelCount:recording.channelCount, channels:recording.channels, sampleRate:recording.sampleRate, origin:globalThis.origin});
    });
  } catch(error) { document.querySelector('output').textContent = error.message; }
};
</script></body>`;

test.beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), "comma-hardware-"));
  const output = join(directory, "runtime.cjs");
  await build({
    entryPoints: [resolve("packages/chat-contract/src/mini-app/runtime.ts")],
    outfile: output,
    bundle: true,
    platform: "node",
    format: "cjs",
  });
  const runtime = createRequire(import.meta.url)(output) as {
    miniAppRuntimeDocument(): string;
    miniAppRuntimeCsp: string;
    miniAppFrameSandbox: string;
    miniAppFrameAllow(capabilities: string[]): string;
  };
  const audioHost = await build({
    entryPoints: [resolve("packages/app/src/components/apps/miniAppDevices.ts")],
    bundle: true,
    write: false,
    platform: "browser",
    format: "iife",
    globalName: "miniAppAudioHost",
    define: { "import.meta.env.SSR": "false" },
  });
  server = await startE2eTestServer((request, response) => {
    if (request.url === "/audio-host.js") {
      response.setHeader("content-type", "text/javascript");
      response.end(audioHost.outputFiles[0]!.text);
      return;
    }
    response.setHeader("content-type", "text/html");
    if (request.url === "/app-runtime/") {
      response.setHeader("content-security-policy", runtime.miniAppRuntimeCsp);
      response.end(runtime.miniAppRuntimeDocument());
      return;
    }
    const microphone = request.url === "/microphone";
    const capabilities = microphone
      ? ["microphone"]
      : request.url === "/denied"
        ? []
        : ["usb", "bluetooth"];
    response.end(`<!doctype html><body>${microphone ? '<script src="/audio-host.js"></script>' : ""}<script>
      if (${microphone}) {
        const audio = new AudioContext();
        const destination = new MediaStreamAudioDestinationNode(audio, {channelCount:2, channelCountMode:'explicit', channelInterpretation:'discrete'});
        const merger = audio.createChannelMerger(2);
        [0.125,0.5].forEach((value,index) => {
          const source = audio.createConstantSource();
          source.offset.value = value;
          source.connect(merger,0,index);
          source.start();
        });
        merger.connect(destination);
        const track = destination.stream.getAudioTracks()[0];
        // Only the device ID is synthetic. Channel count comes from the real stream.
        const settings = track.getSettings();
        track.getSettings = () => ({...settings, deviceId:'fixture'});
        navigator.mediaDevices.getUserMedia = async constraints => {
          window.audioConstraints = constraints;
          await audio.resume();
          return destination.stream;
        };
        navigator.mediaDevices.enumerateDevices = async () => [{kind:'audioinput',deviceId:'fixture',label:'Stereo input',getCapabilities:()=>({channelCount:{min:2,max:2},sampleRate:{min:audio.sampleRate,max:audio.sampleRate}})}];
        window.audioTrack = track;
      }
      addEventListener('message', event => {
        const frame = document.querySelector('iframe');
        if (event.source !== frame.contentWindow || event.data?.type !== 'comma-app:ready' || frame.dataset.started) return;
        frame.dataset.started = 'true';
        const channel = new MessageChannel();
        if (${microphone}) {
          const host = new miniAppAudioHost.MiniAppDevices((message, transfer) => channel.port1.postMessage(message, transfer), () => frame);
          channel.port1.onmessage = async event => {
            const call = event.data;
            if (call.type !== 'call') return;
            const result = await host.run(call.op,call.args);
            channel.port1.postMessage(result.ok ? {type:'result',id:call.id,ok:true,value:result.value} : {type:'result',id:call.id,ok:false,error:{code:result.code,message:result.message}});
          };
        }
        frame.contentWindow.postMessage({type:'comma-app:init', init:{
          app:{id:'hardware',name:'Hardware',version:1},viewer:null,theme:'light',tokens:{},locale:'en-US',timeZone:'UTC',
          capabilities:${JSON.stringify(capabilities)},grants:[],storage:[],backend:false
        }}, '*', [channel.port2]);
        const data = new TextEncoder().encode(${JSON.stringify(microphone ? audioApplication : application).replaceAll("</script", "<\\/script")}).buffer;
        channel.port1.postMessage({type:'files',files:[{path:'index.html',mime:'text/html',data}]}, [data]);
      });
    </script><iframe id="app" sandbox="${runtime.miniAppFrameSandbox}" allow="${runtime.miniAppFrameAllow(capabilities)}" src="/app-runtime/"></iframe></body>`);
  });
  origin = server.origin;
});

test.afterAll(async () => {
  await server.close();
  await rm(directory, { recursive: true, force: true });
});

async function emulateBluetooth(cdp: CDPSession) {
  emulated = cdp;
  await cdp.send("BluetoothEmulation.enable", {
    state: "powered-on",
    leSupported: true,
  });
  await cdp.send("BluetoothEmulation.simulatePreconnectedPeripheral", {
    address: "09:09:09:09:09:09",
    name: "Test sensor",
    manufacturerData: [],
    knownServiceUuids: ["0000180f-0000-1000-8000-00805f9b34fb"],
  });
}

test("opaque mini-app frames use only declared device APIs and cannot read the host", async ({
  page,
  browser,
}) => {
  const cdp = await browser.newBrowserCDPSession();
  await emulateBluetooth(cdp);
  for (const path of ["/denied", "/allowed"]) {
    await page.goto(origin + path);
    await page.frameLocator("iframe").locator("#usb").waitFor();
    const frame = page
      .frames()
      .find((candidate) => candidate.url().endsWith("/app-runtime/"))!;
    const result = await frame.evaluate(async () => {
      const hardware = navigator as Navigator & {
        usb: { getDevices(): Promise<unknown[]> };
        bluetooth: { getAvailability(): Promise<boolean> };
      };
      let usb: string;
      try {
        await hardware.usb.getDevices();
        usb = "allowed";
      } catch (error) {
        usb = (error as Error).name;
      }
      let parentAccess: string;
      try {
        void parent.document;
        parentAccess = "allowed";
      } catch (error) {
        parentAccess = (error as Error).name;
      }
      return {
        origin: globalThis.origin,
        usb,
        bluetooth: await hardware.bluetooth.getAvailability(),
        parentAccess,
      };
    });
    expect(result).toEqual({
      origin: "null",
      usb: path === "/allowed" ? "allowed" : "SecurityError",
      bluetooth: path === "/allowed",
      parentAccess: "SecurityError",
    });
  }
});

test("an opaque mini-app requests a device, reads and writes BLE data, then disconnects", async ({
  page,
  browser,
}) => {
  const cdp = await browser.newBrowserCDPSession();
  await emulateBluetooth(cdp);
  const address = "09:09:09:09:09:09";
  const { serviceId } = await cdp.send("BluetoothEmulation.addService", {
    address,
    serviceUuid: "0000180f-0000-1000-8000-00805f9b34fb",
  });
  await cdp.send("BluetoothEmulation.addCharacteristic", {
    serviceId,
    characteristicUuid: "00002a19-0000-1000-8000-00805f9b34fb",
    properties: { read: true, write: true },
  });
  const writes: string[] = [];
  cdp.on("BluetoothEmulation.gattOperationReceived", (event) => {
    void cdp.send("BluetoothEmulation.simulateGATTOperationResponse", {
      ...event,
      code: 0,
    });
  });
  cdp.on("BluetoothEmulation.characteristicOperationReceived", (event) => {
    if (event.type === "write") writes.push(event.data!);
    void cdp.send("BluetoothEmulation.simulateCharacteristicOperationResponse", {
      characteristicId: event.characteristicId,
      type: event.type,
      code: 0,
      ...(event.type === "read" ? { data: Buffer.from([73]).toString("base64") } : {}),
    });
  });
  await page.goto(origin + "/allowed");
  await page.frameLocator("iframe").locator("#bluetooth").waitFor();
  const access = await page.context().newCDPSession(page);
  await access.send("DeviceAccess.enable");
  let selected = false;
  access.on("DeviceAccess.deviceRequestPrompted", (event) => {
    const device = event.devices.find((candidate) => candidate.id === address);
    if (!device || selected) return;
    selected = true;
    void access.send("DeviceAccess.selectPrompt", {
      id: event.id,
      deviceId: device.id,
    });
  });
  const frame = page.frameLocator("iframe");
  await frame.locator("#bluetooth").click();
  await expect(frame.locator("output")).toHaveText("bluetooth:read:73:wrote:42");
  expect(writes).toEqual([Buffer.from([42]).toString("base64")]);
  await frame.locator("#disconnect").click();
  await expect(frame.locator("output")).toHaveText("bluetooth:disconnected");
});

test("microphone channels cross the opaque frame without mixing and stop capture", async ({
  page,
}) => {
  await page.goto(origin + "/microphone");
  const frame = page.frameLocator("iframe");
  await frame.locator("#record").click();
  await expect(frame.locator("output")).toContainText('"values"');
  const result = JSON.parse(await frame.locator("output").innerText());
  expect(result).toMatchObject({
    origin: "null",
    channelCount: 2,
    channels: [1, 0],
    devices: [{ id: "fixture", channelCount: { min: 2, max: 2 } }],
  });
  expect(result.values[0]).toBeCloseTo(0.5, 3);
  expect(result.values[1]).toBeCloseTo(0.125, 3);
  expect(result.sampleRate).toBeGreaterThan(0);
  expect(await page.evaluate(() => Reflect.get(window, "audioTrack").readyState)).toBe(
    "ended"
  );
  expect(
    await page.evaluate(() => Reflect.get(window, "audioConstraints"))
  ).toMatchObject({
    audio: { deviceId: { exact: "fixture" }, channelCount: { exact: 2 } },
  });
});
