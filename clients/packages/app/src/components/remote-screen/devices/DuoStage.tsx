// The iPhone Duo as a live 3D model (three.js), loaded only where one shows: the simulator's picture on the screen that
// shows it, the model moving between postures. It draws only when something changed (a frame, a move, a size).
import { uiClock } from "@comma/ui/clock";
import { isReducedMotionEnabled } from "@comma/ui/tokens";
import {
  useEffect,
  useImperativeHandle,
  useRef,
  type Ref,
  type RefObject,
} from "react";
import {
  AdditiveBlending,
  AnimationMixer,
  Box3,
  CanvasTexture,
  DirectionalLight,
  Color,
  DoubleSide,
  EquirectangularReflectionMapping,
  Euler,
  Group,
  HemisphereLight,
  LinearFilter,
  Mesh,
  MeshBasicMaterial,
  MeshStandardMaterial,
  NeutralToneMapping,
  PerspectiveCamera,
  PMREMGenerator,
  Raycaster,
  Scene,
  SRGBColorSpace,
  Texture,
  Vector2,
  Vector3,
  WebGLRenderer,
  type AnimationAction,
  type Material,
  type Object3D,
} from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { DUO_METAL_LIGHT, DUO_METAL_ROUGHNESS, duoStudioCanvas } from "./duoStudio";
import type { ScreenTurn } from "../screenDevice";
import duoBlackUrl from "./iphone-duo-black.glb?url";
import duoLightUrl from "./iphone-duo.glb?url";
import {
  DUO_MODEL_AXES,
  DUO_POSTURE_MS,
  duoEase,
  duoFrame,
  duoFramingBetween,
  duoPoseBetween,
  duoPoseOf,
  duoTiltAccumulate,
  duoTiltAngles,
  type DuoFraming,
  type DuoPoseState,
  type DuoTilt,
} from "./duoPose";
import {
  duoPictureAt,
  duoTextureMatrix,
  type DuoPoint,
  type DuoPosture,
  type DuoScreen,
} from "./duoScreens";

/** The video's current frame, when it has one to give. */
function videoFrameOf(video: HTMLVideoElement): VideoFrame | undefined {
  if (typeof VideoFrame === "undefined" || video.readyState < 2) return undefined;
  try {
    return new VideoFrame(video);
  } catch {
    return undefined;
  }
}

/** What the stage round it asks of the model. */
export type DuoStageHandle = {
  /** Where a point of the page is on the picture of the screen that shows, if it is on it and nothing is in front. */
  pick(clientX: number, clientY: number): DuoPoint | undefined;
  /** Turns the device a little more for a drag off its screens (`dx`, `dy` pixels since the last call). */
  tilt(dx: number, dy: number): void;
};

export type DuoStageProps = {
  /** The simulator's picture: its video, or (a fixture) a canvas drawn once per `sourceVersion`. */
  source: RefObject<HTMLVideoElement | HTMLCanvasElement | null>;
  sourceVersion?: number | undefined;
  /** The screen the picture is on (the simulator's fold says it). */
  screen: DuoScreen;
  /** How the picture arrives turned (degrees clockwise): it is upright for the viewer. */
  pictureTurn: ScreenTurn;
  posture: DuoPosture;
  /** How far the model is turned clockwise before the viewer (duoModelTurn). */
  modelTurn: ScreenTurn;
  finish?: "light" | "black" | undefined;
  handle?: Ref<DuoStageHandle> | undefined;
  /** This page cannot draw in 3D (no WebGL): the stage round it draws the device another way. */
  onUnavailable?: (() => void) | undefined;
};

// A long lens: the device reads flat-on with little perspective, as in a product shot.
const FOV = 14;
const SCREEN_MESHES: Record<DuoScreen, readonly string[]> = {
  cover: ["ScreenCover"],
  inner: ["ScreenInner_Camera", "ScreenInner_Crease", "ScreenInner_Cover"],
};
// The rig's animations: frame = 180 - opening, at this rate.
const RIG_FPS = 24;

