import { isReducedMotionEnabled } from "@comma/ui/tokens";
import { uiClock } from "@comma/ui/clock";
import { useLayoutEffect, useRef } from "react";

// The wave's colours: an LCH ladder on the brand's #1040F2 (L 38, C 106, H 301),
// stepping the hue by 30° each way and raising the lightness away from the base,
// chroma cut back to fit sRGB. Front to tail: H 241, 271, 301, 331, 1, 31.
const ramp = ["#6dd2ff", "#179bf9", "#1040f2", "#de00d1", "#fd5a97", "#ffaca2"];

// The avatar comes out of Quick Chat's NameDrop wave (the overlay's
// name-drop-effect.ts, now the QuickChatHosts' NameDropEffect.swift and
// effect.hlsl), drawn in the area round the avatar: a ridge of mesh rises through the
// area, refracting what is under it upward with a recoil behind it; its band
// blurs and draws the red and blue apart; a rainbow arc of the ladder's
// colours rides it. Above the ridge nothing is yet; below it the face settles.
// Same shapes as Quick Chat's displacement(), scaled from a screen to the avatar's area.
const vertex = `attribute vec2 p;varying vec2 uv;void main(){uv=p*.5+.5;gl_Position=vec4(p,0.,1.);}`;

const fragment = `
precision mediump float;
uniform sampler2D u_tex;
uniform vec4 u_shock;  // ridge y, its presence, recoil y, its presence (0 bottom .. 1 top of the area)
uniform vec2 u_band;   // the ridge band's opacity and its colour fringe
uniform float u_arc;   // the rainbow arc's opacity
uniform vec3 u_ramp[6];
varying vec2 uv;
float sq(float x){return x*x;}
vec4 face(vec2 q,float r){
  q=vec2(q.x,1.-q.y);
  if(r<.001)return texture2D(u_tex,q);
  vec4 c=texture2D(u_tex,q)*.2;
  for(int i=0;i<8;i++){float a=6.2831853*(float(i)+.5)/8.;c+=texture2D(u_tex,q+vec2(cos(a),sin(a))*r)*.1;}
  return c;
}
vec3 ladder(float s){
  s=clamp(s,0.,1.)*5.;
  return s<1.?mix(u_ramp[0],u_ramp[1],s):s<2.?mix(u_ramp[1],u_ramp[2],s-1.):s<3.?mix(u_ramp[2],u_ramp[3],s-2.)
    :s<4.?mix(u_ramp[3],u_ramp[4],s-3.):mix(u_ramp[4],u_ramp[5],s-4.);
}
void main(){
  float across=(uv.x-.5)*2.;
  float curve=abs(across);
  // All of the effect across the middle of the area, easing out towards its sides, top and bottom.
  float strength=(1.-smoothstep(.55,1.,curve))*smoothstep(0.,.1,uv.y)*(1.-smoothstep(.88,1.,uv.y));
  // The ridge: a dome, its lens the derivative of a gaussian, its body a bulge, the recoil a smaller one behind.
  float meshDistance=uv.y-(u_shock.x+.12*curve*curve);
  float meshQ=meshDistance/.16;
  float meshDerivative=-2.*meshQ*exp(-meshQ*meshQ);
  float meshBody=exp(-sq(meshDistance/.28));
  float recoilQ=(uv.y-(u_shock.z+.08*curve*curve))/.15;
  float recoilDerivative=-2.*recoilQ*exp(-recoilQ*recoilQ);
  vec2 normal=normalize(vec2(-.25*across,1.));
  float lens=(meshDerivative*.09*u_shock.y+meshBody*.03*u_shock.y+recoilDerivative*.035*u_shock.w)*strength;
  vec2 d=vec2(normal.x*lens-.12*across*curve*meshBody*u_shock.y*strength,normal.y*lens);
  vec2 q=uv+d;
  // Below the ridge the face is there; it blurs in the band, with its red and blue drawn apart.
  float shown=1.-smoothstep(-.18,.04,meshDistance);
  float band=exp(-sq(meshDistance/.2))*u_band.x*strength;
  float blur=band*.045;
  vec4 c=face(q,blur);
  if(band>.002){
    vec3 fr=vec3(face(q+vec2(0.,u_band.y),blur).r,c.g,face(q-vec2(0.,u_band.y),blur).b);
    c.rgb=mix(c.rgb,fr,band);
  }
  // The rainbow arc, its rows the ladder's colours, riding just above the ridge.
  float rows=(meshDistance-.05)/.2;
  float envelope=exp(-rows*rows*1.6)*strength*u_arc;
  vec3 arc=ladder(.5-rows*.5);
  // Over the face the arc tints it; off it, the arc is its own light.
  vec3 under=mix(vec3(1.),c.rgb,c.a);
  vec3 col=mix(c.a>.001?c.rgb:arc,arc*(.6+.4*under),envelope*.85);
  float alpha=max(c.a*shown,envelope*.95);
  gl_FragColor=vec4(col,alpha);
}`;

/** The area the wave runs through, in avatar sizes: the hero's width and a little above and below the face. */
const AREA = { width: 2.6, height: 1.45 };

// Quick Chat's package spring (mass 2, stiffness 300, damping 50), and its recoil, damping ratio 0.4.
const spring = (time: number, begin: number, speed: number) => {
  const local = Math.max(time - begin, 0) * 0.7 * speed;
  return Math.max(
    0,
    Math.min(1, 1 - 3 * Math.exp(-10 * local) + 2 * Math.exp(-15 * local))
  );
};
const bounce = (time: number, begin: number, speed: number) => {
  const local = Math.max(time - begin, 0) * 0.7 * speed;
  const natural = 12.24745;
  const decay = 0.4 * natural;
  const frequency = natural * Math.sqrt(1 - 0.4 ** 2);
  return (
    1 -
    Math.exp(-decay * local) *
      (Math.cos(frequency * local) + (decay / frequency) * Math.sin(frequency * local))
  );
};

