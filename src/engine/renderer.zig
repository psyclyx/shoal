const std = @import("std");
const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

const log = std.log.scoped(.renderer);

// ---------------------------------------------------------------------------
// Vertex layout
// ---------------------------------------------------------------------------

pub const Vertex = extern struct {
    // Position
    x: f32,
    y: f32,
    // UV (for texture sampling; 0,0 for solid colour)
    u: f32,
    v: f32,
    // Colour (RGBA 0-1)
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    // Rect dimensions (for SDF rounded corners)
    rect_w: f32,
    rect_h: f32,
    // Corner radii: top-left, top-right, bottom-left, bottom-right
    radius_tl: f32,
    radius_tr: f32,
    radius_bl: f32,
    radius_br: f32,
    // 0.0 = solid colour with rounded-rect SDF, 1.0 = texture sample,
    // 2.0 = area fill curve, 3.0 = line stroke curve
    mode: f32,
};

// ---------------------------------------------------------------------------
// Shader sources
// ---------------------------------------------------------------------------

const vert_src: [*c]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\
    \\layout(location = 0) in vec2 a_pos;
    \\layout(location = 1) in vec2 a_uv;
    \\layout(location = 2) in vec4 a_color;
    \\layout(location = 3) in vec2 a_rect_size;
    \\layout(location = 4) in vec4 a_corner_radius;
    \\layout(location = 5) in float a_mode;
    \\
    \\uniform mat4 u_projection;
    \\
    \\out vec2 v_uv;
    \\out vec4 v_color;
    \\out vec2 v_rect_size;
    \\out vec4 v_corner_radius;
    \\out float v_mode;
    \\out vec2 v_local_pos;
    \\
    \\void main() {
    \\    v_uv           = a_uv;
    \\    v_color        = a_color;
    \\    v_rect_size    = a_rect_size;
    \\    v_corner_radius = a_corner_radius;
    \\    v_mode         = a_mode;
    \\    // a_uv doubles as the normalised local position (0..rect_size)
    \\    v_local_pos    = a_uv * a_rect_size;
    \\    gl_Position    = u_projection * vec4(a_pos, 0.0, 1.0);
    \\}
    \\
;