type Model = {
  mixer: AnimationMixer;
  actions: AnimationAction[];
  screens: Record<DuoScreen, Mesh[]>;
  /** Each screen mesh's own (dark, glossy) material, shown while it shows no picture. */
  dark: Map<Mesh, Material | Material[]>;
};

export default function DuoStage(props: DuoStageProps) {
  const host = useRef<HTMLDivElement>(null);
  const latest = useRef(props);
  latest.current = props;
  // What the effect below set up, for the props' effects and the handle.
  const world = useRef<{
    invalidate(): void;
    pick(clientX: number, clientY: number): DuoPoint | undefined;
    refreshPicture(): void;
    retarget(): void;
    tilt(dx: number, dy: number): void;
  } | null>(null);

  useImperativeHandle(
    props.handle,
    () => ({
      pick: (x, y) => world.current?.pick(x, y),
      tilt: (dx, dy) => world.current?.tilt(dx, dy),
    }),
    []
  );

  const finish = props.finish ?? "light";
  useEffect(() => {
    const element = host.current;
    if (!element) return undefined;
    const view = element.ownerDocument.defaultView ?? window;
    let renderer: WebGLRenderer;
    try {
      renderer = new WebGLRenderer({ antialias: true, alpha: true });
    } catch {
      latest.current.onUnavailable?.();
      return undefined;
    }
    renderer.setClearColor(0x000000, 0);
    renderer.outputColorSpace = SRGBColorSpace;
    renderer.toneMapping = NeutralToneMapping;
    renderer.toneMappingExposure = 1;
    renderer.setPixelRatio(view.devicePixelRatio || 1);
    const canvas = renderer.domElement;
    canvas.className = "comma-remote-screen-duo-canvas";
    element.append(canvas);

    // A light studio: a soft room for the metal and glass to show, a sky over a pale floor, a key and a fill.
    const scene = new Scene();
    const pmrem = new PMREMGenerator(renderer);
    // The studio the metal mirrors (duoStudio.ts): hard white strips and black flags, so polished edges read bright.
    const studio = new CanvasTexture(duoStudioCanvas(element.ownerDocument));
    studio.mapping = EquirectangularReflectionMapping;
    studio.colorSpace = SRGBColorSpace;
    const environment = pmrem.fromEquirectangular(studio).texture;
    studio.dispose();
    scene.environment = environment;
    scene.environmentIntensity = 1.15;
    scene.add(new HemisphereLight(0xffffff, 0xb8b4ac, 0.35));
    const key = new DirectionalLight(0xffffff, 0.9);
    key.position.set(0.6, 1, 1.2);
    const fill = new DirectionalLight(0xffffff, 0.3);
    fill.position.set(-1.2, 0.2, 0.8);
    scene.add(key, fill);

    const camera = new PerspectiveCamera(FOV, 1, 0.01, 10);
    const pivot = new Group();
    const holder = new Group();
    holder.quaternion.copy(DUO_MODEL_AXES);
    pivot.add(holder);
    scene.add(pivot);

    // The picture: one texture on one material, put on whichever screen shows it.
    const pictureMaterial = new MeshBasicMaterial({
      toneMapped: false,
      side: DoubleSide,
    });
    // The cover glass over each screen: only the room it reflects (not the lights' sharp highlights), added over the
    // picture.
    const glass = new MeshBasicMaterial({
      color: 0x000000,
      envMap: environment,
      reflectivity: 0.07,
      transparent: true,
      blending: AdditiveBlending,
      depthWrite: false,
      polygonOffset: true,
      polygonOffsetFactor: -1,
      polygonOffsetUnits: -1,
    });
    let texture: Texture | null = null;
    let textureSize = "";
    /** The video frame the texture shows now, let go when the next takes its place. */
    let lastFrame: VideoFrame | undefined;
    const closeFrame = () => {
      lastFrame?.close();
      lastFrame = undefined;
    };
    let showing: { screen: DuoScreen; turn: ScreenTurn } | null = null;
    let model: Model | null = null;
    let disposed = false;

    const showPicture = () => {
      if (!model) return;
      const { screen, pictureTurn } = latest.current;
      const on = texture !== null;
      for (const name of ["cover", "inner"] as const)
        for (const mesh of model.screens[name])
          mesh.material =
            on && name === screen ? pictureMaterial : model.dark.get(mesh)!;
      if (texture && (showing?.screen !== screen || showing.turn !== pictureTurn)) {
        texture.matrix.set(...duoTextureMatrix(screen, pictureTurn));
        showing = { screen, turn: pictureTurn };
      }
    };

    /** Takes the source's current picture: a new texture when its size changed. */
    const refreshPicture = () => {
      const picture = latest.current.source.current;
      const width =
        picture instanceof HTMLVideoElement
          ? picture.videoWidth
          : (picture?.width ?? 0);
      const height =
        picture instanceof HTMLVideoElement
          ? picture.videoHeight
          : (picture?.height ?? 0);
      const size = picture && width > 0 && height > 0 ? `${width}x${height}` : "";
      // A video's frame goes to the texture as a VideoFrame: three.js sizes a texture by its image's width and height,
      // which a <video> has as attributes (none: 0), so its texture was made empty and every frame missed it.
      const frame =
        picture instanceof HTMLVideoElement && size ? videoFrameOf(picture) : undefined;
      if (size !== textureSize) {
        texture?.dispose();
        closeFrame();
        texture = null;
        showing = null;
        textureSize = size;
        if (picture && size && (frame || !(picture instanceof HTMLVideoElement))) {
          texture = frame
            ? new Texture(frame)
            : new CanvasTexture(picture as HTMLCanvasElement);
          texture.colorSpace = SRGBColorSpace;
          texture.minFilter = LinearFilter;
          texture.magFilter = LinearFilter;
          texture.generateMipmaps = false;
          texture.matrixAutoUpdate = false;
          pictureMaterial.map = texture;
          pictureMaterial.needsUpdate = true;
        } else pictureMaterial.map = null;
      } else if (texture && frame) {
        // (the frame before is on the GPU by now: it is let go)
        closeFrame();
        texture.image = frame;
      }
      if (frame) lastFrame = frame;
      if (texture) texture.needsUpdate = true;
      showPicture();
      invalidate();
    };

    const poseModel = (state: DuoPoseState) => {
      pivot.quaternion.copy(state.turn);
      if (model) {
        const time = Math.min(
          Math.max(0, 180 - state.opening) / RIG_FPS,
          180 / RIG_FPS - 1e-4
        );
        for (const action of model.actions) action.time = time;
        model.mixer.update(0);
      }
      scene.updateMatrixWorld(true);
    };
    const box = new Box3();
    const framingOf = (state: DuoPoseState, aspect: number): DuoFraming => {
      poseModel(state);
      box.setFromObject(pivot, true);
      return duoFrame(box, FOV, aspect);
    };

    // Where the model stands, and the change under way.
    const targetOf = () => {
      const { posture, modelTurn } = latest.current;
      return {
        key: `${posture.id}/${modelTurn}`,
        state: duoPoseOf(posture, modelTurn),
      };
    };
    let target = targetOf();
    let current: DuoPoseState = target.state;
    let move: { from: DuoPoseState; to: DuoPoseState; start: number } | null = null;
    let framings: { aspect: number; from: DuoFraming; to: DuoFraming } | null = null;
    // The slight turn a drag off the screens gives, and the turn a posture move began with (it goes back to none).
    let tiltRaw: DuoTilt = { yaw: 0, pitch: 0 };
    let tiltFrom: DuoTilt = { yaw: 0, pitch: 0 };
    // What the camera showed last: a change that interrupts another goes on from there.
    let shown: { aspect: number; framing: DuoFraming } | null = null;

    let cancelFrame: (() => void) | null = null;
    const invalidate = () => {
      if (cancelFrame || disposed) return;
      cancelFrame = uiClock.frame(() => {
        cancelFrame = null;
        draw();
      }, view);
    };

    const draw = () => {
      const width = element.clientWidth;
      const height = element.clientHeight;
      if (!model || width === 0 || height === 0) return;
      const aspect = width / height;
      let share = 1;
      if (move) {
        share = duoEase((uiClock.monotonic() - move.start) / DUO_POSTURE_MS);
        current = duoPoseBetween(move.from, move.to, share);
      }
      const from = move?.from ?? current;
      const to = move?.to ?? current;
      // (at rest it is measured once, not on every frame of the picture)
      if (!framings || framings.aspect !== aspect)
        framings = {
          aspect,
          from:
            move && shown?.aspect === aspect ? shown.framing : framingOf(from, aspect),
          to: framingOf(to, aspect),
        };
      const framing = duoFramingBetween(framings.from, framings.to, share);
      shown = { aspect, framing };
      poseModel(current);
      camera.aspect = aspect;
      // The tilt orbits the camera round the framing's centre: as if the device turned the other way.
      const tilt = move
        ? { yaw: tiltFrom.yaw * (1 - share), pitch: tiltFrom.pitch * (1 - share) }
        : duoTiltAngles(tiltRaw);
      const orbit = new Vector3(0, 0, framing.distance).applyEuler(
        new Euler((-tilt.pitch * Math.PI) / 180, (-tilt.yaw * Math.PI) / 180, 0, "YXZ")
      );
      camera.position.set(
        framing.center.x + orbit.x,
        framing.center.y + orbit.y,
        framing.center.z + orbit.z
      );
      camera.lookAt(framing.center);
      const reach = framing.distance;
      camera.near = reach / 20;
      camera.far = reach * 4;
      camera.updateProjectionMatrix();
      renderer.render(scene, camera);
      if (move && share >= 1) {
        move = null;
        framings = null;
        tiltFrom = { yaw: 0, pitch: 0 };
      }
      // Drawn and at rest: a press finds the screen where it shows (a test waits for this).
      canvas.toggleAttribute("data-still", !move);
      if (move) invalidate();
    };

    const retarget = () => {
      const next = targetOf();
      if (next.key === target.key) return;
      target = next;
      if (!model || isReducedMotionEnabled()) {
        move = null;
        framings = null;
        current = next.state;
      } else {
        move = { from: current, to: next.state, start: uiClock.monotonic() };
        framings = null;
        tiltFrom = duoTiltAngles(tiltRaw);
      }
      tiltRaw = { yaw: 0, pitch: 0 };
      invalidate();
    };

    const resize = () => {
      const width = element.clientWidth;
      const height = element.clientHeight;
      if (width === 0 || height === 0) return;
      renderer.setPixelRatio(view.devicePixelRatio || 1);
      renderer.setSize(width, height, false);
      framings = null;
      invalidate();
    };
    const sized = new view.ResizeObserver(resize);
    sized.observe(element);

    const raycaster = new Raycaster();
    const pick = (clientX: number, clientY: number): DuoPoint | undefined => {
      if (!model) return undefined;
      const rect = canvas.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) return undefined;
      const at = new Vector2(
        ((clientX - rect.left) / rect.width) * 2 - 1,
        -((clientY - rect.top) / rect.height) * 2 + 1
      );
      raycaster.setFromCamera(at, camera);
      const [first] = raycaster.intersectObject(holder, true);
      const { screen, pictureTurn } = latest.current;
      if (!first?.uv || !model.screens[screen].includes(first.object as Mesh))
        return undefined;
      return duoPictureAt(screen, pictureTurn, first.uv);
    };

    const tilt = (dx: number, dy: number) => {
      if (move) return;
      tiltRaw = duoTiltAccumulate(tiltRaw, dx, dy);
      invalidate();
    };

    world.current = { invalidate, pick, refreshPicture, retarget, tilt };

    // The picture's frames, as they come.
    let cancelVideo: (() => void) | null = null;
    const watchSource = () => {
      const picture = latest.current.source.current;
      if (picture instanceof HTMLVideoElement) {
        // A frame is taken when the video presents it, and also when a display frame finds the video moved on: a
        // video the page does not show may present nothing, and its frame callbacks then never come.
        let request = 0;
        let tick: (() => void) | null = null;
        let seen = -1;
        const decoded = () =>
          picture.getVideoPlaybackQuality?.().totalVideoFrames ?? picture.currentTime;
        const onFrame = () => {
          seen = decoded();
          refreshPicture();
          request = picture.requestVideoFrameCallback(onFrame);
        };
        if (picture.requestVideoFrameCallback)
          request = picture.requestVideoFrameCallback(onFrame);
        const poll = () => {
          if (picture.readyState >= 2 && decoded() !== seen) {
            seen = decoded();
            refreshPicture();
          }
          tick = uiClock.frame(poll, view);
        };
        tick = uiClock.frame(poll, view);
        cancelVideo = () => {
          if (picture.cancelVideoFrameCallback)
            picture.cancelVideoFrameCallback(request);
          tick?.();
        };
      }
      refreshPicture();
    };

    const loader = new GLTFLoader();
    loader.load(
      finish === "black" ? duoBlackUrl : duoLightUrl,
      (gltf) => {
        if (disposed) {
          disposeTree(gltf.scene);
          return;
        }
        const screens: Record<DuoScreen, Mesh[]> = { cover: [], inner: [] };
        const dark = new Map<Mesh, Material | Material[]>();
        gltf.scene.traverse((object) => {
          if (!(object instanceof Mesh)) return;
          // Polished metal, whatever the file says: near mirror, and the light finish's silver champagne.
          for (const material of [object.material].flat())
            if (
              material instanceof MeshStandardMaterial &&
              material.name in DUO_METAL_ROUGHNESS
            ) {
              material.metalness = 1;
              material.roughness = DUO_METAL_ROUGHNESS[material.name]!;
              if (finish === "light" && material.name !== "CameraPlate")
                material.color = new Color().setRGB(
                  DUO_METAL_LIGHT.r,
                  DUO_METAL_LIGHT.g,
                  DUO_METAL_LIGHT.b,
                  SRGBColorSpace
                );
            }
          for (const name of ["cover", "inner"] as const)
            if (SCREEN_MESHES[name].includes(object.name)) {
              screens[name].push(object);
              dark.set(object, object.material);
            }
        });
        for (const mesh of [...screens.cover, ...screens.inner]) {
          const sheen = new Mesh(mesh.geometry, glass);
          sheen.name = `${mesh.name}_Glass`;
          // (the crease bends as its screen does: the same weights)
          sheen.morphTargetInfluences = mesh.morphTargetInfluences;
          sheen.morphTargetDictionary = mesh.morphTargetDictionary;
          sheen.renderOrder = 1;
          sheen.raycast = () => undefined;
          mesh.add(sheen);
        }
        const mixer = new AnimationMixer(gltf.scene);
        const actions = gltf.animations.map((clip) => {
          const action = mixer.clipAction(clip);
          action.play();
          return action;
        });
        holder.add(gltf.scene);
        model = { mixer, actions, screens, dark };
        current = target.state;
        watchSource();
        resize();
        invalidate();
      },
      undefined,
      () => undefined
    );

    return () => {
      disposed = true;
      world.current = null;
      cancelFrame?.();
      cancelVideo?.();
      sized.disconnect();
      model?.mixer.stopAllAction();
      if (model) for (const [mesh, material] of model.dark) mesh.material = material;
      disposeTree(holder);
      pictureMaterial.dispose();
      glass.dispose();
      texture?.dispose();
      closeFrame();
      environment.dispose();
      pmrem.dispose();
      renderer.dispose();
      renderer.forceContextLoss();
      canvas.remove();
    };
  }, [finish]);

  // A new posture or turn moves the model; a new screen or turn of the picture puts it anew.
  const { posture, modelTurn, screen, pictureTurn, sourceVersion } = props;
  useEffect(() => {
    world.current?.retarget();
  }, [posture, modelTurn]);
  useEffect(() => {
    world.current?.refreshPicture();
  }, [screen, pictureTurn, sourceVersion]);

  return <div className="comma-remote-screen-duo-model" ref={host} />;
}

/** Frees what a tree of the scene holds on the GPU. */
function disposeTree(root: Object3D) {
  root.traverse((object) => {
    if (!(object instanceof Mesh)) return;
    object.geometry.dispose();
    for (const material of [object.material].flat() as Material[]) material.dispose();
  });
}
