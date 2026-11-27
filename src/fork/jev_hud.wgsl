// Fork (macOS, FORK.md "Jev key"): the HUD's Jev border, appended to
// `rune_hud.wgsl` by `Painter::pipeline` in `src/rune_hud.rs` and drawn after the
// plate's rim. `u.ears.w` is `fork::jev_key::hud_border()`: 0 draws nothing (every
// other OS, and the goldens), 1 the dark appearance's border, 2 the light one's.
// The plate is dark in either appearance, so the ring is white in both; the light
// one's ring and glow are fainter. Neither moves.
fn jev_border(result: ptr<function, vec4f>, distance: f32, aa: f32, island_shape: f32) {
    let look = u.ears.w;
    if (look <= 0.0) {
        return;
    }
    let dark = look < 1.5;
    let ring = select(0.6, 0.9, dark);
    let width = select(1.0, 1.5, dark);
    let glow = select(0.16, 0.3, dark);
    let sigma = select(3.0, 4.0, dark);
    let inner = select(0.0, 0.06, dark);
    let white = vec3f(1.0);
    // An island hangs from the screen's top edge as the notch's black: no glow.
    if (u.plate_layout.w < 0.5) {
        let outside = max(distance, 0.0);
        let halo = exp(-0.5 * outside * outside / (sigma * sigma)) * (1.0 - coverage(distance, aa));
        composite(result, white, glow * halo);
    }
    let inside = max(-distance, 0.0);
    composite(result, white, inner * exp(-inside / 3.0) * coverage(distance, aa) * island_shape);
    let half = width * 0.5;
    composite(result, white, ring * coverage(abs(distance + half) - half, aa) * island_shape);
}
