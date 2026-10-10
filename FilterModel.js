.pragma library

// Screen FX filter model: default state, presets, and the GLSL composer.
//
// The composed shader targets Hyprland's one screen-shader slot
// (decoration:screen_shader). The `time` uniform is emitted only when an
// animated effect is active, because Hyprland requires
// debug:damage_tracking=0 for any screen shader that uses it — static-only
// stacks stay cheap.

var EFFECT_KEYS = ["grain", "aberration", "keyspill", "scanlines", "vignette", "flicker"]

var PRESETS = [
  { value: "none", label: "None" },
  { value: "cyberpunk", label: "Neon" },
  { value: "vhs", label: "VHS" },
  { value: "blade", label: "Blade" },
  { value: "matrix", label: "Matrix" },
  { value: "terminal", label: "Term" }
]

var GRADES = [
  { value: "none", label: "None" },
  { value: "neon", label: "Neon" },
  { value: "amber", label: "Amber" },
  { value: "blade", label: "Blade" },
  { value: "matrix", label: "Matrix" },
  { value: "terminal", label: "Term" }
]

function defaultState() {
  return {
    grain: { on: false, intensity: 0.35, size: 2, mode: "animated" },
    aberration: { on: false, strength: 0.25 },
    keyspill: { on: false, bleed: 0.35 },
    scanlines: { on: false, opacity: 0.35, density: 3 },
    vignette: { on: false, strength: 0.35 },
    flicker: { on: false, amount: 0.3 },
    grade: "none"
  }
}

function clampNum(v, lo, hi, fallback) {
  var n = Number(v)
  if (!isFinite(n)) return fallback
  return Math.max(lo, Math.min(hi, n))
}

function normalize(raw) {
  var s = defaultState()
  if (!raw || typeof raw !== "object") return s
  for (var i = 0; i < EFFECT_KEYS.length; i++) {
    var k = EFFECT_KEYS[i]
    if (!raw[k] || typeof raw[k] !== "object") continue
    for (var p in s[k]) {
      if (raw[k][p] !== undefined) s[k][p] = raw[k][p]
    }
  }
  s.grain.intensity = clampNum(s.grain.intensity, 0, 1, 0.35)
  s.grain.size = Math.round(clampNum(s.grain.size, 1, 8, 2))
  s.grain.mode = s.grain.mode === "static" ? "static" : "animated"
  s.aberration.strength = clampNum(s.aberration.strength, 0, 1, 0.25)
  s.keyspill.bleed = clampNum(s.keyspill.bleed, 0, 1, 0.35)
  s.scanlines.opacity = clampNum(s.scanlines.opacity, 0, 1, 0.35)
  s.scanlines.density = Math.round(clampNum(s.scanlines.density, 2, 8, 3))
  s.vignette.strength = clampNum(s.vignette.strength, 0, 1, 0.35)
  s.flicker.amount = clampNum(s.flicker.amount, 0, 1, 0.3)
  if (raw.grade !== undefined) s.grade = raw.grade
  s.grade = gradeExists(s.grade) ? s.grade : "none"
  return s
}

function gradeExists(id) {
  for (var i = 0; i < GRADES.length; i++) if (GRADES[i].value === id) return true
  return false
}

function isActive(s) {
  if (!s) return false
  for (var i = 0; i < EFFECT_KEYS.length; i++) if (s[EFFECT_KEYS[i]].on) return true
  return s.grade !== "none"
}

function isAnimated(s) {
  if (!s) return false
  return (s.grain.on && s.grain.mode === "animated") || s.flicker.on
}

function presetState(id) {
  var s = defaultState()
  if (id === "cyberpunk") {
    s.grain = { on: true, intensity: 0.3, size: 2, mode: "animated" }
    s.aberration = { on: true, strength: 0.35 }
    s.keyspill = { on: true, bleed: 0.35 }
    s.vignette = { on: true, strength: 0.3 }
    s.grade = "neon"
  } else if (id === "vhs") {
    s.grain = { on: true, intensity: 0.5, size: 2, mode: "animated" }
    s.keyspill = { on: true, bleed: 0.7 }
    s.scanlines = { on: true, opacity: 0.25, density: 3 }
    s.flicker = { on: true, amount: 0.35 }
    s.grade = "amber"
  } else if (id === "blade") {
    s.grain = { on: true, intensity: 0.22, size: 2, mode: "animated" }
    s.aberration = { on: true, strength: 0.12 }
    s.vignette = { on: true, strength: 0.5 }
    s.grade = "blade"
  } else if (id === "matrix") {
    s.grain = { on: true, intensity: 0.12, size: 1, mode: "static" }
    s.scanlines = { on: true, opacity: 0.2, density: 2 }
    s.vignette = { on: true, strength: 0.35 }
    s.grade = "matrix"
  } else if (id === "terminal") {
    s.grain = { on: true, intensity: 0.15, size: 2, mode: "static" }
    s.scanlines = { on: true, opacity: 0.22, density: 2 }
    s.vignette = { on: true, strength: 0.25 }
    s.grade = "terminal"
  }
  return s
}

function matchesPreset(s, id) {
  return JSON.stringify(normalize(s)) === JSON.stringify(normalize(presetState(id)))
}

function matchingPreset(s) {
  for (var i = 0; i < PRESETS.length; i++) {
    if (matchesPreset(s, PRESETS[i].value)) return PRESETS[i].value
  }
  return ""
}

function fmt(x) {
  var n = Math.round(Number(x) * 10000) / 10000
  var out = String(n)
  if (out.indexOf(".") < 0 && out.indexOf("e") < 0) out += ".0"
  return out
}

