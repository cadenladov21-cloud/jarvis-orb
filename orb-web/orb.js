// Jarvis Orb renderer: raw WebGL2, no dependencies.
//
// Passes per frame:
//   1. sphere   full-screen shader: deep-blue body, starry core, fresnel rim, halo
//   2. dust     orbiting points, additive
//   3. ribbons  instanced triangle strips whose curves are evaluated on the GPU, additive
//   4. bloom    dual-Kawase down/up chain over the HDR scene
//   5. composite tonemap, premultiplied alpha so the page sits on a transparent window
//
// Public API (called from Swift, or from the console when iterating in a browser):
//   window.orb.setState(name)   idle | hover | listening | thinking | awaitingApproval | speaking | error
//   window.orb.setCursor(x, y)  cursor offset from the orb centre in orb-window half-widths,
//                               x right, y up (0,0 = centre, ±1 = window edge). null clears it.
//   window.orb.setVisible(bool) pauses rendering entirely while the window is covered.
//
// Rendering runs at 60 fps while something is happening (non-idle state, cursor moving nearby,
// a transition settling) and at the idle frame rate otherwise (window.orb.setIdleFps).
(() => {
  'use strict';

  const bridge = window.webkit && window.webkit.messageHandlers;
  const inApp = !!(bridge && bridge.orbLog);
  const params = new URLSearchParams(location.search);
  const config = window.orbConfig || {};

  if (inApp) {
    for (const level of ['log', 'warn', 'error']) {
      const original = console[level].bind(console);
      console[level] = (...args) => {
        original(...args);
        try { bridge.orbLog.postMessage(level + ': ' + args.map(String).join(' ')); } catch (_) {}
      };
    }
    window.addEventListener('error', (e) => console.error(e.message, `${e.filename}:${e.lineno}`));
  } else {
    document.body.classList.add('preview');
  }

  const canvas = document.getElementById('orb');
  const gl = canvas.getContext('webgl2', {
    alpha: true,
    premultipliedAlpha: true,
    antialias: false,
    depth: false,
    stencil: false,
    powerPreference: 'low-power',
  });
  if (!gl) {
    console.error('WebGL2 unavailable');
    return;
  }
  canvas.addEventListener('webglcontextlost', (e) => e.preventDefault());
  canvas.addEventListener('webglcontextrestored', () => location.reload());

  const hdr = !!gl.getExtension('EXT_color_buffer_float') || !!gl.getExtension('EXT_color_buffer_half_float');

  // ---------------------------------------------------------------- shaders

  const COMMON = `#version 300 es
precision highp float;
const float TAU = 6.2831853;
mat3 rotX(float a){ float c=cos(a), s=sin(a); return mat3(1.,0.,0., 0.,c,s, 0.,-s,c); }
mat3 rotY(float a){ float c=cos(a), s=sin(a); return mat3(c,0.,-s, 0.,1.,0., s,0.,c); }
mat3 rotZ(float a){ float c=cos(a), s=sin(a); return mat3(c,s,0., -s,c,0., 0.,0.,1.); }
// Gentle perspective; +z points at the viewer.
vec2 project(vec3 p){ return p.xy * (4.0 / (4.0 - p.z)); }

uniform vec2 uCursor;   // smoothed cursor, scene units (window half-widths)
uniform float uProx;    // 0 = cursor far or absent, 1 = cursor right at the orb
uniform float uExpand;  // state + breathing scale of everything orbiting the sphere

vec2 cursorDir(){ float l = length(uCursor); return l > 1e-4 ? uCursor / l : vec2(0.0); }

// Things orbiting the sphere react to the cursor: the side facing it reaches toward it,
// and strands close to it are drawn in.
vec3 react(vec3 p, float bend){
  p *= uExpand;
  vec2 cdir = cursorDir();
  float r = length(p.xy);
  float facing = max(0.0, dot(p.xy / max(r, 1e-4), cdir));
  p.xy += cdir * facing * facing * uProx * 0.22 * r;
  vec2 toC = uCursor - p.xy;
  float near = exp(-dot(toC, toC) / 0.08);
  // Over the sphere itself the cursor brightens the orb instead of tugging strands across it.
  float offSphere = smoothstep(0.30, 0.48, length(uCursor));
  p.xy += toC * near * uProx * bend * offSphere;
  return p;
}
`;

  const FULLSCREEN_VS = `#version 300 es
out vec2 vUv;
void main(){
  vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
  vUv = p * 0.5 + 0.5;
  gl_Position = vec4(p, 0.0, 1.0);
}`;

  const SPHERE_FS = COMMON + `
in vec2 vUv;
out vec4 o;
uniform float uTime, uRadius, uPx, uEnergy, uGlow;
uniform vec2 uShift;
uniform vec3 uDeep, uNeb, uCore, uRim, uColB;

float hash12(vec2 p){ vec3 p3 = fract(vec3(p.xyx) * .1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
vec2 hash22(vec2 p){ vec3 p3 = fract(vec3(p.xyx) * vec3(.1031, .1030, .0973)); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.xx + p3.yz) * p3.zy); }
float vnoise(vec2 p){
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash12(i), hash12(i + vec2(1,0)), u.x), mix(hash12(i + vec2(0,1)), hash12(i + vec2(1,1)), u.x), u.y);
}
float fbm(vec2 p){
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 4; i++) { v += a * vnoise(p); p = p * 2.03 + 17.1; a *= 0.5; }
  return v;
}
// Sparse twinkling stars, at most one per grid cell.
float stars(vec2 p, float scale, float t){
  vec2 g = p * scale, id = floor(g), f = fract(g);
  vec2 sp = 0.2 + 0.6 * hash22(id);
  float h = hash12(id + 7.13);
  float tw = 0.55 + 0.45 * sin(t * (0.8 + 2.5 * h) + h * 40.0);
  float size = 0.05 + 0.09 * h * h;
  return smoothstep(size, 0.0, length(f - sp)) * step(0.45, h) * tw;
}

void main(){
  vec2 p = vUv * 2.0 - 1.0 - uShift;
  float d = length(p) / uRadius;
  float aa = uPx / uRadius * 1.5;
  vec2 cdir = cursorDir();
  vec3 col = vec3(0.0);
  float cov = 0.0;

  if (d < 1.0 + aa) {
    float z = sqrt(max(0.0, 1.0 - d * d));
    // Lens-like mapping: the interior reads as depth rather than a flat disc.
    vec2 q = (p / uRadius) / (0.55 + 0.45 * z);
    float ang = uTime * 0.04;
    q = mat2(cos(ang), -sin(ang), sin(ang), cos(ang)) * q;

    float neb = fbm(q * 2.0 + vec2(uTime * 0.03, -uTime * 0.02));
    float neb2 = fbm(q * 4.2 - neb * 1.6 + uTime * 0.035);

    col = uDeep;
    col += uNeb * (0.42 * neb + 0.30 * neb2) * (0.35 + 0.65 * z);
    col += uColB * 0.20 * smoothstep(0.52, 0.85, neb2);

    // Bright core; it drifts a little toward the cursor, like an eye following it.
    vec2 coreOff = cdir * min(length(uCursor), 1.5) / 1.5 * uProx * 0.18 * uRadius;
    float dc = length(p - coreOff) / uRadius;
    col += mix(uNeb, uCore, 0.25) * exp(-dc * dc * 7.0) * 0.75 * uEnergy;
    col += uCore * exp(-dc * dc * 40.0) * 1.2 * uEnergy;
    col += vec3(1.0) * exp(-dc * dc * 220.0) * 3.0 * uEnergy;

    // Star dust, densest toward the core.
    float s = stars(q, 16.0, uTime) + 0.8 * stars(q + 3.7, 30.0, uTime * 1.3) + 0.6 * stars(q - 1.3, 55.0, uTime * 1.7);
    col += mix(uCore, vec3(1.0), 0.4) * s * (0.35 + 1.8 * exp(-dc * dc * 4.0));

    // Fresnel rim and the thin bright edge, brighter on the side facing the cursor.
    float facing = max(0.0, dot(p / max(length(p), 1e-4), cdir));
    float rimBoost = 1.0 + 0.9 * uProx * facing * facing;
    col += mix(uNeb, uRim, 0.35) * pow(1.0 - z, 2.5) * 1.5 * rimBoost;
    col += uRim * exp(-pow((d - 0.972) / 0.02, 2.0)) * 1.3 * rimBoost * mix(1.0, uEnergy, 0.5);

    cov = smoothstep(1.0 + aa, 1.0 - aa, d);
    col *= cov;
  }

  float h = max(0.0, d - 1.0);
  vec3 halo = mix(uNeb, uRim, 0.4) * exp(-h * 5.0) * 0.32 + uColB * exp(-h * 16.0) * 0.45;
  col += halo * uGlow * (1.0 - cov);

  o = vec4(col, cov);
}`;

  const RIBBON_VS = COMMON + `
layout(location=0) in vec2 aVert;   // t in [0,1], side in {-1,1}
layout(location=1) in vec4 aRot;    // euler x, y, z, precession rate
layout(location=2) in vec4 aShape;  // radius, eccentricity, wobble amplitude, wobble frequency (integer)
layout(location=3) in vec4 aStyle;  // width px, brightness, violet mix, phase
uniform float uTime, uRadius, uBright;
uniform vec2 uRes, uShift;
uniform vec3 uColA, uColB;
out float vSide, vI;
out vec3 vCol;

vec3 curve(float t){
  float th = t * TAU, ph = aStyle.w, T = uTime;
  float r = aShape.x * (1.0 + 0.06 * sin(3.0 * th + ph + T * 0.37) + 0.04 * sin(5.0 * th - ph * 1.7 + T * 0.29));
  vec3 p = vec3(cos(th) * r * (1.0 + aShape.y), sin(th) * r * (1.0 - aShape.y), 0.0);
  p.z = aShape.z * aShape.x * sin(aShape.w * th + ph * 2.0 + T * 0.45);
  float pr = T * aRot.w;
  p = rotZ(aRot.z + pr * 0.6) * rotX(aRot.x + pr * 0.35) * rotY(aRot.y + pr * 0.5) * p;
  return react(p, 0.6);
}

void main(){
  float t = aVert.x, side = aVert.y, dt = 1.0 / 512.0;
  vec3 p0 = curve(t);
  vec2 s0 = project(p0);
  vec2 dir = project(curve(t + dt)) - project(curve(t - dt));
  dir = length(dir) > 1e-6 ? normalize(dir) : vec2(1.0, 0.0);
  vec2 nrm = vec2(-dir.y, dir.x);
  gl_Position = vec4(s0 + uShift + nrm * side * aStyle.x / uRes, 0.0, 1.0);
  vSide = side;

  // Pulses of light travelling along each ribbon.
  float th = t * TAU;
  float flow = pow(0.5 + 0.5 * sin(2.0 * th - uTime * (0.55 + 0.6 * fract(aStyle.w)) + aStyle.w * 3.0), 4.0);
  float depth = clamp(p0.z / aShape.x * 0.5 + 0.5, 0.0, 1.0);
  float rr = length(s0);
  float behind = step(p0.z, 0.0) * (1.0 - smoothstep(uRadius * 0.97, uRadius * 1.04, rr));
  float edge = smoothstep(1.0, 0.70, rr);
  vec2 toC = uCursor - s0;
  float excite = 1.0 + 1.6 * uProx * exp(-dot(toC, toC) / 0.03);
  vI = aStyle.y * uBright * excite * (0.22 + 0.78 * flow) * (0.5 + 0.5 * depth) * (1.0 - 0.82 * behind) * edge;

  vCol = mix(uColA, uColB, aStyle.z);
  vCol = mix(vCol, vec3(0.75, 0.82, 1.0), flow * 0.35);
}`;

  const RIBBON_FS = `#version 300 es
precision highp float;
in float vSide, vI;
in vec3 vCol;
out vec4 o;
void main(){
  float a = exp(-vSide * vSide * 9.0) * vI;
  o = vec4(vCol * a, 0.0);
}`;

  const DUST_VS = COMMON + `
layout(location=0) in vec4 aP;  // orbit radius, start angle, angular speed, size px
layout(location=1) in vec4 aQ;  // inclination, node, brightness, twinkle seed
uniform float uTime, uRadius, uDpr;
uniform vec2 uShift;
out float vI;
void main(){
  float a = aP.y + uTime * aP.z;
  vec3 p = rotY(aQ.y) * rotX(aQ.x) * (vec3(cos(a), sin(a), 0.0) * aP.x);
  p = react(p, 0.35);
  vec2 s = project(p);
  gl_Position = vec4(s + uShift, 0.0, 1.0);
  gl_PointSize = aP.w * uDpr;
  float rr = length(s);
  float behind = step(p.z, 0.0) * (1.0 - smoothstep(uRadius * 0.97, uRadius * 1.04, rr));
  float tw = 0.5 + 0.5 * sin(uTime * (1.2 + aQ.w * 0.4) + aQ.w * 10.0);
  vI = aQ.z * (0.3 + 0.7 * tw) * (1.0 - 0.9 * behind) * smoothstep(1.0, 0.75, rr);
}`;

  const DUST_FS = `#version 300 es
precision highp float;
in float vI;
uniform vec3 uColA;
out vec4 o;
void main(){
  vec2 c = gl_PointCoord * 2.0 - 1.0;
  float a = exp(-dot(c, c) * 4.0) * vI;
  o = vec4(mix(uColA, vec3(1.0), 0.55) * a, 0.0);
}`;

  const PREFILTER_FS = `#version 300 es
precision highp float;
in vec2 vUv;
out vec4 o;
uniform sampler2D uSrc;
uniform vec2 uHalf;
uniform float uThreshold;
void main(){
  vec3 c = texture(uSrc, vUv).rgb * 4.0;
  c += texture(uSrc, vUv - uHalf).rgb + texture(uSrc, vUv + uHalf).rgb;
  c += texture(uSrc, vUv + vec2(uHalf.x, -uHalf.y)).rgb + texture(uSrc, vUv - vec2(uHalf.x, -uHalf.y)).rgb;
  c /= 8.0;
  float br = max(c.r, max(c.g, c.b));
  float soft = clamp(br - uThreshold + 0.25, 0.0, 0.5);
  soft = soft * soft / 0.5;
  o = vec4(c * max(soft, br - uThreshold) / max(br, 1e-4), 1.0);
}`;

  const DOWN_FS = `#version 300 es
precision highp float;
in vec2 vUv;
out vec4 o;
uniform sampler2D uSrc;
uniform vec2 uHalf;
void main(){
  vec3 c = texture(uSrc, vUv).rgb * 4.0;
  c += texture(uSrc, vUv - uHalf).rgb + texture(uSrc, vUv + uHalf).rgb;
  c += texture(uSrc, vUv + vec2(uHalf.x, -uHalf.y)).rgb + texture(uSrc, vUv - vec2(uHalf.x, -uHalf.y)).rgb;
  o = vec4(c / 8.0, 1.0);
}`;

  const UP_FS = `#version 300 es
precision highp float;
in vec2 vUv;
out vec4 o;
uniform sampler2D uSrc;
uniform vec2 uHalf;
void main(){
  vec2 h = uHalf;
  vec3 c = texture(uSrc, vUv + vec2(-h.x * 2.0, 0.0)).rgb + texture(uSrc, vUv + vec2(h.x * 2.0, 0.0)).rgb;
  c += texture(uSrc, vUv + vec2(0.0, h.y * 2.0)).rgb + texture(uSrc, vUv + vec2(0.0, -h.y * 2.0)).rgb;
  c += (texture(uSrc, vUv + vec2(-h.x, h.y)).rgb + texture(uSrc, vUv + vec2(h.x, h.y)).rgb) * 2.0;
  c += (texture(uSrc, vUv + vec2(h.x, -h.y)).rgb + texture(uSrc, vUv + vec2(-h.x, -h.y)).rgb) * 2.0;
  o = vec4(c / 12.0, 1.0);
}`;

  const COMPOSITE_FS = `#version 300 es
precision highp float;
in vec2 vUv;
out vec4 o;
uniform sampler2D uScene, uBloom;
uniform float uBloomStrength, uExposure;
void main(){
  vec4 s = texture(uScene, vUv);
  vec3 c = s.rgb + texture(uBloom, vUv).rgb * uBloomStrength;
  c = 1.0 - exp(-c * uExposure);
  // Premultiplied output: the glow is emitted light, alpha follows its brightness.
  float a = max(s.a, max(c.r, max(c.g, c.b)));
  o = vec4(c, a);
}`;

  function compile(type, src) {
    const sh = gl.createShader(type);
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
      throw new Error('shader compile failed: ' + gl.getShaderInfoLog(sh));
    }
    return sh;
  }

  function program(vs, fs) {
    const p = gl.createProgram();
    gl.attachShader(p, compile(gl.VERTEX_SHADER, vs));
    gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
      throw new Error('program link failed: ' + gl.getProgramInfoLog(p));
    }
    const uniforms = {};
    const n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
    for (let i = 0; i < n; i++) {
      const name = gl.getActiveUniform(p, i).name;
      uniforms[name] = gl.getUniformLocation(p, name);
    }
    return { p, u: uniforms };
  }

  // Sets whichever of the given uniforms the program actually uses (unused ones are optimised out).
  function setUniforms(prog, values) {
    for (const [name, v] of Object.entries(values)) {
      const loc = prog.u[name];
      if (!loc) continue;
      if (typeof v === 'number') gl.uniform1f(loc, v);
      else if (v.length === 2) gl.uniform2fv(loc, v);
      else gl.uniform3fv(loc, v);
    }
  }

  const progs = {
    sphere: program(FULLSCREEN_VS, SPHERE_FS),
    ribbon: program(RIBBON_VS, RIBBON_FS),
    dust: program(DUST_VS, DUST_FS),
    prefilter: program(FULLSCREEN_VS, PREFILTER_FS),
    down: program(FULLSCREEN_VS, DOWN_FS),
    up: program(FULLSCREEN_VS, UP_FS),
    composite: program(FULLSCREEN_VS, COMPOSITE_FS),
  };

  // --------------------------------------------------------------- geometry

  // Deterministic PRNG so the orb looks the same every launch.
  function mulberry32(seed) {
    return () => {
      seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
      let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  const rand = mulberry32(0x0a7b15);
  const between = (a, b) => a + (b - a) * rand();

  const SPHERE_RADIUS = 0.34;
  const SEGMENTS = 320;

  // A ribbon is a bundle of near-parallel strands sharing an orbit plane.
  const BUNDLES = [
    // count, radius range, eccentricity, wobble, strands, width px, brightness
    { count: 5, r: [0.43, 0.52], ecc: [0.00, 0.12], wob: [0.03, 0.10], strands: [3, 5], width: [5.5, 7.0], bright: [1.2, 1.7] },
    { count: 7, r: [0.42, 0.62], ecc: [0.02, 0.25], wob: [0.04, 0.14], strands: [2, 3], width: [3.5, 4.5], bright: [0.6, 0.95] },
    { count: 5, r: [0.58, 0.80], ecc: [0.22, 0.45], wob: [0.05, 0.16], strands: [1, 2], width: [2.8, 3.4], bright: [0.35, 0.55] },
  ];

  const ribbonInstances = [];
  for (const b of BUNDLES) {
    for (let i = 0; i < b.count; i++) {
      const rx = between(0, Math.PI), ry = between(0, Math.PI), rz = between(0, Math.PI * 2);
      const prec = between(0.04, 0.16) * (rand() < 0.5 ? -1 : 1);
      const radius = between(...b.r), ecc = between(...b.ecc), wob = between(...b.wob);
      const freq = [1, 2, 2][Math.floor(rand() * 3)];
      const phase = between(0, 100);
      const violet = rand() < 0.35 ? between(0.5, 1.0) : between(0.0, 0.35);
      const strands = Math.round(between(b.strands[0], b.strands[1]));
      const width = between(...b.width), bright = between(...b.bright);
      for (let s = 0; s < strands; s++) {
        ribbonInstances.push(
          rx + s * 0.012, ry, rz, prec,
          radius + s * 0.009, ecc, wob * (1 + s * 0.08), freq,
          width * (s === 0 ? 1 : 0.8), bright * (s === 0 ? 1 : 0.55), violet, phase + s * 0.35,
        );
      }
    }
  }
  const ribbonCount = ribbonInstances.length / 12;

  const stripVerts = new Float32Array((SEGMENTS + 1) * 4);
  for (let i = 0; i <= SEGMENTS; i++) {
    const t = i / SEGMENTS;
    stripVerts.set([t, -1, t, 1], i * 4);
  }

  const ribbonVao = gl.createVertexArray();
  gl.bindVertexArray(ribbonVao);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, stripVerts, gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(ribbonInstances), gl.STATIC_DRAW);
  for (let i = 0; i < 3; i++) {
    gl.enableVertexAttribArray(1 + i);
    gl.vertexAttribPointer(1 + i, 4, gl.FLOAT, false, 48, i * 16);
    gl.vertexAttribDivisor(1 + i, 1);
  }

  const DUST_COUNT = 220;
  const dust = new Float32Array(DUST_COUNT * 8);
  for (let i = 0; i < DUST_COUNT; i++) {
    const near = rand() < 0.6;
    dust.set([
      near ? between(0.37, 0.55) : between(0.55, 0.92),
      between(0, Math.PI * 2),
      between(0.04, 0.22) * (rand() < 0.5 ? -1 : 1),
      between(1.0, 2.6),
      between(0, Math.PI), between(0, Math.PI * 2),
      near ? between(0.4, 1.0) : between(0.15, 0.5),
      between(0, 10),
    ], i * 8);
  }
  const dustVao = gl.createVertexArray();
  gl.bindVertexArray(dustVao);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, dust, gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 4, gl.FLOAT, false, 32, 0);
  gl.enableVertexAttribArray(1);
  gl.vertexAttribPointer(1, 4, gl.FLOAT, false, 32, 16);

  const emptyVao = gl.createVertexArray();
  gl.bindVertexArray(null);

  // ---------------------------------------------------------- render targets

  function target(w, h) {
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    if (hdr) gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.HALF_FLOAT, null);
    else gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const fb = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    return { tex, fb, w, h };
  }

  function freeTarget(t) {
    gl.deleteTexture(t.tex);
    gl.deleteFramebuffer(t.fb);
  }

  const BLOOM_LEVELS = 5;
  let scene = null;
  let bloom = [];
  let dpr = 1;

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    const size = Math.max(1, Math.round(canvas.clientWidth * dpr));
    if (scene && scene.w === size) return;
    canvas.width = canvas.height = size;
    if (scene) freeTarget(scene);
    bloom.forEach(freeTarget);
    scene = target(size, size);
    bloom = [];
    let s = size;
    for (let i = 0; i < BLOOM_LEVELS; i++) {
      s = Math.max(1, s >> 1);
      bloom.push(target(s, s));
    }
  }

  // ------------------------------------------------------------------ state

  const IDLE_PALETTE = {
    colA: [0.14, 0.28, 1.00], colB: [0.46, 0.22, 1.00],
    deep: [0.010, 0.018, 0.16], neb: [0.05, 0.10, 0.75],
    core: [0.55, 0.70, 1.00], rim: [0.45, 0.58, 1.00],
  };

  // speed: orbital motion. energy: core and ribbon brightness. glow: halo. expand: orbit scale.
  // pulse/pulseHz: breathing of expand, energy and glow.
  const STATES = {
    idle: {
      speed: 1.0, energy: 1.0, glow: 1.0, bloom: 1.0, expand: 1.0, pulse: 0.012, pulseHz: 0.18,
      ...IDLE_PALETTE,
    },
    hover: {
      speed: 1.35, energy: 1.25, glow: 1.4, bloom: 1.25, expand: 1.04, pulse: 0.015, pulseHz: 0.3,
      ...IDLE_PALETTE,
    },
    listening: {
      speed: 1.4, energy: 1.3, glow: 1.45, bloom: 1.3, expand: 1.05, pulse: 0.035, pulseHz: 0.9,
      colA: [0.08, 0.55, 1.00], colB: [0.22, 0.38, 1.00],
      deep: [0.005, 0.03, 0.16], neb: [0.03, 0.30, 0.80],
      core: [0.55, 0.85, 1.00], rim: [0.40, 0.85, 1.00],
    },
    thinking: {
      speed: 2.8, energy: 1.2, glow: 1.2, bloom: 1.2, expand: 0.93, pulse: 0.02, pulseHz: 1.6,
      colA: [0.38, 0.22, 1.00], colB: [0.78, 0.22, 0.95],
      deep: [0.03, 0.01, 0.16], neb: [0.25, 0.08, 0.75],
      core: [0.80, 0.65, 1.00], rim: [0.70, 0.50, 1.00],
    },
    awaitingApproval: {
      speed: 0.6, energy: 1.1, glow: 1.3, bloom: 1.25, expand: 1.0, pulse: 0.06, pulseHz: 0.55,
      colA: [1.00, 0.55, 0.12], colB: [1.00, 0.32, 0.18],
      deep: [0.04, 0.02, 0.10], neb: [0.35, 0.15, 0.45],
      core: [1.00, 0.80, 0.55], rim: [1.00, 0.70, 0.35],
    },
    speaking: {
      speed: 1.7, energy: 1.3, glow: 1.3, bloom: 1.25, expand: 1.03, pulse: 0.025, pulseHz: 2.4,
      colA: [0.18, 0.45, 1.00], colB: [0.40, 0.30, 1.00],
      deep: [0.010, 0.018, 0.16], neb: [0.06, 0.16, 0.85],
      core: [0.70, 0.82, 1.00], rim: [0.55, 0.72, 1.00],
    },
    error: {
      speed: 0.6, energy: 0.85, glow: 1.1, bloom: 1.0, expand: 0.97, pulse: 0.03, pulseHz: 0.4,
      colA: [1.00, 0.16, 0.18], colB: [0.85, 0.10, 0.40],
      deep: [0.10, 0.005, 0.03], neb: [0.60, 0.05, 0.15],
      core: [1.00, 0.55, 0.55], rim: [1.00, 0.35, 0.35],
    },
  };
  // Overdue mood: the resting orb warms toward amber-red while something is overdue.
  const OVERDUE_PALETTE = {
    colA: [1.00, 0.42, 0.22], colB: [0.95, 0.25, 0.45],
    deep: [0.08, 0.02, 0.10], neb: [0.55, 0.12, 0.35],
    core: [1.00, 0.72, 0.55], rim: [1.00, 0.52, 0.38],
  };
  const MOOD_MIX = 0.5;
  let mood = 'normal';
  const SCALARS = ['speed', 'energy', 'glow', 'bloom', 'expand', 'pulse', 'pulseHz'];
  const COLORS = ['colA', 'colB', 'deep', 'neb', 'core', 'rim'];

  let stateName = 'idle';
  const look = JSON.parse(JSON.stringify(STATES.idle));

  // Cursor target from Swift and its smoothed follower.
  let cursorTarget = null;
  const cursor = [0, 0];
  let prox = 0;
  let lastCursorMove = -Infinity;
  let shakeStart = -Infinity;

  let visible = true;
  let rafId = 0;

  // Every frame is drawn on a vsync, so motion is evenly paced; when idle, frame() skips vsyncs
  // to hold idleFps. (Idle frames once came from a timer to save the display link's cost, but
  // timer frames land unevenly against the display and the motion judders.)
  function schedule() {
    if (!visible || rafId) return;
    rafId = requestAnimationFrame(frame);
  }

  function wake() { schedule(); }

  window.orb = {
    setState(name) {
      if (!STATES[name]) { console.warn('unknown orb state', name); return; }
      if (name === 'error' && stateName !== 'error') shakeStart = performance.now();
      stateName = name;
      wake();
    },
    setCursor(x, y) {
      cursorTarget = (x == null || y == null) ? null : [x, y];
      lastCursorMove = performance.now();
      wake();
    },
    setVisible(v) {
      visible = !!v;
      if (visible) {
        last = lastSettle = performance.now();
        wake();
      } else {
        cancelAnimationFrame(rafId);
        rafId = 0;
      }
    },
    /// 'overdue' warms the resting orb; 'normal' clears it.
    setMood(name) {
      mood = name === 'overdue' ? 'overdue' : 'normal';
      wake();
    },
    /// Idle frame rate: 60 on mains power, 30 on battery (set by the app).
    setIdleFps(fps) {
      idleFps = Math.max(10, Math.min(60, Number(fps) || 30));
    },
    get state() { return stateName; },
  };

  // ------------------------------------------------------------------- frame

  let idleFps = config.idleFps || 30;
  // How long cursor motion keeps the loop at full rate.
  const CURSOR_ACTIVE_MS = 1200;

  const fpsEl = document.getElementById('fps');
  const showFps = params.has('fps') || !!config.fps;
  if (showFps) fpsEl.style.display = 'block';
  let fpsFrames = 0, fpsSince = performance.now();

  let time = between(0, 100);
  let pulsePhase = 0;
  let last = performance.now();
  let lastSettle = last;

  function fullscreen() {
    gl.bindVertexArray(emptyVao);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  // Moves `look`, the cursor and proximity toward their targets; returns true while still settling.
  function settle(dt) {
    const goal = STATES[stateName];
    const k = 1 - Math.exp(-dt * 4);
    let moving = false;
    for (const key of SCALARS) {
      const delta = goal[key] - look[key];
      look[key] += delta * k;
      if (Math.abs(delta) > 0.002) moving = true;
    }
    const moody = mood === 'overdue' && (stateName === 'idle' || stateName === 'hover');
    for (const key of COLORS) {
      for (let i = 0; i < 3; i++) {
        const target = moody ? goal[key][i] + (OVERDUE_PALETTE[key][i] - goal[key][i]) * MOOD_MIX : goal[key][i];
        const delta = target - look[key][i];
        look[key][i] += delta * k;
        if (Math.abs(delta) > 0.002) moving = true;
      }
    }

    const kc = 1 - Math.exp(-dt * 7);
    let proxGoal = 0;
    if (cursorTarget) {
      for (let i = 0; i < 2; i++) {
        const delta = cursorTarget[i] - cursor[i];
        cursor[i] += delta * kc;
        if (Math.abs(delta) > 0.002) moving = true;
      }
      // Starts noticing from about four window-widths away, fully engaged at the window edge.
      const dist = Math.hypot(cursorTarget[0], cursorTarget[1]);
      proxGoal = 1 - Math.min(1, Math.max(0, (dist - 1.0) / 7.0));
      proxGoal *= proxGoal;
    }
    const deltaP = proxGoal - prox;
    prox += deltaP * (1 - Math.exp(-dt * 3));
    if (Math.abs(deltaP) > 0.002) moving = true;
    return moving;
  }

  function frame(now) {
    rafId = 0;
    if (!visible) return;

    const settling = settle(Math.min(0.05, (now - lastSettle) / 1000));
    lastSettle = now;
    const active = stateName !== 'idle' || settling || now - lastCursorMove < CURSOR_ACTIVE_MS;
    // Skip vsyncs when idle; the 4 ms slack keeps a 30 fps cadence from drifting to 20.
    if (!active && now - last < 1000 / idleFps - 4) {
      schedule();
      return;
    }
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    resize();

    time += dt * look.speed;
    pulsePhase += dt * look.pulseHz * Math.PI * 2;
    const breath = Math.sin(pulsePhase) * look.pulse;
    const expand = look.expand * (1 + breath);
    const energy = look.energy * (1 + breath * 2.5);
    const glow = look.glow * (1 + breath * 3);

    // A short decaying shake when entering the error state.
    const shakeT = (now - shakeStart) / 1000;
    const shakeAmp = shakeT < 0.6 ? 0.025 * (1 - shakeT / 0.6) : 0;
    const shift = shakeAmp > 0 ? [Math.sin(shakeT * 70) * shakeAmp, 0] : [0, 0];

    const shared = { uTime: time, uRadius: SPHERE_RADIUS, uCursor: cursor, uProx: prox, uExpand: expand, uShift: shift };
    const size = scene.w;
    gl.disable(gl.DEPTH_TEST);

    // 1. sphere (replaces scene contents, writes coverage to alpha)
    gl.bindFramebuffer(gl.FRAMEBUFFER, scene.fb);
    gl.viewport(0, 0, size, size);
    gl.disable(gl.BLEND);
    gl.useProgram(progs.sphere.p);
    setUniforms(progs.sphere, {
      ...shared, uPx: 2 / size, uEnergy: energy, uGlow: glow,
      uDeep: look.deep, uNeb: look.neb, uCore: look.core, uRim: look.rim, uColB: look.colB,
    });
    fullscreen();

    // 2 & 3. dust and ribbons, additive in colour, alpha untouched
    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(gl.ONE, gl.ONE, gl.ZERO, gl.ONE);

    gl.useProgram(progs.dust.p);
    setUniforms(progs.dust, { ...shared, uDpr: dpr, uColA: look.colA });
    gl.bindVertexArray(dustVao);
    gl.drawArrays(gl.POINTS, 0, DUST_COUNT);

    gl.useProgram(progs.ribbon.p);
    setUniforms(progs.ribbon, {
      ...shared, uRes: [size, size], uBright: Math.sqrt(energy), uColA: look.colA, uColB: look.colB,
    });
    gl.bindVertexArray(ribbonVao);
    gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, (SEGMENTS + 1) * 2, ribbonCount);

    // 4. bloom: threshold + downsample chain, then additive upsample back to level 0
    gl.disable(gl.BLEND);
    gl.activeTexture(gl.TEXTURE0);
    let src = scene;
    for (let i = 0; i < bloom.length; i++) {
      const dst = bloom[i];
      const prog = i === 0 ? progs.prefilter : progs.down;
      gl.bindFramebuffer(gl.FRAMEBUFFER, dst.fb);
      gl.viewport(0, 0, dst.w, dst.h);
      gl.useProgram(prog.p);
      gl.bindTexture(gl.TEXTURE_2D, src.tex);
      gl.uniform1i(prog.u.uSrc, 0);
      gl.uniform2f(prog.u.uHalf, 0.5 / src.w, 0.5 / src.h);
      if (i === 0) gl.uniform1f(prog.u.uThreshold, 0.35);
      fullscreen();
      src = dst;
    }
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE);
    gl.useProgram(progs.up.p);
    gl.uniform1i(progs.up.u.uSrc, 0);
    for (let i = bloom.length - 1; i > 0; i--) {
      const from = bloom[i], to = bloom[i - 1];
      gl.bindFramebuffer(gl.FRAMEBUFFER, to.fb);
      gl.viewport(0, 0, to.w, to.h);
      gl.bindTexture(gl.TEXTURE_2D, from.tex);
      gl.uniform2f(progs.up.u.uHalf, 0.5 / from.w, 0.5 / from.h);
      fullscreen();
    }

    // 5. composite to the canvas
    gl.disable(gl.BLEND);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, size, size);
    gl.useProgram(progs.composite.p);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, scene.tex);
    gl.uniform1i(progs.composite.u.uScene, 0);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, bloom[0].tex);
    gl.uniform1i(progs.composite.u.uBloom, 1);
    gl.uniform1f(progs.composite.u.uBloomStrength, 0.55 * look.bloom);
    gl.uniform1f(progs.composite.u.uExposure, 1.0);
    fullscreen();

    if (showFps) {
      fpsFrames++;
      if (now - fpsSince > 500) {
        fpsEl.textContent = `${Math.round(fpsFrames * 1000 / (now - fpsSince))} fps  ${stateName}  prox ${prox.toFixed(2)}`;
        fpsFrames = 0;
        fpsSince = now;
      }
    }
    schedule();
  }

  // Browser preview: the mouse stands in for Swift's cursor feed, keys 1-7 switch states.
  if (!inApp) {
    const names = Object.keys(STATES);
    window.addEventListener('mousemove', (e) => {
      const r = canvas.getBoundingClientRect();
      const half = r.width / 2;
      window.orb.setCursor((e.clientX - r.left - half) / half, -(e.clientY - r.top - half) / half);
    });
    document.addEventListener('mouseleave', () => window.orb.setCursor(null, null));
    window.addEventListener('keydown', (e) => {
      const i = Number(e.key) - 1;
      if (names[i]) window.orb.setState(names[i]);
    });
  }

  resize();
  console.log(`orb ready: ${canvas.width}px, ${ribbonCount} strands, ${hdr ? 'half-float' : '8-bit'} targets`);
  wake();
})();