const frag_src: [*c]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\
    \\in vec2 v_uv;
    \\in vec4 v_color;
    \\in vec2 v_rect_size;
    \\in vec4 v_corner_radius;
    \\in float v_mode;
    \\in vec2 v_local_pos;
    \\
    \\uniform sampler2D u_atlas;
    \\
    \\// Curve uniforms
    \\uniform float u_values[64];
    \\uniform int u_value_count;
    \\uniform float u_values2[64];
    \\uniform int u_value_count2;
    \\uniform vec4 u_color2;
    \\uniform float u_fill;
    \\uniform float u_thickness;
    \\uniform int u_smooth;
    \\
    \\out vec4 frag_color;
    \\
    \\float roundedRectSDF(vec2 p, vec2 half_size, float radius) {
    \\    vec2 d = abs(p) - half_size + vec2(radius);
    \\    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - radius;
    \\}
    \\
    \\float catmullRom(float p0, float p1, float p2, float p3, float t) {
    \\    float t2 = t * t;
    \\    float t3 = t2 * t;
    \\    return 0.5 * ((2.0 * p1) +
    \\                   (-p0 + p2) * t +
    \\                   (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
    \\                   (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3);
    \\}
    \\
    \\float sampleArray(float x, int count, float vals[64]) {
    \\    if (count < 2) return count > 0 ? vals[0] : 0.0;
    \\    float pos = x * float(count - 1);
    \\    int idx = int(floor(pos));
    \\    float t = fract(pos);
    \\    int i0 = clamp(idx - 1, 0, count - 1);
    \\    int i1 = clamp(idx,     0, count - 1);
    \\    int i2 = clamp(idx + 1, 0, count - 1);
    \\    int i3 = clamp(idx + 2, 0, count - 1);
    \\    if (u_smooth > 0) {
    \\        return clamp(catmullRom(vals[i0], vals[i1],
    \\                                vals[i2], vals[i3], t), 0.0, 1.0);
    \\    } else {
    \\        return mix(vals[i1], vals[i2], t);
    \\    }
    \\}
    \\float sampleCurve(float x) { return sampleArray(x, u_value_count, u_values); }
    \\float sampleCurve2(float x) { return sampleArray(x, u_value_count2, u_values2); }
    \\
    \\void main() {
    \\    if (v_mode > 2.5) {
    \\        // Mode 3: line stroke curve
    \\        float curve_val = sampleCurve(v_uv.x);
    \\        float curve_y = 1.0 - curve_val;
    \\        float fw3 = fwidth(curve_y) * v_rect_size.y;
    \\        float dist = abs(v_uv.y - curve_y) * v_rect_size.y;
    \\        float half_thick = max(u_thickness, fw3) * 0.5;
    \\        float aa = 1.0 - smoothstep(half_thick - 0.75, half_thick + 0.75, dist);
    \\        float speculative = smoothstep(u_fill - 0.02, u_fill, v_uv.x);
    \\        vec4 color = mix(v_color, u_color2, speculative);
    \\        float a = aa * color.a;
    \\        frag_color = vec4(color.rgb * a, a);
    \\    } else if (v_mode > 1.5) {
    \\        // Mode 2: area fill curve + optional line overlay from values2
    \\        float curve_val = sampleCurve(v_uv.x);
    \\        float curve_y = 1.0 - curve_val;
    \\        // Use fwidth for slope-aware AA — widens on steep curves
    \\        float fw = fwidth(curve_y);
    \\        float aa_size = max(2.0 / v_rect_size.y, fw * 1.5);
    \\        float aa = smoothstep(curve_y - aa_size, curve_y + aa_size, v_uv.y);
    \\        float speculative = smoothstep(u_fill - 0.02, u_fill, v_uv.x);
    \\        vec4 color = mix(v_color, u_color2, speculative);
    \\        float a = aa * color.a;
    \\        // Overlay second series as a line stroke
    \\        if (u_value_count2 > 0) {
    \\            float c2_val = sampleCurve2(v_uv.x);
    \\            float c2_y = 1.0 - c2_val;
    \\            float fw2 = fwidth(c2_y) * v_rect_size.y;
    \\            float dist2 = abs(v_uv.y - c2_y) * v_rect_size.y;
    \\            float half2 = max(1.0, fw2) * 0.5 + 0.5;
    \\            float line_aa = 1.0 - smoothstep(half2 - 0.5, half2 + 0.5, dist2);
    \\            float line_a = line_aa * u_color2.a;
    \\            // Composite line over area: premultiplied alpha blend
    \\            a = line_a + a * (1.0 - line_a);
    \\            vec3 blended = (u_color2.rgb * line_a + color.rgb * aa * color.a * (1.0 - line_a));
    \\            if (a > 0.0) blended /= a;
    \\            color = vec4(blended, 1.0);
    \\        }
    \\        frag_color = vec4(color.rgb * a, a);
    \\    } else if (v_mode > 0.5) {
    \\        // Mode 1: texture (glyph atlas) -- single-channel alpha
    \\        float a = texture(u_atlas, v_uv).r * v_color.a;
    \\        frag_color = vec4(v_color.rgb * a, a);
    \\    } else {
    \\        // Mode 0: solid colour with rounded-rect SDF antialiasing
    \\        vec2 half_size = v_rect_size * 0.5;
    \\        vec2 p = v_local_pos - half_size;
    \\        float radius;
    \\        if (p.x < 0.0 && p.y < 0.0) {
    \\            radius = v_corner_radius.x;
    \\        } else if (p.x >= 0.0 && p.y < 0.0) {
    \\            radius = v_corner_radius.y;
    \\        } else if (p.x < 0.0 && p.y >= 0.0) {
    \\            radius = v_corner_radius.z;
    \\        } else {
    \\            radius = v_corner_radius.w;
    \\        }
    \\        float dist = roundedRectSDF(p, half_size, radius);
    \\        float aa = (1.0 - smoothstep(-0.5, 0.5, dist)) * v_color.a;
    \\        frag_color = vec4(v_color.rgb * aa, aa);
    \\    }
    \\}
    \\
;

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

pub const Renderer = struct {
    // GL handles
    program: c.GLuint,
    vao: c.GLuint,
    vbo: c.GLuint,

    // Uniform locations
    u_projection: c.GLint,
    u_atlas: c.GLint,
    // Curve uniforms
    u_values: c.GLint,
    u_value_count: c.GLint,
    u_values2: c.GLint,
    u_value_count2: c.GLint,
    u_color2: c.GLint,
    u_fill: c.GLint,
    u_thickness: c.GLint,
    u_smooth: c.GLint,

    // CPU-side vertex accumulator
    vertices: std.ArrayListUnmanaged(Vertex),
    allocator: std.mem.Allocator,

    // Current frame dimensions
    width: f32,
    height: f32,

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        // --- Compile & link shader program ---
        const program = try createProgram();

        const u_projection = c.glGetUniformLocation(program, "u_projection");
        const u_atlas = c.glGetUniformLocation(program, "u_atlas");
        const u_values = c.glGetUniformLocation(program, "u_values");
        const u_value_count = c.glGetUniformLocation(program, "u_value_count");
        const u_values2 = c.glGetUniformLocation(program, "u_values2");
        const u_value_count2 = c.glGetUniformLocation(program, "u_value_count2");
        const u_color2 = c.glGetUniformLocation(program, "u_color2");
        const u_fill = c.glGetUniformLocation(program, "u_fill");
        const u_thickness = c.glGetUniformLocation(program, "u_thickness");
        const u_smooth = c.glGetUniformLocation(program, "u_smooth");

        // --- VAO / VBO ---
        var vao: c.GLuint = 0;
        var vbo: c.GLuint = 0;
        c.glGenVertexArrays(1, &vao);
        c.glGenBuffers(1, &vbo);

        c.glBindVertexArray(vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);

        const stride: c.GLsizei = @sizeOf(Vertex);

        // location 0 : a_pos  (2 x f32)
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "x")));

        // location 1 : a_uv   (2 x f32)
        c.glEnableVertexAttribArray(1);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "u")));

        // location 2 : a_color (4 x f32)
        c.glEnableVertexAttribArray(2);
        c.glVertexAttribPointer(2, 4, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "r")));

        // location 3 : a_rect_size (2 x f32)
        c.glEnableVertexAttribArray(3);
        c.glVertexAttribPointer(3, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "rect_w")));

        // location 4 : a_corner_radius (4 x f32)
        c.glEnableVertexAttribArray(4);
        c.glVertexAttribPointer(4, 4, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "radius_tl")));

        // location 5 : a_mode (1 x f32)
        c.glEnableVertexAttribArray(5);
        c.glVertexAttribPointer(5, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "mode")));

        c.glBindVertexArray(0);

        return .{
            .program = program,
            .vao = vao,
            .vbo = vbo,
            .u_projection = u_projection,
            .u_atlas = u_atlas,
            .u_values = u_values,
            .u_value_count = u_value_count,
            .u_values2 = u_values2,
            .u_value_count2 = u_value_count2,
            .u_color2 = u_color2,
            .u_fill = u_fill,
            .u_thickness = u_thickness,
            .u_smooth = u_smooth,
            .vertices = .{},
            .allocator = allocator,
            .width = 0,
            .height = 0,
        };
    }

    pub fn deinit(self: *Renderer) void {
        c.glDeleteProgram(self.program);
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteVertexArrays(1, &self.vao);
        self.vertices.deinit(self.allocator);
    }

    // -----------------------------------------------------------------------
    // Frame begin / end
    // -----------------------------------------------------------------------

    pub fn begin(self: *Renderer, width: f32, height: f32) void {
        self.width = width;
        self.height = height;
        self.vertices.clearRetainingCapacity();

        c.glViewport(0, 0, @intFromFloat(width), @intFromFloat(height));
        c.glClearColor(0.0, 0.0, 0.0, 0.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);

        c.glUseProgram(self.program);

        // Orthographic projection: (0,0) top-left -> (width,height) bottom-right
        const proj = ortho(0, width, height, 0, -1, 1);
        c.glUniformMatrix4fv(self.u_projection, 1, c.GL_FALSE, &proj);

        // Bind atlas to texture unit 0 (caller is responsible for creating the texture)
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glUniform1i(self.u_atlas, 0);
    }

    pub fn end(self: *Renderer) void {
        self.flush();
        c.glDisable(c.GL_SCISSOR_TEST);
    }

    // -----------------------------------------------------------------------
    // Drawing primitives
    // -----------------------------------------------------------------------

    /// Draw a filled, optionally rounded rectangle.
    pub fn drawRect(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: [4]f32,
        corner_radius: [4]f32,
    ) void {
        self.pushQuad(x, y, w, h, color, corner_radius, .{ 0, 0, 1, 1 }, 0.0);
    }

    /// Draw a textured quad (e.g. a glyph from an atlas).
    /// `tex_x/y/w/h` are texel coordinates normalised to 0-1 by the caller.
    pub fn drawTexturedQuad(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: [4]f32,
        tex_x: f32,
        tex_y: f32,
        tex_w: f32,
        tex_h: f32,
    ) void {
        const no_radius = [4]f32{ 0, 0, 0, 0 };
        self.pushQuad(x, y, w, h, color, no_radius, .{ tex_x, tex_y, tex_w, tex_h }, 1.0);
    }

    /// Draw a border as four rectangles (top, bottom, left, right).
    /// `widths` order: top, right, bottom, left.
    pub fn drawBorder(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: [4]f32,
        widths: [4]f32,
        corner_radius: [4]f32,
    ) void {
        const top = widths[0];
        const right = widths[1];
        const bottom = widths[2];
        const left = widths[3];

        const no_r = [4]f32{ 0, 0, 0, 0 };

        // Top edge
        if (top > 0) {
            self.drawRect(x, y, w, top, color, .{ corner_radius[0], corner_radius[1], 0, 0 });
        }
        // Bottom edge
        if (bottom > 0) {
            self.drawRect(x, y + h - bottom, w, bottom, color, .{ 0, 0, corner_radius[2], corner_radius[3] });
        }
        // Left edge (between top and bottom borders)
        if (left > 0) {
            self.drawRect(x, y + top, left, h - top - bottom, color, no_r);
        }
        // Right edge (between top and bottom borders)
        if (right > 0) {
            self.drawRect(x + w - right, y + top, right, h - top - bottom, color, no_r);
        }
    }

    /// Draw a curve (area fill or line stroke) evaluated per-pixel in the fragment shader.
    /// Flushes the vertex batch to set curve-specific uniforms.
    pub fn drawCurve(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        values: []const f32,
        value_count: u32,
        values2: []const f32,
        value_count2: u32,
        color: [4]f32,
        color2: [4]f32,
        fill: f32,
        thickness: f32,
        smooth: bool,
        is_line: bool,
    ) void {
        self.flush();

        // Set curve uniforms
        c.glUniform1fv(self.u_values, @intCast(value_count), values.ptr);
        c.glUniform1i(self.u_value_count, @intCast(value_count));
        if (value_count2 > 0) {
            c.glUniform1fv(self.u_values2, @intCast(value_count2), values2.ptr);
        }
        c.glUniform1i(self.u_value_count2, @intCast(value_count2));
        c.glUniform4f(self.u_color2, color2[0], color2[1], color2[2], color2[3]);
        c.glUniform1f(self.u_fill, fill);
        c.glUniform1f(self.u_thickness, thickness);
        c.glUniform1i(self.u_smooth, @intFromBool(smooth));

        // Mode 2.0 = area fill, 3.0 = line stroke.
        // UV is 0-1 across the quad (same mapping as mode 0 rects).
        const mode: f32 = if (is_line) 3.0 else 2.0;
        self.pushQuad(x, y, w, h, color, .{ 0, 0, 0, 0 }, .{ 0, 0, 1, 1 }, mode);

        // Flush immediately so curve uniforms only apply to this quad.
        self.flush();
    }

    /// Enable scissor test to clip rendering to the given rectangle.
    pub fn setScissor(self: *Renderer, x: f32, y: f32, w: f32, h: f32) void {
        // Flush anything that was queued before the scissor change.
        self.flush();

        c.glEnable(c.GL_SCISSOR_TEST);
        // GL scissor origin is bottom-left; our coordinate space has origin at top-left.
        const sx: c.GLint = @intFromFloat(x);
        const sy: c.GLint = @intFromFloat(self.height - y - h);
        const sw: c.GLsizei = @intFromFloat(w);
        const sh: c.GLsizei = @intFromFloat(h);
        c.glScissor(sx, sy, sw, sh);
    }

    /// Disable scissor test.
    pub fn clearScissor(self: *Renderer) void {
        self.flush();
        c.glDisable(c.GL_SCISSOR_TEST);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    pub fn flush(self: *Renderer) void {
        const count = self.vertices.items.len;
        if (count == 0) return;

        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferData(
            c.GL_ARRAY_BUFFER,
            @intCast(count * @sizeOf(Vertex)),
            self.vertices.items.ptr,
            c.GL_STREAM_DRAW,
        );

        c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(count));
        c.glBindVertexArray(0);

        self.vertices.clearRetainingCapacity();
    }

    fn pushQuad(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: [4]f32,
        corner_radius: [4]f32,
        uv_rect: [4]f32, // u0, v0, u1, v1
        mode: f32,
    ) void {
        // For solid-colour quads and curves, UV encodes the normalised local
        // position (0..1 mapping to 0..rect_size). For textured quads the UV
        // is the atlas coordinate.
        const is_normalized = mode < 0.5 or mode > 1.5;
        const uv_l = if (is_normalized) @as(f32, 0.0) else uv_rect[0];
        const uv_t = if (is_normalized) @as(f32, 0.0) else uv_rect[1];
        const uv_r = if (is_normalized) @as(f32, 1.0) else uv_rect[0] + uv_rect[2];
        const uv_b = if (is_normalized) @as(f32, 1.0) else uv_rect[1] + uv_rect[3];

        const base = Vertex{
            .x = 0,
            .y = 0,
            .u = 0,
            .v = 0,
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
            .rect_w = w,
            .rect_h = h,
            .radius_tl = corner_radius[0],
            .radius_tr = corner_radius[1],
            .radius_bl = corner_radius[2],
            .radius_br = corner_radius[3],
            .mode = mode,
        };

        // Two triangles: TL, TR, BL  and  TR, BR, BL
        const verts = [6]Vertex{
            // top-left
            withPosUV(base, x, y, uv_l, uv_t),
            // top-right
            withPosUV(base, x + w, y, uv_r, uv_t),
            // bottom-left
            withPosUV(base, x, y + h, uv_l, uv_b),
            // top-right
            withPosUV(base, x + w, y, uv_r, uv_t),
            // bottom-right
            withPosUV(base, x + w, y + h, uv_r, uv_b),
            // bottom-left
            withPosUV(base, x, y + h, uv_l, uv_b),
        };

        self.vertices.appendSlice(self.allocator, &verts) catch {
            log.err("vertex buffer allocation failed", .{});
        };
    }
};