function gradeGlsl(grade) {
  switch (grade) {
    case "neon":
      return "  c = pow(c, vec3(1.06, 1.0, 0.92)) * vec3(1.06, 0.94, 1.14);"
    case "amber":
      return "  float gl = dot(c, vec3(0.299, 0.587, 0.114));\n  c = mix(c, vec3(gl) * vec3(1.12, 0.86, 0.5), 0.8);"
    case "blade":
      return "  float gl = dot(c, vec3(0.299, 0.587, 0.114));\n  c = mix(vec3(gl), c, 0.72);\n  c = pow(c * vec3(0.92, 1.04, 1.1), vec3(1.12));\n  c += vec3(0.0, 0.015, 0.035);"
    case "matrix":
      return "  float gl = dot(c, vec3(0.299, 0.587, 0.114));\n  c = mix(c, vec3(gl) * vec3(0.3, 1.0, 0.42), 0.85);"
    case "terminal":
      return "  float gl = dot(c, vec3(0.299, 0.587, 0.114));\n  c = mix(c, vec3(gl) * vec3(0.45, 1.05, 0.55), 0.7);\n  c = c * 0.9 + vec3(0.0, 0.02, 0.0);"
  }
  return ""
}

// Returns { source, active, animated }. Empty source means clear the slot.
function compose(rawState) {
  var s = normalize(rawState)
  var animated = isAnimated(s)
  var active = isActive(s)
  if (!active) return { source: "", active: false, animated: false }

  var b = []
  b.push("#version 300 es")
  b.push("// generated by fichte.screenfx — do not edit")
  b.push("precision highp float;")
  b.push("in vec2 v_texcoord;")
  b.push("layout(location = 0) out vec4 fragColor;")
  b.push("uniform sampler2D tex;")
  if (animated) b.push("uniform float time;")
  b.push("")
  b.push("float sf_noise(vec2 p) {")
  b.push("  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);")
  b.push("}")
  b.push("")
  b.push("void main() {")
  b.push("  vec2 uv = v_texcoord;")
  b.push("  vec3 c;")

  // Base sample, with optional radial chromatic aberration.
  if (s.aberration.on) {
    b.push("  vec2 dir = uv - 0.5;")
    b.push("  float ab = " + fmt(s.aberration.strength * 0.012) + ";")
    b.push("  c.r = texture(tex, uv + dir * ab).r;")
    b.push("  c.g = texture(tex, uv).g;")
    b.push("  c.b = texture(tex, uv - dir * ab).b;")
  } else {
    b.push("  c = texture(tex, uv).rgb;")
  }

  // RGB keyspill: horizontal per-channel smear so channels leak past edges.
  if (s.keyspill.on) {
    var kb = fmt(s.keyspill.bleed)
    b.push("  float kb = " + kb + ";")
    b.push("  float kw = kb * 0.005;")
    b.push("  vec3 sp;")
    b.push("  sp.r = 0.55 * texture(tex, uv + vec2(kw, 0.0)).r")
    b.push("       + 0.25 * texture(tex, uv + vec2(kw * 2.2, 0.0)).r + 0.20 * c.r;")
    b.push("  sp.g = 0.35 * texture(tex, uv + vec2(kw * 0.45, 0.0)).g")
    b.push("       + 0.25 * texture(tex, uv - vec2(kw * 0.45, 0.0)).g + 0.40 * c.g;")
    b.push("  sp.b = 0.55 * texture(tex, uv - vec2(kw, 0.0)).b")
    b.push("       + 0.25 * texture(tex, uv - vec2(kw * 2.2, 0.0)).b + 0.20 * c.b;")
    b.push("  c = mix(c, sp, clamp(kb * 1.3, 0.0, 1.0));")
  }

  // Color grade (before scanlines/grain so the grain stays luminance-only).
  if (s.grade !== "none") {
    b.push("  c = clamp(c, 0.0, 1.0);")
    b.push(gradeGlsl(s.grade))
  }

  // Scanlines: darkened rows in the framebuffer's pixel domain.
  if (s.scanlines.on) {
    b.push("  float slStep = " + fmt(s.scanlines.density) + ";")
    b.push("  float slOn = step(slStep * 0.5, mod(gl_FragCoord.y, slStep));")
    b.push("  c *= 1.0 - " + fmt(s.scanlines.opacity) + " * 0.45 * slOn;")
  }

  // Film grain: per-cell hash, reseeded per frame when animated.
  if (s.grain.on) {
    b.push("  vec2 gcell = floor(gl_FragCoord.xy / " + fmt(s.grain.size) + ");")
    var gseed = animated && s.grain.mode === "animated" ? "floor(time * 24.0)" : "0.0"
    b.push("  float gn = sf_noise(gcell + vec2(" + gseed + " * 0.6180339887, " + gseed + "));")
    b.push("  c += (gn - 0.5) * " + fmt(s.grain.intensity * 0.55) + ";")
  }

  // CRT flicker: slow brightness wobble.
  if (s.flicker.on) {
    b.push("  c *= 1.0 - " + fmt(s.flicker.amount) + " * 0.22 * (0.5 + 0.5 * sin(time * 7.0 + 1.3));")
  }

  // Vignette: corner falloff.
  if (s.vignette.on) {
    b.push("  float vd = length(uv - 0.5);")
    b.push("  c *= 1.0 - " + fmt(s.vignette.strength) + " * smoothstep(0.32, 0.88, vd);")
  }

  b.push("  fragColor = vec4(clamp(c, 0.0, 1.0), 1.0);")
  b.push("}")

  return { source: b.join("\n") + "\n", active: true, animated: animated }
}
