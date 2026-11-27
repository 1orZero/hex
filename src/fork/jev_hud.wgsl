// Fork (macOS, FORK.md "Jev key"): the HUD's Jev border, appended to
// `rune_hud.wgsl` by `Painter::pipeline` in `src/rune_hud.rs` and drawn after the
// plate's rim. `u.ears.w` is `fork::jev_key::hud_border()`: 0 draws nothing (every
// other OS, and the goldens), 1 the dark appearance's border, 2 the light one's.
// The plate is dark in either appearance. Dark draws a white ring and glow; on a
// light window a white glow can't be seen, so light draws a violet, pink, and cyan
// gradient instead. Neither moves.
fn jev_border(result: ptr<function, vec4f>, point: vec2f, distance: f32, aa: f32, island_shape: f32) {
    let look = u.ears.w;
    if (look <= 0.0) {
        return;
    }
    var ring_color = vec3f(1.0);
    var glow_color = vec3f(1.0);
    var ring = 0.9;
    var width = 1.5;
    var glow = 0.3;
    var sigma = 4.0;
    var inner = 0.06;
    if (look > 1.5) {
        ring_color = jev_gradient(
            vec3f(179.0, 157.0, 251.0) / 255.0,
            vec3f(240.0, 166.0, 234.0) / 255.0,
            vec3f(103.0, 216.0, 238.0) / 255.0,
            point);
        glow_color = jev_gradient(
            vec3f(124.0, 58.0, 237.0) / 255.0,
            vec3f(192.0, 38.0, 211.0) / 255.0,
            vec3f(8.0, 145.0, 178.0) / 255.0,
            point);
        ring = 1.0;
        glow = 0.36;
        sigma = 7.0;
        inner = 0.16;
    }
    // An island hangs from the screen's top edge as the notch's black: no glow.
    if (u.plate_layout.w < 0.5) {
        let outside = max(distance, 0.0);
        let halo = exp(-0.5 * outside * outside / (sigma * sigma)) * (1.0 - coverage(distance, aa));
        composite(result, glow_color, glow * halo);
    }
    let inside = max(-distance, 0.0);
    composite(result, glow_color, inner * exp(-inside / 3.0) * coverage(distance, aa) * island_shape);
    let half = width * 0.5;
    composite(result, ring_color, ring * coverage(abs(distance + half) - half, aa) * island_shape);
}

// Three colours around the plate by angle (flattened, as the plate is wide), cyan
// at the left end, violet along the top, pink at the right end.
fn jev_gradient(a: vec3f, b: vec3f, c: vec3f, point: vec2f) -> vec3f {
    let turn = atan2(point.y * 3.0, point.x) / TAU + 0.25;
    let w = 0.5 + 0.5 * cos(TAU * vec3f(turn, turn - 1.0 / 3.0, turn - 2.0 / 3.0));
    let k = w * w * w;
    return (a * k.x + b * k.y + c * k.z) / (k.x + k.y + k.z);
}