/** The face as the card shows it at rest: initials on the card's grey ground, in a circle. */
function face(
  initials: string,
  px: number,
  area: { width: number; height: number },
  ink: string,
  ground: string
) {
  const c = document.createElement("canvas");
  c.width = area.width;
  c.height = area.height;
  const g = c.getContext("2d")!;
  g.translate((area.width - px) / 2, (area.height - px) / 2);
  g.beginPath();
  g.arc(px / 2, px / 2, px / 2, 0, Math.PI * 2);
  g.fillStyle = ground;
  g.fill();
  g.fillStyle = ink;
  g.font = `500 ${Math.round(px * 0.35)}px -apple-system, "SF Pro Display", "PingFang SC", sans-serif`;
  g.textAlign = "center";
  g.textBaseline = "middle";
  g.fillText(initials, px / 2, px / 2 + px * 0.02);
  return c;
}

/**
 * An avatar that comes out of a rising wave of mesh-gradient light, drawn in WebGL, when it is first shown, then
 * rests as a plain bordered avatar. With Reduce Motion, or without WebGL, it is simply there.
 */
export function MeshAvatar({ initials, size }: { initials: string; size: number }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const shell = useRef<HTMLSpanElement>(null);
  // Before the first paint, so the plain face never shows ahead of the wave.
  useLayoutEffect(() => {
    const el = canvas.current;
    const box = shell.current;
    // The OS preference or Comma's own reduced-motion setting.
    const still = isReducedMotionEnabled();
    const gl = el?.getContext("webgl", { premultipliedAlpha: false, alpha: true });
    if (!el || !box || !gl || still) {
      box?.setAttribute("data-rest", "");
      return undefined;
    }
    const scale = Math.min(window.devicePixelRatio || 1, 2);
    el.width = Math.round(size * AREA.width * scale);
    el.height = Math.round(size * AREA.height * scale);
    const styles = getComputedStyle(box);
    const tex = face(
      initials,
      Math.round(size * scale),
      el,
      styles.getPropertyValue("--mesh-avatar-ink").trim() || "#4a4c50",
      styles.getPropertyValue("--mesh-avatar-ground").trim() || "#f1f1f1"
    );
    const compile = (type: number, source: string) => {
      const sh = gl.createShader(type)!;
      gl.shaderSource(sh, source);
      gl.compileShader(sh);
      return sh;
    };
    const program = gl.createProgram()!;
    gl.attachShader(program, compile(gl.VERTEX_SHADER, vertex));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragment));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      box.setAttribute("data-rest", "");
      return undefined;
    }
    gl.useProgram(program);
    // The canvas draws the face from here on, its last frame included; the DOM face stays for no WebGL.
    box.setAttribute("data-mesh", "");
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(
      gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 3, -1, -1, 3]),
      gl.STATIC_DRAW
    );
    const corner = gl.getAttribLocation(program, "p");
    gl.enableVertexAttribArray(corner);
    gl.vertexAttribPointer(corner, 2, gl.FLOAT, false, 0, 0);
    gl.bindTexture(gl.TEXTURE_2D, gl.createTexture());
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, tex);
    gl.viewport(0, 0, el.width, el.height);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    const uniform = (name: string) => gl.getUniformLocation(program, name);
    gl.uniform3fv(
      uniform("u_ramp"),
      ramp.flatMap((c) =>
        [1, 3, 5].map((i) => Number.parseInt(c.slice(i, i + 2), 16) / 255)
      )
    );
    // Quick Chat's shockwave springs, slowed for an area this small so the ridge takes about a second to cross it.
    const delay = 200;
    const end = 3;
    let start = 0;
    let cancel: () => void = () => undefined;
    const draw = (now: number) => {
      start ||= now + delay;
      const t = Math.max(0, now - start) / 1000;
      const travel = spring(t, 0.05, 0.22);
      const presence = 1 - spring(t, 1.1, 0.3);
      gl.uniform4f(
        uniform("u_shock"),
        -0.3 + 1.65 * travel,
        presence,
        -0.3 + 1.25 * bounce(t, 0.35, 0.28),
        spring(t, 0.05, 1.2) * (1 - spring(t, 1.3, 0.35))
      );
      gl.uniform2f(uniform("u_band"), 1 - spring(t, 1.2, 0.3), 0.02 * presence);
      gl.uniform1f(uniform("u_arc"), (1 - spring(t, 1.0, 0.4)) * Math.min(1, t / 0.12));
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      if (t < end) cancel = uiClock.frame(draw);
      else box.setAttribute("data-rest", "");
    };
    cancel = uiClock.frame(draw);
    return () => {
      cancel();
      gl.getExtension("WEBGL_lose_context")?.loseContext();
    };
  }, [initials, size]);
  return (
    <span
      className="comma-mesh-avatar"
      ref={shell}
      style={{ width: size, height: size }}
    >
      <span className="comma-mesh-avatar__face">{initials}</span>
      <canvas
        aria-hidden="true"
        className="comma-mesh-avatar__mesh"
        ref={canvas}
        style={{
          width: size * AREA.width,
          height: size * AREA.height,
          left: (size - size * AREA.width) / 2,
          top: (size - size * AREA.height) / 2,
        }}
      />
    </span>
  );
}