// ---------------------------------------------------------------------------
// Utility functions
// ---------------------------------------------------------------------------

fn withPosUV(base: Vertex, x: f32, y: f32, u: f32, v: f32) Vertex {
    var vert = base;
    vert.x = x;
    vert.y = y;
    vert.u = u;
    vert.v = v;
    return vert;
}

/// Build a column-major 4x4 orthographic projection matrix (returned as [16]f32).
fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) [16]f32 {
    const rl = right - left;
    const tb = top - bottom;
    const fn_ = far - near;
    return .{
        2.0 / rl,           0,                  0,                0,
        0,                   2.0 / tb,           0,                0,
        0,                   0,                  -2.0 / fn_,       0,
        -(right + left) / rl, -(top + bottom) / tb, -(far + near) / fn_, 1,
    };
}

// ---------------------------------------------------------------------------
// Shader compilation helpers
// ---------------------------------------------------------------------------

fn createProgram() !c.GLuint {
    const vs = try compileShader(c.GL_VERTEX_SHADER, vert_src);
    defer c.glDeleteShader(vs);

    const fs = try compileShader(c.GL_FRAGMENT_SHADER, frag_src);
    defer c.glDeleteShader(fs);

    const program = c.glCreateProgram();
    c.glAttachShader(program, vs);
    c.glAttachShader(program, fs);
    c.glLinkProgram(program);

    var ok: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var buf: [1024]u8 = undefined;
        var len: c.GLsizei = 0;
        c.glGetProgramInfoLog(program, buf.len, &len, &buf);
        log.err("shader link error: {s}", .{buf[0..@intCast(len)]});
        c.glDeleteProgram(program);
        return error.ShaderLinkFailed;
    }

    return program;
}

fn compileShader(shader_type: c.GLenum, source: [*c]const u8) !c.GLuint {
    const shader = c.glCreateShader(shader_type);
    c.glShaderSource(shader, 1, &source, null);
    c.glCompileShader(shader);

    var ok: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var buf: [1024]u8 = undefined;
        var len: c.GLsizei = 0;
        c.glGetShaderInfoLog(shader, buf.len, &len, &buf);
        const kind: []const u8 = if (shader_type == c.GL_VERTEX_SHADER) "vertex" else "fragment";
        log.err("{s} shader compile error: {s}", .{ kind, buf[0..@intCast(len)] });
        c.glDeleteShader(shader);
        return error.ShaderCompileFailed;
    }

    return shader;
}
